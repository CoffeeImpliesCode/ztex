//! ztex.layout.draw — the terminal flat, painter-ordered draw list
//! (text/rect/line at absolute coordinates) + box→draw flattening. Every
//! primitive carries the byte span of the box it came from.

const std = @import("std");
const box = @import("box.zig");
pub const atom = @import("ztex.atom");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

/// A drawable primitive.
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
    color: Color,
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
    src_start: u32,
    src_end: u32,
};

pub const Line = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    color: Color,
    width: f32,
    src_start: u32,
    src_end: u32,
};

/// The flat, ordered draw list. Painter's order; absolute coordinates.
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
///     render from the root box; svg.zig draws the viewBox from these).
///     Boxes deliberately under-bind the drawn ink (italic overhang, tall
///     display variants), which is why svg.zig pads them heuristically.
///   - `bounds()` — the INK bounds accumulated by `flatten`: the exact
///     vertical ink extents of every drawn glyph (char boxes carry the
///     drawn glyph's ink as their h/d) and the exact rect areas, with the
///     horizontal glyph extent taken from the advance box (the ink table
///     carries only asc/desc, so the true ink left/right edges are not
///     available).
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
    /// initial union; all zeros for an empty draw list). Internal — read
    /// through `bounds()`.
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

    /// Exact ink bounds of everything `flatten` drew, relative to the root
    /// reference point: `width` = horizontal ink span, `height` = ink
    /// ascent above the baseline, `depth` = ink descent below it. All zero
    /// for an empty draw list. See the struct doc for the box-vs-ink
    /// semantics (this is the INK bound; `width`/`height`/`depth` are the
    /// BOX bounds).
    pub fn bounds(self: *const DrawList) struct { width: f32, height: f32, depth: f32 } {
        if (!self.ink_valid) return .{ .width = 0, .height = 0, .depth = 0 };
        return .{
            .width = self.ink_max_x - self.ink_min_x,
            .height = -self.ink_min_y,
            .depth = self.ink_max_y,
        };
    }

    /// Union a drawn primitive's extent (x0,y0)-(x1,y1) into the running
    /// ink bbox. Called by `flatten` for every emitted primitive.
    fn accInk(self: *DrawList, x0: f32, y0: f32, x1: f32, y1: f32) void {
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

/// Flatten a box tree into a draw list in painter's order.
///
/// `(x, y)` is the box's reference point (baseline). Children are placed at
/// `(x + cr.x_shift, y + cr.shift)`, computed by layout. Every emitted
/// primitive's extent is also unioned into the list's running ink bbox
/// (see `DrawList.bounds()`).
pub fn flatten(
    list: *const box.BoxList,
    root: u32,
    src: []const u8,
    x: f32,
    y: f32,
    out: *DrawList,
) !void {
    const b = list.get(root);
    switch (b.kind) {
        .char => {
            // The drawn glyph is the box's codepoint. Normally its utf-8
            // equals the source span bytes (zero copy); a synthetic box (a
            // big operator like \sum → ∑) has no matching source bytes, so
            // its glyph is duped into the glyph arena. Synthetic is the sole
            // non-alias case — no byte comparison needed.
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
                .color = black,
                .synthetic = ch.synthetic,
                .bigop_form = ch.bigop_form,
                .radical_form = ch.radical_form,
                .delim_fixed = ch.delim_fixed,
                .delim_form = ch.delim_form,
                .delim_req = ch.delim_req,
                .src_start = b.src_start,
                .src_end = b.src_end,
            } });
            // Ink extent: vertical from the box h/d — for a char box these
            // ARE the drawn glyph's ink (layoutChar/layoutText box by
            // glyphInk × drawn size; display big-ops by their .v1 variant
            // ink) — horizontal from the advance box (the ink table carries
            // only asc/desc, so the true ink left/right edges are not
            // available).
            out.accInk(x, y - b.height, x + b.width, y + b.depth);
        },
        .rule => {
            try out.add(.{ .rect = .{
                .x = x,
                .y = y - b.height,
                .w = b.width,
                .h = b.height + b.depth,
                .color = black,
                .src_start = b.src_start,
                .src_end = b.src_end,
            } });
            out.accInk(x, y - b.height, x + b.width, y + b.depth);
        },
        .glue, .strut => {}, // metrics only; nothing to draw
        .hbox, .vbox, .script => {
            for (list.children(root)) |cr| {
                try flatten(list, cr.idx, src, x + cr.x_shift, y + cr.shift, out);
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
    const r = try list.createLeaf(.rule, 2.0, 1.0, 1.0, .{ .start = 0, .end = 1 });
    try flatten(&list, r, "x", 5, 30, &out);
    const b1 = out.bounds();
    // union: x span [5, 14], top at y −3, bottom at y 31
    try testing.expectApproxEqAbs(@as(f32, 9), b1.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3), b1.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 31), b1.depth, 0.001);
}

test "bounds: empty draw list reports zero" {
    var out = DrawList.init(testing.allocator);
    defer out.deinit();
    const b = out.bounds();
    try testing.expectEqual(@as(f32, 0), b.width);
    try testing.expectEqual(@as(f32, 0), b.height);
    try testing.expectEqual(@as(f32, 0), b.depth);
}
