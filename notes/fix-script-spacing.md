# fix-script-spacing — script placement + inter-term spacing vs XeTeX

Fixes the consistent nits found by the --ref vision critique (ours vs the
unicode-math XeTeX reference): subscripts sat HIGHER, superscripts LOWER,
and the display big-op/limit geometry was small (∫ "slightly bolder and
taller" is the display-variant box, fixed; the drawn ink cannot select the
font's `.v1` variant — see residuals).

Reference = XeTeX + standalone preview + unicode-math, `$\displaystyle …$`,
10pt, glyph geometry via mutool SVG + stext (`parse_xetex_svg`). All values
below in TeX pt at 10pt (ref PDF pt × 72.27/72). Measured FIRST, changed
only confirmed-different parameters.

## Probe table (ours BEFORE → AFTER vs ref; Δ = after − ref)

| # | probe | parameter | before | after | ref | Δ |
|---|-------|-----------|-------:|------:|----:|---:|
| 1 | `x_i` | sub drop (sub1) | 1.500 | 2.470 | 2.470 | 0.000 |
| 2 | `x^2` | sup raise (sup1) | 4.129 | 3.630 | 3.631 | −0.001 |
| 3 | `x_i^2` | sup raise | 4.129 | 3.630 | 3.631 | −0.001 |
| 3 | `x_i^2` | sub drop (sub2+4rt clearance) | 2.472 | 2.569 | 2.611 | −0.042* |
| 4 | `\int_0^1` | sup raise (base_h − supdrop) | 5.578 | 11.860 | 11.860 | 0.000 |
| 4 | `\int_0^1` | sub drop (base_d + subdrop) | 3.560 | 10.010 | 10.009 | +0.001 |
| 4 | `\int_0^1` | sup x-offset (variant advance) | 9.970 | 9.990 | 9.989 | +0.001 |
| 4 | `\int_0^1` | sub x-offset (variant adv − variant ic) | 6.650 | 4.080 | 4.079 | +0.001 |
| 5 | `\sum_{i=1}^{n} x_i` | over-limit n raise (bigop1) | 9.500 | 11.500 | 11.570 | −0.070* |
| 5 | `\sum_{i=1}^{n} x_i` | under-limit i drop (bigop2) | 8.829 | 10.832 | 10.817 | +0.015 |
| 5 | `\sum_{i=1}^{n} x_i` | following-term advance (vbox 1.444em + thin) | 12.393 | 16.107 | 16.106 | +0.001 |
| 6 | `a+b` | bin glue (med 4/18, quad 1em) | 7.222 | 7.222 | 7.510 | −0.288* |
| 7 | `x\,dx` | thin-space glue (3/18, quad 1em) | 1.667 | 1.667 | 1.660 | +0.007 |
| 8 | `\frac{x_i}{n}` | num+den shift (num1/denom1) | 13.625 | 13.625 | 13.632 | −0.007 |

`*` residual, not a parameter (see below).

## Changes (EDIT ONLY metrics.zig + layout.zig)

### src/layout/metrics.zig — GlueParams (Latin-Modern-Math MATH constants)
Measured from latinmodern-math.otf (fontTools MATH table) and verified
against the XeTeX render (probe numbers above; LM SuperscriptShiftUp
0.363em, SubscriptShiftDown 0.247em, SuperscriptShiftUpCramped 0.289em,
UpperLimitGapMin 0.20em, LowerLimitGapMin 0.167em, UpperLimitBaselineRiseMin
0.111em, LowerLimitBaselineDropMin 0.60em, bigop5 0 — the last via the
fontspec fontdimen dump of the OT math font, fd13 = 0pt).

- sup1 4.12892 → **3.63** (probe 2: ref sup raise 3.630; LM has no
  display/text distinction, so sup2 = sup1 = 3.63)
- sup3 2.88889 → **2.89** (SuperscriptShiftUpCramped)
- sub1 1.5 → **2.47** (probe 1: ref sub drop 2.470)
- sub2 2.47217 → **2.47**, sub3 1.333 → **2.47** (SubscriptShiftDown at
  every size; no separate "with superscript" constant in LM)
- supdrop 3.86108 → **1.75**, subdrop 0.5 → **1.4** (SuperscriptBaselineDropMax
  0.25em × 0.7 / SubscriptBaselineDropMin 0.20em × 0.7 — evaluated at the
  script size; probes 4: 11.860 = 13.611 − 1.75, 10.008 = 8.611 + 1.40)
- bigop_spacing1 1.11112 → **2.0** (UpperLimitGapMin)
- bigop_spacing3 2.0 → **1.11** (UpperLimitBaselineRiseMin — the two were
  SWAPPED vs LM)
- bigop_spacing5 1.0 → **0.0** (LM bigop5)
- bigop_spacing2 1.67, bigop_spacing4 6.0, axis 2.5, rule 0.4, num/denom,
  x_height 4.30555: unchanged (already match — measured frac total
  13.625/13.632, axis = LM 0.25em, rt = LM 0.04em)
- test "glue parameters are positive": bigop_spacing5 is legitimately 0 now.

### src/layout/layout.zig
- **symFor**: delete the cmsy7/cmsy5 tables; one LM set (sup 3.63/3.63/2.89,
  sub 2.47/2.47) scaled LINEARLY by s() — measured `x^{y^2}` script sup
  2.541 = 3.63 × 0.7 (the old cmsy7 sup2 4.311 was CM-only).
- **layoutScript supdrop/subdrop**: constants 2.4722/0.5 → `s(1.75)`,
  `s(1.4)` (em-relative, scale with size).
- **quadEm**: 1.0 at EVERY style (the old cmsy7 1.170641 / cmsy5 1.472241
  quads are CM values). Measured script \, = 3/18 × 6.9738 = 1.162pt and
  \; = 5/18 × 6.9738 = 1.937pt on `x^{1\,1}` / `x^{1\;1}`.
- **bigOpInk display variants** (op, display): display style boxes the
  font's `.v1` display-variant extents (measured from the XeTeX render:
  ∑ ink 0.950/0.450, advance 1.444em; ∏/∐ 1.278em; ⋃/⋂/⨆ 1.111em). The
  limits ops take the variant advance as the box; ∫/∮ (nolimits) keep the
  BASE advance (measured: scripted `\int_0^1` row = 0.665em + scripts, bare
  `\int x` = 0.665 + 0.334 + thin) but the box h/d and the side-script
  attachment use the variant (`.disp_advance` 0.999em, `.ic` 5.91pt).
- **layoutScript op-base gaps**: beside scripts attach at the op advance —
  display nolimits: sup at variant advance (9.99pt), sub at variant advance
  − variant italic (4.08pt); text: sup at box, sub at box − base ic. The
  old "sup at box + ic" matched display only because 0.665 + 0.332 ≈ 0.999.
- **opTailIc**: only a bare DISPLAY nolimits op carries the
  variant-advance-minus-base tail (3.34pt at 10pt); text and limits ops
  have none (measured bare `\int x` 11.606 = 0.999em + thin, text 8.285 =
  0.665em + thin, `\sum x` 16.040 = 1.444em + thin).

## Residuals (measured, NOT parameters — per-glyph font metrics)
- **x_i^2 sub drop 0.042**: the i ink height (our drawn font 0.657em vs the
  font XeTeX embeds 0.6634em) feeds the 4·rt clearance.
- **sum n raise 0.070**: the n ink depth (ours 0 vs the embedded 0.0067em)
  lifts the over-limit baseline by the depth.
- **Horizontal letter/script offsets** (x^2 sup_x 0.28, x_i^2 sub_x 0.44,
  a+b 0.29, x\,dx 0.44, sum limit centering 0.53–0.68): XeTeX's embedded
  font renders per-glyph advances LARGER than the hmtx of every local
  latinmodern-math.otf (x 0.572em vs 0.528em — the PDF /W array and the
  TJ positions confirm), and script-size glyphs use the GSUB ssty=0
  variants (1.st 0.569em, i.st 0.323em, n.st 0.631em … vs our 0.5/0.278/
  0.556 × 0.7). These are per-glyph METRICS (metrics.zig `table`/`table7`),
  not GlueParams/script/glue parameters — out of this task's scope
  ("EDIT ONLY metrics.zig GlueParams values + layout.zig constants");
  a follow-up can apply the measured .st/.sts advances to table7/table5.
- **Display-op drawn ink vs box**: the box is the `.v1` extents (so the
  script/limit geometry matches), but the SVG still draws the BASE glyph
  (the `.v1` is a MATH-table variant a <text> cannot select), so the
  display ∑/∫ ink is smaller than the reference's. The "∫ bolder and
  taller" appearance nit needs the variant outlines — rendering limitation,
  not a layout parameter.
- The 3.5pt SVG margin / 2pt linegap (svg.zig) are renderer safety, not
  layout; both engines' content rows now agree (ours 71.9×27.4 vs ref
  74.4×28.6 content pt — the 2.5pt width = the per-glyph advance residuals).

## Verification
- `zig build test`: 112/114 pass; the 2 failures are the golden draw-list/
  svg snapshots — INTENTIONAL output change (parent regenerates goldens).
- Probe harness re-measured after the change; table above.
