//! ztex.layout.box — the box pool: fixed-size `Box` records, a parallel
//! `ChildRef` run per parent, a `CharData` side table, and a SPARSE `Poly`
//! table that only `.poly` boxes index.

const std = @import("std");
const atom = @import("ztex.atom");

pub const Kind = enum(u8) {
    /// children laid left→right, baseline-aligned
    hbox,
    /// children stacked vertically (fraction); positioned by shift
    vbox,
    char,
    /// invisible; metrics only
    glue,
    /// invisible; metrics only
    strut,
    /// filled rectangle (fraction bar, rule); leaf
    rule,
    /// a base with its scripts: children placed at the base's own script
    /// offsets. A real container like `hbox`/`vbox`, kept as its own kind
    /// because a consumer can tell a script box from a plain row without
    /// inspecting the children.
    script,
    /// a STROKED POLYLINE: one connected stroke, leaf — the long
    /// `\widehat` / `\widetilde` accent. Its geometry lives in the SPARSE
    /// `polys` side table, read through `BoxList.poly`.
    poly,
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

/// A laid-out box: fixed-size, stored in the BoxList pool.
///
/// Only the SHARED layout header lives here (kind, dimensions, child run,
/// source span). Everything char-only — codepoint, style, size, and the
/// layout flags that ride along to flatten/SVG (synthetic, big-op form,
/// display-variant advance/ic, radical form, fixed-delimiter req) — lives in
/// the BoxList `chars` side table, indexed by box index and populated only for
/// `.char` boxes; other kinds pay no storage for it. Read/write char state
/// through BoxList.charData/charDataPtr, never directly on a Box.
///
/// Polyline geometry is shaped the same way for the `.poly` kind only: the
/// box carries an index (`poly_idx`) into the sparse `polys` table, never
/// the geometry itself.
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
    /// index of this box's stroke record in `BoxList.polys`, or `no_poly`
    /// when it has none. Ordinary boxes (glyph, rule, glue, strut, and every
    /// container) own NO record, so the stroke table holds one entry per
    /// `.poly` box and nothing else. Read the record through `BoxList.poly`,
    /// never off this field.
    poly_idx: u32 = no_poly,
    // provenance: byte span into the source this box came from
    src_start: u32,
    src_end: u32,
    /// Paint override for everything this box draws, set by the layout arm
    /// that owns an explicit scope (`\color` / `\textcolor` / `\boxed`'s
    /// rules). `null` = inherit: the nearest enclosing box with a non-null
    /// color paints this box's subtree, and a formula with no scope at all
    /// leaves every primitive on the host's own foreground.
    ///
    /// It rides on the SHARED header, not the char side table, because a
    /// color scope also paints rules and lines — `\color{red}{a+b}` and a
    /// `\boxed` inside `\textcolor`. layout sets it ONLY on the scope's own
    /// transparent wrapper box, never on the primitives it contains: the
    /// override is a property of the scope, and flatten resolves the
    /// nearest non-null ancestor, so nested scopes restore the outer color
    /// without the layout rewriting a single flattened primitive.
    color: ?atom.Color = null,
};

pub const CharData = struct {
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
    /// content-sized `\left`/`\right` fence MATH-table variant index
    /// (0 = no fence sizing, the layout picked the BASE glyph; 1..7 =
    /// parenleft.vN etc. — the SMALLEST variant whose asc+desc ink covers
    /// `req_em`, with 7 as the ceiling when content exceeds every variant).
    /// Set in layout.layoutDelimChar for paired `\left..\right` fences;
    /// 0 for every `\big`/fixed/binom box (those carry `delim_fixed`
    /// instead — the FIXED req from amsmath's fraction-delim rule).
    /// svg.zig emits `data-delim-form="vN"` so the rasterizer resolves
    /// the same variant glyph the layout boxed — the declared base
    /// font-size alone cannot tell a stretched paren apart from a plain
    /// one (a `\left( \begin{pmatrix} ... \\ ... \\ ... \\ ... \end{pmatrix} \right)`
    /// at 20pt needs v6+, otherwise the paren is drawn at 20pt — too
    /// short for 4 rows of content).
    delim_form: u8 = 0,
    /// For a content-sized `\left`/`\right` fence whose required ink
    /// EXCEEDS the largest MATH-table variant (e.g. a 4-row pmatrix at
    /// 20pt needs ~4em > parenleft.v7's 2.99em): the exact required height
    /// in em of `size_pt`, carried so svg.zig can emit `data-delim-req`
    /// and the rasterizer build an XeTeX-style GlyphAssembly (top + N
    /// extenders + bottom) to that height instead of capping at the
    /// smallest variant (v7), which would leave the fence too short to
    /// cover the content. 0 when `delim_form`'s variant already covers
    /// `req_em` — the common, non-exhausted-ladder case.
    delim_req: f32 = 0,

    /// The DRAWN glyph's real ink overhang past its ADVANCE box, in POINTS at
    /// `size`: how far the ink reaches LEFT of the box origin (a negative
    /// left side bearing — math italic `j`, every combining mark, whose ink
    /// is drawn left of the zero-advance origin) and how far it reaches RIGHT
    /// of origin + advance (the italic and bold `f` hook, which leans past
    /// its own advance). Both are non-negative and 0 when the ink fits inside
    /// the advance box, so an ordinary glyph frames exactly as before; only a
    /// glyph that really reaches out widens the frame. The layout arm that
    /// created this box fills them from the SAME `metrics.glyphInkAt` lookup
    /// that sized its height and depth — never a second per-glyph lookup, and
    /// never a per-glyph allocation.
    ///
    /// 0 for any box that draws something other than its `cp`'s own glyph: a
    /// MATH-table delimiter or radical variant, a display big-op's `.v1` form
    /// and an assembled fence each paint a DIFFERENT glyph, whose horizontal
    /// ink is its own variant's and must never borrow the base codepoint's
    /// bounds. `flatten` enforces that, so a stray value cannot mis-frame a
    /// variant.
    ink_left: f32 = 0,
    ink_right: f32 = 0,
};

/// One vertex of a `.poly` box's stroke, relative to the box's reference
/// point (left edge, baseline), in the same y-down sense as every `shift`.
pub const PolyPoint = struct {
    dx: f32,
    dy: f32,
};

/// The most vertices a `.poly` stroke can have. `\widehat` uses 3 (ONE
/// apex); `\widetilde` tessellates a full sine period into 4 arcs of up to 6
/// chords each, so 25 is the ceiling — a fixed array, so a stroke never
/// allocates and the side-table entry is a constant size.
pub const max_poly_points: usize = 25;

/// `Box.poly_idx` for a box that owns no stroke record. Real record indices
/// are always below the box count, so the sentinel can never collide with
/// one and `poly()` needs no separate "is there a stroke" flag.
pub const no_poly: u32 = std.math.maxInt(u32);

/// The stroke of a `.poly` box: ONE connected polyline through `count`
/// vertices (`count - 1` straight segments) of constant `width`. This is how
/// the long `\widehat` / `\widetilde` form is drawn — a single hat with a
/// single apex, or a smooth single-period wave, spanning its argument —
/// rather than a run of repeated marks.
///
/// `extend[i]` is how far the stroke passes THROUGH vertex `i`, in points:
/// the segment before it starts `extend[i]` early and the segment after it
/// ends `extend[i]` late. That is what makes the painted corners match. Each
/// segment is emitted as its own butt-capped `Draw.Line`, and two butt-capped
/// bands meeting at a corner leave a wedge-shaped NOTCH on the outside of
/// the turn — up to a full miter's reach for a sharp corner like the hat's
/// apex. Overlapping the two bands by that reach closes it; the ends
/// (`extend[0]` and `extend[count-1]`) are 0, so the stroke's outer extent
/// is still exactly where the box says it is. Layout sets `extend` to the
/// corner's miter reach, capped at half the shorter adjacent chord.
pub const Poly = struct {
    points: [max_poly_points]PolyPoint = .{PolyPoint{ .dx = 0, .dy = 0 }} ** max_poly_points,
    count: u8 = 0,
    /// stroke width in points
    width: f32 = 0,
    extend: [max_poly_points]f32 = @splat(0),
};

/// Do NOT copy a BoxList by value: it owns the `boxes`, `childrefs`, `chars`,
/// `polys`, and `scratch` arrays and deinits them exactly once. `init`/`deinit`
/// must be paired 1:1; after `deinit` the list is unusable.
pub const BoxList = struct {
    gpa: std.mem.Allocator,
    boxes: std.ArrayList(Box) = .empty,
    childrefs: std.ArrayList(ChildRef) = .empty,
    /// Char-only box state, parallel to `boxes` (indexed by box index):
    /// `.char` boxes carry their real values, every other kind the default.
    chars: std.ArrayList(CharData) = .empty,
    /// SPARSE Polyline geometry, ONE record per `.poly` box in creation
    /// order, addressed by that box's `poly_idx` — never parallel to
    /// `boxes`: an ordinary box stores `no_poly` and pays nothing here.
    /// Read through `poly`, which borrows the record in place.
    polys: std.ArrayList(Poly) = .empty,
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
        self.polys.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn get(self: *const BoxList, idx: u32) Box {
        std.debug.assert(idx < self.boxes.items.len);
        return self.boxes.items[idx];
    }

    pub fn charData(self: *const BoxList, idx: u32) CharData {
        std.debug.assert(idx < self.chars.items.len);
        return self.chars.items[idx];
    }

    /// Mutable char-state slot, for post-create flagging.
    pub fn charDataPtr(self: *BoxList, idx: u32) *CharData {
        std.debug.assert(idx < self.chars.items.len);
        return &self.chars.items[idx];
    }

    /// Mutable slot for the shared paint override (see `Box.color`), for the
    /// scope-owning layout arm to set once, right after `create`.
    pub fn colorPtr(self: *BoxList, idx: u32) *?atom.Color {
        std.debug.assert(idx < self.boxes.items.len);
        return &self.boxes.items[idx].color;
    }

    /// ChildRef run of a box (empty for leaves).
    ///
    /// Invalidation contract: the returned slice aliases `childrefs`
    /// storage. Any `create`/`createLeaf` call may reallocate that array and
    /// dangle the slice — never hold it across a `create` call.
    pub fn children(self: *const BoxList, idx: u32) []const ChildRef {
        std.debug.assert(idx < self.boxes.items.len);
        const b = &self.boxes.items[idx];
        if (b.num_children == 0) return &.{};
        return self.childrefs.items[b.first_child .. b.first_child + b.num_children];
    }

    /// Append a box plus its contiguous run of child placements (copied into
    /// `childrefs`); returns the box index.
    ///
    /// Every table is left exactly as it was when any allocation fails, so a
    /// caught `error.OutOfMemory` leaves `chars` the same length as `boxes`,
    /// `childrefs` without an orphan tail, and `polys` untouched.
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
        // Only `createPoly` appends a stroke record, so it is the only
        // constructor that may make a `.poly` box.
        std.debug.assert(kind != .poly);
        const first: u32 = @intCast(self.childrefs.items.len);
        try self.childrefs.appendSlice(self.gpa, placements);
        errdefer self.childrefs.shrinkRetainingCapacity(first);
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
        errdefer self.boxes.shrinkRetainingCapacity(idx);
        try self.chars.append(self.gpa, if (kind == .char)
            .{ .cp = cp, .style = style, .size = size }
        else
            .{});
        errdefer self.chars.shrinkRetainingCapacity(idx);
        return idx;
    }

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

    /// Append a stroked-polyline leaf: a `.poly` box carrying `stroke` (see
    /// `Poly`) with the box extents the caller derived from that stroke's
    /// own ink — a box bounds the ink that is drawn, like every other box,
    /// so the draw list's bounds cover it.
    ///
    /// This is the only constructor that appends to `polys`: the stroke
    /// lands in the sparse table first and the box's `poly_idx` points at
    /// it. A failed append unwinds that record again, so a poly box never
    /// survives without the geometry it indexes, and no ordinary box ever
    /// acquires one.
    pub fn createPoly(
        self: *BoxList,
        stroke: Poly,
        width: f32,
        height: f32,
        depth: f32,
        span: atom.Span,
    ) !u32 {
        const poly_idx: u32 = @intCast(self.polys.items.len);
        try self.polys.append(self.gpa, stroke);
        errdefer self.polys.shrinkRetainingCapacity(poly_idx);
        const idx: u32 = @intCast(self.boxes.items.len);
        try self.boxes.append(self.gpa, .{
            .kind = .poly,
            .width = width,
            .height = height,
            .depth = depth,
            // A stroke box is a leaf: its `first_child` only records where
            // the run would start, and `num_children == 0` is the test.
            .first_child = @intCast(self.childrefs.items.len),
            .num_children = 0,
            .src_start = span.start,
            .src_end = span.end,
            .poly_idx = poly_idx,
        });
        errdefer self.boxes.shrinkRetainingCapacity(idx);
        try self.chars.append(self.gpa, .{});
        errdefer self.chars.shrinkRetainingCapacity(idx);
        return idx;
    }

    /// The stroke of the `.poly` box at `idx`, BORROWED: the pointer aliases
    /// the record in `polys`, so reading a stroke costs no 308-byte copy.
    ///
    /// Invalidation contract: the returned pointer aliases `polys`
    /// storage. Any `create`/`createPoly` call may reallocate that array and
    /// dangle it — read what you need before the next constructor call,
    /// exactly like `children`.
    pub fn poly(self: *const BoxList, idx: u32) *const Poly {
        std.debug.assert(idx < self.boxes.items.len);
        const b = &self.boxes.items[idx];
        std.debug.assert(b.kind == .poly);
        std.debug.assert(b.poly_idx < self.polys.items.len);
        return &self.polys.items[b.poly_idx];
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

test "boxlist: a color scope rides on its own box and no other" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    // Every box starts with no override: an uncolored formula must leave the
    // host's own foreground alone.
    const glyph = try list.createLeaf(.char, 5.0, 7.0, 0.0, .{ .start = 0, .end = 1 });
    try testing.expect(list.get(glyph).color == null);
    const rule = try list.createLeaf(.rule, 5.0, 0.4, 0.0, .{ .start = 0, .end = 1 });
    try testing.expect(list.get(rule).color == null);

    const red: atom.Color = .{ .r = 0xFF, .g = 0, .b = 0, .a = 0x80 };
    const scope_children = [_]ChildRef{
        .{ .idx = glyph, .x_shift = 0, .shift = 0 },
        .{ .idx = rule, .x_shift = 5.0, .shift = 7.0 },
    };
    const scope = try list.create(.hbox, 10.0, 7.0, 0.0, &scope_children, 0, .roman, 0, .{
        .start = 0,
        .end = 9,
    });
    list.colorPtr(scope).* = red;
    try testing.expectEqual(red, list.get(scope).color.?);
    // The scope paints its SUBTREE, so the override belongs to the wrapper
    // alone — the children below it keep inheriting, which is what lets a
    // nested scope restore the outer color.
    try testing.expect(list.get(glyph).color == null);
    try testing.expect(list.get(rule).color == null);
    // A nested scope wins over its ancestor, and it is a DIFFERENT box: the
    // outer one still carries red.
    const inner_children = [_]ChildRef{.{ .idx = glyph, .x_shift = 0, .shift = 0 }};
    const inner = try list.create(.hbox, 5.0, 7.0, 0.0, &inner_children, 0, .italic, 0, .{
        .start = 0,
        .end = 1,
    });
    const blue: atom.Color = .{ .r = 0, .g = 0, .b = 0xFF, .a = 0xFF };
    list.colorPtr(inner).* = blue;
    try testing.expectEqual(blue, list.get(inner).color.?);
    try testing.expectEqual(red, list.get(scope).color.?);
    // Alpha survives: a half-transparent scope is a real override, not a
    // sentinel for "no color".
    try testing.expectEqual(@as(u8, 0x80), list.get(scope).color.?.a);
}

test "boxlist: a poly box keeps one connected stroke and its own bounds" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    // A two-segment hat: ONE apex, not a run of repeated marks, with the
    // apex's miter reach carried so the two butt-capped bands meet flush.
    var stroke: Poly = .{ .count = 3, .width = 0.8 };
    stroke.points[0] = .{ .dx = 0, .dy = 2 };
    stroke.points[1] = .{ .dx = 20, .dy = -18 };
    stroke.points[2] = .{ .dx = 40, .dy = 2 };
    stroke.extend[1] = 1.3; // the apex; both ENDS stay unextended
    const p = try list.createPoly(stroke, 40, 19, 3, .{ .start = 0, .end = 5 });
    const pb = list.get(p);
    try testing.expectEqual(Kind.poly, pb.kind);
    try testing.expectEqual(@as(u16, 0), pb.num_children);
    try testing.expectEqual(@as(f32, 40), pb.width);
    try testing.expectEqual(@as(f32, 19), pb.height);
    try testing.expectEqual(@as(f32, 3), pb.depth);
    try testing.expectEqual(@as(u32, 0), pb.src_start);
    try testing.expectEqual(@as(u32, 5), pb.src_end);
    try testing.expectEqual(stroke, list.poly(p).*);
    // `count` is the whole contract: 3 vertices are 2 segments, and the
    // unused tail of the fixed run draws nothing further.
    try testing.expectEqual(@as(usize, 2), @as(usize, list.poly(p).count) - 1);
    // Ordinary boxes pay NOTHING for the stroke table: no record is appended
    // for them, and the box says so with the `no_poly` sentinel. The shared
    // color slot on the header is untouched too.
    const c = try list.createLeaf(.char, 5, 7, 0, .{ .start = 0, .end = 1 });
    try testing.expectEqual(@as(usize, 1), list.polys.items.len);
    try testing.expectEqual(no_poly, list.get(c).poly_idx);
    try testing.expect(list.get(c).color == null);
}

test "boxlist: only a poly box owns a stroke record" {
    var list = BoxList.init(testing.allocator);
    defer list.deinit();
    const span: atom.Span = .{ .start = 0, .end = 1 };
    const glyph = try list.createLeaf(.char, 5, 7, 0, span);
    const bar = try list.createLeaf(.rule, 8, 0.4, 0, span);
    const gap = try list.createLeaf(.glue, 2, 0, 0, span);
    const strut = try list.createLeaf(.strut, 0, 8, 3, span);
    const kids = [_]ChildRef{
        .{ .idx = glyph, .x_shift = 0, .shift = 0 },
        .{ .idx = bar, .x_shift = 5, .shift = -7 },
    };
    const row = try list.create(.hbox, 8, 7, 0, &kids, 0, .italic, 0, span);
    const col = try list.create(.vbox, 8, 7, 0, &kids, 0, .italic, 0, span);
    const sup = try list.create(.script, 8, 7, 0, &kids, 0, .italic, 0, span);
    // Seven ordinary boxes, ZERO stroke records: a dense table would have
    // paid a whole record for each of them.
    try testing.expectEqual(@as(usize, 7), list.boxes.items.len);
    try testing.expectEqual(@as(usize, 7), list.chars.items.len);
    try testing.expectEqual(@as(usize, 0), list.polys.items.len);
    for ([_]u32{ glyph, bar, gap, strut, row, col, sup }) |i| {
        try testing.expectEqual(no_poly, list.get(i).poly_idx);
    }
}

test "boxlist: an out-of-memory unwind leaves every table consistent" {
    // `chars` is indexed by box index and `poly_idx` by record, so a partial
    // append is a corrupt list. Fail EVERY allocation in turn: whatever is
    // caught, the tables stay in step.
    var fail_at: usize = 0;
    while (fail_at < 12) : (fail_at += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_at,
            .resize_fail_index = fail_at,
        });
        var list = BoxList.init(failing.allocator());
        defer list.deinit();
        const span: atom.Span = .{ .start = 0, .end = 2 };
        var stroke: Poly = .{ .count = 3, .width = 0.4 };
        stroke.points[1] = .{ .dx = 10, .dy = -6 };
        const glyph = list.createLeaf(.char, 5, 7, 0, span) catch null;
        const poly = list.createPoly(stroke, 20, 6, 0, span) catch null;
        var kids: [2]ChildRef = undefined;
        var n: usize = 0;
        if (glyph) |g| {
            kids[n] = .{ .idx = g, .x_shift = 0, .shift = 0 };
            n += 1;
        }
        if (poly) |p| {
            kids[n] = .{ .idx = p, .x_shift = 5, .shift = -6 };
            n += 1;
        }
        _ = list.create(.hbox, 20, 7, 0, kids[0..n], 0, .italic, 0, span) catch 0;
        _ = list.createLeaf(.rule, 20, 0.4, 0, span) catch 0;
        try testing.expectEqual(list.boxes.items.len, list.chars.items.len);
        var strokes: usize = 0;
        for (list.boxes.items) |b| {
            const end: usize = @as(usize, b.first_child) + @as(usize, b.num_children);
            try testing.expect(end <= list.childrefs.items.len);
            if (b.kind == .poly) {
                strokes += 1;
                try testing.expect(b.poly_idx < list.polys.items.len);
            } else {
                try testing.expectEqual(no_poly, b.poly_idx);
            }
        }
        try testing.expectEqual(strokes, list.polys.items.len);
    }
}
