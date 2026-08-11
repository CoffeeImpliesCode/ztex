# Box model + layout-coordinate audit — `box.zig` / `layout.zig` / `layout/root.zig` vs MicroTeX + TeX

Full-pipeline STAGE 3 audit, READ-ONLY. Scope: the height/depth/shift/baseline/
y-axis conventions of the box model and every layout function, and whether the
draw list's total height/depth bound ALL ink in the SVG viewBox.

Method: line-by-line walk of `src/layout/{box,layout,draw}.zig`,
`src/layout/root.zig`, `src/svg.zig`; reference walk of MicroTeX
`box/{box,box_group,box_single}.cpp`, `atom/{atom_basic,atom_char,atom_impl}.cpp`
(SymbolAtom/ScriptsAtom/BigOperatorAtom/FractionAtom); TeX (tex.web hpack/
make_scripts/make_op/make_fraction semantics, TeXBook Appendix G). Every claim
below was checked numerically against the byte-exact regression goldens
(`src/tests/regression.zig`, size 20) and against the installed Latin Modern
Math OTF's actual glyph ink (fontTools, `latinmodern-math.otf`).

Verdict up front: the box-model conventions and every shift sign are CORRECT
and mutually consistent (positive shift = down, height = ascent, depth =
descent; parent folds h−shift / d+shift exactly like MicroTeX `HBox::recalculate`
and TeX hpack). There is NO sign inversion and NO baseline mismatch between
layout and flatten. There IS one real, visible output defect (R1): for big
operators the drawn glyph's ink does not match the box the layout uses, so the
operator renders shifted up and clipped — the top candidate for "looks wrong".

---

## R1. THE HEADLINE: big-op drawn ink does not match the cmex10-derived box — display/text operators render ~3.5–6.1pt above the math axis with 0.5–16.1pt top clipping, and limits collide with the operator. CONFIRMED (font-measured).

**ztex:** `layoutOp` (layout.zig ~line 780-860) boxes a big op with the cmex10
TFM metrics — display ∑: w=14.44448, **h=1.00001, d=15.00012**; display ∫/∮:
w=5.55557, **h=0, d=22.22246**; text-style: h=0, d=10.00013/11.11122 — and
places the glyph's SVG `<text>` baseline AT the box baseline. Parents then
axis-center the BOX with the TeX shift `(h−d)/2 − axis` (verified: layoutRow
`op_shift`, layoutScript `base_shift`, layoutOpLimits `op_shift` all identical,
and all match XeTeX \showbox numbers quoted in the code: display ∫ −13.61122,
text ∫ −8.0556, script ∑ −6.75006).

**Reference:** TeX draws the cmex10 O130/O111 glyph whose ink really spans
[+1, −15]em around the baseline (ink hangs below), so the box and the shift
make the ink axis-centered. MicroTeX has the same model (`CharBox::draw` draws
the glyph at its baseline; the box carries the font's metrics).

**But the drawn glyph here is NOT the cmex glyph** — it is the small variant at
font-size `10×scale` (∑: 14pt, ∫: 20pt at any document size), rendered by the
viewer's font. Measured ink of Latin Modern Math (fontTools, per-mille of em):

| glyph | LM Math ink (asc / desc) | box h / d (10pt) | box center vs baseline |
|---|---|---|---|
| ∑ U+2211 | +0.750 / −0.250 (axis-centered: center at +0.25em) | 1.00 / 15.00 (center −7.0pt) | −0.70em |
| ∏ U+220F | +0.750 / −0.250 | 1.00 / 15.00 | −0.70em |
| ∫ U+222B | +0.805 / −0.306 | 0 / 22.22 (center −11.1pt) | −1.11em |
| font MATH axis | 0.250em | layout axis | 0.25em |

So the font draws every big op **axis-centered** (ink center at 0.25em above
the text baseline = the font's AxisHeight 250/1000), while the box assumes the
ink hangs below the baseline (center at −0.7em). The SVG text baseline is at
the box baseline → the drawn ink center lands at `(h−d)/2 + 0.25·gs` above the
math axis (y-down sign checked): ∑ 3.5pt, ∫ 6.1pt, text-style ∑/∫ 2.5–3.1pt.
Worse, the ink's ascent (0.75–0.81em of gs) far exceeds the box ascent
(0.1em/0) → top clipping in every context where the operator's baseline sits
near the top of the viewBox:

| context (verified numbers) | op baseline (SVG y) | actual ink [top, bottom] | viewBox | top clip |
|---|---|---|---|---|
| `\sum x` row, 20pt doc (gs 14) | 1.00 | [−9.49, +4.51] | [0, 16.00] | **9.49pt** |
| `\int` alone, 10pt doc (gs 20) | 0.00 | [−16.10, +6.12] | [0, 22.22] | **16.1pt** |
| text `\int` in `\frac{\int}{2}` num, 10pt (gs 10) | 0.00 | [−8.05, +3.06] | [0, 11.2+] | **8.05pt** |
| `\sum_{i=1}^{n}` golden, 20pt (gs 14) | 10.03 | [−0.47, +13.53] | [0, 36.93] | 0.47pt |

The limits golden (byte-exact, `regression.zig`) quantifies the misplacement:
the ∑ ink occupies y∈[−0.47, 13.53] while TeX's cmex geometry puts it at
[9.03, 25.03] — the ∑ renders **9.5pt higher than TeX**, and the over-limit 'n'
(ink [0.73, 7.03]) now **overlaps the operator** instead of clearing it by the
2.0pt kern. `\sum x` / `\int` / `\int_0^1`-style expressions are visibly wrong:
the operator hugs the top edge, cropped.

**Fix (layout/box domain):** the LM Math operators are AXIS-CENTERED glyphs
(ink center at the font's axis = 0.25em above the text baseline), unlike
cmex10's hang-below glyphs, so the TeX box-centering formula no longer applies.
Two coordinated changes in `layoutOp`/parents:
1. Box h/d = the drawn glyph's font extents (gs = 10×scale): ∑/∏/⋃:
   h = 0.75·gs, d = 0.25·gs; ∫/∮: h = 0.805·gs, d = 0.306·gs — so the viewBox
   and the limits' vertical measurements cover the real ink.
2. The operator child's shift becomes the fixed `−axis − 0.25·gs` (text
   baseline 0.25·gs below the math axis), NOT `(h−d)/2 − axis`. Then the font
   ink center lands exactly on the axis (baseline + 0.25·gs = −axis ✓) and the
   ink spans [−axis − gs, −axis] (∑) — bottom touching the axis, nothing
   clipped. The over/under-limit kerns then measure from the real ink top
   (checked: the golden's 'n' clears the ∑ by ~2.7pt instead of overlapping).
Width and the limit-spacing params (bigop1-5) stay cmex10 — they are
advance/spacing facts, correct as-is. This also removes the +28% ∫ width
defect PipelineVerify (R1/R2 in `pipeline-verify.md`) measures, because the
box stops claiming a different glyph than the one drawn.

**Magnitude:** 2.5–6.1pt vertical misplacement of the ink center; 0.5–16.1pt
top clipping; over-limit/operator overlap ≈ 9.5pt in the limits case. This is
the "significantly flawed output" the audit was asked to lead with.

---

## R2. Digit box heights (6.44444) are 0.5pt short of TeX (6.94446) and 0.2pt short of LM Math's ascender → ≤0.5pt top clip on digits. CONFIRMED (minor, metrics-table).

**ztex:** `metrics.zig` table: 0x30–0x39 h=6.44444 (0.644em), d=0.
**Reference:** cmr10 TFM digits: ht 6.94446 (0.694em). LM Math '1' ink asc
0.666em.
**Verdict:** at 20pt the '1' in the fraction golden renders ink [12.888881−13.32,
12.888881] → 0.43pt above the viewBox top (fraction golden: num '1' baseline
12.888881, box h 12.888881). Sub-0.5pt, imperceptible, but a genuine
box-vs-ink shortfall for digits; a metrics-table fix (h = 6.94446) belongs to
the metrics stage, not layout. All other ordinary glyphs match their font
extents closely (x: 0.431em both; f: 0.75/0.19em both) — the layout model is
sound for them.

---

## R3. `layout()` on a bare-op ROOT skips axis centering (latent API gap, no current user path). LOW.

**ztex:** axis centering lives in the PARENTS: layoutRow folds a bare op's
`op_shift`; layoutScript folds `base_shift`; layoutOpLimits folds `op_shift`.
A bare `.op` node passed directly to `layout.layout()` returns the RAW box
(h=1/d=15 for display ∑) with no shift, and `layout/root.zig` then reports
out.height=1, out.depth=15 — baseline at the viewBox top, as if the shift were
absent.
**Reference:** TeX applies shift_amount at EVERY hpack (single-item hlists
included) — a bare \int gets its shift from make_op→hpack. MicroTeX same
(shift set on the SymbolAtom box).
**Verdict:** the parser ALWAYS wraps the root (`parseRow .top`) and every
fraction part (`parseRequiredArg` returns the inner row) in a row, so no
parser-produced tree reaches this path — verified by walking `parser.zig`
(parse/parseRow/parseRequiredArg/parseScriptArg). The public `layout()` API can
hit it with a hand-built AST; harmless today, worth a guard if `layout()`
becomes a public entry point. (In TeX the shift would still be applied; the
fraction/script paths DO handle bare ops correctly: `\frac{\sum}{2}` → num row
absorbs the shift → kern1 measured from the SHIFTED depth 2.5, not 10.0 —
verified.)

---

## R4. `layoutOpLimits` ±delta/2 horizontal limit skew is correct-but-inert: no limits-taking op has nonzero italic. CONFIRMED (dead code, not a bug).

**ztex:** over-limit x_shift = (vbox_w−sup_w)/2 + delta/2, under = −delta/2,
delta = displayOp ic. Matches MicroTeX `BigOperatorAtom::createBox`
(`x->_shift = delta/2`, `z->_shift = -delta/2`) and TeX make_op.
**Verdict:** every op that TAKES limits (∏∐∑⋂⋃⨆) has ic=0 in `display_ops`
(verified in `metrics.zig`); the only nonzero-ic ops (∫/∮, ic 4.44446) never
take limits (`bigOpLimits` false). So delta=0 always, the skew never fires, and
the vbox width = max(op, sup, sub) always bounds the limits — no overhang, no
horizontal clip. Correct; keep as-is.

---

## Verified-correct items (line-by-line, no action)

- **Convention** (`box.zig`): height = ascent (y-up ≥ 0), depth = descent
  (≥ 0), `ChildRef.shift` positive = DOWN, "relative to the parent's reference
  point (baseline)". Matches MicroTeX `Box` (`_height/_depth/_shift` doc) and
  TeX shift_amount (positive = down).
- **Fold rule**: parent h += −shift, d += +shift. `layoutRow` (`cb.height −
  op_shift`, `cb.depth + op_shift`) is EXACTLY MicroTeX `HBox::recalculate`
  (`max(h, box._height − box._shift)`, `max(d, box._depth + box._shift)`), and
  `draw.zig flatten` (`y + cr.shift`) is EXACTLY MicroTeX `HBox::draw`
  (`y + box->_shift`). The op_shift formula `(h−d)/2 − axis` matches TeX
  make_op and MicroTeX SymbolAtom (equivalent for h=0 glyphs), verified
  against the XeTeX numbers quoted in the code (display ∫ 13.61122/8.61124;
  script ∑ −6.75006).
- **SVG y-axis trace**: layout is y-up baseline-anchored; flatten converts to
  y-down draw coords (baseline y, positive shift down); `svg.zig` offsets every
  primitive by `dl.height` so the top of all folded content lands at y=0.
  `dl.height` = root box height = TRUE total ascent because every shift
  producer folds (row: op_shift; script: base/sup/sub; limits: op/sup/sub;
  fraction: num/den/rule). Verified numerically against ALL regression goldens
  to ≤1e-4 (x, x^2, \frac{1}{2}, \sum_{i=1}^{n}, \text{hi}, padding case).
- **layoutScript**: sup shift = −(shift_up − sup_op_shift) (up), sub shift =
  shift_down + sub_op_shift (down), op base axis-centered via base_shift;
  height = max over (shift_up + sup top), depth = max over (shift_down + sub
  bottom) — matches MicroTeX ScriptsAtom (`vBox->_height = shiftUp + x->_height`,
  `_depth = shiftDown + y->_depth`). sup1/sup2/sup3 selection identical to
  MicroTeX (display→sup1, cramped→sup3, else sup2; XeTeX-verified in code
  comments: \frac{x^2}{y^2} num sup2 3.62892 / den sup3 2.88889). sub1/sub2 by
  presence ✓. The both-scripts interspace guard (4·rt, then the 0.8·x-height
  psi refinement) matches TeX's net effect.
- **layoutOpLimits**: term-by-term match with MicroTeX limits construction:
  op centered on axis; over kern = max(bigop1, bigop3 − over.depth); under k =
  max(bigop2, bigop4 − under.height); bigop5 top pad only with over, bottom pad
  only with under; sup/sub boxes measured at script size with proper cramping
  (sup inherits, sub always cramped). Golden-verified: every coordinate of
  \sum_{i=1}^{n} at 20pt matched (∑ y=10.027781 = h+kern+sup_h+bigop5+op_shift
  arithmetic, sub y=35.92792, n y=7.027771, widths 22.712145, x centering
  4.1338325/7.1544275).
- **layoutFraction**: matches MicroTeX FractionAtom exactly: num1/denom1
  (display) vs num2/denom2 or num3 (\atop); clearance 3·rt / 7·drt / rt /
  3·drt; kern1/kern2 axis-clearance adjustment (raise shift_up/shift_down);
  num_shift = −shift_up (up), den_shift = +shift_down (down); rule = leaf with
  h=d=rt/2 placed at shift −axis → rect y = y−rt/2, h = rt, CENTER ON THE AXIS
  (matches MicroTeX strut/rule stack: rule line at baseline − axis); height =
  shift_up + num.height, depth = shift_down + den.height; \nulldelimiterspace
  1.2pt pads folded into the vbox (matches MicroTeX HBox(vb, vb.width+2f,
  center)). Golden-verified (rule center 21.419041 = dl.height − axis 5;
  num/den baselines 12.888881/40.13806; depth = denom1 13.71902).
- **Bound-check**: `src/tests/sanity.zig` asserts every primitive is inside
  [0, h+d] after the +height offset for its corpus; the regression goldens pin
  the layout numbers. The only ink escapes found are R1 and R2, neither of
  which the box/layout coordinates cause.

## Cross-references
- `pipeline-verify.md` R1/R2: the comparison harness cannot see ink; the ∫
  +28% width defect and (this audit's) ink-position defect both live in the
  display-op box/glyph mismatch — R1 here is the layout-side half of that
  defect (box says cmex10, glyph is the scaled small variant).
- `audit-scripts.md` / `audit-bigop.md` / `audit-fraction.md` (earlier audits):
  the axis-shift, script-floor, and fraction-gap values they pinned are
  consistent with this audit's fold-rule and golden checks.
