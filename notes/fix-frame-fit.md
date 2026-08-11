# Fix: normal-glyph boxes from the DRAWN LM-Math ink — frame fits all ink

Date: 2026-08-13. Scope: `src/layout/metrics.zig` (ink table + `glyphInk`),
`src/layout/layout.zig` (`layoutChar`, `layoutText`). Follow-up to
`fix-pipeline-ink.md` (FixInk) and `fix-bigop-width.md` (FixBigOpWidth),
which fixed the BIG-OP boxes to the drawn ink; this extends the same
treatment to NORMAL glyphs. INTENTIONAL output change — goldens regenerate;
tests/goldens untouched. SKIP gates (no build/test/fmt; only the build
compile check below).

## Root cause

`layoutChar`/`layoutText` boxed every normal glyph with the cmr10/cmmi10
METRIC height/depth (e.g. digit h = 6.44444×size/10, `x` h = 4.30555×size/10)
while DRAWING the Latin-Modern-Math glyph, whose ink pokes past that
Computer-Modern design box. The draw-list height/depth (max over boxes) and
the SVG viewBox are therefore smaller than the drawn ink, and the frame
clips ink at the top/bottom. The task spec's blanket "ink ascends ~0.75em /
descends ~0.25em" (the LMMath font ascender/descender, hhea 806/−194) is
only an UPPER bound: per-glyph measurement (Approach A) shows the real ink
is much tighter (digits 0.666/0.022, `x` 0.431/0.000, `n` 0.442/0.000) —
the blanket bound would have padded every line with ~0.6em of dead space.

## Method

fontTools `BoundsPen` on `latinmodern-math.otf` (the lmodern-2.005 Nix
package at
`/nix/store/whmfn34z3b5hdihz7zqinlwkw5gv9l6g-lmodern-2.005/.../latinmodern-math.otf`;
font internal version 1.959, same file FixInk/FixBigOpWidth measured) —
CFF outline bounds, upem 1000, per-mille → em of the glyph font-size:
ascent = yMax/upem, descent = −yMin/upem (clamped ≥ 0). Every codepoint in
the metrics tables (`table`, `table_roman`, `table7/5`, `table_roman7/5`,
`display_ops`) was measured — 317 unique codepoints, 312 with LMMath
glyphs; the 5 absent (Ϝ U+03D8, ▹ U+25B9, ◃ U+25C3, ⤒ U+2912, ⧫ U+29EB)
fall back to the font bound. The big-op rows reproduce the existing
`bigOpInk` table exactly (∫ 0.805/0.306, ∑ 0.750/0.250, ⋂ 0.772/0.250,
⋃ 0.750/0.272, ⨆ 0.764/0.264) — same font, same pen, cross-checked.

### Measured ink (em) — common glyphs

| glyph | asc | desc | glyph | asc | desc |
|---|---|---|---|---|---|
| digits 0–9 | 0.666–0.677 | 0–0.022 | b d h k l | 0.694 | 0–0.011 |
| x | 0.431 | 0.000 | y | 0.431 | 0.205 |
| i | 0.657 | 0.000 | g p q | 0.442–0.453 | 0.194–0.206 |
| n | 0.442 | 0.000 | ( ) [ ] { } \| / | 0.748–0.750 | 0.248–0.250 |
| = | 0.367 | 0.000 | + − | 0.583/0.270 | 0.083/0 |
| , ; | 0.106/0.431 | 0.193 | A–Z | 0.677–0.716 | 0–0.022 |
| ∫ ∮ | 0.805 | 0.306 | ∑ ∏ ∐ | 0.750 | 0.250 |

## The change

`metrics.zig`:

- `GlyphInk { asc, desc }` (em) next to `Glyph`.
- `ink_table` (~317 rows, sorted by `cp`) after `table_roman5`: measured
  asc/desc for every metric-table codepoint.
- `pub fn glyphInk(cp) GlyphInk`: binary search over `ink_table`; the
  LMMath design bound `{ 0.750, 0.250 }` for codepoints without measured
  ink (ams-only symbols, CJK, … — safe for the browser fallback fonts).

`layout.zig`:

- `layoutChar`: box `height = ink.asc × size_pt`, `depth = ink.desc ×
  size_pt`; WIDTH stays `s(g.width, size_pt)` — the metric-table advance is
  a spacing fact and is untouched (only height/depth change, per spec).
- `layoutText`: same for `\text` grapheme boxes (roman text renders in
  LMRoman whose ink is ≤ the LMMath bound; box uses the same ink).
- Unknown-codepoint fallback boxes (CJK, glyphEstimate path) also use
  `glyphInk` → the 0.750/0.250 bound (was 0.7em/0.15em).

Because every placement site (row, fraction, script, limits) reads box
dimensions and the char-base script floors ignore base h/d (`sup_base`/
`sub_base` = 0 for char nuclei — tex.web make_scripts), the only visible
changes are: (a) the accumulated height/depth — the frame; (b) TeX
clearance enforcement in fractions/limits, which now measures from the
real ink. For this repro the fraction parts did NOT move (LMMath `n` ink
0.442em ≈ cmr10 0.4306em ⇒ kern2 still ≥ 3·rt) and every script floor was
unchanged (ink tops of `i`/`0`/`1` ≈ their CM box tops at script sizes).

## Before/after box height/depth for the repro glyphs (`-s 20`)

| glyph | size | before h / d (cmr10/cmmi10 × size/10) | after h / d (ink × size) |
|---|---|---|---|
| ∫ sup `1` | 14 | 9.022 / 0 | 9.324 / 0.000 |
| ∫ sub `0` | 14 | 9.022 / 0 | 9.324 / 0.308 |
| ∑ sub `i` | 14 | 9.233 / 0 | 9.198 / 0.000 |
| ∑ sub `1` | 14 | 9.022 / 0 | 9.324 / 0.000 |
| ∑ sub `=` | 14 | 5.136 / −1.864 | 5.138 / 0.000 |
| ∑ over `n` | 14 | 6.028 / 0 | 6.188 / 0.000 |
| frac den `n` | 20 | 8.611 / 0 | 8.840 / 0.000 |
| frac num `x` | 20 | 8.611 / 0 | 8.620 / 0.000 |
| `d` (x\,dx) | 20 | 13.889 / 0 | 13.880 / 0.220 |

## Frame-bounds verification (`\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`, `-s 20`)

Before: frame 147.324 × **54.67** (∫ script box h 33.77 = 24.7478 shift +
9.022 box; ∑ vbox depth 20.90 = 9 + 1.667 k + 9.233 sub + 1.0 bigop5) —
the ∫ sup `1` ink (9.324) exceeded the 33.77 box by 0.30pt and the frame
clipped the top; the ∑ sub row (baseline 53.67, −1.86–0.30pt ink below it
in fallback fonts) clipped the bottom.

After: frame 147.32399 × **55.06247** (∫ script box h 34.0718 = 24.7478 +
9.324 ink; ∑ vbox depth 20.9907 = 9 + 1.667 + 9.324 + 1.0). Width unchanged
(147.324 — every advance came from the untouched metric widths).

Every `<text>` primitive's ink bounds (fontTools BoundsPen, same font)
checked against the viewBox — **0 violations**:

- ∫ sup `1` (y=9.324, 14pt): ink top = 9.324 − 0.666×14 = **0.000** ≥ 0 ✓
  (was −0.30pt past the old 33.77 box).
- ∑ sub `i` (y=54.062, 14pt): ink bottom = 54.062 + 0.000 = 54.062 ≤
  55.06247 ✓ (old: baseline 53.67, 1.0pt margin but ink-bottom depended on
  the fallback font's descender).
- ∫ sub `0`: bottom 52.100 ✓; fraction, `+`, `x\,dx`: all inside ✓.

### The other 4 defects stay fixed (re-verified on the new output)

1. ∑ over-limit `n` centered over the ∑ ink: n center 13.202 vs ∑ ink
   center 13.202 — Δ = **0.000pt** (widths unchanged).
2. ∑ clears the next term: fraction starts 30.937, ∑ ink+thin glue ends
   29.737 — gap **1.200pt**.
3. ∫ sup `1` at ink + italic correction: x = 73.336 + 22.120 (ink) +
   4.44446 (dop.ic) = 99.900 — rendered x 99.900, Δ = **0.000pt**.
4. Subscripts fully visible: ∑ sub `i` bottom 54.062 and ∫ sub `0` bottom
   52.100 both ≤ frame height 55.06247 ✓.

## Notes

- The box is exactly tangent at the top (∫ sup `1` ink top = 0.000 by
  construction: shift_up + ink_asc = the script box height). No viewBox
  margin added (spec: draw/svg only if needed; the measured ink satisfies
  the ≥ 0 / ≤ height acceptance exactly).
- `\text{hi}` (20pt): 13.88 vs 13.89 before — LMRoman ink ≈ cmr10 metrics,
  no visual change; CJK fallback boxes grow 0.7/0.15em → 0.75/0.25em (the
  sanctioned font bound).
- The 5 unmeasured codepoints (Ϝ ▹ ◃ ⤒ ⧫) get the 0.750/0.250 bound —
  they draw from the browser's fallback fonts, and the bound is safe for
  those.
