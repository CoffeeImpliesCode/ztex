# Fix: big-op ink box, display-op size scaling, constant supdrop — `layout.zig`

Date: 2026-08-13. Scope: `src/layout/layout.zig` only. Fixes the CRITICAL
big-op ink defect (pipeline-box R1 / pipeline-svg F1), the display-op size
scaling defect (F3), and the size-scaled supdrop/subdrop (PipeMetrics F2).
INTENTIONAL output change — goldens regenerate; tests/goldens untouched.

Ink extents below are measured with fontTools on
`latinmodern-math.otf` 2.005 (CFF bounds, per-mille → em). LMMath draws
every big op AXIS-CENTERED (ink center = font MATH axis = 0.250em), unlike
cmex10 whose glyphs hang below the baseline; the old box (cmex10 h/d) +
baseline placement therefore rode the ink 0.75–1.1em too high.

---

## Fix 1 — big-op box from the DRAWN font's ink (the critical fix)

`layoutOp` now boxes the op with `bigOpInk(op) × drawn size` instead of the
cmex10 TFM h/d. Width stays cmex10 (display next-larger 14.44448 / 5.55557;
text 10.55559 / 4.72223 — advance facts, unscaled), as do the bigop
spacing/limits gaps. Because every placement site already applies
`(h−d)/2 − axis` (layoutRow op_shift, layoutScript base_shift,
layoutOpLimits op_shift, script-content op folds), fixing h/d to the real
ink automatically centers the ink on the math axis everywhere — no shift
formula changed, only the box.

Measured ink (em of the glyph font-size):

| op | asc | desc | op | asc | desc |
|---|---|---|---|---|---|
| ∑ U+2211 | 0.750 | 0.250 | ∫ U+222B | 0.805 | 0.306 |
| ∏ U+220F | 0.750 | 0.250 | ∮ U+222E | 0.805 | 0.306 |
| ∐ U+2210 | 0.750 | 0.250 | ⋂ U+22C2 | 0.772 | 0.250 |
| ⋃ U+22C3 | 0.750 | 0.272 | ⨆ U+2A06 | 0.764 | 0.264 |

Shift sign verified against the box convention (positive = down) and against
XeTeX-LMMath `\showbox` at -s 20: display ∑ ink top/bottom land at
19.0/9.0 and ∫ at 27.22/17.22 — the exact XeTeX numbers — so the correct
formula is `shift = (ink_asc − ink_desc)/2·gs − axis` (= the standard
`(h−d)/2 − axis` with ink h/d), NOT `−(axis + 0.25·gs)` (that sign variant
would put the ink 0.5·gs above the axis).

### Before/after geometry (y-up; shift + = down; "row h" = content ascent)

| context | old box h/d | old shift | old ink top / clip | new box h/d | new shift | new ink top / clip |
|---|---|---|---|---|---|---|
| `\sum x` 10pt (gs 14) | 1.00 / 15.00 | −9.50 | 20.00 / **9.50** | 10.50 / 3.50 | +1.00 | 9.50 / **0.00** |
| bare `\int` 10pt (gs 20) | 0 / 22.22 | −13.61 | 29.71 / **16.10** | 16.10 / 6.12 | +2.49 | 13.61 / **0.00** |
| `\int_0^1 x` 20pt (gs 40) | 0 / 22.22 | −16.11 | 32.21 / **16.10** | 32.20 / 12.24 | +4.98 | 27.22 / **0.00** |
| limits `\sum_{i=1}^n` 20pt (gs 28) | 1.00 / 15.00 | −12.00 | 22.50 / **9.50** | 21.00 / 7.00 | +2.00 | 19.00 / **0.00** |
| text `\int` 10pt (frac num) | 0 / 11.11 | −8.06 | ink 8.05 pt above baseline | 8.05 / 3.06 | ≈0 | ink top 8.05 = base_h |

- Limits: the over-limit kern now measures from the true ink top — the 'n'
  clears the ∑ by kern 2.0pt (was overlapping, ink 9.5pt too high); vbox
  ascent = axis + 0.5·gs + kern + sup_h + sup_d + bigop5.
- Text/script ops: shift ≈ 0 at any size (ink center 0.25em = axis 0.25em
  of size_pt), matching XeTeX-LMMath's text ∫ shift ≈ 0; the ∫ stub is gone.

## Fix 2 — display-op size scales with the document size (PipeSvg F3)

`glyph_size = size_pt × metrics.displayOp.scale` (was the fixed `10 × scale`),
so at -s 20 the ∑ draws at 28pt (was 14) and the ∫ at 40pt (was 20). The box
width stays the cmex10 design value; the ink stays centered (Fix 1). The
SVG font-size already comes from the box's `size` field, so the plumbing was
unchanged — only the value.

| -s | ∑ gs before → after | ∫ gs before → after |
|---|---|---|
| 10 | 14 → 14 | 20 → 20 |
| 20 | 14 → **28** | 20 → **40** |

## Fix 3 — supdrop/subdrop constant (PipeMetrics F2)

TeX reads sup_drop/sub_drop from the SCRIPT-size symbol font
(\fontdimen8/17\scriptfont2 = cmsy7/cmsy5) at EVERY style: native 2.4722pt /
0.5pt, never scaled. `layoutScript` now uses the constants (was
`s(2.4722, size_pt)` / `s(gl.subdrop, size_pt)`). XeTeX pins the values:
`x^{a\over b}` sup shift 4.479 = 6.9512 − 2.4722; `\int^2` 5.5834 =
8.0556 − 2.4722.

| -s | supdrop before → after | subdrop before → after |
|---|---|---|
| 10 | 2.4722 → 2.4722 | 0.5 → 0.5 |
| 20 | 4.9444 → **2.4722** | 1.0 → **0.5** |

## Verification notes

- Ink extents measured from the installed LMMath (CFF BoundsPen).
- New geometry reproduces XeTeX-LMMath \showbox exactly at -s 20
  (∑ 19.0+9.0, ∫ 27.22+17.22) — the strongest available reference.
- ViewBox now contains the full ∑/∫ ink in every context (clip 9.5–16.1pt → 0);
  the bare ∫ renders as a full integral, not a bottom stub.
- Left intentionally unchanged (out of scope, tracked separately): the cmex10
  ADVANCE width (display ∑/∫ boxes keep 14.44448/5.55557 even though the
  drawn LMMath glyph advance is wider — horizontal width fidelity is
  PipelineVerify R1/R2's +28% ∫ defect), the italic-correction tails, and the
  bigop1-5 gap params.
