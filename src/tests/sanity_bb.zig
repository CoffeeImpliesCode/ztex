// ztex.tests.sanity_bb — TDD regression for \mathbb (blackboard) glyph
// mapping.
//
// Bug: \mathbb{1} and \mathbb{R} rendered as the PLAIN ASCII digit/letter
// (1, R) instead of the double-struck glyphs (𝟙 U+1D7D9, ℝ U+211D). The
// layout's char mapping handled only .italic (mathItalic); the .bb style
// fell through to the source byte unchanged, so a \mathbb{R} drew a plain
// R — the user-reported "x in R should use the actual double-struck Real
// symbol" nit (CommutatorDeep's \mathbb{1} likewise drew a plain 1).
//
// Fix (in this test's expectation): layoutChar maps a .bb-style char to the
// double-struck MATH codepoint (letters → U+1D538.., digits → U+1D7D8..;
// C/H/N/P/Q/R/Z → the Letterlike ℂ/ℍ/ℕ/ℙ/ℚ/ℝ/ℤ) when the active metric
// source has the glyph, exactly like the existing mathItalic path.

const std = @import("std");
const ztex = @import("ztex");

const testing = std.testing;

test "sanity: \\mathbb maps chars to double-struck codepoints" {
    // \mathbb{1} → double-struck one U+1D7D9 (CommutatorDeep iℏ𝟙 part)
    {
        var out = try ztex.render(testing.allocator, "\\mathbb{1}", .display, 20, null);
        defer out.deinit();
        try testing.expectEqual(@as(usize, 1), out.len());
        const t = switch (out.items.items[0]) {
            .text => |v| v,
            else => return error.ExpectedTextPrimitive,
        };
        try testing.expectEqualStrings("\u{1D7D9}", t.bytes);
    }
    // \mathbb{R} → double-struck ℝ U+211D (BigOExpansion x ∈ ℝ)
    {
        var out = try ztex.render(testing.allocator, "\\mathbb{R}", .display, 20, null);
        defer out.deinit();
        try testing.expectEqual(@as(usize, 1), out.len());
        const t = switch (out.items.items[0]) {
            .text => |v| v,
            else => return error.ExpectedTextPrimitive,
        };
        try testing.expectEqualStrings("\u{211D}", t.bytes);
    }
    // \mathbb{N} → ℕ U+2115 (Letterlike double-struck)
    {
        var out = try ztex.render(testing.allocator, "\\mathbb{N}", .display, 20, null);
        defer out.deinit();
        const t = switch (out.items.items[0]) {
            .text => |v| v,
            else => return error.ExpectedTextPrimitive,
        };
        try testing.expectEqualStrings("\u{2115}", t.bytes);
    }
}
