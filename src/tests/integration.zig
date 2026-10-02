//! ztex.tests.integration — full-pipeline invariants over a LaTeX corpus.
//!
//! Render a fixed corpus through the public facade and assert structural
//! and geometry invariants without pinning internal serialization.

const std = @import("std");
const ztex = @import("ztex");

const testing = std.testing;

const size_pt: f32 = 20;

const corpus = [_][]const u8{
    "x",
    "x^2",
    "x_2",
    "x^2+y_1",
    "\\frac{1}{2}",
    "\\sum_{i=1}^{n}",
    "\\text{hi}",
    "\\mathbf{ab}",
};

test {
    std.testing.refAllDecls(@This());
}

test "integration: corpus renders non-empty with positive bounds" {
    for (corpus) |src| {
        var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
        defer out.deinit();
        try testing.expect(out.len() > 0);
        try testing.expect(out.width > 0);
        try testing.expect(out.height > 0);
    }
}

test "integration: every primitive carries valid provenance into the source" {
    for (corpus) |src| {
        var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
        defer out.deinit();
        for (out.items.items) |d| {
            switch (d) {
                .text => |t| {
                    // non-empty window into the original source
                    try testing.expect(t.src_start < t.src_end);
                    try testing.expect(t.src_end <= src.len);
                    // the glyph is non-empty and aliases the source window for
                    // ordinary chars (a big operator synthesizes e.g. ∑ instead)
                    try testing.expect(t.bytes.len > 0);
                    const aliased = std.mem.eql(u8, t.bytes, src[t.src_start..t.src_end]);
                    if (!aliased) {
                        // synthesized glyph: must still be a valid multi-byte codepoint
                        try testing.expect(t.bytes.len >= 2);
                    }
                },
                .rect => |r| {
                    try testing.expect(r.src_start < r.src_end);
                    try testing.expect(r.src_end <= src.len);
                },
                .line => |l| {
                    try testing.expect(l.src_start < l.src_end);
                    try testing.expect(l.src_end <= src.len);
                },
            }
        }
    }
}

test "integration: superscript is raised, shrunk, and has exact spans" {
    const src = "x^2";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    try testing.expectEqual(@as(usize, 2), out.len());
    const base = switch (out.items.items[0]) {
        .text => |t| t,
        else => return error.ExpectedTextPrimitive,
    };
    const sup = switch (out.items.items[1]) {
        .text => |t| t,
        else => return error.ExpectedTextPrimitive,
    };

    // base: full size on the baseline, covers "x"
    try testing.expectEqualStrings("𝑥", base.bytes);
    try testing.expectEqualStrings("x", src[base.src_start..base.src_end]);
    try testing.expectEqual(size_pt, base.size);

    // superscript: raised above the baseline and scaled down, covers "2"
    try testing.expectEqualStrings("2", sup.bytes);
    try testing.expectEqualStrings("2", src[sup.src_start..sup.src_end]);
    try testing.expect(sup.size < size_pt);
    try testing.expect(sup.y < 0);
}

test "integration: fraction draws a rule plus numerator and denominator" {
    const src = "\\frac{1}{2}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    var text_count: usize = 0;
    var rect_count: usize = 0;
    for (out.items.items) |d| {
        switch (d) {
            .text => text_count += 1,
            .rect => rect_count += 1,
            .line => {},
        }
    }
    try testing.expect(rect_count >= 1); // the fraction rule
    try testing.expect(text_count >= 2); // "1" and "2"
}

test "integration: text mode emits one full-size primitive per character" {
    const src = "\\text{hi}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();

    try testing.expectEqual(@as(usize, 2), out.len());
    for (out.items.items, 0..) |d, i| {
        const t = switch (d) {
            .text => |v| v,
            else => return error.ExpectedTextPrimitive,
        };
        try testing.expectEqual(size_pt, t.size);
        try testing.expectEqualStrings(if (i == 0) "h" else "i", t.bytes);
        // spans sit strictly inside the braces: '{' at byte 5, '}' at byte 8
        try testing.expect(t.src_start >= 6);
        try testing.expect(t.src_end <= 8);
    }
}

// The forced math classes rank by the glue TeX's spacing table gives them
// against an ord neighbour: `\mathord` takes nothing, `\mathpunct` a thin
// space after it, `\mathinner` a thin space on each side, `\mathbin` a medium
// space on each side, `\mathrel` a thick space on each side. Rendering one row
// per wrapper measures that ladder end to end, the parser's `\mathXXX` mapping
// included. The ORDER is the contract, never the points: a new face or a
// corrected table can move every width without breaking the ranking.
test "integration: the forced classes space in the order ord < punct < inner < bin < rel" {
    const rows = [_][]const u8{
        "a\\mathord{X}b",
        "a\\mathpunct{X}b",
        "a\\mathinner{X}b",
        "a\\mathbin{X}b",
        "a\\mathrel{X}b",
    };
    var widths: [rows.len]f32 = undefined;
    for (rows, 0..) |src, i| {
        var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
        defer out.deinit();
        widths[i] = out.width;
    }
    // Each rung measures strictly narrower than the next: an equal pair means
    // that wrapper never reached the glue table.
    for (widths[0 .. widths.len - 1], widths[1..]) |lower, upper| {
        try testing.expect(lower < upper);
    }
}

test "integration: boxed draws a closed frame outside the formula" {
    var plain = try ztex.render(testing.allocator, "x", .display, size_pt, null);
    defer plain.deinit();
    var framed = try ztex.render(testing.allocator, "\\boxed{x}", .display, size_pt, null);
    defer framed.deinit();
    try testing.expect(framed.width > plain.width);
    try testing.expect(framed.height > plain.height);
    try testing.expect(framed.depth > plain.depth);
    var horizontal: usize = 0;
    var vertical: usize = 0;
    for (framed.items.items) |d| {
        if (d == .rect) {
            const r = d.rect;
            if (r.w > r.h) horizontal += 1 else vertical += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), horizontal);
    try testing.expectEqual(@as(usize, 2), vertical);
}

test "integration: nested color scopes restore the surrounding foreground" {
    const src = "a{\\color{red}b\\textcolor{blue}{c}d}e";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    const expected = [_][3]u8{
        .{ 0, 0, 0 }, .{ 255, 0, 0 }, .{ 0, 0, 255 }, .{ 255, 0, 0 }, .{ 0, 0, 0 },
    };
    var glyph: usize = 0;
    for (out.items.items) |d| {
        if (d == .text) {
            try testing.expect(glyph < expected.len);
            const c = d.text.color;
            try testing.expectEqualSlices(u8, &expected[glyph], &.{ c.r, c.g, c.b });
            glyph += 1;
        }
    }
    try testing.expectEqual(expected.len, glyph);
}

test "integration: textcolor has the ordinary-group spacing of xcolor" {
    var plain = try ztex.render(testing.allocator, "a\\mathord{=}b", .display, size_pt, null);
    defer plain.deinit();
    var colored = try ztex.render(
        testing.allocator,
        "a\\textcolor{red}{=}b",
        .display,
        size_pt,
        null,
    );
    defer colored.deinit();
    try testing.expectApproxEqAbs(plain.width, colored.width, 0.001);
}

test "integration: hline surrounds rows without introducing empty cells" {
    const src =
        "\\begin{array}{cc}\\hline a&b\\\\\\hline c&d\\\\\\hline\\end{array}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var rules: [3]f32 = undefined;
    var rows = [_]?f32{ null, null };
    var rule_count: usize = 0;
    for (out.items.items) |d| {
        switch (d) {
            .rect => |r| {
                try testing.expect(rule_count < rules.len);
                try testing.expect(r.w > r.h);
                // \arrayrulewidth is a FIXED 0.4pt: the rule on a leading, an
                // interior and a trailing boundary is equally thick, and it is
                // never scaled with the font.
                try testing.expectApproxEqAbs(@as(f32, 0.4), r.h, 0.001);
                rules[rule_count] = r.y;
                rule_count += 1;
            },
            .text => |t| {
                const bytes = src[t.src_start..t.src_end];
                if (std.mem.eql(u8, bytes, "a")) rows[0] = t.y;
                if (std.mem.eql(u8, bytes, "c")) rows[1] = t.y;
            },
            .line => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(rules.len, rule_count);
    std.mem.sort(f32, &rules, {}, std.sort.asc(f32));
    const first_row = rows[0] orelse return error.TestUnexpectedResult;
    const last_row = rows[1] orelse return error.TestUnexpectedResult;
    try testing.expect(rules[0] < first_row);
    try testing.expect(first_row < rules[1]);
    try testing.expect(rules[1] < last_row);
    try testing.expect(last_row < rules[2]);
    // The two rows stand \baselineskip apart — the strut's own 0.7 + 0.3 of it
    // — plus the one \arrayrulewidth their shared boundary opens up.
    try testing.expectApproxEqAbs(1.2 * size_pt + 0.4, last_row - first_row, 0.001);
    // Two rules on ONE boundary are two separate \noalign entries, and
    // latex.ltx's \@xhline leaves \doublerulesep of clear air between their
    // ink bands: 2pt apart, each \arrayrulewidth thick.
    const pair_src = "\\begin{matrix}a\\\\\\hline\\hline b\\end{matrix}";
    var pair = try ztex.render(testing.allocator, pair_src, .display, size_pt, null);
    defer pair.deinit();
    var pair_rules: [2]f32 = undefined;
    var pair_count: usize = 0;
    for (pair.items.items) |d| {
        switch (d) {
            .rect => |r| {
                try testing.expect(pair_count < pair_rules.len);
                try testing.expectApproxEqAbs(@as(f32, 0.4), r.h, 0.001);
                pair_rules[pair_count] = r.y;
                pair_count += 1;
            },
            .text, .line => {},
        }
    }
    try testing.expectEqual(pair_rules.len, pair_count);
    try testing.expectApproxEqAbs(@as(f32, 2.0), pair_rules[1] - pair_rules[0], 0.001);
}

test "integration: matrix rows stand \\baselineskip apart" {
    // LaTeX's \@array zeroes \baselineskip and \lineskip inside a matrix, so
    // the row strut alone sets the baseline distance: 0.7 + 0.3 of
    // \baselineskip, exactly 1.2em — 24pt at this 20pt base. The text
    // paren's `(` box, whose 0.75 + 0.25em this replaced, put every
    // neighbouring row 20pt apart instead.
    const src = "\\begin{matrix}x\\\\x\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    try testing.expectApproxEqAbs(1.2 * size_pt, try glyphRowGap(&out, src, "x"), 0.001);
}

test "integration: textit and textbf keep text glyphs in their requested faces" {
    const cases = .{
        .{ "\\textit{ab}", "text_italic" },
        .{ "\\textbf{ab}", "bold" },
    };
    inline for (cases) |c| {
        var out = try ztex.render(testing.allocator, c[0], .display, size_pt, null);
        defer out.deinit();
        for (out.items.items, 0..) |d, i| {
            const t = d.text;
            try testing.expectEqualStrings(c[1], @tagName(t.style));
            try testing.expectEqualStrings(if (i == 0) "a" else "b", t.bytes);
        }
    }
}

test "integration: font-backed superscripts use the drawn glyph's MATH correction" {
    var ctx = try ztex.Context.init(testing.allocator);
    defer ctx.deinit();
    const face = ctx.fonts.math;
    for ([_]u21{ 0x1D453, 0x1D465 }, [_][]const u8{ "f^2", "x^2" }) |cp, src| {
        const gid = face.glyphIndex(cp) orelse return error.TestUnexpectedResult;
        const ic = face.mathValues(gid).italic_correction orelse 0;
        const advance = ctx.fonts.metrics(face, cp, size_pt).width;
        var out = try ctx.render(src, .display, size_pt, null);
        defer out.deinit();
        const base = out.items.items[0].text;
        const sup = out.items.items[1].text;
        try testing.expectApproxEqAbs(advance + ic * size_pt, sup.x - base.x, 0.001);
    }
}

test "integration: nested text weights and slants combine and restore" {
    const cases = .{
        .{ "\\textbf{a\\textit{b}c}", "bold", "bold_italic" },
        .{ "\\textit{a\\textbf{b}c}", "text_italic", "bold_italic" },
    };
    inline for (cases) |c| {
        var out = try ztex.render(testing.allocator, c[0], .display, size_pt, null);
        defer out.deinit();
        try testing.expectEqual(@as(usize, 3), out.items.items.len);
        for (out.items.items, 0..) |d, i| {
            try testing.expectEqualStrings(if (i == 1) c[2] else c[1], @tagName(d.text.style));
            try testing.expectEqualStrings("abc"[i .. i + 1], d.text.bytes);
        }
    }
}

test "integration: runtime MATH parameters control nested scripts and fraction rules" {
    var ctx = try ztex.Context.init(testing.allocator);
    defer ctx.deinit();
    const parsed = ctx.fonts.math.mathConstants() orelse return error.TestUnexpectedResult;
    var constants = parsed.*;
    constants.script_percent_scale_down = 0.6;
    constants.script_script_percent_scale_down = 0.4;
    constants.fraction_rule_thickness = 0.08;
    constants.fraction_num_display_style_gap_min = 0.8;
    constants.fraction_denom_display_style_gap_min = 0.8;
    ctx.fm.font.math_constants = &constants;

    var scripts = try ctx.render("x^{y^2}", .display, size_pt, null);
    defer scripts.deinit();
    try testing.expectApproxEqAbs(size_pt * 0.6, scripts.items.items[1].text.size, 0.001);
    try testing.expectApproxEqAbs(size_pt * 0.4, scripts.items.items[2].text.size, 0.001);

    const src = "\\frac{a}{b}";
    var fraction = try ctx.render(src, .display, size_pt, null);
    defer fraction.deinit();
    var bar: ?ztex.draw.Rect = null;
    var baselines = [_]?f32{ null, null };
    for (fraction.items.items) |d| {
        switch (d) {
            .rect => |r| bar = r,
            .text => |t| {
                const bytes = src[t.src_start..t.src_end];
                if (std.mem.eql(u8, bytes, "a")) baselines[0] = t.y;
                if (std.mem.eql(u8, bytes, "b")) baselines[1] = t.y;
            },
            .line => return error.TestUnexpectedResult,
        }
    }
    const rule = bar orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(size_pt * constants.fraction_rule_thickness, rule.h, 0.001);
    var numerator = try ctx.render("a", .text, size_pt, null);
    defer numerator.deinit();
    var denominator = try ctx.render("b", .text, size_pt, null);
    defer denominator.deinit();
    const num_y = baselines[0] orelse return error.TestUnexpectedResult;
    const den_y = baselines[1] orelse return error.TestUnexpectedResult;
    const num_bounds = numerator.bounds();
    const num_bottom = num_y + num_bounds.depth;
    try testing.expect(rule.y - num_bottom >= size_pt * 0.8 - 0.01);
    try testing.expect(den_y + denominator.bounds().min_y - rule.y - rule.h >= size_pt * 0.8 - 0.01);
}

test "integration: scoped frame paint overrides host ink in RGBA and alpha masks" {
    var ctx = try ztex.Context.init(testing.allocator);
    defer ctx.deinit();
    const cases = .{
        .{ "\\boxed{x}", [4]u8{ 0, 0, 255, 255 } },
        .{ "\\textcolor{black}{\\boxed{x}}", [4]u8{ 0, 0, 0, 255 } },
        .{ "\\textcolor{#ff000080}{\\boxed{x}}", [4]u8{ 255, 0, 0, 128 } },
        .{ "\\textcolor{transparent}{\\boxed{x}}", [4]u8{ 0, 0, 0, 0 } },
    };
    inline for (cases) |c| {
        var out = try ctx.render(c[0], .display, size_pt, null);
        defer out.deinit();
        var top: ?ztex.draw.Rect = null;
        for (out.items.items) |d| {
            if (d == .rect and d.rect.w > d.rect.h) {
                if (top == null or d.rect.y < top.?.y) top = d.rect;
            }
        }
        const rule = top orelse return error.TestUnexpectedResult;
        const bounds = out.bounds();
        // At five pixels per point the 0.4pt frame has a fully covered
        // interior pixel, so this checks paint precedence, not edge coverage.
        const x: usize = @intFromFloat(@floor(4 + (rule.x + rule.w / 2 - bounds.min_x) * 5));
        const y: usize = @intFromFloat(@floor(4 + (rule.y + rule.h / 2 - bounds.min_y) * 5));
        for ([_]ztex.raster.Format{ .rgba32, .alpha8 }) |format| {
            var pixels = try ztex.raster.rasterize(testing.allocator, &ctx, &out, .{
                .dpi = 360,
                .padding = 4,
                .format = format,
                .fg = .{ .r = 0, .g = 0, .b = 255 },
            });
            defer pixels.deinit();
            if (format == .rgba32) {
                const offset = y * pixels.stride + x * 4;
                const expected = c[1];
                try testing.expectEqualSlices(u8, &expected, pixels.pixels[offset .. offset + 4]);
            } else {
                try testing.expectEqual(c[1][3], pixels.pixels[y * pixels.stride + x]);
            }
        }
    }
}

test "integration: a color declaration does not change relation spacing" {
    var plain = try ztex.render(testing.allocator, "a=b", .display, size_pt, null);
    defer plain.deinit();
    var colored = try ztex.render(testing.allocator, "\\color{red}a=b", .display, size_pt, null);
    defer colored.deinit();
    try testing.expectApproxEqAbs(plain.width, colored.width, 0.001);
}

test "integration: smash suppresses vertical metrics but preserves visible ink" {
    var plain = try ztex.render(testing.allocator, "b", .display, size_pt, null);
    defer plain.deinit();
    var smashed = try ztex.render(testing.allocator, "\\smash{b}", .display, size_pt, null);
    defer smashed.deinit();
    try testing.expectApproxEqAbs(plain.width, smashed.width, 0.001);
    try testing.expectEqual(@as(f32, 0), smashed.height);
    try testing.expectEqual(@as(f32, 0), smashed.depth);
    try testing.expectEqual(@as(usize, 1), smashed.items.items.len);
    try testing.expectEqualStrings(plain.items.items[0].text.bytes, smashed.items.items[0].text.bytes);
    const before = plain.bounds();
    const after = smashed.bounds();
    try testing.expectApproxEqAbs(before.min_y, after.min_y, 0.001);
    try testing.expectApproxEqAbs(before.depth, after.depth, 0.001);
}

test "integration: tag draws a roman parenthesized equation number" {
    const src = "x=1\\tag{3}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    const expected = [_][]const u8{ "(", "3", ")" };
    try testing.expect(out.items.items.len >= expected.len);
    const number = out.items.items[out.items.items.len - expected.len ..];
    for (number, expected, 0..) |d, bytes, i| {
        const t = d.text;
        try testing.expectEqualStrings(bytes, t.bytes);
        try testing.expectEqual(ztex.atom.CharStyle.roman, t.style);
        if (i != 1) {
            try testing.expectEqualStrings("\\tag{3}", src[t.src_start..t.src_end]);
        }
    }
}

test "integration: a color declaration ends at its environment cell" {
    const src = "\\begin{matrix}\\color{red}a&b\\\\c&d\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var glyph: usize = 0;
    for (out.items.items) |d| {
        if (d != .text) continue;
        const text = d.text;
        const expected: ztex.atom.Color = if (glyph == 0)
            .{ .r = 255, .g = 0, .b = 0 }
        else
            .{ .r = 0, .g = 0, .b = 0 };
        try testing.expectEqual(expected, text.color);
        glyph += 1;
    }
    try testing.expectEqual(@as(usize, 4), glyph);
}

fn twoRowGap(out: *const ztex.draw.DrawList) !f32 {
    var first: ?f32 = null;
    for (out.items.items) |d| {
        if (d != .text) continue;
        if (first) |y| return d.text.y - y;
        first = d.text.y;
    }
    return error.TestUnexpectedResult;
}

/// The x of the first glyph whose source window is exactly `bytes` — where a
/// cell's width measurement becomes visible to the caller.
fn glyphX(out: *const ztex.draw.DrawList, src: []const u8, bytes: []const u8) !f32 {
    for (out.items.items) |d| {
        if (d != .text) continue;
        const t = d.text;
        if (std.mem.eql(u8, src[t.src_start..t.src_end], bytes)) return t.x;
    }
    return error.TestUnexpectedResult;
}

/// The horizontal distance between two glyphs located by what the source
/// wrote — a cell's width measurement as the caller sees it.
fn glyphSpan(
    out: *const ztex.draw.DrawList,
    src: []const u8,
    from: []const u8,
    to: []const u8,
) !f32 {
    return (try glyphX(out, src, to)) - (try glyphX(out, src, from));
}

/// The baseline distance between the first two glyphs whose source window is
/// exactly `bytes` — the row pitch of a two-row environment, located by what
/// the source wrote rather than by emission order.
fn glyphRowGap(out: *const ztex.draw.DrawList, src: []const u8, bytes: []const u8) !f32 {
    var first: ?f32 = null;
    for (out.items.items) |d| {
        if (d != .text) continue;
        const t = d.text;
        if (!std.mem.eql(u8, src[t.src_start..t.src_end], bytes)) continue;
        if (first) |y| return t.y - y;
        first = t.y;
    }
    return error.TestUnexpectedResult;
}

test "integration: arraystretch ends at its group" {
    const plain_src = "\\begin{matrix}x\\\\x\\end{matrix}";
    const stretched_src = "\\arraystretch{2}" ++ plain_src;
    const grouped_src = "{" ++ stretched_src ++ "}" ++ plain_src;
    var plain = try ztex.render(testing.allocator, plain_src, .display, size_pt, null);
    defer plain.deinit();
    var stretched = try ztex.render(testing.allocator, stretched_src, .display, size_pt, null);
    defer stretched.deinit();
    var grouped = try ztex.render(testing.allocator, grouped_src, .display, size_pt, null);
    defer grouped.deinit();
    var baselines: [4]f32 = undefined;
    var glyph: usize = 0;
    for (grouped.items.items) |d| {
        if (d != .text) continue;
        try testing.expect(glyph < baselines.len);
        baselines[glyph] = d.text.y;
        glyph += 1;
    }
    try testing.expectEqual(baselines.len, glyph);
    try testing.expectApproxEqAbs(try twoRowGap(&stretched), baselines[1] - baselines[0], 0.001);
    try testing.expectApproxEqAbs(try twoRowGap(&plain), baselines[3] - baselines[2], 0.001);
}

test "integration: a nested matrix rule spans its alignment including outer pads" {
    const src = "\\begin{matrix}a&\\begin{matrix}x\\\\\\hline x\\end{matrix}\\\\d\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var rule: ?ztex.draw.Rect = null;
    var inner: [2]ztex.draw.Text = undefined;
    var glyph: usize = 0;
    for (out.items.items) |d| {
        switch (d) {
            .rect => |r| {
                try testing.expect(rule == null);
                rule = r;
            },
            .text => |t| {
                if (!std.mem.eql(u8, src[t.src_start..t.src_end], "x")) continue;
                try testing.expect(glyph < inner.len);
                inner[glyph] = t;
                glyph += 1;
            },
            .line => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(inner.len, glyph);
    const r = rule orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(inner[0].x - 5.0, r.x, 0.001);
    try testing.expectApproxEqAbs(inner[1].x - 5.0, r.x, 0.001);
    try testing.expect(inner[0].y < r.y);
    try testing.expect(inner[1].y > r.y + r.h);
    var plain = try ztex.render(testing.allocator, "x", .display, size_pt, null);
    defer plain.deinit();
    try testing.expectApproxEqAbs(plain.width + 10.0, r.w, 0.001);
}

// A color scope paints the atoms under it and changes no geometry, so the
// cell it ends in measures exactly what the plain cell measures — including
// the italic correction the column appends after its last character. The
// distance to the NEXT column's glyph is that measurement made visible: at
// 20pt the plain `f & Q` holds 21.6pt, and a scope over the `f` must not
// drop it to 19.8pt.
test "integration: a color scope keeps the italic correction of the cell's last character" {
    const plain_src = "\\begin{matrix}f&Q\\end{matrix}";
    const declared_src = "\\begin{matrix}\\color{red}f&Q\\end{matrix}";
    const grouped_src = "\\begin{matrix}\\textcolor{red}{f}&Q\\end{matrix}";
    const bare_src = "\\begin{matrix}f{}&Q\\end{matrix}";
    var plain = try ztex.render(testing.allocator, plain_src, .display, size_pt, null);
    defer plain.deinit();
    const corrected = try glyphSpan(&plain, plain_src, "f", "Q");
    for ([_][]const u8{ declared_src, grouped_src }) |src| {
        var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
        defer out.deinit();
        try testing.expectApproxEqAbs(corrected, try glyphSpan(&out, src, "f", "Q"), 0.001);
    }
    // The correction is part of that measurement and not merely equal between
    // the plain and the colored render: `f{}` is the same cell content and
    // the same advance with no character left to correct, so its next column
    // sits nearer than the corrected one.
    var bare = try ztex.render(testing.allocator, bare_src, .display, size_pt, null);
    defer bare.deinit();
    try testing.expect(corrected > try glyphSpan(&bare, bare_src, "f", "Q"));
}

// An `\arraystretch` written inside an environment body is a declaration the
// body reads and hands back: it sizes the environment it was written in and
// no other. The environment after it keeps the default row pitch.
test "integration: an arraystretch assigned inside a cell stops at its environment" {
    const plain_src = "\\begin{matrix}c\\\\c\\end{matrix}";
    const src = "\\begin{matrix}\\arraystretch{2}a\\\\a\\end{matrix}" ++ plain_src;
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var plain = try ztex.render(testing.allocator, plain_src, .display, size_pt, null);
    defer plain.deinit();
    const assigned = try glyphRowGap(&out, src, "a");
    const following = try glyphRowGap(&out, src, "c");
    // The assignment reaches the environment it was written in: its rows sit
    // at twice the default distance.
    try testing.expect(assigned > following);
    // The next environment reads the default factor, exactly as the same
    // environment does on its own.
    try testing.expectApproxEqAbs(try glyphRowGap(&plain, plain_src, "c"), following, 0.001);
}

// The same scope in the other direction: an override inside a NESTED
// environment sizes that nested environment, and the factor the outer body
// started with is what the environment after it reads.
test "integration: an outer arraystretch survives an override in a nested environment" {
    const src = "\\arraystretch{2}\\begin{matrix}a\\\\a\\end{matrix}" ++
        "\\begin{matrix}b\\\\\\arraystretch{0.5}\\begin{matrix}c\\\\c\\end{matrix}\\end{matrix}" ++
        "\\begin{matrix}d\\\\d\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    const outer = try glyphRowGap(&out, src, "a");
    const nested = try glyphRowGap(&out, src, "c");
    const restored = try glyphRowGap(&out, src, "d");
    // The override sizes the nested environment only ...
    try testing.expect(nested < outer);
    // ... and the outer factor is what the environment after it reads.
    try testing.expectApproxEqAbs(outer, restored, 0.001);
}

// A frame follows the INK, not the box that measured it. At a size inside
// the LMRoman17 optical band a `\text` glyph is boxed by that band's optical
// advance, which is narrower than the advance of the 10pt design the ink is
// measured on, and both metric sources paint the SAME `f` hook. So the
// static frame has to reach exactly as far as the embedded face's frame, and
// both have to reach past the advance box that frames the glyph otherwise.
test "integration: the static frame reaches the ink a narrower optical advance would clip" {
    const src = "\\text{f}";
    var ctx = try ztex.Context.init(testing.allocator);
    defer ctx.deinit();
    var static = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer static.deinit();
    var fonted = try ctx.render(src, .display, size_pt, null);
    defer fonted.deinit();
    const framed = static.bounds().min_x + static.bounds().width;
    try testing.expectApproxEqAbs(
        fonted.bounds().min_x + fonted.bounds().width,
        framed,
        0.01,
    );
    try testing.expect(framed > static.width);
}

// An `\arraystretch` written in a cell belongs to that cell. It still sizes
// the environment it was written in — that is the first row, and one
// environment's rows share its strut — but the rows and cells after it read
// the outer factor again, including the nested environment one of them
// opens: the nested rows here keep the default pitch while the outer rows
// open up to twice it.
test "integration: a cell's arraystretch does not reach the rows and cells after it" {
    const src = "\\begin{matrix}\\arraystretch{2}x\\\\" ++
        "\\begin{matrix}b\\\\b\\end{matrix}\\\\x\\end{matrix}";
    const plain_outer = "\\begin{matrix}x\\\\\\begin{matrix}b\\\\b\\end{matrix}\\\\x\\end{matrix}";
    const plain_nested = "\\begin{matrix}b\\\\b\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var outer = try ztex.render(testing.allocator, plain_outer, .display, size_pt, null);
    defer outer.deinit();
    var nested = try ztex.render(testing.allocator, plain_nested, .display, size_pt, null);
    defer nested.deinit();
    // The outer rows (the `x` cells) open up ...
    try testing.expect(
        (try glyphRowGap(&out, src, "x")) > (try glyphRowGap(&outer, plain_outer, "x")),
    );
    // ... and the nested environment in the NEXT row keeps the default pitch.
    try testing.expectApproxEqAbs(
        try glyphRowGap(&nested, plain_nested, "b"),
        try glyphRowGap(&out, src, "b"),
        0.001,
    );
}

// `\left … \right` bounds its interior the way a group does, so a factor
// written between the delimiters ends with the pair: the environment inside
// it is stretched, and the environment that follows reads the default.
test "integration: an arraystretch inside a left-right pair ends with the pair" {
    const plain_src = "\\begin{matrix}c\\\\c\\end{matrix}";
    const src = "\\left(\\arraystretch{2}\\begin{matrix}a\\\\a\\end{matrix}\\right)" ++ plain_src;
    const stretched_src = "\\arraystretch{2}\\begin{matrix}a\\\\a\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var stretched = try ztex.render(testing.allocator, stretched_src, .display, size_pt, null);
    defer stretched.deinit();
    var plain = try ztex.render(testing.allocator, plain_src, .display, size_pt, null);
    defer plain.deinit();
    try testing.expectApproxEqAbs(
        try glyphRowGap(&stretched, stretched_src, "a"),
        try glyphRowGap(&out, src, "a"),
        0.001,
    );
    try testing.expectApproxEqAbs(
        try glyphRowGap(&plain, plain_src, "c"),
        try glyphRowGap(&out, src, "c"),
        0.001,
    );
}

// The cells of the first row decide this environment's strut together: a
// cell that only INHERITS a factor changes nothing, so the plain cells after
// the assigning one still stand at the doubled pitch.
test "integration: a first-row assignment survives the plain cells after it" {
    const src = "\\begin{matrix}\\arraystretch{2}x&y\\\\x&z\\end{matrix}";
    const stretched_src = "\\arraystretch{2}\\begin{matrix}x&y\\\\x&z\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var stretched = try ztex.render(testing.allocator, stretched_src, .display, size_pt, null);
    defer stretched.deinit();
    try testing.expectApproxEqAbs(
        try glyphRowGap(&stretched, stretched_src, "x"),
        try glyphRowGap(&out, src, "x"),
        0.001,
    );
}

// A second assignment in the first row REPLACES the first one — the last one
// written is the factor the environment's rows are built from, here back to
// the default the plain matrix has.
test "integration: the last first-row assignment wins" {
    const src = "\\begin{matrix}\\arraystretch{2}x&\\arraystretch{1}y\\\\x&z\\end{matrix}";
    const plain_src = "\\begin{matrix}x&y\\\\x&z\\end{matrix}";
    const stretched_src = "\\arraystretch{2}\\begin{matrix}x&y\\\\x&z\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var plain = try ztex.render(testing.allocator, plain_src, .display, size_pt, null);
    defer plain.deinit();
    var stretched = try ztex.render(testing.allocator, stretched_src, .display, size_pt, null);
    defer stretched.deinit();
    try testing.expectApproxEqAbs(
        try glyphRowGap(&plain, plain_src, "x"),
        try glyphRowGap(&out, src, "x"),
        0.001,
    );
    try testing.expect(
        (try glyphRowGap(&out, src, "x")) < (try glyphRowGap(&stretched, stretched_src, "x")),
    );
}

// A nested environment in a LATER cell reads the factor the body opened
// with: the first cell's assignment sized the rows around it (the `x` cells)
// and stops there, so the nested rows keep the default pitch.
test "integration: a nested environment in a later cell reads the outer factor" {
    const nested = "\\begin{matrix}y\\\\y\\end{matrix}";
    const src = "\\begin{matrix}\\arraystretch{2}x&" ++ nested ++ "\\\\x&z\\end{matrix}";
    const stretched_src = "\\arraystretch{2}\\begin{matrix}x&{\\arraystretch{1}" ++
        nested ++ "}\\\\x&z\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var stretched = try ztex.render(testing.allocator, stretched_src, .display, size_pt, null);
    defer stretched.deinit();
    var plain = try ztex.render(testing.allocator, nested, .display, size_pt, null);
    defer plain.deinit();
    try testing.expectApproxEqAbs(
        try glyphRowGap(&stretched, stretched_src, "x"),
        try glyphRowGap(&out, src, "x"),
        0.001,
    );
    try testing.expectApproxEqAbs(
        try glyphRowGap(&plain, nested, "y"),
        try glyphRowGap(&out, src, "y"),
        0.001,
    );
}

// An assignment the parser meets inside a NESTED environment is that
// environment's own: the enclosing cell did not make it, so the enclosing
// rows keep the default pitch while the nested rows carry the factor.
test "integration: a nested environment's assignment is not the enclosing cell's" {
    const nested = "\\begin{matrix}y\\\\y\\end{matrix}";
    const src = "\\begin{matrix}\\begin{matrix}\\arraystretch{2}y\\\\y\\end{matrix}" ++
        "&z\\\\z&w\\end{matrix}";
    const plain_src = "\\begin{matrix}{\\arraystretch{2}" ++ nested ++
        "}&z\\\\z&w\\end{matrix}";
    const stretched_nested = "\\arraystretch{2}" ++ nested;
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var plain = try ztex.render(testing.allocator, plain_src, .display, size_pt, null);
    defer plain.deinit();
    var stretched = try ztex.render(testing.allocator, stretched_nested, .display, size_pt, null);
    defer stretched.deinit();
    // The enclosing rows are the default ones ...
    try testing.expectApproxEqAbs(
        try glyphRowGap(&plain, plain_src, "z"),
        try glyphRowGap(&out, src, "z"),
        0.001,
    );
    // ... and the nested rows are the stretched ones.
    try testing.expectApproxEqAbs(
        try glyphRowGap(&stretched, stretched_nested, "y"),
        try glyphRowGap(&out, src, "y"),
        0.001,
    );
}

// A `\def` inside a GROUP is local to it, so it neither reaches the enclosing
// cell's factor nor the environment's rows — the same rule that ends a
// factor at the closing brace of any group.
test "integration: a group's assignment is not the enclosing cell's" {
    const src = "\\begin{matrix}{\\arraystretch{2}}x&y\\\\x&z\\end{matrix}";
    const plain_src = "\\begin{matrix}x&y\\\\x&z\\end{matrix}";
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var plain = try ztex.render(testing.allocator, plain_src, .display, size_pt, null);
    defer plain.deinit();
    try testing.expectApproxEqAbs(
        try glyphRowGap(&plain, plain_src, "x"),
        try glyphRowGap(&out, src, "x"),
        0.001,
    );
}

test "integration: a nested body preserves its enclosing cell's stretch assignment" {
    const body = "\\begin{matrix}x\\begin{matrix}y\\end{matrix}\\\\x\\end{matrix}";
    const src = "\\arraystretch{3}\\begin{matrix}\\arraystretch{2}x" ++
        "\\begin{matrix}y\\end{matrix}\\\\x\\end{matrix}";
    const ref_src = "\\arraystretch{2}" ++ body;
    var out = try ztex.render(testing.allocator, src, .display, size_pt, null);
    defer out.deinit();
    var reference = try ztex.render(testing.allocator, ref_src, .display, size_pt, null);
    defer reference.deinit();
    try testing.expectApproxEqAbs(
        try glyphRowGap(&reference, ref_src, "x"),
        try glyphRowGap(&out, src, "x"),
        0.001,
    );
}

fn maskInkWidth(mask: *const ztex.PixelBuffer) u32 {
    var left = mask.width;
    var right: u32 = 0;
    for (0..mask.height) |y| {
        for (0..mask.width) |x| {
            if (mask.pixels[y * mask.stride + x] < 128) continue;
            left = @min(left, @as(u32, @intCast(x)));
            right = @max(right, @as(u32, @intCast(x)));
        }
    }
    return if (left <= right) right - left + 1 else 0;
}

test "integration: sans math paints a distinct sans-serif capital I" {
    var ctx = try ztex.Context.init(testing.allocator);
    defer ctx.deinit();
    const opts: ztex.RasterOptions = .{ .dpi = 192, .format = .alpha8 };
    var serif = try ctx.renderPixels("\\mathrm{I}", .text, 40, opts, null);
    defer serif.deinit();
    var sans = try ctx.renderPixels("\\mathsf{I}", .text, 40, opts, null);
    defer sans.deinit();
    try testing.expect(maskInkWidth(&sans) < maskInkWidth(&serif));
}

test "integration: monospace math preserves equal character advances at every size" {
    var ctx = try ztex.Context.init(testing.allocator);
    defer ctx.deinit();
    for ([_]f32{ 8, 20, 60 }) |size| {
        var static = try ztex.render(testing.allocator, "\\mathtt{AIW012}", .text, size, null);
        defer static.deinit();
        var real = try ctx.render("\\mathtt{AIW012}", .text, size, null);
        defer real.deinit();
        for ([_]*const ztex.draw.DrawList{ &static, &real }) |list| {
            var previous: ?f32 = null;
            var advance: ?f32 = null;
            for (list.items.items) |item| {
                if (item != .text) continue;
                if (previous) |x| {
                    const distance = item.text.x - x;
                    if (advance) |expected|
                        try testing.expectApproxEqAbs(expected, distance, 0.001)
                    else
                        advance = distance;
                }
                previous = item.text.x;
            }
        }
    }
}

test "text faces fall back to the same real math Greek outline" {
    var ctx = try ztex.Context.init(testing.allocator);
    defer ctx.deinit();
    const opts: ztex.RasterOptions = .{ .dpi = 192, .padding = 2, .format = .alpha8 };
    var reference = try ctx.renderPixels("\\mathsf{\\alpha}", .display, 40, opts, null);
    defer reference.deinit();
    for ([_][]const u8{
        "\\mathrm{\\alpha}",
        "\\text{α}",
        "\\textit{α}",
        "\\textbf{α}",
        "\\textit{\\textbf{α}}",
    }) |source| {
        var pixels = try ctx.renderPixels(source, .display, 40, opts, null);
        defer pixels.deinit();
        try testing.expectEqual(reference.width, pixels.width);
        try testing.expectEqual(reference.height, pixels.height);
        try testing.expectEqualSlices(u8, reference.pixels, pixels.pixels);
    }
}

test "amsmath colon keeps two mu before and six mu after in every style" {
    var ctx = try ztex.Context.init(testing.allocator);
    defer ctx.deinit();
    for ([_]ztex.layout.Style{ .display, .text, .script, .script_script }) |style| {
        for ([_]bool{ false, true }) |font_backed| {
            var plain = if (font_backed)
                try ctx.render("0\\mathord{:}0", style, 20, null)
            else
                try ztex.render(testing.allocator, "0\\mathord{:}0", style, 20, null);
            defer plain.deinit();
            var spaced = if (font_backed)
                try ctx.render("0\\colon0", style, 20, null)
            else
                try ztex.render(testing.allocator, "0\\colon0", style, 20, null);
            defer spaced.deinit();
            var reference: [3]ztex.draw.Text = undefined;
            var actual: [3]ztex.draw.Text = undefined;
            var ri: usize = 0;
            var ai: usize = 0;
            for (plain.items.items) |item| if (item == .text) {
                try testing.expect(ri < reference.len);
                reference[ri] = item.text;
                ri += 1;
            };
            for (spaced.items.items) |item| if (item == .text) {
                try testing.expect(ai < actual.len);
                actual[ai] = item.text;
                ai += 1;
            };
            try testing.expectEqual(reference.len, ri);
            try testing.expectEqual(actual.len, ai);
            const mu = reference[0].size / 18;
            try testing.expectApproxEqAbs(reference[0].x, actual[0].x, 0.01);
            try testing.expectApproxEqAbs(reference[1].x + 2 * mu, actual[1].x, 0.01);
            try testing.expectApproxEqAbs(reference[2].x + 8 * mu, actual[2].x, 0.01);
        }
    }
}

test "integration: a cases radical inherits its cell's text style" {
    var context = try ztex.Context.init(testing.allocator);
    defer context.deinit();
    const source = "\\begin{cases}\\frac{\\frac{a}{b}}{\\frac{c}{d}} & x\\neq 0\\\\" ++
        "\\sqrt{\\frac{a}{b}} & x=0\\end{cases}";
    for ([_]bool{ false, true }) |real| {
        var dl = if (real)
            try context.render(source, .display, 20, null)
        else
            try ztex.render(testing.allocator, source, .display, 20, null);
        defer dl.deinit();
        // The exact-font reference's cases block is 60.75pt tall.
        // An oversized 36pt radical raises the same block to 69.32pt.
        const bounds = dl.bounds();
        try testing.expect(bounds.height + bounds.depth < 64);
    }
}

test "integration: horizontal braces fit the nucleus before assembling" {
    var context = try ztex.Context.init(testing.allocator);
    defer context.deinit();
    for ([_]bool{ false, true }) |real| {
        for ([_]ztex.layout.Style{ .display, .text }) |style| {
            for ([_]f32{ 8, 20, 60 }) |size| {
                for ([_]struct { base: []const u8, braced: []const u8 }{
                    .{ .base = "a+b", .braced = "\\overbrace{a+b}" },
                    .{ .base = "\\frac{a}{b}", .braced = "\\underbrace{\\frac{a}{b}}" },
                }) |source| {
                    var base = if (real)
                        try context.render(source.base, style, size, null)
                    else
                        try ztex.render(testing.allocator, source.base, style, size, null);
                    defer base.deinit();
                    var braced = if (real)
                        try context.render(source.braced, style, size, null)
                    else
                        try ztex.render(testing.allocator, source.braced, style, size, null);
                    defer braced.deinit();
                    // Preserve the nucleus's real ink overhang. A nucleus
                    // narrower than the 0.492em base brace keeps that glyph.
                    const limit = @max(base.bounds().width, 0.5 * size);
                    try testing.expect(braced.bounds().width <= limit + 0.02 * size);
                }
            }
        }
    }
}

test "integration: colon-equals relations retain dot count and orientation" {
    for ([_]struct { source: []const u8, bands: usize }{
        .{ .source = "\\coloneq", .bands = 2 },
        .{ .source = "\\Coloneqq", .bands = 3 },
        .{ .source = "\\Coloneqqs", .bands = 3 },
    }) |relation| {
        var pixels = try ztex.renderPixels(testing.allocator, relation.source, .display, 20, .{
            .dpi = 300,
            .padding = 2,
            .format = .alpha8,
        }, null);
        defer pixels.deinit();
        var first_width: usize = 0;
        var last_width: usize = 0;
        var count: usize = 0;
        var previous = false;
        for (0..pixels.width) |column| {
            var ink = false;
            for (0..pixels.height) |row| {
                if (pixels.pixels[row * pixels.stride + column] > 127) {
                    ink = true;
                    break;
                }
            }
            if (ink) {
                if (!previous) {
                    count += 1;
                    last_width = 0;
                }
                if (count == 1) first_width += 1;
                last_width += 1;
            }
            previous = ink;
        }
        try testing.expectEqual(relation.bands, count);
        // Colon dots form narrow columns; the equals bars are on the right.
        try testing.expect(first_width < last_width);
    }
}

test "integration: braces and forced limits keep their measured ink gaps" {
    var context = try ztex.Context.init(testing.allocator);
    defer context.deinit();
    // Exact-font XeTeX: the overbrace tips clear a+b; the upper annotation gap
    // is 0.20em, and a lower n clears the band by about 0.29em at script size.
    for ([_]struct {
        source: []const u8,
        bands: usize,
        min_gap: f32,
        max_gap: f32,
    }{
        .{ .source = "\\overbrace{a+b}", .bands = 2, .min_gap = 0.04, .max_gap = 0.12 },
        .{ .source = "\\overbrace{a+b}^{n}", .bands = 3, .min_gap = 0.04, .max_gap = 0.12 },
        .{
            .source = "\\underbrace{\\frac{a}{b}}_{n}",
            .bands = 5,
            .min_gap = 0.26,
            .max_gap = 0.34,
        },
        .{ .source = "\\overset{n}{a+b}", .bands = 2, .min_gap = 0.17, .max_gap = 0.24 },
        .{
            .source = "\\underset{n}{\\frac{a}{b}}",
            .bands = 4,
            .min_gap = 0.26,
            .max_gap = 0.34,
        },
    }) |case| {
        for ([_]bool{ false, true }) |real| {
            var list = if (real)
                try context.render(case.source, .display, 20, null)
            else
                try ztex.render(testing.allocator, case.source, .display, 20, null);
            defer list.deinit();
            var pixels = try ztex.raster.rasterize(
                testing.allocator,
                &context,
                &list,
                .{ .dpi = 192, .padding = 0, .format = .alpha8 },
            );
            defer pixels.deinit();
            var bands: usize = 0;
            var last_start: usize = 0;
            var previous_end: usize = 0;
            var end: usize = 0;
            var previous = false;
            for (0..pixels.height) |row| {
                var ink = false;
                for (0..pixels.width) |column| {
                    if (pixels.pixels[row * pixels.stride + column] > 127) {
                        ink = true;
                        break;
                    }
                }
                if (ink) {
                    if (!previous) {
                        bands += 1;
                        last_start = row;
                        previous_end = end;
                    }
                    end = row;
                }
                previous = ink;
            }
            try testing.expectEqual(case.bands, bands);
            const gap = @as(f32, @floatFromInt(last_start - previous_end - 1)) / (20 * 192 / 72);
            try testing.expect(gap >= case.min_gap);
            try testing.expect(gap <= case.max_gap);
        }
    }
}

test "integration: indexed radicals retain the measured degree kern width" {
    var context = try ztex.Context.init(testing.allocator);
    defer context.deinit();
    const source = "\\sqrt[3]{x+y} + \\sqrt[n]{\\frac{1}{x}}";
    for ([_]bool{ false, true }) |real| {
        var list = if (real)
            try context.render(source, .display, 20, null)
        else
            try ztex.render(testing.allocator, source, .display, 20, null);
        defer list.deinit();
        // LuaLaTeX's 121.07pt box brackets the index with size-scaled MATH
        // kerns and rides it on the radical's shoulder; XeTeX's 126.65pt
        // box hangs it off the ink with 10pt-based kerns. Ink framing
        // trims the empty shoulder, so compare the advance.
        try testing.expect(list.width > 119);
        try testing.expect(list.width < 123);
    }
}

test "integration: deeply nested radical assemblies do not add quantization gaps" {
    var context = try ztex.Context.init(testing.allocator);
    defer context.deinit();
    const source = "\\sqrt{1+\\sqrt{1+\\sqrt{1+\\sqrt{1+\\sqrt{1+\\sqrt{1+x}}}}}}";
    for ([_]bool{ false, true }) |real| {
        var list = if (real)
            try context.render(source, .display, 20, null)
        else
            try ztex.render(testing.allocator, source, .display, 20, null);
        defer list.deinit();
        // Exact-font XeTeX's 69.92pt box includes 0.8pt of empty top kern.
        // Its ink is 69.12pt; fixed overlap inflated ztex's ink to 74.4pt.
        const bounds = list.bounds();
        try testing.expect(bounds.height + bounds.depth > 69);
        try testing.expect(bounds.height + bounds.depth < 71);
    }
}

test "integration: translucent radicals paint each connector once" {
    var context = try ztex.Context.init(testing.allocator);
    defer context.deinit();
    const sources = [_][]const u8{
        "\\textcolor{#00000080}{\\sqrt{x}}",
        "\\textcolor{#00000080}{\\sqrt{\\begin{matrix}x\\\\x\\\\x\\\\x\\\\x\\end{matrix}}}",
    };
    for (sources) |source| {
        for ([_]bool{ false, true }) |real| {
            var list = if (real)
                try context.render(source, .display, 20, null)
            else
                try ztex.render(testing.allocator, source, .display, 20, null);
            defer list.deinit();
            for ([_]ztex.raster.Format{ .rgba32, .alpha8 }) |format| {
                var pixels = try ztex.raster.rasterize(testing.allocator, &context, &list, .{
                    .dpi = 192,
                    .format = format,
                    .bg = null,
                });
                defer pixels.deinit();
                const step: usize = if (format == .rgba32) 4 else 1;
                var at: usize = if (format == .rgba32) 3 else 0;
                var maximum: u8 = 0;
                while (at < pixels.pixels.len) : (at += step) {
                    const alpha = pixels.pixels[at];
                    try testing.expect(alpha <= 128);
                    maximum = @max(maximum, alpha);
                }
                try testing.expectEqual(@as(u8, 128), maximum);
            }
        }
    }
}

test "integration: a narrow radical nucleus preserves the glyph's connecting cap" {
    var context = try ztex.Context.init(testing.allocator);
    defer context.deinit();
    for ([_]bool{ false, true }) |real| {
        var empty = if (real)
            try context.render("\\sqrt{}", .display, 20, null)
        else
            try ztex.render(testing.allocator, "\\sqrt{}", .display, 20, null);
        defer empty.deinit();
        var narrow = if (real)
            try context.render("\\sqrt{\\hspace{0.01pt}}", .display, 20, null)
        else
            try ztex.render(testing.allocator, "\\sqrt{\\hspace{0.01pt}}", .display, 20, null);
        defer narrow.deinit();
        const options: ztex.raster.Options = .{ .dpi = 192, .format = .alpha8, .bg = null };
        var a = try ztex.raster.rasterize(testing.allocator, &context, &empty, options);
        defer a.deinit();
        var b = try ztex.raster.rasterize(testing.allocator, &context, &narrow, options);
        defer b.deinit();
        try testing.expectEqual(a.width, b.width);
        try testing.expectEqual(a.height, b.height);
        for (a.pixels, b.pixels) |left, right| {
            try testing.expect(@as(u16, right) + 1 >= left);
        }
    }
}
