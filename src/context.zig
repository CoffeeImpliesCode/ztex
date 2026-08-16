//! ztex.context — "initialize once, render many".
//!
//! A `Context` owns a `FontContext` (embedded Latin Modern Math + Roman
//! fallback fonts) and a `FontMetrics` union wired to it: `fm` is the
//! `.font` arm pointing at the context's fonts, so every `render` measures
//! glyphs from the REAL fonts — served from the context's per-(face,
//! codepoint) metric cache, which the first render fills and every later
//! render hits. Create one context, render any number of formulas with it.
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
//! stays available for one-shot use and for tests. Both call the SINGLE
//! shared pipeline `layout.render` with an explicit `FontMetrics` argument
//! (SIM1/H1). The metric source is the closed `FontMetrics` union (SIM2):
//! context.zig builds the `.font` arm — a `FontHook` carrying the
//! `*FontContext` (opaque to the layout module, which cannot import
//! font.zig) plus the font-glyph lookup below — so `init` is one struct
//! literal instead of hand-installed fn-pointer plumbing, and the concrete
//! cast lives in exactly one place.

const std = @import("std");
const atom = @import("ztex.atom");
const font = @import("font.zig");
const parse = @import("ztex.parse");
const layout = @import("ztex.layout");
const metrics = layout.metrics;
const draw = layout.draw;

/// Font-backed glyph lookup, the `.font` arm's hook (see `FontHook` in
/// metrics.zig). Real-font metrics for `cp` in `style` at the 10pt base
/// (em × 10, so the layout's s(v, size_pt) scaling applies — LM is a 10pt
/// design): width = the face's cached hmtx advance, height/depth = the
/// face's OWN nominal hhea extents. Style `.roman` selects the LM Roman
/// regular face (`\text`/`\mathrm`), every other style the LM Math face.
/// The italic correction stays the static row's value (LM Math's MATH table
/// is not parsed yet), so sup/sub placement and the post-op tail keep
/// today's values. Null when the face has no glyph for `cp` — glyph/glyphAt
/// then fall back to the static tables, and finally to glyphEstimate.
fn contextGlyph(ctx: *anyopaque, cp: u21, style: atom.CharStyle) ?metrics.Glyph {
    const f: *font.FontContext = @ptrCast(@alignCast(ctx));
    const face = if (style == .roman) f.romanFace(false) else f.mathFace();
    if (face.glyphIndex(cp) == null) return null;
    const m = f.metrics(face, cp, 10.0);
    var ic: f32 = 0;
    if (metrics.staticGlyph(cp, style)) |e| ic = e.italic_correction;
    return .{
        .width = m.width,
        .height = m.height,
        .depth = m.depth,
        .italic_correction = ic,
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
            .fm = .{ .font = .{ .ctx = fonts, .glyph = &contextGlyph } },
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
    /// fonts via `self.fm`. The returned `DrawList`'s `text` primitives
    /// alias `src`, so `src` must outlive the draw list. `size_pt` is the
    /// base font size in points. On a parse error, `err_info` (when
    /// non-null) is filled with the kind + span.
    ///
    /// Takes `*Context` (not `*const`, C1): the first render fills the font
    /// metric cache (`FontContext.metrics` mutates it while measuring), so
    /// rendering is not a const operation.
    pub fn render(
        self: *Context,
        gpa: std.mem.Allocator,
        src: []const u8,
        size_pt: f32,
        err_info: ?*parse.Info,
    ) !draw.DrawList {
        var ast = try parse.parse(gpa, src, err_info);
        defer ast.deinit();
        return layout.render(gpa, &ast, ast.root, &self.fm, size_pt);
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
    var out = try ctx.render(testing.allocator, "x", 20, null);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.len());
    const t = out.items.items[0].text;
    try testing.expectEqualStrings("𝑥", t.bytes);
    try testing.expectEqual(@as(f32, 20), t.size);
    try testing.expectApproxEqAbs(@as(f32, 11.44), out.width, 0.001);
    // a second render reuses the same context (and its font metric cache)
    var out2 = try ctx.render(testing.allocator, "x", 20, null);
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
    var out = try ctx.render(testing.allocator, "\\triangleright", 20, null);
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
