# Cumulative horizontal drift fix (multi-element rows vs XeTeX)

Date: 2026-08-12 · Files: `src/layout/layout.zig`, `src/layout/metrics.zig`

## Symptom

In multi-element display formulas each successive atom lands progressively LEFT
of XeTeX (up to ~3pt by the end of `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1
x\,dx` at 10pt). Vertical was already fine (max|dy| 0.08pt).

## Isolation (progressive prefixes, 10pt display, ztex vs XeTeX SVG)

Measured inter-element advances (TeX pt; xetex PDF coords × 1.00375):

| transition | ztex | XeTeX | deficit |
|---|---|---|---|
| sum-limits → next (1→x in p1) | 5.17 | 6.37 | −1.20 |
| sum-limits → frac (1→x in p5) | 5.17 | 7.57 | −2.40 |
| frac → ord (n→x in p2) | 8.98 | 8.69 | +0.29 |
| frac → bin (n→+ in p4) | 9.54 | 10.90 | −1.37 |
| + → ∫ | 10.00 | 9.96 | +0.04 |
| ∫ → 1, 1 → 0 | 10.00, −4.44 | 9.96, −4.43 | ~0 |
| 0 → x (script-combo tail) | 10.11 | 10.56 | −0.45 |

The drift entered at TWO transitions: the post-limits-op advance (sum → next)
and the post-fraction advance (frac → bin). The ∫ block was internally
consistent (constant inherited shift).

## Root causes (all verified against XeTeX \showbox + tex.web, not guessed)

1. **Script-style glue was NOT suppressed.** ztex's glue table applied
   med/thick in ALL styles. TeX (tex.web §799 string `"0234…"`) suppresses
   med/thick AND the conditional thins in script/scriptscript — only ord↔op
   and close→op keep thin. Consequence: the subscript `i=1` was glued
   (2.41+1.94+5.44+1.94+3.50 = 15.24pt), so the limits vbox grew to 15.24
   instead of TeX's op width 14.44447. TeX's limits vbox width = max(op, sup,
   sub) where the unglued sub `i=1` = 12.95pt < op → vbox = 14.44447, sub
   content centered. The post-sum advance under-shot because ztex's vbox was
   too wide AND the last sub glyph sat at the box edge instead of centered.

2. **Script-size glue uses the script symbol font's quad.** TeX: 1mu =
   quad/18 of \scriptfont2. cmsy7 quad = 1.170641em (not 1.0em), so thin at
   7pt = 3/18 × 1.170641 × 7 = 1.3657pt, not 1.1667pt. Same for scriptscript
   (cmsy5 quad 1.472241em).

3. **Fractions have no null-delimiter padding.** TeX wraps a delimiter-less
   \over/\atop in two \nulldelimiterspace boxes: row box = 1.2 + max(num,den)
   + 1.2 (fixed 1.2pt, unscaled in scripts). ztex's frac box was 2.4pt too
   narrow → frac→bin under-advanced by ~1.4pt (also frac→rel/→ord glue
   changes).

4. **A \over fraction is an ORD noad, not inner.** tex.web §14981:
   fraction_noad falls through to `t := ord_noad`. Measured: `{x\over n} x`
   has NO glue, `{x\over n} + y` gets med. Only \left..\right are inner.
   ztex's frac→ord thin glue was wrong (p2 was +0.29 over).

5. **Script-size font metrics are optically scaled, not 0.7×10pt.** TeX uses
   cmr7/cmmi7/cmsy7 (design 7pt), whose relative metrics differ from cmr10/
   cmmi10/cmsy10: cmmi7 i = 0.404185em (vs 0.344513), cmr7 '=' = 0.876988em
   (vs 0.777781), cmr7 '1' = 0.5694475em (vs 0.5), etc. This shifted every
   script glyph and scripted-box width (x_i num, ∫ sup/sub, the limits sub).
   Also: '='/'+' come from family 0 (cmr), not cmsy, in this TeX Live.

6. **Big ops at script size are NOT scaled.** TeX Live has no cmex7/cmex5;
   \scriptfont3 = cmex10@10. `x_{\sum}` renders ∑ at 10pt scale, box
   10.55559pt even at 7pt (measured).

7. Two wrong 10pt metrics in the table: P = 6.42014 (was 6.92014, measured)
   and ω = 6.22455 (was 6.51392; cmmi slot 33 = 0.622455em).

## Fixes

`src/layout/layout.zig`:

- **glue_table**: exact tex.web digits → nibbles
  (0 none, 1 = conditional thin display/text only, 2 = thin always,
  3/4 = med/thick display/text only). ord→op/op→ord/close→op stay thin in
  scripts; everything else med/thick/thin-conditional suppressed there.
- **quadEm(style)**: script glue width = units/18 × quad × size_pt with
  quad 1.170641 (script) / 1.472241 (scriptscript) / 1.0 (display/text).
- **leftRole/rightRole**: `.fraction => .ord` (was .inner).
- **layoutFraction**: pad the row box with 2 × 1.2pt (\nulldelimiterspace);
  children shift +1.2pt; rule spans the inner max(num,den) width only.
- **layoutOp** non-display branch: use the cmex10 table values UNSCALED and
  glyph_size = 10.0 (TeX has no cmex7/5; script ops render at 10pt).
- **layoutChar / layoutScript (sup_ic) / layoutText**: use the new size-aware
  `metrics.glyphAt` lookup.

`src/layout/metrics.zig`:

- New `table7` (201 entries) and `table5` (201 entries): real cmr7/cmmi7/
  cmsy7 and cmr5/cmmi5/cmsy5 TFM metrics (em×10 convention), slots from
  plain.tex mathchardefs; composites (≠ ∉ ≢ ⋯ ″ ↦) composed from real 7pt/5pt
  parts; ams/stmary/cmex fall back to the 10pt table (linear).
- New `pub fn glyphAt(fm, cp, style, size_pt)`: picks table7 at ≈7pt, table5
  at ≈5pt, else the 10pt table; values stay in the 10pt-base convention so
  the existing `s(v, size_pt)` scaling lands on true points.
- Fixed P (6.42014) and ω (6.22455) in the 10pt table.

## Result (10pt display, p5 = full formula)

Per-glyph dx (ours − ref, pt): all glyphs within ±0.01pt (last glyph was
−3.03pt before, +0.01pt after). Inter-element advances match XeTeX to ≤0.01pt
everywhere (p1..p5). Corpus (`x^2`, `x_2`, `\frac{a+b}{c-d}`,
`\sum_{i=1}^{n} x_i`, `a\cdot b`, `\int_0^1 x\,dx`, `x^2+y^2`): worst |dx|
0.01pt.

## Notes / out of scope

- TeX appends the italic correction of an unscripted char with ic ≠ 0 as a
  kern after it (tex.web make_math). No corpus glyph has ic ≠ 0 in a row
  position, so it doesn't affect these measurements; left for a future pass.
- TeX's scripted-char box = base + separate script combo; ztex's single-box
  model is equivalent for advances (verified), so layoutScript needed no
  structural change — only the metrics feeding it.
- Gates skipped per instructions; goldens will regenerate.
