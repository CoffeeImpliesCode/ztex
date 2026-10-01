//! ztex.raster — CPU coverage rasterizer for math draw lists.
//!
//! Produces pixel buffers from a `draw.DrawList` using analytic quadratic Bézier
//! scanline coverage (`coverage.zig`) and exact rectangle/line fills.
//! Supports customizable resolution (DPI), scale, foreground/background colors,
//! and pixel formats (RGBA8888, Alpha8).

const std = @import("std");
const context = @import("context.zig");
const coverage = @import("coverage.zig");
const layout = @import("ztex.layout");
const draw = layout.draw;
const atom = @import("ztex.atom");
const font = @import("font.zig");

pub const Format = enum {
    /// 32-bit RGBA (R, G, B, A in byte order)
    rgba32,
    /// 8-bit coverage mask (1 byte per pixel: 0 = transparent, 255 = fully inked)
    alpha8,
};

pub const Options = struct {
    /// Target resolution in DPI (dots per inch). Standard web/screen is 96.0; print is 300.0+.
    dpi: f32 = 96.0,
    /// Additional uniform scale factor.
    scale: f32 = 1.0,
    /// Padding around the content in pixels.
    padding: u32 = 0,
    /// Output pixel format.
    format: Format = .rgba32,
    /// Foreground ink color (used when format is .rgba32). Default is black (#000000FF).
    fg: draw.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    /// Background color (used when format is .rgba32; null = fully transparent).
    bg: ?draw.Color = null,
};

/// A rasterized pixel buffer owned by the caller.
pub const PixelBuffer = struct {
    gpa: std.mem.Allocator,
    /// Pixel payload. For rgba32, length is width * height * 4. For alpha8, width * height.
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    format: Format,

    pub fn deinit(self: *PixelBuffer) void {
        self.gpa.free(self.pixels);
        self.* = undefined;
    }

    /// Write buffer as a binary Netpbm image: PPM (P6) for rgba32, PGM (P5) for alpha8.
    pub fn writePnm(self: *const PixelBuffer, io: std.Io, file: std.Io.File) !void {
        var hdr_buf: [64]u8 = undefined;
        switch (self.format) {
            .rgba32 => {
                const hdr = try std.fmt.bufPrint(&hdr_buf, "P6\n{d} {d}\n255\n", .{ self.width, self.height });
                try file.writeStreamingAll(io, hdr);
                var row_buf: [4096 * 3]u8 = undefined;
                for (0..self.height) |y| {
                    const row = self.pixels[y * self.stride .. (y + 1) * self.stride];
                    var x: usize = 0;
                    while (x < self.width) {
                        const chunk: usize = @min(self.width - x, row_buf.len / 3);
                        for (0..chunk) |i| {
                            const src_px = row[(x + i) * 4 .. (x + i) * 4 + 3];
                            @memcpy(row_buf[i * 3 .. i * 3 + 3], src_px);
                        }
                        try file.writeStreamingAll(io, row_buf[0 .. chunk * 3]);
                        x += chunk;
                    }
                }
            },
            .alpha8 => {
                const hdr = try std.fmt.bufPrint(&hdr_buf, "P5\n{d} {d}\n255\n", .{ self.width, self.height });
                try file.writeStreamingAll(io, hdr);
                try file.writeStreamingAll(io, self.pixels);
            },
        }
    }
};

const testing = std.testing;

test "PixelBuffer.writePnm writes wide RGBA rows" {
    for ([_]u32{ 2730, 2731, 4099 }) |width| {
        const width_usize: usize = width;
        const stride = width * 4;
        var header_buffer: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} 1\n255\n", .{width});

        const pixels = try testing.allocator.alloc(u8, width_usize * 4);
        var pixel_buffer: PixelBuffer = .{
            .gpa = testing.allocator,
            .pixels = pixels,
            .width = width,
            .height = 1,
            .stride = stride,
            .format = .rgba32,
        };
        defer pixel_buffer.deinit();

        const expected = try testing.allocator.alloc(u8, header.len + width_usize * 3);
        defer testing.allocator.free(expected);
        @memcpy(expected[0..header.len], header);
        for (0..width_usize) |x| {
            const rgb = [3]u8{
                @truncate(x),
                @truncate(x >> 4),
                @truncate(x >> 8),
            };
            const pixel_offset = x * 4;
            pixels[pixel_offset] = rgb[0];
            pixels[pixel_offset + 1] = rgb[1];
            pixels[pixel_offset + 2] = rgb[2];
            pixels[pixel_offset + 3] = 0xa5;

            const pnm_offset = header.len + x * 3;
            expected[pnm_offset] = rgb[0];
            expected[pnm_offset + 1] = rgb[1];
            expected[pnm_offset + 2] = rgb[2];
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
}

/// Where the draw list's ink origin (x = 0, y = the ink top) lands in the
/// buffer, in points: the negative of the ink minimum, i.e. the same shift
/// svg.zig applies to its viewBox origin. Applied before the pt→px scale and
/// the pixel padding, so the two back ends frame the same content.
const Origin = struct {
    x: f32,
    y: f32,
};

/// Rasterize a draw list using the font context's embedded/cached fonts.
pub fn rasterize(
    gpa: std.mem.Allocator,
    ctx: *context.Context,
    dl: *const draw.DrawList,
    opts: Options,
) !PixelBuffer {
    const pt_to_px = (opts.dpi / 72.0) * opts.scale;
    const pad = opts.padding;

    // Same basis as svg.zig's viewBox: the INK bounds, so a PNG and an SVG of
    // one draw list cover the same content. `padding` and the 1px bearing
    // below stay in pixels, as before.
    const ink = dl.bounds();
    const origin = Origin{ .x = -ink.min_x, .y = -ink.min_y };
    const content_w = @max(1.0, ink.width * pt_to_px);
    const content_h = @max(1.0, (ink.height + ink.depth) * pt_to_px);
    // Add 1px minimum bearing headroom to prevent subpixel antialiasing clamp at row 0
    const width = @as(u32, @intFromFloat(@ceil(content_w))) + 2 * pad + 1;
    const height = @as(u32, @intFromFloat(@ceil(content_h))) + 2 * pad + 1;
    const bytes_per_pixel: u32 = if (opts.format == .rgba32) 4 else 1;
    const stride = width * bytes_per_pixel;
    const total_bytes = @as(usize, height) * @as(usize, stride);

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

    for (dl.items.items) |d| {
        switch (d) {
            .text => |t| {
                try drawGlyph(
                    gpa,
                    ctx,
                    pixels,
                    width,
                    height,
                    stride,
                    opts,
                    t,
                    pt_to_px,
                    pad_f,
                    origin,
                );
            },
            .rect => |r| {
                const x0 = pad_f + (r.x + origin.x) * pt_to_px;
                const x1 = pad_f + (r.x + r.w + origin.x) * pt_to_px;
                const y0 = pad_f + (r.y + origin.y) * pt_to_px;
                const y1 = pad_f + (r.y + r.h + origin.y) * pt_to_px;
                fillRect(pixels, width, height, stride, opts, x0, x1, y0, y1);
            },
            .line => |l| {
                const half = 0.5 * l.width;
                const x0 = pad_f + (@min(l.x0, l.x1) - half + origin.x) * pt_to_px;
                const x1 = pad_f + (@max(l.x0, l.x1) + half + origin.x) * pt_to_px;
                const y0 = pad_f + (@min(l.y0, l.y1) - half + origin.y) * pt_to_px;
                const y1 = pad_f + (@max(l.y0, l.y1) + half + origin.y) * pt_to_px;
                fillRect(pixels, width, height, stride, opts, x0, x1, y0, y1);
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

test "rasterize: \\mathbf draws the bold face, not the regular one" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();

    // \mathbf used to resolve to the same face as \text, so \mathbf{x} and
    // \text{x} rasterized identically — the SVG said bold, the bitmap did
    // not. Compare the two at the same size: a real bold face puts down
    // noticeably more ink for the same glyph.
    const inkOf = struct {
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

    const bold = try inkOf(&ctx, "\\mathbf{x}");
    const roman = try inkOf(&ctx, "\\text{x}");
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

// The old rasterizer named 62 Latin Modern glyph ids literally: 4 big
// operators, 6 radical pieces and 52 fence rungs. Every one of them must
// come back out of the font's own MATH table unchanged, so the lookup is a
// pure substitution for those families. The ids live only here, as
// expectations — no draw path names a glyph.
test "resolveGlyph: the MATH table reproduces every former hardcoded glyph id" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const face = ctx.fonts.faceForStyle(.italic);

    // Display big operators: .v1 of each operator's own ladder.
    const bigops = [_]struct { cp: u21, text: []const u8, gid: u32 }{
        .{ .cp = 0x2211, .text = "\u{2211}", .gid = 3074 }, // ∑ summation.v1
        .{ .cp = 0x220F, .text = "\u{220F}", .gid = 3075 }, // ∏ product.v1
        .{ .cp = 0x222B, .text = "\u{222B}", .gid = 3063 }, // ∫ integral.v1
        .{ .cp = 0x222E, .text = "\u{222E}", .gid = 3067 }, // ∮ contourintegral.v1
        // The old switch named only the four above, so every other display
        // operator fell through to its BASE glyph — ∐, ⋃, ⋂, ⨆, ∯ and ∰
        // all have a .v1 the layout meant to draw.
        .{ .cp = 0x2210, .text = "\u{2210}", .gid = 3076 }, // ∐ coproduct.v1
        .{ .cp = 0x222F, .text = "\u{222F}", .gid = 3068 }, // ∯ contourint.v1
        .{ .cp = 0x2230, .text = "\u{2230}", .gid = 3069 }, // ∰ contouriint.v1
        .{ .cp = 0x22C3, .text = "\u{22C3}", .gid = 2768 }, // ⋃ nbigcup.v1
        .{ .cp = 0x22C2, .text = "\u{22C2}", .gid = 2766 }, // ⋂ nbigcap.v1
        .{ .cp = 0x2A06, .text = "\u{2A06}", .gid = 2793 }, // ⨆ bigsqcup.v1
    };
    for (bigops) |op| {
        var t = item(op.text, .italic);
        t.bigop_form = .variant;
        try testing.expectEqual(op.gid, resolveGlyph(face, op.cp, &t).?);
    }

    // The √ vertical variants radical.v1 … radical.v4.
    for ([_]u32{ 3081, 3082, 3083, 3084 }, 0..) |gid, rung| {
        var t = item("\u{221A}", .italic);
        t.radical_form = @intCast(rung + 1);
        try testing.expectEqual(gid, resolveGlyph(face, radical_cp, &t).?);
    }
    // The √ glyph ASSEMBLY's three pieces, bottom → extender → top. The old
    // switch named only the top two and let radical_form 7 reach the cmap's
    // U+23B7 — the same glyph in Latin Modern, but only by coincidence of
    // that font's numbering.
    const pieces = [_]struct { form: u8, gid: u32 }{
        .{ .form = radical_form_top, .gid = 3080 },
        .{ .form = radical_form_extender, .gid = 3079 },
        .{ .form = radical_form_bottom, .gid = 3078 },
    };
    for (pieces) |piece| {
        var t = item("\u{221A}", .italic);
        t.radical_form = piece.form;
        try testing.expectEqual(piece.gid, resolveGlyph(face, radical_cp, &t).?);
    }

    // Fence ladders .v1 … .v7. `|` and ∣ share the divides construction.
    const divides = [7]u32{ 2677, 2684, 2691, 2698, 2705, 2712, 2719 };
    const floor_left = [7]u32{ 2377, 2399, 2421, 2443, 2465, 2487, 2535 };
    const floor_right = [7]u32{ 2378, 2400, 2422, 2444, 2466, 2488, 2536 };
    const ceil_left = [7]u32{ 2375, 2397, 2419, 2441, 2463, 2485, 2533 };
    const ceil_right = [7]u32{ 2376, 2398, 2420, 2442, 2464, 2486, 2534 };
    const angle_left = [7]u32{ 2583, 2587, 2591, 2595, 2599, 2603, 2607 };
    const angle_right = [7]u32{ 2584, 2588, 2592, 2596, 2600, 2604, 2608 };
    const slash = [7]u32{ 2672, 2679, 2686, 2693, 2700, 2707, 2714 };
    const fences = [_]struct { cp: u21, text: []const u8, ladder: [7]u32 }{
        .{ .cp = '(', .text = "(", .ladder = .{ 2367, 2389, 2411, 2433, 2455, 2477, 2499 } },
        .{ .cp = ')', .text = ")", .ladder = .{ 2368, 2390, 2412, 2434, 2456, 2478, 2500 } },
        .{ .cp = '[', .text = "[", .ladder = .{ 2373, 2395, 2417, 2439, 2461, 2483, 2525 } },
        .{ .cp = ']', .text = "]", .ladder = .{ 2374, 2396, 2418, 2440, 2462, 2484, 2526 } },
        .{ .cp = '{', .text = "{", .ladder = .{ 2371, 2393, 2415, 2437, 2459, 2481, 2515 } },
        .{ .cp = '}', .text = "}", .ladder = .{ 2372, 2394, 2416, 2438, 2460, 2482, 2516 } },
        .{ .cp = '|', .text = "|", .ladder = divides },
        .{ .cp = 0x2223, .text = "\u{2223}", .ladder = divides },
        // ‖ parallel has its own construction. The old switch clamped rungs
        // 5-7 of divides AND parallel to .v4; the ladder has rungs there.
        .{
            .cp = 0x2225,
            .text = "\u{2225}",
            .ladder = .{ 2678, 2685, 2692, 2699, 2706, 2713, 2720 },
        },
        // The old per-codepoint switch named none of these, so \left⌊,
        // \left⟨ and \left/ all fell through to their BASE glyph. They have
        // real ladders; pin the rungs they now draw.
        .{ .cp = 0x230A, .text = "\u{230A}", .ladder = floor_left },
        .{ .cp = 0x230B, .text = "\u{230B}", .ladder = floor_right },
        .{ .cp = 0x2308, .text = "\u{2308}", .ladder = ceil_left },
        .{ .cp = 0x2309, .text = "\u{2309}", .ladder = ceil_right },
        .{ .cp = 0x27E8, .text = "\u{27E8}", .ladder = angle_left },
        .{ .cp = 0x27E9, .text = "\u{27E9}", .ladder = angle_right },
        .{ .cp = 0x002F, .text = "/", .ladder = slash },
    };
    for (fences) |fence| {
        for (fence.ladder, 0..) |gid, rung| {
            var t = item(fence.text, .italic);
            t.delim_form = @intCast(rung + 1);
            try testing.expectEqual(gid, resolveGlyph(face, fence.cp, &t).?);
        }
    }

    // amsmath's FIXED rule: the rung whose ladder ink covers req_em, with
    // 2.392em (\binom at display) landing on parenleft.v6.
    const fixed = [_]struct { req_em: f32, gid: u32 }{
        .{ .req_em = 0.5, .gid = 2367 },
        .{ .req_em = 0.9, .gid = 2389 },
        .{ .req_em = 1.2, .gid = 2411 },
        .{ .req_em = 1.5, .gid = 2433 },
        .{ .req_em = 1.9, .gid = 2455 },
        .{ .req_em = 2.392, .gid = 2477 },
        .{ .req_em = 2.8, .gid = 2499 },
    };
    for (fixed) |f| {
        var t = item("(", .italic);
        t.delim_fixed = f.req_em;
        try testing.expectEqual(f.gid, resolveGlyph(face, '(', &t).?);
    }
}

// U+2A11 ∬ was pinned to U+222E ∮'s .v1, so every double contour integral
// rasterized as a single one. Its own ladder starts at 3071.
test "resolveGlyph: a display \\iint draws contourint2.v1, not \\oint's variant" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const face = ctx.fonts.faceForStyle(.italic);

    var oint = item("\u{222E}", .italic);
    oint.bigop_form = .variant;
    var iint = item("\u{2A11}", .italic);
    iint.bigop_form = .variant;

    const oint_gid = try expectResolved(u32, "U+222E .v1", resolveGlyph(face, 0x222E, &oint));
    const iint_gid = try expectResolved(u32, "U+2A11 .v1", resolveGlyph(face, 0x2A11, &iint));
    try testing.expectEqual(@as(u32, 3067), oint_gid);
    try testing.expectEqual(@as(u32, 3071), iint_gid);
    try testing.expect(iint_gid != oint_gid);
    // Read back from the table, not from a constant: 3071 IS contourint2.v1.
    const base = try expectResolved(u32, "U+2A11 base glyph", face.glyphIndex(0x2A11));
    const ladder = try expectResolved(font.MathVariants, "U+2A11 ladder", face.variants(base));
    try testing.expectEqual(@as(usize, 1), ladder.len());
    try testing.expectEqual(iint_gid, ladder.glyph(0));
}

// The bug reached the pixels, not just the glyph id: with U+2A11 pinned to
// U+222E's variant, a display ∬ and a display ∮ produced the SAME bitmap.
test "rasterize: a display \\iint and \\oint no longer rasterize identically" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();

    var oint = item("\u{222E}", .italic);
    oint.bigop_form = .variant;
    var iint = item("\u{2A11}", .italic);
    iint.bigop_form = .variant;
    const iint_base = item("\u{2A11}", .italic);

    var oint_buffer = try rasterOne(testing.allocator, &ctx, oint);
    defer oint_buffer.deinit();
    var iint_buffer = try rasterOne(testing.allocator, &ctx, iint);
    defer iint_buffer.deinit();
    var base_buffer = try rasterOne(testing.allocator, &ctx, iint_base);
    defer base_buffer.deinit();

    try testing.expect(inkedPixels(oint_buffer) > 0);
    try testing.expect(inkedPixels(iint_buffer) > 0);
    // The bug: ∬ was pinned to ∮'s variant, so the two drew the same pixels.
    try testing.expect(!std.mem.eql(u8, iint_buffer.pixels, oint_buffer.pixels));
    // And the variant rung is what reaches the pixels — ∬ at base size is a
    // different drawing again, so the ladder is genuinely consulted.
    try testing.expect(!std.mem.eql(u8, iint_buffer.pixels, base_buffer.pixels));
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
test "resolveGlyph: a face with no MATH table degrades to the base glyph" {
    var ctx = try context.Context.init(testing.allocator);
    defer ctx.deinit();
    const face = ctx.fonts.faceForStyle(.roman);
    // Precondition: the Roman face really carries no MATH data.
    try testing.expect(face.mathConstants() == null);

    var stretched = item("(", .roman);
    stretched.delim_form = 6;
    const plain = item("(", .roman);
    try testing.expectEqual(
        face.glyphIndex('(').?,
        resolveGlyph(face, '(', &stretched).?,
    );

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
    try testing.expect(resolveGlyph(face, 0x2211, &op) == null);
    var empty_buffer = try rasterOne(testing.allocator, &ctx, op);
    defer empty_buffer.deinit();
    try testing.expectEqual(@as(usize, 0), inkedPixels(empty_buffer));
}

/// U+221A √ — the glyph an OpenType MATH table keys the radical's vertical
/// size variants and its glyph assembly under. layout.zig boxes the ASSEMBLY
/// pieces under the placeholder codepoints U+F300 (top), U+F301 (extender)
/// and U+23B7 (bottom); the private-use pair is in no cmap, so those pieces
/// resolve through this anchor instead of through the codepoint on the draw
/// item.
const radical_cp: u21 = 0x221A;

/// Which piece of the radical's MATH glyph assembly layout.zig is asking for.
/// Values below `radical_form_top` select a pre-built vertical size variant.
const radical_form_top: u8 = 5;
const radical_form_extender: u8 = 6;
const radical_form_bottom: u8 = 7;

/// The glyph at the 1-based MATH size-variant position `variant_index` of
/// `cp`'s ladder. Null when the face carries no MATH table, the codepoint has
/// no glyph, or the ladder is shorter than the requested rung — the caller
/// degrades rather than inventing an id. `variants` excludes the base glyph,
/// hence the -1. Allocation free: the ladder is a view over the face's bytes.
fn mathVariantGlyph(
    face: *const font.FontFace,
    cp: u21,
    variant_index: u8,
) ?u32 {
    if (variant_index == 0) return null;
    const base_gid = face.glyphIndex(cp) orelse return null;
    const ladder = face.variants(base_gid) orelse return null;
    const rung: usize = @as(usize, variant_index) - 1;
    if (rung >= ladder.len()) return null;
    return ladder.glyph(rung);
}

/// One piece of the radical's MATH glyph assembly: the top piece, the
/// extender, or the bottom piece. Null when the face has no MATH table, no √
/// glyph, no assembly, or an empty one.
fn radicalAssemblyGlyph(face: *const font.FontFace, piece: u8) ?u32 {
    const base_gid = face.glyphIndex(radical_cp) orelse return null;
    const stack = face.assembly(base_gid) orelse return null;
    if (stack.partCount() == 0) return null;
    // Parts run bottom to top, so the top piece is the last part.
    if (piece == radical_form_top) return stack.part(stack.partCount() - 1).glyph;
    if (piece == radical_form_bottom) return stack.part(0).glyph;
    if (piece != radical_form_extender) return null;
    // A construction may list several extender glyphs; the last one is the
    // piece the top part stacks onto, so that is the one to repeat.
    var i: usize = stack.partCount();
    while (i > 0) {
        i -= 1;
        if (stack.part(i).extender) return stack.part(i).glyph;
    }
    return null;
}

/// The amsmath FIXED-rule variant position (1-based) for a delimiter boxed at
/// `req_em` ink: the smallest rung of metrics.delim_ladder whose ascent plus
/// descent covers the request.
fn fixedDelimForm(req_em: f32) u8 {
    if (req_em >= 2.8) return 7;
    if (req_em >= 2.3) return 6;
    if (req_em >= 1.9) return 5;
    if (req_em >= 1.5) return 4;
    if (req_em >= 1.2) return 3;
    if (req_em >= 0.9) return 2;
    return 1;
}

/// The glyph a draw item paints: the MATH size variant for a stretchy item
/// (display big operator, √, fence), else the base cmap glyph. Null when the
/// codepoint has no glyph at all — the caller then draws nothing.
///
/// Degrading to the base glyph is deliberate. A face without a MATH table (any
/// LM Roman face, any user-supplied font) then paints an unstretched but
/// legible fence, and a ladder too short for the request paints the base glyph
/// too. Failing the draw instead would discard every other formula on the page
/// because one font lacks a table, and the raster API has no per-glyph error
/// channel to report a soft failure through. Nothing here panics and nothing
/// invents a glyph id: an unresolved stretchy item is never drawn from a
/// foreign font's numbering.
fn resolveGlyph(face: *const font.FontFace, cp: u21, t: *const draw.Text) ?u32 {
    if (t.bigop_form == .variant) {
        if (mathVariantGlyph(face, cp, 1)) |g| return g;
    }
    if (t.radical_form > 0) {
        // Rungs above the ladder (form 5..7) fall through to the assembly;
        // anything past `radical_form_bottom` is rejected by both.
        const piece = mathVariantGlyph(face, radical_cp, t.radical_form) orelse
            radicalAssemblyGlyph(face, t.radical_form);
        if (piece) |g| return g;
    }
    if (t.delim_form > 0 or t.delim_fixed > 0) {
        const variant_index = if (t.delim_form > 0)
            t.delim_form
        else
            fixedDelimForm(t.delim_fixed);
        if (mathVariantGlyph(face, cp, variant_index)) |g| return g;
    }
    return face.glyphIndex(cp);
}

fn drawGlyph(
    gpa: std.mem.Allocator,
    ctx: *context.Context,
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    opts: Options,
    t: draw.Text,
    pt_to_px: f32,
    pad_f: f32,
    origin: Origin,
) !void {
    const cp: u21 = blk: {
        if (t.bytes.len == 0) return;
        if (t.bytes.len == 1) break :blk t.bytes[0];
        if (t.bytes.len == 2) break :blk std.unicode.utf8Decode2(t.bytes[0..2].*) catch return;
        if (t.bytes.len == 3) break :blk std.unicode.utf8Decode3(t.bytes[0..3].*) catch return;
        if (t.bytes.len == 4) break :blk std.unicode.utf8Decode4(t.bytes[0..4].*) catch return;
        return;
    };

    const face = ctx.fonts.faceForStyle(t.style);

    // Stretchy glyphs resolve through the face's own MATH table (see
    // `resolveGlyph`): a glyph id is font-specific, so baking one in draws
    // the wrong shape on every font but Latin Modern.
    const gid = resolveGlyph(face, cp, &t) orelse return;
    var outline = try face.glyphOutline(gpa, gid);
    defer outline.deinit();
    if (outline.curves.items.len == 0) return;
    // Normalization: reverse CCW contours (CFF / Latin Modern convention) to CW (Y-up right-hand rule)
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < outline.curves.items.len) : (i += 1) {
        const at_end = i + 1 == outline.curves.items.len;
        const boundary = !at_end and (outline.curves.items[i].p2[0] != outline.curves.items[i + 1].p0[0] or
            outline.curves.items[i].p2[1] != outline.curves.items[i + 1].p0[1]);
        if (!at_end and !boundary) continue;

        var lo = run_start;
        var hi = i;
        while (lo < hi) : ({
            lo += 1;
            hi -= 1;
        }) {
            const tmp = outline.curves.items[lo];
            outline.curves.items[lo] = .{
                .p0 = outline.curves.items[hi].p2,
                .p1 = outline.curves.items[hi].p1,
                .p2 = outline.curves.items[hi].p0,
            };
            outline.curves.items[hi] = .{
                .p0 = tmp.p2,
                .p1 = tmp.p1,
                .p2 = tmp.p0,
            };
        }
        if (lo == hi) {
            const c = outline.curves.items[lo];
            outline.curves.items[lo] = .{ .p0 = c.p2, .p1 = c.p1, .p2 = c.p0 };
        }
        run_start = i + 1;
    }

    const gscale = t.size * pt_to_px / @as(f32, @floatCast(@as(f64, @floatFromInt(face.unitsPerEm()))));
    const ox = pad_f + (t.x + origin.x) * pt_to_px;
    const h_f: f32 = @floatFromInt(height);
    const ybase = h_f - (pad_f + (t.y + origin.y) * pt_to_px);

    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);

    for (outline.curves.items) |*c| {
        const points = [_]*[2]f32{ &c.p0, &c.p1, &c.p2 };
        for (points) |p| {
            const fx = ox + p[0] * gscale;
            const fy = ybase + p[1] * gscale;
            p[0] = fx;
            p[1] = fy;
            min_x = @min(min_x, fx);
            max_x = @max(max_x, fx);
            min_y = @min(min_y, fy);
            max_y = @max(max_y, fy);
        }
    }

    const h_i: i64 = @intCast(height);
    var wy0: i64 = @intFromFloat(@floor(min_y));
    var wy1: i64 = @intFromFloat(@floor(max_y));
    if (wy0 >= h_i or wy1 < 0) return;
    wy0 = @max(wy0, 0);
    wy1 = @min(wy1, h_i - 1);

    var cx0: i64 = @intFromFloat(@floor(min_x));
    var cx1: i64 = @intFromFloat(@ceil(max_x));
    cx0 = @max(cx0, 0);
    cx1 = @min(cx1, @as(i64, @intCast(width)));
    if (cx1 <= cx0) return;

    const ncols: usize = @intCast(cx1 - cx0);
    const row_buf = try gpa.alloc(f32, ncols);
    defer gpa.free(row_buf);

    const cov_curves: []const coverage.QuadCurve =
        std.mem.bytesAsSlice(coverage.QuadCurve, std.mem.sliceAsBytes(outline.curves.items));

    var wy = wy0;
    while (wy <= wy1) : (wy += 1) {
        coverage.coverageRow(cov_curves, @floatFromInt(wy), @floatFromInt(cx0), row_buf);
        const row: usize = @intCast(h_i - 1 - wy);
        for (row_buf, 0..) |cov, k| {
            if (cov <= 0.0) continue;
            const x = @as(usize, @intCast(cx0)) + k;
            blendPixel(pixels, row, x, stride, opts, cov);
        }
    }
}

fn fillRect(
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    opts: Options,
    x0f: f32,
    x1f: f32,
    y0f: f32,
    y1f: f32,
) void {
    const c0: i64 = @max(@as(i64, @intFromFloat(@floor(x0f))), 0);
    const c1: i64 = @min(@as(i64, @intFromFloat(@ceil(x1f))), @as(i64, @intCast(width)));
    const r0: i64 = @max(@as(i64, @intFromFloat(@floor(y0f))), 0);
    const r1: i64 = @min(@as(i64, @intFromFloat(@ceil(y1f))), @as(i64, @intCast(height)));
    if (c1 <= c0 or r1 <= r0) return;

    var r = r0;
    while (r < r1) : (r += 1) {
        var c = c0;
        while (c < c1) : (c += 1) {
            blendPixel(pixels, @intCast(r), @intCast(c), stride, opts, 1.0);
        }
    }
}

inline fn blendPixel(
    pixels: []u8,
    row: usize,
    col: usize,
    stride: u32,
    opts: Options,
    coverage_val: f32,
) void {
    const cov = @min(1.0, @max(0.0, coverage_val));
    switch (opts.format) {
        .rgba32 => {
            const idx = row * stride + col * 4;
            const fg_a: f32 = @as(f32, @floatFromInt(opts.fg.a)) / 255.0 * cov;
            const src_r: f32 = @floatFromInt(opts.fg.r);
            const src_g: f32 = @floatFromInt(opts.fg.g);
            const src_b: f32 = @floatFromInt(opts.fg.b);

            const dst_r: f32 = @floatFromInt(pixels[idx]);
            const dst_g: f32 = @floatFromInt(pixels[idx + 1]);
            const dst_b: f32 = @floatFromInt(pixels[idx + 2]);
            const dst_a: f32 = @as(f32, @floatFromInt(pixels[idx + 3])) / 255.0;

            const out_a = fg_a + dst_a * (1.0 - fg_a);
            if (out_a > 0.0) {
                const out_r = (src_r * fg_a + dst_r * dst_a * (1.0 - fg_a)) / out_a;
                const out_g = (src_g * fg_a + dst_g * dst_a * (1.0 - fg_a)) / out_a;
                const out_b = (src_b * fg_a + dst_b * dst_a * (1.0 - fg_a)) / out_a;
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
