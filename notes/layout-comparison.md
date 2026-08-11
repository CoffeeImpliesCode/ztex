# ztex vs MicroTeX layout comparison

Date: 2026-08-12
Corpus: 12 formulas covering ztex-supported constructs (plain, superscript,
subscript, frac, big-op limits, `\text`, `\mathbf`/`\mathrm`, spacing).
Reference renderer: MicroTeX (`clatexmath -headless`).
All artifacts: `/tmp/ztex_cmp/` (`<n>.svg` = ztex, `<n>_ref.svg` = MicroTeX),
machine-readable results in `/tmp/ztex_cmp/results.json`.
Comparison script: `scripts/compare_geom.py` (run: `python3 scripts/compare_geom.py`).

## Working recipe

```sh
# ztex (white bg, size 20):
cd ~/projects/ztex
zig build run -- -i '<formula>' -o /tmp/ztex_cmp/<n>.svg -s 20 -b white

# MicroTeX headless reference (build once; /tmp/fcshim per the repo recipe):
cd ~/projects/MicroTeX
nix-shell -p gtkmm3 gtksourceview gtksourceviewmm cairomm fontconfig freetype tinyxml-2 --run \
  '_build/src/clatexmath -headless "-input=<formula>" -output=/tmp/ztex_cmp/<n>_ref.svg'
```

## Comparison method

MicroTeX SVGs draw every glyph as `<use xlink:href="#glyph-N-M" x y/>` with the
outline `<path>` in `<defs>`; the use origin is the baseline for text glyphs and
the box top for big operators. ztex draws every glyph as
`<text x y font-size>`. The script parses both, computes each glyph's visual
bbox (MicroTeX: use pos + defs path bbox; ztex: text pos + font size), and
checks the same RELATIVE invariants in both engines. Absolute positions are
never compared (fonts differ). Font sizes/scale ratios: ztex scripts are
`size_pt * 0.7` (layout.zig:143,189); MicroTeX script glyphs measure ~0.70 of
full size (script "1" h=9.33 vs full-size "1" h=13.31).

## Per-formula verdicts (all PASS — structural invariants hold in BOTH engines)

| # | Formula | Verdict | Key geometry (ztex / MicroTeX) |
|---|---------|---------|-------------------------------|
| 1 | `x` | PASS | single glyph; baseline present |
| 2 | `x^2` | PASS | sup ABOVE (y 6.02 < 20.62 / 19.02 < 27.28), RIGHT of base, smaller (fs 14<20 / glyph 9.33 vs full 13.31) |
| 3 | `x_2` | PASS | sub BELOW (y 9.6 > 8.6 / 21.61 > 18.61), right of base |
| 4 | `x_i^2` | PASS | sup above (6.02/19.02), sub below (21.62/32.22); 2 and i share x (11/21.43) |
| 5 | `\frac{1}{2}` | PASS | num 8.6 < rule 19.2..20.0 < den 30.6 (z); num vis 22.9 < rule 31.4 < den vis 36.8 (m); rule spans glyphs in both |
| 6 | `\frac{x+1}{y-1}` | PASS | num (x+1, one baseline) above rule, den (y-1, one baseline) below; rule 19.2..20 / 31.4; LTR within each |
| 7 | `\sum_{i=1}^{n} x_i` | PASS* | limits above/below op; row baseline shared (∑=x at 26.02 / 45.03) — *see Finding 3 (placement differs) |
| 8 | `\int_0^1 x\,dx` | PASS* | 1 above (6.02 / vis bottom 19.0), 0 below (27.02 / vis top 49.4); x,d,x row aligned (26.02 / 40.84) — *see Finding 3 |
| 9 | `\text{hi}` | PASS | h,i on one baseline (13.8 / 23.89), adjacent, LTR |
| 10 | `\mathbf{x}+\mathrm{ab}` | PASS* | x,+,a,b LTR on one baseline (13.8 / 23.89) — *see Finding 1 (weight no-op) |
| 11 | `a\,b\;c\quad d` | PASS | gaps 3.3 < 4.9 < 19.7 (z) and 4.0 < 5.8 < 20.1 (m); quad ≈ 1em (20) in both |
| 12 | `\prod_{k=1}^{m} k` | PASS* | m above, k=1 below, row k aligned — *see Finding 3 |

No formula shows a hard layout bug in ztex: no wrong order, no superscript
below its base, no rule outside the fraction. All structural invariants that
must hold independent of font metrics hold in both engines.

## Concrete discrepancies

### 1. `\mathbf` is a visual no-op in ztex (feature gap, not a layout bug)
ztex emits `<text>` without any `font-weight` attribute (svg.zig:45) and the
layout has no bold font selection; `\mathbf{x}` renders an ordinary `x`.
MicroTeX renders a distinct bold `x` (glyph outline differs: w 11.3/h 8.88 vs
plain w 9.9/h 9.06). Structural layout (order, baseline, sizes) matches; only
the glyph weight differs. If bold rendering is desired, svg.zig must emit
`font-weight` (and the layout a bold char style).

### 2. Frac parts are NOT shrunk to `\scriptstyle` — in BOTH engines
ztex draws `\frac` numerator/denominator at font-size 20 (same as body);
MicroTeX frac digits measure 13.31 units = full size (scripts measure 9.33 =
0.70). The two engines agree with each other, but both deviate from TeX, which
sets frac parts in `\scriptstyle` (0.7×). Not a bug between the engines — a
shared deviation from TeX convention worth revisiting.

### 3. Big-op limits: ztex CLI renders TEXT-style limits, not display style
This is the most significant real difference found:
- **ztex**: the CLI entry passes `.text` style (layout/root.zig:23), so
  `layoutOpLimits` (which centers limits over the operator, layout.zig:202-230)
  is **unreachable**. Limits go through the side-script path: `x_shift =
  base.width + gap` (layout.zig:157-170). Measured: ∑ at x=0, `n` at x=18 and
  `i=1` at x=18 (right edge of the 0.8em operator box), stacked above/below.
  The operator glyph is the TEXT-size ∑/∫/∏ (fixed 0.8em box).
- **MicroTeX**: display style by default — limits CENTERED over the operator
  (`n` center 24.4 ≈ ∑ center 24.45; `m` center ≈ ∏ center) and the operator
  is the DISPLAY-size variant (∑ glyph 28 units tall vs text ~13).
- TeX convention (display style): larger operator, limits centered above/below.
  ztex's placement (limits at the right edge, sub BELOW the baseline) matches
  neither the display convention nor the text-style side placement.
- Fix direction: expose a style (default `.display` for `\sum`/`\prod`/`\int`
  with `_{}^{}`), or pass `.display` from the CLI; the `layoutOpLimits` code
  already exists and is tested (layout.zig:449).

### 4. Inter-atom space widths differ (metric-dependent, both sane)
`\,` : ztex 3.3 px (≈ 3/18 em, TeX thin) vs MicroTeX 4.0-5.0 px (≈ 1/4 em).
`\;` : 4.9 vs 5.8. `\quad` : 19.7 vs 20.1 (both ≈ 1 em ✓). Ordering
thin < med < quad holds in both; absolute amounts depend on the space/glue
constants, not on layout structure.

## Notes
- MicroTeX places the `\int` upper limit to the upper-RIGHT of the tall ∫ glyph
  (x 30 vs ∫ ink 11.1..28.9); its bbox overlaps the ∫'s top in y only — no
  horizontal ink overlap, renders fine.
- ztex limit rows share the operator baseline exactly (∑ and x at 26.02); the
  `\int` row (x,d,x) is aligned in both engines.
- Raster caveat: resvg renders ztex `<text>` SVGs unreliably when zoomed
  (`-w`/`-z` shift glyphs via font fallback; 1x is exact). The comparison is
  therefore coordinate-based (SVG attributes), not raster-based; rasters at 1x
  were used only to recover ztex glyph widths for the spacing check.

## Fix applied (from discrepancy #3)

`layout/root.render` now defaults to `.display` style, so big-operator limits
render centered over a display-size operator via `layoutOpLimits` (previously
unreachable — the CLI passed `.text`, stacking limits beside the op). Regression
goldens for `\sum_{i=1}^{n}` regenerated. Verified: limits centered (n above,
i=1 below), matching the MicroTeX reference.
