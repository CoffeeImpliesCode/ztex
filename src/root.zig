//! LaTeX math to draw lists, SVG, and CPU pixel buffers.
//!
//! Import the registered `ztex` module for this facade, or `ztex.atom`,
//! `ztex.parse`, `ztex.layout`, `ztex.font`, `ztex.glyph`, and `ztex.svg`
//! independently. `raster` is available through this facade.
//!
//! Call `render`, serialize with `svg.render`, then release the bytes with
//! the supplied allocator and the draw list with `deinit`. Draw lists borrow
//! the original source, which must remain alive and unchanged until their
//! last use. `Context` reuses embedded faces and caches across calls;
//! `renderPixels` creates a temporary context for one formula.
//!
//! Static parsing and layout do not open files. Embedded font payloads are
//! reached by font-backed rendering, not unconditionally by an import;
//! Zig lazily analyzes declarations. `renderPipeline` is an internal
//! cross-file helper, not a supported consumer entry point.
const std = @import("std");

pub const atom = @import("ztex.atom");
pub const parse = @import("ztex.parse");
pub const layout = @import("ztex.layout");
pub const draw = layout.draw;
pub const svg = @import("ztex.svg");
pub const font = @import("ztex.font");
pub const raster = @import("raster.zig");
pub const PixelBuffer = raster.PixelBuffer;
pub const RasterOptions = raster.Options;
// Imported by path, not re-exported: hosts reach the font-backed context
// through `ztex.Context` below.
const context = @import("context.zig");

pub const Context = context.Context;

/// Failures from source parsing or checked layout; no partial draw list escapes.
pub const RenderError = parse.Error || layout.Error;
/// Rendering plus pixel allocation and glyph decoding failures.
pub const PixelRenderError = RenderError || raster.Error || font.FontError;

/// Shared parse+layout pipeline behind both facades. Internal — not part of
/// the host-facing API: `ztex.render` and `Context.render` are the public
/// entry points, differing only in the metric source (`&metrics.default`
/// vs a Context's `.font` arm).
///
/// `src` remains borrowed by the returned list; parsing scratch is released.
/// Invalid `size_pt` is refused before parsing. Diagnostics change only on
/// a syntax/source-limit failure, not on allocation, option, or font failure.
pub fn renderPipeline(
    gpa: std.mem.Allocator,
    fm: *const layout.metrics.FontMetrics,
    src: []const u8,
    style: layout.Style,
    size_pt: f32,
    err_info: ?*parse.Info,
) RenderError!draw.DrawList {
    if (!std.math.isFinite(size_pt) or size_pt <= 0) return error.InvalidArgument;
    var ast = try parse.parse(gpa, src, err_info);
    defer ast.deinit();
    return layout.render(gpa, &ast, ast.root, fm, style, size_pt);
}

/// Lay out `src` with immutable bundled metric tables, without font I/O.
///
/// `size_pt` must be finite and positive; otherwise `error.InvalidArgument`
/// is returned before parsing or allocating. On success the caller owns a
/// `DrawList`, releases it once with `deinit`, and keeps `src` alive and
/// unchanged until its last use. The list stores `gpa` for cleanup.
///
/// `err_info = null` requests no diagnostic. A syntax/source-limit error fills
/// it; success and all other errors leave it unchanged. Errors release all
/// temporary allocations and return no partial list. Independent calls may
/// run concurrently when their allocator and source are safe to share.
pub fn render(
    gpa: std.mem.Allocator,
    src: []const u8,
    style: layout.Style,
    size_pt: f32,
    err_info: ?*parse.Info,
) RenderError!draw.DrawList {
    return renderPipeline(gpa, &layout.metrics.default, src, style, size_pt, err_info);
}

/// Render one formula with a temporary embedded-font context.
///
/// Repeated callers can reuse `Context.renderPixels` to keep its faces and
/// metric cache. The returned buffer is independent of `src` and the context;
/// the caller keeps `gpa` valid and calls `PixelBuffer.deinit` exactly once.
/// Size and diagnostic rules are those of `render`; raster options and
/// payload limits are those of `raster.rasterize`. No partial buffer escapes.
pub fn renderPixels(
    gpa: std.mem.Allocator,
    src: []const u8,
    style: layout.Style,
    size_pt: f32,
    opts: RasterOptions,
    err_info: ?*parse.Info,
) PixelRenderError!PixelBuffer {
    if (!std.math.isFinite(size_pt) or size_pt <= 0) return error.InvalidArgument;
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

test "facade: invalid font size is refused before parsing or allocating" {
    // A bad size must not enter layout or overwrite a syntax diagnostic.
    const sizes = [_]f32{ 0, -5, std.math.nan(f32), std.math.inf(f32) };
    for (sizes) |size| {
        var info: parse.Info = .{ .kind = .missing_script, .span = .{ .start = 3, .end = 4 } };
        const before = info;
        try testing.expectError(
            error.InvalidArgument,
            render(testing.failing_allocator, "\\frac{", .display, size, &info),
        );
        try testing.expectEqualDeep(before, info);
        try testing.expectError(
            error.InvalidArgument,
            renderPixels(testing.failing_allocator, "x", .display, size, .{}, null),
        );
    }
}
