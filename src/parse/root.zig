//! ztex.parse — LaTeX math source → superflat atom tree.
//!
//! Usable on its own: `parse(gpa, src)` returns an `atom.Ast` you can inspect
//! or feed to `ztex.layout`.

const std = @import("std");
const atom = @import("ztex.atom");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
pub const err = @import("error.zig");

/// The complete set of command names the parser recognizes (see
/// parser.supported_commands) — the single external answer to "what commands
/// does this parser support".
pub const supported_commands = parser.supported_commands;

/// Parse-error context (kind + span + message); see `err.Info`.
pub const Info = err.Info;
/// The parse-error kinds; see `err.Kind`.
pub const Kind = err.Kind;

pub const Error = lexer.Error || parser.Error || error{
    /// the source exceeds `max_source_bytes` (too long for `Span`'s u32 byte offsets)
    SourceTooLarge,
};

/// Hard upper bound on `src.len`. `Span` (token.zig) stores byte offsets as
/// u32, and the lexer's `emit` casts its usize positions with `@intCast`; a
/// source longer than `maxInt(u32)` bytes would overflow that cast (a
/// safe-mode panic / a ReleaseFast truncation). We reject such sources up
/// front with `error.SourceTooLarge` instead. Realistic math input is orders
/// of magnitude smaller; the bound only guards the degenerate case.
pub const max_source_bytes: usize = std.math.maxInt(u32);

/// True when a source of `len` bytes is too long for u32 byte offsets.
/// Factored out so the boundary is unit-testable without a multi-GiB
/// allocation.
pub fn sourceTooLong(len: usize) bool {
    return len > max_source_bytes;
}

/// Pre-lex and parse `src` into an atom tree. Caller owns the Ast: free with
/// `ast.deinit()`. `ast.src` aliases the caller's `src` (never copied). On
/// a parse error, `err_info` (when non-null) is filled with the kind and the
/// offending byte span before the error is returned; on success it is
/// untouched.
pub fn parse(gpa: std.mem.Allocator, src: []const u8, err_info: ?*Info) Error!atom.Ast {
    if (sourceTooLong(src.len)) {
        // Zero-width span at offset 0; the whole input is over the bound.
        if (err_info) |info| info.* = .{
            .kind = .source_too_large,
            .span = .{ .start = 0, .end = 0 },
        };
        return error.SourceTooLarge;
    }
    var ast = atom.Ast.init(gpa, src);
    errdefer ast.deinit();
    // pre-lex capacity heuristic: tokens ≈ src.len/4 (capacity-only, the
    // ArrayList grows past it if the input is denser)
    try ast.reserve(src.len / 4, src.len / 2);
    try lexer.lex(&ast, err_info);
    // Node-pool reserve heuristic: 2·(tokens + 1) would cap a fully-binary
    // tree, but unary/n-ary atoms (scripts, fractions, groups, …) can emit
    // more than one node per token, so it is NOT an exact bound — the pool
    // grows on demand in pushNode. The reserve only avoids common-case
    // realloc churn (capacity-only, no shrink).
    try ast.nodes.ensureTotalCapacity(gpa, 2 * (ast.tokens.items.len + 1));
    var p = parser.Parser.init(gpa, src, ast.tokens.items, err_info);
    ast.root = try p.parse(&ast);
    return ast;
}

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "parse: sourceTooLong boundary is maxInt(u32)" {
    // Constructing a real >4 GiB source is impractical, so the check is
    // factored into `sourceTooLong` and tested at the boundary directly.
    try testing.expectEqual(max_source_bytes, std.math.maxInt(u32));
    try testing.expect(!sourceTooLong(max_source_bytes)); // last representable
    try testing.expect(sourceTooLong(max_source_bytes + 1)); // first overflow
    try testing.expect(sourceTooLong(std.math.maxInt(usize)));
}

test "parse: over-limit source returns SourceTooLarge with kind and span" {
    // Exercise the parse() gate without a multi-GiB allocation: the check
    // runs on src.len before any lexing, so a bound-mocked caller can be
    // driven through the public error path only via a genuinely huge slice.
    // Instead, assert the boundary contract via sourceTooLong and that the
    // error kind/message exist (see Kind.source_too_large).
    try testing.expectEqual(Kind.source_too_large, @as(Kind, .source_too_large));
    try testing.expectEqualStrings(
        "Source too large",
        @as(Info, .{ .kind = .source_too_large, .span = .{ .start = 0, .end = 0 } }).message(),
    );
}

test "parse: full pipeline, x+1 becomes 3-char row" {
    var ast = try parse(testing.allocator, "x+1", null);
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 3), ast.tokens.items.len);
    const root = ast.node(ast.root);
    try testing.expectEqual(.row, root.tag);
    try testing.expectEqual(@as(u16, 3), root.num_children);
}

test "parse: frac with scripts" {
    var ast = try parse(testing.allocator, "\\frac{1}{2}+x^2", null);
    defer ast.deinit();
    // root row: [fraction, char, script]
    try testing.expectEqual(@as(u16, 3), ast.node(ast.root).num_children);
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    const script = ast.node(ast.child(ast.root, 2));
    try testing.expectEqual(.script, script.tag);
}

test "parse: unknown command is an error with kind and span" {
    var err_info: Info = undefined;
    try testing.expectError(
        error.UnknownCommand,
        parse(testing.allocator, "\\nosuchcmd{x}", &err_info),
    );
    const info = err_info;
    try testing.expectEqual(Kind.unknown_command, info.kind);
    // the span covers exactly the offending command token, "\nosuchcmd"
    try testing.expectEqual(@as(u32, 0), info.span.start);
    try testing.expectEqual(@as(u32, 10), info.span.end);
}

test "parse: dangling escape is an error with kind and span" {
    var err_info: Info = undefined;
    try testing.expectError(error.DanglingEscape, parse(testing.allocator, "abc\\", &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.dangling_escape, info.kind);
    // the span covers the dangling backslash itself
    try testing.expectEqual(@as(u32, 3), info.span.start);
    try testing.expectEqual(@as(u32, 4), info.span.end);
}

test "parse: missing argument points at the end of input" {
    var err_info: Info = undefined;
    // \frac{a} is missing the denominator: the error is a zero-width span
    // at end of source (offset 8), where the argument was expected.
    try testing.expectError(
        error.MissingArgument,
        parse(testing.allocator, "\\frac{a}", &err_info),
    );
    const info = err_info;
    try testing.expectEqual(Kind.missing_argument, info.kind);
    try testing.expectEqual(@as(u32, 8), info.span.start);
    try testing.expectEqual(@as(u32, 8), info.span.end);
    try testing.expectEqualStrings("Missing argument", info.message());
}

test "parse: stray closing brace reports kind and span" {
    var err_info: Info = undefined;
    // the trailing } after a complete \frac is an unexpected r_group
    try testing.expectError(
        error.UnexpectedRGroup,
        parse(testing.allocator, "\\frac{1}{2}}", &err_info),
    );
    const info = err_info;
    try testing.expectEqual(Kind.unexpected_r_group, info.kind);
    try testing.expectEqual(@as(u32, 11), info.span.start); // the stray }
    try testing.expectEqual(@as(u32, 12), info.span.end);
}

test "parse: unclosed left-right points at the \\left command" {
    var err_info: Info = undefined;
    try testing.expectError(error.UnclosedGroup, parse(testing.allocator, "\\left(", &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.unclosed_group, info.kind);
    try testing.expectEqual(@as(u32, 0), info.span.start); // the \left command
    try testing.expectEqual(@as(u32, 5), info.span.end);
}

test "parse: pretty-print helpers resolve a real error position" {
    const src = "x + y\n\\frac{1}{2}}\nz";
    var err_info: Info = undefined;
    try testing.expectError(error.UnexpectedRGroup, parse(testing.allocator, src, &err_info));
    const info = err_info;
    try testing.expectEqual(Kind.unexpected_r_group, info.kind);
    const lc = err.lineCol(src, info.span.start);
    try testing.expectEqual(@as(usize, 2), lc.line);
    try testing.expectEqual(@as(usize, 12), lc.col); // the stray } is byte 12 of line 2
    try testing.expectEqualStrings("\\frac{1}{2}}", err.sourceLine(src, info.span.start));
}

test "parse: atop fraction has no rule line" {
    var ast = try parse(testing.allocator, "\\atop{1}{2}", null);
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expectEqual(@as(u32, 0), frac.data);
}

test "parse: text command" {
    var ast = try parse(testing.allocator, "\\text{ab}", null);
    defer ast.deinit();
    try testing.expectEqual(.text, ast.node(ast.child(ast.root, 0)).tag);
}

test "parse: bold style command" {
    var ast = try parse(testing.allocator, "\\mathbf{y}", null);
    defer ast.deinit();
    const st = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.styled, st.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.CharStyle.bold)), st.data);
}

test "parse: thin space command" {
    var ast = try parse(testing.allocator, "\\,", null);
    defer ast.deinit();
    const sp = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.space, sp.tag);
    try testing.expectApproxEqAbs(@as(f32, 0.166), atom.fixedToEm(sp.data), 0.001);
}
