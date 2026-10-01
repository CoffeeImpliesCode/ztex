//! ztex.layout.draw — box tree → painter-ordered draw list of absolute-
//! coordinate primitives (text/rect/line), each carrying its box's byte span.

const std = @import("std");
const box = @import("box.zig");
pub const atom = @import("ztex.atom");

/// The channel struct a paint color is, shared with the parser that reads
/// `\color`/`\textcolor` arguments (`atom.parseColorChecked`).
pub const Color = atom.Color;

pub const Draw = union(enum) {
    /// a glyph run at its baseline (x, y)
    text: Text,
    /// a filled rectangle (fraction bars, rules, radical bars)
    rect: Rect,
    /// a stroked line (decorations)
    line: Line,
};

pub const Text = struct {
    /// utf-8 glyph bytes. Two ownership domains, discriminated by
    /// `synthetic`: false = a slice into the source (never copied); true =
    /// bytes duped into DrawList.glyph_arena (owned by the arena, freed on
    /// draw-list deinit — never free or retain across the list).
    bytes: []const u8,
    /// baseline position in output coordinates
    x: f32,
    y: f32,
    /// font size in points
    size: f32,
    /// effective font style (\text/\mathrm = roman, variables = italic, …)
    style: atom.CharStyle,
    /// the ink color this run paints. `color_override` says whether it came
    /// from an explicit color scope (then it wins) or is the plain black
    /// default (then the host foreground wins).
    color: Color,
    /// true when an explicit color scope covers this run — `color` is that
    /// scope's color, and even an explicit black or a transparent
    /// {0,0,0,0} beats the host foreground. false = no scope: the back end
    /// uses its own foreground color.
    color_override: bool = false,
    /// true when `bytes` is arena-owned (a synthesized glyph with no source
    /// bytes to alias, e.g. \sum → ∑); false when `bytes` aliases the source.
    /// Carried from the box's `synthetic` in `flatten`.
    synthetic: bool = false,
    /// big-op form carried from the box: `.variant` = a DISPLAY big-op
    /// drawing the MATH .v1 variant (svg.zig emits data-op="v1" so the
    /// rasterizer/verifier resolve the variant); everything else stays the
    /// default `.base`.
    bigop_form: box.BigOpForm = .base,
    /// radical MATH-table variant index (0 = base √, 1–4 = radical.v1–v4),
    /// carried from the box so svg.zig can emit data-radical="vN". Set only
    /// for stretchy √ glyphs in layoutSqrt; 0 for every other text.
    radical_form: u8 = 0,
    /// amsmath FIXED-rule delimiter req_em (`\binom`/`\genfrac-with-delims`
    /// — e.g. 2.392 at display, ~1.09 at text), carried from the box so
    /// svg.zig can emit data-fixed-req and the rasterizer resolve the same
    /// variant the layout boxed. 0 = a content-`\left` fence.
    delim_fixed: f32 = 0,
    /// content-sized `\left`/`\right` fence MATH-table variant index
    /// (0 = the BASE glyph was sufficient — plain `\left(x\right)`-style
    /// fences, or non-fence char boxes; 1..7 = the SMALLEST MATH-table
    /// variant whose asc+desc ink covered the inner box's extent, e.g.
    /// parenleft.v6 for a 4-row pmatrix at 20pt). Carried from the box's
    /// `delim_form` in `flatten`. svg.zig emits `data-delim-form="vN"`
    /// so the rasterizer resolves the same variant glyph the layout
    /// boxed — the declared base font-size alone cannot tell a stretched
    /// fence apart from a plain one (a content-sized `\left..\right`
    /// fence with `delim_form > 0` MUST be drawn as a variant glyph at
    /// base size, not the base glyph scaled up — the variant ladder
    /// keeps the stroke constant; scaling thickens it).
    delim_form: u8 = 0,
    /// content-sized `\left`/`\right` fence required ink in em (TeX
    /// make_delim's 2δ·901/1000), carried from the box when the content is
    /// TALLER than the largest MATH-table variant (delim_form == 7 but the
    /// content still exceeds v7's ink). svg.zig emits `data-delim-req` so
    /// the rasterizer assembles the XeTeX GlyphAssembly (top + extenders +
    /// bottom) to exactly this height. 0 = the variant covers the content.
    delim_req: f32 = 0,
    // provenance
    src_start: u32,
    src_end: u32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: Color,
    /// see `Text.color_override`: true = an explicit color scope covers
    /// this rule and `color` wins over the host foreground.
    color_override: bool = false,
    src_start: u32,
    src_end: u32,
};

pub const Line = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    color: Color,
    /// see `Text.color_override`: true = an explicit color scope covers
    /// this line and `color` wins over the host foreground.
    color_override: bool = false,
    width: f32,
    src_start: u32,
    src_end: u32,
};

/// The ordered draw list. Painter's order; absolute coordinates.
///
/// Do NOT copy a DrawList by value: it owns the `items` array and the
/// `glyph_arena` (which owns every synthetic glyph's bytes) and deinits
/// them exactly once. `init`/`deinit` must be paired 1:1; after `deinit`
/// the list is unusable.
///
/// Two bound sources, both relative to the root box's reference point
/// (baseline at y = 0, left edge at x = 0):
///   - `width`/`height`/`depth` — the BOX bounds: the laid-out root box's
///     advance and design extents (set by the caller, e.g. layout/root.zig
///     render from the root box). Boxes can under-bind the drawn ink
///     (italic overhang past the advance, a display variant taller than its
///     box) and can over-bind it (an alignment strut), so a frame drawn from
///     them can either clip the ink or carry empty border; the consumers
///     (svg.zig's viewBox, raster.zig's pixel buffer) frame from `bounds()`.
///   - `bounds()` — the INK bounds accumulated by `flatten`: the exact
///     vertical ink extents of every drawn glyph (char boxes carry the
///     drawn glyph's ink as their h/d) and the exact rect areas, with each
///     glyph's horizontal extent taken from its ADVANCE box UNIONED with the
///     real ink edges the layout measured from the drawn face — so a glyph
///     that leans past its advance is inside the frame, not shaved off it.
///
/// Exact INK bounds of everything `flatten` drew, relative to the root
/// reference point. `min_x`/`min_y` are where that ink actually starts: the
/// reference point is (0, 0) for a draw list whose first drawn primitive
/// sits on it, but NOT in general — a fraction's first ink is its numerator,
/// inset by TeX's 1.2pt nulldelimiterspace, so `min_x` is positive there. A
/// consumer must offset by the origin, never assume it is zero.
pub const InkBounds = struct {
    /// x of the leftmost ink (not necessarily 0)
    min_x: f32,
    /// y of the topmost ink (not necessarily 0; negative = above baseline)
    min_y: f32,
    /// horizontal ink span
    width: f32,
    /// ink ascent above the baseline
    height: f32,
    /// ink descent below the baseline
    depth: f32,
};

pub const DrawList = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Draw) = .empty,
    /// arena for generated glyphs (e.g. big-operator ∑) that have no source
    /// bytes; frees with the draw list
    glyph_arena: std.heap.ArenaAllocator,
    /// total laid-out BOX bounds (for an SVG viewBox); see the struct doc
    width: f32 = 0,
    height: f32 = 0,
    depth: f32 = 0,
    /// running ink bbox accumulated by `flatten` (`ink_valid` guards the
    /// initial union). Internal — read through `bounds()`.
    ink_valid: bool = false,
    ink_min_x: f32 = 0,
    ink_min_y: f32 = 0,
    ink_max_x: f32 = 0,
    ink_max_y: f32 = 0,

    pub fn init(gpa: std.mem.Allocator) DrawList {
        return .{
            .gpa = gpa,
            .glyph_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *DrawList) void {
        self.items.deinit(self.gpa);
        self.glyph_arena.deinit();
        self.* = undefined;
    }

    pub fn add(self: *DrawList, d: Draw) !void {
        try self.items.append(self.gpa, d);
    }

    pub fn len(self: *const DrawList) usize {
        return self.items.items.len;
    }

    /// Exact INK bounds of everything `flatten` drew (see `InkBounds`); all
    /// zero for an empty draw list. The `width`/`height`/`depth` FIELDS are
    /// the BOX bounds — see the struct doc.
    pub fn bounds(self: *const DrawList) InkBounds {
        if (!self.ink_valid) {
            return .{ .min_x = 0, .min_y = 0, .width = 0, .height = 0, .depth = 0 };
        }
        return .{
            .min_x = self.ink_min_x,
            .min_y = self.ink_min_y,
            .width = self.ink_max_x - self.ink_min_x,
            .height = -self.ink_min_y,
            .depth = self.ink_max_y,
        };
    }

    /// Union one drawn primitive's ink extent into the running bbox, in the
    /// same coordinates as `add` (baseline-anchored: ascent is negative y).
    /// `flatten` calls it for every primitive it adds, and every other
    /// producer MUST do the same: a primitive recorded without its ink
    /// leaves `bounds()` under-reporting, and the consumers that frame
    /// from it (svg.zig's viewBox, raster.zig's pixel buffer) frame too
    /// little.
    pub fn accInk(self: *DrawList, x0: f32, y0: f32, x1: f32, y1: f32) void {
        if (!self.ink_valid) {
            self.ink_valid = true;
            self.ink_min_x = x0;
            self.ink_min_y = y0;
            self.ink_max_x = x1;
            self.ink_max_y = y1;
            return;
        }
        self.ink_min_x = @min(self.ink_min_x, x0);
        self.ink_min_y = @min(self.ink_min_y, y0);
        self.ink_max_x = @max(self.ink_max_x, x1);
        self.ink_max_y = @max(self.ink_max_y, y1);
    }
};

const black: Color = .{ .r = 0, .g = 0, .b = 0 };

/// `(x, y)` is the box's reference point (baseline); children land at
/// `(x + cr.x_shift, y + cr.shift)` as computed by layout. Every emitted
/// primitive's extent is also unioned into `out`'s running ink bbox (see
/// `DrawList.bounds()`).
///
/// The whole formula starts outside every color scope: a formula with no
/// `\color`/`\textcolor`/`\boxed` emits plain black primitives with no
/// override, exactly as before, so the back ends keep using the host
/// foreground.
pub fn flatten(
    list: *const box.BoxList,
    root: u32,
    src: []const u8,
    x: f32,
    y: f32,
    out: *DrawList,
) !void {
    try flattenIn(list, root, src, x, y, out, null);
}

/// `inherited` is the color of the nearest enclosing scope, or null outside
/// every scope. A box that declares its own `color` overrides that for its
/// own primitive AND becomes the scope its children inherit, so the NEAREST
/// explicit scope wins and leaving a scope restores the enclosing one — the
/// recursion carries the enclosing value as a parameter instead of mutating
/// anything already flattened.
fn flattenIn(
    list: *const box.BoxList,
    root: u32,
    src: []const u8,
    x: f32,
    y: f32,
    out: *DrawList,
    inherited: ?Color,
) !void {
    const b = list.get(root);
    const scope: ?Color = if (b.color) |c| c else inherited;
    switch (b.kind) {
        .char => {
            // Normally the drawn utf-8 equals the source span bytes (zero
            // copy); a synthetic box (a big operator like \sum → ∑) has no
            // matching source bytes, so its glyph is duped into the glyph
            // arena. Synthetic is the sole non-alias case — no byte
            // comparison needed.
            const ch = list.charData(root);
            const bytes = if (ch.synthetic) blk: {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(ch.cp, &buf) catch 0;
                break :blk try out.glyph_arena.allocator().dupe(u8, buf[0..n]);
            } else src[b.src_start..b.src_end];
            try out.add(.{ .text = .{
                .bytes = bytes,
                .x = x,
                .y = y,
                .size = ch.size,
                .style = ch.style,
                .color = scope orelse black,
                .color_override = scope != null,
                .synthetic = ch.synthetic,
                .bigop_form = ch.bigop_form,
                .radical_form = ch.radical_form,
                .delim_fixed = ch.delim_fixed,
                .delim_form = ch.delim_form,
                .delim_req = ch.delim_req,
                .src_start = b.src_start,
                .src_end = b.src_end,
            } });
            // Ink extent. Vertically the box h/d ARE the drawn glyph's ink
            // (layoutChar/layoutText box by glyphInk × drawn size; display
            // big-ops by their .v1 variant ink). Horizontally it is the
            // ADVANCE box UNIONED with the drawn glyph's real ink edges —
            // `left`/`right` are how far that ink reaches past the advance
            // box, so a negative left side bearing (math italic `j`, every
            // combining mark) and a right overhang (the italic and bold `f`
            // hook) land INSIDE the frame instead of being shaved off it.
            // Both are 0 for a glyph whose ink fits its advance box, which
            // is why a hand-built DrawList keeps its exact old extent.
            //
            // A box that draws a MATH-table VARIANT — a stretched delimiter
            // (`delim_form`), an amsmath fixed fence (`delim_fixed`), a
            // radical variant or a display big-op's `.v1` form — paints
            // another glyph than its `cp` names, so the base codepoint's
            // horizontal bounds are meaningless there and are dropped: the
            // variant's own advance box frames it.
            const base_glyph = ch.delim_form == 0 and ch.delim_fixed == 0 and
                ch.radical_form == 0 and ch.bigop_form == .base;
            const left = if (base_glyph) ch.ink_left else 0;
            const right = if (base_glyph) ch.ink_right else 0;
            out.accInk(x - left, y - b.height, x + b.width + right, y + b.depth);
        },
        .rule => {
            try out.add(.{ .rect = .{
                .x = x,
                .y = y - b.height,
                .w = b.width,
                .h = b.height + b.depth,
                .color = scope orelse black,
                .color_override = scope != null,
                .src_start = b.src_start,
                .src_end = b.src_end,
            } });
            out.accInk(x, y - b.height, x + b.width, y + b.depth);
        },
        .poly => {
            // ONE connected stroke: `count` vertices make `count - 1`
            // straight segments, emitted in stroke order so the painter's
            // order matches the geometry. No new drawable variant and no
            // per-segment color: the whole stroke inherits the enclosing
            // scope and one span, exactly like the other primitives.
            const stroke = list.poly(root);
            // Borrowed in place: the stroke is a view of the box's own
            // record, not a copy of its fixed 25-vertex run.
            var segments: usize = 0;
            var k: u8 = 0;
            while (k + 1 < stroke.count) : (k += 1) {
                const from = stroke.points[k];
                const to = stroke.points[k + 1];
                const sx = to.dx - from.dx;
                const sy = to.dy - from.dy;
                const len = @sqrt(sx * sx + sy * sy);
                // A zero-length segment has no extent — both back ends paint
                // nothing for it (svg's butt cap, raster's band), so it does
                // not belong in the list.
                if (len <= 0) continue;
                // Each segment is prolonged THROUGH its interior vertices by
                // that vertex's miter reach (`extend`): two butt-capped bands
                // meeting at a corner leave a notch on the outside of the
                // turn — a full miter's reach at the hat's apex. The two
                // ENDS carry no extension, so the stroke's outer extent
                // stays exactly on the box's edges.
                const dx = sx / len;
                const dy = sy / len;
                const back: f32 = if (k > 0) stroke.extend[k] else 0;
                const fwd: f32 = if (k + 1 < stroke.count) stroke.extend[k + 1] else 0;
                try out.add(.{ .line = .{
                    .x0 = x + from.dx - back * dx,
                    .y0 = y + from.dy - back * dy,
                    .x1 = x + to.dx + fwd * dx,
                    .y1 = y + to.dy + fwd * dy,
                    .color = scope orelse black,
                    .color_override = scope != null,
                    .width = stroke.width,
                    .src_start = b.src_start,
                    .src_end = b.src_end,
                } });
                segments += 1;
            }
            // The box's h/d bound the PAINTED band (layout derives them from
            // the butt-cap union of these segments, reach included), so the
            // ink bbox — and with it the SVG viewBox and the zero-pad raster
            // frame — covers the whole stroke with no padding fudge.
            //
            // ONLY once a segment was emitted: a stroke whose vertices all
            // coincide paints nothing at all, and accumulating the box for it
            // would frame an empty draw list as if ink were there.
            if (segments > 0) out.accInk(x, y - b.height, x + b.width, y + b.depth);
        },
        .glue, .strut => {}, // metrics only; nothing to draw
        .hbox, .vbox, .script => {
            for (list.children(root)) |cr| {
                try flattenIn(list, cr.idx, src, x + cr.x_shift, y + cr.shift, out, scope);
            }
        },
    }
}

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "flatten: char emits text with provenance" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const src = "x+1";
    const c = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    // tag the char box's cp/size so flatten can build a text primitive
    list.charDataPtr(c).size = 10.0;
    list.charDataPtr(c).cp = 'x';
    try flatten(&list, c, src, 0, 10, &out);
    try testing.expectEqual(@as(usize, 1), out.len());
    const t = out.items.items[0].text;
    try testing.expectEqualStrings("x", t.bytes);
    try testing.expectEqual(@as(f32, 0), t.x);
    try testing.expectEqual(@as(f32, 10), t.y);
    try testing.expectEqual(@as(f32, 10), t.size);
    try testing.expectEqual(@as(u32, 0), t.src_start);
    try testing.expectEqual(@as(u32, 1), t.src_end);
}

test "flatten: rule emits rect; glue emits nothing" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const r = try list.createLeaf(.rule, 10.0, 0.2, 0.2, .{ .start = 3, .end = 4 });
    try flatten(&list, r, "x+1", 5, 20, &out);
    try testing.expectEqual(@as(usize, 1), out.len());
    const rect = out.items.items[0].rect;
    try testing.expectEqual(@as(f32, 5), rect.x);
    try testing.expectEqual(@as(f32, 20 - 0.2), rect.y);
    try testing.expectEqual(@as(f32, 10), rect.w);
    try testing.expectEqual(@as(f32, 0.4), rect.h);
    try testing.expectEqual(@as(u32, 3), rect.src_start);
    try testing.expectEqual(@as(u32, 4), rect.src_end);
}

test "flatten: hbox walks children in order" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const src = "ab";
    const a = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const b = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    list.charDataPtr(a).size = 10.0;
    list.charDataPtr(b).size = 10.0;
    list.charDataPtr(a).cp = 'a';
    list.charDataPtr(b).cp = 'b';
    const children = [_]box.ChildRef{
        .{ .idx = a, .x_shift = 0, .shift = 0 },
        .{ .idx = b, .x_shift = 4.0, .shift = 0 },
    };
    const h = try list.create(.hbox, 8.0, 3.0, 0.5, &children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    try flatten(&list, h, src, 0, 10, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    try testing.expectEqualStrings("a", out.items.items[0].text.bytes);
    try testing.expectEqualStrings("b", out.items.items[1].text.bytes);
    try testing.expectEqual(@as(f32, 4.0), out.items.items[1].text.x);
}

test "flatten: vbox recurses into children" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const src = "ab";
    const a = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const b = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    list.charDataPtr(a).size = 10.0;
    list.charDataPtr(b).size = 10.0;
    list.charDataPtr(a).cp = 'a';
    list.charDataPtr(b).cp = 'b';
    const children = [_]box.ChildRef{
        .{ .idx = a, .x_shift = 1.0, .shift = -2.0 },
        .{ .idx = b, .x_shift = 5.0, .shift = 3.0 },
    };
    const v = try list.create(.vbox, 9.0, 6.0, 4.0, &children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    try flatten(&list, v, src, 10, 20, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    const t0 = out.items.items[0].text;
    try testing.expectEqualStrings("a", t0.bytes);
    try testing.expectEqual(@as(f32, 11), t0.x); // 10 + x_shift 1
    try testing.expectEqual(@as(f32, 18), t0.y); // 20 + shift -2
    const t1 = out.items.items[1].text;
    try testing.expectEqualStrings("b", t1.bytes);
    try testing.expectEqual(@as(f32, 15), t1.x); // 10 + x_shift 5
    try testing.expectEqual(@as(f32, 23), t1.y); // 20 + shift 3
}

test "flatten: script box recurses into base and superscript" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const src = "x2";
    const base = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    const sup = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 1, .end = 2 });
    list.charDataPtr(base).size = 10.0;
    list.charDataPtr(sup).size = 10.0;
    list.charDataPtr(base).cp = 'x';
    list.charDataPtr(sup).cp = '2';
    const children = [_]box.ChildRef{
        .{ .idx = base, .x_shift = 0, .shift = 0 },
        .{ .idx = sup, .x_shift = 4.0, .shift = -3.0 },
    };
    const s = try list.create(.script, 8.0, 6.0, 0.5, &children, 0, .italic, 0, .{ .start = 0, .end = 2 });
    try flatten(&list, s, src, 0, 10, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    try testing.expectEqualStrings("x", out.items.items[0].text.bytes);
    try testing.expectEqualStrings("2", out.items.items[1].text.bytes);
    try testing.expectEqual(@as(f32, 4.0), out.items.items[1].text.x);
    try testing.expectEqual(@as(f32, 7.0), out.items.items[1].text.y); // 10 + shift -3
}

test "flatten: strut emits nothing" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const st = try list.createLeaf(.strut, 2.0, 3.0, 1.0, .{ .start = 0, .end = 1 });
    try flatten(&list, st, "x", 0, 0, &out);
    try testing.expectEqual(@as(usize, 0), out.len());
}

test "bounds: flatten accumulates the drawn ink extents" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const c = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    list.charDataPtr(c).cp = 'x';
    // baseline at y = 0 (the root reference point); ink y ∈ [−3, +0.5]
    try flatten(&list, c, "x", 10, 0, &out);
    const b0 = out.bounds();
    try testing.expectApproxEqAbs(@as(f32, 4), b0.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3), b0.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), b0.depth, 0.001);
    // the origin is the ink's own corner, not the reference point: the
    // glyph was drawn at x = 10
    try testing.expectApproxEqAbs(@as(f32, 10), b0.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -3), b0.min_y, 0.001);
    const r = try list.createLeaf(.rule, 2.0, 1.0, 1.0, .{ .start = 0, .end = 1 });
    try flatten(&list, r, "x", 5, 30, &out);
    const b1 = out.bounds();
    // union: x span [5, 14], top at y −3, bottom at y 31
    try testing.expectApproxEqAbs(@as(f32, 9), b1.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3), b1.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 31), b1.depth, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), b1.min_x, 0.001);
}

test "bounds: empty draw list reports zero" {
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const b = out.bounds();
    try testing.expectEqual(@as(f32, 0), b.min_x);
    try testing.expectEqual(@as(f32, 0), b.min_y);
    try testing.expectEqual(@as(f32, 0), b.width);
    try testing.expectEqual(@as(f32, 0), b.height);
    try testing.expectEqual(@as(f32, 0), b.depth);
}

test "bounds: a glyph's real ink widens the frame past its advance box" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const c = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    list.charDataPtr(c).cp = 'f';
    // The drawn glyph's ink reaches past BOTH ends of its advance box: 0.5pt
    // left of the origin and 1.25pt past origin+advance.
    list.charDataPtr(c).ink_left = 0.5;
    list.charDataPtr(c).ink_right = 1.25;
    try flatten(&list, c, "f", 10, 0, &out);
    const b = out.bounds();
    try testing.expectApproxEqAbs(@as(f32, 9.5), b.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5.75), b.width, 0.001);
    // Vertical extents are the box's own ink and are untouched by the edges.
    try testing.expectApproxEqAbs(@as(f32, 3), b.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), b.depth, 0.001);
    // The LAYOUT ADVANCE is the box's business: framing a wider glyph must
    // not widen the box the next glyph is placed against.
    try testing.expectApproxEqAbs(@as(f32, 4), list.get(c).width, 0.001);
}

test "bounds: a glyph whose ink fits its advance box keeps the advance box" {
    // The zero-edge case is the boundary the union has to respect: with no
    // overhang on either side the frame is the advance box exactly, which is
    // what every hand-built DrawList in this file still gets.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const c = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
    list.charDataPtr(c).cp = 'x';
    try flatten(&list, c, "x", 10, 0, &out);
    const b = out.bounds();
    try testing.expectApproxEqAbs(@as(f32, 10), b.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4), b.width, 0.001);
}

test "bounds: a variant glyph is framed by its own advance box" {
    // A stretched delimiter, an amsmath fixed fence, a radical variant and a
    // display big-op's .v1 form each paint a DIFFERENT glyph than their `cp`
    // names. The base codepoint's horizontal edges describe another outline
    // entirely, so they must not reach the frame even when they are set.
    const Form = enum { delim, fixed_fence, radical, bigop };
    const forms = [_]Form{ .delim, .fixed_fence, .radical, .bigop };
    for (forms) |form| {
        var list = box.BoxList.init(testing.allocator);
        defer list.deinit();
        var out = DrawList.init(testing.allocator);
        defer out.deinit();
        const c = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = 0, .end = 1 });
        list.charDataPtr(c).cp = 'f';
        const ch = list.charDataPtr(c);
        ch.ink_left = 0.5;
        ch.ink_right = 1.25;
        switch (form) {
            .delim => ch.delim_form = 6,
            .fixed_fence => ch.delim_fixed = 2.392,
            .radical => ch.radical_form = 2,
            .bigop => ch.bigop_form = .variant,
        }
        try flatten(&list, c, "f", 10, 0, &out);
        const b = out.bounds();
        try testing.expectApproxEqAbs(@as(f32, 10), b.min_x, 0.001);
        try testing.expectApproxEqAbs(@as(f32, 4), b.width, 0.001);
    }
}

// ── color scopes ─────────────────────────

/// A `.char` box 4pt wide with `cp` drawn at 10pt, spanning one source byte
/// at `start`. The char-state side table is what `flatten` reads the glyph
/// from, so a draw-list test has to fill it in.
fn charBox(list: *box.BoxList, cp: u21, start: u32) !u32 {
    const idx = try list.createLeaf(.char, 4.0, 3.0, 0.5, .{ .start = start, .end = start + 1 });
    list.charDataPtr(idx).cp = cp;
    list.charDataPtr(idx).size = 10.0;
    return idx;
}

/// The paint override a color scope put on a box, set the way layout sets
/// it: on the atom's own wrapper box, which then paints itself and scopes
/// its subtree.
fn setColor(list: *box.BoxList, idx: u32, c: ?Color) void {
    list.colorPtr(idx).* = c;
}

/// A container hbox `w` pt wide holding `children` over `span`: the
/// transparent wrapper a color scope paints itself through.
fn scopeBox(list: *box.BoxList, children: []const box.ChildRef, w: f32, span: atom.Span) !u32 {
    return list.create(.hbox, w, 3.0, 0.5, children, 0, .italic, 0, span);
}

/// The channel triplet of a primitive's color, for comparing against a
/// literal expectation.
fn rgb(c: Color) [3]u8 {
    return .{ c.r, c.g, c.b };
}

// The scope a primitive paints with is decided while flattening, so the
// nesting has to survive three levels: an outer scope, a nested one that
// takes precedence inside it, and content after the nested scope closes.
// A mutable "current color" would leak blue onto `d` — the enclosing red
// must come back.
test "flatten: the nearest color scope wins and leaving it restores the outer one" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const a = try charBox(&list, 'a', 0);
    const b = try charBox(&list, 'b', 1);
    const c = try charBox(&list, 'c', 2);
    const d = try charBox(&list, 'd', 3);
    // innermost: { c } in blue
    const inner_children = [_]box.ChildRef{.{ .idx = c, .x_shift = 0, .shift = 0 }};
    const inner = try scopeBox(&list, &inner_children, 4.0, .{ .start = 2, .end = 3 });
    setColor(&list, inner, .{ .r = 0, .g = 0, .b = 255 });
    // outer: { b {c} d } in red
    const outer_children = [_]box.ChildRef{
        .{ .idx = b, .x_shift = 0, .shift = 0 },
        .{ .idx = inner, .x_shift = 4.0, .shift = 0 },
        .{ .idx = d, .x_shift = 8.0, .shift = 0 },
    };
    const outer = try scopeBox(&list, &outer_children, 12.0, .{ .start = 1, .end = 4 });
    setColor(&list, outer, .{ .r = 255, .g = 0, .b = 0 });
    const root_children = [_]box.ChildRef{
        .{ .idx = a, .x_shift = 0, .shift = 0 },
        .{ .idx = outer, .x_shift = 4.0, .shift = 0 },
    };
    const root = try scopeBox(&list, &root_children, 16.0, .{ .start = 0, .end = 4 });
    try flatten(&list, root, "abcd", 0, 10, &out);

    try testing.expectEqual(@as(usize, 4), out.len());
    const want_rgb = [_][3]u8{
        .{ 0, 0, 0 }, // a: outside every scope
        .{ 255, 0, 0 }, // b: outer scope
        .{ 0, 0, 255 }, // c: the nested scope wins over the outer one
        .{ 255, 0, 0 }, // d: back to the outer scope, not blue
    };
    const want_override = [_]bool{ false, true, true, true };
    for (out.items.items, want_rgb, want_override) |item, want, over| {
        const t = item.text;
        try testing.expectEqualSlices(u8, &want, &rgb(t.color));
        try testing.expectEqual(over, t.color_override);
    }
    // Provenance is untouched by the scope: each run still spans its own
    // source byte.
    for (out.items.items, 0..) |item, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), item.text.src_start);
        try testing.expectEqual(@as(u32, @intCast(i + 1)), item.text.src_end);
    }
}

// A scope on a CONTAINER paints nothing by itself — the wrapper is a
// transparent box — so the primitives inside carry the color, and a
// container with no scope leaves its subtree black and un-overridden. The
// back end picks its own foreground from `color_override`, so the flag has
// to be false here or every uncolored formula would go black over a host
// foreground that used to win.
test "flatten: an uncolored primitive is opaque black with no override" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const c = try charBox(&list, 'x', 0);
    const r = try list.createLeaf(.rule, 10.0, 0.2, 0.2, .{ .start = 1, .end = 2 });
    const children = [_]box.ChildRef{
        .{ .idx = c, .x_shift = 0, .shift = 0 },
        .{ .idx = r, .x_shift = 4.0, .shift = -1.0 },
    };
    const h = try scopeBox(&list, &children, 14.0, .{ .start = 0, .end = 2 });
    try flatten(&list, h, "x+", 0, 0, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    const t = out.items.items[0].text;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &rgb(t.color));
    try testing.expectEqual(@as(u8, 255), t.color.a);
    try testing.expect(!t.color_override);
    const rect = out.items.items[1].rect;
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &rgb(rect.color));
    try testing.expectEqual(@as(u8, 255), rect.color.a);
    try testing.expect(!rect.color_override);
}

// A transparent foreground is {0,0,0,0} — a paint decision meaning "draw
// nothing", not "no color given". Losing the alpha here (or letting the
// host foreground substitute for it) would paint the content black.
test "flatten: a transparent scope reaches its primitives with the alpha intact" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const c = try charBox(&list, 'x', 0);
    const r = try list.createLeaf(.rule, 10.0, 0.2, 0.2, .{ .start = 1, .end = 2 });
    const children = [_]box.ChildRef{
        .{ .idx = c, .x_shift = 0, .shift = 0 },
        .{ .idx = r, .x_shift = 4.0, .shift = 0 },
    };
    const h = try scopeBox(&list, &children, 14.0, .{ .start = 0, .end = 2 });
    setColor(&list, h, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    try flatten(&list, h, "x+", 0, 0, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    const t = out.items.items[0].text;
    try testing.expectEqual(@as(u8, 0), t.color.a);
    try testing.expect(t.color_override);
    const rect = out.items.items[1].rect;
    try testing.expectEqual(@as(u8, 0), rect.color.a);
    try testing.expect(rect.color_override);
}

// A half-transparent scope keeps its own channels AND its alpha: the alpha
// is part of the color, not a separate flag the back end may drop.
test "flatten: a scoped rule keeps its channels, alpha and own span" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const r = try list.createLeaf(.rule, 10.0, 0.2, 0.2, .{ .start = 3, .end = 4 });
    const children = [_]box.ChildRef{.{ .idx = r, .x_shift = 2.0, .shift = -3.0 }};
    const h = try scopeBox(&list, &children, 12.0, .{ .start = 3, .end = 4 });
    setColor(&list, h, .{ .r = 18, .g = 52, .b = 86, .a = 128 });
    try flatten(&list, h, "x+", 0, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.len());
    const rect = out.items.items[0].rect;
    try testing.expectEqualSlices(u8, &.{ 18, 52, 86 }, &rgb(rect.color));
    try testing.expectEqual(@as(u8, 128), rect.color.a);
    try testing.expect(rect.color_override);
    // The rule keeps its own span and geometry, and still reports its ink,
    // so a colored frame is framed and attributed like any other rule.
    try testing.expectEqual(@as(u32, 3), rect.src_start);
    try testing.expectEqual(@as(u32, 4), rect.src_end);
    try testing.expectEqual(@as(f32, 2), rect.x);
    try testing.expectEqual(@as(f32, -3.2), rect.y);
    try testing.expectEqual(@as(f32, 10), rect.w);
    try testing.expectEqual(@as(f32, 0.4), rect.h);
    const ink = out.bounds();
    try testing.expectApproxEqAbs(@as(f32, 2), ink.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.2), ink.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), ink.width, 0.001);
}

// A color scope on a primitive box paints that primitive directly: layout
// may flag a char or rule box itself (\boxed's four rules), so the nearest
// scope is not only ever an ancestor.
test "flatten: a color on a primitive box paints it and overrides the inherited scope" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const r = try list.createLeaf(.rule, 10.0, 0.2, 0.2, .{ .start = 1, .end = 2 });
    setColor(&list, r, .{ .r = 0, .g = 255, .b = 0 });
    const children = [_]box.ChildRef{.{ .idx = r, .x_shift = 0, .shift = 0 }};
    const h = try scopeBox(&list, &children, 10.0, .{ .start = 1, .end = 2 });
    setColor(&list, h, .{ .r = 255, .g = 0, .b = 0 });
    try flatten(&list, h, "x+", 0, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.len());
    const rect = out.items.items[0].rect;
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0 }, &rgb(rect.color));
    try testing.expect(rect.color_override);
}

// A nested scope on a script box colors the base and the scripts alike: the
// script box is one container, so nothing below it may silently opt out of
// the color.
test "flatten: a scope over a script box colors base and scripts alike" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const base = try charBox(&list, 'x', 0);
    const sup = try charBox(&list, '2', 1);
    const children = [_]box.ChildRef{
        .{ .idx = base, .x_shift = 0, .shift = 0 },
        .{ .idx = sup, .x_shift = 4.0, .shift = -3.0 },
    };
    const s = try list.create(
        .script,
        8.0,
        6.0,
        0.5,
        &children,
        0,
        .italic,
        0,
        .{ .start = 0, .end = 2 },
    );
    setColor(&list, s, .{ .r = 0, .g = 128, .b = 0 });
    try flatten(&list, s, "x2", 0, 10, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    for (out.items.items) |item| {
        try testing.expectEqualSlices(u8, &.{ 0, 128, 0 }, &rgb(item.text.color));
        try testing.expect(item.text.color_override);
    }
}

// ── wide accents ─────────────────────────

// A stroke through `vertices`, with `reach[i]` at each vertex — the miter
// extension layout sets. Vertices past the run keep the degenerate default
// and are never drawn: `count` is the run length.
fn polyStroke(vertices: []const box.PolyPoint, reach: []const f32, width: f32) box.Poly {
    var stroke: box.Poly = .{ .count = @intCast(vertices.len), .width = width };
    for (vertices, 0..) |v, i| {
        stroke.points[i] = v;
        if (i < reach.len) stroke.extend[i] = reach[i];
    }
    return stroke;
}

// The long \widehat / \widetilde form is ONE connected stroke: `count`
// vertices make `count - 1` segments. A run of repeated mark boxes would
// draw a sawtooth instead, so the count of emitted segments IS the
// geometry — and each one must carry the stroke's width, the box's span and
// the enclosing color scope. With no miter reach set, segment k runs
// vertex to vertex.
test "flatten: a poly box emits its segments as one connected stroke" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    // A two-segment hat: left foot, ONE apex, right foot.
    const stroke = polyStroke(
        &.{
            .{ .dx = 0, .dy = 4 },
            .{ .dx = 10, .dy = -6 },
            .{ .dx = 20, .dy = 4 },
        },
        &.{ 0, 0, 0 },
        0.4,
    );
    const p = try list.createPoly(stroke, 20.0, 6.0, 0.0, .{ .start = 0, .end = 8 });
    const children = [_]box.ChildRef{.{ .idx = p, .x_shift = 0, .shift = 0 }};
    const h = try scopeBox(&list, &children, 20.0, .{ .start = 0, .end = 8 });
    setColor(&list, h, .{ .r = 0, .g = 0, .b = 255 });
    try flatten(&list, h, "\\widehat", 0, 0, &out);

    try testing.expectEqual(@as(usize, 2), out.len());
    const first = out.items.items[0].line;
    try testing.expectEqual(@as(f32, 0), first.x0);
    try testing.expectEqual(@as(f32, 4), first.y0);
    try testing.expectEqual(@as(f32, 10), first.x1);
    try testing.expectEqual(@as(f32, -6), first.y1);
    const second = out.items.items[1].line;
    // The second segment STARTS where the first ended: one stroke, not two
    // strokes that meet by luck.
    try testing.expectEqual(@as(f32, 10), second.x0);
    try testing.expectEqual(@as(f32, -6), second.y0);
    try testing.expectEqual(@as(f32, 20), second.x1);
    try testing.expectEqual(@as(f32, 4), second.y1);
    for ([_]Line{ first, second }) |seg| {
        try testing.expectEqual(@as(f32, 0.4), seg.width);
        try testing.expectEqual(@as(u32, 0), seg.src_start);
        try testing.expectEqual(@as(u32, 8), seg.src_end);
        try testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, &rgb(seg.color));
        try testing.expect(seg.color_override);
    }
    // The box's h/d bound the stroke's own ink, so the ink bbox covers both
    // segments without a padding fudge.
    const ink = out.bounds();
    try testing.expectApproxEqAbs(@as(f32, 0), ink.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 6), ink.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), ink.width, 0.001);
}

// A vertex's miter reach makes the two bands OVERLAP there, so the corner
// closes instead of notching. Each segment is prolonged by its interior
// vertices' reach along its own direction: the first runs 1.3pt past the
// apex, the second starts 1.3pt before it — 1.3/√2 on each axis of a 45°
// pair. The ENDS move by nothing, so the stroke's outer extent is still the
// box's own left and right edges.
test "flatten: a miter reach closes the corner without moving the ends" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const stroke = polyStroke(
        &.{
            .{ .dx = 0, .dy = 4 },
            .{ .dx = 10, .dy = -6 },
            .{ .dx = 20, .dy = 4 },
        },
        &.{ 0, 1.3, 0 },
        0.4,
    );
    const p = try list.createPoly(stroke, 20.0, 6.0, 0.0, .{ .start = 0, .end = 8 });
    try flatten(&list, p, "\\widehat", 0, 0, &out);
    try testing.expectEqual(@as(usize, 2), out.len());
    const first = out.items.items[0].line;
    const second = out.items.items[1].line;
    // The overlap: segment 1 ends PAST the apex, segment 2 starts BEFORE it.
    // Without the reach both land exactly on it and the corner notches.
    try testing.expectApproxEqAbs(@as(f32, 10.919), first.x1, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -6.919), first.y1, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 9.081), second.x0, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -6.919), second.y0, 0.001);
    try testing.expect(first.x1 > 10.0);
    try testing.expect(second.x0 < 10.0);
    // The ends are untouched: the stroke still starts at the left edge and
    // stops at the right one, so the box bounds still frame it exactly.
    try testing.expectEqual(@as(f32, 0), first.x0);
    try testing.expectEqual(@as(f32, 4), first.y0);
    try testing.expectEqual(@as(f32, 20), second.x1);
    try testing.expectEqual(@as(f32, 4), second.y1);
}

// `count` is the whole contract: two vertices are ONE segment, and the
// unused tail of the fixed-size run draws nothing further.
test "flatten: a two-vertex poly emits exactly one segment" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const stroke = polyStroke(
        &.{ .{ .dx = 0, .dy = 0 }, .{ .dx = 8, .dy = 4 } },
        &.{ 0, 0 },
        0.4,
    );
    const p = try list.createPoly(stroke, 8.0, 0.0, 0.0, .{ .start = 0, .end = 8 });
    try flatten(&list, p, "\\widetilde", 0, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.len());
    const seg = out.items.items[0].line;
    try testing.expectEqual(@as(f32, 8), seg.x1);
    try testing.expectEqual(@as(f32, 4), seg.y1);
    // Uncolored stroke: black with no override, like every other primitive.
    try testing.expect(!seg.color_override);
}

// A degenerate stroke (every vertex on the same point) is a stroke of no
// extent. It must not emit a zero-length segment that both back ends would
// have to treat specially — and the reach must not turn it into one either.
// The BOX still carries real extents (layout bounds the accent it replaced),
// and those must not leak into the frame: nothing painted means an empty ink
// bbox, so the SVG viewBox and the zero-pad raster frame reserve no room for
// a stroke that is not there.
test "flatten: a degenerate poly draws nothing and frames nothing" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const stroke = polyStroke(
        &.{ .{ .dx = 4, .dy = 4 }, .{ .dx = 4, .dy = 4 }, .{ .dx = 4, .dy = 4 } },
        &.{ 1.3, 1.3, 1.3 },
        0.4,
    );
    const p = try list.createPoly(stroke, 8.0, 6.0, 1.0, .{ .start = 0, .end = 8 });
    try flatten(&list, p, "\\widehat", 0, 0, &out);
    try testing.expectEqual(@as(usize, 0), out.len());
    try testing.expect(!out.ink_valid);
    const ink = out.bounds();
    try testing.expectEqual(@as(f32, 0), ink.min_x);
    try testing.expectEqual(@as(f32, 0), ink.min_y);
    try testing.expectEqual(@as(f32, 0), ink.width);
    try testing.expectEqual(@as(f32, 0), ink.height);
    try testing.expectEqual(@as(f32, 0), ink.depth);
}

// The same rule on a stroke that is only PARTLY degenerate: skipping the
// coincident pair must not take the ink with it. One emitted segment still
// bounds the whole box, so an accumulator gated on the wrong condition would
// under-frame every stroked accent.
test "flatten: a partly degenerate poly still frames its real segment" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    // Vertices 0 and 1 coincide, so that segment has no extent; 1 → 2 is real.
    const stroke = polyStroke(
        &.{ .{ .dx = 0, .dy = 4 }, .{ .dx = 0, .dy = 4 }, .{ .dx = 8, .dy = -4 } },
        &.{ 0, 0, 0 },
        0.4,
    );
    const p = try list.createPoly(stroke, 8.0, 8.0, 0.0, .{ .start = 0, .end = 8 });
    try flatten(&list, p, "\\widehat", 0, 0, &out);
    try testing.expectEqual(@as(usize, 1), out.len());
    try testing.expectEqual(@as(f32, 8), out.items.items[0].line.x1);
    try testing.expectEqual(@as(f32, -4), out.items.items[0].line.y1);
    const ink = out.bounds();
    try testing.expectApproxEqAbs(@as(f32, 0), ink.min_x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8), ink.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8), ink.height, 0.001);
}
