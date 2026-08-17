// ztex.tests.sanity_cfrac — TDD regression for the \cfrac numerator gap.
//
// Bug: \cfrac rendered the numerator '1' too close to the fraction rule
// above it — ~1.9pt short on a single cfrac, compounding ~7.5pt over a
// nested continuation. Root cause: amsmath defines
//   \cfrac = {\displaystyle\frac{\strut #2}{#3}}
// i.e. the NUMERATOR is `\strut #2` — an invisible display-size strut that
// carries DEPTH (0.36em of the effective size) below the numerator
// baseline. That depth enters TeX make_fraction's clearance check
//   kern1 = num1 − numerator_depth − (axis + rt/2) ≥ 3·rt
// so with the strut's depth present the check trips and bumps the numerator
// up ~2.2pt (XeTeX: \cfrac{1}{a} numerator-to-rule gap ≈ 14.6pt vs the
// strut-less 12.75pt). ztex laid out the bare numerator (depth 0), so the
// gap came out ~1.9pt short per level.
//
// Fix (in this test's expectation): a \cfrac numerator is boxed at least as
// deep as the display strut, so the clearance bump fires and the numerator
// sits higher — matching XeTeX.

const std = @import("std");
const ztex = @import("ztex");

const testing = std.testing;

test "sanity: \\cfrac numerator gap is larger than a strut-less \\frac" {
    // The cfrac numerator '1' must sit HIGHER above the fraction rule than
    // a plain display \frac{1}{a}'s numerator (the strut forces the extra
    // clearance bump). Both at 30pt display; measure the numerator-baseline
    // to rule-top distance.
    const cfrac_pt = fracBaselineToRule("\\cfrac{1}{a}", 30) orelse
        return error.NoCfracGeometry;
    const frac_pt = fracBaselineToRule("\\frac{1}{a}", 30) orelse
        return error.NoFracGeometry;

    // The cfrac numerator sits strictly higher (bigger gap) than the plain
    // display fraction's numerator because of the strut-induced bump.
    try testing.expect(cfrac_pt > frac_pt + 1.0);
}

fn fracBaselineToRule(src: []const u8, size: f32) ?f32 {
    var out = ztex.render(std.testing.allocator, src, size, null) catch return null;
    defer out.deinit();
    var one_baseline: ?f32 = null;
    var rule_top: ?f32 = null;
    for (out.items.items) |d| {
        switch (d) {
            .text => |t| {
                if (one_baseline == null and std.mem.eql(u8, t.bytes, "1"))
                    one_baseline = t.y;
            },
            .rect => |r| {
                if (r.h <= 2.0 and rule_top == null) rule_top = r.y;
            },
            .line => {},
        }
    }
    // Draw-list coords: baseline at y=0, ascent negative (y < 0 is up),
    // rule at y = r.y (a rect top edge at r.y going down). The numerator
    // baseline 'one' is negative (above axis); the rule top 'rule_top' is
    // negative (on the axis, above baseline). Gap = |one| - |rule_top|.
    const one = one_baseline orelse return null;
    const rt = rule_top orelse return null;
    return @abs(one) - @abs(rt);
}
