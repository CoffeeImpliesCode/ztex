# Cases brace ink-span fix — FixCasesBrace

## Defect
`\begin{cases} x^2 & x > 0 \\ -x & x \le 0 \end{cases}` at 30pt: the leading `{`
(cases left brace) rendered only ~1 row tall (~30pt) instead of spanning both
rows (~90pt) like the references.

## Diagnosis (layout vs rasterizer)

Measured BEFORE any code change:

1. SVG font-size of the `{` = **30pt (base)** — by design. The ztex layout
   sizes a stretched delimiter's *box* from the smallest MATH variant whose ink
   covers the enclosed content, then emits the `<text>` at the BASE font size;
   the rasterizer is expected to reconstruct the variant from geometry — the
   same protocol used by paired `\left(...\right)`. (`zig build run` SVG:
   `<text ... font-size="30pt">{</text>`.)

2. The MATH variant the raster resolves for the `{` = **NONE** (empty
   `delim_targets`).

3. The LAYOUT is CORRECT: `layoutEnv` (`src/layout/layout.zig:1948-1976`) computes
   `req_em = 2.78em` from the two-row strut extent and `layoutDelimChar`
   (`src/layout/layout.zig:2156`) picks **braceleft.v7** (ink 3.0em). The env
   vbox box is h=52.5 / d=37.5 (90pt total); the SVG frame is 100.8pt (90 +
   2×2.4 pad + 6 linegap). Verified: `90 + 10.8 = 100.8 == /tmp/cases.svg height`.

4. XeTeX draws the cases brace at **base size (~29.89pt)** with the v7 variant
   glyph (ink 3.0em × 29.89 = 89.6pt). So the layout's base-font-size + v7 box
   MATCHES XeTeX. The defect is purely that the rasterizer never resolves the
   variant.

Root cause: `cases` has an open `{` but **no close** (`envCloseDelim(.cases)`
returns null, `src/parse/parser.zig:2032`). `_delimiter_targets` only resolves
delimiters that (a) pair with a matching close → "pair" mode, or (b) are
emitted at a scaled font-size (`\left\{...\right.` via `layoutDelimSized`) →
"scaled" mode. The cases brace is (a) unpaired AND (b) at base size, so it fell
through both and was drawn as the base glyph (30pt).

=> **Fix location: `scripts/critique.py` (B), not src/ (A).** The SVG is
correct; the rasterizer's `_delimiter_targets` sizes wrong.

## Change
`scripts/critique.py`, `_delimiter_targets` (new block 1012-1051, after the
"scaled" unpaired-fence loop): extend the gap→level recovery to UNMATCHED
opening delimiters emitted at the BASE size.

The layout flushes the enclosed array at the brace's variant ADVANCE, so the
x-gap from the opener to its first enclosed cell IS the chosen variant's
advance. The new loop matches that gap against the LM Math brace variant ladder
(within `DELIM_GAP_TOL_EM` = 0.02em) — exactly the existing `\big` level
recovery, just applied to an opener with no close partner. The brace resolves
to **level 7 (v7)** at the declared base size (mode "level": `size_v = size_pt`),
drawing the constant-stroke v7 glyph (ink = 3.0em × 30pt = 90pt) — filling the
layout's 90pt box, no stroke thickening, no clipping.

Docstring updated (lines 832 "FOUR", 857-865) to document the unmatched-opener
form.

Why not content-reconstruction ("pair" mode): the layout sizes from the
strut-inflated extent (2.78em → v7); glyph-ink reconstruction is tighter
(2.42em, fragile near v6's 2.4em threshold and diverges for 1-row cases). The
gap→level recovery reads the layout's exact choice, matching XeTeX robustly.

Scope: only unmatched-openers-at-base-size are affected (in practice: the cases
`{` and the degenerate unmatched `\big\{`). Paired `\left(...\right)` ("pair"),
scaled `\left\{...\right.` ("scaled"), and matched `\big(\big)` / env
delimiters ("level" via the pairs loop) are unchanged.

## Before / after vs refs (brace ink height, 30pt)

| pane   | before fix | after fix |
|--------|-----------:|----------:|
| OURS   | 29.62 pt   | 89.61 pt  |
| XeTeX  | 89.61 pt   | 89.61 pt  |
| KaTeX  | 89.99 pt   | 89.99 pt  |
| MathJax| 71.99 pt   | 71.99 pt  |

OUR vs XeTeX after: **90.00 pt (resolved variant) / 89.61 pt (rendered PNG),
Δ = 0.0 pt** — within the 1.5pt bar. (Geometric variant ink 90.0pt = 3.0em×30;
XeTeX renders v7 at 29.89pt ⇒ 89.6pt; 0.4pt from the 0.4% unit rounding.)

## Verification

- Brace spans both rows: content ink y-span [9.56, 81.21] pt ⊂ brace box
  [2.40, 92.40] pt. ✓ Both rows enclosed.
- `compute_geometry` on `/tmp/cases.svg`: `defects=0`, `clipped=[]` (clipping_pt
  all 0.0), `glyph_count=11`. No clipping, no box-intersection defects.
- Rasterizer (`rasterize_svg`) now draws the v7 PUA brace at base size; render.png
  brace ink = 89.61pt.
- No regressions on paired/scaled/matched-level delimiters:
  `\left(\frac{a+b}{c-d}\right)` → "pair" req 1.79em; `\left\{\frac{a+b}{c-d}\right.`
  → "scaled" req 2.24em (unchanged); `\bigl(x\bigr)`/`pmatrix` `[ ]`/`( )` → "level"
  (unchanged); `\big\{ x` (unmatched) → "level" v1 (was: base glyph).
- No Zig source changed (layout was already correct); `zig build run` builds and
  renders the formula unchanged. Only `scripts/critique.py` edited.
