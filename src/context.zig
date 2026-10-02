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
//! font.zig), the font-glyph lookup below, the horizontal and vertical MATH
//! stretch resolvers below, and a borrowed pointer to the
//! owned LM Math face's MATH constants — so `init` is one struct literal
//! instead of hand-installed fn-pointer plumbing, and the concrete cast
//! lives in exactly one place.

const std = @import("std");
const atom = @import("ztex.atom");
const font = @import("ztex.font");
const glyph = @import("ztex.glyph");
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
/// measurements — read once per (face, cp, glyph) by the font context,
/// cached beside the advance and scaled with it, so sup/sub placement
/// follows the glyph that is actually drawn (LM Math's table: 𝑓 carries a
/// 0.09em italic correction, 𝑥 a 0.329em top accent). A face that records
/// none — every LM Roman text face — keeps the static row's correction
/// instead. Null when the face has no glyph for `cp`: glyph/glyphAt then
/// fall back to the static tables, and finally to glyphEstimate.
///
/// `size_pt` is the size the glyph is DRAWN at and selects nothing but the
/// prime tier: the answer stays the 10pt base every caller scales, and it is
/// asked for at `font.small_prime_max_size` or below so the prime composites
/// are measured from the unencoded alternates the back ends paint there.
/// Above the gate the base itself is asked for and multiplied by exactly one,
/// so no size that was already correct gains a rounding step.
fn contextGlyph(ctx: *anyopaque, cp: u21, style: atom.CharStyle, size_pt: f32) ?metrics.Glyph {
    const f: *font.FontContext = @ptrCast(@alignCast(ctx));
    const face = f.faceForCodepoint(cp, style);
    if (face.glyphIndex(cp) == null) return null;
    const script: ?f32 = if (size_pt <= font.small_prime_max_size) size_pt else null;
    const m = f.metrics(face, cp, script orelse base_pt);
    const to_base: f32 = if (script) |drawn| base_pt / drawn else 1.0;
    var ic: f32 = 0;
    if (m.italic_correction) |value| {
        ic = value * to_base;
    } else if (metrics.staticGlyph(cp, style)) |e| {
        ic = e.italic_correction;
    }
    return .{
        .width = m.width * to_base,
        .height = m.height * to_base,
        .depth = m.depth * to_base,
        .italic_correction = ic,
        .top_accent_attachment = if (m.top_accent_attachment) |value| value * to_base else null,
    };
}

/// The em size every per-glyph answer is stated at; the layout scales it with
/// `s()`.
const base_pt: f32 = 10.0;

fn contextHorizontal(
    ctx: *anyopaque,
    cp: u21,
    req_em: f32,
) metrics.StretchError!?metrics.StretchGeometry {
    const fonts: *font.FontContext = @ptrCast(@alignCast(ctx));
    const stretch = (try glyph.stretchGeometry(
        fonts.gpa,
        fonts.math,
        .{ .cp = cp, .horizontal_req = req_em },
    )) orelse return null;
    return .{
        .advance_em = stretch.advance_em,
        .finite_ceiling_em = stretch.finite_ceiling_em,
        .ink = inkOf(stretch.ink),
    };
}

/// A request's painted union as layout's `GlyphInk`, in em from the item's
/// own origin and Y-up: `asc` above the baseline, `desc` below it, and
/// `bottom` the lower edge measured back UP — positive only for ink that
/// floats entirely above the baseline. `left` is how far the ink reaches
/// left of the origin; `right_edge` is its absolute right edge and stays
/// SIGNED, because the consumer takes `max(0, right_edge × size − advance)`
/// for the overhang and ink that ends left of its own origin is not a margin.
fn inkOf(ink: glyph.Bounds) metrics.GlyphInk {
    return .{
        .asc = @max(0, ink.y_max),
        .desc = @max(0, -ink.y_min),
        .left = @max(0, -ink.x_min),
        .right_edge = ink.x_max,
        .bottom = @max(0, ink.y_min),
    };
}

/// The VERTICAL form of `cp` a draw item names, resolved from the owned LM
/// Math face's own MATH table: `form` is the rung of THIS fence's own ladder,
/// `assembly_req` the ink height in em that asks for its assembly, and
/// `fixed_req` the amsmath FIXED-rule height whose covering rung this fence
/// picks (0 for neither). The answer is the widest hmtx advance among the
/// glyphs the form places — the column layout reserves — together with the
/// ink those placements really paint, both from the same resolution the back
/// ends draw through. A face with no MATH table degrades to its base cmap
/// glyph exactly as raster and svg do; null is only "no glyph, or nothing
/// painted", and the resolver's errors stay errors.
fn contextVertical(
    ctx: *anyopaque,
    cp: u21,
    form: u8,
    assembly_req: f32,
    fixed_req: f32,
) metrics.StretchError!?metrics.StretchGeometry {
    const fonts: *font.FontContext = @ptrCast(@alignCast(ctx));
    const stretch = (try glyph.verticalGeometry(fonts.gpa, fonts.math, .{
        .cp = cp,
        .delim_form = form,
        .delim_req = assembly_req,
        .delim_fixed = fixed_req,
    })) orelse return null;
    return .{
        .advance_em = stretch.advance_em,
        .ink = inkOf(stretch.ink),
    };
}

/// Reusable embedded-font renderer with one owner and mutable glyph caches.
///
/// Created by `init`; a zero or arbitrary literal is not a valid context.
/// `fonts` has a stable heap address for the hooks in `fm`. A context value
/// may move, but a copy shares its allocations and is not a second owner.
/// Keep the original allocator and owned font/hook identities intact until
/// exactly one `deinit`; fields are reachable, not enforced private state.
/// Methods do not perform font discovery or I/O. Concurrent or reentrant
/// access to one context requires external serialization.
pub const Context = struct {
    /// Borrowed allocator for the font owner, caches, and render results.
    /// Keep its backing state and identity valid through each result's cleanup.
    gpa: std.mem.Allocator,
    /// Owned heap allocation; released by this context, never by a borrower.
    fonts: *font.FontContext,
    /// Hooks and MATH constants borrowed from `fonts`; invalid after `deinit`.
    fm: metrics.FontMetrics,

    /// Allocation or embedded-font decoding failures; construction is failure-atomic.
    pub const InitError = error{OutOfMemory} || font.FontError;

    /// Construct the font owner and its metric hooks with `gpa`, which is retained.
    /// On error every acquired allocation is released and no context escapes.
    pub fn init(gpa: std.mem.Allocator) InitError!Context {
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
                    .horizontal_glyph = &contextHorizontal,
                    .vertical_glyph = &contextVertical,
                    // Borrowed from the owned LM Math face and valid for the
                    // life of `fonts`: layout reads its script sizes, axis
                    // height, gaps and rule thicknesses from the font's own
                    // MATH table instead of the static TeX parameters.
                    .math_constants = fonts.math.mathConstants(),
                },
            },
        };
    }

    /// Releases the owned font arena and heap allocation, not `gpa` or render results.
    /// The value and its font/hook borrows become invalid; repeat disposal is invalid.
    pub fn deinit(self: *Context) void {
        self.fonts.deinit();
        self.gpa.destroy(self.fonts);
        self.* = undefined;
    }

    /// Lay out `src` using the owned font faces and metric cache.
    ///
    /// `size_pt` must be finite and positive (`error.InvalidArgument` otherwise).
    /// The returned list is owned by the caller and borrows only `src`, which
    /// must remain alive and unchanged until its last use; it does not borrow
    /// this context. Its stored allocator is `self.gpa`; dispose it once.
    ///
    /// Syntax/source-limit failures fill a supplied `err_info`; `null` opts
    /// out. Success and other failures leave it unchanged. Failure releases
    /// scratch and returns no partial list, but may retain valid cache entries.
    /// This mutates caches, performs no I/O, and has no cancellation points.
    pub fn render(
        self: *Context,
        src: []const u8,
        style: layout.Style,
        size_pt: f32,
        err_info: ?*parse.Info,
    ) root.RenderError!draw.DrawList {
        return root.renderPipeline(self.gpa, &self.fm, src, style, size_pt, err_info);
    }

    /// Render through this context into an independently owned pixel buffer.
    ///
    /// Source, size, and diagnostic rules are those of `render`; frame limits
    /// are those of `raster.rasterize`. The caller disposes the result once
    /// while `self.gpa` remains valid. Neither source nor context is retained.
    /// Failure returns no partial buffer and leaves the context usable.
    pub fn renderPixels(
        self: *Context,
        src: []const u8,
        style: layout.Style,
        size_pt: f32,
        opts: RasterOptions,
        err_info: ?*parse.Info,
    ) root.PixelRenderError!PixelBuffer {
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

test "context: tall and unpaired delimiter ink is enclosed by the zero-padding frame" {
    var ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    const sources = [_][]const u8{
        "\\begin{pmatrix}a&b\\\\c&d\\\\e&f\\end{pmatrix}",
        "\\left\\{\\begin{matrix}a\\\\b\\\\c\\\\d\\\\e\\\\f\\end{matrix}\\right\\}",
        "\\left.\\frac{a}{b}\\right|",
    };
    for (sources) |source| {
        var out = try ctx.render(source, .display, 20, null);
        defer out.deinit();
        const frame = out.bounds();
        for (out.items.items) |item| {
            if (item != .text) continue;
            const t = item.text;
            if (t.delim_form == 0 and t.delim_req == 0 and t.delim_fixed == 0) continue;
            const cp = std.unicode.utf8Decode(t.bytes) catch return error.TestUnexpectedResult;
            const ink = (try glyph.paintedBounds(testing.allocator, ctx.fonts.math, .{
                .cp = cp,
                .delim_form = t.delim_form,
                .delim_req = t.delim_req,
                .delim_fixed = t.delim_fixed,
            })) orelse return error.TestUnexpectedResult;
            try testing.expect(t.x + ink.x_min * t.size >= frame.min_x - 0.001);
            try testing.expect(t.x + ink.x_max * t.size <= frame.min_x + frame.width + 0.001);
            try testing.expect(t.y - ink.y_max * t.size >= frame.min_y - 0.001);
            try testing.expect(
                t.y - ink.y_min * t.size <= frame.min_y + frame.height + frame.depth + 0.001,
            );
        }
    }
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

test "context: a font-backed accent lands the mark's attachment on the base's" {
    var ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var out = try ctx.render("\\hat{x}", .display, 20, null);
    defer out.deinit();
    // Two drawn items: the base 𝑥 and the combining circumflex, each placed
    // by its own origin in the real face.
    var base_x: f32 = 0;
    var mark_x: f32 = 0;
    var seen: usize = 0;
    for (out.items.items) |item| {
        if (item != .text) continue;
        const cp = std.unicode.utf8Decode(item.text.bytes) catch continue;
        if (cp == 0x1D465) base_x = item.text.x;
        if (cp == 0x0302) mark_x = item.text.x;
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);
    // LM Math's own MATH table: the base's 0.329em attachment receives the
    // mark's -0.264em one, so the mark origin sits 0.593em right of the base's
    // at 20pt. The mark's ink centre is NOT the target — the mark has a zero
    // advance and all of its ink left of the origin, so `ink_metrics` clamps
    // `right_edge` to 0 and an ink-centred mark lands 0.041em too far left.
    const base_attach = metrics.fontTopAccentAttachment(&ctx.fm, 0x1D465, .italic) orelse
        return error.TestUnexpectedResult;
    const mark_attach = metrics.fontTopAccentAttachment(&ctx.fm, 0x0302, .italic) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(0.329, base_attach, 0.001);
    try testing.expectApproxEqAbs(-0.264, mark_attach, 0.001);
    try testing.expectApproxEqAbs((base_attach - mark_attach) * 20.0, mark_x - base_x, 0.001);
}

/// Where `x'''` puts its two drawn items: the base's origin and the prime
/// composite's own origin, size and baseline. The composite is one glyph for
/// the whole prime run, so a `x'`-style render is the same two items.
const PrimeRun = struct {
    base_x: f32,
    base_y: f32,
    prime_x: f32,
    prime_y: f32,
    prime_size: f32,
};

fn primeRun(dl: *const draw.DrawList, cp: u21) error{TestUnexpectedResult}!PrimeRun {
    var run: PrimeRun = undefined;
    var seen: usize = 0;
    for (dl.items.items) |item| {
        if (item != .text) continue;
        const t = item.text;
        seen += 1;
        const here = std.unicode.utf8Decode(t.bytes) catch continue;
        if (here == 0x1D465) {
            run.base_x = t.x;
            run.base_y = t.y;
        } else if (here == cp) {
            run.prime_x = t.x;
            run.prime_y = t.y;
            run.prime_size = t.size;
        }
    }
    if (seen != 2) return error.TestUnexpectedResult;
    return run;
}

/// TeX's `\scriptspace`: the fixed 0.5pt a script box carries AFTER its own
/// content. A `x'''` noad is the base's advance, then the prime composite's,
/// then this pad — so reading a composite's advance off a drawn width without
/// naming the pad measures the pad too.
const script_space: f32 = 0.5;

/// The base 𝑥's own advance at `size_pt`, read from the very face layout
/// measures and draws it from: everything the prime adds to the noad sits on
/// top of this, and nothing else does.
fn baseAdvance(ctx: *const Context, size_pt: f32) f32 {
    const face = ctx.fonts.faceForCodepoint(0x1D465, .italic);
    return ctx.fonts.metrics(face, 0x1D465, size_pt).width;
}

test "context: a script-size prime run measures the face's unencoded composite" {
    var ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    // An 8pt base sets its script at 5.6pt, and every prime composite at that
    // size is the face's unencoded alternate on LM Math's 0.3em grid: 0.489 /
    // 0.789 / 1.089 / 1.389em for a run of one to four primes. The triple
    // prime therefore advances 6.0984pt, and the noad it hangs off is the
    // base's own 4.576pt plus that plus TeX's 0.5pt scriptspace pad.
    var out = try ctx.render("x'''", .display, 8, null);
    defer out.deinit();
    const run = try primeRun(&out, 0x2034);
    try testing.expectApproxEqAbs(@as(f32, 5.6), run.prime_size, 0.0001);
    const base = baseAdvance(&ctx, 8);
    // The composite's origin is the base's right edge — 𝑥 carries no italic
    // correction — so this is where the base ends and the prime begins.
    try testing.expectApproxEqAbs(base, run.prime_x - run.base_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 6.0984), out.width - base - script_space, 0.001);
    try testing.expectApproxEqAbs(base + 6.0984 + script_space, out.width, 0.001);
    // The raise is the layout's own script shift — 0.363em of the base, the
    // 2.904pt of an 8pt base — and no glyph swap moves it: the composite's
    // baseline is exactly as far above the base's as it always was.
    try testing.expectApproxEqAbs(@as(f32, 2.904), run.base_y - run.prime_y, 0.001);

    // The whole family switches together, each run at its own composite.
    const family = [_]struct { src: []const u8, cp: u21, width: f32 }{
        .{ .src = "x'", .cp = 0x2032, .width = base + 2.7384 + script_space },
        .{ .src = "x''", .cp = 0x2033, .width = base + 4.4184 + script_space },
        .{ .src = "x'''", .cp = 0x2034, .width = base + 6.0984 + script_space },
        .{ .src = "x''''", .cp = 0x2057, .width = base + 7.7784 + script_space },
    };
    for (family) |c| {
        var one = try ctx.render(c.src, .display, 8, null);
        defer one.deinit();
        const item = try primeRun(&one, c.cp);
        try testing.expectApproxEqAbs(@as(f32, 5.6), item.prime_size, 0.0001);
        try testing.expectApproxEqAbs(c.width, one.width, 0.001);
    }
}

test "context: past the script gate the prime composite measures exactly as before" {
    var ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    // The gate is the drawn size, and a 12pt base is already past it: its
    // 8.4pt script draws the cmap's own 0.711em composite, 5.9724pt. A 20pt
    // and a 60pt base keep the measures they always had — 9.954pt over a
    // 21.894001pt noad and 29.862pt over a 64.682pt one — and 12.06pt is the
    // base whose script (8.442pt) sits closest to the gate from above. The
    // noad is base + composite + \scriptspace at every size, gate or no gate.
    const cases = [_]struct {
        size: f32,
        script: f32,
        advance: f32,
        width: f32,
        raise: f32,
    }{
        .{ .size = 12, .script = 8.4, .advance = 5.9724, .width = 13.336401, .raise = 4.356 },
        .{ .size = 12.06, .script = 8.442, .advance = 6.0024, .width = 13.400682, .raise = 4.3778 },
        .{ .size = 20, .script = 14, .advance = 9.954, .width = 21.894001, .raise = 7.26 },
        .{ .size = 60, .script = 42, .advance = 29.862, .width = 64.682, .raise = 21.78 },
    };
    for (cases) |c| {
        var out = try ctx.render("x'''", .display, c.size, null);
        defer out.deinit();
        const run = try primeRun(&out, 0x2034);
        try testing.expectApproxEqAbs(c.script, run.prime_size, 0.0001);
        const base = baseAdvance(&ctx, c.size);
        try testing.expectApproxEqAbs(base, run.prime_x - run.base_x, 0.001);
        try testing.expectApproxEqAbs(c.advance, out.width - base - script_space, 0.001);
        try testing.expectApproxEqAbs(c.width, out.width, 0.001);
        try testing.expectApproxEqAbs(c.raise, run.base_y - run.prime_y, 0.001);
    }
}
