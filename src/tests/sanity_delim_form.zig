// ztex.tests.sanity_delim_form — TDD regression for the matrix outer-paren
// bug.
//
// Bug: a tall pmatrix renders its outer ( ) at the BASE font size — far
// too short for ~4em of content. layoutDelimChar picks a MATH-table variant
// (v6/v7) based on req_em, but the variant index never reached the SVG —
// only data-fixed-req existed (for \binom-style fixed fences), so the
// rasterizer drew the BASE paren glyph at base size.
//
// Fix: the layout's chosen variant index travels via
//   CharData.delim_form → Draw.Text.delim_form → svg.zig emits
//   `data-delim-form="vN"` → critique.py maps to the PUA variant codepoint.
//
// This test asserts the propagation: a 4-row pmatrix must produce parens
// with delim_form ≥ 6 (v6 = 2.392em, v7 = 2.99em at LM Math — the ladder
// ceiling when content exceeds every smaller variant's ink).

const std = @import("std");
const ztex = @import("ztex");

const testing = std.testing;

test "sanity: tall matrix outer parens carry a stretched variant (delim_form >= 6)" {
    const src = "\\begin{pmatrix} a & b \\\\ c & d \\\\ e & f \\\\ g & h \\end{pmatrix}";
    var out = try ztex.render(testing.allocator, src, 20, null);
    defer out.deinit();

    var open_form: u8 = 0;
    var close_form: u8 = 0;
    var open_count: usize = 0;
    var close_count: usize = 0;
    for (out.items.items) |d| {
        switch (d) {
            .text => |t| {
                if (std.mem.eql(u8, t.bytes, "(")) {
                    open_form = t.delim_form;
                    open_count += 1;
                }
                if (std.mem.eql(u8, t.bytes, ")")) {
                    close_form = t.delim_form;
                    close_count += 1;
                }
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 1), open_count);
    try testing.expectEqual(@as(usize, 1), close_count);
    try testing.expect(open_form > 0);
    try testing.expect(close_form > 0);
    try testing.expectEqual(open_form, close_form);
    // 4 rows of content ≈ 4em of ink; the smallest variant covering it is
    // v6 (2.392em) or v7 (2.99em, the ladder ceiling).
    try testing.expect(open_form >= 6);
}
