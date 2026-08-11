# fix-strict-round1 — strict critique round: all 9 vision nits measured vs the same-size reference

Formula: `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`, both engines at **48pt**
(ours: `ztex -s 48` → PIL raster at 4/3 px/pt; reference: XeTeX+unicode-math
`\fontsize{48}` → mutool `-r 96` = 4/3 px/pt). Same px/pt ⇒ pixel and pt
measurements are directly comparable. Every nit measured FIRST; only
confirmed differences fixed. (The previous critique-ref rounds compared ours
at 48pt against a **10pt** reference upscaled 5.6× — every "bolder" nit was
partly that upscale artifact; the same-size reference removes it.)

## Per-nit table (values in pt at 48pt; Δ = ours − ref after the fix)

| nit | vision claim | measured ours | measured ref | Δ | disposition |
|-----|--------------|--------------:|-------------:|----:|-------------|
| 1 | ∑ bolder/taller | 45.26 × 48.00 ink | 63.65 × 66.97 ink | −18.4w, −19.0h | REAL, but renderer limitation (see below) |
| 2 | ∑ sub `i=1` HIGHER | 51.99 | 51.80 | +0.20 | FIXED (was −6.15): bigop2/4 now scale |
| 3 | ∑ sup `n` LOWER | 55.20 | 55.36 | −0.16 | FIXED (was −7.76): bigop1/3 now scale |
| 4 | fraction bar thicker | 1.92 | 1.9126 | +0.007 | NOT confirmed (equal) |
| 4 | fraction glyphs bolder | x 24.19×20.69; n 24.14×21.21; i 7.19×22.08 | 23.81×21.67; 25.92×21.67; 8.84×22.49 | ≤1.9 mixed dir | NOT confirmed (per-glyph advance residuals; PIL raster smoothed) |
| 5 | + larger | 31.97 × 31.97 | 31.85 × 31.85 | +0.12 | NOT confirmed |
| 5 | + more spaced | gaps 10.67 / 10.67 | 10.63 / 10.63 | +0.04 | NOT confirmed |
| 6 | ∫ bolder/taller | 26.54 × 53.33 ink | 42.42 × 106.24 ink | −15.9w, −52.9h | REAL, but renderer limitation (see below) |
| 7 | ∫ sub `0` HIGHER | 48.05 | 47.87 | +0.18 | NOT confirmed (≤0.3) |
| 8 | ∫ sup `1` LOWER | 56.93 | 56.71 | +0.21 | NOT confirmed (≤0.3) |
| 9 | x dx more spaced | 7.97 | 7.94 | +0.03 | NOT confirmed |
| 9 | x dx bolder | x 24.19×20.69; d 23.66×33.84 | 23.81×21.67; 22.76×33.72 | ≤0.9 | NOT confirmed; PIL raster smoothed |

Non-48pt confirmation of the same fixes: `\sum_{i=1}^{n} x_i` at 20pt —
n_raise 23.000 vs ref 23.067 (Δ 0.067), i_drop 21.664 vs ref 21.582
(Δ 0.082). At 10pt the change is a NO-OP (s(2.0,10)=2.0 etc.), preserving the
previous round's verified 10pt parity (n_raise 11.50, i_drop 10.832 unchanged).

## Changes (EDIT ONLY src/layout/layout.zig + scripts/critique.py; metrics.zig values already correct)

### 1. src/layout/layout.zig — `layoutOpLimits`: big-op limit kerns now scale with size
Root cause of nits 2/3: the over/under-limit gaps were
`max(bigop_spacing1, bigop_spacing3 − sup_d)` etc. with the 10pt-base
parameters applied UNSCALED (a comment claimed the cmex10 fontdimens stay at
their 10pt design size for every math size — "verified at 20pt"). With
XeTeX+unicode-math the limits gaps come from the Latin-Modern-Math MATH table
(UpperLimitGapMin 0.20em, LowerLimitGapMin 0.167em, UpperLimitBaselineRiseMin
0.111em, LowerLimitBaselineDropMax 0.60em), which are em-relative and scale
linearly. Measured on `\sum_{i=1}^{n} x_i` in the reference: over-limit kern
2.02pt @10pt, 4.05pt @20pt, 9.71pt @48pt — exactly bigop1 × size/10. The old
code pinned it at 2.0pt at every size, so the ∑ limits drifted 6–8pt at 48pt
and the 20pt "verification" was simply wrong. Fix:
```zig
const kern = @max(s(gl.bigop_spacing1, size_pt), s(gl.bigop_spacing3, size_pt) - sup_d);
const k    = @max(s(gl.bigop_spacing2, size_pt), s(gl.bigop_spacing4, size_pt) - sub_h);
```
Affects every display limits-op (`\sum \prod \bigcup \lim \max …` — shared
path), correcting all non-10pt sizes; 10pt output byte-identical.

### 2. scripts/critique.py — `rasterize_svg`: 2× supersample + LANCZOS downscale
PIL's direct glyph rasterization at 48pt+ renders measurably bolder than
mutool's reference raster (per-glyph ink coverage at the same 4/3 px/pt: x
0.295 vs 0.257, d 0.263 vs 0.257 — measured before). With a same-size
reference, the ink EXTENTS of the fraction glyphs and integrand are within
~1px of the ref, so the "bolder" look of nits 4/9 is raster antialiasing, not
geometry. Fix: draw at 2× (8/3 px/pt) and `Image.LANCZOS`-downscale to the
final 4/3 px/pt (`RASTER_SUPERSAMPLE = 2`); final geometry (positions, ink
extents, canvas size) unchanged. Coverage after: d 0.263 → 0.257 (== ref),
x 0.295 → 0.288.

## Confirmed-but-unfixable (measured, renderer limitations — NOT layout params)

Nits 1 and 6 are REAL: the drawn ∑/∫ ink is far smaller than the reference's
(∑ 45.3×48.0 vs 63.65×66.97; ∫ 26.5×53.3 vs 42.4×106.2 at 48pt). Root cause:
XeTeX draws the MATH-table displayOperatorVariants (`summation.v1`,
`integral.v1`), while ztex's SVG `<text>` can only draw cmap glyphs — the
base ∑/∫. The LAYOUT already models the variant exactly (the display-op box
is the .v1 extents and the limits/scripts/advance geometry matches the ref to
≤0.3pt — nits 2/3/7/8); only the drawn OUTLINE is the base glyph.

Verified impossible to fix by scaling the base glyph in layout.zig:
- The limits/scripts anchor at the variant's ink top (0.95em up for ∑, 1.361
  for ∫). The base glyph's ink top is 0.75em of its drawn size, so matching
  the top forces 0.75·S = 0.95·48 ⇒ S = 60.8, which then leaves the ink 6.3pt
  narrow and 6.4pt shallow (center 3.2pt high). A box rotation (box = drawn
  ink, same h+d) keeps the parent shifts invariant, but moves the glyph
  baseline by (h−d)/2 − axis, shifting the limits with it — measured: the
  ∑ limits broke by −4.60/+4.64pt and the 'n' gap collapsed to 0.4pt
  (ref 10.2). Reverted.
- ∫/∮'s .v1 aspect (0.887/2.222 = 0.399) differs from the base (0.553/1.111
  = 0.498): the height-matching scale (2.0×) makes the ink 10.7pt too wide,
  colliding with the beside superscript; the width-matching scale (1.604×)
  leaves the height 20% short and the ink center 7.2pt high.
- The remaining per-glyph letter/script ink widths (n 24.14 vs 25.92, script
  i 7.19 vs 8.84) are the known embedded-font/script-variant (ssty) advance
  residuals — metrics-table scope, not layout.

Fixing nits 1/6 needs the actual variant outlines (draw/svg emitting the .v1
path, or a renderer able to select MATH-table variants) — outside this round's
EDIT-ONLY scope (layout.zig/metrics.zig/critique.py).

## Verification
- `zig build test`: 112/114 pass; the 2 failures are the golden draw-list/svg
  snapshots — INTENTIONAL output change (parent regenerates goldens; tests
  untouched per instructions).
- Full `--ref` critique at 48pt with the same-size reference runs clean with
  the new raster; the vision model now reports only "slightly" sub-pixel
  deltas plus the two renderer-limited ∑/∫ nits.
- `\lim_{x \to 0} f(x)` at 48pt: under-limit drop 30.39 vs ref 30.28 (Δ 0.11).
- 10pt probes byte-identical to the pre-fix binary (fix is a no-op at 10pt).
