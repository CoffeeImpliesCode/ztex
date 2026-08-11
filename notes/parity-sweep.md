# ztex vs MicroTeX - adversarial parity sweep (20pt)

Date: 2026-08-12. Corpus: 16 formulas. Both rendered headless at 20pt.
ztex: `zig-out/bin/ztex -i F -o n.svg -s 20 -b white`. MicroTeX:
`clatexmath -headless "-input=F" -output=n_ref.svg`. Artifacts + all SVGs +
parser + analysis in `/tmp/parity/`. Glyph geometry: ztex from `<text x y
font-size>` (baseline anchor); MicroTeX from `<use x y>` + defs path bboxes.
ztex op box heights are metric-derived (metrics.zig; display glyph_size =
2*20 = 40pt).

Font caveat: resvg raster of ztex `<text>` uses font fallback (ink ~27px for
a SUM that metric-boxes at 40px); all layout numbers below come from the
deterministic SVG coordinates / metrics table, NOT rasters.

## Per-formula verdicts (px @20pt; delta = ztex - MicroTeX; >0.5 flagged)

| # | Formula | ztex | MicroTeX | Delta | Verdict |
|---|---------|------|----------|-------|---------|
| 1 | `a+b` | glue adv 15.02/20.00 | 15.02/20.00 | 0.00 | PASS |
| 2 | `x=y` | 16.99/21.11 | 16.98/21.11 | ~0.00 | PASS |
| 3 | `x^2` | sup raise 8.26 | 8.26 | 0.00 | PASS |
| 4 | `x_2` | sub drop 3.00 | 3.00 | 0.00 | PASS |
| 5 | `x_i^2` | sup 8.26 / sub 4.94 | 8.26 / 4.94 | 0.00 | PASS |
| 6 | `\frac{x+1}{y-1}` | num->rule 8.13, den->rule 18.32 | 8.53 / 18.72 | -0.40 | PASS |
| 7 | `\frac{a}{b}+c` | num 8.13, den 18.32 | 8.53 / 18.72 | -0.40 | PASS |
| 8 | `\sum_{i=1}^{n} x_i` | op box 40.00, limits centered | op 28.00 | **+12.00** | FAIL |
| 9 | `\int_0^1 x\,dx` | op box 44.44 | 44.44 | 0.00 | PASS |
| 10 | `\sqrt{x}` | **unsupported** (UnknownCommand) | renders | - | FAIL |
| 11 | `(a+b)` | 7.78/15.02/20.00/8.58 | same | 0.00 | PASS |
| 12 | `[a,b]` | 5.56/10.57/8.89/8.58 | 5.55/10.57/8.89/8.59 | ~0 | PASS |
| 13 | `a\cdot b` | dot->b adv 14.44 | 10.00 | **+4.44** | FAIL |
| 14 | `\mathbf{x}+\mathrm{ab}` | x->+ 15.88 (plain x) | 16.58 (bold x) | **-0.70** | WARN |
| 15 | `\text{hi}` | h->i 11.52 | 11.11 | +0.41 | PASS |
| 16 | `\sum_{i=1}^{n} \frac{1}{i^2}` | op box 40; frac 8.13/18.68 | op 28; 8.53/18.72 | **+12.00**/-0.40 | FAIL |

## Ranked discrepancies (>0.5px)

1. **SUM display operator 12px too big** (formulas 8, 16). ztex SUM box =
   40px (metrics.zig: SUM depth 10.00013 at 10pt x 4 for 40pt display) vs
   MicroTeX display SUM = 28px. INT (d=11.11122 -> 44.44px) matches Micro
   exactly, so the per-symbol table is right for INT but overestimates SUM
   depth by ~43%. Effect: SUM limits (n above, i=1 below) are pushed farther
   from the operator and total formula height grows. Most impactful (>=5px,
   hits every SUM).
2. **`\cdot` glyph width 4.44px too wide** (formula 13). ztex has no U+22C5
   entry in its metric table -> `glyphEstimate` gives width 0.5em = 10px; the
   real dot is ~5.56px. Advance dot->b = 14.44 vs Micro 10.00. Every `\cdot`
   is ~1.8x too wide.
3. **`\mathbf` is a visual no-op (delta -0.70 advance)** (formula 14). ztex
   emits `<text>` without `font-weight` and has no bold metrics; `\mathbf{x}`
   renders a plain thinner x (x->+ 15.88) vs Micro's bold x (16.58). Feature
   gap (weight), not a position bug.

Non-flagged (all <0.5px): inter-atom glue, script raise/lower, fraction
num/den vs rule (consistently -0.40 = ztex slightly tighter), INT size, parens
and brackets spacing, `\text` advance.

## Denominator `-` glue (requirement 3)
Verified in formula 6 `\frac{x+1}{y-1}`. Denominator rows:
- ztex: y->- adv 14.25, -->1 adv 20.00 (den baselines y=40.14 all three).
- MicroTeX: y->- adv 14.25, -->1 adv 20.00 (baselines y=50.14).
Both engines glue the denominator minus identically (leading `-` demoted to
ord -> no space before it; ord->ord med space after). No discrepancy; ztex
does NOT leave an extra gap, and does NOT mis-glue it - parity confirmed.

## Single most impactful
**SUM display operator sized 40px instead of 28px (+12px, ~43% too deep).**
It changes the core geometry of every SUM/PROD formula (limits distance,
overall height) and is the largest single delta in the sweep. Fix target:
metrics.zig SUM depth (0x2211 d=10.00013) is too large - should be ~7.0 at
10pt (28px at 40pt) to match MicroTeX/TeX's SUM ~ 1.4em. INT is already
correct.
