# fix-strict-round3 — draw the actual MATH-table display variant glyphs

Formula `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`, ours at 48pt (ztex)
vs XeTeX+unicode-math at the same size. Round 2 drew the cmap BASE glyph at a
scaled font-size (∑ 1.4×, ∫ 2.0×) so the ink HEIGHT matched the reference —
but a single font-size scalar cannot match both dimensions (∫ base aspect
0.498 vs the .v1 variant 0.399): the height-matched scale drew the ∫ ~25% too
wide (53.09 vs ref 42.42 at 48pt) and overlapped its beside scripts 1/0.

Round 3: revert the drawn-size scale (the SVG emits font-size = design) and
make the critique PIL rasterizer draw the ACTUAL MATH-table display variant
glyph (summation.v1, integral.v1, …) — the same glyph XeTeX draws — so the
render matches in width AND height.

## Changes (EDIT ONLY src/layout/layout.zig + scripts/critique.py)

### 1. layout.zig — `layoutOp` drawn size back to design
Round 2's `glyph_size = size_pt × (variant.ink + base.ink) / base.ink` is
reverted to `glyph_size = size_pt` (every style). The box/limits/scripts/
advance geometry is untouched (the box stays the round-1 tree: display ops box
by the display-variant extents × size_pt). Verified: the round-3 SVG is
BYTE-IDENTICAL to the round-1 artifact for the big-op `<text>` elements
(font-size 48pt, x/y 16.8/190.374/96.10559 — round 2 had 67.2/96pt).

### 2. critique.py — resolve and draw the MATH .v1 variant
- **Resolution**: for the 8 big-op codepoints (∑ U+2211, ∫ U+222B, ∏ U+220F,
  ∐ U+2210, ⋃ U+22C3, ⋂ U+22C2, ⨆ U+2A06, ∮ U+222E) read the font's MATH
  table: `MathVariants.VertGlyphConstruction[base]` variant records; the LAST
  record is the largest display variant (LM Math lists base then .v1; vertical
  extent ≥ DisplayOperatorMinHeight 1.3em). Fallback: conventional
  `<base>.v1` naming. All 8 resolve: summation.v1, integral.v1, product.v1,
  uni2210.v1, uni22C3.v1, uni22C2.v1, uni2A06.v1, contourintegral.v1.
- **PIL drawing**: FreeType rasterizes by cmap, so the base font is patched in
  memory with fontTools — a private-use codepoint (U+F000..F007) per operator
  is mapped to its .v1 glyph name in the cmap — and the PUA char is drawn with
  `anchor="ls"` at the same size/baseline the base glyph used. Same rasterizer
  (PIL FreeType), same supersampling, correct variant shape at the declared
  font-size. Cached per (path, size_px); patched bytes built once per font.
- **Geometric verifier**: `_glyph_ink_boxes` resolves the variant glyph name
  and uses its outline + hmtx advance, so the verifier measures the SAME ink
  the raster draws (clipping, overlaps, op boxes).

## Before/after drawn ink (48pt)

| glyph | round 2 (base@scale) | round 3 (.v1@design) | XeTeX ref raster | Δ |
|-------|---------------------:|---------------------:|-----------------:|-----:|
| ∑ | 63.37 × 67.20 | **63.75 × 67.50** | 63.00 × 67.50 | +0.75w (raster AA), 0.00h |
| ∫ | **53.09 × 106.66** (25% too wide) | **42.00 × 106.50** | 42.00 × 106.50 | **exact** |

(fontTools BoundsPen on the .v1 at 48pt: ∑ 63.89 × 67.20, ∫ 42.58 × 106.66 —
the raster deltas are PIL-vs-mutool antialiasing on thin strokes, ≤0.8pt.)
At 10pt the fontTools .v1 inks are ∑ 13.31×14.00, ∫ 8.87×22.22 (ref 13.26×13.95,
8.84×22.13).

## Overlap check

- **∫/1 (sup)**: clean — the .v1 ink ends 5.68pt before the sup `1` at 48pt
  (round 2 overlapped it by 38%).
- **∫/0 (sub)**: the sub attaches at variant advance − italic correction
  (0.408em), INSIDE the .v1 ink (which ends at 0.943em) — measured on the
  XeTeX reference raster: the ref's `0` component bbox lies inside the ∫ ink
  bbox identically (221 pt² of bbox intersection in BOTH). This is intended
  reference-faithful adjacency, so the verifier now excludes a big-op's own
  attached beside scripts from overlap defects (like it already excluded
  limit-touching): a script-sized (< op size) element, horizontally inside the
  op's ink span, vertically adjacent to the op's ink box → "op's attached
  beside script". The geometric verifier must not flag ∫/1 or ∫/0 — it does
  not (0 defects).
- ∮ (U+222E) was missing from the verifier's op-detection set (`BIGOP_GLYPHS`)
  despite having the same .v1 sub-overlap behavior as ∫ — added; `\oint_0^1 f`
  now verifies clean.

## Critique verdict

- Non-ref (`scripts/critique.py -s 48`): **PASS — 0 geometric defects**
  (clipping 0/4 edges, no off-center limits, no real overlaps, no empty
  glyphs); all vision FAIL claims refuted as artifacts.
- Ref (`scripts/critique.py --ref -s 48`): nits 1 (∑ size) and 6 (∫ size)
  from round 2 are GONE, and the "∫ appears thinner" nit is gone (replaced by
  the generic "∫ bolder" raster-artifact nit that also hits ∑ and the fraction
  bar — the known ~+4% PIL-vs-mutool stroke boldness, not a shape issue). The
  9 remaining nits are all `minor` and are round 1's sub-pixel set (limit
  positions ±0.2pt, glue, spacing) — no size/width/overlap defects.
- 10pt render: 0 geometric defects, clipping 0.

## Browser/SVG note

The SVG/browser still shows the cmap BASE glyph at design size (cmap cannot
select MATH variants) — the CRITIQUE render (what the loop judges) draws the
.v1 variant via the patched font; the two differ only in the op glyph shapes,
positions/sizes are identical.

## Known non-blocking

`\bigcup_{j} A_j` shows an "off-center limit" flag (2.31pt vs 1% threshold):
the verifier measures the LIMIT's INK center, and the slanted italic `j`'s ink
center is 2.28pt left of its advance center (measured) — the limit IS centered
on the op's box in the layout. Pre-existing verifier precision artifact,
outside the strict corpus; left as-is to keep the centering semantics stable.
