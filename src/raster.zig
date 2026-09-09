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

/// Rasterize a draw list using the font context's embedded/cached fonts.
pub fn rasterize(
    gpa: std.mem.Allocator,
    ctx: *context.Context,
    dl: *const draw.DrawList,
    opts: Options,
) !PixelBuffer {
    const pt_to_px = (opts.dpi / 72.0) * opts.scale;
    const pad = opts.padding;

    const content_w = @max(1.0, dl.width * pt_to_px);
    const content_h = @max(1.0, (dl.height + dl.depth) * pt_to_px);
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
                try drawGlyph(gpa, ctx, dl, pixels, width, height, stride, opts, t, pt_to_px, pad_f);
            },
            .rect => |r| {
                const x0 = pad_f + r.x * pt_to_px;
                const x1 = pad_f + (r.x + r.w) * pt_to_px;
                const y0 = pad_f + (r.y + dl.height) * pt_to_px;
                const y1 = pad_f + (r.y + r.h + dl.height) * pt_to_px;
                fillRect(pixels, width, height, stride, opts, x0, x1, y0, y1);
            },
            .line => |l| {
                const half = 0.5 * l.width;
                const x0 = pad_f + (@min(l.x0, l.x1) - half) * pt_to_px;
                const x1 = pad_f + (@max(l.x0, l.x1) + half) * pt_to_px;
                const y0 = pad_f + (@min(l.y0, l.y1) - half + dl.height) * pt_to_px;
                const y1 = pad_f + (@max(l.y0, l.y1) + half + dl.height) * pt_to_px;
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

fn drawGlyph(
    gpa: std.mem.Allocator,
    ctx: *context.Context,
    dl: *const draw.DrawList,
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    opts: Options,
    t: draw.Text,
    pt_to_px: f32,
    pad_f: f32,
) !void {
    const cp: u21 = blk: {
        if (t.bytes.len == 0) return;
        if (t.bytes.len == 1) break :blk t.bytes[0];
        if (t.bytes.len == 2) break :blk std.unicode.utf8Decode2(t.bytes[0..2].*) catch return;
        if (t.bytes.len == 3) break :blk std.unicode.utf8Decode3(t.bytes[0..3].*) catch return;
        if (t.bytes.len == 4) break :blk std.unicode.utf8Decode4(t.bytes[0..4].*) catch return;
        return;
    };

    const face = switch (t.style) {
        .roman => ctx.fonts.romanFace(false),
        else => ctx.fonts.mathFace(),
    };

    // Resolve OpenType MATH variants for big operators, radicals, and delimiters
    const gid = blk: {
        if (t.bigop_form == .variant) {
            if (cp == 0x2211) break :blk @as(u32, 3074); // summation.v1
            if (cp == 0x220F) break :blk @as(u32, 3075); // product.v1
            if (cp == 0x222B) break :blk @as(u32, 3063); // integral.v1
            if (cp == 0x222E or cp == 0x2A11) break :blk @as(u32, 3067); // contourintegral.v1
        }
        if (t.radical_form > 0) {
            switch (t.radical_form) {
                1 => break :blk @as(u32, 3081), // radical.v1
                2 => break :blk @as(u32, 3082), // radical.v2
                3 => break :blk @as(u32, 3083), // radical.v3
                4 => break :blk @as(u32, 3084), // radical.v4
                5 => break :blk @as(u32, 3080), // radical.tp
                6 => break :blk @as(u32, 3079), // radical.ex
                else => {},
            }
        }
        if (t.delim_form > 0 or t.delim_fixed > 0) {
            const vi = if (t.delim_form > 0) t.delim_form else blk_fix: {
                if (t.delim_fixed >= 2.8) break :blk_fix @as(u8, 7);
                if (t.delim_fixed >= 2.3) break :blk_fix @as(u8, 6);
                if (t.delim_fixed >= 1.9) break :blk_fix @as(u8, 5);
                if (t.delim_fixed >= 1.5) break :blk_fix @as(u8, 4);
                if (t.delim_fixed >= 1.2) break :blk_fix @as(u8, 3);
                if (t.delim_fixed >= 0.9) break :blk_fix @as(u8, 2);
                break :blk_fix @as(u8, 1);
            };
            if (cp == '(') {
                switch (vi) {
                    1 => break :blk @as(u32, 2367), // parenleft.v1
                    2 => break :blk @as(u32, 2389), // parenleft.v2
                    3 => break :blk @as(u32, 2411), // parenleft.v3
                    4 => break :blk @as(u32, 2433), // parenleft.v4
                    5 => break :blk @as(u32, 2455), // parenleft.v5
                    6 => break :blk @as(u32, 2477), // parenleft.v6
                    else => break :blk @as(u32, 2499), // parenleft.v7
                }
            } else if (cp == ')') {
                switch (vi) {
                    1 => break :blk @as(u32, 2368), // parenright.v1
                    2 => break :blk @as(u32, 2390), // parenright.v2
                    3 => break :blk @as(u32, 2412), // parenright.v3
                    4 => break :blk @as(u32, 2434), // parenright.v4
                    5 => break :blk @as(u32, 2456), // parenright.v5
                    6 => break :blk @as(u32, 2478), // parenright.v6
                    else => break :blk @as(u32, 2500), // parenright.v7
                }
            } else if (cp == '[') {
                switch (vi) {
                    1 => break :blk @as(u32, 2373), // bracketleft.v1
                    2 => break :blk @as(u32, 2395), // bracketleft.v2
                    3 => break :blk @as(u32, 2417), // bracketleft.v3
                    4 => break :blk @as(u32, 2439), // bracketleft.v4
                    5 => break :blk @as(u32, 2461), // bracketleft.v5
                    6 => break :blk @as(u32, 2483), // bracketleft.v6
                    else => break :blk @as(u32, 2525), // bracketleft.v7
                }
            } else if (cp == ']') {
                switch (vi) {
                    1 => break :blk @as(u32, 2374), // bracketright.v1
                    2 => break :blk @as(u32, 2396), // bracketright.v2
                    3 => break :blk @as(u32, 2418), // bracketright.v3
                    4 => break :blk @as(u32, 2440), // bracketright.v4
                    5 => break :blk @as(u32, 2462), // bracketright.v5
                    6 => break :blk @as(u32, 2484), // bracketright.v6
                    else => break :blk @as(u32, 2526), // bracketright.v7
                }
            } else if (cp == '{') {
                switch (vi) {
                    1 => break :blk @as(u32, 2371), // braceleft.v1
                    2 => break :blk @as(u32, 2393), // braceleft.v2
                    3 => break :blk @as(u32, 2415), // braceleft.v3
                    4 => break :blk @as(u32, 2437), // braceleft.v4
                    5 => break :blk @as(u32, 2459), // braceleft.v5
                    6 => break :blk @as(u32, 2481), // braceleft.v6
                    else => break :blk @as(u32, 2515), // braceleft.v7
                }
            } else if (cp == '}') {
                switch (vi) {
                    1 => break :blk @as(u32, 2372), // braceright.v1
                    2 => break :blk @as(u32, 2394), // braceright.v2
                    3 => break :blk @as(u32, 2416), // braceright.v3
                    4 => break :blk @as(u32, 2438), // braceright.v4
                    5 => break :blk @as(u32, 2460), // braceright.v5
                    6 => break :blk @as(u32, 2482), // braceright.v6
                    else => break :blk @as(u32, 2516), // braceright.v7
                }
            } else if (cp == '|' or cp == 0x2223) {
                switch (vi) {
                    1 => break :blk @as(u32, 2677), // divides.v1
                    2 => break :blk @as(u32, 2684), // divides.v2
                    3 => break :blk @as(u32, 2691), // divides.v3
                    else => break :blk @as(u32, 2698), // divides.v4
                }
            } else if (cp == 0x2225) {
                switch (vi) {
                    1 => break :blk @as(u32, 2678), // parallel.v1
                    2 => break :blk @as(u32, 2685), // parallel.v2
                    3 => break :blk @as(u32, 2692), // parallel.v3
                    else => break :blk @as(u32, 2699), // parallel.v4
                }
            }
        }
        break :blk face.glyphIndex(cp) orelse return;
    };
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
    const ox = pad_f + t.x * pt_to_px;
    const h_f: f32 = @floatFromInt(height);
    const ybase = h_f - (pad_f + (t.y + dl.height) * pt_to_px);

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
