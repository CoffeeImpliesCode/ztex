//! tools/gen_goldens.zig — print ready-to-paste Zig golden tables for the
//! breadth corpus (draw-list, SVG, and atom-tree snapshots), mirroring the
//! format of src/tests/regression.zig. Run via `zig build gen-goldens` (see
//! build.zig) or `zig run` with the module graph. The output is designed to
//! be pasted into the `golden` / `golden_svg` / `golden_atoms` tables.
//!
//! Usage: `zig build gen-goldens > /tmp/goldens.txt`.

const std = @import("std");
const ztex = @import("ztex");

// The breadth corpus: one formula per feature area. Each must parse and lay
// out cleanly (validated against `zig build run`). Keep formulas focused so
// a golden catches a targeted regression, not a soup.
const corpus = [_][]const u8{
    // fractions
    "\\frac{x^2+1}{x-1}",
    "\\dfrac{a}{b}",
    "\\cfrac{1}{a_1+\\cfrac{1}{a_2}}",
    "\\binom{n}{k}",
    // radicals
    "\\sqrt{a^2+b^2}",
    "\\sqrt[3]{\\frac{a}{b}}",
    // delimiters
    "\\left( \\frac{x+1}{x-1} \\right)",
    "\\left| x^2 \\right|",
    "\\big( a+b \\big)",
    "\\left\\{ \\frac{a}{b} \\right\\}",
    // big operators + limits
    "\\int_0^1 x^2\\,dx",
    "\\prod_{i=1}^{n} i",
    "\\lim_{x \\to 0} \\frac{\\sin x}{x}",
    "\\sum_{i=1}^{n} i^2",
    // styles
    "\\mathbb{R}",
    "\\mathbb{1}",
    "\\mathcal{L}",
    "\\mathbf{x}",
    // accents
    "\\hat{A}^{\\dagger}",
    "\\bar{x}",
    "\\vec{v}",
    "\\dot{q}",
    "\\tilde{n}",
    // environments
    "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
    "\\begin{cases} x & x>0 \\\\ -x & x\\le 0 \\end{cases}",
    // relations / operators
    "\\alpha + \\beta \\le \\gamma",
    "x \\in \\mathbb{R}",
    "x \\neq y",
    "e^{i\\theta}",
    // spaces / pmod
    "a\\,b",
    "x \\quad y",
    "x \\pmod n",
    "x \\bmod y",
};

/// The focused SVG corpus of src/tests/regression.zig, with the padding each
/// case renders at. Mirrors `regression.golden_svg`; that table cannot be
/// regenerated from the breadth corpus above, so this section exists to keep
/// it reproducible.
const regression_corpus = [_]struct { src: []const u8, padding: f32 }{
    .{ .src = "x", .padding = 0 },
    .{ .src = "x^2", .padding = 0 },
    .{ .src = "\\frac{1}{2}", .padding = 0 },
    .{ .src = "\\sum_{i=1}^{n}", .padding = 0 },
    .{ .src = "\\text{hi}", .padding = 0 },
    .{ .src = "x^2", .padding = 5 },
};

fn dumpDraw(gpa: std.mem.Allocator, src: []const u8, size: f32) ![]u8 {
    var dl = try ztex.render(gpa, src, size, null);
    defer dl.deinit();
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (dl.items.items) |d| {
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

fn dumpSvgOnly(gpa: std.mem.Allocator, src: []const u8, size: f32, padding: f32) ![]u8 {
    var dl = try ztex.render(gpa, src, size, null);
    defer dl.deinit();
    const svg = try ztex.svg.render(gpa, &dl, .{ .padding = padding });
    defer gpa.free(svg);
    return ztex.svg.stripForGoldenSnapshot(gpa, svg);
}

fn dumpAtomsOnly(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
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
            if (sp.end > sp.start) try buf.print(gpa, " {s}", .{ast.src[sp.start..sp.end]});
        },
        else => {},
    }
    try buf.append(gpa, '\n');
    for (0..n.num_children) |i| {
        try dumpNode(gpa, buf, ast, ast.child(idx, i));
    }
}

fn zigEscape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    // Escape for a Zig multiline string: a source backslash must be doubled
    // so the golden's `\frac` reads `\\frac` inside the \\ … \\ multiline.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.debug.print("== draw-list goldens ==\n", .{});
    for (corpus) |src| {
        const d = try dumpDraw(gpa, src, 20);
        defer gpa.free(d);
        const esc = try zigEscape(gpa, src);
        defer gpa.free(esc);
        std.debug.print(".{{ .src = \"{s}\", .dump =\n", .{esc});
        var it = std.mem.splitScalar(u8, d, '\n');
        while (it.next()) |line| {
            std.debug.print("    \\\\{s}\n", .{line});
        }
        std.debug.print("    }},\n", .{});
    }

    std.debug.print("\n== svg goldens ==\n", .{});
    for (corpus) |src| {
        const svg = try dumpSvgOnly(gpa, src, 20, 0);
        defer gpa.free(svg);
        const esc = try zigEscape(gpa, src);
        defer gpa.free(esc);
        std.debug.print(".{{ .src = \"{s}\", .padding = 0, .svg =\n", .{esc});
        var it = std.mem.splitScalar(u8, svg, '\n');
        while (it.next()) |line| {
            std.debug.print("    \\\\{s}\n", .{line});
        }
        std.debug.print("    }},\n", .{});
    }

    std.debug.print("\n== regression svg goldens ==\n", .{});
    for (regression_corpus) |c| {
        const svg = try dumpSvgOnly(gpa, c.src, 20, c.padding);
        defer gpa.free(svg);
        const esc = try zigEscape(gpa, c.src);
        defer gpa.free(esc);
        std.debug.print(
            ".{{ .src = \"{s}\", .padding = {d}, .svg =\n",
            .{ esc, @as(i32, @intFromFloat(c.padding)) },
        );
        var it = std.mem.splitScalar(u8, svg, '\n');
        while (it.next()) |line| {
            std.debug.print("    \\\\{s}\n", .{line});
        }
        std.debug.print("    }},\n", .{});
    }

    std.debug.print("\n== atom goldens ==\n", .{});
    for (corpus) |src| {
        const a = try dumpAtomsOnly(gpa, src);
        defer gpa.free(a);
        const esc = try zigEscape(gpa, src);
        defer gpa.free(esc);
        std.debug.print(".{{ .src = \"{s}\", .dump =\n", .{esc});
        var it = std.mem.splitScalar(u8, a, '\n');
        while (it.next()) |line| {
            std.debug.print("    \\\\{s}\n", .{line});
        }
        std.debug.print("    }},\n", .{});
    }
}
