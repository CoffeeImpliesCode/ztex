//! ztex — LaTeX math parsing + layout → SVG-style draw list.
//!
//! Facade over independently usable modules:
//! - `ztex.parse` — LaTeX source → superflat atom tree
//! - `ztex.layout` — atom tree + font metrics → box tree → draw list
//! - `ztex.svg` — draw list → SVG document
//!
//! plus two back ends that turn a draw list into pixels or markup:
//! `ztex.svg.render` and `raster.rasterize` (re-exported below; the latter
//! always needs a `Context`, because it resolves every glyph through the
//! real faces).
//!
//! Module weight: importing `ztex` pulls 1,193,544 bytes (1.14 MiB) of
//! embedded Latin Modern faces (`font.zig` → `src/fonts/`) — LM Math plus
//! LM Roman regular, italic, bold and bold italic — because the `Context`
//! facade measures from them and the rasterizer draws from them.
//! `ztex.parse` and `ztex.layout` do NOT depend on `font.zig` — they reach
//! real fonts through an opaque `metrics.FontHook`, so a host that only
//! wants the static tables can import those two modules and never link the
//! font bytes. The static path answers from compiled-in numbers instead:
//! the Computer Modern rows, plus rows generated from those SAME embedded
//! faces for the text styles the CM tables do not describe and sparse ink
//! edges for all five, so a glyph is framed by the outline it is drawn
//! from.
const std = @import("std");

pub const atom = @import("ztex.atom");
pub const parse = @import("ztex.parse");
pub const layout = @import("ztex.layout");
pub const draw = layout.draw;
pub const svg = @import("ztex.svg");
pub const font = @import("font.zig");
pub const raster = @import("raster.zig");
pub const PixelBuffer = raster.PixelBuffer;
pub const RasterOptions = raster.Options;
// Imported by path, not re-exported: hosts reach the font-backed context
// through `ztex.Context` below.
const context = @import("context.zig");

/// Font-backed rendering context: owns a FontContext (five embedded Latin
/// Modern faces plus the per-(face, codepoint) metric cache) and a
/// FontMetrics wired to it — "initialize once, render many" (see
/// context.zig). Its `.font` arm also borrows LM Math's decoded MATH
/// constants, valid for the life of the context. Rasterizing a draw list
/// needs one: `raster.rasterize` resolves every run's face through it.
pub const Context = context.Context;
/// Shared parse+layout pipeline behind both facades. Internal — not part of
/// the host-facing API: `ztex.render` and `Context.render` are the public
/// entry points, differing only in the metric source (`&metrics.default`
/// vs a Context's `.font` arm).
///
/// The returned `DrawList`'s `text` primitives alias `src`, so `src` must
/// outlive the draw list. `size_pt` is the base font size in points. On a
/// parse error, `err_info` (when non-null) is filled with the kind + span.
/// Errors propagate unmapped: `layout.render`'s closed set (OutOfMemory,
/// InvalidAst) is a subset of this facade's typed return set, so callers
/// match the typed set exhaustively instead of re-enumerating errors.
pub fn renderPipeline(
    gpa: std.mem.Allocator,
    fm: *const layout.metrics.FontMetrics,
    src: []const u8,
    style: layout.Style,
    size_pt: f32,
    err_info: ?*parse.Info,
) (parse.Error || error{InvalidAst})!draw.DrawList {
    var ast = try parse.parse(gpa, src, err_info);
    defer ast.deinit();
    // layout.render fails only with OutOfMemory/InvalidAst, both members of
    // the typed set below, so they propagate unmapped — callers match the
    // closed facade set exhaustively instead of re-enumerating errors.
    return layout.render(gpa, &ast, ast.root, fm, style, size_pt);
}

/// Full pipeline: LaTeX source → draw list (SVG-style primitives),
/// measured from the bundled static tables (`layout.metrics.default`).
/// Those tables are compiled-in numbers — the Computer Modern rows, plus
/// rows and ink edges generated from the same embedded faces — so this
/// entry point touches no font file and holds no mutable state, and is
/// shareable across threads. `Context.render` is the same pipeline measured
/// from the real fonts; both share the body in `renderPipeline` above.
/// Details on the returned draw list's lifetime and `err_info` are
/// documented there.
pub fn render(
    gpa: std.mem.Allocator,
    src: []const u8,
    style: layout.Style,
    size_pt: f32,
    err_info: ?*parse.Info,
) (parse.Error || error{InvalidAst})!draw.DrawList {
    return renderPipeline(gpa, &layout.metrics.default, src, style, size_pt, err_info);
}

/// One-shot rasterization: initializes a temporary Context — the
/// rasterizer needs real faces, so this is not a static-table path — and
/// rasterizes the formula to a PixelBuffer. For batch rendering, prefer
/// initializing a persistent `ztex.Context` and calling `ctx.renderPixels`,
/// so the faces and the metric cache are built once.
pub fn renderPixels(
    gpa: std.mem.Allocator,
    src: []const u8,
    style: layout.Style,
    size_pt: f32,
    opts: RasterOptions,
    err_info: ?*parse.Info,
) !PixelBuffer {
    var ctx = try Context.init(gpa);
    defer ctx.deinit();
    return ctx.renderPixels(src, style, size_pt, opts, err_info);
}
test {
    std.testing.refAllDecls(@This());
}

// ── tests ────────────────

const testing = std.testing;

test "facade: render produces drawables with provenance" {
    const src = "\\frac{1}{2}+x";
    var out = try render(testing.allocator, src, .display, 20, null);
    defer out.deinit();
    try testing.expect(out.len() > 0);
    // the fraction bar is a rect; plus the char/frac text primitives
    var saw_rect = false;
    var saw_text = false;
    for (out.items.items) |d| {
        switch (d) {
            .rect => saw_rect = true,
            .text => saw_text = true,
            .line => {},
        }
    }
    try testing.expect(saw_rect); // fraction rule
    try testing.expect(saw_text); // glyphs
    try testing.expect(out.width > 0);
}

test "facade: frac renders a rect rule and glyphs" {
    const src = "\\frac{1}{2}";
    var out = try render(testing.allocator, src, .display, 10, null);
    defer out.deinit();
    var saw_rect = false;
    var saw_text = false;
    for (out.items.items) |d| {
        switch (d) {
            .rect => saw_rect = true,
            .text => saw_text = true,
            .line => {},
        }
    }
    try testing.expect(saw_rect); // the fraction bar
    try testing.expect(saw_text); // numerator and denominator digits
}

test "facade: text renders glyphs with source spans" {
    const src = "\\text{hi}";
    var out = try render(testing.allocator, src, .display, 10, null);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 2), out.len());
    const t0 = out.items.items[0].text;
    try testing.expectEqualStrings("h", t0.bytes);
    try testing.expectEqual(@as(u32, 6), t0.src_start);
    try testing.expectEqual(@as(u32, 7), t0.src_end);
    const t1 = out.items.items[1].text;
    try testing.expectEqualStrings("i", t1.bytes);
    try testing.expectEqual(@as(u32, 7), t1.src_start);
    try testing.expectEqual(@as(u32, 8), t1.src_end);
}

test "facade: renderPixels produces non-empty RGBA pixel buffer" {
    var pix = try renderPixels(testing.allocator, "x^2 + 1", .display, 20.0, .{}, null);
    defer pix.deinit();
    try testing.expect(pix.width > 0);
    try testing.expect(pix.height > 0);
    try testing.expectEqual(@as(usize, pix.width * pix.height * 4), pix.pixels.len);

    // Check that some ink was actually drawn (alpha > 0)
    var has_ink = false;
    var i: usize = 0;
    while (i < pix.pixels.len) : (i += 4) {
        if (pix.pixels[i + 3] > 0) {
            has_ink = true;
            break;
        }
    }
    try testing.expect(has_ink);
}

test "facade: renderPixels produces alpha8 mask" {
    var pix = try renderPixels(testing.allocator, "\\frac{a}{b}", .display, 20.0, .{ .format = .alpha8 }, null);
    defer pix.deinit();
    try testing.expect(pix.width > 0);
    try testing.expect(pix.height > 0);
    try testing.expectEqual(@as(usize, pix.width * pix.height), pix.pixels.len);

    var has_ink = false;
    for (pix.pixels) |a| {
        if (a > 0) {
            has_ink = true;
            break;
        }
    }
    try testing.expect(has_ink);
}

test "facade: the math style argument changes the layout" {
    // A host rendering math inline in prose must be able to ask for text
    // style; if the parameter were ignored, every inline fraction would come
    // out display-sized and every \sum would stack its limits.
    const frac = "\\frac{1}{2}";
    var disp = try render(testing.allocator, frac, .display, 20, null);
    defer disp.deinit();
    var text = try render(testing.allocator, frac, .text, 20, null);
    defer text.deinit();
    try testing.expect(text.height < disp.height);
    try testing.expect(text.width < disp.width);

    // \sum is the sharper case: display sets the limits above and below,
    // text moves them beside the operator, so the formula gets WIDER and
    // SHORTER. Equal dimensions would mean the style never reached layout.
    const sum = "\\sum_{i=1}^{n} i";
    var sd = try render(testing.allocator, sum, .display, 20, null);
    defer sd.deinit();
    var st = try render(testing.allocator, sum, .text, 20, null);
    defer st.deinit();
    try testing.expect(st.width > sd.width);
    try testing.expect(st.height < sd.height);
}
