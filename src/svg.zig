//! ztex.svg — serialize a draw list into SVG.
//!
//! The draw model uses baseline-anchored coordinates (y = baseline; ascent is
//! negative). SVG is top-down, so this module offsets every primitive from
//! the frame origin — the draw list's INK minimum (see `render`) — so all
//! content sits at non-negative x and y inside the viewBox. Text is emitted
//! with its baseline at `y` (SVG default dominant-baseline is alphabetic).

const std = @import("std");
const layout = @import("ztex.layout");
const draw = layout.draw;
const atom = draw.atom;

pub const Options = struct {
    /// empty margin around the content, on every side (pt)
    padding: f32 = 0,
    /// optional background fill
    background: ?draw.Color = null,
    /// font family for math runs (italic variables, operators, big ops)
    font_family: []const u8 = "Latin Modern Math, Latin Modern Roman, DejaVu Serif, serif",
    /// font family for upright runs (\text, \mathrm, \mathbf, …)
    text_font_family: []const u8 = "Latin Modern Roman, DejaVu Serif, serif",
};

/// SVG font attributes for one CharStyle. Math (italic) runs use the math
/// family, whose glyphs are italic by design; roman/bold runs switch to the
/// upright text family so \text/\mathrm render upright instead of in the
/// math font's italic shapes. font-style is emitted anyway so fallback
/// faces (LM Roman Italic, DejaVu Serif Italic) stay italic when LMMath is
/// missing.
const FontSpec = struct {
    family: []const u8,
    style: []const u8,
    /// css font-weight; empty string = normal
    weight: []const u8,
};

fn fontSpec(style: atom.CharStyle, opts: *const Options) FontSpec {
    return switch (style) {
        .italic => .{ .family = opts.font_family, .style = "italic", .weight = "" },
        .roman => .{ .family = opts.text_font_family, .style = "normal", .weight = "" },
        .bold => .{ .family = opts.text_font_family, .style = "normal", .weight = "bold" },
        // letter variants: LMMath carries blackboard/script/fraktur glyphs;
        // sans/mono map to their dedicated families.
        .bb, .cal, .frak => .{ .family = opts.font_family, .style = "normal", .weight = "" },
        .sans => .{ .family = "DejaVu Sans, sans-serif", .style = "normal", .weight = "" },
        .mono => .{ .family = "DejaVu Sans Mono, monospace", .style = "normal", .weight = "" },
    };
}

/// Serialize a draw list to an SVG string. Caller owns the returned bytes.
/// Fails only on allocation failure (`error.OutOfMemory`) or a non-finite
/// coordinate (`error.NonFiniteCoordinate`, rejected by checkFinite).
pub fn render(
    gpa: std.mem.Allocator,
    dl: *const draw.DrawList,
    opts: Options,
) error{ OutOfMemory, NonFiniteCoordinate }![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    // The frame is the INK bounds, not the box bounds: boxes under-bind the
    // drawn glyphs (italic overhang past the advance, a display variant
    // taller than the box that sized it), so a frame built on them clips the
    // ink that is actually drawn.
    const ink = dl.bounds();

    // The largest text size in points: both margins below scale with the
    // glyph size, which the ink bbox itself does not carry.
    var max_size: f32 = 0;
    for (dl.items.items) |d| {
        if (d == .text) max_size = @max(max_size, d.text.size);
    }
    // Horizontal slack, left and right. The ink bbox measures a glyph's
    // horizontal extent from its ADVANCE box, not from the true ink left /
    // right edge (the math ink table carries ascent / descent only), and an
    // italic glyph leans past that edge — so a frame tight on the
    // accumulated ink would shave the overhang off. 0.08 em of the largest
    // size is the slop that covers it, and the border width XeTeX's preview
    // leaves around the content.
    const advance_slack = 0.08 * max_size;
    // Latin Modern Math has a 0.2em lineGap that browsers include in the
    // text line-box extent, below the baseline. Bounding only the glyph ink
    // under-shoots the browser's rendering and clips the bottom, so the
    // frame carries that descent below the ink.
    const linegap = 0.2 * max_size;

    // Vertically the ink is exact (a char box's h/d IS the drawn glyph's
    // ink), so only the caller's padding and the browser line box below the
    // baseline go on top of it — the ink top lands ON the frame edge.
    const pad_x = opts.padding + advance_slack;
    const pad_top = opts.padding;
    const pad_bottom = opts.padding + linegap;
    const w = ink.width + 2 * pad_x;
    const h = ink.height + ink.depth + pad_top + pad_bottom;
    // The frame origin is its top-left corner, so the INK MINIMUM (which is
    // not the root reference point: a fraction's ink starts at its
    // 1.2pt-inset numerator) lands on the frame margin. Every primitive
    // takes the same offset, which keeps it inside the frame.
    const off_x = pad_x - ink.min_x;
    const off_y = pad_top - ink.min_y;
    try checkFinite(&.{ w, h, off_x, off_y });

    // All layout numbers are points. width/height carry explicit pt units so
    // the output renders at its declared physical size (bare user units would
    // be px = 96/72 × pt, i.e. 0.75×). The viewBox stays unitless: its user
    // units are defined to equal pt by width/height.
    try buf.print(
        gpa,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}pt\" height=\"{d}pt\" viewBox=\"0 0 {d} {d}\">\n",
        .{ w, h, w, h },
    );
    if (opts.background) |bg| {
        try buf.print(gpa, "<rect width=\"{d}pt\" height=\"{d}pt\" fill=\"#{s}\"/>\n", .{ w, h, colorHex(bg) });
    }

    for (dl.items.items) |d| {
        switch (d) {
            .text => |t| {
                const fs = fontSpec(t.style, &opts);
                try checkFinite(&.{ t.x + off_x, t.y + off_y, t.size });
                try buf.print(
                    gpa,
                    "<text x=\"{d}pt\" y=\"{d}pt\" font-size=\"{d}pt\" font-family=\"",
                    .{ t.x + off_x, t.y + off_y, t.size },
                );
                // font_family/text_font_family are caller-supplied (Options),
                // so escape them like text content: a `"` would otherwise
                // break the attribute or allow attribute injection.
                try escapeAppend(gpa, &buf, fs.family);
                try buf.print(gpa, "\" font-style=\"{s}\"", .{fs.style});
                if (t.bigop_form == .variant) {
                    // A DISPLAY big-op: the drawn glyph is the OpenType
                    // MATH-table .v1 variant (XeTeX's display form), not the
                    // cmap base glyph the browser shows. The critique
                    // rasterizer/verifier read this marker and resolve the
                    // .v1 PUA glyph; unmarked big-ops (text/script style)
                    // draw the cmap base glyph at their declared size. The
                    // declared font-size cannot tell the forms apart — both
                    // are emitted at the current size.
                    try buf.appendSlice(gpa, " data-op=\"v1\"");
                }
                if (t.radical_form > 0) {
                    // A stretchy √ glyph: the drawn glyph is the OpenType
                    // MATH-table vertical variant (radical.v1..v4), not the
                    // cmap base glyph the browser shows at the declared size.
                    // The critique rasterizer reads this marker and resolves
                    // the variant PUA glyph; a browser renders the base √
                    // (taller variants are a MATH-only feature). The
                    // font-size alone cannot tell the forms apart — both
                    // draw at the current math size.
                    try buf.print(gpa, " data-radical=\"v{d}\"", .{t.radical_form});
                }
                if (t.delim_fixed > 0) {
                    // A \left/\right delimiter sized by amsmath's FIXED
                    // fraction-delimiter rule (fenced \binom/\genfrac):
                    // the layout boxed it by this req_em. The rasterizer
                    // resolves the same variant; the base font-size alone
                    // cannot tell it from a content-sized fence.
                    try buf.print(gpa, " data-fixed-req=\"{d:.3}\"", .{t.delim_fixed});
                }
                if (t.delim_form > 0) {
                    // A \left/\right delimiter sized by content (TeX
                    // make_delim, layoutDelimChar): the layout picked the
                    // SMALLEST MATH-table variant whose asc+desc ink
                    // covered the inner box's extent and tagged it as the
                    // 1..7 ladder index. The rasterizer resolves the same
                    // variant glyph (critique.py maps to a PUA codepoint);
                    // the base font-size alone cannot tell it apart from
                    // a plain `\left(x\right)` (a tall pmatrix fence at
                    // 20pt needs v6+, otherwise the paren is drawn at
                    // 20pt — too short for 4 rows of content).
                    try buf.print(gpa, " data-delim-form=\"v{d}\"", .{t.delim_form});
                }
                if (t.delim_req > 0) {
                    // A content-sized fence whose required ink EXCEEDS the
                    // largest MATH-table variant (delim_form capped at v7
                    // but the content — e.g. a 4-row pmatrix — is taller):
                    // the exact required height in em of the base size, so
                    // the rasterizer assembles the XeTeX GlyphAssembly
                    // (top + N extenders + bottom) to exactly this height
                    // instead of drawing v7 too short.
                    try buf.print(gpa, " data-delim-req=\"{d:.3}\"", .{t.delim_req});
                }
                if (fs.weight.len > 0) {
                    try buf.print(gpa, " font-weight=\"{s}\"", .{fs.weight});
                }
                try buf.print(gpa, " fill=\"#{s}\">", .{colorHex(t.color)});
                try escapeAppend(gpa, &buf, t.bytes);
                try buf.append(gpa, '<');
                try buf.appendSlice(gpa, "/text>\n");
            },
            .rect => |r| {
                try checkFinite(&.{ r.x + off_x, r.y + off_y, r.w, r.h });
                try buf.print(
                    gpa,
                    "<rect x=\"{d}pt\" y=\"{d}pt\" width=\"{d}pt\" height=\"{d}pt\" fill=\"#{s}\"/>\n",
                    .{ r.x + off_x, r.y + off_y, r.w, r.h, colorHex(r.color) },
                );
            },
            .line => |l| {
                try checkFinite(&.{
                    l.x0 + off_x, l.y0 + off_y, l.x1 + off_x, l.y1 + off_y, l.width,
                });
                try buf.print(
                    gpa,
                    "<line x1=\"{d}pt\" y1=\"{d}pt\" x2=\"{d}pt\" " ++
                        "y2=\"{d}pt\" stroke=\"#{s}\" stroke-width=\"{d}pt\"/>\n",
                    .{
                        l.x0 + off_x,      l.y0 + off_y, l.x1 + off_x, l.y1 + off_y,
                        colorHex(l.color), l.width,
                    },
                );
            },
        }
    }
    try buf.appendSlice(gpa, "</svg>\n");
    return buf.toOwnedSlice(gpa);
}

/// Write the SVG for a draw list to `path` (created/truncated) inside `dir`.
pub fn writeFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    dl: *const draw.DrawList,
    opts: Options,
) !void {
    const svg = try render(gpa, dl, opts);
    defer gpa.free(svg);
    var file = try std.Io.Dir.createFile(dir, io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, svg);
}

fn colorHex(c: draw.Color) [8]u8 {
    return .{
        hexDigit(c.r >> 4),
        hexDigit(c.r & 0x0f),
        hexDigit(c.g >> 4),
        hexDigit(c.g & 0x0f),
        hexDigit(c.b >> 4),
        hexDigit(c.b & 0x0f),
        hexDigit(c.a >> 4),
        hexDigit(c.a & 0x0f),
    };
}

fn hexDigit(value: u8) u8 {
    return "0123456789abcdef"[value & 0x0f];
}

/// Parse a color from a name (`white`, `black`, …) or hex (`#RRGGBB[AA]`).
/// Returns null for the valid "no background" values `none`/`transparent`,
/// a `draw.Color` for a recognized name/hex, and
/// `error.UnrecognizedColor` for anything else — so callers can tell "no
/// background" apart from a typo (e.g. `-b blak`).
pub fn parseColorChecked(s: []const u8) !?draw.Color {
    if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "transparent")) return null;
    if (s.len > 0 and s[0] == '#') return parseHex(s[1..]) orelse error.UnrecognizedColor;
    const named = [_]struct { name: []const u8, c: draw.Color }{
        .{ .name = "white", .c = .{ .r = 255, .g = 255, .b = 255 } },
        .{ .name = "black", .c = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .name = "red", .c = .{ .r = 255, .g = 0, .b = 0 } },
        .{ .name = "green", .c = .{ .r = 0, .g = 128, .b = 0 } },
        .{ .name = "blue", .c = .{ .r = 0, .g = 0, .b = 255 } },
        .{ .name = "yellow", .c = .{ .r = 255, .g = 255, .b = 0 } },
        .{ .name = "cyan", .c = .{ .r = 0, .g = 255, .b = 255 } },
        .{ .name = "magenta", .c = .{ .r = 255, .g = 0, .b = 255 } },
        .{ .name = "orange", .c = .{ .r = 255, .g = 165, .b = 0 } },
        .{ .name = "gray", .c = .{ .r = 128, .g = 128, .b = 128 } },
        .{ .name = "grey", .c = .{ .r = 128, .g = 128, .b = 128 } },
    };
    for (named) |n| {
        if (std.mem.eql(u8, s, n.name)) return n.c;
    }
    return error.UnrecognizedColor;
}

fn parseHex(s: []const u8) ?draw.Color {
    if (s.len != 6 and s.len != 8) return null;
    var c: draw.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (s.len == 8) c.a = std.fmt.parseInt(u8, s[6..8], 16) catch return null;
    c.r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
    c.g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
    c.b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
    return c;
}

/// Fail loudly (error) rather than emit `nan`/`inf` into the SVG. A
/// non-finite coordinate would otherwise be printed verbatim by `{d}` and
/// produce a broken/invisible document.
fn checkFinite(vals: []const f32) !void {
    for (vals) |v| {
        if (!std.math.isFinite(v)) return error.NonFiniteCoordinate;
    }
}

/// XML-escape text content: `& < > "`.
fn escapeAppend(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try buf.appendSlice(gpa, "&amp;"),
            '<' => try buf.appendSlice(gpa, "&lt;"),
            '>' => try buf.appendSlice(gpa, "&gt;"),
            '"' => try buf.appendSlice(gpa, "&quot;"),
            else => try buf.append(gpa, c),
        }
    }
}

const font_family_attr = " font-family=\"";
const data_op_attr = " data-op=\"v1\"";

/// One stripped attribute: `start` is where its text begins, `after` is the
/// offset the copy continues from once it is gone.
const StripHit = struct { start: usize, after: usize };

/// Golden-snapshot form of an SVG document: the same bytes with every
/// `font-family="…"` value and every `data-op="v1"` marker removed. Both are
/// stripped because neither is geometry. The family name depends on the
/// machine's font stack, so keeping it would make the goldens fail on any
/// machine but this one; `data-op` is the rasterizer's hint that the drawn
/// glyph is the OpenType MATH `.v1` big-op variant, covered by the critique
/// rasterizer instead of the snapshot. font-style/weight and pt units are
/// kept. Either attribute may come first inside a `<text>`, so both are
/// removed in one input-ordered pass. Caller owns the result; `svg` is only
/// read.
pub fn stripForGoldenSnapshot(
    gpa: std.mem.Allocator,
    svg: []const u8,
) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (nextStrip(svg, i)) |hit| {
        try out.appendSlice(gpa, svg[i..hit.start]);
        i = hit.after;
    }
    if (i < svg.len) try out.appendSlice(gpa, svg[i..]);
    return out.toOwnedSlice(gpa);
}

/// The earlier of the two stripped attributes at or after `from`, or null
/// when the remaining input holds neither.
fn nextStrip(svg: []const u8, from: usize) ?StripHit {
    const fam = std.mem.findPos(u8, svg, from, font_family_attr);
    const dop = std.mem.findPos(u8, svg, from, data_op_attr);
    if (fam) |f| {
        if (dop) |d| {
            if (d < f) return dataOpHit(d);
        }
        // the family value ends at its closing quote
        var j = f + font_family_attr.len;
        while (j < svg.len and svg[j] != '"') j += 1;
        return .{ .start = f, .after = j + 1 };
    }
    if (dop) |d| return dataOpHit(d);
    return null;
}

fn dataOpHit(at: usize) StripHit {
    return .{ .start = at, .after = at + data_op_attr.len };
}

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

const black = draw.Color{ .r = 0, .g = 0, .b = 0 };

/// A draw list shaped like a laid-out `\frac{1}{2}` at 20pt: a numerator
/// run, the rule, a denominator run — with KNOWN ink extents, recorded the
/// way `flatten` records them (a text run's horizontal extent is its
/// ADVANCE box, a rect's is its own area), so the ink box is
/// x ∈ [1.2, 11.2], y ∈ [-26, 17]. The ink origin is NOT the root reference
/// point: a fraction pads its parts by TeX's 1.2pt nulldelimiterspace, so
/// the leftmost ink starts at x = 1.2. The BOX bounds stay 0 — a box that
/// under-binds the drawn ink is exactly the case the frame must survive.
fn fractionDrawList(gpa: std.mem.Allocator) !draw.DrawList {
    var dl = draw.DrawList.init(gpa);
    errdefer dl.deinit();
    try dl.add(.{ .text = .{
        .bytes = "1",
        .x = 1.2,
        .y = -13,
        .size = 20,
        .style = .italic,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    } });
    dl.accInk(1.2, -26, 6.2, -13); // 13pt of ink ascent, no descent
    try dl.add(.{ .rect = .{
        .x = 1.2,
        .y = -5,
        .w = 10,
        .h = 0.8,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    } });
    dl.accInk(1.2, -5, 11.2, -4.2);
    try dl.add(.{ .text = .{
        .bytes = "2",
        .x = 1.2,
        .y = 13,
        .size = 20,
        .style = .italic,
        .color = black,
        .src_start = 1,
        .src_end = 2,
    } });
    dl.accInk(1.2, 13, 6.2, 17); // no ink ascent, 4pt of descent
    return dl;
}

/// Three runs in a row at 20pt — math italic (the default), roman and bold:
/// the three font specs `render` emits. Each run carries its ink.
fn styledDrawList(gpa: std.mem.Allocator) !draw.DrawList {
    var dl = draw.DrawList.init(gpa);
    errdefer dl.deinit();
    const styles = [3]atom.CharStyle{ .italic, .roman, .bold };
    const runs = [3][]const u8{ "x", "hi", "b" };
    for (styles, runs, 0..) |style, bytes, i| {
        const x: f32 = @floatFromInt(10 * i);
        try dl.add(.{ .text = .{
            .bytes = bytes,
            .x = x,
            .y = 0,
            .size = 20,
            .style = style,
            .color = black,
            .src_start = @intCast(i),
            .src_end = @intCast(i + 1),
        } });
        dl.accInk(x, -7, x + 5, 2); // 7pt of ink ascent, 2pt of descent
    }
    return dl;
}

/// The largest text size in the draw list, in points — the frame's margins
/// are documented in `render` as fractions of it.
fn maxTextSize(dl: *const draw.DrawList) f32 {
    var max_size: f32 = 0;
    for (dl.items.items) |d| {
        if (d == .text) max_size = @max(max_size, d.text.size);
    }
    return max_size;
}

/// The frame the primitives live in: the viewBox width/height. The root
/// element declares the same numbers in pt, so a mismatch would render the
/// document at other than its declared physical size.
const Frame = struct { w: f32, h: f32 };

fn frameOf(svg: []const u8) !Frame {
    const at = std.mem.indexOf(u8, svg, "viewBox=\"0 0 ") orelse return error.MissingAttribute;
    var i = at + "viewBox=\"0 0 ".len;
    const w = try scanNum(svg, &i);
    const h = try scanNum(svg, &i);
    try testing.expectApproxEqAbs(w, try attrNumber(svg, " width=\""), 0.001);
    try testing.expectApproxEqAbs(h, try attrNumber(svg, " height=\""), 0.001);
    return .{ .w = w, .h = h };
}

/// The shift every primitive takes from its draw-list coordinate: the
/// frame's own origin.
const Shift = struct { x: f32, y: f32 };

/// The frame invariant, for a whole document:
///   - every emitted primitive lies inside the frame, at a non-negative
///     coordinate;
///   - every primitive takes the SAME shift, and that shift puts the frame
///     origin on the INK minimum: the ink top lands on the top edge (the
///     vertical ink is exact) and the ink sits between equal horizontal
///     margins (the ink's horizontal edge is the advance box, which
///     under-binds an italic overhang, so a margin stays).
/// Walks the emitted elements in painter order, zipped with the draw
/// list's primitives. Every primitive must be visited: an element `render`
/// emitted outside the draw list (the background rect) or not at all (the
/// root, the closing tag) carries no geometry and is skipped, so the zip
/// stays aligned.
fn expectInsideFrame(svg: []const u8, dl: *const draw.DrawList, frame: Frame) !void {
    const ink = dl.bounds();
    var shift: ?Shift = null;

    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, svg, '\n');
    while (lines.next()) |line| {
        if (checked == dl.len()) break;
        const box = emittedBox(line) orelse continue;
        const d = dl.items.items[checked];
        try testing.expect(box.x0 >= 0);
        try testing.expect(box.y0 >= 0);
        try testing.expect(box.x1 <= frame.w);
        try testing.expect(box.y1 <= frame.h);
        const one: Shift = switch (d) {
            .text => |t| .{ .x = box.x0 - t.x, .y = box.y0 - t.y },
            .rect => |r| .{ .x = box.x0 - r.x, .y = box.y0 - r.y },
            .line => |l| .{
                .x = box.x0 - @min(l.x0, l.x1),
                .y = box.y0 - @min(l.y0, l.y1),
            },
        };
        if (shift) |s| {
            try testing.expectApproxEqAbs(s.x, one.x, 0.001);
            try testing.expectApproxEqAbs(s.y, one.y, 0.001);
        } else {
            shift = one;
        }
        checked += 1;
    }
    try testing.expectEqual(dl.len(), checked);
    const origin = shift orelse return error.NoPrimitivesEmitted;
    try testing.expectApproxEqAbs(@as(f32, 0), ink.min_y + origin.y, 0.001);
    try testing.expectApproxEqAbs((frame.w - ink.width) / 2, ink.min_x + origin.x, 0.001);
}

/// The bounding box of one emitted element, over every geometry attribute
/// it carries. A `<text>` run carries only its baseline anchor (its
/// advance is not emitted), so its box is a point. Null for a line with no
/// geometry (the root element, the background rect, the closing tag).
fn emittedBox(line: []const u8) ?struct { x0: f32, y0: f32, x1: f32, y1: f32 } {
    var x0 = std.math.inf(f32);
    var x1 = -std.math.inf(f32);
    var y0 = std.math.inf(f32);
    var y1 = -std.math.inf(f32);
    var found = false;
    for ([_][]const u8{ " x=\"", " x1=\"", " x2=\"" }) |attr| {
        const v = attrNumber(line, attr) catch continue;
        x0 = @min(x0, v);
        x1 = @max(x1, v);
        found = true;
    }
    for ([_][]const u8{ " y=\"", " y1=\"", " y2=\"" }) |attr| {
        const v = attrNumber(line, attr) catch continue;
        y0 = @min(y0, v);
        y1 = @max(y1, v);
        found = true;
    }
    if (!found) return null;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

/// Parse the number at `i` (after one separating space) and advance `i`
/// past it. Fails when no number follows.
fn scanNum(s: []const u8, i: *usize) !f32 {
    if (i.* < s.len and s[i.*] == ' ') i.* += 1;
    const start = i.*;
    while (i.* < s.len) : (i.* += 1) {
        const c = s[i.*];
        const is_num = (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e';
        if (!is_num) break;
    }
    if (i.* == start) return error.EmptyAttribute;
    return std.fmt.parseFloat(f32, s[start..i.*]);
}

/// Parse the number at the first occurrence of `attr` in an SVG attribute
/// value, stopping at the value's first non-numeric character (the `pt`
/// unit, the separating space, or the closing quote). Fails when `attr` is
/// absent.
fn attrNumber(hay: []const u8, attr: []const u8) !f32 {
    const at = std.mem.indexOf(u8, hay, attr) orelse return error.MissingAttribute;
    var i = at + attr.len;
    return scanNum(hay, &i);
}

test "svg: the frame is the ink bbox and every coordinate is non-negative" {
    var dl = try fractionDrawList(testing.allocator);
    defer dl.deinit();
    const ink = dl.bounds();
    // the ink origin is NOT the root reference point: the fraction pads its
    // parts by 1.2pt, so the frame has to offset by it
    try testing.expect(ink.min_x > 0);

    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    const frame = try frameOf(svg);
    try expectInsideFrame(svg, &dl, frame);

    // The margins are the documented ones: 0.08em of advance slack either
    // side (the ink's horizontal edge is the advance box, which under-binds
    // an italic overhang) and 0.2em of browser line box below the ink.
    // Assert the invariant, not a float literal: 0.08 * 20 is 1.6000001 in
    // f32, so pinning its spelling would pin float formatting.
    const margin = (frame.w - ink.width) / 2;
    try testing.expectApproxEqAbs(0.08 * maxTextSize(&dl), margin, 0.001);
    try testing.expectApproxEqAbs(
        0.2 * maxTextSize(&dl),
        frame.h - (ink.height + ink.depth),
        0.001,
    );
}

test "svg: a box that under-binds the ink cannot clip the frame" {
    var dl = try fractionDrawList(testing.allocator);
    defer dl.deinit();
    const correct = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(correct);
    // The same draw list, now with box bounds that BOUND its ink, against
    // the under-binding zeros it carried above. The frame follows the ink
    // either way, so the document is byte-identical.
    const ink = dl.bounds();
    try testing.expect(ink.width > dl.width);
    try testing.expect(ink.height > dl.height);
    dl.width = 12;
    dl.height = 30;
    dl.depth = 20;
    const bounding = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(bounding);
    try testing.expectEqualStrings(correct, bounding);
    // ... and the frame still holds every primitive.
    try expectInsideFrame(bounding, &dl, try frameOf(bounding));
}

test "svg: escapes xml-special characters in text" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "a<b&c",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 5,
    } });
    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "a&lt;b&amp;c") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "a<b&c") == null);
}

test "svg: background fills the viewBox" {
    var dl = try fractionDrawList(testing.allocator);
    defer dl.deinit();
    const svg = try render(testing.allocator, &dl, .{ .background = .{ .r = 255, .g = 255, .b = 255 } });
    defer testing.allocator.free(svg);
    const frame = try frameOf(svg);
    // the background spans the whole frame, in the frame's own pt units
    var want: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &want,
        "<rect width=\"{d}pt\" height=\"{d}pt\" fill=\"#ffffffff\"/>",
        .{ frame.w, frame.h },
    );
    try testing.expect(std.mem.indexOf(u8, svg, head) != null);
    // ... and the content primitives are still framed on top of it
    try expectInsideFrame(svg, &dl, frame);
}

test "svg: pt units and per-style fonts on the svg root and text" {
    var dl = try styledDrawList(testing.allocator);
    defer dl.deinit();
    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    // the root declares the frame in pt (bare user units would be px, 0.75x)
    // and the viewBox repeats the same numbers
    const frame = try frameOf(svg);
    var want: [192]u8 = undefined;
    const head = try std.fmt.bufPrint(&want, "<svg xmlns=\"http://www.w3.org/2000/svg\" " ++
        "width=\"{d}pt\" height=\"{d}pt\" viewBox=\"0 0 {d} {d}\">", .{
        frame.w, frame.h, frame.w, frame.h,
    });
    try testing.expect(std.mem.startsWith(u8, svg, head));
    // math (italic) runs: math family + font-style italic
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Latin Modern Math, Latin Modern Roman, " ++
        "DejaVu Serif, serif\" font-style=\"italic\"") != null);
    // \text/\mathrm (roman): upright text family + font-style normal
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Latin Modern Roman, DejaVu Serif, serif\" " ++
        "font-style=\"normal\"") != null);
    // \mathbf: bold weight on the text family
    try testing.expect(std.mem.indexOf(u8, svg, "font-weight=\"bold\"") != null);
    try expectInsideFrame(svg, &dl, frame);
}

test "svg: parseColorChecked tells none/transparent from unrecognized" {
    // valid "no background" values stay null (no background)
    try testing.expect((try parseColorChecked("none")) == null);
    try testing.expect((try parseColorChecked("transparent")) == null);
    // a valid color parses
    try testing.expectEqual(@as(draw.Color, .{ .r = 255, .g = 0, .b = 0 }), (try parseColorChecked("red")).?);
    try testing.expectEqual(@as(draw.Color, .{ .r = 255, .g = 128, .b = 0 }), (try parseColorChecked("#ff8000")).?);
    // bad hex is rejected
    try testing.expectError(error.UnrecognizedColor, parseColorChecked("#zz0000"));
    // an unrecognized string errors (not silently treated as no background)
    try testing.expectError(error.UnrecognizedColor, parseColorChecked("blak"));
}

test "svg: escapes quotes in the font-family attribute" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "x",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 1,
    } });
    const svg = try render(testing.allocator, &dl, .{ .font_family = "Fake \"Injected\" Family" });
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Fake &quot;Injected&quot; Family\"") != null);
    // the raw quote must not survive into the attribute
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Fake \"Injected\" Family\"") == null);
}

test "svg: rejects non-finite coordinates" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "x",
        .x = std.math.nan(f32),
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 1,
    } });
    try testing.expectError(error.NonFiniteCoordinate, render(testing.allocator, &dl, .{}));
}
test "svg: \\mathbf declares a bold weight and \\text does not" {
    // The bitmap path resolves \mathbf to the embedded bold face; the SVG
    // path cannot embed a face, so it declares the weight instead. Both sides
    // must agree that \mathbf is bold, or the two outputs diverge.
    const emit = struct {
        fn f(style: atom.CharStyle) ![]u8 {
            var dl = draw.DrawList.init(testing.allocator);
            defer dl.deinit();
            try dl.add(.{ .text = .{
                .bytes = "x",
                .x = 0,
                .y = 0,
                .size = 10,
                .style = style,
                .color = .{ .r = 0, .g = 0, .b = 0 },
                .src_start = 0,
                .src_end = 1,
            } });
            dl.accInk(0, -7, 5, 2);
            return try render(testing.allocator, &dl, .{});
        }
    }.f;

    const bold = try emit(.bold);
    defer testing.allocator.free(bold);
    const roman = try emit(.roman);
    defer testing.allocator.free(roman);

    try testing.expect(std.mem.indexOf(u8, bold, "font-weight=\"bold\"") != null);
    try testing.expect(std.mem.indexOf(u8, roman, "font-weight=") == null);
}
