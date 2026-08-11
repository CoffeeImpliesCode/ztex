# fix-layout-audit — layout.zig corrections, verified vs XeTeX

Date 2026-08-12. Scope: src/layout/layout.zig only. All numbers at 10pt unless
noted, measured from XeTeX \showbox (tectonic/crates/engine_xetex) and
xelatex→mutool renders; ztex rendered via `zig-out/bin/ztex -i <f> -s N`.
Authoritative = tex.web / xetex-math.c make_scripts/make_op + real TFM
(tftopl cmr7/cmmi7/cmsy7/cmsy5/cmsy10/cmex10).

Result: 96/98 tests pass; the 2 failures are the \sum_{i=1}^{n} golden
snapshots in tests/regression.zig, which regenerate per the intentional
output change (display op box is now cmex design-size at the 20pt test size,
fix #5 below).

---

## 1. Axis-center bare big operators (was HIGH, 13.56pt) — layoutRow

Before: a bare display op was placed at shift 0; the ∫ sat on the baseline and
its ink hung 13.56pt below the row baseline.

After: every bare op (display, text, script) gets make_op's axis shift
`(h−d)/2 − axis` in layoutRow; the row absorbs it into height/depth so the
operand stays on the baseline.

| case | XeTeX (\showbox) | ztex after |
|---|---|---|
| display `\int x` | ∫ box h=0 d=22.22246 w=10.00002(=5.55557+ic kern) shifted −13.61122; row h=13.61122 d=8.61124; x at 11.66665 | ∫ shifted −13.6112; x at 11.6667 dy 13.6112 ✓ |
| text `\int x` | ∫ shifted −8.0556 (= (0−11.11122)/2 − 2.5) | same ✓ |
| script ∑ in x_{\sum} | ∑ box shifted −6.75006 (axis = cmsy7 1.75); sub box h=6.75006 d=3.25006 at shift 3.30563; ∑ glyph 3.44443 above x | ∑ glyph −3.4445, sub 3.3056 ✓ |

Also covers the beside-scripted op base at TEXT/SCRIPT style: `\frac{\int_0^1 x}{y}`
numerator ∫ shifted −8.0556, sup 1 at w+ic = 6.6667, raise 5.5834 (= 8.0556 −
2.4722), drop 3.5556 — all match XeTeX (was: no shift, sup 3.62892, sub 11.61).

## 2. opTailIc bare-op ic — RESOLVED, NO CHANGE

The audit claimed XeTeX adds NO ic after a bare op (reading make_scripts'
`goto lab82` as discarding delta). Empirically FALSE: tex.web mlist_to_hlist
adds the kern BEFORE make_scripts:

```
if math_type(subscr)=empty and delta≠0 then link(p):=new_kern(delta)
```

So bare ops (and sup-only ops) DO advance by the ic; only ops with a subscript
skip the kern (the ic then moves the superscript). Measured:

| case | XeTeX | ztex |
|---|---|---|
| display `\int x` | ∫ box w=10.00002 (5.55557 + ic kern 4.44446); x at 11.66665 | x at 11.6667 ✓ |
| text `\int x` | ∫ box w=6.66667 (4.72223 + 1.94446); x at 8.33332 | same ✓ |
| `\int_0^1` | no kern; sup at w+ic 4.44444 inside the vbox | sup_gap = dop.ic ✓ |

Keep the bare-op branch; documented in opTailIc's comment.

## 3. Script refinements — layoutScript

### 3a/3b both-scripts clearance: LOWER the subscript; psi inside the guard

Before: `if interspace < 4·rt: shift_up += deficit` (raised the superscript),
then psi applied whenever both scripts present.

After (exact XeTeX): `shift_down += deficit`, then INSIDE the guard
`psi = 0.8·xh − (shift_up − sup.depth); if psi>0 { shift_up += psi; shift_down −= psi; }`.

Verified `x_i^j` (collision + psi case):

| | XeTeX | ztex before | ztex after |
|---|---|---|---|
| shift_up | 4.80553 | 5.12087 | 4.8056 ✓ |
| shift_down | 2.78741 | 2.47217 | 2.7875 ✓ |
| final interspace | 4·rt = 1.59991 | — | 1.6 ✓ |

### 3c sup_drop: script-size symbol font for ALL bases + char-base rule

The audit's value "cmsy7 sup_drop ≈ 2.88889" is WRONG (that is cmsy10's SUP3).
tftopl cmsy7: SUPDROP 0.353171 em × 7 = **2.472197pt** (cmsy5: 2.47223).
ztex already used 2.4722 for display ops; now ALL box bases use it.

TeX also has a rule the audit missed: make_scripts sets shift_up/shift_down to
0 for a CHAR nucleus — only the sup1/sup2/sup3, sub1/sub2 and x-height floors
apply; a BOX nucleus (op, fraction, braced list) starts from
height − sup_drop / depth + sub_drop.

| case | XeTeX | ztex before | ztex after |
|---|---|---|---|
| display `\int^2 x` | sup at 13.61122 − 2.4722 = 11.139 | 11.139 (display special case) | 11.139 ✓ |
| display `b^2` | sup1 floor 4.12892 (char base!) | 4.12892 ✓ | 4.12892 ✓ |
| text `b^2` | sup2 floor 3.62892 (char base) | 3.62892 ✓ | 3.62892 ✓ |
| `\frac{\int_0^1 x}{y}` num ∫ | sup 5.5834 (8.0556 − 2.4722) | 3.62892 (no shift, 3.86108) | 5.5834 ✓ |

### 3d cramped style — implemented; the audit had the DIRECTION BACKWARDS

tex.web: `num_style(#)=#+2−2*(# div 6)` (cramped iff current cramped),
`denom_style(#)=2*(# div 2)+cramped+2−2*(# div 6)` (ALWAYS cramped),
`sub_style(#)=…+cramped` (subscripts always cramped). So the DENOMINATOR uses
sup3, the numerator does NOT (the audit said numerator).

Threaded a `cramped: bool` through a new internal layoutInner (public
layout() unchanged); fraction denominator → cramped, numerator → inherits,
subscript content → always cramped.

Verified display `\frac{x^2}{y^2}`: numerator sup floor sup2 = 3.62892,
denominator sup floor sup3 = 2.88889 (XeTeX \showbox: shifted −3.62892 /
−2.88889) ✓. `x_{y^2}`: the 2's floor = sup3(cmsy7) = 2.0 ✓.

### 3e (found while verifying 3d) script sizes are ROOT-relative

10pt → 7pt → 5pt, NOT multiplicative. XeTeX \showbox: the 2 in x_{y^2} and
the 3 in x_{y_{2_3}} are both cmr/m/n/5 (5pt); before, ztex computed
7×0.5 = 3.5pt. Fixed: display/text → size×0.7, script → size×(0.5/0.7),
scriptscript → size×1.0.

### 3f (found while verifying 3d) sup floors come from the CURRENT size font

sup1/sup2/sup3/sub1/sub2 read from cmsy10 (display/text), cmsy7 (script),
cmsy5 (scriptscript) — the optically scaled fonts are NOT 10pt×0.7/0.5:
cmsy7 sup2 = 0.431115×7 = 3.0178pt (not 2.5402), cmsy5 sup2 = 2.0178pt.
Verified `x^{y^{2}}`: the 2 raised sup2(cmsy7) = 3.01779 (XeTeX \showbox).

## 4. layoutSpace style/quad-aware — layoutSpace

`\,` `\;` `\!` `\quad` `\qquad` are mu-spaces: width = em × quadEm(style) ×
size_pt (quadEm already existed for inter-atom glue: cmsy10 1.0 / cmsy7
1.170641 / cmsy5 1.472241).

| case | XeTeX | ztex before | ztex after |
|---|---|---|---|
| `\,` in script (x^{a\,b}) | glue 1.36574 = 3/18×1.170641×7 (\showbox) | 1.1667 | 1.3602 (see residual) |
| `\quad` in script | 1.0×1.170641×7 = 8.1945 | 7.0 | 8.1945 ✓ |

Residual: the PARSER stores `\,` = 0.166 em (not 3/18 = 0.166667) and
`\;` = 0.277 (not 5/18) — src/parse/parser.zig, out of this task's edit
scope. Layout can't correct the source value; ~0.4% short.

## 5. Text/script (and display) op box: cmex is design-size — the audit's
   "scale by size_pt" premise is empirically FALSE

cmex10 is an EXTERNAL font: TeX loads it at its 10pt design size for every
math size and never scales it. Verified at \fontsize{20}{24}: XeTeX draws
∑/∫ at 9.963 (10pt) scale while the text is 20.66pt; the display ∫ box stays
w=5.55557 (from the 20pt `\displaystyle\int_0^1 x` render: sup 1 at
148.712+5.55557+4.44446 scaled = 158.675). \showbox at 20pt: ∑ box
w=10.55559 (design), over-gap kern 1.99998 = bigop3 (design 2.0, not 4.0),
top bigop5 kern 1.0 (design), ∫ drawn from "cmex/m/n/13.99994" but the PDF
scale is 9.9626.

Changes: layoutOp's display branch drops the size_pt scaling (box + drawn
glyph fudge fixed at the 10pt design size); the text/script branch was already
design-size (kept); layoutOpLimits' bigop_spacing1–5 and the display op's ic
are now design-size (axis still scales — it is a cmsy param).

| case (20pt doc) | XeTeX | ztex before | ztex after |
|---|---|---|---|
| display ∑ box w | 14.44448 | 28.889 (scaled) | 14.44448 ✓ |
| ∑ drawn size | 9.963 (10pt design) | 28 (20×1.4) | 14 (10×1.4 fudge) ✓ |
| over-limit n (rel row) | −15.0 = op_top −13.0 − kern 2.0 | −17.0 (kern 4.0) | −15.0 ✓ |

At 10pt everything is unchanged (s(v,10) = v); the 10pt corpus renders match
XeTeX to <0.001pt (per-glyph; the ~0.005/char PDF drift on `\int_0^1 x\,dx`
is the mutool/LM glyph-advance artifact — \showbox structure is exact).

## Files touched

- src/layout/layout.zig only (as scoped). opTailIc, layoutFraction geometry,
  layoutOpLimits geometry (10pt), superflat box model, spans: unchanged.
- tests/goldens intentionally NOT touched (regenerate).
