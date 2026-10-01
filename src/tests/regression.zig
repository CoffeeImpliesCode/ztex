//! ztex.tests.regression — MicroTeX-style golden snapshots.
//!
//! Golden draw-list, SVG, and atom-tree snapshots for a fixed corpus. Any
//! change to the rendered output or the atom tree breaks a snapshot, pinning
//! the pipeline. To regenerate goldens after an intended change, dump the
//! actual output and update the tables below.

const std = @import("std");
const ztex = @import("ztex");

const testing = std.testing;

/// Canonical one-line-per-primitive rendering of a draw list, in painter
/// order. One line per primitive:
///   T:<bytes>,<x>,<y>,<size>[<src_start>,<src_end>]   — text glyph run
///   R:<x>,<y>,<w>,<h>[<src_start>,<src_end>]          — filled rect
///   L:<x0>,<y0>,<x1>,<y1>[<src_start>,<src_end>]      — stroked line
/// Numbers are shortest-round-trip floats / decimal ints (Ryu formatting),
/// so output is deterministic for a fixed code version.
pub fn dump(gpa: std.mem.Allocator, src: []const u8, size_pt: f32) ![]u8 {
    var out = try ztex.render(gpa, src, .display, size_pt, null);
    defer out.deinit();
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (out.items.items) |d| {
        switch (d) {
            .text => |t| try buf.print(gpa, "T:{s},{d},{d},{d}[{d},{d}]\n", .{
                t.bytes, t.x, t.y, t.size, t.src_start, t.src_end,
            }),
            .rect => |r| try buf.print(gpa, "R:{d},{d},{d},{d}[{d},{d}]\n", .{
                r.x, r.y, r.w, r.h, r.src_start, r.src_end,
            }),
            .line => |l| try buf.print(gpa, "L:{d},{d},{d},{d}[{d},{d}]\n", .{
                l.x0, l.y0, l.x1, l.y1, l.src_start, l.src_end,
            }),
        }
    }
    return buf.toOwnedSlice(gpa);
}

/// Golden draw-list snapshots for the corpus, at size_pt = 20.
pub const golden = [_]struct { src: []const u8, dump: []const u8 }{
    .{ .src = "x", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\
    },
    .{ .src = "x^2", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\T:2,11.759999,-7.26,14[2,3]
    \\
    },
    .{ .src = "x_2", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\T:2,11.44,4.94,14[2,3]
    \\
    },
    .{ .src = "x^2+y_1", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\T:2,11.759999,-7.26,14[2,3]
    \\T:+,23.704443,0,20[3,4]
    \\T:𝑦,43.708885,0,20[4,5]
    \\T:1,53.508884,4.94,14[6,7]
    \\
    },
    .{ .src = "\\frac{1}{2}", .dump =
    \\T:1,1.2,-13.53016,20[6,7]
    \\R:1.2,-5.4,10,0.8[0,10]
    \\T:2,1.2,13.71902,20[9,10]
    \\
    },
    .{ .src = "\\sum_{i=1}^{n}", .dump =
    \\T:𝑛,10.240001,-23.154,14[12,13]
    \\T:∑,0,0,20[0,4]
    \\T:𝑖,3.0790005,21.664001,14[6,7]
    \\T:=,7.9090004,21.664001,14[7,8]
    \\T:1,18.801,21.664001,14[8,9]
    \\
    },
    .{ .src = "\\text{hi}", .dump =
    \\T:h,0,0,20[6,7]
    \\T:i,10.22,0,20[7,8]
    \\
    },
    .{ .src = "\\mathbf{ab}", .dump =
    \\T:a,0,0,20[8,9]
    \\T:b,10,0,20[9,10]
    \\
    },
};

test "regression: draw-list snapshots" {
    for (golden) |g| {
        const actual = try dump(testing.allocator, g.src, 20);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(g.dump, actual);
    }
}

/// Serialize the full pipeline to an SVG string: LaTeX source → draw list →
/// SVG, with `padding` as the empty margin around the content. Caller owns
/// the returned bytes.
pub fn dumpSvg(gpa: std.mem.Allocator, src: []const u8, size_pt: f32, padding: f32) ![]u8 {
    var dl = try ztex.render(gpa, src, .display, size_pt, null);
    defer dl.deinit();
    const svg = try ztex.svg.render(gpa, &dl, .{ .padding = padding });
    defer gpa.free(svg);
    return ztex.svg.stripForGoldenSnapshot(gpa, svg);
}

/// Golden SVG snapshots for the corpus, at size_pt = 20.
pub const golden_svg = [_]struct { src: []const u8, padding: f32, svg: []const u8 }{
    .{ .src = "x", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="14.639999pt" height="13.06pt" viewBox="0 0 14.639999 13.06">
    \\<text x="1.5999999pt" y="8.84pt" font-size="20pt" font-style="italic" fill="#000000ff">𝑥</text>
    \\</svg>
    \\
    },
    .{ .src = "x^2", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="21.96pt" height="20.803999pt" viewBox="0 0 21.96 20.803999">
    \\<text x="1.5999999pt" y="16.584pt" font-size="20pt" font-style="italic" fill="#000000ff">𝑥</text>
    \\<text x="13.359999pt" y="9.323999pt" font-size="14pt" font-style="italic" fill="#000000ff">2</text>
    \\</svg>
    \\
    },
    .{ .src = "\\frac{1}{2}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="13.2pt" height="44.56918pt" viewBox="0 0 13.2 44.56918">
    \\<text x="1.5999999pt" y="13.319999pt" font-size="20pt" font-style="italic" fill="#000000ff">1</text>
    \\<rect x="1.5999999pt" y="21.45016pt" width="10pt" height="0.8pt" fill="#000000ff"/>
    \\<text x="1.5999999pt" y="40.56918pt" font-size="20pt" font-style="italic" fill="#000000ff">2</text>
    \\</svg>
    \\
    },
    .{ .src = "\\sum_{i=1}^{n}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="32.08pt" height="55.16pt" viewBox="0 0 32.08 55.16">
    \\<text x="11.84pt" y="6.1879997pt" font-size="14pt" font-style="italic" fill="#000000ff">𝑛</text>
    \\<text x="1.5999999pt" y="29.342pt" font-size="20pt" font-style="italic" fill="#000000ff">∑</text>
    \\<text x="4.6790004pt" y="51.006pt" font-size="14pt" font-style="italic" fill="#000000ff">𝑖</text>
    \\<text x="9.509001pt" y="51.006pt" font-size="14pt" font-style="italic" fill="#000000ff">=</text>
    \\<text x="20.401001pt" y="51.006pt" font-size="14pt" font-style="italic" fill="#000000ff">1</text>
    \\</svg>
    \\
    },
    .{ .src = "\\text{hi}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="18.42pt" height="17.880001pt" viewBox="0 0 18.42 17.880001">
    \\<text x="1.5999999pt" y="13.88pt" font-size="20pt" font-style="normal" fill="#000000ff">h</text>
    \\<text x="11.82pt" y="13.88pt" font-size="20pt" font-style="normal" fill="#000000ff">i</text>
    \\</svg>
    \\
    },
    .{ .src = "x^2", .padding = 5, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="31.96pt" height="30.803999pt" viewBox="0 0 31.96 30.803999">
    \\<text x="6.6pt" y="21.584pt" font-size="20pt" font-style="italic" fill="#000000ff">𝑥</text>
    \\<text x="18.359999pt" y="14.323999pt" font-size="14pt" font-style="italic" fill="#000000ff">2</text>
    \\</svg>
    \\
    },
};

test "regression: svg snapshots" {
    for (golden_svg) |g| {
        const actual = try dumpSvg(testing.allocator, g.src, 20, g.padding);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(g.svg, actual);
    }
}

/// Canonical pre-order dump of the root-reachable atom tree: one node per
/// line, `tag[start,end]`, plus the raw source text for leaf tags
/// (char/text/op/space). Children are visited in order, so the output is a
/// deterministic serialization of the parse.
pub fn dumpAtoms(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var ast = try ztex.parse.parse(gpa, src, null);
    defer ast.deinit();
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try dumpNode(gpa, &buf, &ast, ast.root);
    return buf.toOwnedSlice(gpa);
}

fn dumpNode(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), ast: *const ztex.atom.Ast, idx: u32) !void {
    const n = ast.node(idx);
    const sp = ast.span(idx);
    try buf.print(gpa, "{s}[{d},{d}]", .{ @tagName(n.tag), sp.start, sp.end });
    switch (n.tag) {
        .char, .text, .op, .space => {
            if (sp.end > sp.start) {
                try buf.print(gpa, " {s}", .{ast.src[sp.start..sp.end]});
            }
        },
        else => {},
    }
    try buf.append(gpa, '\n');
    for (0..n.num_children) |i| {
        try dumpNode(gpa, buf, ast, ast.child(idx, i));
    }
}

/// Golden atom-tree snapshots for the three most structurally distinct
/// formulas: script (x^2), fraction (\frac{1}{2}), big operator with limits
/// (\sum_{i=1}^{n}).
pub const golden_atoms = [_]struct { src: []const u8, dump: []const u8 }{
    .{ .src = "x^2", .dump =
    \\row[0,3]
    \\script[0,3]
    \\char[0,1] x
    \\char[2,3] 2
    \\
    },
    .{ .src = "\\frac{1}{2}", .dump =
    \\row[0,10]
    \\fraction[0,10]
    \\row[6,7]
    \\char[6,7] 1
    \\row[9,10]
    \\char[9,10] 2
    \\
    },
    .{ .src = "\\sum_{i=1}^{n}", .dump =
    \\row[0,14]
    \\script[0,14]
    \\op[0,4] \sum
    \\group[11,14]
    \\row[12,13]
    \\char[12,13] n
    \\group[5,10]
    \\row[6,9]
    \\char[6,7] i
    \\char[7,8] =
    \\char[8,9] 1
    \\
    },
};

test "regression: atom-tree snapshots" {
    for (golden_atoms) |g| {
        const actual = try dumpAtoms(testing.allocator, g.src);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(g.dump, actual);
    }
}

test {
    std.testing.refAllDecls(@This());
}
