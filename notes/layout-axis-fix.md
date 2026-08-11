# Display big-op axis centering in the beside path (layoutScript)

Date: 2026-08-12 · Files: `src/layout/layout.zig` only (metrics.zig, tests,
goldens untouched)

Driver: after the nolimits transition, `\int_0^1 x\,dx` matched XeTeX
horizontally (∫ 0.0, sup 1 at +0.04, sub 0 at +0.02, integrand ~0.4pt) but
was vertically off by max|dy| = 13.56pt: ztex put the display ∫ ON the row
baseline, while TeX centers display big operators on the math axis.

## TeX rule (verified against XeTeX source + measurements)

- `make_op` (xetex.web/tex.web) shifts a big-op box by
  `half(h−d) − axis` for ANY style — including `\intop\nolimits` ops whose
  scripts stay beside. For the display ∫ (cmex10 O111: w=5.55557, h=0,
  d=22.22246, ic=4.44444) at 10pt: `(0 − 22.22246)/2 − 2.5 = −13.61123`
  (y-down: negative = up).
- `make_scripts` then computes the raises/drops from the box AFTER hpack
  absorbs its shift_amount: z.h = 13.61122, z.d = 8.61124. `sup_drop(t)`
  and `sub_drop(t)` are read from the SCRIPT-SIZE math-symbols font
  (cmsy7): sup_drop = 2.4722, sub_drop = 0.49998 (cmsy7 fd18/fd19; the
  10pt 3.86108/0.5 values in GlueParams only happen to match for sub_drop).
- XeTeX `\showbox` of `$\displaystyle\int_0^1 x$` (measured this session):
  ∫ box h=0 d=22.22246 w=5.55557 `shifted −13.61122`; script combo vbox
  `h=24.76135+0.0`, `shifted +9.11122`; sup hbox shifted +4.44444; kern
  15.73914; sub hbox h=4.51111. Formula box h=15.65013, d=9.11122.
- Rendered XeTeX (display 10pt, `\int_0^1 x\,dx`): ∫ baseline 13.56pt
  above the row baseline; sup `1` 11.10pt above (2.46 below the ∫
  baseline); sub `0` 22.64pt below the ∫ baseline.

## Change (layoutScript, beside path only)

1. When the base is a display-style big op that keeps beside scripts
   (`tag == .op and style == .display and !bigOpLimits` → ∫/∮), shift the
   base child box by `base_shift = (bb.height − bb.depth)/2 − axis`
   (axis = s(gl.axis_height, size_pt)), applied via `.shift` exactly like
   layoutOpLimits' `op_shift`. All other bases keep shift 0.
2. Script raises/drops are computed from the SHIFTED dimensions
   `base_h = bb.height − base_shift` (13.61123) and
   `base_d = bb.depth + base_shift` (8.61124), and the script box's
   height/depth are initialized to those — the row baseline ends up at the
   bottom of the ∫ depth region, as in TeX.
3. The raise/drop rules are unchanged (`max(base_h − supdrop, sup1|sup2,
   sup.depth + xh/4)`; `max(base_d + subdrop, sub1|sub2, …)`). The one
   correction: for the display-op case, `supdrop` uses the SCRIPT-SIZE
   value 2.4722pt (10pt basis) instead of GlueParams.supdrop (3.86108),
   because TeX evaluates sup_drop(t) with t = script_size (cmsy7 fd18).
   This only bites when height − sup_drop dominates — tall bases like the
   shifted display ∫; plain bases are unaffected (sup1/sup2 win).
   `subdrop` needs no special case: cmsy7 sub_drop = 0.49998 ≈ 0.5.
4. Sup/sub x positions untouched (sup at bb.width + display ic = 10.00003,
   sub at bb.width = 5.55557), per spec.

## Geometry `\int_0^1` display, 10pt

| item | before (ztex) | after (ztex) | XeTeX (target) |
|------|---------------|--------------|----------------|
| ∫ baseline vs row | 0.0 (on baseline) | −13.611 | −13.56/−13.61122 |
| sup `1` vs row | −4.129 | −11.139 | −11.10 (−11.139) |
| sub `0` vs row | +22.722 | +9.111 | +9.03 (+9.111) |
| sub `0` vs ∫ baseline | +22.722 | +22.722 | +22.64 (+22.722) |
| script box h | 8.64 | 15.650 | 15.65013 |
| script box d | 22.72 | 9.111 | 9.11122 |
| x: ∫ / sup / sub | 0 / 10.00003 / 5.55557 | unchanged | 0 / 10.0 / 5.556 |

(TeX-pt values from the XeTeX \showbox; the rendered PDF numbers are ~0.37%
smaller due to the 72/72.27 pt conversion.)

Verified by re-rendering (`zig build run -- -i '\int_0^1 x\,dx' -s 10`):
∫ y=2.038909, sup y=4.511108, sub y=24.761368, row (x d x) y=15.650139 →
∫ 13.611 above row, sup 11.139 above row, sub 22.722 below ∫ baseline —
the script box is (15.650 + 9.111), matching XeTeX's \showbox exactly.

Also verified unchanged: `x^2` (sup floor sup1 = 4.129), `x_2` (sub1 = 1.5),
`\sum_{i=1}^n x_i` (limits vbox, axis shift −9.5, staggering),
`\frac{\int_0^1 x}{2}` (text-style ∫ in the numerator stays ON the baseline).

## Scope / known limitations

- Only DISPLAY-style big ops with beside scripts (∫/∮) are axis-centered.
  Text/inline ops keep the baseline (spec requirement; note that XeTeX
  actually axis-centers those too — `\[...\]` vs `$...$` differ only in
  glyph size — so this remains a pre-existing deviation for text style).
- A BARE display `\int` (no scripts) also stays on the baseline: it never
  enters layoutScript (layoutOp returns an unshifted char box). XeTeX
  shifts it too, but the spec scoped this fix to the layoutScript beside
  path; the corpus case (`\int_0^1 x\,dx`) is the scripted one.
- `\sum\nolimits` in display is not modeled (parser stores no limits
  flag; ∑ routes to layoutOpLimits) — pre-existing, unchanged.

## Constraints honored

- EDITED ONLY src/layout/layout.zig; layoutOpLimits untouched.
- Superflat box model, spans, synthetic flag, x logic preserved.
- No build/test/fmt/ziglint gates run beyond the local smoke render;
  goldens intentionally NOT regenerated (they will change).
