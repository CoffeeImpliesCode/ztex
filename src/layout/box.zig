//! ztex.layout.box — superflat TeX box model.
//!
//! Same pattern as the atom AST: one flat array of fixed-size boxes, with
//! child placement stored as contiguous index runs in a parallel array. A box
//! carries its own dimensions (width/height/depth) plus a source byte span, so
//! every drawable downstream can map back to input text.
//!
//! Child placement is per-parent, so it lives in `ChildRef` (index + offsets),
//! never in the shared child box. `flatten` positions each child at
//! `(x + cr.x_shift, y + cr.shift)` uniformly.

const std = @import("std");
const atom = @import("ztex.atom");

pub const Kind = enum(u8) {
    /// children laid left→right, baseline-aligned
    hbox,
    /// children stacked vertically (fraction); positioned by shift
    vbox,
    /// a single glyph; leaf
    char,
    /// invisible; metrics only
    glue,
    /// invisible strut; metrics only
    strut,
    /// filled rectangle (fraction bar, rule); leaf
    rule,
    /// base + superscript + subscript overlay
    script,
};

/// Per-parent child placement: which box, and where relative to the parent's
/// reference point (baseline).
pub const ChildRef = struct {
    idx: u32,
    x_shift: f32,
    shift: f32,
};

/// The form a big-operator char box draws. DISPLAY big-ops draw the
/// OpenType MATH-table .v1 variant glyph (what XeTeX draws for a display
/// operator); text/script big-ops draw the CMAP base glyph at the declared
/// size (the smaller form every other engine uses for a text-style
/// operator). The form rides through flatten into the SVG (svg.zig emits
/// `data-op="v1"` for `.variant`) so the rasterizer/verifier resolve the
/// right glyph — the declared font-size alone cannot tell them apart, since
/// both forms are emitted at the current size. Every non-big-op box keeps
/// the default `.base`.
pub const BigOpForm = enum(u8) {
    base,
    variant,
};

/// A flat, fixed-size laid-out box.
///
/// Box carries only the SHARED layout header (kind, dimensions, child run,
/// source span). Everything char-only — codepoint, style, size, and the
/// layout flags that ride along to flatten/SVG (synthetic, big-op form,
/// display-variant advance/ic, radical form, fixed-delimiter req) — lives
/// in the BoxList `chars` side table, indexed by box index and populated
/// only for `.char` boxes; rule/glue/strut/hbox/vbox/script boxes pay no
/// storage for it. Read/write char state through BoxList.charData /
/// charDataPtr, never directly on a Box.
pub const Box = struct {
    kind: Kind,
    width: f32,
    height: f32,
    depth: f32,
    /// index of the first ChildRef (into BoxList.childrefs). Meaningful only
    /// when `num_children > 0`; the no-children test is `num_children == 0`,
    /// NEVER `first_child == 0` — index 0 is a valid ChildRef slot.
    first_child: u32,
    num_children: u16,
    // provenance: byte span into the source this box came from
    src_start: u32,
    src_end: u32,
};

/// Char-only state of a glyph box, held in the BoxList side table
/// (BoxList.chars), not in Box. Every box index has an entry — `.char`
/// boxes get their real values in `create`, all other kinds the default.
pub const CharData = struct {
    /// the glyph codepoint
    cp: u21 = 0,
    /// effective font style
    style: atom.CharStyle = .italic,
    /// font size in points
    size: f32 = 0,
    /// true when the glyph is synthesized by layout (big operators,
    /// e.g. \sum → ∑) and has no matching source bytes to alias; false for
    /// every other box, meaning the drawn glyph equals the source span.
    /// Set true only in layout.layoutOp; layoutChar/layoutText boxes take the
    /// default false.
    synthetic: bool = false,
    /// display big-ops (MATH .v1 variant) vs the base form. Default
    /// `.base`; set to `.variant` only in layout.layoutOp for display ops.
    bigop_form: BigOpForm = .base,
    /// hmtx advance of the DISPLAY variant in em (∫/∮ .v1: 0.999;
    /// the limits ops' variants equal their base advance, e.g. ∑ 1.444).
    /// Set in layout.layoutOp for display ops; layoutOpLimits boxes a
    /// display limits-op vbox by it — XeTeX boxes the display ∫/∮ by the
    /// .v1 advance, not the base 0.665em. 0 for every other box.
    disp_advance: f32 = 0,
    /// MathItalicsCorrection of the DRAWN form, pt at the 10pt base
    /// (∫/∮: 3.32 base, 5.91 .v1). layoutOpLimits skews the limits by
    /// ±delta/2 with delta = this value for display ops (the .v1 ic — XeTeX
    /// measured) and the base glyph ic for text/script ops. 0 otherwise.
    disp_ic: f32 = 0,
    /// radical MATH-table variant index (0 = base √, 1–4 = radical.v1–v4).
    /// Set in layoutSqrt when a vertical variant is selected (the surd's ink
    /// height must cover the radicand; the base glyph is used when it suffices).
    /// svg.zig emits data-radical="v1" so the rasterizer resolves the variant
    /// glyph — the declared font-size alone cannot tell base from variant since
    /// both draw at the current math size. 0 for every other box.
    radical_form: u8 = 0,
    /// amsmath FIXED-rule delimiter (`\binom`/`\genfrac-with-delims`)
    /// req_em used to box this delimiter (binomialDelimReqEm(style) — e.g.
    /// 2.392 at display → parenleft.v6, ~1.09 at text → the base paren).
    /// 0 = a content-`\left` fence. Set in layout.layoutLeftRight for
    /// binom_fixed fences; svg.zig emits data-fixed-req so the rasterizer
    /// resolves the SAME req the layout boxed — the declared base font-size
    /// alone cannot tell a fixed fence apart from a content-sized one
    /// (a display `\binom{n}{k}` needs v6, which the ink-derived extent
    /// undershoots).
    delim_fixed: f32 = 0,
};

/// The flat box pool.
///
/// Do NOT copy a BoxList by value: it owns the `boxes`, `childrefs`,
/// `chars`, and `scratch` arrays and deinits them exactly once.
/// `init`/`deinit` must be paired 1:1; after `deinit` the list is unusable.
pub const BoxList = struct {
    gpa: std.mem.Allocator,
    boxes: std.ArrayList(Box) = .empty,
    childrefs: std.ArrayList(ChildRef) = .empty,
    /// Char-only box state, parallel to `boxes` (indexed by box index).
    /// `.char` boxes carry their codepoint/style/size and layout flags;
    /// every other kind keeps the default entry. Rule/glue/strut/hbox/vbox/
    /// script boxes pay no storage for char state.
    chars: std.ArrayList(CharData) = .empty,
    /// Reusable per-parent placement buffer. Layout fns save `items.len`,
    /// append their placements, hand the run to `create` (which copies it
    /// into `childrefs`), then restore `items.len` — so recursive reuse
    /// never aliases a live run and the buffer is allocated once.
    scratch: std.ArrayList(ChildRef) = .empty,

    pub fn init(gpa: std.mem.Allocator) BoxList {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *BoxList) void {
        self.boxes.deinit(self.gpa);
        self.childrefs.deinit(self.gpa);
        self.chars.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *const BoxList, idx: u32) Box {
        std.debug.assert(idx < self.boxes.items.len);
        return self.boxes.items[idx];
    }

    /// Char-only state of a box (codepoint, style, size, layout flags).
    /// Every box index has an entry; non-char boxes return the default.
    pub fn charData(self: *const BoxList, idx: u32) CharData {
        std.debug.assert(idx < self.chars.items.len);
        return self.chars.items[idx];
    }

    /// Mutable char-state slot, for post-create flagging (synthetic, big-op
    /// form, display advance/ic, radical form, fixed-delimiter req).
    pub fn charDataPtr(self: *BoxList, idx: u32) *CharData {
        std.debug.assert(idx < self.chars.items.len);
        return &self.chars.items[idx];
    }

    /// ChildRef run of a box (empty for leaves).
    ///
    /// Invalidation contract: the returned slice aliases `childrefs`
    /// storage. Any `create`/`createLeaf` call may reallocate that array and
    /// dangle the slice — never hold it across a `create` call.
    pub fn children(self: *const BoxList, idx: u32) []const ChildRef {
        // Read the fields straight from the pool instead of going through
        // `get` (which copies the whole Box) — one less by-value copy per
        // parent. `get` stays by-value for callers that want a Box.
        std.debug.assert(idx < self.boxes.items.len);
        const b = &self.boxes.items[idx];
        if (b.num_children == 0) return &.{};
        return self.childrefs.items[b.first_child .. b.first_child + b.num_children];
    }

    /// Append a box with a contiguous run of child placements; returns index.
    /// Char-only state (cp/style/size) goes into the `chars` side table,
    /// populated only for `.char` boxes — every other kind keeps the
    /// default entry and pays no storage for it.
    pub fn create(
        self: *BoxList,
        kind: Kind,
        width: f32,
        height: f32,
        depth: f32,
        placements: []const ChildRef,
        cp: u21,
        style: atom.CharStyle,
        size: f32,
        span: atom.Span,
    ) !u32 {
        const first: u32 = @intCast(self.childrefs.items.len);
        try self.childrefs.appendSlice(self.gpa, placements);
        const idx: u32 = @intCast(self.boxes.items.len);
        try self.boxes.append(self.gpa, .{
            .kind = kind,
            .width = width,
            .height = height,
            .depth = depth,
            .first_child = first,
            .num_children = @intCast(placements.len),
            .src_start = span.start,
            .src_end = span.end,
        });
        try self.chars.append(self.gpa, if (kind == .char)
            .{ .cp = cp, .style = style, .size = size }
        else
            .{});
        return idx;
    }

    /// Append a leaf box (no children).
    pub fn createLeaf(
        self: *BoxList,
        kind: Kind,
        width: f32,
        height: f32,
        depth: f32,
        span: atom.Span,
    ) !u32 {
        return self.create(kind, width, height, depth, &.{}, 0, .italic, 0, span);
    }
};

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "boxlist: leaf and parent with child placements" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    const a = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const b = try list.createLeaf(.char, 5.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    const children = [_]ChildRef{
        .{ .idx = a, .x_shift = 0, .shift = 0 },
        .{ .idx = b, .x_shift = 4.0, .shift = 0 },
    };
    const h = try list.create(.hbox, 9.0, 3.0, 0.5, &children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    const hb = list.get(h);
    try testing.expectEqual(@as(u16, 2), hb.num_children);
    try testing.expectEqual(@as(f32, 9.0), hb.width);
    const ch = list.children(h);
    try testing.expectEqual(@as(u32, a), ch[0].idx);
    try testing.expectEqual(@as(f32, 4.0), ch[1].x_shift);
    try testing.expectEqual(@as(u32, 0), hb.src_start);
    try testing.expectEqual(@as(u32, 2), hb.src_end);
}

test "boxlist: leaf has empty children" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    const c = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    try testing.expectEqual(@as(usize, 0), list.children(c).len);
}

test "boxlist: child offsets accumulate through nested parents" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    const a = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const b = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    const h_children = [_]ChildRef{
        .{ .idx = a, .x_shift = 0, .shift = 0 },
        .{ .idx = b, .x_shift = 4.0, .shift = 0 },
    };
    const h = try list.create(.hbox, 8.0, 3.0, 0.5, &h_children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    const v_children = [_]ChildRef{
        .{ .idx = h, .x_shift = 2.0, .shift = 5.0 },
    };
    const v = try list.create(.vbox, 8.0, 3.0, 0.5, &v_children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    const h_off = list.children(v)[0].x_shift;
    const b_off = list.children(h)[1].x_shift;
    try testing.expectEqual(@as(f32, 2.0), h_off);
    try testing.expectEqual(@as(f32, 4.0), b_off);
    // 'b' sits at the sum of every ancestor x_shift
    try testing.expectApproxEqAbs(@as(f32, 6.0), h_off + b_off, 0.001);
}
