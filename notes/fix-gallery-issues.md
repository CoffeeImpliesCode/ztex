# Fix: gallery layout bugs — \left\{ over a scripted tower, \textstyle\int beside limits

Two bugs the user spotted in the KaTeX-corpus 3-pane gallery, both at `-s 30`.
EDIT ONLY: `src/layout/layout.zig`. SKIP gates. Goldens intentionally change
(regression corpus has no \left..\right / text-style big-op formulas, so the
168 tests still pass unchanged).

## Bug 1 — \left\{ does not grow over a tall scripted tower

Formula: `\left( x^2 \right) \left\{ x^{x^{x^{x^x}}} \right.` at `-s 30`.

### Root cause

The LAYOUT box was already correct: layoutLeftRight measures the inner
script-box height (h=36.03, d=0.33 at 30pt) and picks braceleft.v5
(asc 1.300 / desc 0.800 em → box 39.0/24.0, width 21.21). The defect was the
DRAWN size: the `<text font-size>` stayed at the BASE size (30), so the
browser and the critique rasterizer drew the BASE `{` glyph (ink 22.5/7.5 at
30pt) — the brace visibly stopped ~14pt short of the tower. The task's
hypothesis (content-height measurement) is disproven by the box dump: the
box grows correctly; only the drawn glyph encodes no growth.

The rasterizer (scripts/critique.py) reconstructs a stretched delimiter's
MATH size variant only for delimiters it can PAIR (open+close). A fence
whose partner is a null delimiter (`\left.` / `\right.`) is unpaired and is
drawn as the declared glyph at the declared size — so the intent must live
in the SVG itself.

### Fix

`layoutLeftRight` routes a fence delimiter WITHOUT a partner through a new
`layoutDelimScaled` helper (continuous scaled-base path, the no-ladder
fallback): the base glyph is drawn at the font-size whose axis-centered ink
covers the content exactly — TeX make_delim's 2δ with
δ = max(h−a, d+a) of the enclosed box, no \delimitershortfall (XeTeX's
brace covers the tower exactly: 118px = 118px), floored at the base size.
The box becomes the scaled base glyph's own advance/ink (layoutScaledChar),
so the drawn ink bounds exactly what the box reserves — the following atom
never overlaps the wider scaled glyph. Paired delimiters keep the MATH
variant path unchanged (the rasterizer resolves them from the content at
the base size).

### Before → after (`-s 30`)

| metric | before | after |
|---|---|---|
| `{` font-size | 30 (base) | 57.066 (= 2δ/1.0em) |
| `{` ink top above baseline | 22.5pt | 36.03pt |
| tower top ink above baseline | 36.12pt | 36.12pt |
| brace vs tower top gap | −13.6pt (short) | +0.09pt (within ~1pt) |
| `{` box advance (width) | 21.21pt | 28.53pt (= 0.5em × 57.066) |
| brace ink right vs tower x origin | overlap 2.5pt | clear by 4.5pt |
| `\left( x^2 \right)` parens | base, 30pt | base, 30pt (unchanged) |
| `\left( \frac{a}{b} \right)` parens | base, 30pt | base, 30pt (unchanged, paired) |

Raster (PIL, gallery pane): brace ink y 4.5..60.75, tower ink y 4.5..40.5 —
the brace covers the tower top to bottom, top exactly at the tower top.

## Bug 2 — \textstyle\int beside limits overlap + wrong size

Formula: `\displaystyle\int\limits_2^3 3x^2\,dx + \sum\nolimits^n_{i=1}i +
\textstyle\int_0^1 x\,dx` at `-s 30`.

### Root cause (two defects)

1. **Text ∫ drawn as a display ∫.** The rasterizer resolves the MATH .v1
   display variant for EVERY big-op codepoint regardless of style
   (scripts/critique.py `BIGOP_PUA.get(ord(content))`), so a text-style ∫
   emitted at size_pt rendered as a full-size display ∫ — identical to the
   display ∫ next to it ("should be smaller") — and its desc (0.861em)
   swallowed the beside-limit 0, which sat at 0.333em (advance − ic) INSIDE
   the big ∫ ink ("the limits overlap with it"). XeTeX draws the text ∫ as
   the BASE glyph (ink 0.805/0.306 em), so no overlap.

2. **Beside-script attachment.** The text-op branch placed the sub at
   advance − ic (0.333em) and the sup at the advance — the letter rule
   applied to an op; the sub landed inside the drawn ∫ ink.

### Fix

- `layoutOp`: a NON-display big op is drawn at
  `size_pt × base_asc/disp_asc` (∫: 0.805/1.361 → 0.5915×size; ∑:
  0.750/0.950 → 0.7895×size). The rasterizer's .v1 resolution at that size
  lands on exactly the base form's ink HEIGHT — XeTeX's text ∫ IS the base
  glyph at size_pt — and the SVG's declared size shows the text op visibly
  smaller than a display op. The box (advance, limits, script drops) is
  untouched. Display ops keep size_pt (the .v1 at size_pt is XeTeX-exact).
- `layoutScript` non-display op branch: superscript at advance + base ic,
  subscript at the advance itself (`sup_ic = +ic`, `sub_ic = 0`), so the
  sub clears the drawn ∫ ink (the acceptance's sub at the advance ~19.95pt,
  sup at advance+ic ~29.91pt at 30pt). Display nolimits ops (sup at the
  .v1 advance, sub at .v1 advance − .v1 ic) are unchanged and stay
  XeTeX-exact.

### Before → after (`-s 30`)

| metric | before | after |
|---|---|---|
| text ∫ font-size | 30 | 17.744 (∫ base-asc/disp-asc ratio) |
| text ∫ ink height (raster) | 40.4pt (.v1@30, = display) | 38.2pt (.v1@17.74, height = base form @30) |
| display ∫ ink height (raster) | 40.4pt | 59.2pt+ (.v1@30, unchanged) |
| sub 0 x-offset | 9.99pt (0.333em, inside ink) | 19.95pt (0.665em = advance) |
| sup 1 x-offset | 19.95pt (0.665em) | 29.91pt (advance + ic 0.332em) |
| sub 0 vs text-∫ ink (raster) | overlap (inside .v1 ink) | clear by 5.2pt |
| \displaystyle\int\limits_2^3 | stacked 3/2 | stacked 3/2 (unchanged) |
| \int_0^1 beside at display | sup 0.999em, sub 0.408em | unchanged (XeTeX-exact) |
| \sum limits | stacked | stacked (unchanged) |

Verification renders (SVG geometry at -s 30, extract_geom-style):
- `\textstyle\int_0^1 x\,dx`: ∫ at 17.744pt, sub `0` at +19.95pt, sup `1`
  at +29.91pt, following `x` at 48.31 — no ink overlap (sub/sup clear of
  the ∫ ink by ≥ 5pt).
- Full formula: display ∫ (limits) at 30pt unchanged; text ∫ at 17.744pt;
  the two ∫s visibly differ in the raster (ratio 1.55 in ink height).
- `zig build test`: 168/168 pass (regression goldens unchanged — no
  left-right or text-style big-op formulas in the corpus).
