# Pipeline STAGE 4 audit — draw.zig flatten + svg.zig SVG generation

Date: 2026-08-13. Scope: how the box tree becomes draw primitives (src/layout/draw.zig,
src/layout/box.zig) and how the draw list becomes SVG text (src/svg.zig), and whether the
drawn INK lands where the layout boxes say. READ-ONLY audit; the binary was built
(`zig build -Doptimize=ReleaseSafe`) and used only to render probe formulas — no test gates
were run.

Test formula (rendered at `-s 20`, `-p 0`, `-b none`):
`\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`
SVG: `viewBox="0 0 127.067696 37.041344"`; root baseline at SVG y = 22.14126 (= dl.height = base).
XeTeX reference (same formula, LMMath, 20pt, `\showbox`): total 143.7407 x (33.04414 + 24.21683).

Every position below was cross-verified by hand against the layout source formulas AND
reproduced by the binary's SVG output (they agree exactly, to 1e-3 pt). Ink extents are
measured from the actual installed fonts with fontTools (LMMath 2.005:
/nix/store/whmfn34z3b5hdihz7zqinlwkw5gv9l6g-lmodern-2.005/.../latinmodern-math.otf;
cmr/cmmi TFM truth via tftopl).

---

## F1 — CRITICAL: big-operator glyph ink is drawn ~1em too high; 2/3–3/4 of every ∑/∫ is clipped out of the viewBox. This is the "significantly flawed output".

**ztex:** `layoutOp` gives the display op a cmex10-derived BOX (∑ h=1.00001 d=15.00012,
∫ h=0 d=22.22246 at 10pt, fixed) and `layoutRow`/`layoutScript`/`layoutOpLimits` place the
glyph BASELINE exactly where TeX puts the cmex glyph's baseline (op_shift = (h−d)/2 − axis;
verified: bare ∫ baseline lands 13.61pt above the row baseline, matching TeX-CM). The glyph
is then drawn as the Unicode codepoint at font-size 14 (∑) / 20 (∫).

**The mismatch:** cmex10 big-op glyphs have their ink almost entirely BELOW their baseline
(∑ ink ≈ +0.1em…−1.5em; ∫ ink ≈ 0…−2.2em), so TeX's baseline placement centers the ink on
the math axis. Unicode math-font glyphs (LMMath, DejaVu, STIX) are drawn with their ink mostly
ABOVE their baseline (LMMath ∑: +0.75em/−0.25em; ∫: +0.805em/−0.306em; DejaVu ∑:
+0.719/−0.192; ∫: +0.757/−0.181). Drawing the LMMath glyph at the cmex baseline puts its ink
≈(cmex ink center) − (LMMath ink center) ≈ 0.75–0.8 em of the drawn glyph too high.

**Measured (this render, -s 20):**
- `\sum` alone: viewBox 16.00013 tall; ∑ baseline at y=1.000; LMMath ink at 14pt =
  +10.5/−3.5 → ink spans y −9.5…+4.5. **9.5pt of the symbol's top is outside the viewBox;**
  only the bottom third is visible.
- `\int_0^1 x`: viewBox 27.300276; ∫ baseline at y=4.0778; ink +16.1/−6.12 → spans
  −12.0…+10.2. **12pt clipped at the top;**
- Test formula: ∑ ink spans −0.36…+13.64 (0.36 clipped; ink center at 6.64 sits 10.5pt
  above the axis at 17.14); ∫ ink spans −10.07…+12.15 (**10.07pt clipped**; ink center
  16.1pt above the axis). The ∫ appears as only its bottom hook; the ∑ floats at the top of the
  limit gap. TeX/cmex would draw the ink at 6.03…28.25 (∫) / 9.14…25.14 (∑).

**Verdict: WRONG.** The layout is faithfully TeX-CM; the ink is a different font paradigm.
Magnitude: 9.5–16.1pt vertical ink displacement at 20pt (≈0.8–1.1 em); the viewBox is
violated at the top by 0.4–12pt (SVG default hides overflow, so the symbol tops are simply
gone).

**Fix:** position the op glyph by its own ink: in layout coordinates the glyph baseline
should be at `axis − (ink_up − ink_down)/2` with ink measured from the actual font (for
LMMath ∫ at 20pt this is ≈0 → baseline on the math baseline, exactly XeTeX-LMMath's
placement: `\showbox` shows the ∫ box with shift ≈ 0 and ink centered on the axis). The
box height/depth that drive limit gaps and the viewBox must then use the drawn glyph's
ink extents (ink_up/ink_down) instead of the cmex h/d, or every limit position and the
viewBox stay wrong even after the baseline is fixed. See F3 for the size part.

## F2 — HIGH: whole SVG is in points but emitted as unitless px; output renders at 0.75× the requested point size.

**ztex:** all layout numbers are points (`-s 20` = 20pt). `svg.zig` writes
`width="127.07"` `font-size="20"` with no units — SVG user units are px (1 px at CSS
zoom 1). A browser renders the glyphs at 20px = 15pt.

**Correct:** either emit pt units (`width="127.07pt"` `font-size="20pt"`) so 1 unit = 1pt,
or scale by 96/72 for px.

**Verdict: WRONG vs the documented contract** ("-s <pt> font size in points"): the physical
output is 75% of the declared size. Magnitude: global 0.75× (at 20pt, text renders 15pt).
Uniform, so no clipping or relative distortion — but any size comparison against XeTeX/TeX
or an embedding at true pt is off by 4/3.

## F3 — HIGH: display big-op glyph size does not scale with size_pt (∑ always font-size 14, ∫ always 20), and the scale fudge (1.4 / 2.0) matches nothing in the drawn font at size ≠ 10pt.

**ztex:** `layoutOp` uses the fixed 10pt cmex box and `glyph_size = 10 × scale` at EVERY
document size (verified: `\sum` renders font-size 14 at both -s 10 and -s 20).
**Correct (TeX-CM):** cmex10 is a fixed-design-size font; TeX indeed keeps the 10pt box at
20pt document size. **Correct (XeTeX-LMMath):** display ops scale with the text size —
`\showbox` at 20pt shows the ∑ assembly 19.0+9.0 (28pt tall) and the ∫ 27.22+17.22, i.e.
≈1.4em / 1.36em, while ztex draws 14pt/20pt ink.
**Verdict: WRONG for the font actually drawn** (LMMath is first in the family). ztex is a
hybrid: CM boxes + LMMath ink. At -s 20 the ∑/∫ ink is half of XeTeX-LMMath's; the 1.4
scale only matches LMMath's display ∑ at 10pt, and the 2.0 ∫ scale matches neither LMMath
(display ∫ ≈1.36em) nor cmex (22.22pt at 10pt is a box, not ink). Also the cmex ∑ box is
16pt tall but the drawn ink 14pt → 2pt of dead space inside the limit box at any size.
**Fix:** derive display-op size from the font's MATH table (or per-glyph ink em) and the
current size_pt, e.g. font-size = size_pt × 1.4 for ∑-class, size_pt × ~1.36 for ∫-class
when LMMath is the math font; then F1's placement fixes itself for free if the ink em is
used consistently for both.

## F4 — MEDIUM: `\text{}` / `\mathrm` / styles are not emitted; text mode renders italic.

**ztex:** every `<text>` gets one fixed `font-family` and NO `font-style`/`font-weight`;
the AST/metrics track `CharStyle` (italic/roman/bold) but svg.zig ignores it. LMMath's
default glyphs are italic, so `\text{hi}` (roman in the metrics, cmr10 boxes) renders
italic letters. `\mathrm{x}` likewise italic; `\mathbf` has no bold at all.
**Correct:** math runs in LMMath (or an italic face), `\text`/`\mathrm` runs in an upright
face (`Latin Modern Roman`, `font-style="normal"`).
**Verdict: WRONG.** Magnitude: whole text-mode runs in the wrong typeface; style commands
(\mathrm, \mathbf, \mathit) are visually no-ops.
**Fix:** svg.zig must emit per-text style (`font-style="italic|normal"`,
`font-family` per style class), using the box's `CharStyle` that flatten already carries.

## F5 — MEDIUM: font availability dependence — the fallback chain silently changes the output.

**ztex:** family = "Latin Modern Math, Latin Modern Roman, DejaVu Serif, serif".
**Correct behavior:** with LMMath present, math letters are italic, ∑/∫/⋅ exist ✓.
Without LMMath: LM Roman has NO ∑ (U+2211), ∫ (U+222B), ⋅ (U+22C5), √, ≤, etc. → tofu or
DejaVu fallback; and math letters go UPRIGHT (LM Roman). Mixed LMMath/LM Roman selection
is invisible to the layout.
**Verdict: RISK (design flaw):** the output's appearance is machine-dependent in the
symbols that matter most, and there is no "math vs text" font pairing, so even F4's fix
needs two families. Either bundle a font (LMMath) or restrict the family to a documented,
checked set. (Note: with LMMath present, the advances of its Latin letters equal LM
Roman's and are within ~0.9pt of cmmi10's — see F6 — so ordinary letters are fine.)

## F6 — LOW: per-glyph ink-vs-box mismatches (cmmi10/cmr10 metrics vs LMMath ink), ≤0.93pt at 20pt.

Measured ink vs ztex box at rendered sizes (test formula):
| glyph | size | box h / d / w (pt) | LMMath ink up / down / adv (pt) | delta |
|---|---|---|---|---|
| x | 20 | 8.611 / 0 / 11.431 | 8.62 / 0 / 10.56 | adv −0.87 (ink short); up +0.01 |
| i | 14 | 9.233 / 0 / 4.823 | 9.20 / 0 / 3.89 | adv −0.93 |
| n (sup) | 14 | 6.028 / 0 / 9.887* | 6.19 / 0 / 7.78 | ink up +0.16 over box |
| n (den) | 20 | 8.611 / 0 / 12.005 | 8.84 / 0 / 11.12 | adv −0.88; up +0.23 |
| = | 14 | 5.136 / −1.864 / 10.889 | 5.14 / −1.86 / 10.892 | ≈0 (metric-compatible) |
| 1, 0 | 14 | 9.022 / 0 / 7.0 | 9.32 / 0..0.31 / 7.0 | up +0.30, 0-down +0.31 |
| d | 20 | 13.889 / 0 / 10.410 | 13.88 / 0.22 / 11.12 | adv +0.71 (extra gap; ink width 9.86 fits) |
| + | 20 | 11.667 / 1.667 / 15.556 | 11.66 / 1.66 / 15.56 | ≈0 |

\* n-at-14 sup box w = 6.00235×1.4 = 8.40329 (main table; verified via the over-limit
x_shift (22.71211−8.40329)/2 = 7.15443 ✓). Width only matters for vbox centering, harmless.

**Verdict: ACCEPTABLE-with-note.** Ink fits the vertical boxes to ≤0.31pt (only the 20pt
n exceeds by 0.23pt and digits by 0.30pt; the x top overshoots by 0.009pt — a hair past the
viewBox). Advance mismatches ≤0.93pt per glyph accumulate across a run (total width in the
test formula: 127.07 vs XeTeX-LMMath 143.74 — dominated by F1/F3 big-op geometry, with
≈6pt from letter-advance drift). LM Roman/CM text compatibility does NOT extend to the
cmmi10 italic advances (cmmi10 x 0.5715em vs LMMath 0.528em, n 0.6002 vs 0.556, d 0.5205 vs
0.556). Fix only if width fidelity matters: use LMMath's own advances for the boxes, or
keep cmmi10 and document the ≤1pt drift.

## F7 — VERIFIED CORRECT (no action): baseline mapping, viewBox math, escaping, provenance, synthetic flag.

- Baseline conversion: flatten emits `text.y` = the box's baseline y (y-up layout);
  `base = dl.height + pad` maps the topmost BOX to y=pad. Verified numerically: root
  baseline lands at SVG y = 22.14126; numerator/denominator/rule/sub/sup positions all
  reproduce the layout formulas to 1e-3 pt (e.g. rule center at axis = 17.141;
  `x_i` sub i at +3.0pt below x = sub1@20pt; over-limit n at +15.000065 above baseline).
- `dl.height`/`dl.depth` = root box's height/depth, which is the true max ascent/descent
  including limits, scripts and axis centering (verified: dl.height = frac height
  22.14126 = num1 + x-height-of-numerator; the ∑-limits vbox contributes 22.028 < 22.141).
  All non-op ink lies inside [0, height]: topmost ordinary ink = over-limit n at 0.95,
  bottommost = sub row baseline 36.04 (depth 0) + bigop5 pad. The ONLY viewBox violations
  are the big-op inks (F1) and a 0.009pt x hairline.
- `viewBox height = dl.height + dl.depth + 2·pad`: internally consistent; no bottom
  clipping in the test formula (∫ tail ends at 12.15, well inside).
- Escaping: `escapeAppend` covers & < > " (tests present); attributes are numeric/const
  so no injection. Colors: 8-digit #rrggbbaa, correct.
- `.synthetic` flag: only big ops and parser-override glyphs (\cdot → U+22C5) dupe into
  the glyph arena; all other text aliases the source span. Codepoints exist in LMMath and
  DejaVu (measured); absent from LM Roman (see F5).
- font-size plumbing: `t.size` = box `size` = 10 base / 7 script / 5 scriptscript /
  10×scale display — the SVG emits exactly the box's size, so the size bug is F3 (the
  VALUE), not the plumbing.

## Ranking and recommended order

1. F1 (vertical placement of big-op ink; clipped symbols) — rework display-op vertical
   layout to use the drawn font's ink. 2. F2 (pt vs px, 0.75×). 3. F3 (big-op size vs
   size_pt). 4. F4 + F5 (styles/font pairing for \text, \mathrm, \mathbf; font
   availability). 6. F6 (optional advance fidelity). F7: leave alone.
