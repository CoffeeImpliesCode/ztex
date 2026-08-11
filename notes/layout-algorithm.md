# ztex math layout vs MicroTeX and Tectonic/XeTeX

Sources: ztex `src/layout/{layout.zig,metrics.zig}`; MicroTeX `res/builtin/tex_param.res.cpp`,
`atom/{atom_basic,atom_impl}.cpp`, `core/glue.cpp`; Tectonic `engine_xetex/xetex/xetex-math.c`
(Web2C port of Knuth's `mlist.c`; params read from tfm fontdimens or OpenType MATH table —
algorithm identical to TeX/MicroTeX). All values at 10pt base. MicroTeX em-units ×10 → pt.

## Axis & sizes

| Param | MicroTeX (pt) | TeX/CM tfm (pt) | ztex | Delta |
|---|---|---|---|---|
| axis_height | 0.25em = 2.5 | 2.5 | 2.5 | agree |
| script factor | 0.7 (script), 0.5 (scriptscript) | 0.7 / 0.5 | 0.7 always (no 0.5) | close (0.7·0.7 = 0.49 ≈ 0.5 stacked) |
| cramped styles | D′ T′ S′ SS′ exist | yes | none | differs (denominator, roots) |

## Superscripts

- **TeX/MicroTeX**: `shift_up = max(base.height − sup_drop, sup1|sup2|sup3, sup.depth + x_height/4)`
  where sup_drop = 3.86, sup1 = 4.13 (display), sup2 = 3.63 (text), sup3 = 2.89 (cramped).
  For a 4.3pt-tall base in text style: **3.63pt**. Tectonic: `xetex-math.c:2448,2694`.
- **ztex**: `shift = base.height + 3.0` → 7.3pt for same base. The 3.0 is a fixed raise, not a
  drop, and the sup1/2/3 and `depth + x_height/4` floors are absent.
- **Delta: differs** — superscript baseline ~3.7pt too high.
- Horizontal: ztex gap 0.1em (1.0pt) after base; MicroTeX SCRIPT_SPACE 0.5pt; both ignore
  per-glyph italic-correction delta (MicroTeX adds a `delta` strut for chars like f/x).
  **differs** (2× gap, no delta).

## Subscripts

- **TeX/MicroTeX**: `shift_down = max(base.depth + sub_drop, sub1, sub.height − 0.8·x_height)`,
  sub_drop = 0.5, sub1 = 1.5; with both scripts sub1 → sub2 = 2.47 and interspace floor
  `4·rule_thickness` = 1.6pt (shifts grow to fit). Tectonic `xetex-math.c:2563-2568,2810-2828`.
- **ztex**: `shift = base.depth + 0.5` (sub_drop only), no sub1/sub2 floor, no 1.6pt
  interspace enforcement.
- **Delta: differs** — for a depth-0 base: 0.5 vs 1.5 (1.0pt too low); sup+sub may collide.

## Fractions

- **TeX**: rule centered on axis; `shift_up/down` from axis: display num1 = 6.77 / denom1 = 6.86,
  text num2 = 3.94 / denom2 = 3.45; clearance floor `clr` = 3·thickness (1.2pt, display) or
  thickness (0.4pt, text); `\atop` (no rule): clr = 7·t / 3·t. Tectonic `xetex-math.c:2064-2138`.
  Numerator style = current (non-cramped); denominator = cramp one level down (display→10pt text,
  text→7pt script).
- **ztex**: baseline shifts = axis ± 3.0 fixed both styles; no num1/2/3, denom1/2, no clearance
  floor; num and den both laid out in `.text` at full size (denominator never shrinks or cramps).
  Rule width = max(num, den) ✓; `\atop` adds 0.4pt height.
- **Delta: close in text style (3.0 vs 3.94/3.45, den should be 0.7×), differs in display**
  (6.77/6.86 vs 3.0 → tight), denominator ~1.43× too large in text-style fractions.

## Big-op limits (display)

- **TeX**: over gap = `max(bigop1, bigop3 − over.depth)` = max(1.11, 2.0 − d) ≈ 2.0 typical;
  under gap = `max(bigop2, bigop4 − under.height)` = max(1.67, 6.0 − h) ≈ 6.0 typical; outer
  padding bigop5 = 1.0 above/below scripts. Tectonic `xetex-math.c:1488-1544`.
- **ztex**: `gap = 0.2em` (2.0pt) both sides, centered; no bigop2/4/5; `big_op_spacing1` in
  `GlueParams` is dead (unused by `layoutOpLimits`).
- **Delta: over agrees (2.0 vs 2.0), under differs** — 2.0 vs 6.0 (~3× too tight); missing
  1.0pt outer padding.

## Spaces / glue

- **Explicit**: TeX thin = 3/18, med = 4/18, thick = 5/18 em, quad = 1em. ztex `\,` 0.166em ✓,
  `\;` 0.277em ✓, `\quad` 1em ✓, `\qquad` 2em ✓, `\!` −0.166em ✓; no `\>` (4/18 med).
  **agree** (minus med).
- **Inter-atom**: MicroTeX inserts glue-table spaces (ord-bin med, ord-rel thick, … suppressed in
  script styles). ztex `layoutRow` concatenates children with no glue — **differs (missing)**.

## Baseline/axis

- Fraction vbox baseline = axis ✓ (rule shift 0). Op limits: ztex centers op on baseline ✓;
  TeX shifts display op so its center sits on the axis (no-op for symmetric glyphs; ztex op is a
  fixed 0.8×0.7em char, no next-larger variant).

## Biggest deltas

1. **Superscript raise** — ztex `height+3.0` vs TeX `max(height−3.86, 3.63)`; ~3.7pt too high.
2. **Fraction gaps** — fixed ±3.0 vs display num1/denom1 6.77/6.86 (and missing den style shift).
3. **Big-op under-gap** — 2.0 vs 6.0 (bigop4); missing bigop5 padding.
4. **No inter-atom glue** (ord-bin/ord-rel spaces) and **no italic-correction handling**.
5. Subscript floor (sub1 1.5 / sub2 2.47) and 1.6pt sup/sub interspace absent.
