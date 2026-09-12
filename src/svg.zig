//! ztex.svg — serialize a draw list into SVG.
//!
//! The draw model uses baseline-anchored coordinates (y = baseline; ascent is
//! negative). SVG is top-down, so this module offsets every primitive down by
//! the draw list's total ascent so all content sits at non-negative y inside
//! the viewBox. Text is emitted with its baseline at `y` (SVG default
//! dominant-baseline is alphabetic).

const std = @import("std");
const layout = @import("ztex.layout");
const draw = layout.draw;
const atom = draw.atom;

pub const Options = struct {
    /// empty margin around the content (pt)
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

    // Small safety slop so the frame bounds the ink even with minor renderer
    // font-metric variation; kept tight (0.08 x max_size) to match the
    // references' borders (XeTeX preview ~6pt, KaTeX tight). The lineGap
    // below handles the browser line-box descent.
    var max_size: f32 = 0;
    for (dl.items.items) |d| {
        if (d == .text) max_size = @max(max_size, d.text.size);
    }
    const margin = 0.08 * max_size;
    // Latin Modern Math has a 0.2em lineGap that browsers include in the
    // text line-box extent (below the baseline). Bounding only the glyph ink
    // under-shoots the browser's rendering and clips the bottom.
    const linegap = 0.2 * max_size;
    const pad = opts.padding + margin;
    const w = dl.width + 2 * pad;
    const h = dl.height + dl.depth + 2 * pad + linegap;
    const base = dl.height + pad; // baseline offset so top lands at y = pad
    try checkFinite(&.{ w, h });

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
                try checkFinite(&.{ t.x + pad, t.y + base, t.size });
                try buf.print(
                    gpa,
                    "<text x=\"{d}pt\" y=\"{d}pt\" font-size=\"{d}pt\" font-family=\"",
                    .{ t.x + pad, t.y + base, t.size },
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
                try checkFinite(&.{ r.x + pad, r.y + base, r.w, r.h });
                try buf.print(
                    gpa,
                    "<rect x=\"{d}pt\" y=\"{d}pt\" width=\"{d}pt\" height=\"{d}pt\" fill=\"#{s}\"/>\n",
                    .{ r.x + pad, r.y + base, r.w, r.h, colorHex(r.color) },
                );
            },
            .line => |l| {
                try checkFinite(&.{ l.x0 + pad, l.y0 + base, l.x1 + pad, l.y1 + base, l.width });
                try buf.print(
                    gpa,
                    "<line x1=\"{d}pt\" y1=\"{d}pt\" x2=\"{d}pt\" " ++
                        "y2=\"{d}pt\" stroke=\"#{s}\" stroke-width=\"{d}pt\"/>\n",
                    .{ l.x0 + pad, l.y0 + base, l.x1 + pad, l.y1 + base, colorHex(l.color), l.width },
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

test "svg: baseline offset places all content at non-negative y" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    // a single char with ascent 8, depth 2, on the baseline
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
    dl.width = 5;
    dl.height = 8;
    dl.depth = 2;
    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    // The baseline lands at the draw list's ascent plus the 0.08*size frame
    // margin, so the content top sits at y = margin and every coordinate is
    // non-negative. Assert the invariant, not a formatted float literal:
    // 0.08 * 10 is 0.79999995 in f32, so pinning its shortest-round-trip
    // spelling would pin float formatting instead of the geometry.
    try testing.expectApproxEqAbs(@as(f32, 8.8), try attrNumber(svg, "y=\""), 0.001);
    // The frame bounds the ink: ascent + descent, padded by the margin on
    // both sides, plus the 0.2em browser lineGap below the baseline.
    try testing.expectApproxEqAbs(
        @as(f32, 8 + 2 + 2 * 0.8 + 2),
        try attrNumber(svg, "height=\""),
        0.001,
    );
    try testing.expectApproxEqAbs(@as(f32, 5 + 2 * 0.8), try attrNumber(svg, "width=\""), 0.001);
}

/// Parse the number at the first occurrence of `attr` in an SVG attribute
/// value, stopping at the value's first non-numeric character (the `pt`
/// unit or the closing quote). Fails when `attr` is absent.
fn attrNumber(svg: []const u8, attr: []const u8) !f32 {
    const at = std.mem.indexOf(u8, svg, attr) orelse return error.MissingAttribute;
    const start = at + attr.len;
    var end = start;
    while (end < svg.len) : (end += 1) {
        const c = svg[end];
        const is_num = (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e';
        if (!is_num) break;
    }
    if (end == start) return error.EmptyAttribute;
    return std.fmt.parseFloat(f32, svg[start..end]);
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
    dl.width = 10;
    dl.height = 5;
    dl.depth = 1;
    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "a&lt;b&amp;c") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "a<b&c") == null);
}

test "svg: background fills the viewBox" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    dl.width = 10;
    dl.height = 5;
    dl.depth = 1;
    const svg = try render(testing.allocator, &dl, .{ .background = .{ .r = 255, .g = 255, .b = 255 } });
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "<rect width=\"10pt\" height=\"6pt\" fill=\"#ffffffff\"/>") != null);
}

test "svg: pt units and per-style fonts on the svg root and text" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "x",
        .x = 0,
        .y = 0,
        .size = 20,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 1,
    } });
    _ = try dl.add(.{ .text = .{
        .bytes = "hi",
        .x = 10,
        .y = 0,
        .size = 20,
        .style = .roman,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 1,
        .src_end = 3,
    } });
    _ = try dl.add(.{ .text = .{
        .bytes = "b",
        .x = 20,
        .y = 0,
        .size = 20,
        .style = .bold,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 3,
        .src_end = 4,
    } });
    dl.width = 30;
    dl.height = 8;
    dl.depth = 2;
    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    // root width/height carry pt (margin 0.08*20=1.6 each side => +3.2 wide;
    // height = 8+2+3.2 + lineGap 4 = 17.2); viewBox unitless
    try testing.expect(std.mem.indexOf(u8, svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"33.2pt\" " ++
        "height=\"17.2pt\" viewBox=\"0 0 33.2 17.2\">") != null);
    // math (italic) runs: math family + font-style italic
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Latin Modern Math, Latin Modern Roman, " ++
        "DejaVu Serif, serif\" font-style=\"italic\"") != null);
    // \text/\mathrm (roman): upright text family + font-style normal
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Latin Modern Roman, DejaVu Serif, serif\" " ++
        "font-style=\"normal\"") != null);
    // \mathbf: bold weight on the text family
    try testing.expect(std.mem.indexOf(u8, svg, "font-weight=\"bold\"") != null);
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
    dl.width = 5;
    dl.height = 8;
    dl.depth = 2;
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
    dl.width = 5;
    dl.height = 8;
    dl.depth = 2;
    try testing.expectError(error.NonFiniteCoordinate, render(testing.allocator, &dl, .{}));
}
