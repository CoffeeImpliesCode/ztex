# Adversarial layout audit: ztex vs MicroTeX (20pt)

Both rendered through real binaries, same inputs. ztex: `zig-out/bin/ztex -i F -s 20`; MicroTeX: `clatexmath -headless`. Positions read from emitted SVG baseline coords. MicroTeX glue values from `src/core/glue.cpp` (thin=3, med=4, thick=5 units, factor=quad/18=em/18); TeX nominal params from `src/res/builtin/tex_param.res.cpp`. ztex renders root in `.display` (layout/root.zig:44); MicroTeX also display (limits on \sum, full-size frac parts).

Unsupported by ztex (cmd_map, parse/parser.zig:57-78): `\\sqrt`, `\\cdot`. Everything else in the corpus renders in both.

## Per-formula

| Formula | ztex gap (px@20) | MicroTeX gap (px@20) | Delta |
|---|---|---|---|
| `a+b`  a→+ | 0 | med 4.44 | **-4.44** |
| `a+b`  +→b | 0 | med 4.44 | **-4.44** |
| `x=y`  x→=, =→y | 0 each | thick 5.56 each | **-5.56 each** |
| `a b`  a→b (ord-ord) | 0 | 0 | match |
| `a,b`  a→, | 0 | 0 (ord-punct=0) | match |
| `a,b`  ,→b | 0 | thin 3.33 | **-3.33** |
| `x+y+z` (each ord-bin-ord) | 0 each | 4.44 each | **-4.44 each** |
| `x^2+y^2` x²→+ | 0 | 4.44 | **-4.44** |
| `f(x)` f→( (ord-open) | 0 | 0 | match (ztex also drops f's 0.4em ital-correction strut) |
| superscript raise | 14.6 | 8.26 | **+6.34 (too high)** |
| subscript drop (depth-0 base) | 1.0 | max(depth+0.5, sub1=3.0) | **-2.0 (too low)** |
| frac num-to-rule | 10.6 | 8.1 | **+2.5 (num floats high)** |
| frac den clearance | **-3.2 (OVERLAP)** | +4.1 | **-7.3** |
| \sum glyph height | 14 (0.7em) | ~28 (display op) | **-50% (too small)** |
| \sum under-gap (op bottom→sub) | 4 | ~8.5 | **-4.5** |

## Ranked bug list (biggest visual impact first)

1. **Inter-atom glue is MISSING** — layout.zig:100-124 (`layoutRow` does `x += cb.width` at :120, no glue). Every ord-bin/ord-rel/ord-punct adjacency renders flush. `x=y` loses 5.56px/side; `a+b` loses 4.44px/side; `a,b` loses 3.33px after comma. Fix: in `layoutRow`, before `x += cb.width`, insert glue from a TeX table (ord-bin med, ord-rel thick, ord-punct thin; suppress in `.script`/`.script_script`) using each child's atom type. **THE single most impactful fix — it corrects every operator/relation/punctuation formula.**
2. **Superscript raised ~6.3px too high** — layout.zig:170-171: `shift = -(bb.height + raise)` with fixed `raise=sup_raise`(3.0, metrics.zig glue). Missing TeX `max(base.height-supdrop, sup1|2|3, sup.depth+x_height/4)` (supdrop 3.86, sup2 3.63 → 7.26px@20). ztex 14.6 vs 8.26px.
3. **Fraction denominator overlaps the bar / parts never shrunk** — layout.zig:298-299 lays num AND den at `.text` full size; :321 fixed `den_shift = axis + frac_den_gap` (6px@20). Full-size den 'b' ascender 13.8px > 11px shift ⇒ b punches 3.2px THROUGH the bar. MicroTeX shrinks den to \scriptstyle (0.7, ~9.7px) and enforces denom1 clearance ⇒ 4.1px. Latent 1.43× part-size error in text/script contexts. Fix: shrink num/den per style + use num1/denom1 (6.77/6.86em) + clearance floor.
4. **Big-op too small + limits too tight** — layout.zig:277-278 fixes glyph at 0.8em×0.7em (14px tall) vs MicroTeX display \sum ~28px (−50%). :201 limits gap 0.2em both sides (4px) vs bigop4-based ~8.5px; no bigop5 (1em) outer padding. Op centered on baseline, not axis-shifted.
5. **Subscript drop floor missing** — layout.zig:179-180 `shift = bb.depth + sub_drop(0.5)`; missing `max(depth+subdrop, sub1=1.5)` floor ⇒ 2px too low on depth-0 bases; sup/sub 1.6px interspace floor absent.
6. **Script sizes**: 0.7 used for both script & scriptscript (no 0.5); script gap 0.1em (2px) vs SCRIPT_SPACE ~0.5px; no italic-correction delta strut. Minor.
7. **\text uses math table metrics** (h width 5.0pt@10) with no inter-letter spacing/kerning — minor for this corpus.

## Glue-issue quantification
`layoutRow` inserts no space between any adjacent atoms. Versus MicroTeX/TeX at 20pt: ord-rel **5.56px/side** missing (thick=5/18em), ord-bin **4.44px/side** (med=4/18em), ord-punct **3.33px** (thin=3/18em). Script styles: these glues are 0 in TeX too, so ztex matches there — the gap is in text/display. ord-ord and ord-open correctly 0.

## Biggest visual impact (ranked)
1. Inter-atom glue (fixes a+b, x=y, x+y+z, x^2+y^2, a,b, frac+c in one change).
2. Fraction denominator clearance (fixes bar-punch-through; pairs with #3 part shrink).
3. Superscript raise (6.3px, affects x^2+y^2, \sum).
4. Big-op size (\sum half-size).
