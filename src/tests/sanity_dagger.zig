// ztex.tests.sanity_dagger — TDD regression for the superscript-on-accent
// raise.
//
// Bug: `\hat{A}^{\dagger}` raised the dagger to ~24.75pt above the A
// baseline at 30pt (fontsize {30}{36}); XeTeX raises it to only 10.89pt
// (the sup1 floor, 3.63em). Root cause: XeTeX parses `\hat{A}^{\dagger}`
// as `\hat{A^{\dagger}}` — the hat applies OVER the scripted char, so the
// dagger's raise is the CHAR nucleus floor (sup1), not the accented box's
// height. ztex parsed it as a superscript on the whole ACCENT box, so
// layoutScript used `sup_base = base_h − supdrop` where base_h is inflated
// by the hat sitting on top (~14pt too large).
//
// Fix (in this test's expectation): the superscript (dagger) raise on an
// accent base uses the CHAR floor (sup1/sup2/sup3) like a bare-char
// nucleus, not the accent-box height. The dagger baseline then sits ~
// sup1 (3.63em) above the A baseline.

const std = @import("std");
const ztex = @import("ztex");

const testing = std.testing;

test "sanity: superscript on an accent base uses the char sup floor" {
    // \hat{A}^{\dagger} at 30pt: the dagger baseline must sit only ~sup1
    // (3.63em = 10.89pt) above the A baseline, NOT the accent-box height
    // (~25pt, inflated by the hat on top).
    var out = try ztex.render(testing.allocator, "\\hat{A}^{\\dagger}", 30, null);
    defer out.deinit();

    // Find the A baseline (the 'A' text) and the dagger († U+2020).
    var a_y: ?f32 = null;
    var dag_y: ?f32 = null;
    for (out.items.items) |d| {
        switch (d) {
            .text => |t| {
                if (std.mem.eql(u8, t.bytes, "𝐴") and a_y == null) a_y = t.y; // math-italic A
                if (std.mem.indexOf(u8, t.bytes, "†") != null) dag_y = t.y;
            },
            else => {},
        }
    }
    const a = a_y orelse return error.NoBaseA;
    const dag = dag_y orelse return error.NoDagger;

    // Draw-list coords: baseline at y=0, ascent negative (y<0 is up). The
    // dagger baseline is `dag` (negative, above the A baseline). Raise =
    // |dag| − |a|.
    const raise = @abs(dag) - @abs(a);
    // XeTeX: 10.89pt = sup1 (3.63em × 30). Accept the char-floor raise
    // (~sup1) — NOT the accent-box height (~25pt, would be >= 20).
    try testing.expect(raise < 16.0); // not the accent-inflated ~25pt
    try testing.expect(raise > 5.0); // not zero
}
