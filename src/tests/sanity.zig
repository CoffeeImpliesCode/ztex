//! ztex.tests.sanity — position-sanity invariants over the rendered output.
//!
//! Renders a fixed corpus through the public facade and asserts every
//! primitive lands at finite coordinates inside the draw list's own bounds
//! (width, height, depth). The SVG emitter mirrors those bounds by offsetting
//! each baseline by +height, so in-bounds draw coords are in-bounds SVG. No
//! golden strings; complements integration.zig.

const std = @import("std");
const ztex = @import("ztex");

const testing = std.testing;

const size_pt: f32 = 20;
/// A coordinate at or beyond this magnitude is layout corruption, not a
/// sane position.
const max_abs_coord: f32 = 1e6;

const corpus = [_][]const u8{
    "x",
    "abc",
    "x^2",
    "x_2",
    "\\frac{1}{2}",
    "\\sum_{i=1}^{n}",
    "\\text{hi}",
};

test {
    testing.refAllDecls(@This());
}

/// Assert a numeric field is finite and not absurdly large.
fn expectSaneCoord(v: f32) !void {
    try testing.expect(std.math.isFinite(v));
    try testing.expect(@abs(v) < max_abs_coord);
}

/// Assert a point is inside the draw-list bounds as the SVG emitter sees
/// them: x in [0, width]; baseline y offset by +height in [0, height+depth].
fn expectInBounds(dl: *const ztex.draw.DrawList, x: f32, y: f32) !void {
    try testing.expect(x >= 0);
    try testing.expect(x <= dl.width);
    const svg_y = y + dl.height;
    try testing.expect(svg_y >= 0);
    try testing.expect(svg_y <= dl.height + dl.depth);
}

/// Assert a primitive's coordinates are finite, bounded in magnitude, and
/// inside the draw-list bounds.
fn expectSanePrimitive(dl: *const ztex.draw.DrawList, d: ztex.draw.Draw) !void {
    switch (d) {
        .text => |t| {
            try expectSaneCoord(t.x);
            try expectSaneCoord(t.y);
            try expectSaneCoord(t.size);
            try expectInBounds(dl, t.x, t.y);
        },
        .rect => |r| {
            try expectSaneCoord(r.x);
            try expectSaneCoord(r.y);
            try expectSaneCoord(r.w);
            try expectSaneCoord(r.h);
            try expectInBounds(dl, r.x, r.y);
        },
        .line => |l| {
            try expectSaneCoord(l.x0);
            try expectSaneCoord(l.y0);
            try expectSaneCoord(l.x1);
            try expectSaneCoord(l.y1);
            try expectSaneCoord(l.width);
            try expectInBounds(dl, l.x0, l.y0);
            try expectInBounds(dl, l.x1, l.y1);
        },
    }
}

test "sanity: corpus primitives have finite in-bounds coordinates" {
    for (corpus) |src| {
        var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
        defer out.deinit();
        for (out.items.items) |d| try expectSanePrimitive(&out, d);
    }
}

test "sanity: 'abc' is three text primitives on the baseline" {
    const src = "abc";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    try testing.expectEqual(@as(usize, 3), out.len());
    // math-italic letters emit the U+1D4xx forms ("a" -> "𝑎" etc), not the
    // source ASCII (the italic variable glyphs).
    const expected = [_][]const u8{ "\u{1D44E}", "\u{1D44F}", "\u{1D450}" };
    for (out.items.items, 0..) |d, i| {
        const t = switch (d) {
            .text => |v| v,
            else => return error.ExpectedTextPrimitive,
        };
        try testing.expectEqualStrings(expected[i], t.bytes);
        try testing.expectEqual(@as(f32, 0), t.y);
    }
    // glyphs advance left to right and stop at the row width
    try testing.expect(out.items.items[0].text.x < out.items.items[1].text.x);
    try testing.expect(out.items.items[1].text.x < out.items.items[2].text.x);
    try testing.expect(out.items.items[2].text.x <= out.width);
}

test "sanity: 'x^2' raises and shrinks the superscript" {
    const src = "x^2";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    try testing.expectEqual(@as(usize, 2), out.len());
    const base = switch (out.items.items[0]) {
        .text => |t| t,
        else => return error.ExpectedTextPrimitive,
    };
    const sup = switch (out.items.items[1]) {
        .text => |t| t,
        else => return error.ExpectedTextPrimitive,
    };
    try testing.expectEqualStrings("𝑥", base.bytes);
    try testing.expectEqual(@as(f32, 0), base.y);
    try testing.expectEqualStrings("2", sup.bytes);
    // superscript baseline rises above the base baseline and is scaled down
    try testing.expect(sup.y < 0);
    try testing.expect(sup.size < size_pt);
    try testing.expect(sup.size > 0);
}

test "sanity: 'x_2' lowers the subscript below the baseline" {
    const src = "x_2";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    try testing.expectEqual(@as(usize, 2), out.len());
    const base = switch (out.items.items[0]) {
        .text => |t| t,
        else => return error.ExpectedTextPrimitive,
    };
    const sub = switch (out.items.items[1]) {
        .text => |t| t,
        else => return error.ExpectedTextPrimitive,
    };
    try testing.expectEqualStrings("𝑥", base.bytes);
    try testing.expectEqual(@as(f32, 0), base.y);
    try testing.expectEqualStrings("2", sub.bytes);
    // subscript baseline drops below the base baseline
    try testing.expect(sub.y > 0);
}

test "sanity: fraction rule sits between baselines and spans the width" {
    const src = "\\frac{1}{2}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    var num: ?ztex.draw.Text = null;
    var den: ?ztex.draw.Text = null;
    var rule: ?ztex.draw.Rect = null;
    var rect_count: usize = 0;
    for (out.items.items) |d| {
        switch (d) {
            .text => |t| {
                if (std.mem.eql(u8, t.bytes, "1")) num = t;
                if (std.mem.eql(u8, t.bytes, "2")) den = t;
            },
            .rect => |r| {
                rect_count += 1;
                rule = r;
            },
            .line => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), rect_count); // just the rule
    const n = num orelse return error.NoNumerator;
    const d = den orelse return error.NoDenominator;
    const r = rule orelse return error.NoRule;

    // the rule straddles the axis: below the numerator baseline, above the
    // denominator baseline, in draw-list coordinates
    try testing.expect(n.y < r.y);
    try testing.expect(r.y < d.y);
    // the rule spans the fraction's inner width (TeX \nulldelimiterspace
    // pads 1.2pt each side OUTSIDE the content), so the rule is 2*1.2 narrower
    try testing.expect(r.w > 0);
    try testing.expectApproxEqAbs(r.w, out.width - 2 * 1.2, 0.001);
}

test "sanity: '\\sum_{i=1}^{n}' renders one big-operator glyph" {
    const src = "\\sum_{i=1}^{n}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    var sum_count: usize = 0;
    for (out.items.items) |d| {
        const t = switch (d) {
            .text => |v| v,
            else => continue,
        };
        if (std.mem.eql(u8, t.bytes, "∑")) sum_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), sum_count);
}
