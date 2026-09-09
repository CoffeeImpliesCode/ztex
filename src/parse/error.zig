//! ztex.parse.error — parse-error context (kind + span + message).
//!
//! Lexer/parser error-return sites are bare error-set values (`error.Xxx`)
//! with no position. Threading an `?*Info` out-param through `lex`/`parse`
//! lets clients pretty-print the failure: the kind, the byte span of the
//! offending input, and a TeX-style message. The error VALUES are unchanged
//! (tests still `expectError` them); `Info` is only filled when a caller
//! passes a non-null pointer, and only immediately before the matching
//! error is returned.

const std = @import("std");
const atom = @import("ztex.atom");

/// The failure kinds, one per lexer/parser error-set member. Each parser
/// kind maps to exactly one error value in the parser's `fail` helper (the
/// lexer's two kinds are returned directly at their sites), so a site can
/// record an `Info` and return the SAME bare error it returned before
/// (error-value compatibility is load-bearing for `expectError` tests).
pub const Kind = enum {
    dangling_escape,
    invalid_utf8,
    unexpected_r_group,
    unexpected_script,
    double_script,
    unknown_command,
    missing_argument,
    missing_script,
    unclosed_group,
    unexpected_middle,
    unknown_environment,
    mismatched_end,
    unclosed_environment,
    child_count_overflow,
    source_too_large,
    nesting_too_deep,
};

/// Parse-error context filled by `lex`/`parse` when the caller passes a
/// non-null `err_info` out-param. On success the out-param is untouched.
pub const Info = struct {
    kind: Kind,
    /// Byte span of the offending input into the source. Zero-width at end
    /// of source when the error is "expected X but hit end of input"
    /// (e.g. `\frac{a}` — the missing denominator's position).
    span: atom.Span,

    /// A concrete TeX-style message for this kind.
    pub fn message(self: Info) []const u8 {
        return switch (self.kind) {
            .dangling_escape => "Dangling escape",
            .invalid_utf8 => "Invalid UTF-8",
            .unexpected_r_group => "Unexpected '}'",
            .unexpected_script => "Unexpected script",
            .double_script => "Double script",
            .unknown_command => "Unknown command",
            .missing_argument => "Missing argument",
            .missing_script => "Missing script",
            .unclosed_group => "Unclosed group",
            .unexpected_middle => "Unexpected \\middle",
            .unknown_environment => "Unknown environment",
            .mismatched_end => "Mismatched \\end",
            .unclosed_environment => "Unclosed environment",
            .child_count_overflow => "Child count overflow",
            .source_too_large => "Source too large",
            .nesting_too_deep => "Nesting too deep",
        };
    }
};

/// Counts every LEADING byte of a sequence (continuation bytes 0b10xxxxxx
/// are not new codepoints), so it is exact for well-formed input and still
/// yields a sane value on a prefix truncated mid-codepoint.
pub fn countCodepoints(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// The column counts CODEPOINTS from the line start (not bytes), so a caret
/// aligned by `col` sits under the right visual character even when a
/// multi-byte char precedes the error.
pub fn lineCol(src: []const u8, offset: usize) struct { line: usize, col: usize } {
    const o = @min(offset, src.len);
    var line: usize = 1;
    var line_start: usize = 0;
    for (src[0..o], 0..) |b, i| {
        if (b == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = countCodepoints(src[line_start..o]) + 1 };
}

/// With a trailing `\r` trimmed (so a CRLF-terminated line prints clean).
/// Empty source yields "".
pub fn sourceLine(src: []const u8, offset: usize) []const u8 {
    const o = @min(offset, src.len);
    var start = o;
    while (start > 0 and src[start - 1] != '\n') start -= 1;
    var end = o;
    while (end < src.len and src[end] != '\n') end += 1;
    var line = src[start..end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "error: lineCol is 1-based per line" {
    const src = "ab\ncde\r\nf";
    // 'd' at offset 4: line 2, byte col 2
    const lc = lineCol(src, 4);
    try testing.expectEqual(@as(usize, 2), lc.line);
    try testing.expectEqual(@as(usize, 2), lc.col);
    try testing.expectEqual(@as(usize, 1), lineCol(src, 0).line);
    try testing.expectEqual(@as(usize, 1), lineCol(src, 0).col);
    // EOF is on the last line, one past its last byte
    const eof = lineCol(src, src.len);
    try testing.expectEqual(@as(usize, 3), eof.line);
    try testing.expectEqual(@as(usize, 2), eof.col);
    // an offset past EOF clamps to EOF
    try testing.expectEqual(eof.line, lineCol(src, src.len + 10).line);
    try testing.expectEqual(eof.col, lineCol(src, src.len + 10).col);
}

test "error: lineCol counts codepoints, not bytes" {
    // 'ξ' (U+03BE) is 2 bytes. The '\' after it sits at byte offset 7 but
    // codepoint column 7 (x, space, =, space, ξ, space = 6 cells before it).
    const src = "x = ξ \\frac";
    // "x = ξ \frac": x(0) sp(1) =(2) sp(3) ξ(4,5) sp(6) \(7)
    const lc = lineCol(src, 7); // the backslash
    try testing.expectEqual(@as(usize, 1), lc.line);
    try testing.expectEqual(@as(usize, 7), lc.col); // not byte col 8
    // ASCII still behaves exactly as before (codepoint count == byte count)
    try testing.expectEqual(@as(usize, 3), lineCol(src, 2).col); // '='
    try testing.expectEqual(@as(usize, 5), lineCol(src, 4).col); // ξ start
    // An offset INSIDE a codepoint (never produced by real error spans,
    // which point at token starts) counts the partial leading byte; kept
    // to document the boundary, not as a real caret target.
    try testing.expectEqual(@as(usize, 6), lineCol(src, 5).col); // mid-ξ
    try testing.expectEqual(@as(usize, 6), lineCol(src, 6).col); // space after ξ (5 cps before)
    // countCodepoints matches on ASCII
    try testing.expectEqual(@as(usize, 5), countCodepoints("ab=c "));
    try testing.expectEqual(@as(usize, 2), countCodepoints("ξx"));
}

test "error: sourceLine returns the containing line, CR trimmed" {
    const src = "ab\ncde\r\nf";
    try testing.expectEqualStrings("ab", sourceLine(src, 0));
    try testing.expectEqualStrings("cde", sourceLine(src, 4)); // \r trimmed
    try testing.expectEqualStrings("f", sourceLine(src, 8));
    try testing.expectEqualStrings("", sourceLine("", 0));
}
