//! CPU coverage rasterizer for point-coordinate math draw lists.
//!
//! Reach this module as `@import("ztex").raster`. Call `rasterize` with a
//! live context and draw list, use the result, then call `PixelBuffer.deinit`.
//! Resolution, scale, colors, and RGBA/alpha-mask storage are caller choices.
//! Rendering performs no font discovery or file I/O; `PixelBuffer.writePnm`
//! uses the caller's explicit file and I/O capability.
//!
//! FONT-BACKED ONLY. Unlike `ztex.render`, which measures from static tables,
//! `rasterize` takes a `context.Context` and resolves every run through the
//! face that codepoint actually draws from
//! (`FontContext.faceForCodepoint` — the style's own face when it carries
//! the glyph, the math face when only that one does), then decodes that
//! face's outline — including the OpenType MATH form the layout boxed: the
//! size variant a display big operator, a stretchy `√` or a `\left`/`\right`
//! fence needs, and, for a fence taller than its whole ladder, the whole
//! glyph ASSEMBLY stacked to the height TeX asked for. Which glyph that is
//! comes from `ztex.glyph`, the same resolver `svg.zig` draws with. A face
//! with no ladder for the request degrades to the unstretched base glyph
//! rather than failing: the raster path has no per-glyph error channel, and
//! discarding every other formula on the page because one font lacks a
//! table would be worse than a short fence.
//!
//! ONE LOGICAL GLYPH IS ONE PIECE OF INK. An assembly's parts overlap by the
//! font's own MinConnectorOverlap, so filling each part on its own applies
//! the ink alpha twice in every join — a translucent `\left(` came out with
//! dark seams down its length, where `svg.zig`'s single compound path put one
//! fill. The parts are therefore cut into disjoint bands along the axis the
//! stack grows on, so no pixel is ever swept by two of them: each is composited
//! once, and its antialiased edges stay soft. See `GlyphItem.assignBands`.

const std = @import("std");
const context = @import("context.zig");
const coverage = @import("coverage.zig");
const layout = @import("ztex.layout");
const draw = layout.draw;
const atom = @import("ztex.atom");
const font = @import("ztex.font");
const glyph = @import("ztex.glyph");

/// Allocation, option, coordinate, size-limit, and font-decoding failures.
pub const Error = error{
    OutOfMemory,
    InvalidArgument,
    OutputTooLarge,
    NonFiniteCoordinate,
} || font.FontError;

/// Pixel storage format; both variants preserve ink alpha.
pub const Format = enum {
    /// 32-bit RGBA (R, G, B, A in byte order)
    rgba32,
    /// 8-bit coverage mask (1 byte per pixel: 0 = transparent, 255 = fully
    /// inked). A byte is the glyph coverage times the ALPHA byte of the ink
    /// — `Options.fg`'s for ordinary ink, the scope color's inside `\color` /
    /// `\textcolor` — so `fg`'s red, green and blue never reach a mask, and
    /// the canvas is always transparent: `Options.bg` is ignored entirely.
    alpha8,
};

/// Frame and paint settings for point-coordinate draw lists.
/// Defaults target a screen at 96 DPI with opaque black ink and no background.
pub const Options = struct {
    /// Target resolution in DPI (dots per inch). Standard web/screen is 96.0;
    /// print is 300.0+. Must be a positive finite number, or
    /// `error.InvalidArgument`: every pixel length `rasterize` derives is a
    /// multiple of the pt → px scale, so a dpi that is not one has no frame.
    dpi: f32 = 96.0,
    /// Additional uniform scale factor. Positive and finite, as `dpi`.
    scale: f32 = 1.0,
    /// Padding around the content in pixels, on both axes. A margin whose
    /// framed extent or row stride no 32-bit size can describe is
    /// `error.OutputTooLarge`, refused before the pixel block is requested.
    /// Glyph geometry excludes this margin; only output indexing adds it.
    padding: u32 = 0,
    /// Largest accepted pixel payload. The default imposes no cap beyond
    /// `usize`; lower it to bound output memory. Exceeding it returns
    /// `error.OutputTooLarge` before pixel allocation. It does not bound
    /// font or scanline scratch allocations.
    max_bytes: usize = std.math.maxInt(usize),
    /// RGBA preserves color by default; choose `alpha8` for a coverage mask.
    format: Format = .rgba32,
    /// Ink color for primitives no color scope covers. Default is black
    /// (#000000FF). A primitive an explicit color scope covers paints its own
    /// color instead — the SCOPE decides, not the value, so an explicit black
    /// or a transparent {0,0,0,0} still beats this one. In `.alpha8` this
    /// field still matters, but only through its alpha byte, which is what
    /// scales the mask (see `Format.alpha8`).
    fg: draw.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    /// Background color, filled before anything is drawn. `null` = fully
    /// transparent. `.alpha8` ignores it: that canvas is always transparent.
    bg: ?draw.Color = null,
};

/// Independently owned, row-major pixels; no source or context borrow survives.
/// Keep the allocator valid and unchanged through exactly one `deinit`.
/// Copying shares storage, not ownership. Read-only access may be shared;
/// mutation or disposal must not overlap another use.
pub const PixelBuffer = struct {
    /// Borrowed allocator used for `pixels`; must retain its original identity.
    gpa: std.mem.Allocator,
    /// Owned payload; length is `height * stride`. RGBA channels use straight alpha.
    pixels: []u8,
    /// Pixel dimensions; indices satisfy `x < width` and `y < height`.
    width: u32,
    height: u32,
    /// Bytes per row, top-down: four per RGBA pixel or one per alpha pixel.
    /// Row offsets must use `usize`, not `u32`: a native payload may exceed 4 GiB.
    stride: u32,
    /// Encoding of every pixel in `pixels`; changing it invalidates the layout.
    format: Format,

    /// Releases the pixel storage, not the allocator. The value and all aliases
    /// are invalid afterward; repeat disposal, including through a copy, is invalid.
    pub fn deinit(self: *PixelBuffer) void {
        self.gpa.free(self.pixels);
        self.* = undefined;
    }

    /// Write P6 RGB composited over white, or P5 coverage without a matte.
    ///
    /// Borrows `io` and `file` for this blocking call; neither is closed or
    /// retained. A write error, including `error.Canceled`, may leave a prefix
    /// in the file. The buffer is unchanged. This adds no image allocation;
    /// the I/O provider controls its own temporary storage.
    pub fn writePnm(
        self: *const PixelBuffer,
        io: std.Io,
        file: std.Io.File,
    ) std.Io.File.Writer.Error!void {
        var hdr_buf: [64]u8 = undefined;
        switch (self.format) {
            .rgba32 => {
                const hdr = std.fmt.bufPrint(&hdr_buf, "P6\n{d} {d}\n255\n", .{
                    self.width, self.height,
                }) catch unreachable;
                try file.writeStreamingAll(io, hdr);
                var row_buf: [4096 * 3]u8 = undefined;
                // usize offsets: the 32-bit frame bounds ONE row, so a
                // payload past 4 GiB is still a legal buffer — and a row
                // offset counted in u32 wraps halfway down one.
                const stride: usize = self.stride;
                for (0..self.height) |y| {
                    const at = @as(usize, y) * stride;
                    const row = self.pixels[at .. at + stride];
                    var x: usize = 0;
                    while (x < self.width) {
                        const chunk: usize = @min(self.width - x, row_buf.len / 3);
                        for (0..chunk) |i| {
                            const src_px = row[(x + i) * 4 ..][0..4];
                            const dst = row_buf[i * 3 ..][0..3];
                            const alpha: u16 = src_px[3];
                            if (alpha == 255) {
                                @memcpy(dst, src_px[0..3]);
                            } else if (alpha == 0) {
                                @memset(dst, 255);
                            } else {
                                const matte: u16 = 255 * (255 - alpha) + 127;
                                for (0..3) |channel| {
                                    dst[channel] = @intCast(
                                        (@as(u16, src_px[channel]) * alpha + matte) / 255,
                                    );
                                }
                            }
                        }
                        try file.writeStreamingAll(io, row_buf[0 .. chunk * 3]);
                        x += chunk;
                    }
                }
            },
            .alpha8 => {
                const hdr = std.fmt.bufPrint(&hdr_buf, "P5\n{d} {d}\n255\n", .{
                    self.width, self.height,
                }) catch unreachable;
                try file.writeStreamingAll(io, hdr);
                try file.writeStreamingAll(io, self.pixels);
            },
        }
    }
};

const testing = std.testing;

test "PixelBuffer.writePnm white-mattes straight alpha across rows and chunks" {
    const width: u32 = 4097;
    const height: u32 = 2;
    const rgba = [_][4]u8{
        .{ 0, 45, 155, 0 },
        .{ 0, 0, 0, 128 },
        .{ 255, 0, 0, 128 },
        .{ 17, 63, 250, 255 },
    };
    const rgb = [_][3]u8{
        .{ 255, 255, 255 },
        .{ 127, 127, 127 },
        .{ 255, 127, 127 },
        .{ 17, 63, 250 },
    };
    const count: usize = width * height;
    var pixel_buffer: PixelBuffer = .{
        .gpa = testing.allocator,
        .pixels = try testing.allocator.alloc(u8, count * 4),
        .width = width,
        .height = height,
        .stride = width * 4,
        .format = .rgba32,
    };
    defer pixel_buffer.deinit();
    const header = "P6\n4097 2\n255\n";
    const expected = try testing.allocator.alloc(u8, header.len + count * 3);
    defer testing.allocator.free(expected);
    @memcpy(expected[0..header.len], header);
    for (0..count) |i| {
        @memcpy(pixel_buffer.pixels[i * 4 ..][0..4], &rgba[i % rgba.len]);
        @memcpy(expected[header.len + i * 3 ..][0..3], &rgb[i % rgb.len]);
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const file = try tmp.dir.createFile(testing.io, "chunked.ppm", .{});
        defer file.close(testing.io);
        try pixel_buffer.writePnm(testing.io, file);
    }
    const actual = try tmp.dir.readFileAlloc(
        testing.io,
        "chunked.ppm",
        testing.allocator,
        .limited(expected.len + 1),
    );
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
}

/// Where the draw list's ink origin (x = 0, y = the ink top) lands in the
/// buffer, in points: the negative of the ink minimum, i.e. the same shift
/// svg.zig applies to its viewBox origin. Applied before the pt→px scale and
/// the pixel padding, so the two back ends frame the same content.
const Origin = struct {
    x: f32,
    y: f32,
};

/// Rasterize a draw list using the font context's embedded/cached faces, into a
/// `PixelBuffer` the caller owns. The buffer is framed from `dl.bounds()` —
/// the INK bounds, the same source svg.zig cuts its viewBox from — with
/// `padding` added in PIXELS on both axes and one extra pixel column and row
/// of bearing past the ink so edge antialiasing is never clamped at the last
/// row. Pt → px is `(dpi / 72) * scale`.
///
/// `ctx` is required, not optional: every run and every primitive is painted
/// with a face resolved from it (see the module header). It fails on
/// `error.InvalidArgument` for a `dpi`/`scale` that is not a positive finite
/// number, on `error.NonFiniteCoordinate` for a draw list with a non-finite
/// ink extent — the same coordinate error the SVG serializer reports for it —
/// and on `error.OutputTooLarge` for dimensions or stride beyond `u32`,
/// a payload beyond `usize`, or a payload above `opts.max_bytes`, before
/// pixel allocation. A native payload is not otherwise limited to 32 bits.
/// Missing glyphs paint nothing; malformed glyph outlines return font errors.
///
/// The caller owns the returned buffer and releases it with `deinit` once.
/// `ctx`, `dl`, their source bytes, and borrowed faces must remain valid for
/// the call only. On error all pixel and scanline allocations are released
/// and no partial buffer escapes; the context's existing caches remain live.
/// Serialize access to a shared context. This CPU operation performs no I/O
/// and has no cancellation points.
pub fn rasterize(
    gpa: std.mem.Allocator,
    ctx: *context.Context,
    dl: *const draw.DrawList,
    opts: Options,
) Error!PixelBuffer {
    // Every length below is a multiple of the pt → px scale, so a dpi or
    // scale that is not a positive finite number — or a product that
    // overflows to infinity — has no pixel size to compute, and rounding one
    // out of it anyway traps in `@intFromFloat`.
    if (!std.math.isFinite(opts.dpi) or opts.dpi <= 0) return error.InvalidArgument;
    if (!std.math.isFinite(opts.scale) or opts.scale <= 0) return error.InvalidArgument;
    const pt_to_px = (opts.dpi / 72.0) * opts.scale;
    if (!std.math.isFinite(pt_to_px) or pt_to_px <= 0) return error.InvalidArgument;
    const pad = opts.padding;

    // Same basis as svg.zig's viewBox: the INK bounds, so a bitmap and an SVG
    // of one draw list cover the same content. `padding` and the 1px bearing
    // below stay in pixels.
    const ink = dl.bounds();
    // A draw list carrying a non-finite extent has no frame to cut: report
    // the coordinate, as the SVG serializer does for the very same list,
    // rather than turning a NaN width into a pixel count.
    if (!std.math.isFinite(ink.width) or
        !std.math.isFinite(ink.height) or
        !std.math.isFinite(ink.depth)) return error.NonFiniteCoordinate;
    const origin = Origin{ .x = -ink.min_x, .y = -ink.min_y };
    const content_w = @max(1.0, ink.width * pt_to_px);
    const content_h = @max(1.0, (ink.height + ink.depth) * pt_to_px);
    // The content plus the caller's margin on both axes plus the 1px bearing
    // past the ink that keeps subpixel antialiasing off row 0.
    const width = try framedExtent(content_w, pad);
    const height = try framedExtent(content_h, pad);
    const bytes_per_pixel: u32 = if (opts.format == .rgba32) 4 else 1;
    const stride = std.math.mul(u32, width, bytes_per_pixel) catch return error.OutputTooLarge;
    const total_bytes = std.math.mul(usize, @as(usize, height), @as(usize, stride)) catch
        return error.OutputTooLarge;
    if (total_bytes > opts.max_bytes) return error.OutputTooLarge;

    const pixels = try gpa.alloc(u8, total_bytes);
    errdefer gpa.free(pixels);

    // Initialize background
    switch (opts.format) {
        .rgba32 => {
            if (opts.bg) |bg| {
                var i: usize = 0;
                while (i < total_bytes) : (i += 4) {
                    pixels[i] = bg.r;
                    pixels[i + 1] = bg.g;
                    pixels[i + 2] = bg.b;
                    pixels[i + 3] = bg.a;
                }
            } else {
                @memset(pixels, 0);
            }
        },
        .alpha8 => {
            @memset(pixels, 0);
        },
    }

    const pad_f: f32 = @floatFromInt(pad);

    // One scratch for the whole frame: the per-item buffers below are
    // reused by every item, and the decoded outline of a glyph is decoded
    // once for the frame instead of once per placement.
    var scratch: GlyphScratch = .{ .gpa = gpa };
    defer scratch.deinit();

    for (dl.items.items) |d| {
        switch (d) {
            .text => |t| {
                try drawGlyph(
                    &scratch,
                    ctx,
                    pixels,
                    width,
                    height,
                    stride,
                    opts.format,
                    inkOf(opts, t.color, t.color_override),
                    t,
                    pt_to_px,
                    pad,
                    origin,
                );
            },
            .rect => |r| {
                const x0 = pad_f + (r.x + origin.x) * pt_to_px;
                const x1 = pad_f + (r.x + r.w + origin.x) * pt_to_px;
                const y0 = pad_f + (r.y + origin.y) * pt_to_px;
                const y1 = pad_f + (r.y + r.h + origin.y) * pt_to_px;
                fillRect(
                    pixels,
                    width,
                    height,
                    stride,
                    opts.format,
                    inkOf(opts, r.color, r.color_override),
                    x0,
                    x1,
                    y0,
                    y1,
                );
            },
            .line => |l| {
                // A stroke, not a box: the band's half width scales with
                // the resolution like every other length here, and the band
                // follows the segment (see `strokeSegment`). Filling the
                // endpoints' bounding box instead would paint the whole
                // wedge between them for any diagonal — a hat's apex would
                // come out as a filled triangle.
                const half = 0.5 * l.width * pt_to_px;
                const x0 = pad_f + (l.x0 + origin.x) * pt_to_px;
                const x1 = pad_f + (l.x1 + origin.x) * pt_to_px;
                const y0 = pad_f + (l.y0 + origin.y) * pt_to_px;
                const y1 = pad_f + (l.y1 + origin.y) * pt_to_px;
                strokeSegment(
                    pixels,
                    width,
                    height,
                    stride,
                    opts.format,
                    inkOf(opts, l.color, l.color_override),
                    x0,
                    y0,
                    x1,
                    y1,
                    half,
                );
            },
        }
    }

    return .{
        .gpa = gpa,
        .pixels = pixels,
        .width = width,
        .height = height,
        .stride = stride,
        .format = opts.format,
    };
}

/// The pixel extent of one framed axis: `content_px` rounded up, plus
/// `2 * pad + 1` for the caller's margin and the one-pixel bearing past the
/// ink. Every step is measured in the widest type and checked, because the
/// frame is a 32-bit one: an extent it cannot describe is a reported
/// `error.OutputTooLarge` instead of a wrapped, clamped or truncated picture
/// smaller than the caller asked for.
fn framedExtent(content_px: f32, pad: u32) error{OutputTooLarge}!u32 {
    // f64, because f32 cannot represent 2^32 - 1: compared in f32 that
    // bound rounds UP to 2^32, and the cast below would trap on it.
    const ceiled: f64 = @ceil(@as(f64, content_px));
    if (!std.math.isFinite(ceiled) or
        ceiled > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.OutputTooLarge;
    const content_u32: u32 = @intFromFloat(ceiled);
    const margin = std.math.mul(u32, pad, 2) catch return error.OutputTooLarge;
    const framed = std.math.add(u32, content_u32, margin) catch return error.OutputTooLarge;
    return std.math.add(u32, framed, 1) catch return error.OutputTooLarge;
}

// ── scoped colors ─────────────────────────

/// The RGBA quadruple at (x, y), y counted from the top as the rgba32
/// payload is stored.
fn rgbaAt(buf: PixelBuffer, x: usize, y: usize) [4]u8 {
    const i = y * @as(usize, buf.stride) + x * 4;
    return .{ buf.pixels[i], buf.pixels[i + 1], buf.pixels[i + 2], buf.pixels[i + 3] };
}

/// One 4 x 4 pt rule whose ink starts at the origin, painted in `c`. At
/// 72 dpi that is pixels (0, 0)…(3, 3) exactly; pixel 4 is the 1px bearing
/// `rasterize` leaves past the ink, so "painted" and "left alone" are
/// distinguishable without any coverage guessing.
fn ruleList(gpa: std.mem.Allocator, c: draw.Color, color_override: bool) !draw.DrawList {
    var dl = draw.DrawList.init(gpa);
    errdefer dl.deinit();
    try dl.add(.{ .rect = .{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .color = c,
        .color_override = color_override,
        .src_start = 0,
        .src_end = 1,
    } });
    dl.accInk(0, 0, 4, 4);
    return dl;
}

test "rasterize: an explicit black scope beats a white host foreground" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    // Both draw lists carry the same black primitive; only the scope flag
    // differs. Deciding by VALUE ("this color is black, so use the host
    // foreground instead") would paint the scoped rule white.
    var scoped = try ruleList(testing.allocator, .{ .r = 0, .g = 0, .b = 0 }, true);
    defer scoped.deinit();
    var plain = try ruleList(testing.allocator, .{ .r = 0, .g = 0, .b = 0 }, false);
    defer plain.deinit();
    const opts: Options = .{
        .dpi = 72,
        .format = .rgba32,
        .fg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    };
    var buf = try rasterize(testing.allocator, &ctx, &scoped, opts);
    defer buf.deinit();
    var host = try rasterize(testing.allocator, &ctx, &plain, opts);
    defer host.deinit();

    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, rgbaAt(buf, 1, 1));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, rgbaAt(host, 1, 1));
    // The untouched bearing proves both really painted where they claim:
    // alpha 255 inside the rule, alpha 0 outside it.
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(buf, 4, 4));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(host, 4, 4));
}

test "rasterize: a transparent scope paints nothing, in either pixel format" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    // {0,0,0,0} means "draw nothing", not "no color given": substituting
    // the host foreground here would put ink where the formula asked for
    // none.
    var dl = try ruleList(testing.allocator, .{ .r = 0, .g = 0, .b = 0, .a = 0 }, true);
    defer dl.deinit();
    var rgba = try rasterize(testing.allocator, &ctx, &dl, .{
        .dpi = 72,
        .format = .rgba32,
        .fg = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    });
    defer rgba.deinit();
    for (0..@as(usize, rgba.height)) |y| {
        for (0..@as(usize, rgba.width)) |x| {
            try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, rgbaAt(rgba, x, y));
        }
    }
    var mask = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 72, .format = .alpha8 });
    defer mask.deinit();
    try testing.expectEqual(@as(usize, 0), inkedPixels(mask));

    // The same scope over a glyph: the very same glyph drawn with no scope
    // puts down ink, the scoped one puts down none.
    var ghost = item("x", .italic);
    ghost.color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    ghost.color_override = true;
    var painted = try rasterOne(testing.allocator, &ctx, item("x", .italic));
    defer painted.deinit();
    var faded = try rasterOne(testing.allocator, &ctx, ghost);
    defer faded.deinit();
    try testing.expect(inkedPixels(painted) > 0);
    try testing.expectEqual(@as(usize, 0), inkedPixels(faded));
}

test "rasterize: alpha8 and rgba32 agree on a scoped alpha" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    // Half-transparent ink: the mask strength and the stored alpha must be
    // the same number, or a PGM and a PPM of one colored formula disagree
    // about how much of it there is.
    const half: draw.Color = .{ .r = 12, .g = 34, .b = 56, .a = 128 };
    var dl = try ruleList(testing.allocator, half, true);
    defer dl.deinit();
    var mask = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 72, .format = .alpha8 });
    defer mask.deinit();
    var rgba = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 72, .format = .rgba32 });
    defer rgba.deinit();
    const strength = mask.pixels[0];
    try testing.expectEqual(@as(u8, 128), strength);
    try testing.expectEqual([4]u8{ 12, 34, 56, strength }, rgbaAt(rgba, 1, 1));
    // ... and the bearing is still empty in both.
    try testing.expectEqual(@as(u8, 0), mask.pixels[mask.pixels.len - 1]);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(rgba, 4, 4));
}

// A wide accent's apex and a tilde's wave are DIAGONAL segments, and a
// diagonal has to paint as a band of its stroke width, not as the box
// between its endpoints: the box of a 45° apex is a filled triangle, which
// is the difference between a hat and a wedge. The endpoints here are the
// shape's own corners (the ink runs the whole 0…10 square), so the frame is
// exactly what was laid out and nothing is clipped.
test "rasterize: a diagonal line paints its stroke band, not its bounding box" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    try dl.add(.{ .line = .{
        .x0 = 1,
        .y0 = 1,
        .x1 = 9,
        .y1 = 9,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .color_override = true,
        .width = 2,
        .src_start = 0,
        .src_end = 6,
    } });
    dl.accInk(0, 0, 10, 10);
    var buf = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 72, .format = .alpha8 });
    defer buf.deinit();
    const at = struct {
        fn f(b: PixelBuffer, x: u32, y: u32) u8 {
            return b.pixels[y * b.stride + x];
        }
    }.f;
    // The centre of the 45° line: fully covered.
    try testing.expectEqual(@as(u8, 255), at(buf, 5, 5));
    // Inside the endpoints' bounding box, but ~5.7px off the line: empty.
    // A box fill would have inked it.
    try testing.expectEqual(@as(u8, 0), at(buf, 1, 9));
    try testing.expectEqual(@as(u8, 0), at(buf, 9, 1));
    // Butt caps match the filled SVG band's endpoint planes:
    // the pixel past the endpoint's plane is outside the band, so nothing is
    // painted there and the ink stops exactly where the box extents say.
    try testing.expectEqual(@as(u8, 0), at(buf, 9, 9));
    // Just inside the endpoint, on the line itself: covered.
    try testing.expect(at(buf, 8, 8) > 0);
    // A band, not a wedge: well under the 8 x 8 bounding box, and thick
    // enough to be a stroke rather than a hairline.
    const inked = inkedPixels(buf);
    try testing.expect(inked > 8);
    try testing.expect(inked < 8 * 8);
}

test "rasterize: the buffer is sized from the ink bounds, not the box bounds" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    // A 10 x 43 rule whose ink spans x ∈ [1.2, 11.2], y ∈ [−26, 17]: the
    // reference point (0, 0) is NOT the ink origin, and the box bounds
    // (zeros) under-bind the drawn ink.
    try dl.add(.{ .rect = .{
        .x = 1.2,
        .y = -26,
        .w = 10,
        .h = 43,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 1,
    } });
    dl.accInk(1.2, -26, 11.2, 17);
    var buf = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 72, .format = .alpha8 });
    defer buf.deinit();
    // 1 px per pt at 72 dpi, plus the 1px bearing headroom past the ink
    try testing.expectEqual(@as(u32, 11), buf.width);
    try testing.expectEqual(@as(u32, 44), buf.height);
    // The rule covers the ink box exactly: the ink origin shifted it into
    // the top-left corner, and only the 1px headroom past the ink stays
    // empty. A buffer sized from the box bounds would be 1x1, and one that
    // ignored the ink origin would shift the rule off the left edge.
    var inked: usize = 0;
    for (0..buf.height) |y| {
        for (0..buf.width) |x| {
            const on = buf.pixels[y * buf.stride + x] != 0;
            try testing.expectEqual(y != buf.height - 1 and x != buf.width - 1, on);
            if (on) inked += 1;
        }
    }
    try testing.expectEqual(@as(usize, 43 * 10), inked);
}

// The margin is a PIXEL count, and it moves the content by exactly that
// many pixels. This also pins the one-pixel bearing: the ink starts at
// `pad`, not at `pad + 1`.
test "rasterize: padding shifts the content by exactly pad pixels" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var dl = try ruleList(testing.allocator, .{ .r = 0, .g = 0, .b = 0 }, false);
    defer dl.deinit();
    const pad: u32 = 3;
    var buf = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 72, .padding = pad });
    defer buf.deinit();
    // 4pt of ink at 1px per pt, the margin on both sides of it, and the
    // one-pixel bearing past that.
    try testing.expectEqual(@as(u32, 11), buf.width);
    try testing.expectEqual(@as(u32, 11), buf.height);
    try testing.expectEqual(@as(u32, 44), buf.stride);
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, rgbaAt(buf, 3, 3));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(buf, 2, 2));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(buf, 7, 7));
}

// A margin moves the picture by exactly that many pixels, and no painted pixel
// may fall outside that move. `f` at 60pt/720dpi is the case that broke it: the
// ink the rasterizer paints reached a hair above the box the frame is cut from
// (the frame puts its one-pixel bearing on the far side only), so at zero margin
// that ink was clipped and at a 12px margin the very same ink turned up INSIDE
// the margin ring — a margined PGM that was not the unmargined one shifted by
// its margin, which is exactly what a caller comparing the two sees.
test "rasterize: a margin shifts the picture and paints nothing outside it" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var dl = try ctx.render("f", .display, 60, null);
    defer dl.deinit();

    var zero = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 720, .format = .alpha8 });
    defer zero.deinit();
    const pad: u32 = 12;
    var margined = try rasterize(testing.allocator, &ctx, &dl, .{
        .dpi = 720,
        .padding = pad,
        .format = .alpha8,
    });
    defer margined.deinit();
    const core_h: usize = zero.height;
    const core_w: usize = zero.width;
    const margin: usize = pad;

    // The margin grew the frame by itself on both axes, nothing else did.
    try testing.expectEqual(core_w + 2 * margin, @as(usize, margined.width));
    try testing.expectEqual(core_h + 2 * margin, @as(usize, margined.height));

    // Liveness: the ink really does reach the frame's first row, the edge a
    // frame cut from the declared box can lose — otherwise this proves nothing.
    var top_ink: usize = 0;
    for (0..core_w) |x| top_ink += @intFromBool(zero.pixels[x] != 0);
    try testing.expect(top_ink > 0);

    // No ink outside the shift the margin makes...
    var outside: usize = 0;
    // ...and inside it the same picture: the frame is a pixel or more taller
    // with a margin, so a coverage that rounds differently may differ by one
    // level of gray, but no pixel may move further than that.
    var worst: i32 = 0;
    for (0..@as(usize, margined.height)) |y| {
        for (0..@as(usize, margined.width)) |x| {
            const value = margined.pixels[y * @as(usize, margined.stride) + x];
            const in_core = y >= margin and y < margin + core_h and
                x >= margin and x < margin + core_w;
            if (!in_core) {
                outside += @intFromBool(value != 0);
                continue;
            }
            const core = zero.pixels[(y - margin) * @as(usize, zero.stride) + (x - margin)];
            const delta = @as(i32, value) - @as(i32, core);
            worst = @max(worst, if (delta < 0) -delta else delta);
        }
    }
    try testing.expectEqual(@as(usize, 0), outside);
    try testing.expect(worst <= 1);
}

test "rasterize: integer padding preserves glyph coverage" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const pad: u32 = 4;
    const cases = [_]struct { source: []const u8, style: layout.Style, size: f32 }{
        .{ .source = "\\mathrm{\\alpha+\\sqrt{x}}+\\textit{α}", .style = .display, .size = 8 },
        .{
            .source = "\\sqrt{1+\\sqrt{1+\\sqrt{1+\\sqrt{1+\\sqrt{1+\\sqrt{1+x}}}}}}",
            .style = .script,
            .size = 20,
        },
        .{ .source = "\\sqrt{\\frac{a}{b}}", .style = .display, .size = 20 },
        .{ .source = "x^2_0", .style = .display, .size = 20 },
    };
    for (cases) |case| {
        var dl = try ctx.render(case.source, case.style, case.size, null);
        defer dl.deinit();
        var bare = try rasterize(testing.allocator, &ctx, &dl, .{
            .dpi = 300,
            .format = .alpha8,
        });
        defer bare.deinit();
        var margined = try rasterize(testing.allocator, &ctx, &dl, .{
            .dpi = 300,
            .format = .alpha8,
            .padding = pad,
        });
        defer margined.deinit();

        try testing.expectEqual(bare.width + 2 * pad, margined.width);
        try testing.expectEqual(bare.height + 2 * pad, margined.height);

        const margin: usize = pad;
        const core_w: usize = bare.width;
        const core_h: usize = bare.height;
        var worst: i32 = 0;
        for (0..@as(usize, margined.height)) |y| {
            for (0..@as(usize, margined.width)) |x| {
                const value = margined.pixels[y * @as(usize, margined.stride) + x];
                const in_core = y >= margin and y < margin + core_h and
                    x >= margin and x < margin + core_w;
                if (!in_core) {
                    // Measured ink remains inside the unpadded frame.
                    try testing.expectEqual(@as(u8, 0), value);
                    continue;
                }
                const core = bare.pixels[(y - margin) * @as(usize, bare.stride) + x - margin];
                const delta = @as(i32, value) - @as(i32, core);
                worst = @max(worst, if (delta < 0) -delta else delta);
            }
        }
        if (worst != 0) {
            std.debug.print(
                "a margin of {d} moved the picture by {d}: {s} at {d}pt {s}\n",
                .{ pad, worst, case.source, case.size, @tagName(case.style) },
            );
        }
        try testing.expectEqual(@as(i32, 0), worst);
    }
}

// Every length in the frame is a multiple of the pt → px scale, so a dpi
// or scale that is not a positive finite number leaves nothing to round a
// pixel count from: the product is NaN or infinite, and `@intFromFloat`
// TRAPS on both, aborting the process whatever the caller catches.
// `failing_allocator` answers `error.OutOfMemory` to the first byte, so an
// `error.InvalidArgument` here also proves the frame was refused before
// anything was allocated.
test "rasterize: a resolution that is not a positive finite number is refused" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var dl = try ruleList(testing.allocator, .{ .r = 0, .g = 0, .b = 0 }, false);
    defer dl.deinit();
    for ([_]f32{ 0, -96, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |dpi| {
        try testing.expectError(
            error.InvalidArgument,
            rasterize(testing.failing_allocator, &ctx, &dl, .{ .dpi = dpi }),
        );
    }
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) }) |scale| {
        try testing.expectError(
            error.InvalidArgument,
            rasterize(testing.failing_allocator, &ctx, &dl, .{ .dpi = 96, .scale = scale }),
        );
    }
    // A dpi and a scale that are each fine, whose PRODUCT is not: the scale
    // alone overflows (dpi / 72) * scale to infinity.
    try testing.expectError(
        error.InvalidArgument,
        rasterize(testing.failing_allocator, &ctx, &dl, .{
            .dpi = 96,
            .scale = std.math.floatMax(f32),
        }),
    );
}

// The frame is a 32-bit one, and a hostile margin or an enormous resolution
// used to walk straight past that: `2 * pad` overflowed u32, a content size
// past 2^32 - 1 trapped in the float cast, and a row stride wider than a
// u32 wrapped. Each is refused BEFORE the pixel block is asked for — the
// failing allocator would answer `error.OutOfMemory` to the first byte, so
// an `error.OutputTooLarge` here means no allocation was attempted at all.
test "rasterize: a frame no 32-bit size can describe is refused before allocating" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var dl = try ruleList(testing.allocator, .{ .r = 0, .g = 0, .b = 0 }, false);
    defer dl.deinit();
    // 2 * 2^31 is one past the largest u32: the margin alone does not fit.
    try testing.expectError(
        error.OutputTooLarge,
        rasterize(testing.failing_allocator, &ctx, &dl, .{ .dpi = 96, .padding = 2147483648 }),
    );
    // 2 * 2^30 fits, and so does the framed width — but four bytes per pixel
    // of it do not.
    try testing.expectError(
        error.OutputTooLarge,
        rasterize(testing.failing_allocator, &ctx, &dl, .{ .dpi = 96, .padding = 1073741824 }),
    );
    // A resolution that is finite and positive and still frames a picture
    // no 32-bit width can hold: 1e30 dpi is 1.4e28 px per point.
    try testing.expectError(
        error.OutputTooLarge,
        rasterize(testing.failing_allocator, &ctx, &dl, .{ .dpi = 1e30 }),
    );
}

test "rasterize: payload cap is checked before allocating and includes every row" {
    // An empty frame is 2x2 after the minimum content and edge bearing.
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    for ([_]Format{ .rgba32, .alpha8 }) |format| {
        const bytes: usize = if (format == .rgba32) 16 else 4;
        try testing.expectError(
            error.OutputTooLarge,
            rasterize(testing.failing_allocator, &ctx, &dl, .{
                .dpi = 72,
                .format = format,
                .max_bytes = bytes - 1,
            }),
        );
        var accepted = try rasterize(testing.allocator, &ctx, &dl, .{
            .dpi = 72,
            .format = format,
            .max_bytes = bytes,
        });
        defer accepted.deinit();
        try testing.expectEqual(@as(u32, 2), accepted.width);
        try testing.expectEqual(@as(u32, 2), accepted.height);
        try testing.expectEqualSlices(
            u8,
            if (format == .rgba32) &([_]u8{0} ** 16) else &([_]u8{0} ** 4),
            accepted.pixels,
        );
    }
}

// The frame is cut from the ink bounds, so a draw list carrying a non-finite
// extent has none to cut — and its NaN width reached `@intFromFloat` and
// trapped. The rasterizer now answers the coordinate error the SVG
// serializer already reports for the very same list.
test "rasterize: a non-finite ink extent is refused as a coordinate" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.accInk(0, -7, std.math.nan(f32), 2);
    try testing.expectError(
        error.NonFiniteCoordinate,
        rasterize(testing.failing_allocator, &ctx, &dl, .{ .dpi = 96 }),
    );
}

test "rasterize: \\mathbf draws the bold face, not the regular one" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();

    // \mathbf used to resolve to the same face as \text, so \mathbf{x} and
    // \text{x} rasterized identically — the SVG said bold, the bitmap did
    // not. Compare the two at the same size: a real bold face puts down
    // noticeably more ink for the same glyph.
    const countInk = struct {
        fn f(
            c: *context.Context,
            src: []const u8,
        ) !usize {
            var dl = try c.render(src, .display, 40, null);
            defer dl.deinit();
            var buf = try rasterize(testing.allocator, c, &dl, .{
                .dpi = 96,
                .format = .alpha8,
            });
            defer buf.deinit();
            return inkedPixels(buf);
        }
    }.f;

    const bold = try countInk(&ctx, "\\mathbf{x}");
    const roman = try countInk(&ctx, "\\text{x}");
    try testing.expect(bold > 0);
    try testing.expect(roman > 0);
    // Equal ink is the bug: it means \mathbf drew the regular glyph.
    try testing.expect(bold > roman);
    // Bold must be a real weight difference, not an antialiasing wobble.
    try testing.expect(bold * 10 > roman * 11);
}

/// A single-glyph draw item at the origin, 20pt, in `style`. `bytes` is a
/// string literal, so a test draw list needs no glyph arena.
fn item(bytes: []const u8, style: atom.CharStyle) draw.Text {
    return .{
        .bytes = bytes,
        .x = 0,
        .y = 0,
        .size = 20,
        .style = style,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .src_start = 0,
        .src_end = 0,
    };
}

/// The MATH form a draw item asks for, through the same builder `svg.zig`
/// uses: one request, one resolver, so the two back ends cannot disagree
/// about which glyph an item paints.
fn requestOf(t: draw.Text) ?glyph.Request {
    return glyph.requestFor(t.bytes, .{
        .bigop_variant = t.bigop_form == .variant,
        .radical_form = t.radical_form,
        .delim_form = t.delim_form,
        .delim_fixed = t.delim_fixed,
        .delim_req = t.delim_req,
        .horizontal_req = t.horizontal_req,
    });
}

/// Rasterize one draw item at 20pt / 72 dpi (1 px per pt) inside a frame far
/// larger than any variant, so a taller rung is never clipped by the box.
fn rasterOne(gpa: std.mem.Allocator, ctx: *context.Context, t: draw.Text) !PixelBuffer {
    var dl = draw.DrawList.init(gpa);
    defer dl.deinit();
    try dl.add(.{ .text = t });
    dl.accInk(-60, -70, 60, 30);
    return rasterize(gpa, ctx, &dl, .{ .dpi = 72, .format = .alpha8 });
}

/// Non-zero bytes in an alpha8 buffer — the drawn ink.
fn inkedPixels(buffer: PixelBuffer) usize {
    var n: usize = 0;
    for (buffer.pixels) |p| {
        if (p != 0) n += 1;
    }
    return n;
}

/// Buffer rows carrying ink — the drawn glyph's height, in pixels.
fn inkedRows(buffer: PixelBuffer) usize {
    var n: usize = 0;
    for (0..buffer.height) |y| {
        for (0..buffer.width) |x| {
            if (buffer.pixels[y * buffer.stride + x] != 0) {
                n += 1;
                break;
            }
        }
    }
    return n;
}

/// The value a glyph lookup must yield, or a test failure that names what
/// is missing. A forced unwrap would abort the whole test binary when the
/// font data stops resolving, leaving a panic trace instead of the lookup
/// that went null.
fn expectResolved(comptime T: type, subject: []const u8, resolved: ?T) error{MissingGlyph}!T {
    if (resolved) |value| return value;
    std.debug.print("glyph lookup returned null: {s}\n", .{subject});
    return error.MissingGlyph;
}

// The old rasterizer named 62 Latin Modern glyph ids literally: display
// operators, radical pieces and fence rungs. Nothing names a glyph id now —
// the face's own MATH table answers — so what has to hold is that every
// family those ids covered really GROWS: seven rungs of seven different
// heights, for every fence the layout can ask for, including the ones the
// old per-codepoint switch forgot and drew at their base size.
test "rasterize: every fence family grows through its own variant ladder" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const fences = [_][]const u8{
        "(",        ")",        "[",        "]",        "{",        "}",
        "|",        "\u{2223}", "\u{2225}", "\u{230A}", "\u{230B}", "\u{2308}",
        "\u{2309}", "\u{27E8}", "\u{27E9}", "/",
    };
    for (fences) |text| {
        var previous: ?PixelBuffer = null;
        defer if (previous) |*p| p.deinit();
        var previous_rows: usize = 0;
        for (1..8) |rung| {
            var t = item(text, .italic);
            t.delim_form = @intCast(rung);
            const buffer = try rasterOne(testing.allocator, &ctx, t);
            const rows = inkedRows(buffer);
            try testing.expect(rows > previous_rows);
            if (previous) |before| {
                // Same frame, same pen position: a differing bitmap means a
                // DIFFERENT glyph, not the same one nudged.
                try testing.expectEqual(before.pixels.len, buffer.pixels.len);
                try testing.expect(!std.mem.eql(u8, before.pixels, buffer.pixels));
            }
            if (previous) |*before| before.deinit();
            previous = buffer;
            previous_rows = rows;
        }
    }
}

// Every display operator draws its OWN display form. The old switch named
// four of them and let the rest fall through to their base glyphs, so ∬ came
// out identical to ∮; what has to hold now is that no two display operators
// share a drawing and none of them is its base form.
test "rasterize: every display operator draws its own display form" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const operators = [_][]const u8{
        "\u{2211}", "\u{220F}", "\u{222B}", "\u{222E}", "\u{2210}", "\u{222F}",
        "\u{2230}", "\u{22C3}", "\u{22C2}", "\u{2A06}", "\u{2A11}",
    };
    for (operators) |text| {
        var display = item(text, .italic);
        display.bigop_form = .variant;
        const base = item(text, .italic);
        var display_buffer = try rasterOne(testing.allocator, &ctx, display);
        defer display_buffer.deinit();
        var base_buffer = try rasterOne(testing.allocator, &ctx, base);
        defer base_buffer.deinit();
        try testing.expect(inkedPixels(display_buffer) > 0);
        // The display form is a different drawing from the base one.
        try testing.expect(!std.mem.eql(u8, display_buffer.pixels, base_buffer.pixels));
    }
    // ∬ and ∮ used to be the same bitmap; now they are not.
    var oint = item("\u{222E}", .italic);
    oint.bigop_form = .variant;
    var iint = item("\u{2A11}", .italic);
    iint.bigop_form = .variant;
    var oint_buffer = try rasterOne(testing.allocator, &ctx, oint);
    defer oint_buffer.deinit();
    var iint_buffer = try rasterOne(testing.allocator, &ctx, iint);
    defer iint_buffer.deinit();
    try testing.expect(!std.mem.eql(u8, iint_buffer.pixels, oint_buffer.pixels));
}

// A fence must grow along its variant ladder, not by scaling the base
// glyph: every rung paints a different bitmap, each taller than the last,
// and the tallest matches the ladder's own 2.991em advance at 20pt.
test "rasterize: a fence grows through the variant ladder, rung by rung" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const face = ctx.fonts.faceForStyle(.italic);
    const paren = try expectResolved(u32, "'(' base glyph", face.glyphIndex('('));
    const ladder = try expectResolved(font.MathVariants, "'(' ladder", face.variants(paren));
    try testing.expectEqual(@as(usize, 7), ladder.len());

    var previous: ?PixelBuffer = null;
    defer if (previous) |*p| p.deinit();
    var previous_rows: usize = 0;

    for (0..7) |rung| {
        var t = item("(", .italic);
        t.delim_form = @intCast(rung + 1);
        const buffer = try rasterOne(testing.allocator, &ctx, t);
        const rows = inkedRows(buffer);
        // The rung must be visibly taller, and match the AdvanceMeasurement
        // the table reports for it (1px per pt at 20pt).
        try testing.expect(rows > previous_rows);
        try testing.expectApproxEqAbs(
            ladder.advanceEm(rung) * 20.0,
            @as(f32, @floatFromInt(rows)),
            2.0,
        );
        if (previous) |before| {
            // Same frame, same pen position: a differing bitmap means a
            // DIFFERENT glyph, not the same one nudged.
            try testing.expectEqual(buffer.pixels.len, before.pixels.len);
            try testing.expect(!std.mem.eql(u8, buffer.pixels, before.pixels));
        }
        if (previous) |*before| before.deinit();
        previous = buffer;
        previous_rows = rows;
    }
}

// A face with no MATH table must degrade, never fail: the fence still
// renders as its base cmap glyph, and a codepoint the face cannot map at
// all is skipped instead of borrowing a glyph id from another font.
test "rasterize: a face with no MATH table degrades to the base glyph" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const face = ctx.fonts.faceForStyle(.roman);
    const original_math = ctx.fonts.math;
    ctx.fonts.math = face;
    defer ctx.fonts.math = original_math;
    // Precondition: the Roman face really carries no MATH data.
    try testing.expect(face.mathConstants() == null);

    var stretched = item("(", .roman);
    stretched.delim_form = 6;
    const plain = item("(", .roman);
    // The request the CPU resolver answers with: no ladder, no assembly, so
    // the one glyph it CAN honestly draw is the codepoint's own.
    const built = (try glyph.plan(
        testing.allocator,
        face,
        requestOf(stretched) orelse return error.NoRequest,
    )) orelse return error.MissingGlyph;
    switch (built) {
        .stack => return error.AssembledWithoutMath,
        .single => |part| {
            try testing.expectEqual(
                face.glyphIndex('(') orelse return error.MissingGlyph,
                part.glyph,
            );
            try testing.expectEqual(@as(f32, 0), part.y_em);
        },
    }

    var stretched_buffer = try rasterOne(testing.allocator, &ctx, stretched);
    defer stretched_buffer.deinit();
    var plain_buffer = try rasterOne(testing.allocator, &ctx, plain);
    defer plain_buffer.deinit();
    // Degradation, not disappearance: byte-identical to the unstretched glyph.
    try testing.expect(std.mem.eql(u8, stretched_buffer.pixels, plain_buffer.pixels));
    try testing.expect(inkedPixels(stretched_buffer) > 0);

    // ∑ is absent from the Roman face, so there is nothing to degrade TO.
    var op = item("\u{2211}", .roman);
    op.bigop_form = .variant;
    try testing.expectEqual(
        @as(?glyph.Plan, null),
        try glyph.plan(testing.allocator, face, requestOf(op) orelse return error.NoRequest),
    );
    var empty_buffer = try rasterOne(testing.allocator, &ctx, op);
    defer empty_buffer.deinit();
    try testing.expectEqual(@as(usize, 0), inkedPixels(empty_buffer));
}

// A fence whose content outgrew the whole ladder has no glyph to draw: it
// is a STACK. It must paint taller than the largest variant it replaced,
// and reach the height layout asked for, or a tall pmatrix comes out with
// parentheses that stop halfway down the last row.
test "rasterize: a fence past the largest variant paints an assembly of that height" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const size: f32 = 20;

    var tallest = item("(", .italic);
    tallest.size = size;
    tallest.delim_form = 7;
    var tallest_buffer = try rasterOne(testing.allocator, &ctx, tallest);
    defer tallest_buffer.deinit();
    const tallest_rows = inkedRows(tallest_buffer);

    var previous_rows: usize = 0;
    for ([_]f32{ 3.4, 4.5, 6.0 }) |req_em| {
        var tall = item("(", .italic);
        tall.size = size;
        tall.delim_req = req_em;
        var list = try framedList(testing.allocator, &ctx, tall);
        defer list.deinit();
        var buffer = try rasterize(
            testing.allocator,
            &ctx,
            &list,
            .{ .dpi = 72, .format = .alpha8 },
        );
        defer buffer.deinit();
        const rows = inkedRows(buffer);
        try testing.expect(rows > tallest_rows);
        try testing.expect(rows > previous_rows);
        // The request is in em of the run's size; at 72 dpi one point is one pixel.
        try testing.expectApproxEqAbs(req_em * size, @as(f32, @floatFromInt(rows)), 2.0);
        previous_rows = rows;
    }
}

/// One draw item in a draw list whose frame is cut from the geometry the
/// request really paints, so an assembly taller than any size variant is
/// never clipped by the box it is measured against. The caller deinits it.
fn framedList(gpa: std.mem.Allocator, ctx: *context.Context, t: draw.Text) !draw.DrawList {
    const request = requestOf(t) orelse return error.NoRequest;
    const face = if (glyph.needsGeometry(request))
        ctx.fonts.math
    else
        ctx.fonts.faceForCodepoint(request.cp, t.style);
    const bounds = (try glyph.paintedBounds(gpa, face, request)) orelse return error.NoAssembly;
    var dl = draw.DrawList.init(gpa);
    errdefer dl.deinit();
    try dl.add(.{ .text = t });
    // `Draw.Text.y` counts down and a placement's run counts up, so the
    // painted box runs from -y_max to -y_min in points.
    dl.accInk(
        bounds.x_min * t.size - 4,
        -bounds.y_max * t.size - 4,
        bounds.x_max * t.size + 4,
        -bounds.y_min * t.size + 4,
    );
    return dl;
}

/// A closed axis-aligned rectangle in buffer pixels, wound so the interior
/// lies to the RIGHT of travel. Lines carry p1 at the midpoint, exactly as a
/// font outline stores them.
fn rect(x0: f32, y0: f32, x1: f32, y1: f32, out: *[4]coverage.QuadCurve) void {
    const pts = [4][2]f32{ .{ x0, y0 }, .{ x0, y1 }, .{ x1, y1 }, .{ x1, y0 } };
    for (pts, 0..) |a, i| {
        const b = pts[(i + 1) % 4];
        out[i] = .{
            .p0 = a,
            .p1 = .{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 },
            .p2 = b,
        };
    }
}

/// Clip each rectangle to the band the connector cut gives it, sweep the
/// clipped parts and add their coverages — the production path's geometry,
/// driven end to end into a one-pixel alpha8 buffer. Returns that pixel.
fn clippedUnionPixel(
    gpa: std.mem.Allocator,
    rects: []const [4]coverage.QuadCurve,
    cut: f32,
) !u8 {
    var scratch: GlyphScratch = .{ .gpa = gpa };
    defer scratch.deinit();
    var fill: GlyphItem = .{
        .scratch = &scratch,
        .face = undefined,
        .frame = .{
            .t = item("x", .italic),
            .pt_to_px = 1,
            .frame_h = 1,
            .origin = .{ .x = 0, .y = 0 },
            .gscale = 1,
        },
    };
    for (rects, 0..) |*r, i| {
        const first: u32 = @intCast(scratch.contours.items.len);
        scratch.raw.clearRetainingCapacity();
        try scratch.raw.appendSlice(gpa, r);
        // The connector is split down its middle: the part below the cut keeps
        // what is below it, the one above keeps what is above. Both halves
        // survive, so the two are disjoint and their areas simply add.
        const half: Half = if (i == 0) .less else .greater;
        try fill.clipTo(scratch.raw.items, &scratch.clipped, 0, cut, half);
        try scratch.contours.appendSlice(gpa, scratch.clipped.items);
        var span: PlacementSpan = .{
            .first = first,
            .last = @intCast(scratch.contours.items.len),
            .y_lo = std.math.inf(f32),
            .y_hi = -std.math.inf(f32),
            .x_lo = std.math.inf(f32),
            .x_hi = -std.math.inf(f32),
        };
        for (scratch.clipped.items) |c| {
            span.y_lo = @min(span.y_lo, @min(c.p0[1], @min(c.p1[1], c.p2[1])));
            span.y_hi = @max(span.y_hi, @max(c.p0[1], @max(c.p1[1], c.p2[1])));
            span.x_lo = @min(span.x_lo, @min(c.p0[0], @min(c.p1[0], c.p2[0])));
            span.x_hi = @max(span.x_hi, @max(c.p0[0], @max(c.p1[0], c.p2[0])));
        }
        fill.min_x = @min(fill.min_x, span.x_lo);
        fill.max_x = @max(fill.max_x, span.x_hi);
        fill.min_y = @min(fill.min_y, span.y_lo);
        fill.max_y = @max(fill.max_y, span.y_hi);
        try scratch.parts.append(gpa, span);
    }
    var pixels = [_]u8{0};
    try fill.sweep(&pixels, 1, 1, 0, 1, .alpha8, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    return pixels[0];
}

// THE FIRST COUNTEREXAMPLE, and the reason a raw sum cannot be clamped into a
// union. Two IDENTICAL parts, each covering the right half of one pixel. The
// union of two coincident shapes is that same half — 0.5 — but their signed
// areas add to 1.0, and a clamp happily reports 1.0. Only clipping the
// connector between them and ADDING the two disjoint halves recovers 0.5.
test "rasterize: two coincident half-covered parts union to half, not to full" {
    var a: [4]coverage.QuadCurve = undefined;
    var b: [4]coverage.QuadCurve = undefined;
    rect(0.5, 0.0, 1.0, 1.0, &a);
    rect(0.5, 0.0, 1.0, 1.0, &b);
    const rects = [_][4]coverage.QuadCurve{ a, b };

    // The connector runs from 0.5 to 1.0, so the cut is its middle, 0.75.
    const covered = try clippedUnionPixel(testing.allocator, &rects, 0.75);
    try testing.expectApproxEqAbs(@as(f32, 128.0), @as(f32, @floatFromInt(covered)), 2.0);

    // What the unclipped sum would have reported, for the contrast.
    var raw: [1]f32 = undefined;
    var both: [8]coverage.QuadCurve = undefined;
    @memcpy(both[0..4], &a);
    @memcpy(both[4..8], &b);
    coverage.coverageRow(&both, 0, 0, &raw);
    try testing.expectApproxEqAbs(@as(f32, 1.0), raw[0], 0.0001);
}

// THE SECOND COUNTEREXAMPLE, and the reason the cut cannot be rounded to a
// pixel boundary. Two parts overlap by 0.2px of a single pixel: A reaches
// 0.6 across it, B reaches 0.4 from the other side. The union is the whole
// pixel, 1.0 — but giving the pixel to ONE owner (the left one, at a cut
// rounded to ceil(0.5) = 1) yields A alone, 0.6, and B's 0.4 of real ink is
// simply lost. Clipping keeps both shares and adds them.
test "rasterize: a sub-pixel overlap keeps both parts' shares of the pixel" {
    var a: [4]coverage.QuadCurve = undefined;
    var b: [4]coverage.QuadCurve = undefined;
    rect(0.0, 0.0, 0.6, 1.0, &a);
    rect(0.4, 0.0, 1.0, 1.0, &b);
    const rects = [_][4]coverage.QuadCurve{ a, b };

    // The connector runs from 0.4 to 0.6, so the cut is its middle, 0.5.
    const covered = try clippedUnionPixel(testing.allocator, &rects, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 255.0), @as(f32, @floatFromInt(covered)), 2.0);
}

// THE REGRESSION. An assembly's parts share the font's own connector
// material, and each part used to be composited into the buffer on its own:
// in the shared band the ink alpha was applied twice, so a translucent
// `\left(` came out with a dark seam down every join, at twice the alpha of
// the ink beside it — while the SVG of the very same formula, filled as one
// compound path, showed a uniform fence.
test "rasterize: an assembled fence's join carries the ink alpha once, not twice" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();

    // A fence asked for far more ink than its largest variant covers, so the
    // resolver MUST hand back an assembly. Asserted, not assumed: a run that
    // quietly picked a single variant would make every assertion below pass
    // without ever touching a join.
    // 8pt at 96 dpi is the regime the bug hides in: LM's MinConnectorOverlap
    // is 0.02em, about 0.21 of a pixel here, so a join is SUB-PIXEL and any
    // rounding of the cut to a pixel loses a real share of a real edge.
    var fence = item("(", .italic);
    fence.size = 8;
    fence.delim_req = 6.0;
    var built = (try glyph.plan(
        testing.allocator,
        ctx.fonts.math,
        requestOf(fence) orelse return error.NoRequest,
    )) orelse return error.MissingGlyph;
    var placements: usize = 0;
    switch (built) {
        .single => return error.NoAssembly,
        .stack => |*cursor| while (cursor.next()) |part| {
            _ = part;
            placements += 1;
        },
    }
    try testing.expect(placements >= 3);

    const ink: draw.Color = .{ .r = 0, .g = 0, .b = 0, .a = 64 };
    var dl = try framedList(testing.allocator, &ctx, fence);
    defer dl.deinit();
    var rgba = try rasterize(testing.allocator, &ctx, &dl, .{
        .dpi = 96,
        .format = .rgba32,
        .fg = ink,
    });
    defer rgba.deinit();
    var mask = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 96, .format = .alpha8, .fg = ink });
    defer mask.deinit();
    var solid = try rasterize(testing.allocator, &ctx, &dl, .{
        .dpi = 96,
        .format = .alpha8,
    });
    defer solid.deinit();

    // Subpixel stems need not cover a whole pixel. Their opacity still scales
    // linearly with the ink alpha; blending overlapping pieces twice does not.
    for (mask.pixels, solid.pixels) |actual, coverage_alpha| {
        const expected = @as(f32, @floatFromInt(coverage_alpha)) * 64.0 / 255.0;
        try testing.expectApproxEqAbs(expected, @as(f32, @floatFromInt(actual)), 1.0);
    }

    // The same picture in both formats on the SAME ink: an alpha8 mask is the
    // rgba alpha scaled by nothing, and the two back ends disagreeing here
    // is the defect this whole path exists to remove.
    for (0..@as(usize, rgba.height)) |y| {
        for (0..@as(usize, rgba.width)) |x| {
            try testing.expectApproxEqAbs(
                @as(f32, @floatFromInt(mask.pixels[y * @as(usize, mask.stride) + x])),
                @as(f32, @floatFromInt(rgbaAt(rgba, x, y)[3])),
                1.0,
            );
        }
    }
}

test "rasterize: a Roman radical preserves its math surd and upright body" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    for ([_]atom.MathStyle{ .display, .text }) |style| {
        for ([_]f32{ 8, 20, 60 }) |size| {
            var outer = try ctx.renderPixels(
                "\\mathrm{\\sqrt{x}}",
                style,
                size,
                .{ .dpi = 192, .format = .alpha8 },
                null,
            );
            defer outer.deinit();
            var body = try ctx.renderPixels(
                "\\sqrt{\\mathrm{x}}",
                style,
                size,
                .{ .dpi = 192, .format = .alpha8 },
                null,
            );
            defer body.deinit();
            try testing.expectEqual(body.width, outer.width);
            try testing.expectEqual(body.height, outer.height);
            try testing.expectEqualSlices(u8, body.pixels, outer.pixels);
        }
    }
}

test "rasterize: fixed delimiter commands paint their four distinct MATH heights" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const sources = [_][]const u8{ "\\big(", "\\Big(", "\\bigg(", "\\Bigg(" };
    const heights = [_]f32{ 1.094, 1.792, 2.392, 2.990 };
    for (sources, heights) |source, height_em| {
        var pixels = try ctx.renderPixels(
            source,
            .display,
            20,
            .{ .dpi = 192, .format = .alpha8 },
            null,
        );
        defer pixels.deinit();
        const painted_height: f32 = @floatFromInt(inkedRows(pixels));
        try testing.expectApproxEqAbs(height_em * 20 * (192.0 / 72.0), painted_height, 2.0);
    }
}

// An assembly long enough to need more parts than a fixed-size placement
// buffer would hold: every row from the first ink to the last must carry
// ink, or the fence has a hole in it. This is the shape claim that a
// truncated part list, or a sweep that drops the joins, both produce.
test "rasterize: an assembly of hundreds of parts is unbroken top to bottom" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    var tall = item("(", .italic);
    tall.delim_req = 200.0;

    // More parts than any fixed-size placement buffer: the plan has to walk,
    // not enumerate into one.
    const request = requestOf(tall) orelse return error.NoRequest;
    var built = (try glyph.plan(testing.allocator, ctx.fonts.math, request)) orelse
        return error.MissingGlyph;
    var parts: usize = 0;
    switch (built) {
        .single => return error.NoAssembly,
        .stack => |*cursor| while (cursor.next()) |part| {
            _ = part;
            parts += 1;
        },
    }
    try testing.expect(parts > 64);

    var dl = try framedList(testing.allocator, &ctx, tall);
    defer dl.deinit();
    var buf = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 72, .format = .alpha8 });
    defer buf.deinit();

    const s = tall.size;

    const rows = inkedRows(buf);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(rows)), 200.0 * s, 4.0);
    // Continuous: no row between the first and the last inked row is empty.
    var first: usize = 0;
    while (first < @as(usize, buf.height) and rowIsEmpty(buf, first)) first += 1;
    var last = @as(usize, buf.height);
    while (last > first and rowIsEmpty(buf, last - 1)) last -= 1;
    try testing.expect(last > first);
    for (first..last) |y| try testing.expect(!rowIsEmpty(buf, y));
}

fn rowIsEmpty(buffer: PixelBuffer, y: usize) bool {
    const at = y * @as(usize, buffer.stride);
    for (buffer.pixels[at..][0..@as(usize, buffer.width)]) |v| {
        if (v != 0) return false;
    }
    return true;
}

/// One pixel's ink as a coverage: the mask byte, or the rgba32 alpha. Both
/// formats answer the same number, which is what makes a PGM and a PPM of one
/// picture agree about how much ink there is.
fn inkByte(buffer: PixelBuffer, x: usize, y: usize) u8 {
    const at = y * @as(usize, buffer.stride);
    return switch (buffer.format) {
        .alpha8 => buffer.pixels[at + x],
        .rgba32 => buffer.pixels[at + x * 4 + 3],
    };
}

/// The ink one row carries, in PIXELS: the sum of its coverage, so a row a
/// rule covers by a third measures a third of a pixel. Only an OPAQUE ink is
/// measured this way; a translucent one scales every byte by its own alpha.
fn rowInk(buffer: PixelBuffer, y: usize) f32 {
    var total: f32 = 0;
    for (0..@as(usize, buffer.width)) |x| {
        total += @as(f32, @floatFromInt(inkByte(buffer, x, y))) / 255.0;
    }
    return total;
}

/// The whole buffer's ink, in pixels: what a picture weighs against the
/// geometry that claims to have produced it.
fn totalInk(buffer: PixelBuffer) f32 {
    var total: f32 = 0;
    for (0..@as(usize, buffer.height)) |y| total += rowInk(buffer, y);
    return total;
}

/// The ink a primitive paints: its own color when an explicit color scope
/// covers it, else the host foreground. The FLAG decides, not the value, so
/// an explicit black or a transparent {0,0,0,0} beats a light host
/// foreground instead of being taken for "no color given".
fn inkOf(opts: Options, color: draw.Color, color_override: bool) draw.Color {
    return if (color_override) color else opts.fg;
}

/// Composite one covered pixel of `ink` at `coverage_val` (0…1) over the
/// buffer. Both formats honour the ink's alpha identically: rgba32 scales
/// the source alpha, alpha8 scales coverage, so a half-transparent rule
/// leaves a half-strength mask and a fully transparent one leaves nothing.
inline fn blendPixel(
    pixels: []u8,
    row: usize,
    col: usize,
    stride: u32,
    format: Format,
    ink: draw.Color,
    coverage_val: f32,
) void {
    const cov = @min(1.0, @max(0.0, coverage_val)) * @as(f32, @floatFromInt(ink.a)) / 255.0;
    switch (format) {
        .rgba32 => {
            const idx = row * stride + col * 4;
            // coverage already carries the ink alpha (see `cov`).
            const src_r: f32 = @floatFromInt(ink.r);
            const src_g: f32 = @floatFromInt(ink.g);
            const src_b: f32 = @floatFromInt(ink.b);

            const dst_r: f32 = @floatFromInt(pixels[idx]);
            const dst_g: f32 = @floatFromInt(pixels[idx + 1]);
            const dst_b: f32 = @floatFromInt(pixels[idx + 2]);
            const dst_a: f32 = @as(f32, @floatFromInt(pixels[idx + 3])) / 255.0;

            const out_a = cov + dst_a * (1.0 - cov);
            if (out_a > 0.0) {
                const out_r = (src_r * cov + dst_r * dst_a * (1.0 - cov)) / out_a;
                const out_g = (src_g * cov + dst_g * dst_a * (1.0 - cov)) / out_a;
                const out_b = (src_b * cov + dst_b * dst_a * (1.0 - cov)) / out_a;
                pixels[idx] = @intFromFloat(@round(out_r));
                pixels[idx + 1] = @intFromFloat(@round(out_g));
                pixels[idx + 2] = @intFromFloat(@round(out_b));
                pixels[idx + 3] = @intFromFloat(@round(out_a * 255.0));
            }
        },
        .alpha8 => {
            const idx = row * stride + col;
            const cur_a: f32 = @as(f32, @floatFromInt(pixels[idx])) / 255.0;
            const new_a = cur_a + cov * (1.0 - cur_a);
            pixels[idx] = @intFromFloat(@round(new_a * 255.0));
        },
    }
}

/// Fill the butt-capped band of half-width `half` (pixels) along the segment
/// (x0f,y0f)–(x1f,y1f). Coverage is the pixel centre's distance to the
/// segment — 1 inside the band, a linear ramp across the outer half
/// pixel, 0 outside — so a diagonal stroke is a thin diagonal band at a
/// constant width, not the bounding box of its endpoints (which for a
/// diagonal is the whole wedge between them). Both backends paint the same
/// butt-cap geometry: the band stops at each endpoint's plane.
fn strokeSegment(
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
    ink: draw.Color,
    x0f: f32,
    y0f: f32,
    x1f: f32,
    y1f: f32,
    half: f32,
) void {
    if (ink.a == 0) return;
    // One pixel of slack past the band, so the antialiased rim is never
    // clipped at the loop bounds.
    const slack: f32 = 1;
    const limit_x: i64 = @intCast(width);
    const limit_y: i64 = @intCast(height);
    const c0 = @max(@as(i64, @intFromFloat(@floor(@min(x0f, x1f) - half - slack))), 0);
    const c1 = @min(@as(i64, @intFromFloat(@ceil(@max(x0f, x1f) + half + slack))), limit_x);
    const r0 = @max(@as(i64, @intFromFloat(@floor(@min(y0f, y1f) - half - slack))), 0);
    const r1 = @min(@as(i64, @intFromFloat(@ceil(@max(y0f, y1f) + half + slack))), limit_y);
    if (c1 <= c0 or r1 <= r0) return;

    const dx = x1f - x0f;
    const dy = y1f - y0f;
    const len_sq = dx * dx + dy * dy;
    // A zero-length segment draws nothing, as a butt-capped line does.
    if (len_sq <= 0) return;
    const reach = half + 0.5;
    var r = r0;
    while (r < r1) : (r += 1) {
        const py = @as(f32, @floatFromInt(r)) + 0.5;
        var c = c0;
        while (c < c1) : (c += 1) {
            const px = @as(f32, @floatFromInt(c)) + 0.5;
            // Where the pixel's perpendicular meets the segment.
            const t = ((px - x0f) * dx + (py - y0f) * dy) / len_sq;
            // Butt caps match the filled SVG band: the segment stops in the
            // plane through each endpoint instead of rounding past it.
            // Layout sized the box's
            // h/d from exactly this extent, so a round cap would paint
            // outside the ink bbox (clipped at zero padding) and the two back
            // ends would disagree on where the ink ends.
            if (t < 0 or t > 1) continue;
            const ex = px - (x0f + t * dx);
            const ey = py - (y0f + t * dy);
            const cov = reach - @sqrt(ex * ex + ey * ey);
            if (cov <= 0) continue;
            blendPixel(pixels, @intCast(r), @intCast(c), stride, format, ink, cov);
        }
    }
}

/// Coverage is the box/pixel intersection area, not its integer bounds.
/// Blend once so scoped alpha multiplies coverage once in both formats.
fn fillRect(
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
    ink: draw.Color,
    x0f: f32,
    x1f: f32,
    y0f: f32,
    y1f: f32,
) void {
    if (ink.a == 0) return;
    // `!(hi > lo)` and not `hi <= lo`: a NaN end is refused too, and the
    // `@intFromFloat` calls below would trap on one.
    if (!(x1f > x0f) or !(y1f > y0f)) return;
    const c0: i64 = @max(@as(i64, @intFromFloat(@floor(x0f))), 0);
    const c1: i64 = @min(@as(i64, @intFromFloat(@ceil(x1f))), @as(i64, @intCast(width)));
    const r0: i64 = @max(@as(i64, @intFromFloat(@floor(y0f))), 0);
    const r1: i64 = @min(@as(i64, @intFromFloat(@ceil(y1f))), @as(i64, @intCast(height)));
    if (c1 <= c0 or r1 <= r0) return;

    var r = r0;
    while (r < r1) : (r += 1) {
        // Every column in this row has the same vertical coverage.
        const share_y = axisShare(y0f, y1f, r);
        var c = c0;
        while (c < c1) : (c += 1) {
            const cov = axisShare(x0f, x1f, c) * share_y;
            blendPixel(pixels, @intCast(r), @intCast(c), stride, format, ink, cov);
        }
    }
}

/// Intersection length with one unit-width pixel.
inline fn axisShare(lo: f32, hi: f32, index: i64) f32 {
    const left: f32 = @floatFromInt(index);
    return @max(0.0, @min(hi, left + 1.0) - @max(lo, left));
}

// A RULE IS NOT A BOX OF WHOLE PIXELS. A 0.8pt vinculum is 2.1333px of ink
// at 192 dpi: two whole rows and 0.1333 of a third. Rounding the box out to
// whole pixels painted three whole rows — 1.125pt of ink for a 0.8pt rule,
// 40% too heavy, on every radical bar, fraction bar and overline the CPU
// backend drew, in both of its pixel formats.
test "rasterize: a 0.8pt rule paints 2.133px of ink, not three whole rows" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    // The real \sqrt{x} vinculum of the captured corpus, in the frame it was
    // captured in: `rect x=20 y=0 w=61.248886 h=0.8` inside an
    // 81.248886 x 24pt ink box, which at 192 dpi cuts the 218 x 65 pixel
    // buffer the CLI actually wrote for it.
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    try dl.add(.{ .rect = .{
        .x = 20,
        .y = 0,
        .w = 61.248886,
        .h = 0.8,
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .src_start = 0,
        .src_end = 1,
    } });
    dl.accInk(0, 0, 81.248886, 24);
    var mask = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 192, .format = .alpha8 });
    defer mask.deinit();
    var rgba = try rasterize(testing.allocator, &ctx, &dl, .{ .dpi = 192, .format = .rgba32 });
    defer rgba.deinit();
    try testing.expectEqual(@as(u32, 218), mask.width);
    try testing.expectEqual(@as(u32, 65), mask.height);

    // 61.248886pt of rule at 8/3 px per pt is 163.3304px of width, so rows 0
    // and 1 carry a whole row of it, row 2 carries the 0.13333 left over, and
    // row 3 — the frame's one-pixel bearing — carries none of it at all.
    const full_row: f32 = 163.3304;
    try testing.expectApproxEqAbs(full_row, rowInk(mask, 0), 0.5);
    try testing.expectApproxEqAbs(full_row, rowInk(mask, 1), 0.5);
    try testing.expectApproxEqAbs(full_row * 0.13333, rowInk(mask, 2), 0.5);
    try testing.expectEqual(@as(f32, 0), rowInk(mask, 3));
    // The rule as a whole is its own AREA in pixels, 348.4381. A box that
    // paints more than its area is painting a heavier rule than TeX asked
    // for, which is all this defect is.
    try testing.expectApproxEqAbs(@as(f32, 348.4381), totalInk(mask), 0.5);
    // Three rows carry ink, not four: the 0.13333 share of row 2 is real ink
    // that a fill rounding the row away would have dropped, and a fill
    // rounding it UP is what painted row 3 in the first place.
    try testing.expectEqual(@as(usize, 3), inkedRows(mask));

    // Both CPU formats are the same picture: every pixel's mask byte IS its
    // alpha byte, boundary rows included.
    for (0..@as(usize, rgba.height)) |y| {
        for (0..@as(usize, rgba.width)) |x| {
            try testing.expectEqual(inkByte(mask, x, y), inkByte(rgba, x, y));
        }
    }
}

// The share of a pixel an axis-aligned box covers is the product of its two
// axis shares, so a box edge INSIDE a pixel splits that pixel instead of
// rounding it away. [0.25, 3.25) x [0.5, 2.5) has the column shares
// 0.75, 1, 1, 0.25 and the row shares 0.5, 1, 0.5, and every one of those
// numbers is a byte a caller can see.
test "fillRect: a box edge inside a pixel splits that pixel's coverage" {
    const ink: draw.Color = .{ .r = 10, .g = 20, .b = 30, .a = 255 };
    var mask = [_]u8{0} ** 16;
    fillRect(&mask, 4, 4, 4, .alpha8, ink, 0.25, 3.25, 0.5, 2.5);
    // The middle row is the box's only whole row.
    try testing.expectEqualSlices(u8, &.{ 191, 255, 255, 64 }, mask[4..8]);
    // ... and each half row is exactly half of it.
    try testing.expectEqualSlices(u8, &.{ 96, 128, 128, 32 }, mask[0..4]);
    try testing.expectEqualSlices(u8, &.{ 96, 128, 128, 32 }, mask[8..12]);
    // Below the box and right of it the frame is untouched.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, mask[12..16]);
}

// A box that runs off the frame is CLIPPED to it, and a pixel it shares with
// an edge keeps only the part that is really inside. Nothing wraps to the
// far side, nothing outside the frame is touched, and a box with no area
// paints nothing.
test "fillRect: a box clipped by the frame paints only what is inside it" {
    const ink: draw.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    var mask = [_]u8{0} ** 16;
    // [-1.5, 1.5) x [-0.5, 1.5) in a 4 x 4 frame: column 0 lies wholly
    // inside it, column 1 keeps its left half, row 0 wholly inside, row 1 its
    // top half. The corner pixel the two partials share is a quarter of the
    // ink of a whole one.
    fillRect(&mask, 4, 4, 4, .alpha8, ink, -1.5, 1.5, -0.5, 1.5);
    try testing.expectEqualSlices(u8, &.{ 255, 128, 0, 0 }, mask[0..4]);
    try testing.expectEqualSlices(u8, &.{ 128, 64, 0, 0 }, mask[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, mask[8..12]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, mask[12..16]);

    // The far corner the same way: only the half of column 3 and the quarter
    // of row 0 that lie inside the box's own last pixel are painted.
    @memset(mask[0..], 0);
    fillRect(&mask, 4, 4, 4, .alpha8, ink, 3.5, 6.0, -0.25, 0.25);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 32 }, mask[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, mask[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, mask[8..12]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, mask[12..16]);

    // No area, wholly outside, and a degenerate axis: an empty rule is not a
    // rule, and none of these may touch the buffer.
    @memset(mask[0..], 0);
    fillRect(&mask, 4, 4, 4, .alpha8, ink, 2, 2, 0, 4);
    fillRect(&mask, 4, 4, 4, .alpha8, ink, -9, -5, 0, 4);
    fillRect(&mask, 4, 4, 4, .alpha8, ink, 0, 4, 9, 12);
    for (mask) |v| try testing.expectEqual(@as(u8, 0), v);
}

// The geometric share and the ink's alpha are ONE product: a pixel half
// covered by half-transparent ink is a quarter inked, not a half and not an
// eighth. Both formats take that same product, so the mask strength and the
// stored alpha stay the same number.
test "fillRect: translucent ink scales the geometric coverage exactly once" {
    const ink: draw.Color = .{ .r = 12, .g = 34, .b = 56, .a = 128 };
    var mask = [_]u8{0} ** 16;
    var rgba = [_]u8{0} ** 64;
    fillRect(&mask, 4, 4, 4, .alpha8, ink, 0.0, 4.0, 0.5, 2.5);
    fillRect(&rgba, 4, 4, 16, .rgba32, ink, 0.0, 4.0, 0.5, 2.5);
    for (0..3) |y| {
        // Rows 0 and 2 are half covered, row 1 is whole; the ink's own alpha
        // halves what each of them carries, once.
        const carried: u8 = if (y == 1) 128 else 64;
        try testing.expectEqual(carried, mask[y * 4 + 1]);
        try testing.expectEqualSlices(u8, &.{ 12, 34, 56, carried }, rgba[y * 16 + 4 ..][0..4]);
    }
    // ... and a fully covered pixel of a translucent rule carries the ink's
    // own alpha once: neither doubled nor dropped.
    try testing.expectEqual(@as(u8, 128), mask[1 * 4 + 1]);
}

/// One decoded glyph outline, normalized once and reused by every placement
/// of that glyph id: an assembly repeats its extender, and a tall fence can
/// place the same piece a hundred times.
const CachedOutline = struct {
    /// Keyed by glyph id ALONE, which is only sound because the cache never
    /// outlives one item: a gid names a different shape in every face, and
    /// one item resolves all of its placements against ONE face. See
    /// `GlyphScratch.releaseOutlines`, which is what upholds it.
    glyph: u32,
    /// Normalized, in FONT units. Never transformed in place — each
    /// placement transforms its own copy into the item's contour list.
    curves: std.ArrayList(font.QuadCurve) = .empty,
};

/// Where one placement's CLIPPED contours sit in `GlyphScratch.contours`, and
/// the pixel extent they actually cover. The extents bound the control
/// points, which is what bounds a curve, so a placement that cannot reach a
/// scan line is left out of that line's sweep.
const PlacementSpan = struct {
    first: u32,
    last: u32,
    y_lo: f32,
    y_hi: f32,
    x_lo: f32,
    x_hi: f32,
};

/// Buffers reused by every glyph in one frame: the decoded outlines, the
/// transformed and clipped contour lists, the placement index, the connector
/// cuts, and two rows of coverage. Nothing here is per part and nothing is
/// per pixel — a fence of a hundred parts decodes three distinct outlines and
/// allocates nothing once the first item has warmed them.
const GlyphScratch = struct {
    gpa: std.mem.Allocator,
    outlines: std.ArrayList(CachedOutline) = .empty,
    /// One placement's transformed contours, before clipping. Reused per
    /// placement, so it holds one part, never the whole stack.
    raw: std.ArrayList(coverage.QuadCurve) = .empty,
    /// The other side of the clip ping-pong, so a second cut reads the first
    /// cut's output instead of the untouched outline.
    clipped: std.ArrayList(coverage.QuadCurve) = .empty,
    /// Every placement's contours, transformed AND clipped to its own band.
    contours: std.ArrayList(coverage.QuadCurve) = .empty,
    parts: std.ArrayList(PlacementSpan) = .empty,
    /// Each placement's ink extent along the axis the stack grows on, in
    /// buffer pixels; the connector cuts are the midpoints of the overlaps
    /// between neighbours.
    extents: std.ArrayList([2]f32) = .empty,
    /// `extents.len + 1` cut planes; the first is -inf and the last +inf, so
    /// the outermost placements are clipped on one side only.
    cuts: std.ArrayList(f32) = .empty,
    /// Coverage accumulated across the placements, and one placement's own
    /// sweep before it is added in.
    row: std.ArrayList(f32) = .empty,
    one_row: std.ArrayList(f32) = .empty,

    fn deinit(self: *GlyphScratch) void {
        self.releaseOutlines();
        self.outlines.deinit(self.gpa);
        self.raw.deinit(self.gpa);
        self.clipped.deinit(self.gpa);
        self.contours.deinit(self.gpa);
        self.parts.deinit(self.gpa);
        self.extents.deinit(self.gpa);
        self.cuts.deinit(self.gpa);
        self.row.deinit(self.gpa);
        self.one_row.deinit(self.gpa);
    }

    /// `glyph`'s decoded, normalized outline, decoded on this item's first
    /// use. The returned slice is invalidated by the next call for a
    /// DIFFERENT glyph id (the cache may grow), so a caller transforms its
    /// copy before asking again.
    fn outline(self: *GlyphScratch, face: *font.FontFace, glyph_id: u32) ![]const font.QuadCurve {
        for (self.outlines.items) |*cached| {
            if (cached.glyph == glyph_id) return cached.curves.items;
        }
        var decoded = try face.glyphOutline(self.gpa, glyph_id);
        errdefer decoded.deinit();
        normalizeWinding(decoded.curves.items);
        try self.outlines.append(self.gpa, .{ .glyph = glyph_id, .curves = decoded.curves });
        return self.outlines.items[self.outlines.items.len - 1].curves.items;
    }

    /// Drop every decoded outline, keeping the cache's own capacity for the
    /// next item. This is what makes the gid-only key above sound: a glyph
    /// id names a different shape in a different face, so nothing decoded
    /// against one item's face may survive into the next item's.
    ///
    /// The outlines are the only per-item allocation the fill makes; every
    /// other buffer here keeps its capacity for the rest of the frame.
    fn releaseOutlines(self: *GlyphScratch) void {
        for (self.outlines.items) |*cached| cached.curves.deinit(self.gpa);
        self.outlines.clearRetainingCapacity();
    }
};

/// Reverse every contour run so the sweep — whose signed area fills the
/// interior to the RIGHT of travel — paints this font's shapes, which CFF and
/// Latin Modern wind the other way. The reversal is uniform over the whole
/// outline, which is what keeps a COUNTER subtracting from its own solid:
/// outer and inner keep opposite senses and nonzero winding leaves the
/// counter empty. Every placement normalizes the same way, so two parts that
/// overlap ADD — the property the union sweep below is built on.
fn normalizeWinding(curves: []font.QuadCurve) void {
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < curves.len) : (i += 1) {
        const at_end = i + 1 == curves.len;
        const boundary = !at_end and (curves[i].p2[0] != curves[i + 1].p0[0] or
            curves[i].p2[1] != curves[i + 1].p0[1]);
        if (!at_end and !boundary) continue;

        var lo = run_start;
        var hi = i;
        while (lo < hi) : ({
            lo += 1;
            hi -= 1;
        }) {
            const tmp = curves[lo];
            curves[lo] = .{ .p0 = curves[hi].p2, .p1 = curves[hi].p1, .p2 = curves[hi].p0 };
            curves[hi] = .{ .p0 = tmp.p2, .p1 = tmp.p1, .p2 = tmp.p0 };
        }
        if (lo == hi) {
            const c = curves[lo];
            curves[lo] = .{ .p0 = c.p2, .p1 = c.p1, .p2 = c.p0 };
        }
        run_start = i + 1;
    }
}

/// Which side of a cut plane a clip keeps. The plane is perpendicular to
/// `axis` (0 = x, 1 = y), so this reads as "keeps what is above/below" on a
/// vertical stack and "right of / left of" on a horizontal one.
const Half = enum { greater, less };

inline fn along(p: [2]f32, axis: usize) f32 {
    return if (axis == 0) p[0] else p[1];
}

/// The parameter in (0,1) where a MONOTONIC quadratic crosses `cut` along
/// `axis`, or null when it does not cross inside the span. Monotonicity is
/// what makes this unambiguous: the piece crosses at most once, so there is
/// never a choice between two roots and never a tangent double root whose
/// small numerical error would spawn a spurious piece.
///
/// The roots come from the numerically STABLE pairing — q = −(qb ± √disc)/2,
/// then t = q/qa and t = qc/q — never from `(−qb ± √disc) / 2qa`. In that
/// form, when √disc ≈ qb the two terms cancel and a crossing that is nearly
/// linear (qa → 0, which is exactly what a straight edge in a font outline
/// gives) computes to plain zero, so the clip silently drops that piece and
/// punches a hole in the glyph. Here the cancellation is confined to the root
/// that is not needed.
fn crossT(c: coverage.QuadCurve, axis: usize, cut: f32) ?f32 {
    const a0 = along(c.p0, axis);
    const a1 = along(c.p1, axis);
    const a2 = along(c.p2, axis);
    const qa = a0 - 2.0 * a1 + a2;
    const qb = 2.0 * (a1 - a0);
    const qc = a0 - cut;
    if (@abs(qa) < 1e-9) {
        if (@abs(qb) < 1e-12) return null;
        const t = -qc / qb;
        return if (t > 0 and t < 1) t else null;
    }
    const disc = qb * qb - 4.0 * qa * qc;
    if (disc < 0) return null;
    const root = @sqrt(disc);
    // The root that WOULD cancel is the one built from the same sign as qb.
    const q = -0.5 * (qb + if (qb >= 0) root else -root);
    const t1 = q / qa;
    if (t1 > 0 and t1 < 1) return t1;
    if (q != 0) {
        const t2 = qc / q;
        if (t2 > 0 and t2 < 1) return t2;
    }
    return null;
}

/// Split a quadratic at `t` by de Casteljau. Direction is preserved, so a
/// clipped piece winds exactly like the curve it came from — which is what
/// keeps the run's outer and counter contours opposite after a clip.
fn splitAt(c: coverage.QuadCurve, t: f32) [2]coverage.QuadCurve {
    const lerp = struct {
        fn f(a: [2]f32, b: [2]f32, k: f32) [2]f32 {
            return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k };
        }
    }.f;
    const a = lerp(c.p0, c.p1, t);
    const b = lerp(c.p1, c.p2, t);
    const m = lerp(a, b, t);
    return .{
        .{ .p0 = c.p0, .p1 = a, .p2 = m },
        .{ .p0 = m, .p1 = b, .p2 = c.p2 },
    };
}

/// A straight run between two points on the cut, as a degenerate quadratic:
/// what closes a clipped chain back into a loop. Font outlines store straight
/// edges exactly this way (p1 at the midpoint), so the closing edge is
/// indistinguishable from any other line in the outline.
fn segment(a: [2]f32, b: [2]f32) coverage.QuadCurve {
    return .{
        .p0 = a,
        .p1 = .{ (a[0] + b[0]) / 2, (a[1] + b[1]) / 2 },
        .p2 = b,
    };
}

/// Whether two points are the same point to within a rounding step. A clip
/// splits a curve at a computed parameter, so the endpoint it produces and the
/// endpoint of the piece next to it are the SAME expression evaluated twice —
/// bit-identical in principle, but the tolerance keeps a clip from inserting
/// a zero-length (or sliver) closing edge where none is wanted.
fn samePoint(a: [2]f32, b: [2]f32) bool {
    return @abs(a[0] - b[0]) < 1e-6 and @abs(a[1] - b[1]) < 1e-6;
}

/// Margin-free pixel coordinates keep clipping and coverage decisions stable.
/// Adding integer padding before f32 second differences can flip a crossing;
/// the margin belongs only in the final output index.
const ItemFrame = struct {
    t: draw.Text,
    pt_to_px: f32,
    /// Canvas height excluding both padding margins, independent of padding.
    frame_h: f32,
    origin: Origin,
    /// Font units → frame pixels.
    gscale: f32,

    /// A part's origin. `Draw.Text.y` grows DOWN and the frame's y grows
    /// with it, so a part's Y-UP run above the run's baseline moves its
    /// origin UP — the same single rise `svg.zig` applies to the same outline.
    fn originX(self: ItemFrame, part: glyph.Placed) f32 {
        return (self.t.x + self.origin.x + part.x_em * self.t.size) * self.pt_to_px;
    }

    fn originY(self: ItemFrame, part: glyph.Placed) f32 {
        return self.frame_h - (self.t.y + self.origin.y) * self.pt_to_px +
            part.y_em * self.t.size * self.pt_to_px;
    }
};

/// ONE LOGICAL GLYPH, filled as one piece of ink.
///
/// This is NOT a nonzero fill of the whole compound path. `coverageRow` sums
/// the signed areas of the curves it is handed and clamps the sum to [0, 1],
/// which is the true coverage only while the winding number stays at 0 or 1.
/// Feed it overlapping parts and the shared zone carries winding 2, so the sum
/// is twice the ink there, and a half-covered shared edge saturates to a full,
/// hard edge that no other edge in the picture has.
///
/// So the stack is cut GEOMETRICALLY first. Each placement's transformed
/// contours are clipped to its own band — the connector between two
/// neighbours is split at its mid-plane, and the clip is a real half-plane
/// clip that closes the run along the cut (`clipTo`), not a per-pixel
/// ownership rule. The clipped parts are then DISJOINT, so:
///
///   * every individual sweep sees winding ≤ 1, and the kernel's clamp is
///     that part's exact coverage;
///   * the parts' coverages are ADDED across a pixel that several of them
///     reach, and since they are disjoint the sum is exactly the union's
///     coverage — 0.5 where two half-covered edges coincide, not the 1.0 a
///     clamped sum would report;
///   * the ink is composited ONCE, after the sum, so a join can never apply
///     the alpha twice the way filling each part into the buffer on its own
///     did, and a translucent `\left(` loses its dark seams.
///
/// Rounding the cut to a pixel boundary and giving each pixel to one owner
/// does NOT work, and is not used: when the connector is thinner than a pixel
/// (LM's MinConnectorOverlap is 0.02em, about a fifth of a pixel at 8pt/96dpi)
/// the whole straddled pixel would go to one part and the other part's share
/// of it — up to 0.4 of a pixel of real ink — would be lost. Clipping keeps
/// both shares, in the same pixel, as the sum they are.
const GlyphItem = struct {
    scratch: *GlyphScratch,
    frame: ItemFrame,
    face: *font.FontFace,
    min_x: f32 = std.math.inf(f32),
    max_x: f32 = -std.math.inf(f32),
    min_y: f32 = std.math.inf(f32),
    max_y: f32 = -std.math.inf(f32),
    bar: ?struct { x0: f32, x1: f32, y0: f32, y1: f32 } = null,

    /// Pass one: the ink extent of one placement ALONG the growth axis, which
    /// is all the connector cuts need. Nothing is stored but two numbers.
    ///
    /// A placement with no ink records a degenerate extent AT ITS ORIGIN
    /// rather than skipping, so this pass and `place` agree on how many
    /// placements there are and a later placement's index still names its own
    /// band. A blank glyph is a malformed assembly, not a normal one, but a
    /// misaligned index would silently clip a real neighbour.
    fn measure(self: *GlyphItem, part: glyph.Placed, axis: usize) !void {
        const curves = try self.scratch.outline(self.face, part.glyph);
        const x0 = self.frame.originX(part);
        const y0 = self.frame.originY(part);
        const scale = self.frame.gscale;
        if (curves.len == 0) {
            const at = if (axis == 0) x0 else y0;
            try self.scratch.extents.append(self.scratch.gpa, .{ at, at });
            return;
        }
        var lo: f32 = std.math.inf(f32);
        var hi: f32 = -std.math.inf(f32);
        for (curves) |c| {
            for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
                const v = if (axis == 0) x0 + p[0] * scale else y0 + p[1] * scale;
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
        }
        try self.scratch.extents.append(self.scratch.gpa, .{ lo, hi });
    }

    /// The cut planes: one per connector, at the mid-plane of the material
    /// the two neighbours share, bounded by -inf and +inf at the ends. Two
    /// placements that share nothing get the midpoint of the gap between
    /// them, which is where no part inks anyway.
    fn planCuts(self: *GlyphItem) std.mem.Allocator.Error!void {
        const gpa = self.scratch.gpa;
        self.scratch.cuts.clearRetainingCapacity();
        // The count is known BEFORE a single cut is written: one per
        // connector plus the two open ends. Reserving it up front means the
        // fills cannot fail, so an allocation error leaves the list EMPTY
        // rather than a prefix of the cuts — a prefix would clip later parts
        // against planes that belong to other parts and tear the stack.
        try self.scratch.cuts.ensureTotalCapacityPrecise(gpa, self.scratch.extents.items.len + 1);
        self.scratch.cuts.appendAssumeCapacity(-std.math.inf(f32));
        const extents = self.scratch.extents.items;
        for (1..extents.len) |i| {
            self.scratch.cuts.appendAssumeCapacity((extents[i - 1][1] + extents[i][0]) / 2);
        }
        self.scratch.cuts.appendAssumeCapacity(std.math.inf(f32));
    }

    /// Pass two: transform one placement into frame space and clip it to
    /// the band between its two cuts. The clipped contours are appended to
    /// `contours`, and the span records what they cover.
    fn place(
        self: *GlyphItem,
        part: glyph.Placed,
        index: usize,
        axis: usize,
    ) !void {
        const gpa = self.scratch.gpa;
        const curves = try self.scratch.outline(self.face, part.glyph);
        if (curves.len == 0) {
            // A blank glyph paints nothing, but it still occupies its slot so
            // the placement indices match `measure`'s.
            const at = self.scratch.contours.items.len;
            try self.scratch.parts.append(gpa, .{
                .first = @intCast(at),
                .last = @intCast(at),
                .y_lo = std.math.inf(f32),
                .y_hi = -std.math.inf(f32),
                .x_lo = std.math.inf(f32),
                .x_hi = -std.math.inf(f32),
            });
            return;
        }
        const x0 = self.frame.originX(part);
        const y0 = self.frame.originY(part);
        const scale = self.frame.gscale;

        self.scratch.raw.clearRetainingCapacity();
        try self.scratch.raw.ensureUnusedCapacity(gpa, curves.len);
        var rightmost: f32 = -std.math.inf(f32);
        for (curves) |c| {
            const mapped: coverage.QuadCurve = .{
                .p0 = .{ x0 + c.p0[0] * scale, y0 + c.p0[1] * scale },
                .p1 = .{ x0 + c.p1[0] * scale, y0 + c.p1[1] * scale },
                .p2 = .{ x0 + c.p2[0] * scale, y0 + c.p2[1] * scale },
            };
            self.scratch.raw.appendAssumeCapacity(mapped);
            if (self.bar != null) {
                rightmost = @max(rightmost, @max(mapped.p0[0], @max(mapped.p1[0], mapped.p2[0])));
            }
        }

        // Clipping is a ping-pong between `raw` and `clipped`, so the second
        // cut sees the first one's output rather than the untouched outline.
        const cuts = self.scratch.cuts.items;
        var source: []const coverage.QuadCurve = self.scratch.raw.items;
        var sink = &self.scratch.clipped;
        const upper = cuts[index + 1];
        if (std.math.isFinite(upper)) {
            try self.clipTo(source, sink, axis, upper, .less);
            source = sink.items;
            sink = &self.scratch.raw;
            sink.clearRetainingCapacity();
        }
        const lower = cuts[index];
        if (std.math.isFinite(lower)) {
            try self.clipTo(source, sink, axis, lower, .greater);
            source = sink.items;
            sink = if (sink == &self.scratch.raw) &self.scratch.clipped else &self.scratch.raw;
        }
        const first: u32 = @intCast(self.scratch.contours.items.len);
        if (self.bar) |bar| {
            if (rightmost > bar.x0) {
                // Remove the covered cap span, not a tail beyond a narrow
                // vinculum. The retained ink and rule have disjoint areas.
                try self.clipTo(source, sink, 0, bar.x0, .less);
                try self.scratch.contours.appendSlice(gpa, sink.items);
                if (rightmost > bar.x1) {
                    try self.clipTo(source, sink, 0, bar.x1, .greater);
                    try self.scratch.contours.appendSlice(gpa, sink.items);
                }
            } else {
                try self.scratch.contours.appendSlice(gpa, source);
            }
        } else {
            try self.scratch.contours.appendSlice(gpa, source);
        }
        var span: PlacementSpan = .{
            .first = first,
            .last = @intCast(self.scratch.contours.items.len),
            .y_lo = std.math.inf(f32),
            .y_hi = -std.math.inf(f32),
            .x_lo = std.math.inf(f32),
            .x_hi = -std.math.inf(f32),
        };
        for (self.scratch.contours.items[span.first..span.last]) |c| {
            span.y_lo = @min(span.y_lo, @min(c.p0[1], @min(c.p1[1], c.p2[1])));
            span.y_hi = @max(span.y_hi, @max(c.p0[1], @max(c.p1[1], c.p2[1])));
            span.x_lo = @min(span.x_lo, @min(c.p0[0], @min(c.p1[0], c.p2[0])));
            span.x_hi = @max(span.x_hi, @max(c.p0[0], @max(c.p1[0], c.p2[0])));
        }
        // Recorded even when the band held no ink, so `parts` has exactly one
        // entry per placement and the sweep's index walk stays aligned with
        // `cuts`. An empty span simply never reaches a scan line.
        if (span.first != span.last) {
            self.min_y = @min(self.min_y, span.y_lo);
            self.max_y = @max(self.max_y, span.y_hi);
            self.min_x = @min(self.min_x, span.x_lo);
            self.max_x = @max(self.max_x, span.x_hi);
        }
        try self.scratch.parts.append(gpa, span);
    }

    /// Clip every contour run of `src` to the half-plane at `cut` along
    /// `axis`, appending the clipped runs to `out`. Contour breaks are
    /// preserved — a run is clipped on its own — so a glyph's counter stays a
    /// counter instead of being welded to its outer contour.
    fn clipTo(
        self: *GlyphItem,
        src: []const coverage.QuadCurve,
        out: *std.ArrayList(coverage.QuadCurve),
        axis: usize,
        cut: f32,
        half: Half,
    ) !void {
        out.clearRetainingCapacity();
        var run_start: usize = 0;
        var i: usize = 0;
        while (i < src.len) : (i += 1) {
            const at_end = i + 1 == src.len;
            const boundary = !at_end and (src[i].p2[0] != src[i + 1].p0[0] or
                src[i].p2[1] != src[i + 1].p0[1]);
            if (!at_end and !boundary) continue;
            try self.clipRun(src[run_start .. i + 1], out, axis, cut, half);
            run_start = i + 1;
        }
    }

    /// Clip one closed contour run. Each curve is split at its coordinate
    /// extrema first (`coverage.monotonicize`), so every piece is monotonic
    /// along `axis` and crosses the cut at most once — that is what keeps the
    /// root search unambiguous and free of tangent double roots.
    fn clipRun(
        self: *GlyphItem,
        run: []const coverage.QuadCurve,
        out: *std.ArrayList(coverage.QuadCurve),
        axis: usize,
        cut: f32,
        half: Half,
    ) !void {
        const gpa = self.scratch.gpa;
        // The kept chain's own first point and its current open end. The chain
        // closes back to that FIRST KEPT point at the end, not to the run's
        // original start: when the run's first curve is itself clipped away
        // the chain was cut open there, and joining it to a point that no
        // longer exists would draw a stray edge across the cut.
        var start: ?[2]f32 = null;
        var open: ?coverage.QuadCurve = null;

        for (run) |curve| {
            const mono = coverage.monotonicize(curve);
            for (mono.pieces[0..mono.n]) |piece| {
                const one = self.keptHalf(piece, axis, cut, half) orelse continue;
                if (open) |prev| {
                    // A gap means something between here and there was
                    // clipped away; both of its neighbours' ends sit on the
                    // cut, so a straight run along the cut closes the loop.
                    if (!samePoint(prev.p2, one.p0)) {
                        try out.append(gpa, segment(prev.p2, one.p0));
                    }
                } else {
                    start = one.p0;
                }
                try out.append(gpa, one);
                open = one;
            }
        }
        if (open) |last| {
            if (start) |s| {
                if (!samePoint(last.p2, s)) try out.append(gpa, segment(last.p2, s));
            }
        }
    }

    /// The part of one monotonic piece that lies in the kept half, or null
    /// when the piece lies entirely in the discarded half. Monotonicity makes
    /// the split point single, so there is no second candidate to choose
    /// between and no tangent double root to reject.
    fn keptHalf(
        self: *GlyphItem,
        piece: coverage.QuadCurve,
        axis: usize,
        cut: f32,
        half: Half,
    ) ?coverage.QuadCurve {
        _ = self;
        if (crossT(piece, axis, cut)) |t| {
            const halves = splitAt(piece, t);
            const at_lo = along(halves[0].p0, axis);
            const at_hi = along(halves[1].p2, axis);
            if (half == .greater) {
                if (at_hi >= cut) return halves[1];
                if (at_lo >= cut) return halves[0];
            } else {
                if (at_lo <= cut) return halves[0];
                if (at_hi <= cut) return halves[1];
            }
            return null;
        }
        const at = along(piece.p0, axis);
        if (if (half == .greater) at >= cut else at <= cut) return piece;
        return null;
    }
    /// Sum disjoint coverage and compose once; padding shifts output indices.
    fn sweep(
        self: *const GlyphItem,
        pixels: []u8,
        width: u32,
        height: u32,
        pad: u32,
        stride: u32,
        format: Format,
        ink: draw.Color,
    ) !void {
        if (self.scratch.parts.items.len == 0) return;
        const margin: i64 = @intCast(pad);
        const frame_w: i64 = @as(i64, @intCast(width)) - 2 * margin;
        const frame_h: i64 = @as(i64, @intCast(height)) - 2 * margin;
        var wy0: i64 = @intFromFloat(@floor(self.min_y));
        var wy1: i64 = @intFromFloat(@floor(self.max_y));
        if (wy0 >= frame_h + margin or wy1 < -margin) return;
        wy0 = @max(wy0, -margin);
        wy1 = @min(wy1, frame_h + margin - 1);

        var cx0: i64 = @intFromFloat(@floor(self.min_x));
        var cx1: i64 = @intFromFloat(@ceil(self.max_x));
        cx0 = @max(cx0, -margin);
        cx1 = @min(cx1, frame_w + margin);
        if (cx1 <= cx0) return;
        const ncols: usize = @intCast(cx1 - cx0);
        try self.scratch.row.resize(self.scratch.gpa, ncols);
        try self.scratch.one_row.resize(self.scratch.gpa, ncols);
        const total = self.scratch.row.items;
        const one = self.scratch.one_row.items;

        var wy = wy0;
        while (wy <= wy1) : (wy += 1) {
            const y: f32 = @floatFromInt(wy);
            @memset(total, 0);
            // The placements whose clipped ink can reach this line. They are
            // disjoint by construction, so adding their coverages gives the
            // union's coverage for this line, with no pixel counted twice.
            for (self.scratch.parts.items) |part| {
                if (part.y_hi <= y or part.y_lo >= y + 1.0) continue;
                coverage.coverageRow(
                    self.scratch.contours.items[part.first..part.last],
                    y,
                    @floatFromInt(cx0),
                    one,
                );
                for (total, one) |*acc, cov| acc.* += cov;
            }
            if (self.bar) |bar| {
                const share_y = axisShare(bar.y0, bar.y1, wy);
                if (share_y > 0) {
                    for (total, 0..) |*cov, k| {
                        const column = cx0 + @as(i64, @intCast(k));
                        cov.* += axisShare(bar.x0, bar.x1, column) * share_y;
                    }
                }
            }
            const row: usize = @intCast(frame_h - 1 - wy + margin);
            for (total, 0..) |raw_cov, k| {
                const cov = @min(1.0, @max(0.0, raw_cov));
                if (cov <= 0.0) continue;
                blendPixel(
                    pixels,
                    row,
                    @as(usize, @intCast(cx0 + margin)) + k,
                    stride,
                    format,
                    ink,
                    cov,
                );
            }
        }
    }
};

fn drawGlyph(
    scratch: *GlyphScratch,
    ctx: *context.Context,
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    format: Format,
    ink: draw.Color,
    t: draw.Text,
    pt_to_px: f32,
    pad: u32,
    origin: Origin,
) !void {
    if (ink.a == 0) return;
    const request = requestOf(t) orelse return;

    // Every stretchy item resolves through the face's own MATH table (see
    // `ztex.glyph.plan`): a glyph id is font-specific, so baking one in
    // draws the wrong shape on every font but Latin Modern — and a fence
    // taller than its whole ladder is a STACK of parts, not one glyph.
    // Same rule as svg.zig: a stretchy item is a MATH construction whatever
    // style it was typed in, so `\mathrm{\sqrt{x}}` draws the math font's
    // radical — the style's face has no ladder, and its plain U+221A is a
    // short mark with a detached bar. An ORDINARY item asks for the face that
    // actually carries the codepoint, so a letter only the math face has
    // draws rather than coming out blank.
    const face = if (glyph.needsGeometry(request))
        ctx.fonts.math
    else
        ctx.fonts.faceForCodepoint(request.cp, t.style);
    var built = (try glyph.plan(scratch.gpa, face, request)) orelse return;

    // An ORDINARY item's one placement is the glyph the size resolves to
    // (`font.resolvedGlyphId`): the prime composites paint the face's
    // unencoded alternates at script size, exactly the glyph layout measured
    // and svg.zig drew. A stretchy item is never one — its placements come
    // from the face's own MATH constructions, and a construction that names a
    // prime is not a thing this font builds.
    if (!glyph.needsGeometry(request)) {
        if (font.resolvedGlyphId(face, request.cp, t.size)) |gid| {
            if (built == .single) built.single.glyph = gid;
        }
    }

    // The scratch is the frame's, reused by every item; only its contents
    // are this item's. The decoded outlines are the one thing that cannot
    // be carried across, so they are released on the way out — on every
    // exit path, including a failed decode.
    defer {
        scratch.releaseOutlines();
        scratch.parts.clearRetainingCapacity();
        scratch.contours.clearRetainingCapacity();
        scratch.extents.clearRetainingCapacity();
    }

    // Subtract integer margins before conversion to keep glyph geometry stable.
    const frame_h: f32 = @floatFromInt(height - 2 * pad);
    var fill: GlyphItem = .{
        .scratch = scratch,
        .face = face,
        .frame = .{
            .t = t,
            .pt_to_px = pt_to_px,
            .frame_h = frame_h,
            .origin = origin,
            .gscale = t.size * pt_to_px /
                @as(f32, @floatCast(@as(f64, @floatFromInt(face.unitsPerEm())))),
        },
    };
    if (t.radical_bar) |bar| {
        const x0 = (t.x + origin.x + bar.x) * pt_to_px;
        const x1 = x0 + bar.w * pt_to_px;
        const y1 = frame_h - (t.y + origin.y + bar.y) * pt_to_px;
        const y0 = y1 - bar.h * pt_to_px;
        if (!std.math.isFinite(x0) or !std.math.isFinite(x1) or
            !std.math.isFinite(y0) or !std.math.isFinite(y1))
            return error.NonFiniteCoordinate;
        if (x1 > x0 and y1 > y0) {
            fill.bar = .{ .x0 = x0, .x1 = x1, .y0 = y0, .y1 = y1 };
            fill.min_x = x0;
            fill.max_x = x1;
            fill.min_y = y0;
            fill.max_y = y1;
        }
    }
    // A single glyph overlaps nothing, so its axis never matters; a stack
    // says which way it grows, and that is the axis it is cut on.
    var axis: glyph.Axis = .vertical;
    switch (built) {
        .single => {},
        .stack => |copy| axis = copy.axis,
    }
    const axis_index: usize = if (axis == .horizontal) 0 else 1;

    // TWO PASSES over the placements. The first records each one's ink extent
    // along the growth axis; the second transforms and clips it against the
    // cuts those extents imply. Both walks visit the placements in the same
    // order the SVG serializer emits them, and both record one entry per
    // placement — including a blank one, whose empty span simply paints
    // nothing — so a placement's index is the same in both passes.
    const measure_walk = built;
    switch (measure_walk) {
        .single => |part| try fill.measure(part, axis_index),
        .stack => |copy| {
            var stack = copy;
            while (stack.next()) |part| try fill.measure(part, axis_index);
        },
    }
    try fill.planCuts();

    const place_walk = built;
    var index: usize = 0;
    switch (place_walk) {
        .single => |part| try fill.place(part, index, axis_index),
        .stack => |copy| {
            var stack = copy;
            while (stack.next()) |part| {
                try fill.place(part, index, axis_index);
                index += 1;
            }
        },
    }
    try fill.sweep(pixels, width, height, pad, stride, format, ink);
}

/// The width in points of a bare `\prime`'s painted mark, from the alpha mask
/// alone: the columns carrying any coverage. The dpi is high enough that a
/// script-size mark is a dozen pixels across.
fn paintedWidthPt(ctx: *context.Context, src: []const u8, size: f32) !f32 {
    const dpi: f32 = 600;
    var buffer = try ctx.renderPixels(src, .display, size, .{ .dpi = dpi, .format = .alpha8 }, null);
    defer buffer.deinit();
    var columns: u32 = 0;
    var x: u32 = 0;
    while (x < buffer.width) : (x += 1) {
        var y: u32 = 0;
        while (y < buffer.height) : (y += 1) {
            if (buffer.pixels[y * buffer.stride + x] == 0) continue;
            columns += 1;
            break;
        }
    }
    return @as(f32, @floatFromInt(columns)) * 72.0 / dpi;
}

test "raster: the painted prime crosses the script gate with its glyph" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    // A bare `\prime` is drawn at the size it is typed at, so the gate alone
    // decides which composite is painted: below it the face's unencoded
    // alternate, whose single mark is far wider than the cmap's composite's.
    // Same face, same ink rows, drawn sizes half a point apart.
    const below = try paintedWidthPt(&ctx, "\\prime", 5.5);
    const above = try paintedWidthPt(&ctx, "\\prime", 6.5);
    try testing.expect(below > above * 1.2);
}
