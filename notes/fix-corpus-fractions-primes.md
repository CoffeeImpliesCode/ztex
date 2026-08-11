# Fix: nested-fraction bars/gaps, prime placement, array dots/spacing

Corpus entries: NestedFractions, PrimeSpacing, ArrayMode (KaTeX screenshotter
corpus), all verified at `-s 30` against the XeTeX+unicode-math reference
(display style, `\fontsize{30}`, TeX Live 2025) and the KaTeX 0.16.28
reference. All measurements in pt at 30pt (rule centers; XeTeX rendered
values × 30/29.8879 to the nominal scale, since the LM Math font draws at
0.99626× the nominal size).

Files touched: `src/parse/parser.zig` (2 edits), `src/layout/layout.zig`
(2 edits). Nothing else. Regression goldens regenerate (the parent).

## 1. NestedFractions — outer display-fraction numerator gap (Δ 1.15 → 0.07)

Formula: `\dfrac{\frac{a}{b}}{\frac{c}{d}}\dfrac{\dfrac{a}{b}}{\dfrac{c}{d}}\frac{\frac{a}{b}}{\frac{c}{d}}`

Measured per nesting level (rule-center to rule-center / glyph-baseline gaps):

| gap | ours before | XeTeX | KaTeX | ours after |
|---|---|---|---|---|
| group1/3 outer num | 22.276 | 21.124 | 21.91 | **21.196** (Δ 0.07) |
| group1/3 outer den | 20.578 | 20.505 | 20.72 | 20.578 (Δ 0.07) |
| group1/3 inner num | 4.312 | 4.304 | 4.32 | 4.312 (Δ 0.01) |
| group1/3 inner den | 17.845 | 17.785 | 17.85 | 17.845 (Δ 0.06) |
| group2 inner (display) num/den | 12.795/28.079 | 12.764/27.978 | 12.81/28.08 | unchanged |
| group2 outer num/den | 32.609/30.255 | 32.491/30.158 | 32.14/30.07 | unchanged |

Rule thickness: ours 1.2pt = 0.04em × 30 = KaTeX (exactly 1.2); XeTeX draws
1.1954 (0.04em × 29.8879). No fraction in this formula is at script style,
so no rule thinning applies (TeX: rule = fontdimen8 of the symbol font at
the fraction's own size; display/text fractions → 0.4pt at 10pt, script
fractions → 0.28pt — ztex already scales by eff_size).

Root cause of the outer numerator gap: XeTeX's `make_fraction`
(xetexdir/xetex.web §17979) evaluates the OT gap-mins
(`fractionNumDisplayStyleGapMin` 0.12em, `fractionNumeratorGapMin` 0.04em)
with `cur_f` — the font of the LAST character processed before the clamp,
which after `clean_box(denominator)` is the denominator's last glyph. For a
nested-fraction denominator (`\frac{c}{d}` at text style), the last char `d`
is at the SCRIPT size, so the display numerator clamp uses 0.12em × 21 =
2.52 instead of 3.6. Verified three ways (box tree, controlled probes, full
formula): `\frac{\frac{a}{b}}{c}` clamps at 3.6 (denom char at text),
`\frac{\frac{a}{b}}{\frac{c}{d}}` at 2.52 (denom char at script),
`\frac{a}{\rule[-0.5em]{0pt}{2.5em}}` at 3.6 (a `\rule` is a box, no char —
cur_f stays the numerator's `a` at text), matrix text-style fractions at
0.04em × 21 = 0.84.

Fix: `layoutFraction` scales the clearance by `denomLastCharScale` — the
product of the part scales along the denominator's last-char path (a script
atom keeps its NUCLEUS size — measured `\partial x_1`: the sub `1` is at
scriptscript but the clamp uses the script size of `x`). Plain-char
denominators get scale 1.0 → `\frac{a}{b}`, `\frac{1}{2}` etc. are
byte-identical (168/168 tests pass, including the `\frac{1}{2}` golden).

## 2. PrimeSpacing — f_2' prime raise (Δ 5.0 → 0.04) and sub drop (Δ 0.45 → 0.001)

Formula: `f'+f_2'+f^{f'}`

| glyph | ours before | XeTeX | KaTeX | ours after |
|---|---|---|---|---|
| f' prime raise | 10.89 | 10.851 | 12.25* | 10.89 (Δ 0.04) |
| f_2' prime raise | **15.90** | 10.851 | 12.25* | **10.89** (Δ 0.04) |
| f_2' sub drop | **7.41** | 7.865 | 7.55* | **7.896** (Δ 0.03) |
| f^{f'} inner prime raise | 7.623 | 7.595 | — | 7.623 (Δ 0.03) |

\* KaTeX's own prime raise (0.413em sup1) and sub drop differ from XeTeX;
ours = XeTeX.

Root cause 1 (prime raise): the parser wrapped `f_2'` as `(f_2)′` — a nested
script — so the prime became a sup of the `f_2` BOX (raise = base_h −
supdrop = 15.90). TeX attaches both scripts to the same noad: `f_2'` is one
script node with sub `2` AND sup `′`, the prime raising by the char-nucleus
sup1 floor (0.363em × 30 = 10.89).

Fix: `parseAtom` merges a trailing prime into an existing SUB-ONLY script
node (children [base, prime, sub], data sup|sub); a script that already has
a sup (`x^2'`, `x_2^3'`) now errors `DoubleScript` (TeX's "Double
superscript"). `f'`, `{x_2}'` (group base), `f''` (U+2033) unchanged.

Root cause 2 (sub drop): once the prime is on the same noad, TeX's 4·rt
interspace rule applies between the prime's bottom (depth 0) and the `2`'s
top: sub drop = 13.986 (2 height) + 4.8 (4·rt) − 10.89 (raise) = 7.896,
matching XeTeX 7.895 exactly. (Before, the sub-only `f_2` had no sup, so no
interspace adjustment.)

Prime glyph: ztex ink table already gives U+2032 depth 0 (like XeTeX's box);
size 21pt (script) matches both refs. "prime smaller/less bold" is raster
antialiasing noise.

## 3. ArrayMode — \ddots codepoint + matrix cell style

Formula: the 4×4 Hessian `matrix`.

Fix A — `\ddots` was mapped to **⋰ U+22F0** (up-right diagonal) in the
parser command table; LaTeX `\ddots` is **⋱ U+22F1** (down-right). Both
XeTeX and KaTeX emit U+22F1. After the fix the vision critique reports "the
diagonal ellipsis is perfectly aligned, matching all references" (before it
was mirrored).

Fix B — matrix cell style. `layoutEnv` laid every cell out at the ROOT
style, so the matrix's `\frac` cells were DISPLAY style (parts at 30pt).
Measured XeTeX and KaTeX: amsmath `\array` (matrix/array/cases) typesets
every cell in TEXT style regardless of the enclosing style — the fraction
parts render at the SCRIPT size (21pt); only `aligned` keeps the current
style (its `\frac` parts at 30pt). Verified with `\displaystyle
\begin{matrix}\frac{a}{b}\end{matrix}` (parts 20.92pt) vs
`\displaystyle\begin{aligned}\frac{a}{b}&=1\end{aligned}` (parts 29.89pt).
Fix: `cell_style = if (kind == .aligned) style else .text`.

Result (row-baseline deltas = the "spacing between terms" nit):

| rows | ours before | XeTeX | ours after |
|---|---|---|---|
| 1→2 | 74.64 | 48.10 | **48.14** (Δ 0.04) |
| 2→dots | 54.68 | 42.51 | **42.48** (Δ 0.03) |
| dots→4 | 55.97 | 41.67 | **41.65** (Δ 0.02) |

Fraction cells: shift_up 13.25 / shift_down 11.16 (XeTeX 13.246/11.154) —
the text-style clearance (0.04em × 21 = 0.84, from the same
denominator-last-char rule as #1) applied to both clamps. `\vdots`/
`\cdots`/`\ddots` render as the same LM Math glyphs at 30pt as XeTeX; the
remaining "dots more/less spaced" nits are the vision comparing KaTeX's
COMPOSED dots (KaTeX builds `\vdots`/`\cdots` from separate dot glyphs with
its own spacing) against the LM single glyph — ours = XeTeX.

## Residuals (documented, not fixed)

- "fraction bar slightly thicker": ours = KaTeX (1.2pt) exactly; XeTeX
  1.1954 (0.4%). Raster antialiasing / vision noise, not layout.
- `x_1` sub drop in the matrix denominators: ours 5.19 vs XeTeX 6.126 vs
  KaTeX 6.68. XeTeX's 6.126 comes from a two-box digit-1 subscript box
  (sub.height 23.34 — a XeTeX/LM artifact); the plain `x_1` probe shows the
  normal sub1 drop (7.41 at 30pt, ours matches). Pre-existing script-metrics
  nuance, out of the fraction/dots scope.
- KaTeX's prime raise/sub drop and matrix row struts differ from XeTeX
  (0.413em sup1, no prime interspace, tighter rows); ours = XeTeX. The
  vision model attributes any ours-vs-KaTeX difference to ours.
- f^{f'} sup x-gap 2.37 vs XeTeX 2.70 (0.33pt at 30pt): the LM Math
  math-italic f MATH-table IC is 0.09em vs the metrics table's 0.079em
  (copied from the upright f). Within the 0.5pt budget; the general
  italic-correction table is FixLayoutFinal's scope.

## Verification

- `zig build test`: 168/168 pass (goldens for `\frac{1}{2}`, `x^2`, `x_2`,
  `\sum`, `\text`, `\mathbf` byte-identical).
- Corpus probe: 32/126 SUPPORTED (unchanged; NestedFractions/PrimeSpacing/
  ArrayMode already supported).
- Ref critique (scripts/critique.py --ref at -s 30, patched copy — the
  repo script needs `int(w_px * ss)` for PIL ≥ 11 float dims):
  - NestedFractions: "gap larger than XeTeX" nit Δ dropped 1.15 → 0.07pt
    (vision still reports it at 0.1px scale — noise); "baseline alignment
    vs XeTeX" nit gone.
  - PrimeSpacing: "prime higher"/"subscript 2 lower" nits resolved vs
    XeTeX (positions now within 0.04pt).
  - ArrayMode: \ddots "perfectly aligned, matching all references";
    "spacing between terms" now "consistent with XeTeX".
