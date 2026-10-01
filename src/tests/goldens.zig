//! ztex.tests.goldens — broad golden snapshots over the feature corpus.
//!
//! Supplementary to regression.zig's small focused corpus: this module pins
//! the draw-list, SVG, and atom-tree output for a broad set of formulas
//! covering fractions (frac/dfrac/cfrac/binom), radicals (incl. degree),
//! stretchy delimiters, big operators with limits, math styles (mathbb,
//! mathcal, mathbf), accents, environments (pmatrix/cases), relations,
//! spaces, and pmod/bmod. Any internal change that shifts geometry, emits a
//! different glyph, or re-shapes the atom tree breaks a snapshot here.
//!
//! Regenerate after an intended change with `zig build gen-goldens` (the
//! tool prints ready-to-paste tables) or by capturing the probe outputs.
//!
//! The corpus (33 formulas) keeps each case focused so a regression lands on
//! the exact construct that changed.

const std = @import("std");
const regression = @import("regression.zig");

const testing = std.testing;

/// Draw-list snapshots at size_pt = 20 (see regression.dump).
pub const golden = [_]struct { src: []const u8, dump: []const u8 }{
    .{ .src = "\\frac{x^2+1}{x-1}", .dump =
    \\T:𝑥,1.2,-13.53016,20[6,7]
    \\T:2,12.959999,-20.790161,14[8,9]
    \\T:+,24.904444,-13.53016,20[9,10]
    \\T:1,44.908886,-13.53016,20[10,11]
    \\R:1.2,-5.4,53.708885,0.8[0,16]
    \\T:𝑥,5.1099977,13.71902,20[13,14]
    \\T:−,20.994442,13.71902,20[14,15]
    \\T:1,40.998886,13.71902,20[15,16]
    \\
    },
    .{ .src = "\\dfrac{a}{b}", .dump =
    \\T:𝑎,1.2,-13.53016,20[7,8]
    \\R:1.2,-5.4,10.58,0.8[0,11]
    \\T:𝑏,2.2,13.71902,20[10,11]
    \\
    },
    .{ .src = "\\cfrac{1}{a_1+\\cfrac{1}{a_2}}", .dump =
    \\T:1,27.704447,-15,20[7,8]
    \\R:1.2,-5.4,63.008892,0.8[0,27]
    \\T:𝑎,1.2,29.599998,20[10,11]
    \\T:1,11.78,34.539997,14[12,13]
    \\T:+,23.724445,29.599998,20[13,14]
    \\T:1,48.968895,14.599998,20[21,22]
    \\R:44.928894,24.199999,18.08,0.8[14,27]
    \\T:𝑎,44.928894,43.31902,20[24,25]
    \\T:2,55.508896,48.259018,14[26,27]
    \\
    },
    .{ .src = "\\binom{n}{k}", .dump =
    \\T:(,0,0,20[0,6]
    \\T:𝑛,15.92,-13.53016,20[7,8]
    \\T:𝑘,16.710001,13.71902,20[10,11]
    \\T:),29.119999,0,20[0,6]
    \\
    },
    .{ .src = "\\sqrt{a^2+b^2}", .dump =
    \\T:√,0,-3.6020012,20[0,5]
    \\T:𝑎,20,0,20[6,7]
    \\T:2,30.8,-5.78,14[8,9]
    \\T:+,42.744446,0,20[9,10]
    \\T:𝑏,62.748886,0,20[10,11]
    \\T:2,71.32889,-5.78,14[12,13]
    \\R:20,-20.602001,58.828888,0.8[0,13]
    \\
    },
    .{ .src = "\\sqrt[3]{\\frac{a}{b}}", .dump =
    \\T:√,0,-1.0955696,20[0,5]
    \\T:𝑎,21.2,-13.53016,20[15,16]
    \\R:21.2,-5.4,10.58,0.8[9,19]
    \\T:𝑏,22.2,13.71902,20[18,19]
    \\R:20,-30.09557,12.98,0.8[0,19]
    \\T:3,2,-7.7946835,10[6,7]
    \\
    },
    .{ .src = "\\left(\\frac{x+1}{x-1}\\right)", .dump =
    \\T:(,0,0,20[5,6]
    \\T:𝑥,14.46,-13.53016,20[12,13]
    \\T:+,30.344444,-13.53016,20[13,14]
    \\T:1,50.34889,-13.53016,20[14,15]
    \\R:14.46,-5.4,45.88889,0.8[6,20]
    \\T:𝑥,14.46,13.71902,20[17,18]
    \\T:−,30.344444,13.71902,20[18,19]
    \\T:1,50.34889,13.71902,20[19,20]
    \\T:),61.54889,0,20[27,28]
    \\
    },
    .{ .src = "\\left| x^2 \\right|", .dump =
    \\T:|,0,0,20[5,6]
    \\T:𝑥,5.56,0,20[7,8]
    \\T:2,17.32,-7.26,14[9,10]
    \\T:|,24.819998,0,20[17,18]
    \\
    },
    .{ .src = "\\big( a+b \\big)", .dump =
    \\T:(,0,0,20[4,5]
    \\T:𝑎,8.44,0,20[6,7]
    \\T:+,23.464445,0,20[7,8]
    \\T:𝑏,43.468887,0,20[8,9]
    \\T:),52.04889,0,20[14,15]
    \\
    },
    .{ .src = "\\left\\{ \\frac{a}{b} \\right\\}", .dump =
    \\T:{,0,0,20[5,7]
    \\T:𝑎,14.54,-13.53016,20[14,15]
    \\R:14.54,-5.4,10.58,0.8[8,18]
    \\T:𝑏,15.54,13.71902,20[17,18]
    \\T:},26.32,0,20[26,28]
    \\
    },
    .{ .src = "\\int_0^1 x^2\\,dx", .dump =
    \\T:∫,0,0,20[0,4]
    \\T:1,19.98,-23.72,14[7,8]
    \\T:0,8.16,20.019999,14[5,6]
    \\T:𝑥,30.813334,0,20[9,10]
    \\T:2,42.573334,-7.26,14[11,12]
    \\T:𝑑,53.393333,0,20[14,15]
    \\T:𝑥,64.27334,0,20[15,16]
    \\
    },
    .{ .src = "\\prod_{i=1}^{n} i", .dump =
    \\T:𝑛,8.58,-23.154,14[13,14]
    \\T:∏,0,0,20[0,5]
    \\T:𝑖,1.4189997,21.664001,14[7,8]
    \\T:=,6.2489996,21.664001,14[8,9]
    \\T:1,17.140999,21.664001,14[9,10]
    \\T:𝑖,28.893333,0,20[16,17]
    \\
    },
    .{ .src = "\\lim_{x \\to 0} \\frac{\\sin x}{x}", .dump =
    \\T:l,1.7840004,0,20[0,4]
    \\T:i,6.7840004,0,20[0,4]
    \\T:m,11.784,0,20[0,4]
    \\T:𝑥,0,12.6640005,14[6,7]
    \\T:→,8.007999,12.6640005,14[8,11]
    \\T:0,22.008,12.6640005,14[12,13]
    \\T:s,33.541332,-13.53016,20[21,25]
    \\T:i,40.721333,-13.53016,20[21,25]
    \\T:n,45.721333,-13.53016,20[21,25]
    \\T:𝑥,59.274666,-13.53016,20[26,27]
    \\R:33.541332,-5.4,37.173336,0.8[15,30]
    \\T:𝑥,46.408,13.71902,20[29,30]
    \\
    },
    .{ .src = "\\sum_{i=1}^{n} i^2", .dump =
    \\T:𝑛,10.240001,-23.154,14[12,13]
    \\T:∑,0,0,20[0,4]
    \\T:𝑖,3.0790005,21.664001,14[6,7]
    \\T:=,7.9090004,21.664001,14[7,8]
    \\T:1,18.801,21.664001,14[8,9]
    \\T:𝑖,32.213333,0,20[15,16]
    \\T:2,39.113335,-7.26,14[17,18]
    \\
    },
    .{ .src = "\\mathbb{R}", .dump =
    \\T:ℝ,0,0,20[8,9]
    \\
    },
    .{ .src = "\\mathbb{1}", .dump =
    \\T:𝟙,0,0,20[8,9]
    \\
    },
    .{ .src = "\\mathcal{L}", .dump =
    \\T:L,0,0,20[9,10]
    \\
    },
    .{ .src = "\\mathbf{x}", .dump =
    \\T:x,0,0,20[8,9]
    \\
    },
    .{ .src = "\\hat{A}^{\\dagger}", .dump =
    \\T:𝐴,0,0,20[5,6]
    \\T:̂,16.28,-5.3200006,20[0,7]
    \\T:†,15,-7.26,14[9,16]
    \\
    },
    .{ .src = "\\bar{x}", .dump =
    \\T:𝑥,0,0,20[5,6]
    \\T:̄,11.86,0,20[0,7]
    \\
    },
    .{ .src = "\\vec{v}", .dump =
    \\T:𝑣,0,0,20[5,6]
    \\T:⃗,11.16,0,20[0,7]
    \\
    },
    .{ .src = "\\dot{q}", .dump =
    \\T:𝑞,0,0,20[5,6]
    \\T:̇,12.26,0,20[0,7]
    \\
    },
    .{ .src = "\\tilde{n}", .dump =
    \\T:𝑛,0,0,20[7,8]
    \\T:̃,10.58,0,20[0,9]
    \\
    },
    .{ .src = "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", .dump =
    \\T:(,0,0,20[0,6]
    \\T:𝑎,14.72,-12.200001,20[16,17]
    \\T:𝑏,36.31,-12.200001,20[20,21]
    \\T:𝑐,15.43,11.799999,20[25,26]
    \\T:𝑑,35.3,11.799999,20[29,30]
    \\T:),46.18,0,20[0,6]
    \\
    },
    .{ .src = "\\begin{cases} x & x>0 \\\\ -x & x\\le 0 \\end{cases}", .dump =
    \\T:{,0,0,20[0,6]
    \\T:𝑥,18.04,-13.639999,20[14,15]
    \\T:𝑥,65.04,-13.639999,20[18,19]
    \\T:>,82.03555,-13.639999,20[19,20]
    \\T:0,103.151115,-13.639999,20[20,21]
    \\T:−,18.04,15.16,20[25,26]
    \\T:𝑥,33.600002,15.16,20[26,27]
    \\T:𝑥,65.04,15.16,20[30,31]
    \\T:≤,82.03555,15.16,20[31,34]
    \\T:0,103.151115,15.16,20[35,36]
    \\
    },
    .{ .src = "\\alpha + \\beta \\le \\gamma", .dump =
    \\T:α,0,0,20[0,6]
    \\T:+,17.264444,0,20[7,8]
    \\T:β,37.26889,0,20[9,14]
    \\T:≤,53.984444,0,20[15,18]
    \\T:γ,75.1,0,20[19,25]
    \\
    },
    .{ .src = "x \\in \\mathbb{R}", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\T:∈,16.995556,0,20[2,5]
    \\T:ℝ,35.891113,0,20[14,15]
    \\
    },
    .{ .src = "x \\neq y", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\T:≠,16.995556,0,20[2,6]
    \\T:𝑦,38.111115,0,20[7,8]
    \\
    },
    .{ .src = "e^{i\\theta}", .dump =
    \\T:𝑒,0,0,20[0,1]
    \\T:𝑖,9.32,-7.26,14[3,4]
    \\T:θ,14.15,-7.26,14[4,10]
    \\
    },
    .{ .src = "a\\,b", .dump =
    \\T:𝑎,0,0,20[0,1]
    \\T:𝑏,13.9,0,20[3,4]
    \\
    },
    .{ .src = "x \\quad y", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\T:𝑦,31.439999,0,20[8,9]
    \\
    },
    .{ .src = "x \\pmod n", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\T:(,20.328888,0,20[2,7]
    \\T:m,28.10889,0,20[2,7]
    \\T:o,43.54889,0,20[2,7]
    \\T:d,52.72889,0,20[2,7]
    \\T:𝑛,69.615555,0,20[8,9]
    \\T:),81.615555,0,20[2,7]
    \\
    },
    .{ .src = "x \\bmod y", .dump =
    \\T:𝑥,0,0,20[0,1]
    \\T:m,16.995556,0,20[2,7]
    \\T:o,32.435555,0,20[2,7]
    \\T:d,41.615555,0,20[2,7]
    \\T:𝑦,57.391113,0,20[8,9]
    \\
    },
};

test "goldens: draw-list snapshots" {
    for (golden) |g| {
        const actual = try regression.dump(testing.allocator, g.src, 20);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(g.dump, actual);
    }
}

/// SVG snapshots at size_pt = 20, padding 0 (see regression.dumpSvg).
pub const golden_svg = [_]struct { src: []const u8, padding: f32, svg: []const u8 }{
    .{ .src = "\\frac{x^2+1}{x-1}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="53.708885pt" height="48.053185pt" viewBox="0 0 53.708885 48.053185">
    \\<text x="0" y="16.584003" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="11.759999" y="9.324001" font-size="14" font-style="normal" fill="#000000ff">2</text>
    \\<text x="23.704443" y="16.584003" font-size="20" font-style="normal" fill="#000000ff">+</text>
    \\<text x="43.708885" y="16.584003" font-size="20" font-style="normal" fill="#000000ff">1</text>
    \\<rect x="0" y="24.714163" width="53.708885" height="0.8" fill="#000000ff"/>
    \\<text x="3.9099977" y="43.833183" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="19.794441" y="43.833183" font-size="20" font-style="normal" fill="#000000ff">−</text>
    \\<text x="39.798885" y="43.833183" font-size="20" font-style="normal" fill="#000000ff">1</text>
    \\</svg>
    \\
    },
    .{ .src = "\\dfrac{a}{b}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="10.58pt" height="40.30918pt" viewBox="0 0 10.58 40.30918">
    \\<text x="0" y="8.839999" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<rect x="0" y="16.97016" width="10.58" height="0.8" fill="#000000ff"/>
    \\<text x="1" y="36.08918" font-size="20" font-style="normal" fill="#000000ff">𝑏</text>
    \\</svg>
    \\
    },
    .{ .src = "\\cfrac{1}{a_1+\\cfrac{1}{a_2}}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="63.008892pt" height="80.57902pt" viewBox="0 0 63.008892 80.57902">
    \\<text x="26.504446" y="13.32" font-size="20" font-style="normal" fill="#000000ff">1</text>
    \\<rect x="0" y="22.92" width="63.008892" height="0.8" fill="#000000ff"/>
    \\<text x="0" y="57.92" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<text x="10.58" y="62.859997" font-size="14" font-style="normal" fill="#000000ff">1</text>
    \\<text x="22.524445" y="57.92" font-size="20" font-style="normal" fill="#000000ff">+</text>
    \\<text x="47.768894" y="42.92" font-size="20" font-style="normal" fill="#000000ff">1</text>
    \\<rect x="43.728893" y="52.519997" width="18.08" height="0.8" fill="#000000ff"/>
    \\<text x="43.728893" y="71.63902" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<text x="54.308895" y="76.57902" font-size="14" font-style="normal" fill="#000000ff">2</text>
    \\</svg>
    \\
    },
    .{ .src = "\\binom{n}{k}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="43.84pt" height="51.84pt" viewBox="0 0 43.84 51.84">
    \\<text x="0" y="28.92" font-size="20" font-style="normal" data-fixed-req="2.392" data-delim-form="v6" fill="#000000ff">(</text>
    \\<text x="15.92" y="15.38984" font-size="20" font-style="normal" fill="#000000ff">𝑛</text>
    \\<text x="16.710001" y="42.63902" font-size="20" font-style="normal" fill="#000000ff">𝑘</text>
    \\<text x="29.119999" y="28.92" font-size="20" font-style="normal" data-fixed-req="2.392" data-delim-form="v6" fill="#000000ff">)</text>
    \\</svg>
    \\
    },
    .{ .src = "\\sqrt{a^2+b^2}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="78.82889pt" height="28pt" viewBox="0 0 78.82889 28">
    \\<text x="0" y="17" font-size="20" font-style="normal" data-radical="v1" fill="#000000ff">√</text>
    \\<text x="20" y="20.602001" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<text x="30.8" y="14.8220005" font-size="14" font-style="normal" fill="#000000ff">2</text>
    \\<text x="42.744446" y="20.602001" font-size="20" font-style="normal" fill="#000000ff">+</text>
    \\<text x="62.748886" y="20.602001" font-size="20" font-style="normal" fill="#000000ff">𝑏</text>
    \\<text x="71.32889" y="14.8220005" font-size="14" font-style="normal" fill="#000000ff">2</text>
    \\<rect x="20" y="0" width="58.828888" height="0.8" fill="#000000ff"/>
    \\</svg>
    \\
    },
    .{ .src = "\\sqrt[3]{\\frac{a}{b}}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="32.98pt" height="52pt" viewBox="0 0 32.98 52">
    \\<text x="0" y="29" font-size="20" font-style="normal" data-radical="v3" fill="#000000ff">√</text>
    \\<text x="21.2" y="16.56541" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<rect x="21.2" y="24.69557" width="10.58" height="0.8" fill="#000000ff"/>
    \\<text x="22.2" y="43.81459" font-size="20" font-style="normal" fill="#000000ff">𝑏</text>
    \\<rect x="20" y="0" width="12.98" height="0.8" fill="#000000ff"/>
    \\<text x="2" y="22.300886" font-size="10" font-style="normal" fill="#000000ff">3</text>
    \\</svg>
    \\
    },
    .{ .src = "\\left( \\frac{x+1}{x-1} \\right)", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="74.80889pt" height="46.770157pt" viewBox="0 0 74.80889 46.770157">
    \\<text x="0" y="26.850159" font-size="20" font-style="normal" data-delim-form="v5" fill="#000000ff">(</text>
    \\<text x="14.46" y="13.319999" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="30.344444" y="13.319999" font-size="20" font-style="normal" fill="#000000ff">+</text>
    \\<text x="50.34889" y="13.319999" font-size="20" font-style="normal" fill="#000000ff">1</text>
    \\<rect x="14.46" y="21.45016" width="45.88889" height="0.8" fill="#000000ff"/>
    \\<text x="14.46" y="40.56918" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="30.344444" y="40.56918" font-size="20" font-style="normal" fill="#000000ff">−</text>
    \\<text x="50.34889" y="40.56918" font-size="20" font-style="normal" fill="#000000ff">1</text>
    \\<text x="61.54889" y="26.850159" font-size="20" font-style="normal" data-delim-form="v5" fill="#000000ff">)</text>
    \\</svg>
    \\
    },
    .{ .src = "\\left| x^2 \\right|", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="30.379997pt" height="28.04pt" viewBox="0 0 30.379997 28.04">
    \\<text x="0" y="17.02" font-size="20" font-style="normal" data-delim-form="v1" fill="#000000ff">|</text>
    \\<text x="5.56" y="17.02" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="17.32" y="9.76" font-size="14" font-style="normal" fill="#000000ff">2</text>
    \\<text x="24.819998" y="17.02" font-size="20" font-style="normal" data-delim-form="v1" fill="#000000ff">|</text>
    \\</svg>
    \\
    },
    .{ .src = "\\big( a+b \\big)", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="60.488888pt" height="25.88pt" viewBox="0 0 60.488888 25.88">
    \\<text x="0" y="15.94" font-size="20" font-style="normal" fill="#000000ff">(</text>
    \\<text x="8.44" y="15.94" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<text x="23.464445" y="15.94" font-size="20" font-style="normal" fill="#000000ff">+</text>
    \\<text x="43.468887" y="15.94" font-size="20" font-style="normal" fill="#000000ff">𝑏</text>
    \\<text x="52.04889" y="15.94" font-size="20" font-style="normal" fill="#000000ff">)</text>
    \\</svg>
    \\
    },
    .{ .src = "\\left\\{ \\frac{a}{b} \\right\\}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="39.66pt" height="40.93902pt" viewBox="0 0 39.66 40.93902">
    \\<text x="0" y="23" font-size="20" font-style="normal" data-delim-form="v4" fill="#000000ff">{</text>
    \\<text x="14.54" y="9.46984" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<rect x="14.54" y="17.6" width="10.58" height="0.8" fill="#000000ff"/>
    \\<text x="15.54" y="36.71902" font-size="20" font-style="normal" fill="#000000ff">𝑏</text>
    \\<text x="26.32" y="23" font-size="20" font-style="normal" data-delim-form="v4" fill="#000000ff">}</text>
    \\</svg>
    \\
    },
    .{ .src = "\\int_0^1 x^2\\,dx", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="75.71334pt" height="57.371998pt" viewBox="0 0 75.71334 57.371998">
    \\<text x="0" y="33.044" font-size="20" font-style="normal" fill="#000000ff">∫</text>
    \\<text x="19.98" y="9.323999" font-size="14" font-style="normal" fill="#000000ff">1</text>
    \\<text x="8.16" y="53.063995" font-size="14" font-style="normal" fill="#000000ff">0</text>
    \\<text x="30.813334" y="33.044" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="42.573334" y="25.783998" font-size="14" font-style="normal" fill="#000000ff">2</text>
    \\<text x="53.393333" y="33.044" font-size="20" font-style="normal" fill="#000000ff">𝑑</text>
    \\<text x="64.27334" y="33.044" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\</svg>
    \\
    },
    .{ .src = "\\prod_{i=1}^{n} i", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="35.793335pt" height="55.16pt" viewBox="0 0 35.793335 55.16">
    \\<text x="8.58" y="6.1879997" font-size="14" font-style="normal" fill="#000000ff">𝑛</text>
    \\<text x="0" y="29.342" font-size="20" font-style="normal" fill="#000000ff">∏</text>
    \\<text x="1.4189997" y="51.006" font-size="14" font-style="normal" fill="#000000ff">𝑖</text>
    \\<text x="6.2489996" y="51.006" font-size="14" font-style="normal" fill="#000000ff">=</text>
    \\<text x="17.140999" y="51.006" font-size="14" font-style="normal" fill="#000000ff">1</text>
    \\<text x="28.893333" y="29.342" font-size="20" font-style="normal" fill="#000000ff">𝑖</text>
    \\</svg>
    \\
    },
    .{ .src = "\\lim_{x \\to 0} \\frac{\\sin x}{x}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="70.71467pt" height="44.60918pt" viewBox="0 0 70.71467 44.60918">
    \\<text x="1.7840004" y="26.67016" font-size="20" font-style="normal" fill="#000000ff">l</text>
    \\<text x="6.7840004" y="26.67016" font-size="20" font-style="normal" fill="#000000ff">i</text>
    \\<text x="11.784" y="26.67016" font-size="20" font-style="normal" fill="#000000ff">m</text>
    \\<text x="0" y="39.33416" font-size="14" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="8.007999" y="39.33416" font-size="14" font-style="normal" fill="#000000ff">→</text>
    \\<text x="22.008" y="39.33416" font-size="14" font-style="normal" fill="#000000ff">0</text>
    \\<text x="33.541332" y="13.14" font-size="20" font-style="normal" fill="#000000ff">s</text>
    \\<text x="40.721333" y="13.14" font-size="20" font-style="normal" fill="#000000ff">i</text>
    \\<text x="45.721333" y="13.14" font-size="20" font-style="normal" fill="#000000ff">n</text>
    \\<text x="59.274666" y="13.14" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<rect x="33.541332" y="21.27016" width="37.173336" height="0.8" fill="#000000ff"/>
    \\<text x="46.408" y="40.38918" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\</svg>
    \\
    },
    .{ .src = "\\sum_{i=1}^{n} i^2", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="46.113335pt" height="55.16pt" viewBox="0 0 46.113335 55.16">
    \\<text x="10.240001" y="6.1879997" font-size="14" font-style="normal" fill="#000000ff">𝑛</text>
    \\<text x="0" y="29.342" font-size="20" font-style="normal" fill="#000000ff">∑</text>
    \\<text x="3.0790005" y="51.006" font-size="14" font-style="normal" fill="#000000ff">𝑖</text>
    \\<text x="7.9090004" y="51.006" font-size="14" font-style="normal" fill="#000000ff">=</text>
    \\<text x="18.801" y="51.006" font-size="14" font-style="normal" fill="#000000ff">1</text>
    \\<text x="32.213333" y="29.342" font-size="20" font-style="normal" fill="#000000ff">𝑖</text>
    \\<text x="39.113335" y="22.081999" font-size="14" font-style="normal" fill="#000000ff">2</text>
    \\</svg>
    \\
    },
    .{ .src = "\\mathbb{R}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="12.8pt" height="17.66pt" viewBox="0 0 12.8 17.66">
    \\<text x="0" y="13.660001" font-size="20" font-style="normal" fill="#000000ff">ℝ</text>
    \\</svg>
    \\
    },
    .{ .src = "\\mathbb{1}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="11.2pt" height="16.880001pt" viewBox="0 0 11.2 16.880001">
    \\<text x="0" y="12.88" font-size="20" font-style="normal" fill="#000000ff">𝟙</text>
    \\</svg>
    \\
    },
    .{ .src = "\\mathcal{L}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="12.5pt" height="17.66pt" viewBox="0 0 12.5 17.66">
    \\<text x="0" y="13.660001" font-size="20" font-style="normal" fill="#000000ff">L</text>
    \\</svg>
    \\
    },
    .{ .src = "\\mathbf{x}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="12.14pt" height="12.88pt" viewBox="0 0 12.14 12.88">
    \\<text x="0" y="8.88" font-size="20" font-style="normal" font-weight="bold" fill="#000000ff">x</text>
    \\</svg>
    \\
    },
    .{ .src = "\\hat{A}^{\\dagger}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="21.216pt" height="24pt" viewBox="0 0 21.216 24">
    \\<text x="0" y="20" font-size="20" font-style="normal" fill="#000000ff">𝐴</text>
    \\<text x="16.28" y="14.679999" font-size="20" font-style="normal" fill="#000000ff">̂</text>
    \\<text x="15" y="12.74" font-size="14" font-style="normal" fill="#000000ff">†</text>
    \\</svg>
    \\
    },
    .{ .src = "\\bar{x}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="11.86pt" height="17.02pt" viewBox="0 0 11.86 17.02">
    \\<text x="0" y="12.799999" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="11.86" y="12.799999" font-size="20" font-style="normal" fill="#000000ff">̄</text>
    \\</svg>
    \\
    },
    .{ .src = "\\vec{v}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="11.16pt" height="18.44pt" viewBox="0 0 11.16 18.44">
    \\<text x="0" y="14.22" font-size="20" font-style="normal" fill="#000000ff">𝑣</text>
    \\<text x="11.16" y="14.22" font-size="20" font-style="normal" fill="#000000ff">⃗</text>
    \\</svg>
    \\
    },
    .{ .src = "\\dot{q}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="12.26pt" height="21.42pt" viewBox="0 0 12.26 21.42">
    \\<text x="0" y="13.54" font-size="20" font-style="normal" fill="#000000ff">𝑞</text>
    \\<text x="12.26" y="13.54" font-size="20" font-style="normal" fill="#000000ff">̇</text>
    \\</svg>
    \\
    },
    .{ .src = "\\tilde{n}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="12pt" height="19.14pt" viewBox="0 0 12 19.14">
    \\<text x="0" y="14.92" font-size="20" font-style="normal" fill="#000000ff">𝑛</text>
    \\<text x="10.58" y="14.92" font-size="20" font-style="normal" fill="#000000ff">̃</text>
    \\</svg>
    \\
    },
    .{ .src = "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="60.9pt" height="51.84pt" viewBox="0 0 60.9 51.84">
    \\<text x="0" y="28.92" font-size="20" font-style="normal" data-delim-form="v6" fill="#000000ff">(</text>
    \\<text x="14.72" y="16.72" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<text x="36.31" y="16.72" font-size="20" font-style="normal" fill="#000000ff">𝑏</text>
    \\<text x="15.43" y="40.72" font-size="20" font-style="normal" fill="#000000ff">𝑐</text>
    \\<text x="35.3" y="40.72" font-size="20" font-style="normal" fill="#000000ff">𝑑</text>
    \\<text x="46.18" y="28.92" font-size="20" font-style="normal" data-delim-form="v6" fill="#000000ff">)</text>
    \\</svg>
    \\
    },
    .{ .src = "\\begin{cases} x & x>0 \\\\ -x & x\\le 0 \\end{cases}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="113.151115pt" height="64pt" viewBox="0 0 113.151115 64">
    \\<text x="0" y="35" font-size="20" font-style="normal" data-delim-form="v7" fill="#000000ff">{</text>
    \\<text x="18.04" y="21.36" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="65.04" y="21.36" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="82.03555" y="21.36" font-size="20" font-style="normal" fill="#000000ff">&gt;</text>
    \\<text x="103.151115" y="21.36" font-size="20" font-style="normal" fill="#000000ff">0</text>
    \\<text x="18.04" y="50.16" font-size="20" font-style="normal" fill="#000000ff">−</text>
    \\<text x="33.600002" y="50.16" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="65.04" y="50.16" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="82.03555" y="50.16" font-size="20" font-style="normal" fill="#000000ff">≤</text>
    \\<text x="103.151115" y="50.16" font-size="20" font-style="normal" fill="#000000ff">0</text>
    \\</svg>
    \\
    },
    .{ .src = "\\alpha + \\beta \\le \\gamma", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="86.82pt" height="22.419998pt" viewBox="0 0 86.82 22.419998">
    \\<text x="0" y="14.119999" font-size="20" font-style="normal" fill="#000000ff">α</text>
    \\<text x="17.264444" y="14.119999" font-size="20" font-style="normal" fill="#000000ff">+</text>
    \\<text x="37.26889" y="14.119999" font-size="20" font-style="normal" fill="#000000ff">β</text>
    \\<text x="53.984444" y="14.119999" font-size="20" font-style="normal" fill="#000000ff">≤</text>
    \\<text x="75.1" y="14.119999" font-size="20" font-style="normal" fill="#000000ff">γ</text>
    \\</svg>
    \\
    },
    .{ .src = "x \\in \\mathbb{R}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="48.691113pt" height="18.52pt" viewBox="0 0 48.691113 18.52">
    \\<text x="0" y="13.660001" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="16.995556" y="13.660001" font-size="20" font-style="normal" fill="#000000ff">∈</text>
    \\<text x="35.891113" y="13.660001" font-size="20" font-style="normal" fill="#000000ff">ℝ</text>
    \\</svg>
    \\
    },
    .{ .src = "x \\neq y", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="47.911114pt" height="23.2pt" viewBox="0 0 47.911114 23.2">
    \\<text x="0" y="14.6" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="16.995556" y="14.6" font-size="20" font-style="normal" fill="#000000ff">≠</text>
    \\<text x="38.111115" y="14.6" font-size="20" font-style="normal" fill="#000000ff">𝑦</text>
    \\</svg>
    \\
    },
    .{ .src = "e^{i\\theta}", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="20.982pt" height="21.35pt" viewBox="0 0 20.982 21.35">
    \\<text x="0" y="17.130001" font-size="20" font-style="normal" fill="#000000ff">𝑒</text>
    \\<text x="9.32" y="9.870001" font-size="14" font-style="normal" fill="#000000ff">𝑖</text>
    \\<text x="14.15" y="9.870001" font-size="14" font-style="normal" fill="#000000ff">θ</text>
    \\</svg>
    \\
    },
    .{ .src = "a\\,b", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="22.48pt" height="18.1pt" viewBox="0 0 22.48 18.1">
    \\<text x="0" y="13.88" font-size="20" font-style="normal" fill="#000000ff">𝑎</text>
    \\<text x="13.9" y="13.88" font-size="20" font-style="normal" fill="#000000ff">𝑏</text>
    \\</svg>
    \\
    },
    .{ .src = "x \\quad y", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="41.239998pt" height="16.94pt" viewBox="0 0 41.239998 16.94">
    \\<text x="0" y="8.84" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="31.439999" y="8.84" font-size="20" font-style="normal" fill="#000000ff">𝑦</text>
    \\</svg>
    \\
    },
    .{ .src = "x \\pmod n", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="89.39555pt" height="23.920002pt" viewBox="0 0 89.39555 23.920002">
    \\<text x="0" y="14.960001" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="20.328888" y="14.960001" font-size="20" font-style="normal" fill="#000000ff">(</text>
    \\<text x="28.10889" y="14.960001" font-size="20" font-style="normal" fill="#000000ff">m</text>
    \\<text x="43.54889" y="14.960001" font-size="20" font-style="normal" fill="#000000ff">o</text>
    \\<text x="52.72889" y="14.960001" font-size="20" font-style="normal" fill="#000000ff">d</text>
    \\<text x="69.615555" y="14.960001" font-size="20" font-style="normal" fill="#000000ff">𝑛</text>
    \\<text x="81.615555" y="14.960001" font-size="20" font-style="normal" fill="#000000ff">)</text>
    \\</svg>
    \\
    },
    .{ .src = "x \\bmod y", .padding = 0, .svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="67.19112pt" height="21.98pt" viewBox="0 0 67.19112 21.98">
    \\<text x="0" y="13.88" font-size="20" font-style="normal" fill="#000000ff">𝑥</text>
    \\<text x="16.995556" y="13.88" font-size="20" font-style="normal" fill="#000000ff">m</text>
    \\<text x="32.435555" y="13.88" font-size="20" font-style="normal" fill="#000000ff">o</text>
    \\<text x="41.615555" y="13.88" font-size="20" font-style="normal" fill="#000000ff">d</text>
    \\<text x="57.391113" y="13.88" font-size="20" font-style="normal" fill="#000000ff">𝑦</text>
    \\</svg>
    \\
    },
};

test "goldens: svg snapshots" {
    for (golden_svg) |g| {
        const actual = try regression.dumpSvg(testing.allocator, g.src, 20, g.padding);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(g.svg, actual);
    }
}

/// Atom-tree snapshots (see regression.dumpAtoms).
pub const golden_atoms = [_]struct { src: []const u8, dump: []const u8 }{
    .{ .src = "\\frac{x^2+1}{x-1}", .dump =
    \\row[0,16]
    \\fraction[0,16]
    \\row[6,11]
    \\script[6,9]
    \\char[6,7] x
    \\char[8,9] 2
    \\char[9,10] +
    \\char[10,11] 1
    \\row[13,16]
    \\char[13,14] x
    \\char[14,15] -
    \\char[15,16] 1
    \\
    },
    .{ .src = "\\dfrac{a}{b}", .dump =
    \\row[0,11]
    \\fraction[0,11]
    \\row[7,8]
    \\char[7,8] a
    \\row[10,11]
    \\char[10,11] b
    \\
    },
    .{ .src = "\\cfrac{1}{a_1+\\cfrac{1}{a_2}}", .dump =
    \\row[0,27]
    \\fraction[0,27]
    \\row[7,8]
    \\char[7,8] 1
    \\row[10,27]
    \\script[10,13]
    \\char[10,11] a
    \\char[12,13] 1
    \\char[13,14] +
    \\fraction[14,27]
    \\row[21,22]
    \\char[21,22] 1
    \\row[24,27]
    \\script[24,27]
    \\char[24,25] a
    \\char[26,27] 2
    \\
    },
    .{ .src = "\\binom{n}{k}", .dump =
    \\row[0,11]
    \\left[0,11]
    \\char[0,6] \binom
    \\fraction[0,11]
    \\row[7,8]
    \\char[7,8] n
    \\row[10,11]
    \\char[10,11] k
    \\char[0,6] \binom
    \\
    },
    .{ .src = "\\sqrt{a^2+b^2}", .dump =
    \\row[0,13]
    \\row[0,13]
    \\char[0,5] \sqrt
    \\row[6,13]
    \\script[6,9]
    \\char[6,7] a
    \\char[8,9] 2
    \\char[9,10] +
    \\script[10,13]
    \\char[10,11] b
    \\char[12,13] 2
    \\
    },
    .{ .src = "\\sqrt[3]{\\frac{a}{b}}", .dump =
    \\row[0,19]
    \\row[0,19]
    \\script[0,7]
    \\char[0,5] \sqrt
    \\row[6,7]
    \\char[6,7] 3
    \\row[9,19]
    \\fraction[9,19]
    \\row[15,16]
    \\char[15,16] a
    \\row[18,19]
    \\char[18,19] b
    \\
    },
    .{ .src = "\\left( \\frac{x+1}{x-1} \\right)", .dump =
    \\row[0,30]
    \\left[0,30]
    \\char[5,6] (
    \\row[7,21]
    \\fraction[7,21]
    \\row[13,16]
    \\char[13,14] x
    \\char[14,15] +
    \\char[15,16] 1
    \\row[18,21]
    \\char[18,19] x
    \\char[19,20] -
    \\char[20,21] 1
    \\char[29,30] )
    \\
    },
    .{ .src = "\\left| x^2 \\right|", .dump =
    \\row[0,18]
    \\left[0,18]
    \\char[5,6] |
    \\row[7,10]
    \\script[7,10]
    \\char[7,8] x
    \\char[9,10] 2
    \\char[17,18] |
    \\
    },
    .{ .src = "\\big( a+b \\big)", .dump =
    \\row[0,15]
    \\left[0,5]
    \\char[4,5] (
    \\char[6,7] a
    \\char[7,8] +
    \\char[8,9] b
    \\left[10,15]
    \\char[14,15] )
    \\
    },
    .{ .src = "\\left\\{ \\frac{a}{b} \\right\\}", .dump =
    \\row[0,28]
    \\left[0,28]
    \\char[5,7] \{
    \\row[8,18]
    \\fraction[8,18]
    \\row[14,15]
    \\char[14,15] a
    \\row[17,18]
    \\char[17,18] b
    \\char[26,28] \}
    \\
    },
    .{ .src = "\\int_0^1 x^2\\,dx", .dump =
    \\row[0,16]
    \\script[0,8]
    \\op[0,4] \int
    \\char[7,8] 1
    \\char[5,6] 0
    \\script[9,12]
    \\char[9,10] x
    \\char[11,12] 2
    \\space[12,14] \,
    \\char[14,15] d
    \\char[15,16] x
    \\
    },
    .{ .src = "\\prod_{i=1}^{n} i", .dump =
    \\row[0,17]
    \\script[0,15]
    \\op[0,5] \prod
    \\group[12,15]
    \\row[13,14]
    \\char[13,14] n
    \\group[6,11]
    \\row[7,10]
    \\char[7,8] i
    \\char[8,9] =
    \\char[9,10] 1
    \\char[16,17] i
    \\
    },
    .{ .src = "\\lim_{x \\to 0} \\frac{\\sin x}{x}", .dump =
    \\row[0,30]
    \\script[0,14]
    \\opname[0,4]
    \\row[0,4]
    \\char[0,4] \lim
    \\char[0,4] \lim
    \\char[0,4] \lim
    \\group[5,14]
    \\row[6,13]
    \\char[6,7] x
    \\char[8,11] \to
    \\char[12,13] 0
    \\fraction[15,30]
    \\row[21,27]
    \\opname[21,25]
    \\row[21,25]
    \\char[21,25] \sin
    \\char[21,25] \sin
    \\char[21,25] \sin
    \\char[26,27] x
    \\row[29,30]
    \\char[29,30] x
    \\
    },
    .{ .src = "\\sum_{i=1}^{n} i^2", .dump =
    \\row[0,18]
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
    \\script[15,18]
    \\char[15,16] i
    \\char[17,18] 2
    \\
    },
    .{ .src = "\\mathbb{R}", .dump =
    \\row[0,9]
    \\styled[0,9]
    \\row[8,9]
    \\char[8,9] R
    \\
    },
    .{ .src = "\\mathbb{1}", .dump =
    \\row[0,9]
    \\styled[0,9]
    \\row[8,9]
    \\char[8,9] 1
    \\
    },
    .{ .src = "\\mathcal{L}", .dump =
    \\row[0,10]
    \\styled[0,10]
    \\row[9,10]
    \\char[9,10] L
    \\
    },
    .{ .src = "\\mathbf{x}", .dump =
    \\row[0,9]
    \\styled[0,9]
    \\row[8,9]
    \\char[8,9] x
    \\
    },
    .{ .src = "\\hat{A}^{\\dagger}", .dump =
    \\row[0,17]
    \\script[0,17]
    \\row[0,7]
    \\group[4,7]
    \\row[5,6]
    \\char[5,6] A
    \\char[0,4] \hat
    \\group[8,17]
    \\row[9,16]
    \\char[9,16] \dagger
    \\
    },
    .{ .src = "\\bar{x}", .dump =
    \\row[0,7]
    \\row[0,7]
    \\group[4,7]
    \\row[5,6]
    \\char[5,6] x
    \\char[0,4] \bar
    \\
    },
    .{ .src = "\\vec{v}", .dump =
    \\row[0,7]
    \\row[0,7]
    \\group[4,7]
    \\row[5,6]
    \\char[5,6] v
    \\char[0,4] \vec
    \\
    },
    .{ .src = "\\dot{q}", .dump =
    \\row[0,7]
    \\row[0,7]
    \\group[4,7]
    \\row[5,6]
    \\char[5,6] q
    \\char[0,4] \dot
    \\
    },
    .{ .src = "\\tilde{n}", .dump =
    \\row[0,9]
    \\row[0,9]
    \\group[6,9]
    \\row[7,8]
    \\char[7,8] n
    \\char[0,6] \tilde
    \\
    },
    .{ .src = "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", .dump =
    \\row[0,44]
    \\env[0,44]
    \\char[0,6] \begin
    \\row[16,21]
    \\row[16,17]
    \\char[16,17] a
    \\row[20,21]
    \\char[20,21] b
    \\row[25,30]
    \\row[25,26]
    \\char[25,26] c
    \\row[29,30]
    \\char[29,30] d
    \\char[0,6] \begin
    \\
    },
    .{ .src = "\\begin{cases} x & x>0 \\\\ -x & x\\le 0 \\end{cases}", .dump =
    \\row[0,48]
    \\env[0,48]
    \\char[0,6] \begin
    \\row[14,21]
    \\row[14,15]
    \\char[14,15] x
    \\row[18,21]
    \\char[18,19] x
    \\char[19,20] >
    \\char[20,21] 0
    \\row[25,36]
    \\row[25,27]
    \\char[25,26] -
    \\char[26,27] x
    \\row[30,36]
    \\char[30,31] x
    \\char[31,34] \le
    \\char[35,36] 0
    \\
    },
    .{ .src = "\\alpha + \\beta \\le \\gamma", .dump =
    \\row[0,25]
    \\char[0,6] \alpha
    \\char[7,8] +
    \\char[9,14] \beta
    \\char[15,18] \le
    \\char[19,25] \gamma
    \\
    },
    .{ .src = "x \\in \\mathbb{R}", .dump =
    \\row[0,15]
    \\char[0,1] x
    \\char[2,5] \in
    \\styled[6,15]
    \\row[14,15]
    \\char[14,15] R
    \\
    },
    .{ .src = "x \\neq y", .dump =
    \\row[0,8]
    \\char[0,1] x
    \\char[2,6] \neq
    \\char[7,8] y
    \\
    },
    .{ .src = "e^{i\\theta}", .dump =
    \\row[0,11]
    \\script[0,11]
    \\char[0,1] e
    \\group[2,11]
    \\row[3,10]
    \\char[3,4] i
    \\char[4,10] \theta
    \\
    },
    .{ .src = "a\\,b", .dump =
    \\row[0,4]
    \\char[0,1] a
    \\space[1,3] \,
    \\char[3,4] b
    \\
    },
    .{ .src = "x \\quad y", .dump =
    \\row[0,9]
    \\char[0,1] x
    \\space[2,7] \quad
    \\char[8,9] y
    \\
    },
    .{ .src = "x \\pmod n", .dump =
    \\row[0,9]
    \\char[0,1] x
    \\row[2,9]
    \\char[2,7] \pmod
    \\opname[2,7]
    \\row[2,7]
    \\char[2,7] \pmod
    \\char[2,7] \pmod
    \\char[2,7] \pmod
    \\space[2,7] \pmod
    \\char[8,9] n
    \\char[2,7] \pmod
    \\
    },
    .{ .src = "x \\bmod y", .dump =
    \\row[0,9]
    \\char[0,1] x
    \\row[2,7]
    \\space[2,7] \bmod
    \\opname[2,7]
    \\row[2,7]
    \\char[2,7] \bmod
    \\char[2,7] \bmod
    \\char[2,7] \bmod
    \\space[2,7] \bmod
    \\char[8,9] y
    \\
    },
};

test "goldens: atom-tree snapshots" {
    for (golden_atoms) |g| {
        const actual = try regression.dumpAtoms(testing.allocator, g.src);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(g.dump, actual);
    }
}
