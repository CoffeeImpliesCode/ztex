# ztex vs XeTeX: glyph-alignment comparison (10pt scale-matched)

Run 2026-08-12. `scripts/compare_engines.py --ours /tmp/cmp/ztex_i.json --ref /tmp/cmp/xetex_i.json`.
Both engines rendered at 10pt base. Deltas: dx>0 = ours right, dy>0 = ours up, dxi = dx / ref glyph size.

## Recipe (scale fix)
- `scripts/extract_geom.py`: ztex render `-s 10` (was `-s 20`), `BASE_SIZE["ztex"]` 20.0 -> 10.0, docstring updated.
- Re-rendered /tmp/cmp/ztex_{1..7}.json at 10pt. Glyph sequences identical to the 20pt run (counts match);
  sizes exactly halved (10/7/20 pt). Verified against the original 20pt JSONs.

## Math-symbol equivalence (fix)
`scripts/compare_engines.py`: added `MATH_EQUIV` map applied before NFC in `glyph_normeq`:
`⋅ U+22C5 -> · U+00B7`, `− U+2212 -> - U+002D`, `∕ U+2215 -> /`, `∖ U+2216 -> \`,
`∗ U+2217 -> *`, `′ U+2032 -> '`. XeTeX emits plain codepoints (·, −), ztex math codepoints (⋅, −);
previously the dot/moins paired as false 'missing' on both sides. Selftest: 35 checks pass (2 new).

## Per-formula stats (ztex ours, XeTeX ref; baseline first-top)
| i | formula          | pairs | ours/ref unmatch | style | mean\|dx\| | max\|dx\| | max\|dxi\| |
|---|------------------|-------|------------------|-------|------------|-----------|-------------|
| 1 | x^2              | 2     | 0 / 0            | 0     | 0.261      | 0.521     | 0.075       |
| 2 | x_2              | 2     | 0 / 0            | 0     | 0.261      | 0.521     | 0.075       |
| 3 | \frac{a+b}{c-d}  | 6     | 0 / 0            | 6     | 3.345      | 7.071     | 1.014       |
| 4 | \sum_{i=1}^{n} x_i | 6   | 1 / 1 (n reorder)| 0     | 4.470      | 7.583     | 1.087       |
| 5 | a\cdot b         | 3     | 0 / 0            | 0     | 0.025      | 0.046     | 0.005       |
| 6 | \int_0^1 x\,dx   | 5     | 1 / 1 (0 reorder)| 0     | 2.713      | 3.670     | 0.526       |
| 7 | x^2+y^2          | 5     | 0 / 0            | 0     | 0.296      | 0.521     | 0.075       |

Threshold: >0.5pt or >0.05 normalized counts as a real discrepancy.

## Ranked real discrepancies (vs XeTeX)
1. **Fraction contents not shrunk to script style** (formula 3). All 6 glyphs 10.0pt vs XeTeX 7.0pt
   (ratio 1.43, 6/6 style mismatches). Denominator baseline 6.27pt lower; horizontal drift
   accumulates to +7.07pt on `b` (dxi 1.01). ztex sets \frac at text size; TeX uses \scriptstyle (0.7x).
2. **Big operators rendered at 2x base size** (formulas 4, 6). ztex ∑/∫ at 20pt vs XeTeX 10pt
   (size_ratio 2.01). Cascades: limit rows land 15.82pt lower than TeX (dyi up to 2.27) and the
   whole post-operator run shifts ~3.3-4.5pt left.
3. **Limit placement differs** (formulas 4, 6). ztex centers limits on the operator axis; TeX sets
   both limit rows at the same x (~10.5pt right of the operator's left edge). Lower-limit row is
   4.8-7.6pt left of TeX; upper `n` (formula 4) and `0` (formula 6, TeX staggers 0/1 horizontally,
   ztex stacks them) become reorders in the NW alignment. Partly a consequence of #2.
4. **Superscripts raised ~0.51pt higher and advanced ~0.52pt right** (formulas 1, 2, 7; dxi 0.075).
   ztex: raise 4.13pt / advance 6.22pt; TeX: 3.62pt / 5.69pt. Subscript depth matches (formula 2
   dy = -0.006pt), only its x-advance is 0.52pt off. Small but consistent, > threshold.

## Clean
- **Formula 5 (a\cdot b): max|dx| = 0.046pt, max|dxi| = 0.005, 0 unmatched.** The scale fix + math
  equivalence removed the entire prior artifact (was max|dx| = 12.55pt with false-missing ⋅/·).
- XeTeX glyph sizes 9.96/6.97pt vs exact 10/7 are mutool's PDF matrix scale (0.9963) — unit
  artifact, negligible.

## Single most impactful
**ztex's ∑/∫ are 2x XeTeX's size (20pt vs 10pt em)**, which corrupts the two multi-row formulas:
limits drop 15.8pt too low (max dyi 2.27) and the whole formula shifts up to 7.6pt left — the
largest absolute (7.6pt) and normalized (2.27) errors on the corpus. Fixing operator scaling to 1x
should also pull limit placement toward TeX's. Second candidate: missing script-style shrink in
\frac (formula 3, 6/6 mismatches, max dx 7.07pt).
