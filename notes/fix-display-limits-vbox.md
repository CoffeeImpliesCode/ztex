# Fix: display-op limits vbox boxes by the .v1 VARIANT advance

## Problem

A display-style `\int\limits_2^3` produced a limits vbox that boxed the ∫ by the
**base** advance (0.665em × size), not the **.v1 display-variant** advance
(0.999em × size). XeTeX boxes the display ∫math op by the MATH-table integral.v1
variant advance (0.999em). Since the variant glyph's ink extends to ~0.943em from
origin, the narrower 0.665em vbox left the integral's tail overlapping the
following term.

## Change (already in tree — src/layout/layout.zig + src/layout/box.zig)

`box.zig` — two new fields on `Box` (default 0):

- `disp_advance: f32` — hmtx advance of the display .v1 variant in em
  (∫/∮: 0.999; limits ops ∑/∏/⋃/⋂/⨆: == base advance).
- `disp_ic: f32` — MathItalicsCorrection of the drawn form, pt at 10pt base
  (∫/∮ base 3.32, .v1 5.91).

`layoutOp` (line ~3197) — for display ops (`display == true`):

```zig
list.boxes.items[box_idx].bigop_form = .variant;
list.boxes.items[box_idx].disp_advance = ink.disp_advance; // 0.999 for ∫/∮
list.boxes.items[box_idx].disp_ic = ink.ic;                  // 5.91 for ∫/∮
```

`layoutOpLimits` (line ~2873-2929):

```zig
const variant = bb.bigop_form == .variant;
const delta = if (variant)
    s(bb.disp_ic, size_pt)                                   // .v1 ic × scale
else if (metrics.displayOp(bb.cp)) |dop|
    s(dop.ic, size_pt) else 0;                                // base ic for text

const op_w = if (variant) bb.disp_advance * size_pt else bb.width; // .v1 vs base
const vbox_w = @max(op_w, @max(sup_w, sub_w));
```

The op is placed at `x_shift = (vbox_w - op_w) / 2` (centered in wide vbox),
superscripts at `+delta/2`, subscripts at `-delta/2`.

## Before/after clearance

At `\fontsize{30}` (size_pt = 30):

| | old (base advance) | new (.v1 variant advance) | XeTeX ref |
|---|---|---|---|
| vbox width | 0.665em × 30 = 19.95pt | 0.999em × 30 = 29.97pt | 29.97pt |
| ∫ ink right (v1, 0.943em) | 28.29pt from origin | 28.29pt from origin | 28.29pt |
| next `3` start | origin + 19.95 + thin(5.0) = 24.95 | origin + 29.97 + 5.0 = 34.97 | 34.97 (norm) |
| clearance (ink→`3`) | **overlap ~3.3pt** | 6.68pt | 6.68pt |

The spec noted "2.08pt overlap → ~7.9pt clearance"; the total recovery
(10.02pt ≈ (0.999−0.665)×30) is confirmed. The exact overlap value depends on
the ink-bbox measurement path (path bbox vs. rendered raster); the geometric
verdict is identical in both engines after the fix.

## Limit position diff table

Formula: `\displaystyle\int\limits_2^3 3x^2\,dx + \sum\nolimits^n_{i=1}i + \textstyle\int\limits_x^y z`
at `-s 30`, XeTeX ref at `\fontsize{30}` (mutool scale 29.8879, normalized to 30pt).

### Display ∫ limits (variant = true, delta = 0.591em × 30 = 17.73pt)

| element | metric | ztex | XeTeX (norm) | diff | ≤0.5pt |
|---|---|---|---|---|---|
| ∫ origin x | — | 2.4000 | 3.9999 | −1.600 | (border offset) |
| ∫ vbox right | next₃−∫_x−29.97 | 5.000 pt | 5.001 pt | 0.001 | ✓ |
| sup `3` rel_x | center + delta/2 | 18.6000 | 18.6005 | 0.001 | ✓ |
| sub `2` rel_x | center − delta/2 | 0.8700 | 0.8702 | 0.000 | ✓ |
| sup `3` rel_y | raise | −47.2920 | −47.2917 | 0.000 | ✓ |
| sub `2` rel_y | drop | 44.8260 | 44.8255 | 0.001 | ✓ |
| next `3` rel_x | ∫_x + 29.97 + thin | 34.9700 | 34.9707 | 0.001 | ✓ |
| sup−sub x distance | = delta (sup_w=sub_w) | 17.7300 | 17.7303 | 0.000 | ✓ |

### ∑ nolimits (unchanged — disp_advance == advance = 1.444em)

| metric | ztex | XeTeX (norm) | diff |
|---|---|---|---|
| gap `+→∑` | 30.007 pt | 30.000 pt | 0.007 | ✓ |

### Text ∫ limits (regression check — variant = false, delta = 0.332em × 30 = 9.96pt)

| element | metric | ztex | XeTeX (norm) | diff | ≤0.5pt |
|---|---|---|---|---|---|
| ∫ v1 flag | base form | False | — | ✓ | |
| ∫ size | full size | 30.00 | 30.00 | 0.00 | ✓ |
| sup `y` rel_y | raise | −34.4550 | −34.4547 | 0.000 | ✓ |
| sub `x` rel_y | drop | 27.1800 | 27.1776 | 0.002 | ✓ |
| sub `x` rel_x | center − delta/2 | −1.0110 | −1.0108 | 0.000 | ✓ |
| sup `y` rel_x | center + delta/2 | 9.8100 | 9.5156 | 0.294 | ✓ |
| sup−sub x distance | delta + (sub_w−sup_w)/2 | 10.8210 | 10.5263 | 0.295 | ✓ |

Text ∫ uses the `else` branch in `layoutOpLimits` — `variant = false`,
`delta = s(dop.ic, size_pt)` from `metrics.displayOp` (ic = 3.32 for ∫). This
code path is **unchanged** by the DisplayIntVbox edit (which only added the
`variant` branch). The 0.294pt sup-`y` x-difference is a pre-existing font-
metric discrepancy in the math-italic `𝑦` (U+1D49C) glyph width between ztex's
embedded Latin Modern table and XeTeX's rendering — sub `x` matches to 0.0002pt,
and all y-coordinates match to ≤0.003pt.

## Wide-limit check

Formula: `\sum\limits_{i=1}^{\text{verylongterm}}` at `-s 30`.

The over-limit "verylongterm" (12 chars, ~111pt at 21pt) is wider than the ∑
box (43.32pt). The code centers the ∑ in the wide vbox via
`x_shift = (vbox_w − op_w) / 2`:

| metric | ztex | XeTeX (norm) | diff |
|---|---|---|---|
| ∑ centering error (vs expected offset) | 0.0000 pt | 0.0000 pt | 0.000 | ✓ |
| ∑ center vs vbox center | 0.0000 pt | 0.0000 pt | 0.000 | ✓ |
| sub `=` rel_x to ∑ | 11.8635 pt | 11.8632 pt | 0.0003 | ✓ |
| sub `1` rel_x to ∑ | 28.2015 pt | 28.2012 pt | 0.0003 | ✓ |
| sub rel_y to ∑ | 32.4960 pt | 32.4954 pt | 0.0006 | ✓ |
| vbox_w (font-metrics diff) | 111.195 pt | 110.650 pt | 0.545 | text-mode LM |

The 0.545pt vbox_w difference comes from the `\text{verylongterm}` text run
using LMRoman17 advances (ModVerify owns metrics.rs band17 — outside this fix's
scope). The ∑ centering and sub positioning are exact.

## Verification commands

```
zig build test          # 176/176 pass
zig fmt --check src/layout/layout.zig src/layout/box.zig  # clean
```

Refs rendered: `\documentclass[preview,border=4pt]{standalone}` +
`\usepackage{amsmath,unicode-math}` + `\fontsize{30}{36}\selectfont`, xelatex +
mutool draw -F svg (store mupdf 1.27.2).
