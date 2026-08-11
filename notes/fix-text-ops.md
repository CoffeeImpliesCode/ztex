# Fix: text-style big-ops draw the base glyph at the FULL size

## Problem

A text/script-style big op (e.g. `\textstyle\int`) was DRAWN at
`size_pt × base_asc/disp_asc` — the `.v1`-height workaround in `layoutOp`
(now obsolete: the rasterizer no longer resolves `.v1` for every big-op
codepoint). At `-s 30` the text ∫ declared 17.744pt, so the drawn ink was
1.111em × 17.744 = **19.71pt** — 41% too small vs the references
(XeTeX 33.22, KaTeX/MathJax 33.33 at the full 30pt base size). The BOX was
already full-size (`ink.advance × size_pt`, base extents), so the box/limits
geometry was TeX-consistent — only the drawn size was wrong.

A second defect: the critique rasterizer/verifier discriminated display vs
text big-ops by `declared font-size == the pane's base math size`
(`_display_bigop(size, base)`). Once the text ∫ is also declared at 30pt
the discriminator would resolve `.v1` for it again (the "same size" bug).

## Fix

### 1. layoutOp draws every big-op at `size_pt` (src/layout/layout.zig)

Removed `size_pt * (ink.asc / bigOpInk(op, true).asc)`; `glyph_size =
size_pt` for ALL styles. The text ∫ is now the CMAP base glyph at the full
30pt (ink 33.33pt); display ops keep drawing the MATH `.v1` variant at the
full size (unchanged). The box/limits math is untouched — the limits
stagger delta = displayOp.ic (0.332em) × size → delta/2 = 4.98pt at 30,
TeX's real text-∫ stagger, now measured against a glyph drawn at the size
the box was computed for.

### 2. Big-op form marker: box → draw → svg → critique

- **src/layout/box.zig**: `pub const BigOpForm = enum(u8) { base, variant }`
  + `Box.bigop_form: BigOpForm = .base` (default). `layoutOp` sets
  `.variant` for display ops.
- **src/layout/draw.zig** (the box→svg bridge; 1 field + 1 assignment):
  `Draw.Text.bigop_form` copied from the box in `flatten`. NOTE: the
  spec's EDIT-ONLY list omitted draw.zig, but it is the only carrier from
  the box to svg.zig — without it the marker cannot reach the SVG.
- **src/svg.zig**: emits ` data-op="v1"` on `<text>` for `.variant` big-ops
  only; everything else stays unmarked.
- **scripts/critique.py**: `_display_bigop(attrs)` now reads the marker
  (`attrs.get("data-op") == "v1"`) instead of the font-size discriminator,
  in both the PIL rasterizer (`rasterize_svg`) and the geometric verifier
  (`_glyph_ink_boxes` — the `base_size` param is gone; callers updated).
  `_base_math_size` stays (still used by the delimiter machinery).

### 3. Stagger-aware limit-centering check (scripts/critique.py)

After the fix the verifier still flagged the text ∫'s over-limit y:
5.285pt off the ∫ ink center (was 9.4pt). XeTeX ground truth (mutool from
`\textstyle\int\limits_x^y z` at 30pt): XeTeX ALSO places the y 4.97pt
right of the ∫ ink center — TeX make_op staggers limits ±delta/2 (delta =
the op's italic correction) around the op's BOX center, and a naive
ink-center check false-flags that intentional stagger (and the display
∫/∮ `.v1`'s right-skewed ink: its under-limit '2' sits exactly −delta/2 of
the box center while measuring ~10pt off the v1 ink center).

`compute_geometry` now compares each limit against the op's BOX center
(base-glyph hmtx advance / 2) ± delta/2 (new `_limit_stagger` +
`_math_italic_correction` reading the MATH table's
MathItalicsCorrection; ∫/∮ 0.332em, everything else 0 — mirroring the
layout's displayOp table). Limit-op words (\lim) keep the old ink-center
check (delta 0). This removes two false-positive classes (text-∫ stagger,
display-∫ v1 skew) and still catches genuine misplacement (> threshold
from the EXPECTED staggered position).

## Measurements (base 30pt, `-s 30`)

Formula `\textstyle\int\limits_x^y z` (verifier OTF BoundsPen ink, exact):

| glyph | before | after | refs (XeTeX/KaTeX/MathJax) |
|---|---|---|---|
| text ∫ declared size | 17.744pt | **30.000pt** | 30 (all) |
| text ∫ ink height | 19.71pt | **33.33pt** | 33.22 / 33.33 / 33.33 |
| over-limit y offset (stagger-aware) | — | **0.305pt** | XeTeX 0.31 (4.97pt from ink center — the intentional δ/2) |
| under-limit x offset | — | **0.168pt** | XeTeX 0.29 |
| display ∫ ink (v1) | 66.66 | 66.66 (unchanged) | 66.40 |
| display ∑ ink (v1) | 42.00 | 42.00 (unchanged) | — |

Text/display ink ratio: 33.33/66.66 = **0.500** — matches the references'
own ratio (XeTeX 0.500, KaTeX 0.500).

## Byte-identity of display ops

Diffed the pre-change artifact `notes/artifacts/critique-ref-21/render.svg`
against a fresh render of the same formula: all 19 `<text>` elements are
byte-identical EXCEPT (a) the two display big-ops gain exactly
` data-op="v1"` and (b) the text ∫ font-size 17.744 → 30. The `.v1` form
at the full size is unchanged (verify item 3).

## Critique verdict

`python3 scripts/critique.py --ref -s 30 '\displaystyle\int\limits_2^3
3x^2\,dx + \sum\nolimits^n_{i=1}i + \textstyle\int\limits_x^y z'` →
**PASS** (6 minor nits, qwen/qwen-2.5-vl-72b-instruct), including the
vision item: "integral limits alignment: The alignment of the lower limit
'x' and upper limit 'y' on the last integral **matches all references**" —
the y-off-center nit is GONE. No nit about the text ∫'s size (it now
matches the refs). The 6 minor nits are pre-existing layout-parity items
(∫ limits vertical centering vs XeTeX, ∫ stroke, ∑ script positions,
plus-sign spacing).

Geometric verdict (normal mode): defect_count 1 — `∫ × 3` ink overlap
(42.9 pt²): the DISPLAY ∫ `.v1` ink tail extends to x=30.69 while the
following term '3' starts at 28.61. Pre-existing, display-op-only (XeTeX
clears by 7.9pt; the ztex display-∫ limits vbox is boxed by the base
advance 0.665em, not the variant advance 0.999em) — the display-op
box-advance rule owned by the FixLayoutFinal/FixTeXParity scope, untouched
here per the task's "do not touch the display-op .v1 behavior" constraint.
The y-off-center flag itself is gone (all four ∫ limits now ≤ 0.31pt from
the TeX-expected positions).

## Spot checks

- `\textstyle\sum_{i=1}^n i` @30: ∑ declared 30pt, unmarked → base form,
  limits stacked. ✓
- `\frac{\int}{x}` @30: numerator ∫ at 30pt (text-style numerator —
  TeX-correct), unmarked → base. ✓
- `x^{\frac{\int}{x}}` / `x_{\frac{\int}{x}}` @30: script-level ∫ at
  10.5pt, unmarked → base at 10.5. ✓
- `\sum_{\int} x` @30: subscript ∫ at 21pt, unmarked → base at 21. ✓
- Mod array + LimitControls 4-pane render (22 text elements / 4-pane
  combined.png). ✓

## Gates

- `zig build` ✓, `zig build test` ✓ (175/175; the `\sum_{i=1}^{n}` SVG
  golden regenerated — the ∑ line gains ` data-op="v1"`; the draw-list and
  atom-tree goldens are unchanged), `zig fmt --check` ✓.

Note: the build on this host is lock-contended by stale zig processes;
gates were run with an isolated cache (`zig build --cache-dir /tmp/ztcache
--global-cache-dir /tmp/ztglobal`). During the work, a concurrent agent's
debug block (`std.os.getenv`, removed in 0.16) was breaking every build;
Main removed it (layout.zig:1712).
