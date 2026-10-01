//! ztex.context — "initialize once, render many".
//!
//! A `Context` owns a `FontContext` (embedded Latin Modern Math + Roman
//! fallback fonts) and a `FontMetrics` union wired to it: `fm` is the
//! `.font` arm pointing at the context's fonts, so every `render` measures
//! glyphs from the REAL fonts — served from the context's per-(face,
//! codepoint) metric cache, which the first render fills and every later
//! render hits. Create one context, render any number of formulas with it.
//!
//! Thread-safety: a `Context` is NOT shareable — the first render lazily
//! fills the font metric cache and arena, so two threads rendering through
//! the same Context race on that state. Use one Context per thread, or
//! guard a shared Context with an external mutex. The static facade
//! `ztex.render` IS shareable: it measures from the immutable static
//! tables and shares no mutable state.
//!
//! The FontContext is heap-allocated: the `fm` union arm (a pointer into
//! it) must stay valid across the `init` return, and a `FontContext` value
//! returned by `init` is not guaranteed to be placed at the caller's result
//! location in this toolchain — a by-value self-pointer would dangle on the
//! caller's stack once `init`'s frame is reused. Heap allocation makes the
//! pointer stable; copies of the Context share the FontContext, so deinit
//! must be called exactly once.
//!
//! This is the font-backed pipeline; `ztex.render` (static metric tables)
//! stays available for one-shot use and for tests. Both facades call the
//! SINGLE shared pipeline `renderPipeline` (root.zig) with an explicit
//! `FontMetrics` argument. The metric source is the closed `FontMetrics`
//! union: context.zig builds the `.font` arm — a `FontHook` carrying the
//! `*FontContext` (opaque to the layout module, which cannot import
//! font.zig), the font-glyph lookup below, and a borrowed pointer to the
//! owned LM Math face's MATH constants — so `init` is one struct literal
//! instead of hand-installed fn-pointer plumbing, and the concrete cast
//! lives in exactly one place.

const std = @import("std");
const atom = @import("ztex.atom");
const font = @import("font.zig");
const parse = @import("ztex.parse");
const layout = @import("ztex.layout");
const metrics = layout.metrics;
const draw = layout.draw;
pub const raster = @import("raster.zig");
pub const PixelBuffer = raster.PixelBuffer;
pub const RasterOptions = raster.Options;
// The root module hosts the shared `renderPipeline` this facade delegates
// to (same module directory, so the relative import stays inside the ztex
// module; root.zig imports this file back — Zig resolves the cycle lazily).
const root = @import("root.zig");

/// Font-backed glyph lookup, the `.font` arm's hook (see `FontHook` in
/// metrics.zig). Real-font metrics for `cp` in `style` at the 10pt base
/// (em × 10, so the layout's s(v, size_pt) scaling applies — LM is a 10pt
/// design): width = the face's cached hmtx advance, height/depth = the
/// face's OWN nominal hhea extents. The face comes from `faceForStyle`
/// (`\text`/`\mathrm` → LM Roman regular, `\textit` → its italic,
/// `\mathbf` → bold, `\textit{\textbf{}}` → bold italic, every other style
/// → LM Math), the same mapping the rasterizer draws from, so a run can
/// never measure from one face and be drawn from another.
/// The italic correction and top accent attachment are the face's OWN MATH
/// measurements — read once per (face, cp) by the font context, cached
/// beside the advance and scaled with it, so sup/sub placement follows the
/// glyph that is actually drawn (LM Math's table: 𝑓 carries a 0.09em
/// italic correction, 𝑥 a 0.329em top accent). A face that records none —
/// every LM Roman text face — keeps the static row's correction instead.
/// Null when the face has no glyph for `cp`: glyph/glyphAt then fall back
/// to the static tables, and finally to glyphEstimate.
fn contextGlyph(ctx: *anyopaque, cp: u21, style: atom.CharStyle) ?metrics.Glyph {
    const f: *font.FontContext = @ptrCast(@alignCast(ctx));
    const face = f.faceForStyle(style);
    if (face.glyphIndex(cp) == null) return null;
    const m = f.metrics(face, cp, 10.0);
    var ic: f32 = 0;
    if (m.italic_correction) |value| {
        ic = value;
    } else if (metrics.staticGlyph(cp, style)) |e| {
        ic = e.italic_correction;
    }
    return .{
        .width = m.width,
        .height = m.height,
        .depth = m.depth,
        .italic_correction = ic,
        .top_accent_attachment = m.top_accent_attachment,
    };
}

pub const Context = struct {
    /// Caller's allocator; owns the FontContext allocation.
    gpa: std.mem.Allocator,
    /// The FontContext: embedded LM fonts + the per-(face, cp) metric cache
    /// (heap-owned).
    fonts: *font.FontContext,
    /// Metric source: the `.font` arm of the `FontMetrics` union, pointing
    /// at `fonts`.
    fm: metrics.FontMetrics,

    /// Build a context preloaded with the embedded Latin Modern fonts.
    pub fn init(gpa: std.mem.Allocator) !Context {
        const fonts = try gpa.create(font.FontContext);
        errdefer gpa.destroy(fonts);
        fonts.* = try font.FontContext.init(gpa);
        errdefer fonts.deinit();
        return .{
            .gpa = gpa,
            .fonts = fonts,
            .fm = .{
                .font = .{
                    .ctx = fonts,
                    .glyph = &contextGlyph,
                    // Borrowed from the owned LM Math face and valid for the
                    // life of `fonts`: layout reads its script sizes, axis
                    // height, gaps and rule thicknesses from the font's own
                    // MATH table instead of the static TeX parameters.
                    .math_constants = fonts.math.mathConstants(),
                },
            },
        };
    }

    /// Release the FontContext (arena: embedded fonts, cache entries) and
    /// its heap allocation. Call exactly once.
    pub fn deinit(self: *Context) void {
        self.fonts.deinit();
        self.gpa.destroy(self.fonts);
        self.* = undefined;
    }

    /// Full pipeline: LaTeX source → draw list, measured from the real
    /// fonts via `self.fm`. Thin wrapper over the shared `renderPipeline`
    /// (root.zig) with this Context's metric source; the returned
    /// `DrawList`'s `text` primitives alias `src`, so `src` must outlive
    /// the draw list. `size_pt` is the base font size in points. On a
    /// parse error, `err_info` (when non-null) is filled with the kind +
    /// span. Allocates with `self.gpa`.
    ///
    /// Takes `*Context` (not `*const`): the first render fills the font
    /// metric cache (`FontContext.metrics` mutates it while measuring), so
    /// rendering is not a const operation.
    pub fn render(
        self: *Context,
        src: []const u8,
        style: layout.Style,
        size_pt: f32,
        err_info: ?*parse.Info,
    ) (parse.Error || error{InvalidAst})!draw.DrawList {
        return root.renderPipeline(self.gpa, &self.fm, src, style, size_pt, err_info);
    }

    /// Render a formula directly to a raster PixelBuffer (RGBA or Alpha mask).
    pub fn renderPixels(
        self: *Context,
        src: []const u8,
        style: layout.Style,
        size_pt: f32,
        opts: RasterOptions,
        err_info: ?*parse.Info,
    ) !PixelBuffer {
        var dl = try self.render(src, style, size_pt, err_info);
        defer dl.deinit();
        return raster.rasterize(self.gpa, self, &dl, opts);
    }
};

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "context: init once, render many — font metrics match the LM table widths" {
    var ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    // x at 20pt: math-italic U+1D465 advance 0.572em × 20 = 11.44
    // row 5.28pt × 2). The font path answers through the metrics cache.
    var out = try ctx.render("x", .display, 20, null);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.len());
    const t = out.items.items[0].text;
    try testing.expectEqualStrings("𝑥", t.bytes);
    try testing.expectEqual(@as(f32, 20), t.size);
    try testing.expectApproxEqAbs(@as(f32, 11.44), out.width, 0.001);
    // a second render reuses the same context (and its font metric cache)
    var out2 = try ctx.render("x", .display, 20, null);
    defer out2.deinit();
    try testing.expectApproxEqAbs(out.width, out2.width, 0.0001);
    // The per-(face, cp) cache holds ONE entry after two renders of "x":
    // the second render hit the cache instead of recomputing the advance.
    try testing.expectEqual(@as(usize, 1), ctx.fonts.metrics_cache.count());
}

test "context: unmapped codepoint falls back to the static table / estimate" {
    var ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    // U+25B9 (▹ \triangleright) is not in LM Math; the font path falls back
    // to the static table's row (CM width kept for codepoints LM Math does
    // not cover) instead of the 0.5em nominal advance, and rendering still
    // produces a glyph box — graceful, no hole.
    var out = try ctx.render("\\triangleright", .display, 20, null);
    defer out.deinit();
    try testing.expect(out.len() > 0);
    try testing.expectApproxEqAbs(@as(f32, 10.00004), out.width, 0.01);
    // U+1F600 has no row anywhere: glyph() is null (font path + static
    // table both miss) and glyphEstimate answers with its 0.5em estimate
    // (10pt at 20pt, 5pt at the 10pt base).
    const g = metrics.glyph(&ctx.fm, 0x1F600, .italic);
    try testing.expect(g == null);
    const est = metrics.glyphEstimate(&ctx.fm, 0x1F600, .italic);
    try testing.expectApproxEqAbs(@as(f32, 5.0), est.width, 0.001);
}

/// A digest of the drawn coverage: two styles that rasterize the same face
/// through the same code path produce the same digest.
fn inkDigest(buffer: PixelBuffer) u64 {
    var h: u64 = 1469598103934665603;
    for (buffer.pixels) |px| h = (h ^ px) *% 1099511628211;
    return h;
}

test "context: the hook reports the drawn glyph's own MATH measurements" {
    var ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    // The hook borrows LM Math's decoded constants from the owned face: the
    // very pointer layout reads its axis height and script sizes from, never
    // a per-render copy that could outlive the face.
    const mc = ctx.fonts.math.mathConstants() orelse return error.TestUnexpectedResult;
    const borrowed: *const atom.MathConstants = ctx.fm.font.math_constants orelse
        return error.TestUnexpectedResult;
    try testing.expect(mc == borrowed);
    try testing.expectApproxEqAbs(@as(f32, 0.25), mc.axis_height, 0.001);
    // 𝑓 (U+1D453) carries a 0.09em italic correction in LM Math's MATH
    // table; the hook reports that, not the static cmmi10 row's value.
    const f_cp: u21 = 0x1D453;
    const f_gid = ctx.fonts.math.glyphIndex(f_cp) orelse
        return error.TestUnexpectedResult;
    const f_ic = ctx.fonts.math.mathValues(f_gid).italic_correction orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 0.9), f_ic * 10.0, 0.0001);
    const fg = metrics.glyph(&ctx.fm, f_cp, .italic) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(f_ic * 10.0, fg.italic_correction, 0.0001);
    // 𝑥 (U+1D465) has NO italic correction but a 0.329em top accent: the
    // absence stays absent and the accent is forwarded, both straight from
    // the face's own table.
    const x_cp: u21 = 0x1D465;
    const x_gid = ctx.fonts.math.glyphIndex(x_cp) orelse
        return error.TestUnexpectedResult;
    const x_values = ctx.fonts.math.mathValues(x_gid);
    try testing.expect(x_values.italic_correction == null);
    const x_taa = x_values.top_accent_attachment orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 3.29), x_taa * 10.0, 0.0001);
    const xg = metrics.glyph(&ctx.fm, x_cp, .italic) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(x_taa * 10.0, xg.top_accent_attachment.?, 0.0001);
    // A text face records no MATH data at all, so nothing is invented for it:
    // the correction stays whatever the static path has for that style.
    const italic_face = ctx.fonts.faceForStyle(.text_italic);
    try testing.expect(italic_face.mathConstants() == null);
    const tg = metrics.glyph(&ctx.fm, 'f', .text_italic) orelse
        return error.TestUnexpectedResult;
    const static_ic = if (metrics.staticGlyph('f', .text_italic)) |e|
        e.italic_correction
    else
        0;
    try testing.expectApproxEqAbs(static_ic, tg.italic_correction, 0.0001);
    try testing.expect(tg.top_accent_attachment == null);
}

test "context: every text style measures and rasterizes one identical face" {
    var ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    const cases = [_]struct { src: []const u8, style: atom.CharStyle }{
        .{ .src = "\\mathrm{f}", .style = .roman },
        .{ .src = "\\textit{f}", .style = .text_italic },
        .{ .src = "\\mathbf{f}", .style = .bold },
        .{ .src = "\\textit{\\textbf{f}}", .style = .bold_italic },
    };
    var ink: [cases.len]u64 = undefined;
    for (cases, 0..) |c, i| {
        // Measured from the face the rasterizer draws it from: that face's
        // own advance for the same codepoint, at the 10pt base.
        const face = ctx.fonts.faceForStyle(c.style);
        const g = metrics.glyph(&ctx.fm, 'f', c.style) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(
            ctx.fonts.metrics(face, 'f', 10.0).width,
            g.width,
            0.001,
        );
        var out = try ctx.render(c.src, .display, 20, null);
        defer out.deinit();
        try testing.expectEqual(@as(usize, 1), out.len());
        try testing.expectEqual(c.style, out.items.items[0].text.style);
        try testing.expectEqualStrings("f", out.items.items[0].text.bytes);
        try testing.expectApproxEqAbs(g.width * 2.0, out.width, 0.001);
        var buf = try ctx.renderPixels(c.src, .display, 20, .{ .format = .alpha8 }, null);
        defer buf.deinit();
        ink[i] = inkDigest(buf);
    }
    // Four distinct real faces draw four distinct 'f's: no style is a
    // slanted or emboldened copy of another.
    for (ink, 0..) |a, i| {
        for (ink, 0..) |b, j| {
            if (i < j) try testing.expect(a != b);
        }
    }
}
