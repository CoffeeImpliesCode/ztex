//! ztex.layout — atom tree → superflat box tree → draw list.
//!
//! Usable on its own: give it any `atom.Ast` (from ztex.parse or hand-built)
//! plus a root node index, and it produces an SVG-style `draw.DrawList`.

const std = @import("std");
const atom = @import("ztex.atom");

pub const metrics = @import("metrics.zig");
pub const draw = @import("draw.zig");
pub const layout = @import("layout.zig");

/// The math styles a formula can start in (`atom.MathStyle`); the parameter
/// type of `render` below.
pub const Style = layout.Style;
const box = @import("box.zig");

/// Lay out an atom tree and flatten it to a draw list.
///
/// `fm` selects the metric source: `&metrics.default` for the bundled static
/// tables (`ztex.render`), or a Context's font-backed union arm
/// (`Context.render`) — this is the ONE shared pipeline; both facades call
/// it. The returned `DrawList`'s `text` primitives alias `ast.src`, so the
/// source (and ast) must outlive the draw list. The box pool is scratch and
/// freed.
///
/// `style` is the math style the formula STARTS in, which TeX fixes per
/// formula: `.display` for a standalone equation, `.text` for one set inline
/// in running prose. It sets the base size and the limits/subscript rules for
/// everything that follows; `\displaystyle` and friends override it locally
/// from there. A host rendering inline math must pass `.text`, or its
/// fractions and integrals come out display-sized.
///
/// The tree is validated once at this boundary (child counts vs each tag's
/// expected arity, child indices in bounds, and a tree-shaped
/// root-reachable subgraph): a malformed hand-built AST returns
/// `error.InvalidAst` instead of panicking in `Ast.child` or the box
/// asserts. The only other failure is allocation.
pub fn render(
    gpa: std.mem.Allocator,
    ast: *const atom.Ast,
    root: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
) error{ OutOfMemory, InvalidAst }!draw.DrawList {
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
/// bit. `row` accepts any count (including 0 — an empty line).
fn arityOk(tag: atom.Tag, n: atom.Node) bool {
    return switch (tag) {
        .row => true,
        .group, .styled, .mathstyle, .opname, .overline => n.num_children == 1,
        .char, .space, .text, .op => n.num_children == 0,
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

/// Validate the root-reachable subtree ONCE at the layout boundary: every
/// node's child count must match its tag's arity, every child index must be
/// in bounds, and the reachable subgraph must be a TREE — a repeated visit
/// means a cycle or a shared child, either of which the recursive layout
/// would mis-lay-out (a cycle would recurse forever). The walk is iterative
/// (worklist), so a pathological tree cannot overflow the validator's own
/// stack. On any violation returns `error.InvalidAst`; the `Ast.child`
/// @panic and BoxList asserts stay as internal invariant checks that a
/// validated tree never trips.
fn validateAst(
    gpa: std.mem.Allocator,
    ast: *const atom.Ast,
    root: u32,
) error{ OutOfMemory, InvalidAst }!void {
    const count = ast.nodes.items.len;
    if (root >= count) return error.InvalidAst;

    var seen_buf: [128]bool = undefined;
    var work_buf: [128]u32 = undefined;

    const seen = if (count <= seen_buf.len)
        seen_buf[0..count]
    else
        try gpa.alloc(bool, count);
    defer if (count > seen_buf.len) gpa.free(seen);

    @memset(seen, false);
    seen[root] = true;

    var work_len: usize = 1;
    var dyn_work: ?std.ArrayList(u32) = null;
    defer if (dyn_work) |*w| w.deinit(gpa);

    work_buf[0] = root;

    while (work_len > 0) {
        work_len -= 1;
        const idx = if (dyn_work) |*w| blk: {
            // `work_len` mirrors `w.items.len`; only malformed worklist state
            // can make this pop empty, so report the existing AST error.
            const item = w.pop() orelse return error.InvalidAst;
            break :blk item;
        } else work_buf[work_len];

        const n = ast.nodes.items[idx];
        if (!arityOk(n.tag, n)) return error.InvalidAst;
        if (n.num_children == 0) continue;
        if (n.first_child > std.math.maxInt(u32) - @as(u32, n.num_children)) return error.InvalidAst;
        const end = n.first_child + n.num_children;
        var c = n.first_child;
        while (c < end) : (c += 1) {
            if (c >= count) return error.InvalidAst;
            if (seen[c]) return error.InvalidAst;
            seen[c] = true;
            if (dyn_work) |*w| {
                try w.append(gpa, c);
                work_len += 1;
            } else if (work_len < work_buf.len) {
                work_buf[work_len] = c;
                work_len += 1;
            } else {
                var w: std.ArrayList(u32) = .empty;
                try w.ensureTotalCapacity(gpa, count);
                try w.appendSlice(gpa, work_buf[0..work_len]);
                try w.append(gpa, c);
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
