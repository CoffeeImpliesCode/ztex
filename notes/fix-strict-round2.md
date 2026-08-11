# fix-strict-round2 — draw display big-ops at the XeTeX MATH-variant scale

Formula `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`, ours at 48pt and 10pt
(ztex) vs XeTeX+unicode-math at the same size. Round 1 fixed the limits/scripts/
advance geometry (≤0.2pt vs the reference) but left the two REAL visual nits:
the drawn ∑/∫ were the cmap BASE glyph at the design size while XeTeX draws the
MATH-table display VARIANT (summation.v1, integral.v1) — ∑ 45.26×48.0 vs ref
63.65×66.97, ∫ 26.54×53.33 vs ref 42.42×106.24 at 48pt.

Round 2: keep the box/limits geometry AT DESIGN (the variant extents × size_pt,
exactly round 1's box tree) and set the DRAWN font-size of display big-ops to
size_pt × a per-op variant scale. The SVG `<text font-size>` is the only thing
that changes — every x/y and every other size is byte-identical.

## Change (EDIT ONLY src/layout/layout.zig — `layoutOp`)

The box stays: `width = ink.advance × size_pt`, `height/depth = ink.asc/desc ×
size_pt` with `ink = bigOpInk(op, style == .display)` — identical to round 1
(display ops box by the display-variant extents, all other styles by the base
extents). The Text `size` field (the SVG font-size, and thus the PIL-drawn
size) is now, for DISPLAY big-ops only:

```
glyph_size = size_pt × (variant.asc + variant.desc) / (base.asc + base.desc)
```

i.e. the base glyph is drawn at the scale that makes its ink HEIGHT equal the
display variant's ink height. Non-display styles keep `glyph_size = size_pt`
(XeTeX draws the base glyph for text/script/scriptscript big-ops).

### Per-op variant scales (measured)

Computed from the .v1 extents already in `bigOpInk` (layout.zig) — the exact
ratio is variant ink height ÷ base ink height:

| op | base ink (asc/desc) | .v1 ink (asc/desc) | scale |
|----|--------------------:|-------------------:|------:|
| ∑ (sum) | 0.750 / 0.250 | 0.950 / 0.450 | **1.4** |
| ∏ / ∐ (prod/coprod) | 0.750 / 0.250 | 0.950 / 0.450 | **1.4** |
| ⋃ (bigcup) | 0.750 / 0.272 | 0.917 / 0.439 | 1.327 |
| ⋂ (bigcap) | 0.772 / 0.250 | 0.939 / 0.417 | 1.327 |
| ⨆ (bigsqcup) | 0.764 / 0.264 | 0.936 / 0.436 | 1.335 |
| ∫ / ∮ (int/oint) | 0.805 / 0.306 | 1.361 / 0.861 | **2.0** |

Independent check, measured rendered-ink ratios ref/ours at 48pt: ∑ 66.97/48.0
= 1.395, ∫ 106.24/53.33 = 1.992 — the same values within raster rounding
(0.4%). The code derives the scale from the bigOpInk data (per-op, no magic
constants).

## Before/after drawn ink (fontTools ink bbox at the emitted font-size)

| size | glyph | before (round 1) | after (round 2) | XeTeX ref | Δ after |
|------|-------|-----------------:|----------------:|----------:|--------:|
| 48pt | ∑ | 45.26 × 48.00 | **63.37 × 67.20** | 63.65 × 66.97 | −0.28w, +0.23h |
| 48pt | ∫ | 26.54 × 53.33 | **53.09 × 106.66** | 42.42 × 106.24 | **+10.67w**, +0.42h |
| 10pt | ∑ | 9.43 × 10.00 | **13.20 × 14.00** | 13.26 × 13.95 | −0.06w, +0.05h |
| 10pt | ∫ | 5.53 × 11.11 | **11.06 × 22.22** | 8.84 × 22.13 | **+2.22w**, +0.09h |

The HEIGHT (the "bolder/taller" nits 1/6) now matches the reference to ≤0.5pt
at 48pt and ≤0.1pt at 10pt. The ∑ WIDTH also matches (≤0.5pt). The ∫/∮ WIDTH
does not: the base ∫ aspect (0.553/1.111 = 0.498) differs from the .v1 aspect
(0.884/2.222 = 0.399), so the height-matched uniform scale draws it ~25% too
wide (round 1 already measured this: height-match 2.0× → 10.7pt too wide at
48pt; width-match 1.604× → height 20% short). A single font-size scalar cannot
reproduce the .v1 proportions.

## Verification

### Limits/scripts/advance geometry UNCHANGED (the box tree is untouched)
Per-glyph content coordinates (svg x/y minus the frame pad) round-1 vs round-2:
worst delta **0.000035pt at 48pt**, **0.000002pt at 10pt** (float noise). The
round-1 measured values reproduce exactly: ∑ sub `i=1` raise 51.99, ∑ sup `n`
55.20, ∫ sup `1` 56.93, ∫ sub `0` 48.05 — the reference deltas stay ≤0.2pt.
The only SVG diffs are the font-size attributes of the display big-ops (48→67.2
and 48→96 at 48pt; 10→14 and 10→20 at 10pt) and the frame, which grows because
svg.zig's margin is 0.35 × max_size and max_size is now the scaled op size.

### Frame bounds the bigger ink (verified, no svg.zig change needed)
The drawn base glyph at scale pokes above the box top (the base ink split
75/25 and 72/28 differ from the variants' 68/32 and 61/39): ∑ pokes 0.1em,
∫ 0.249em of size_pt above its box top. The margin 0.35 × max_size (max_size
now = the scaled op size) covers it: 0.35×1.4 = 0.49em vs 0.1em poke, 0.35×2.0
= 0.70em vs 0.249em poke. critique.py geometry: **clipping 0 on all four edges
at 48pt and 10pt** (48pt: ink_bbox [37.36, 33.60, 365.19, 164.90] inside the
399.37×217.70 viewBox; 10pt: [7.78, 7.00, 78.77, 34.35] inside 85.89×45.35).
The drawn ink bottom sits INSIDE the box depth (base desc × scale < variant
desc), so no bottom adjustment is needed.

### Critique (`scripts/critique.py --ref`, 48pt, same-size XeTeX ref)
notes/critique-ref-4.md: **nits 1 (∑ size) and 6 (∫ size) are GONE.** The 8
remaining nits are all `minor` and are round 1's sub-pixel set (∑ limits
±0.2pt, fraction/integrand glyph advances, + spacing) plus one new minor
("∫ appears slightly thinner" — the base glyph strokes are thinner than the
.v1's).

## Known residual (round-3 candidate, requires more than layout.zig)
The drawn ∫/∮ at 2.0× is ~25% wider than the .v1 variant and now touches its
beside scripts. Pixel-verified in the 48pt render: the ∫ ink overlaps the
superscript `1` by 38% of the `1`'s ink and the subscript `0` by 39%
(geometric verifier: 61.7% / 16.0% of the smaller ink box by area). The ref
variant's ink (0.884em wide, centered in its 0.999em advance) ends 2.8pt
before the sup at 48pt. The vision model under-reported it ("slightly
thinner", minor) but the geometry is authoritative. Fixing the width needs the
actual .v1 outlines (SVG path emission) or a horizontal glyph compression
(SVG transform) — both outside this round's EDIT-ONLY layout.zig/metrics.zig
scope.
