//! ztex.layout — atom tree → superflat box tree → draw list.
//!
//! Usable on its own: give it any `atom.Ast` (from ztex.parse or hand-built)
//! plus a root node index, and it produces an SVG-style `draw.DrawList`.
//!
//! Layout only MEASURES. It reads the atom tree and a `metrics.FontMetrics`
//! and allocates the box pool, but it never lexes or parses (`ztex.parse`
//! builds the tree) and never paints or opens a file (`ztex.svg` and
//! `ztex.raster` consume the draw list). `render` owns its scratch box pool
//! and frees it before returning; the caller owns the allocator, the
//! `DrawList` it gets back, and the source bytes that draw list borrows.

const std = @import("std");
const atom = @import("ztex.atom");

pub const metrics = @import("metrics.zig");
pub const draw = @import("draw.zig");
pub const layout = @import("layout.zig");

/// The math styles a formula can start in (`atom.MathStyle`); the parameter
/// type of `render` below.
pub const Style = layout.Style;
/// Layout failures: `error.InvalidArgument` for a call argument outside its
/// documented domain, `error.OutOfMemory`, `error.InvalidAst` for a
/// malformed hand-built tree, plus the failures a wired font raises while
/// resolving a stretchy MATH form (`metrics.StretchError`). See
/// `layout.Error`.
pub const Error = layout.Error;
/// The box pool `layout.layout` fills, named here so a caller that drives
/// that low-level entry itself can build and own one instead of reaching
/// into the module tree.
pub const box = @import("box.zig");

/// Lay out an atom tree and flatten it to a draw list.
///
/// `fm` selects the metric source: `&metrics.default` for the bundled static
/// tables (`ztex.render`), or a Context's font-backed union arm
/// (`Context.render`) — this is the ONE shared pipeline; both facades call
/// it. It is borrowed for this call only and is not retained; a `.font` arm
/// calls back into the `FontHook` it carries, so the context and the MATH
/// constants those callbacks borrow must stay live for the whole call. The
/// returned `DrawList`'s `text` primitives ALIAS `ast.src`, so the source
/// bytes must outlive the draw list; the `Ast` itself need not, because
/// nothing in a draw list names a node or a token — it carries byte offsets
/// only. The box pool is scratch and is freed before returning.
///
/// `style` is the math style the formula STARTS in, which TeX fixes per
/// formula: `.display` for a standalone equation, `.text` for one set inline
/// in running prose. It sets the base size and the limits/subscript rules for
/// everything that follows; `\displaystyle` and friends override it locally
/// from there. A host rendering inline math must pass `.text`, or its
/// fractions and integrals come out display-sized.
///
/// `size_pt` is the base font size in POINTS; every dimension the layout
/// derives is a multiple of it. It must be finite and greater than zero — 0,
/// a negative size, an infinity or a NaN returns `error.InvalidArgument`
/// before the tree is even read, rather than a draw list whose extents are
/// not a frame.
///
/// The tree is validated ONCE at this boundary, and every datum the
/// recursive layout reads is checked there: each node's child count against
/// its tag's expected arity, every child index in bounds, the reachable
/// subgraph tree-shaped (a repeat visit is a cycle or a shared child), the
/// depth within `atom.max_ast_depth` — the bound the recursive descent
/// itself needs — each node's token run inside the token table, every token
/// span inside `ast.src`, and every `data` that names something layout can
/// decode: an enum member (a `CharStyle` on `.styled`/`.text`, a `MathStyle`
/// on `.mathstyle` and in a fraction's forced-style field, a `BigOp` on
/// `.op`, an `EnvKind` on `.env`), an index into a fixed table (the `\big`
/// level a `.left` delimiter node carries), or a Unicode scalar (a `.char`
/// codepoint override). Every `.hline` must be an entry of an `.env`.
/// Marker rows require their dispatched fields. Environment rows require a
/// cell, with `.row.data` interpreted as stretch metadata rather than a row
/// marker; only boundary delimiter leaves and row/rule entries are accepted.
/// Packed environment colspec counts must fit `EnvBits.max_spec_cols`.
/// A malformed hand-built AST returns `error.InvalidAst` instead of trapping
/// in `Ast.span`, `@enumFromInt`, `utf8Encode` or the box asserts.
///
/// What is deliberately NOT a rejection here: a payload that is a bit
/// pattern rather than a decode target. A `.space` width may be negative (a
/// `\kern-3mu` sign) or, in a hand-built tree, non-finite — it only ever
/// multiplies a size, so it cannot read out of bounds, and the back ends
/// already refuse a non-finite coordinate with their own error. A source
/// span that cuts a UTF-8 codepoint in half decodes to U+0000 (the defined
/// fallback, not a trap), because `ast.src` is the LEXER's input and is
/// expected to be well-formed UTF-8 at its token boundaries; scanning the
/// whole source for that here would cost every render to defend against an
/// input the parser cannot produce.
///
/// Allocation and a font-backed geometry hook's decode errors propagate.
/// On any error the pool is freed and a partially built draw list is
/// released, so a caught error leaves nothing to clean up but the allocator
/// itself.
pub fn render(
    gpa: std.mem.Allocator,
    ast: *const atom.Ast,
    root: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
) Error!draw.DrawList {
    // Every box dimension is a multiple of the base size, so a size that is
    // not a positive finite number scales the whole formula into NaN or a
    // negative frame. Refuse it before the tree is read and before anything
    // is allocated.
    if (!std.math.isFinite(size_pt) or size_pt <= 0) return error.InvalidArgument;
    try validateAst(gpa, ast, root);
    var list = box.BoxList.init(gpa);
    defer list.deinit();
    // Pre-reserve a safe over-bound: a single node can emit more boxes than
    // itself (1 scripted op node → 3 boxes; 1 text node → N grapheme boxes),
    // so reserve 2× nodes for the pools plus one per node for the reusable
    // placement scratch. These are capacity-only hints; they remove the
    // geometric realloc/copy churn in BoxList.create without touching any
    // geometry. Under-reserving is graceful (the pool grows on demand).
    const est_boxes = @max(16, ast.nodes.items.len * 2);
    try list.boxes.ensureTotalCapacity(gpa, est_boxes);
    try list.chars.ensureTotalCapacity(gpa, est_boxes);
    try list.childrefs.ensureTotalCapacity(gpa, est_boxes);
    try list.scratch.ensureTotalCapacity(gpa, est_boxes);
    const root_box = try layout.layout(&list, ast, root, fm, style, size_pt, .italic);
    var out = draw.DrawList.init(gpa);
    errdefer out.deinit();
    // Capacity-only hint: flatten emits at most one draw per box, and boxes
    // can exceed nodes (see above).
    try out.items.ensureTotalCapacity(gpa, ast.nodes.items.len);
    try draw.flatten(&list, root_box, ast.src, 0, 0, &out);
    const rb = list.get(root_box);
    out.width = rb.width;
    out.height = rb.height;
    out.depth = rb.depth;
    return out;
}

/// Whether a node's child count matches its tag's expected arity, per the
/// atom.zig layout docs: fixed-arity tags (group/styled/mathstyle/opname/
/// overline = 1, char/space/text/op = 0, fraction = 2, mathchoice = 4),
/// bounded ranges (left = 1..3, substack/env = 1+), and the script node,
/// whose children are [base, sup?, sub?] — one slot per ScriptBits presence
/// bit. Plain rows accept any count; marker rows need their dispatched fields.
/// Environment rows hold cells and stretch metadata, not row-family markers.
fn arityOk(tag: atom.Tag, n: atom.Node, env_row: bool) bool {
    return switch (tag) {
        .row => if (env_row) n.num_children > 0 else rowArityOk(n),
        .group, .styled, .mathstyle, .opname, .overline, .boxed, .color, .textcolor => n.num_children == 1,
        .char, .space, .text, .op, .hline => n.num_children == 0,
        .script => n.num_children ==
            1 +
                @as(u16, @intFromBool(n.data & atom.ScriptBits.sup != 0)) +
                @as(u16, @intFromBool(n.data & atom.ScriptBits.sub != 0)),
        .fraction => n.num_children == 2,
        .left => n.num_children >= 1 and n.num_children <= 3,
        .mathchoice => n.num_children == 4,
        .substack, .env => n.num_children >= 1,
    };
}

fn rowArityOk(n: atom.Node) bool {
    // Match layoutInner's row dispatch: sqrt/accent/limits read two fields,
    // not/brace/tag/phantom/kern read at least one. Other rows are sequences.
    switch (n.data) {
        1, 2, 8, 9, 10, 14, 15 => return n.num_children >= 2,
        3, 11, 12, 64 => return n.num_children >= 1,
        else => {},
    }
    if (n.data & ((1 << 4) | (1 << 5)) != 0) return n.num_children >= 1;
    return true;
}

/// The `\big`-family ladder level. `\big \Big \bigg \Bigg` is 1..4, and
/// layout's fixed delimiter ladder has one entry per level plus an unused 0.
const max_big_level: u32 = 4;

/// The low bits of a `.char` node's `data` that hold its codepoint. A
/// `\middle` placeholder ORs `layout.middle_marker` into bit 21; every read
/// of the codepoint truncates to u21 and keeps exactly these bits.
const cp_mask: u32 = 0x1F_FFFF;

/// Whether every child of a `.left` node is a delimiter leaf — the shape a
/// `\big`-family node has (a delimiter and no inner row), and the one whose
/// `data` layout reads as a ladder level. The caller has already checked the
/// child run is inside the pool.
fn allDelimiterLeaves(ast: *const atom.Ast, n: atom.Node) bool {
    const end = n.first_child + n.num_children;
    var c = n.first_child;
    while (c < end) : (c += 1) {
        if (ast.nodes.items[c].tag != .char) return false;
    }
    return true;
}

/// Whether the node's `data` names something layout can decode: a member of
/// the enum its tag carries it as, an index into a table it looks up, or a
/// Unicode scalar value. Layout reads these payloads with `@enumFromInt`,
/// which traps on a value outside its enum, indexes fixed tables with them,
/// which reads out of bounds, and hands them to `utf8Encode`, which fails on
/// a non-scalar; a hand-built `data` is checked here instead. Tags whose
/// `data` is a bit pattern or a boolean — a `.space` width, an `.opname`
/// limits flag, the row markers, the fraction bits — decode to none of those
/// and are always in range.
fn dataOk(ast: *const atom.Ast, n: atom.Node) bool {
    return switch (n.tag) {
        .styled, .text => n.data < std.meta.fields(atom.CharStyle).len,
        .mathstyle => n.data < std.meta.fields(atom.MathStyle).len,
        .op => (n.data & atom.LimitsBits.value_mask) < std.meta.fields(atom.BigOp).len,
        .env => (n.data & atom.EnvBits.kind_mask) < std.meta.fields(atom.EnvKind).len and
            atom.envSpecCount(n.data) <= atom.EnvBits.max_spec_cols,
        .fraction => blk: {
            // 0 = no forced style, otherwise the field is a MathStyle + 1.
            const code = (n.data >> atom.FractionBits.forced_shift) &
                atom.FractionBits.forced_mask;
            break :blk code == 0 or code - 1 < std.meta.fields(atom.MathStyle).len;
        },
        // The codepoint `data` names, or 0 = "read it from the source span".
        .char => blk: {
            const cp = n.data & cp_mask;
            break :blk cp <= 0x10_FFFF and (cp < 0xD800 or cp > 0xDFFF);
        },
        // `\big` reads its ladder level; a stretched `\left..\right` fence
        // ignores `data` and picks its rung from the content height.
        .left => !allDelimiterLeaves(ast, n) or n.data <= max_big_level,
        // A row's `data` is a family marker, and a class-override row masks
        // its class to three bits against an eight-member enum, so neither
        // field can land out of range.
        .row,
        .space,
        .script,
        .group,
        .opname,
        .overline,
        .mathchoice,
        .substack,
        .color,
        .textcolor,
        .boxed,
        .hline,
        => true,
    };
}

/// A nonempty token run must fit the table and compose a valid source span.
/// Individually valid tokens can still produce `start > end` across the run.
fn tokenRunOk(ast: *const atom.Ast, n: atom.Node) bool {
    if (n.num_tokens == 0) return true;
    const end = @as(u64, n.first_token) + n.num_tokens;
    if (end > ast.tokens.items.len) return false;
    return ast.tokens.items[n.first_token].start <=
        ast.tokens.items[@as(usize, @intCast(end - 1))].end;
}

/// One unit of worklist state: the node to visit and how many ancestors it
/// has, the root counting as 1.
const Work = struct { idx: u32, depth: u32, env_row: bool = false };

/// Validate the root-reachable subtree ONCE at the layout boundary, and check
/// every datum the recursive layout reads out of the AST, because none of
/// those reads is bounded where it happens:
///   · every token must describe a real slice of `ast.src` (`start <= end`,
///     `end <= src.len`) — layout draws glyphs from `src[start..end]`;
///   · every node's child count must match its tag's arity, and its token
///     run must fit the token table;
///   · every `data` that names a decode target — an enum member, a fixed
///     table index, or a Unicode scalar — must be one layout can read (see
///     `dataOk`);
///   · every child index must be in bounds, and the reachable subgraph must
///     be a TREE — a repeated visit is a cycle or a shared child, either of
///     which the recursive layout would mis-lay-out (a cycle forever);
///   · the tree must be no deeper than `atom.max_ast_depth`, the bound the
///     recursive descent itself needs;
///   · a `.hline` may appear only as an entry of an `.env`, because it is
///     the one tag the generic row path has no arm for.
///
/// The walk is iterative (worklist), so a pathological tree cannot overflow
/// the validator's own stack, and the small-tree path allocates nothing. On
/// any violation returns `error.InvalidAst`; the `Ast.child` @panic, the
/// `@enumFromInt` traps and the BoxList asserts stay as internal invariant
/// checks that a validated tree never trips.
fn validateAst(
    gpa: std.mem.Allocator,
    ast: *const atom.Ast,
    root: u32,
) error{ OutOfMemory, InvalidAst }!void {
    const count = ast.nodes.items.len;
    if (root >= count) return error.InvalidAst;
    for (ast.tokens.items) |t| {
        if (t.start > t.end or t.end > ast.src.len) return error.InvalidAst;
    }
    if (ast.nodes.items[root].tag == .hline) return error.InvalidAst;

    var seen_buf: [128]bool = undefined;
    var work_buf: [128]Work = undefined;

    const seen = if (count <= seen_buf.len)
        seen_buf[0..count]
    else
        try gpa.alloc(bool, count);
    defer if (count > seen_buf.len) gpa.free(seen);

    @memset(seen, false);
    seen[root] = true;

    var work_len: usize = 1;
    var dyn_work: ?std.ArrayList(Work) = null;
    defer if (dyn_work) |*w| w.deinit(gpa);

    work_buf[0] = .{ .idx = root, .depth = 1 };

    while (work_len > 0) {
        work_len -= 1;
        const item = if (dyn_work) |*w| blk: {
            // `work_len` mirrors `w.items.len`; only malformed worklist state
            // can make this pop empty, so report the existing AST error.
            break :blk w.pop() orelse return error.InvalidAst;
        } else work_buf[work_len];
        if (item.depth > atom.max_ast_depth) return error.InvalidAst;

        const n = ast.nodes.items[item.idx];
        if (!arityOk(n.tag, n, item.env_row)) return error.InvalidAst;
        if (!tokenRunOk(ast, n)) return error.InvalidAst;
        if (n.num_children == 0) {
            if (!dataOk(ast, n)) return error.InvalidAst;
            continue;
        }
        if (n.first_child > std.math.maxInt(u32) - @as(u32, n.num_children)) return error.InvalidAst;
        const end = n.first_child + n.num_children;
        // The whole run at once, so the payload checks that read a child (the
        // `\big` shape test) stay inside the pool.
        if (end > count) return error.InvalidAst;
        if (!dataOk(ast, n)) return error.InvalidAst;
        const in_env = n.tag == .env;
        var c = n.first_child;
        while (c < end) : (c += 1) {
            if (c >= count) return error.InvalidAst;
            if (seen[c]) return error.InvalidAst;
            if (!in_env and ast.nodes.items[c].tag == .hline) return error.InvalidAst;
            if (in_env) switch (ast.nodes.items[c].tag) {
                .row, .hline => {},
                .char => if (c != n.first_child and c + 1 != end) return error.InvalidAst,
                else => return error.InvalidAst,
            };
            seen[c] = true;
            const next: Work = .{
                .idx = c,
                .depth = item.depth + 1,
                .env_row = in_env and ast.nodes.items[c].tag == .row,
            };
            if (dyn_work) |*w| {
                try w.append(gpa, next);
                work_len += 1;
            } else if (work_len < work_buf.len) {
                work_buf[work_len] = next;
                work_len += 1;
            } else {
                var w: std.ArrayList(Work) = .empty;
                try w.ensureTotalCapacity(gpa, count);
                try w.appendSlice(gpa, work_buf[0..work_len]);
                try w.append(gpa, next);
                dyn_work = w;
                work_len += 1;
            }
        }
    }
}

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "render: a single char yields one text primitive" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    _ = try ast.createLeaf(.char, 0, 1, 0); // node 0: a char leaf
    var out = try render(testing.allocator, &ast, 0, &metrics.default, .display, 20);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.len());
    try testing.expectEqualStrings("𝑥", out.items.items[0].text.bytes);
    try testing.expectEqual(@as(f32, 20), out.items.items[0].text.size);
}

test "render: wrong arity returns error.InvalidAst, not a panic" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    _ = try ast.createNode(.group, 0, 1, &.{}, 0); // a group with 0 children
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: out-of-bounds child index returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    // a row whose single child points past the pool end
    _ = try ast.pushNode(.{
        .tag = .row,
        .first_token = 0,
        .num_tokens = 1,
        .first_child = 7,
        .num_children = 1,
        .data = 0,
    });
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: a cyclic tree returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    // a row that is its own child (self-loop)
    _ = try ast.pushNode(.{
        .tag = .row,
        .first_token = 0,
        .num_tokens = 1,
        .first_child = 0,
        .num_children = 1,
        .data = 0,
    });
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: a node whose first token is out of range returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    // Node 0 starts at token 5 of a one-token table: `Ast.span` would read
    // `tokens.items[5]` with no bound of its own.
    _ = try ast.createLeaf(.char, 5, 1, 0);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: a token count running past the token table returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    // The first token is in range and the count is not, so it is the LAST
    // token of the run — `first_token + num_tokens - 1` — that is unchecked.
    _ = try ast.createLeaf(.char, 0, 4, 0);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: a token span past the end of the source returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 99 });
    _ = try ast.createLeaf(.char, 0, 1, 0);
    // The glyph is drawn from `ast.src[start..end]`; the slice is the
    // unchecked read.
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: a reversed token span returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "xy");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 1, .end = 0 });
    _ = try ast.createLeaf(.char, 0, 1, 0);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: a .text leaf whose payload is not a CharStyle returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "{ab}");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 4 });
    _ = try ast.createLeaf(.text, 0, 1, 200);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: a .styled node whose payload is not a CharStyle returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const base = try ast.createLeaf(.char, 0, 1, 0);
    const root = try ast.createNode(.styled, 0, 1, &.{ast.node(base)}, 200);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: a .mathstyle node whose data is not a MathStyle returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const base = try ast.createLeaf(.char, 0, 1, 0);
    const root = try ast.createNode(.mathstyle, 0, 1, &.{ast.node(base)}, 200);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: a big operator outside the BigOp enum returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const op = try ast.createLeaf(.op, 0, 1, 0x1234);
    const root = try ast.createNode(.row, 0, 1, &.{ast.node(op)}, 0);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: an environment kind outside the EnvKind enum returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "ab");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 2 });
    const row = try ast.createNode(.row, 0, 1, &.{}, 0);
    const root = try ast.createNode(.env, 0, 1, &.{ast.node(row)}, 0xF);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: a fraction whose forced-style code is not a MathStyle returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "ab");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try ast.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try ast.createLeaf(.char, 0, 1, 0);
    const den = try ast.createLeaf(.char, 1, 1, 0);
    // Every forced-style code but the four MathStyle codes + 1 (0 = none).
    const root = try ast.createNode(
        .fraction,
        0,
        2,
        &.{ ast.node(num), ast.node(den) },
        atom.FractionBits.forced_mask << atom.FractionBits.forced_shift,
    );
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: a .hline outside an environment returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    _ = try ast.createLeaf(.hline, 0, 1, 0);
    // `.hline` is a rule entry of an `.env`, never an atom the generic row
    // path can dispatch.
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, 0, &metrics.default, .display, 20),
    );
}

test "render: a .hline inside a row returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const rule = try ast.createLeaf(.hline, 0, 1, 0);
    const root = try ast.createNode(.row, 0, 1, &.{ast.node(rule)}, 0);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: a tree one level past max_ast_depth returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    var cur = ast.node(try ast.createLeaf(.char, 0, 1, 0));
    var depth: u32 = 1;
    while (depth <= atom.max_ast_depth) : (depth += 1) {
        cur = ast.node(try ast.createNode(.row, 0, 1, &.{cur}, 0));
    }
    try testing.expectEqual(atom.max_ast_depth + 1, depth);
    const root: u32 = @intCast(ast.nodes.items.len - 1);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: a tree exactly max_ast_depth deep still lays out" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    var cur = ast.node(try ast.createLeaf(.char, 0, 1, 0));
    var depth: u32 = 1;
    while (depth < atom.max_ast_depth) : (depth += 1) {
        cur = ast.node(try ast.createNode(.row, 0, 1, &.{cur}, 0));
    }
    const root: u32 = @intCast(ast.nodes.items.len - 1);
    var out = try render(testing.allocator, &ast, root, &metrics.default, .display, 20);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.len());
    try testing.expectEqualStrings("𝑥", out.items.items[0].text.bytes);
}

test "render: a size that is not a positive finite number returns error.InvalidArgument" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    _ = try ast.createLeaf(.char, 0, 1, 0);
    const bad = [_]f32{
        0,
        -10,
        std.math.inf(f32),
        -std.math.inf(f32),
        std.math.nan(f32),
    };
    for (bad) |size| {
        try testing.expectError(
            error.InvalidArgument,
            render(testing.allocator, &ast, 0, &metrics.default, .display, size),
        );
    }
}

test "render: a \\big delimiter whose ladder level is out of range returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "(");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const delim = try ast.createLeaf(.char, 0, 1, '(');
    // A `.left` whose children are all delimiter leaves IS the \big family,
    // and its `data` is the level that indexes the fixed ladder.
    const root = try ast.createNode(.left, 0, 1, &.{ast.node(delim)}, 99);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: a synthesized .char whose payload is not a Unicode scalar returns error.InvalidAst" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    // Bit 21 is the `\middle` placeholder marker: such a box is drawn from
    // the codepoint in `data` and duped into the glyph arena, so a value
    // past U+10FFFF reaches `utf8Encode` and the run would come out empty.
    const mid = try ast.createLeaf(.char, 0, 1, (1 << 21) | 0x11_0000);
    const root = try ast.createNode(.row, 0, 1, &.{ast.node(mid)}, 0);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: a \\middle placeholder with a scalar codepoint still draws" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const mid = try ast.createLeaf(.char, 0, 1, (1 << 21) | '|');
    const root = try ast.createNode(.row, 0, 1, &.{ast.node(mid)}, 0);
    var out = try render(testing.allocator, &ast, root, &metrics.default, .display, 20);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.len());
    try testing.expectEqualStrings("|", out.items.items[0].text.bytes);
}

test "render: individually valid tokens cannot form a reversed aggregate span" {
    var ast = atom.Ast.init(testing.allocator, "xyz");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const root = try ast.createLeaf(.char, 0, 2, 0);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: synthesized surrogate codepoints are not Unicode scalars" {
    for ([_]u32{ 0xD800, 0xDFFF }) |cp| {
        var ast = atom.Ast.init(testing.allocator, "x");
        defer ast.deinit();
        try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
        const root = try ast.createLeaf(.char, 0, 1, (1 << 21) | cp);
        if (render(testing.allocator, &ast, root, &metrics.default, .display, 20)) |result| {
            var unexpected = result;
            unexpected.deinit();
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(error.InvalidAst, err);
        }
    }
}

test "render: fixed-arity row families reject missing children" {
    const families = [_]u32{ 1, 2, 3, 8, 9, 10, 11, 12, 14, 15, 16, 32, 64 };
    for (families) |data| {
        var ast = atom.Ast.init(testing.allocator, "x");
        defer ast.deinit();
        try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
        const root = try ast.createLeaf(.row, 0, 1, data);
        try testing.expectError(
            error.InvalidAst,
            render(testing.allocator, &ast, root, &metrics.default, .display, 20),
        );
    }
}

test "render: cases rows require a cell even when the row is empty" {
    var ast = atom.Ast.init(testing.allocator, "");
    defer ast.deinit();
    const row = try ast.createLeaf(.row, 0, 0, 0);
    const root = try ast.createNode(
        .env,
        0,
        0,
        &.{ast.node(row)},
        atom.envData(.cases, ""),
    );
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: an environment cannot name more colspec slots than its encoding holds" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const cell = try ast.createLeaf(.char, 0, 1, 0);
    const row = try ast.createNode(.row, 0, 1, &.{ast.node(cell)}, 0);
    const invalid_count = atom.EnvBits.max_spec_cols + 1;
    const data = atom.envData(.array, "") |
        (@as(u32, invalid_count) << atom.EnvBits.count_shift);
    const root = try ast.createNode(.env, 0, 1, &.{ast.node(row)}, data);
    try testing.expectError(
        error.InvalidAst,
        render(testing.allocator, &ast, root, &metrics.default, .display, 20),
    );
}

test "render: an environment row carries stretch metadata rather than a row family" {
    var ast = atom.Ast.init(testing.allocator, "x");
    defer ast.deinit();
    try ast.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const cell = try ast.createLeaf(.char, 0, 1, 0);
    const row = try ast.createNode(.row, 0, 1, &.{ast.node(cell)}, 1);
    const root = try ast.createNode(.env, 0, 1, &.{ast.node(row)}, atom.envData(.matrix, ""));
    var out = try render(testing.allocator, &ast, root, &metrics.default, .display, 20);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 1), out.len());
    try testing.expectEqualStrings("𝑥", out.items.items[0].text.bytes);
}
