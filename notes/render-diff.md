# ztex vs MicroTeX — adversarial render diff (20pt)

Date: 2026-08-12. Both rendered at 20pt. ztex: `zig-out/bin/ztex -i F -s 20 -b white`.
MicroTeX: `clatexmath -headless`. SVGs + rasters in `/tmp/ztex_diff/`.
ztex draws glyphs as `<text x y font-size>`; MicroTeX as `<use x y>` + defs path bboxes.
Glyph ink extents: MicroTeX from defs bbox; ztex from 1x resvg raster. Fonts: both Latin
Modern (C-Modern / LMM). Layout now renders in `.display` (big-op limits + full-size frac).

## Per-formula (px @20pt; delta = ztex − MicroTeX; >1px flagged)

| # | Formula | Metric | ztex | MicroTeX | Δ |
|---|---------|--------|------|----------|---|
| 1 | `a+b` | glue a→+ (med) advance | 15.02 | 15.02 | 0.00 ✅ |
| 1 | `a+b` | glue +→b (med) advance | 20.00 | 20.00 | 0.00 ✅ |
| 2 | `x=y` | glue x→= (thick) advance | 16.99 | 16.98 | +0.01 ✅ |
| 2 | `x=y` | glue =→y (thick) advance | 21.11 | 21.12 | −0.01 ✅ |
| 3 | `x^2` | sup raise (base−sup y) | 8.26 | 8.26 | 0.00 ✅ |
| 4 | `x_2` | sub drop (sub−base y) | 3.00 | 3.00 | 0.00 ✅ |
| 5 | `\frac{a}{b}` | num ink→rule top | 13.74 | 8.31 | **+5.43 ❌** |
| 5 | `\frac{a}{b}` | den ink→rule bottom (clearance) | −0.54 (overlap) | +4.84 | **−5.38 ❌** |
| 6 | `\frac{a+b}{c-d}` | num row a→+/+→b advance | 15.02/20.00 | 15.02/20.00 | 0.00 ✅ |
| 6 | `\frac{a+b}{c-d}` | den row c→-/−→d advance | 13.09/20.00 | 13.09/20.00 | 0.00 ✅ |
| 6 | `\frac{a+b}{c-d}` | num/den vs rule | same +5.4/−5.4 as #5 | | **❌** |
| 7 | `\sum_{i=1}^{n}` | op glyph height | 28 | 28.00 | 0.00 ✅ |
| 7 | `\sum_{i=1}^{n}` | limits centered (box) | ✓ (n @∑-ctr 16) | ✓ (24.4) | ✅ |
| 7 | `\sum_{i=1}^{n}` | op-top→upper-limit gap | ~4.0 | 5.85 | **−1.85 ⚠** |
| 8 | `\int_0^1` | op glyph height | 28 | 44.44 | **−16.44 ❌** |
| 8 | `\int_0^1` | limit placement | centered over box | upper-R of tall ∫ | differs (both non-TeX) |
| 9 | `x^2+y^2` | glue x→+ / +→y advance | 23.38/20.00 | 23.38/20.00 | 0.00 ✅ |
| 9 | `x^2+y^2` | sup raise | 8.26 | 8.26 | 0.00 ✅ |
| 10 | `\text{hi}` | baseline (single row) | 13.9 | 23.89 | ✅ |
| 10 | `\text{hi}` | h→i advance | 11.50 | 11.11 | +0.39 ✅ |
| 11 | `a\cdot b` | **unsupported** | — | renders | `UnknownCommand` (no `\cdot` in cmd_map) |

## Ranked remaining discrepancies (>1px)

1. **Fraction rule drawn on the baseline, not on the math axis (~5px).** `layout.zig`
   `layoutFraction`: the rule leaf is placed at `.shift = 0` (the vbox reference
   baseline), but the clearance math above it (`kern1 = shift_up − nb.depth − (axis +
   Δ)`, `kern2 = (axis − Δ) − (db.height − shift_down)`) already assumes the rule sits on
   the axis (`axis_height = 2.5 → 5px @20pt`). MicroTeX places the rule on the axis and
   measures num1/denom1 from it, so its num→rule = 13.53 − 5 = 8.53. ztex keeps the full
   num1=13.53 above the rule. Net: numerator floats **+5.4px high**, denominator is
   **−5.4px too close** — the denom ascender actually punches ~0.5px THROUGH the 0.8px bar
   (`denom1` 13.3 < b-height 13.5). Affects every `\frac` (corpus #5, #6). Fix: place the
   rule at `shift = −axis`.
2. **`\int` display op 37% too small.** ztex renders every display big-op as the plain
   codepoint at `font-size = 2×` (layoutOp, factor 2.0), giving ∑=28px (coincidentally =
   MicroTeX display ∑) but ∫=28px vs MicroTeX's 44.44px display ∫. MicroTeX picks a
   per-symbol “next-larger” variant; ztex's uniform 2× approximation is only correct for ∑.
   Affects `\int` (#8).
3. **Big-op upper-limit gap ~1.9px tight (minor).** ∑ op-top→n gap ztex ~4.0 vs MicroTeX
   5.85 (`bigop1/bigop3`); sub-gap also tighter. Below the 5px-class issues but >1px.

## Overall verdict

Inter-atom glue, script raise/lower, ∑ display size, and limit centering are now correct
(match MicroTeX/TeX). The two ≥5px visual errors left are the fraction vertical stack
(rule not on the axis) and the undersized `\int` display operator. The **single most
impactful** remaining difference to fix is #1: the fraction rule must sit on the math
axis — a one-line `shift` change that fixes every `\frac`'s num/den placement and the
denominator bar-punch-through.
