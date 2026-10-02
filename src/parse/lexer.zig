//! ztex.parse.lexer — LaTeX math tokenizer.
//!
//! Pre-lexes the whole source into the AST's flat token table. One forward
//! pass over `ast.src` appends a `Token` per lexical element; whitespace and
//! comments are skipped. Every token carries its byte span into the source,
//! so later atoms map back to source text in O(1).
//!
//! A private file: nothing outside this module reaches it by name, and a
//! consumer parses through `ztex.parse.parse`. It allocates only the token
//! entries appended to the Ast it is handed, all of which the Ast's own
//! `deinit` releases; it stores no source of its own.

const std = @import("std");
const atom = @import("ztex.atom");
const zg = @import("zg");
const parse_err = @import("error.zig");

/// Everything `lex` can fail with. `error.OutOfMemory` is the allocator's own
/// tag and reaches the caller with the Ast holding the tokens appended so
/// far — the Ast is the caller's and its `deinit` still releases them. The two
/// syntax tags carry a `Kind` in `Info` when the caller passed a channel, and
/// no allocation survives either of them beyond the tokens already appended.
pub const Error = std.mem.Allocator.Error || error{
    /// a backslash at end of input with nothing after it
    DanglingEscape,
    /// invalid utf-8 in the source
    InvalidUtf8,
};

/// Pre-lex `ast.src` into `ast.tokens`. Whitespace and comments are skipped.
/// On a lex error, `err_info` (when non-null) is filled with the kind and
/// the offending byte span before the error is returned.
///
/// APPENDS: whatever tokens `ast.tokens` already holds are kept, and this
/// runs from the start of `ast.src` again — a caller wanting a clean table
/// clears it first. `ast.src` is read and never written or copied, and every
/// span written into a token is a byte offset into that borrowed slice, so it
/// is the caller's job to keep `src` alive and unmodified for as long as the
/// tokens are read.
///
/// On `error.DanglingEscape` or `error.InvalidUtf8` the tokens appended
/// BEFORE the offending byte stay appended, and `err_info` holds the failing
/// span (for `error.InvalidUtf8`, the offending leading byte alone). On
/// `error.OutOfMemory` `err_info` is untouched: an allocation failure is not
/// a position in the source.
///
/// A `null` `err_info` skips the diagnostic writes and changes no error
/// value; the channel is caller-owned and is never retained past the call.
/// `ast` itself is only appended to and is not otherwise mutated, so a caller
/// may hold a `*atom.Ast` across this call as long as nothing else writes the
/// same Ast or its source concurrently.
pub fn lex(ast: *atom.Ast, err_info: ?*parse_err.Info) Error!void {
    const src = ast.src;
    var pos: usize = 0;
    while (pos < src.len) {
        const start = pos;
        switch (src[pos]) {
            ' ', '\t', '\r', '\n' => pos += 1,
            '%' => pos = commentEnd(src, pos),
            '\\' => pos = try escape(ast, src, start, err_info),
            '{' => {
                pos += 1;
                try emit(ast, .l_group, start, pos);
            },
            '}' => {
                pos += 1;
                try emit(ast, .r_group, start, pos);
            },
            '^' => {
                pos += 1;
                try emit(ast, .sup, start, pos);
            },
            '_' => {
                pos += 1;
                try emit(ast, .sub, start, pos);
            },
            else => {
                // ordinary printable byte: skip the whole run to the next
                // structural byte, emitting a char token per codepoint.
                const run_end = scanUntilStructural(src, pos);
                while (pos < run_end) {
                    const cstart = pos;
                    // ASCII fast path: a leading byte < 0x80 is always a
                    // valid 1-byte codepoint — no decode/validation.
                    if (src[pos] < 0x80) {
                        pos += 1;
                    } else {
                        pos += try codepointLen(src, pos, err_info);
                    }
                    try emit(ast, .char, cstart, pos);
                }
            },
        }
    }
}

/// Append a token covering `start..end`, propagating OOM.
fn emit(ast: *atom.Ast, tag: atom.TokenTag, start: usize, end: usize) std.mem.Allocator.Error!void {
    try ast.pushToken(.{
        .tag = tag,
        .start = @intCast(start),
        .end = @intCast(end),
    });
}

/// End of a comment: `%` runs to, but not including, the next newline.
/// The newline itself is then skipped as whitespace by `lex`.
fn commentEnd(src: []const u8, pos: usize) usize {
    var i = pos;
    while (i < src.len and src[i] != '\n') i += 1;
    return i;
}

/// Consume a control sequence at `start` (the backslash). The name is a
/// maximal run of ascii letters, else a single codepoint (control symbol).
/// Token span: backslash .. just past the name.
fn escape(ast: *atom.Ast, src: []const u8, start: usize, err_info: ?*parse_err.Info) Error!usize {
    var pos = start + 1; // past the backslash
    if (pos >= src.len) {
        // The offending input is the dangling backslash itself.
        if (err_info) |info| info.* = .{
            .kind = .dangling_escape,
            .span = .{ .start = @intCast(start), .end = @intCast(start + 1) },
        };
        return error.DanglingEscape;
    }
    if (isAsciiLetter(src[pos])) {
        while (pos < src.len and isAsciiLetter(src[pos])) pos += 1;
    } else {
        pos += try codepointLen(src, pos, err_info);
    }
    try emit(ast, .command, start, pos);
    return pos;
}

/// Byte length of the utf-8 codepoint at `pos`; the full sequence is validated.
fn codepointLen(src: []const u8, pos: usize, err_info: ?*parse_err.Info) Error!usize {
    // ASCII leading byte: always valid, always 1 byte — no decode needed.
    if (src[pos] < 0x80) return 1;
    const len = std.unicode.utf8ByteSequenceLength(src[pos]) catch
        return invalidUtf8(err_info, pos);
    if (pos + len > src.len) return invalidUtf8(err_info, pos);
    // zg's bjoern.hoehrmann DFA decoder. A well-formed sequence decodes to a
    // codepoint consuming exactly `len` bytes; any ill-formed input is
    // replaced by a shorter maximal subpart, which we report as InvalidUtf8
    // (identical to the previous full-sequence validation).
    var cursor: zg.code_point.uoffset = @intCast(pos);
    const cp = zg.code_point.decodeAtCursor(src, &cursor) orelse return invalidUtf8(err_info, pos);
    if (cp.len != len) return invalidUtf8(err_info, pos);
    return len;
}

/// Record an invalid-utf8 Info (span = the offending leading byte) and
/// return the error value.
fn invalidUtf8(err_info: ?*parse_err.Info, pos: usize) Error {
    if (err_info) |info| info.* = .{
        .kind = .invalid_utf8,
        .span = .{ .start = @intCast(pos), .end = @intCast(pos + 1) },
    };
    return error.InvalidUtf8;
}

fn isAsciiLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// True if `b` is a structural byte: whitespace or a token delimiter.
/// Ordinary printable bytes start a run that can be skipped vectorized.
fn isStructural(b: u8) bool {
    return switch (b) {
        ' ', '\t', '\r', '\n', '%', '\\', '{', '}', '^', '_' => true,
        else => false,
    };
}

/// Index of the first structural byte in `src[pos..]`, or `src.len` if none.
///
/// This is the lexer's real hot loop: it jumps over a run of ordinary
/// printable bytes without a per-byte dispatch. SIMD-accelerated (mitchellh's
/// 5-step shape) when a vector width is available; otherwise scalar. The two
/// paths are kept identical and covered by a differential test.
fn scanUntilStructural(src: []const u8, pos: usize) usize {
    var i = pos;
    if (std.simd.suggestVectorLength(u8)) |n| {
        while (i + n <= src.len) : (i += n) {
            const v: @Vector(n, u8) = src[i..][0..n].*;
            const hit = (v == @as(@TypeOf(v), @splat(' '))) |
                (v == @as(@TypeOf(v), @splat('\t'))) |
                (v == @as(@TypeOf(v), @splat('\r'))) |
                (v == @as(@TypeOf(v), @splat('\n'))) |
                (v == @as(@TypeOf(v), @splat('%'))) |
                (v == @as(@TypeOf(v), @splat('\\'))) |
                (v == @as(@TypeOf(v), @splat('{'))) |
                (v == @as(@TypeOf(v), @splat('}'))) |
                (v == @as(@TypeOf(v), @splat('^'))) |
                (v == @as(@TypeOf(v), @splat('_')));
            if (@reduce(.Or, hit)) {
                const mask: @Int(.unsigned, n) = @bitCast(hit);
                return i + @ctz(mask);
            }
        }
    }
    while (i < src.len and !isStructural(src[i])) i += 1;
    return i;
}

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

fn lexAst(src: []const u8) !atom.Ast {
    var a = atom.Ast.init(testing.allocator, src);
    errdefer a.deinit();
    try lex(&a, null);
    return a;
}

fn expectToken(a: *const atom.Ast, i: usize, tag: atom.TokenTag, start: u32, end: u32) !void {
    const t = a.tokens.items[i];
    try testing.expectEqual(tag, t.tag);
    try testing.expectEqual(start, t.start);
    try testing.expectEqual(end, t.end);
}

fn expectChar(a: *const atom.Ast, i: usize, s: []const u8) !void {
    const t = a.tokens.items[i];
    try testing.expectEqual(atom.TokenTag.char, t.tag);
    try testing.expectEqualStrings(s, a.src[t.start..t.end]);
}

test "lexer: empty source yields no tokens" {
    var a = try lexAst("");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.tokens.items.len);
}

test "lexer: plain ascii chars in order" {
    var a = try lexAst("x+1");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 3), a.tokens.items.len);
    try expectChar(&a, 0, "x");
    try expectChar(&a, 1, "+");
    try expectChar(&a, 2, "1");
}

test "lexer: brackets are ordinary chars" {
    var a = try lexAst("[x]");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 3), a.tokens.items.len);
    try expectChar(&a, 0, "[");
    try expectChar(&a, 1, "x");
    try expectChar(&a, 2, "]");
}

test "lexer: whitespace and comments are skipped" {
    var a = try lexAst("a  b % trailing comment\nc");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 3), a.tokens.items.len);
    try expectChar(&a, 0, "a");
    try expectChar(&a, 1, "b");
    try expectChar(&a, 2, "c");
}

test "lexer: groups and scripts" {
    var a = try lexAst("{a^2_b}");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 7), a.tokens.items.len);
    try expectToken(&a, 0, .l_group, 0, 1);
    try expectToken(&a, 1, .char, 1, 2);
    try expectToken(&a, 2, .sup, 2, 3);
    try expectToken(&a, 3, .char, 3, 4);
    try expectToken(&a, 4, .sub, 4, 5);
    try expectToken(&a, 5, .char, 5, 6);
    try expectToken(&a, 6, .r_group, 6, 7);
}

test "lexer: multi-letter command" {
    var a = try lexAst("\\frac");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.tokens.items.len);
    try expectToken(&a, 0, .command, 0, 5);
    try testing.expectEqualStrings("frac", a.src[1..5]);
}

test "lexer: control symbol is a single codepoint" {
    var a = try lexAst("\\,");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.tokens.items.len);
    try expectToken(&a, 0, .command, 0, 2);
    try testing.expectEqualStrings(",", a.src[1..2]);
    var b = try lexAst("\\\\");
    defer b.deinit();
    try testing.expectEqual(@as(usize, 1), b.tokens.items.len);
    try expectToken(&b, 0, .command, 0, 2);
    try testing.expectEqualStrings("\\", b.src[1..2]);
}

test "lexer: dangling escape is an error" {
    var a = atom.Ast.init(testing.allocator, "abc\\");
    defer a.deinit();
    var err_info: parse_err.Info = undefined;
    try testing.expectError(error.DanglingEscape, lex(&a, &err_info));
    // tokens before the error were emitted
    try testing.expectEqual(@as(usize, 3), a.tokens.items.len);
    // the offending input is the dangling backslash itself
    try testing.expectEqual(parse_err.Kind.dangling_escape, err_info.kind);
    try testing.expectEqual(@as(u32, 3), err_info.span.start);
    try testing.expectEqual(@as(u32, 4), err_info.span.end);
}

test "lexer: utf-8 codepoint keeps its byte span" {
    var a = try lexAst("α");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.tokens.items.len);
    try expectToken(&a, 0, .char, 0, 2);
    try testing.expectEqualStrings("α", a.src[0..2]);
}

test "lexer: invalid utf-8 is an error" {
    var a = atom.Ast.init(testing.allocator, "\xff");
    defer a.deinit();
    var err_info: parse_err.Info = undefined;
    try testing.expectError(error.InvalidUtf8, lex(&a, &err_info));
    try testing.expectEqual(parse_err.Kind.invalid_utf8, err_info.kind);
    try testing.expectEqual(@as(u32, 0), err_info.span.start);
    try testing.expectEqual(@as(u32, 1), err_info.span.end);
}

test "lexer: scanUntilStructural matches the scalar reference" {
    const ref_scan = struct {
        fn run(src: []const u8, pos: usize) usize {
            var i = pos;
            while (i < src.len and !isStructural(src[i])) i += 1;
            return i;
        }
    }.run;
    const cases = [_][]const u8{
        "",
        "abc",
        "a b",
        "x\\frac{y}",
        "hello world\nnext",
        "x^2+y_1",
        "alpha\u{03b1}beta",
        "plain printable run without structural",
    };
    for (cases) |src| {
        var pos: usize = 0;
        while (pos <= src.len) : (pos += 1) {
            try testing.expectEqual(ref_scan(src, pos), scanUntilStructural(src, pos));
        }
    }
}
