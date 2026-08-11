# Fix: math-italic letters map to U+1D4xx (metrics + drawn glyphs)

## Problem
Math variables rendered as the UPRIGHT ASCII letters (U+0078 x, U+0069 i, …)
with the upright LM Math advances, while the XeTeX + unicode-math reference
typesets them as the MATH-ITALIC forms (U+1D465 𝑥, U+1D456 𝑖, …) with their
own advances. Both the layout widths and the drawn glyphs were wrong.

## Codepoint map (layout.zig `mathItalicCp`)
Applied in `layoutChar` and `layoutText` when the style is `.italic`
(default math variables) and the codepoint is an ASCII letter:

| ASCII | mapped | ASCII | mapped |
|---|---|---|---|
| A–Z (U+0041..005A) | U+1D434..U+1D44D | a–z (U+0061..007A) | U+1D44E..U+1D467 |
| h (U+0068) | **U+210E ℎ** | | |

`h` special case: U+1D455 (math-italic h) is UNASSIGNED in Unicode and absent
from Latin Modern Math; the math-italic h is U+210E ℎ (PLANCK CONSTANT).
Verified against real XeTeX + unicode-math: `$h$` emits `&#x210e;`, every
other letter `&#x1d4xx;` (mutool extraction of the xelatex PDF).

The box `cp` becomes the mapped codepoint, so:
- the FontContext / static metric lookup returns the math-italic advance,
- the SVG emits the math-italic character (box marked `synthetic`, like the
  `\cdot` override, so flatten dupes the mapped utf-8 into the glyph arena
  instead of aliasing the source bytes),
- the layout flows that read the box cp (superscript italic-correction,
  `displayOp`) see the mapped cp consistently.

Roman (`\text`, `\mathrm`, operator words) and bold (`\mathbf`) stay
UPRIGHT ASCII — the map only fires for `.italic`.

## Metrics (metrics.zig)
Added 51 rows (50 letters + U+210E) to `table`, `table7`, `table5` and
`ink_table` (all sorted positions; U+210E before U+210F / before U+2190 in
the 7pt/5pt bands):
- `w` = LM Math hmtx advance of the math-italic glyph (em × 10, measured
  with fontTools on latinmodern-math.otf) — the true math-italic advance,
- `h`/`d`/`ic` = the ASCII letter's row values (CM h/d/ic, unchanged), so
  the ink-adjacent metric box and the script italic-correction flow keep
  their values; only the advance (and drawn glyph) change,
- `ink_table`: the math-italic glyphs' own ink asc/desc (measured with
  fontTools BoundsPen; e.g. 𝑥 a=0.442 vs upright x 0.431 — the slanted
  form reaches higher), so the frame still bounds the drawn ink.

Fallback (spec point 2): `layoutChar`/`layoutText` query the mapped cp
first, then fall back to the ASCII entry's metrics when the mapped cp has
no metric (a font without the math-italic glyphs), then to `glyphEstimate`.
The static table keeps the U+0078 etc. rows — the no-font path works.

## Before/after advances (pt at 10pt; em × 10)
Evidence letters: x 5.28 → **5.72** (+0.44), i 2.78 → **3.45** (+0.67),
n 5.56 → **6.00** (+0.44), d 5.56 → **5.20** (−0.36). Full table:

| c | U+ | before | mapped | after | Δ | | c | U+ | before | mapped | after | Δ |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A | 0041 | 7.50 | 1D434 | 7.50 | +0.00 | | a | 0061 | 5.00 | 1D44E | 5.29 | +0.29 |
| B | 0042 | 7.08 | 1D435 | 7.59 | +0.51 | | b | 0062 | 5.56 | 1D44F | 4.29 | −1.27 |
| C | 0043 | 7.22 | 1D436 | 7.15 | −0.07 | | c | 0063 | 4.44 | 1D450 | 4.33 | −0.11 |
| D | 0044 | 7.64 | 1D437 | 8.28 | +0.64 | | d | 0064 | 5.56 | 1D451 | 5.20 | −0.36 |
| E | 0045 | 6.81 | 1D438 | 7.38 | +0.57 | | e | 0065 | 4.44 | 1D452 | 4.66 | +0.22 |
| F | 0046 | 6.53 | 1D439 | 6.43 | −0.10 | | f | 0066 | 3.06 | 1D453 | 4.90 | +1.84 |
| G | 0047 | 7.85 | 1D43A | 7.86 | +0.01 | | g | 0067 | 5.00 | 1D454 | 4.77 | −0.23 |
| H | 0048 | 7.50 | 1D43B | 8.31 | +0.81 | | h | 0068 | 5.56 | 210E | 5.76 | +0.20 |
| I | 0049 | 3.61 | 1D43C | 4.40 | +0.79 | | i | 0069 | 2.78 | 1D456 | 3.45 | +0.67 |
| J | 004A | 5.14 | 1D43D | 5.55 | +0.41 | | j | 006A | 3.06 | 1D457 | 4.12 | +1.06 |
| K | 004B | 7.78 | 1D43E | 8.49 | +0.71 | | k | 006B | 5.28 | 1D458 | 5.21 | −0.07 |
| L | 004C | 6.25 | 1D43F | 6.81 | +0.56 | | l | 006C | 2.78 | 1D459 | 2.98 | +0.20 |
| M | 004D | 9.17 | 1D440 | 9.70 | +0.53 | | m | 006D | 8.33 | 1D45A | 8.78 | +0.45 |
| N | 004E | 7.50 | 1D441 | 8.03 | +0.53 | | n | 006E | 5.56 | 1D45B | 6.00 | +0.44 |
| O | 004F | 7.78 | 1D442 | 7.63 | −0.15 | | o | 006F | 5.00 | 1D45C | 4.85 | −0.15 |
| P | 0050 | 6.81 | 1D443 | 6.42 | −0.39 | | p | 0070 | 5.56 | 1D45D | 5.03 | −0.53 |
| Q | 0051 | 7.78 | 1D444 | 7.91 | +0.13 | | q | 0071 | 5.28 | 1D45E | 4.46 | −0.82 |
| R | 0052 | 7.36 | 1D445 | 7.59 | +0.23 | | r | 0072 | 3.92 | 1D45F | 4.51 | +0.59 |
| S | 0053 | 5.56 | 1D446 | 6.13 | +0.57 | | s | 0073 | 3.94 | 1D460 | 4.69 | +0.75 |
| T | 0054 | 7.22 | 1D447 | 5.84 | −1.38 | | t | 0074 | 3.89 | 1D461 | 3.61 | −0.28 |
| U | 0055 | 7.50 | 1D448 | 6.83 | −0.67 | | u | 0075 | 5.56 | 1D462 | 5.72 | +0.16 |
| V | 0056 | 7.50 | 1D449 | 5.83 | −1.67 | | v | 0076 | 5.28 | 1D463 | 4.85 | −0.43 |
| W | 0057 | 10.28 | 1D44A | 9.44 | −0.84 | | w | 0077 | 7.22 | 1D464 | 7.16 | −0.06 |
| X | 0058 | 7.50 | 1D44B | 8.28 | +0.78 | | x | 0078 | 5.28 | 1D465 | 5.72 | +0.44 |
| Y | 0059 | 7.50 | 1D44C | 5.81 | −1.69 | | y | 0079 | 5.28 | 1D466 | 4.90 | −0.38 |
| Z | 005A | 6.11 | 1D44D | 6.83 | +0.72 | | z | 007A | 4.44 | 1D467 | 4.65 | +0.21 |

## Before/after render (`\int_0^1 x\,dx` at -s 48)
- before: `<text …>x</text>` at 90.052pt, `d` at 123.363pt, `x` at 150.051pt
  (advances x 25.34pt, d 26.69pt at 48pt).
- after: `<text …>𝑥</text>` at 90.052pt, `𝑑` at 125.475pt, `𝑥` at 150.435pt
  (advances x 27.46pt = 0.572em×48, d 24.96pt = 0.520em×48).

Artifacts (PIL raster via scripts/critique.py `rasterize_svg`, LM OTFs):
- `artifacts/fix-math-italic/render-before.png`, `render-after.png`
- `artifacts/fix-math-italic/render-zoom-before-left-after-right.png`
  (2× zoom of the x\,d\,x run; right half visibly slanted).

Slant evidence (objective, y-down pixels, `\int_0^1 x\,dx` at -s 48): mean
ink y of the x glyph per column third — before: right−left = +1.3px
(upright, symmetric); after: right−left = −6.0px (the upper strokes sit on
the right → the glyph leans right). Outline diff (fontTools BoundsPen, em):
x bbox h 0.431 → 𝑥 0.453 (the slanted ascender reaches higher); the glyphs
are different font records (U+0078 vs U+1D465).

## Verification
- `x` → `<text …>𝑥</text>`, box 5.72pt at -s 10 (12.72 − 2×3.5 pad).
- `\int_0^1 x\,dx` → ∫ 1 0 𝑥 𝑑 𝑥; advances x 5.72 / d 5.2 (26.5365 − 19.1567
  = 5.72 − thin 1.67 + d 5.2; second x − d = 5.2 ✓).
- `\sum x_i` → ∑ 𝑥 𝑖 at 10pt; x 5.72 (25.3267 − 19.6067), i 3.45em → 2.415pt
  at the 7pt script size (31.7417 − 3.5 = 14.44 + thin 1.667 + 5.72 + 2.415
  + 0.5 scriptspace ✓).
- `\frac{a+b}{c-d}` → 𝑎 + 𝑏 over 𝑐 − 𝑑.
- `\text{hello}` → upright `h e l l o`, `font-family="Latin Modern Roman"`
  + `font-style="normal"` ✓; `\mathrm{x}` → upright `x` ✓;
  `\mathbf{x}` → upright bold `x` ✓; `\sin x` → roman `s i n` + 𝑥 ✓.
- Font path (Context + embedded LM faces) and static default path agree:
  both emit 𝑥 with the 0.572em advance (`--font` probe and the static
  default render are bit-identical at -s 10).

## critique.py (scripts)
The geometric verifier measures each emitted codepoint's ink via
`cmap.get(ord(ch))` on latinmodern-math.otf; every mapped cp (U+1D4xx,
U+210E) IS in the LM Math cmap (u1D465 etc.), so it resolves natively. The
missing-glyph fallback (`gname is None` → box None → counted as "renders
nothing", advance 0.5em) covers any font that lacks a cp. The PIL
rasterizer draws the chars with the real OTF, so math-italic letters render
as their slanted shapes. No change needed to the script.

## Notes / out of scope
- 8 existing tests fail — ALL expected consequences of the intentional
  output change (parent regenerates goldens): `regression` draw-list + svg
  snapshots, `sanity` 'abc'/'x^2'/'x_2' byte asserts, `integration`
  superscript spans, `layout root.zig` "single char" unit test, `context`
  "font metrics match" (asserts `t.bytes == "x"` and 0.528em width; the
  font path now correctly returns 0.572em). No edits were made to tests or
  goldens per the file constraint.
- `src/layout/box.zig` Box.synthetic doc says "set true only in
  layout.layoutOp" — already stale for the `\cdot` override; now also stale
  for mapped letters. Comment-only; box.zig untouched per the constraint.
- Script superscript x placement is unchanged in logic (ic flow reads the
  box cp → the mapped row's copied ic); the sup moves right by the advance
  delta, which is the intended width change. XeTeX-parity of script
  placement belongs to the script-spacing ticket.
- `x^2` probe: sup at box edge + 0.16pt (the CM x ic 0.016em) — identical
  flow to before, now on the 5.72pt box.
