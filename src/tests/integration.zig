//! ztex.tests.integration — full-pipeline invariants over a LaTeX corpus.
//!
//! MicroTeX-style: render a fixed corpus through the public facade and
//! assert deterministic structural invariants. Golden-string snapshots live
//! in regression.zig; this module never depends on exact coordinates.

const std = @import("std");
const ztex = @import("ztex");

const testing = std.testing;

const size_pt: f32 = 20;

const corpus = [_][]const u8{
    "x",
    "x^2",
    "x_2",
    "x^2+y_1",
    "\\frac{1}{2}",
    "\\sum_{i=1}^{n}",
    "\\text{hi}",
    "\\mathbf{ab}",
};

test {
    std.testing.refAllDecls(@This());
}

test "integration: corpus renders non-empty with positive bounds" {
    for (corpus) |src| {
        var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
        defer out.deinit();
        try testing.expect(out.len() > 0);
        try testing.expect(out.width > 0);
        try testing.expect(out.height > 0);
    }
}

test "integration: every primitive carries valid provenance into the source" {
    for (corpus) |src| {
        var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
        defer out.deinit();
        for (out.items.items) |d| {
            switch (d) {
                .text => |t| {
                    // non-empty window into the original source
                    try testing.expect(t.src_start < t.src_end);
                    try testing.expect(t.src_end <= src.len);
                    // the glyph is non-empty and aliases the source window for
                    // ordinary chars (a big operator synthesizes e.g. ∑ instead)
                    try testing.expect(t.bytes.len > 0);
                    const aliased = std.mem.eql(u8, t.bytes, src[t.src_start..t.src_end]);
                    if (!aliased) {
                        // synthesized glyph: must still be a valid multi-byte codepoint
                        try testing.expect(t.bytes.len >= 2);
                    }
                },
                .rect => |r| {
                    try testing.expect(r.src_start < r.src_end);
                    try testing.expect(r.src_end <= src.len);
                },
                .line => |l| {
                    try testing.expect(l.src_start < l.src_end);
                    try testing.expect(l.src_end <= src.len);
                },
            }
        }
    }
}

test "integration: superscript is raised, shrunk, and has exact spans" {
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

    // base: full size on the baseline, covers "x"
    try testing.expectEqualStrings("𝑥", base.bytes);
    try testing.expectEqualStrings("x", src[base.src_start..base.src_end]);
    try testing.expectEqual(size_pt, base.size);

    // superscript: raised above the baseline and scaled down, covers "2"
    try testing.expectEqualStrings("2", sup.bytes);
    try testing.expectEqualStrings("2", src[sup.src_start..sup.src_end]);
    try testing.expect(sup.size < size_pt);
    try testing.expect(sup.y < 0);
}

test "integration: fraction draws a rule plus numerator and denominator" {
    const src = "\\frac{1}{2}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    var text_count: usize = 0;
    var rect_count: usize = 0;
    for (out.items.items) |d| {
        switch (d) {
            .text => text_count += 1,
            .rect => rect_count += 1,
            .line => {},
        }
    }
    try testing.expect(rect_count >= 1); // the fraction rule
    try testing.expect(text_count >= 2); // "1" and "2"
}

test "integration: text mode emits one full-size primitive per character" {
    const src = "\\text{hi}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    try testing.expectEqual(@as(usize, 2), out.len());
    for (out.items.items, 0..) |d, i| {
        const t = switch (d) {
            .text => |v| v,
            else => return error.ExpectedTextPrimitive,
        };
        try testing.expectEqual(size_pt, t.size);
        try testing.expectEqualStrings(if (i == 0) "h" else "i", t.bytes);
        // spans sit strictly inside the braces: '{' at byte 5, '}' at byte 8
        try testing.expect(t.src_start >= 6);
        try testing.expect(t.src_end <= 8);
    }
}
