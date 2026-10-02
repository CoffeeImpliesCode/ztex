//! ztex.parse — LaTeX math source → superflat atom tree.
//!
//! Usable on its own: `parse(gpa, src)` returns an `atom.Ast` you can inspect
//! or feed to `ztex.layout`. This is the only supported route into the module:
//! `lexer.zig`, `parser.zig` and `error.zig` are private files, and the lexer
//! and parser are reached through `parse` and their published types, never by
//! name. The one thing published besides `parse` that a caller outside this
//! package cannot guess is `err`, the diagnostic channel `parse` writes into.
//!
//! The module owns no I/O and no file: it reads the `src` slice it is handed
//! and keeps it, rather than copying it. The Ast it returns owns every node
//! and token it built, and one `ast.deinit()` releases them; the allocator is
//! the caller's and is never freed here.

const std = @import("std");
const atom = @import("ztex.atom");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

/// The parse-diagnostic module: `Info` (kind + span + message) and the
/// `lineCol`/`sourceLine` helpers a caller uses to turn a span into a
/// printable position. Reached here as `ztex.parse.err`.
pub const err = @import("error.zig");

/// The complete set of command names the parser recognizes (see
/// parser.supported_commands) — the single external answer to "what commands
/// does this parser support". Each name is the bytes after the backslash, so
/// `\frac` appears as `"frac"`. This is exactly the set `parse` accepts:
/// every other name fails with `error.UnknownCommand` and
/// `Kind.unknown_command`. Generated at comptime from the parser's own
/// dispatch table, so it cannot drift from what the parser does.
pub const supported_commands = parser.supported_commands;

/// Parse-error context (kind + span + message); see `err.Info`.
pub const Info = err.Info;
/// The parse-error kinds; see `err.Kind`.
pub const Kind = err.Kind;

/// Everything `parse` can fail with: the lexer's and parser's own sets plus
/// `error.SourceTooLarge`. Every tag except `error.OutOfMemory` carries a
/// matching `Kind` in `Info` when the caller passed a channel; all but
/// `error.SourceTooLarge` are SYNTAX failures in `src` — a construct the
/// module does not accept — and that one is the input-size bound below. All
/// of them leave nothing allocated: the partially built tree is released
/// before the error returns.
pub const Error = lexer.Error || parser.Error || error{
    /// the source exceeds `max_source_bytes` (too long for `Span`'s u32 byte offsets)
    SourceTooLarge,
};

/// Hard upper bound on `src.len`, in BYTES. `atom.Span` stores byte offsets as
/// u32, and the lexer's `emit` casts its usize positions with `@intCast`; a
/// source longer than `maxInt(u32)` bytes would overflow that cast (a
/// safe-mode panic / a ReleaseFast truncation). The bound is HALF of that
/// because the node pool grows to ~2× the token count on nested/scripted
/// way — a source near `maxInt(u32)` could push the pool past the cast. We
/// reject such sources up front with `error.SourceTooLarge` instead.
/// Realistic math input is orders of magnitude smaller; the bound only
/// guards the degenerate case.
///
/// This is a byte limit, not a codepoint one: a source of multi-byte codepoints
/// reaches it sooner. It is a hard precondition of `parse` and of every other
/// entry point in this module, so a caller with input of unknown size should
/// test it with `sourceTooLong` rather than learn the limit from a failure.
pub const max_source_bytes: usize = std.math.maxInt(u32) / 2;

/// True when a source of `len` bytes is too long for u32 byte offsets.
/// Factored out so the boundary is unit-testable without a multi-GiB
/// allocation.
pub fn sourceTooLong(len: usize) bool {
    return len > max_source_bytes;
}

/// Pre-lex and parse `src` into an atom tree. Caller owns the Ast: free with
/// `ast.deinit()`. `ast.src` aliases the caller's `src` (never copied), so
/// `src` must stay alive and unmodified for as long as the Ast is read: every
/// token span and every text leaf indexes into it, and a rewritten byte is
/// read as the source the caller replaced. Nothing else in the Ast borrows
/// from `src`, so the nodes may be copied out and kept after `src` is
/// released, while any token span, `.text` leaf or `Info.span` taken from
/// them does not survive it.
///
/// On a syntax failure `err_info` (when non-null) is filled with the kind and
/// the offending byte span before the error is returned, and the Ast is
/// released before the error reaches the caller — a failing call leaves the
/// caller owning nothing. On success `err_info` is untouched, and so it is on
/// `error.OutOfMemory`, which has no position in the source: a caller must
/// not read `err_info` unless it caught a syntax tag. `error.SourceTooLarge`
/// does fill it, with `Kind.source_too_large`.
///
/// A `null` `err_info` skips the diagnostic work entirely and the error
/// values are unchanged; the channel is a caller-owned out-parameter that is
/// never retained after the call.
///
/// Fails with `error.SourceTooLarge` before any allocation when `src` is past
/// `max_source_bytes`, with `Kind.source_too_large` and a zero-width span at
/// offset 0 in `err_info`.
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

test "parse: sourceTooLong boundary is maxInt(u32)/2" {
    // Constructing a real >2 GiB source is impractical, so the check is
    // factored into `sourceTooLong` and tested at the boundary directly.
    // maxInt(u32)/2: the node pool grows to ~2× the token count and
    // pushNode casts nodes.len to u32 (atom.zig) — see max_source_bytes.
    try testing.expectEqual(max_source_bytes, std.math.maxInt(u32) / 2);
    try testing.expect(!sourceTooLong(max_source_bytes)); // last representable
    try testing.expect(sourceTooLong(max_source_bytes + 1)); // first overflow
    try testing.expect(sourceTooLong(std.math.maxInt(usize)));
}

test "parse: full pipeline, x+1 becomes 3-char row" {
    var ast = try parse(testing.allocator, "x+1", null);
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 3), ast.tokens.items.len);
    const root = ast.node(ast.root);
    try testing.expectEqual(.row, root.tag);
    try testing.expectEqual(@as(u16, 3), root.num_children);
}

test "parse: flat row child-count overflow has kind and span" {
    const child_count_max: usize = std.math.maxInt(u16);
    const src = try testing.allocator.alloc(u8, child_count_max + 1);
    defer testing.allocator.free(src);
    @memset(src, 'x');

    {
        var ast = try parse(testing.allocator, src[0..child_count_max], null);
        defer ast.deinit();
        try testing.expectEqual(
            @as(u16, std.math.maxInt(u16)),
            ast.node(ast.root).num_children,
        );
    }

    var err_info: Info = undefined;
    try testing.expectError(
        error.ChildCountOverflow,
        parse(testing.allocator, src, &err_info),
    );
    try testing.expectEqual(Kind.child_count_overflow, err_info.kind);
    try testing.expectEqual(@as(u32, 0), err_info.span.start);
    try testing.expectEqual(@as(u32, @intCast(src.len)), err_info.span.end);
}

test "parse: nested row child-count overflow keeps inner span" {
    const child_count: usize = @as(usize, std.math.maxInt(u16)) + 1;
    const src = try testing.allocator.alloc(u8, child_count + 2);
    defer testing.allocator.free(src);
    src[0] = '{';
    @memset(src[1 .. 1 + child_count], 'x');
    src[1 + child_count] = '}';

    var err_info: Info = undefined;
    try testing.expectError(
        error.ChildCountOverflow,
        parse(testing.allocator, src, &err_info),
    );
    try testing.expectEqual(Kind.child_count_overflow, err_info.kind);
    try testing.expectEqual(@as(u32, 1), err_info.span.start);
    try testing.expectEqual(@as(u32, @intCast(1 + child_count)), err_info.span.end);
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

/// Build `"{{…{x}…}}"` with `n` nested groups.
fn nestedBraces(n: usize, buf: []u8) []const u8 {
    @memset(buf[0..n], '{');
    buf[n] = 'x';
    @memset(buf[n + 1 .. 2 * n + 1], '}');
    return buf[0 .. 2 * n + 1];
}

test "parse: deeply nested input returns NestingTooDeep, not a crash" {
    // 5000 nested groups ≈ 1 nesting level per byte; without the depth
    // guard this would overflow the C stack, which Zig cannot catch.
    // The guard trips at max_nesting and unwinds cleanly.
    var buf: [5000 * 2 + 1]u8 = undefined;
    const src = nestedBraces(5000, &buf);
    var err_info: Info = undefined;
    try testing.expectError(
        error.NestingTooDeep,
        parse(testing.allocator, src, &err_info),
    );
    const info = err_info;
    try testing.expectEqual(Kind.nesting_too_deep, info.kind);
    try testing.expectEqualStrings("Nesting too deep", info.message());
    // the span points at the opening brace that pushed past the bound
    // (depth max_nesting + 1 → token index max_nesting)
    try testing.expectEqual(@as(u32, parser.max_nesting), info.span.start);
    try testing.expectEqual(@as(u32, parser.max_nesting + 1), info.span.end);
}

test "parse: nesting boundary is max_nesting" {
    // `n` nested groups need `n + 1` active parseRow frames (the top-level
    // row plus one per group), so max_nesting − 1 groups parse (depth
    // reaches exactly max_nesting) and max_nesting groups trip the guard —
    // the depth limit must not change normal inputs.
    var ok_buf: [(parser.max_nesting - 1) * 2 + 1]u8 = undefined;
    const ok_src = nestedBraces(parser.max_nesting - 1, &ok_buf);
    var ast = try parse(testing.allocator, ok_src, null);
    defer ast.deinit();
    try testing.expectEqual(.group, ast.node(ast.child(ast.root, 0)).tag);

    var over_buf: [parser.max_nesting * 2 + 1]u8 = undefined;
    const over_src = nestedBraces(parser.max_nesting, &over_buf);
    try testing.expectError(
        error.NestingTooDeep,
        parse(testing.allocator, over_src, null),
    );
}

test "parse: nested fractions still parse at reasonable depth" {
    // The mutual parseRow/parseGroup/parseCommand recursion through
    // \frac args must be unaffected by the depth guard at sane nesting.
    // 20 levels: \frac{\frac{...\frac{1}{1}...}{1}}{1} (120 + 1 + 60 = 181
    // bytes, comfortably inside buf).
    const open: []const u8 = "\\frac{";
    const close: []const u8 = "}{1}";
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (0..20) |_| {
        @memcpy(buf[len .. len + open.len], open);
        len += open.len;
    }
    buf[len] = '1';
    len += 1;
    for (0..20) |_| {
        @memcpy(buf[len .. len + close.len], close);
        len += close.len;
    }
    var ast = try parse(testing.allocator, buf[0..len], null);
    defer ast.deinit();
    try testing.expectEqual(.fraction, ast.node(ast.child(ast.root, 0)).tag);
}
