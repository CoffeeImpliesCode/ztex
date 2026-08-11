# audit-glue — ztex glue/spacing/role vs MicroTeX + XeTeX

Date 2026-08-12. Authoritative = XeTeX (tectonic/crates/engine_xetex/xetex/xetex-math.c).
MicroTeX = architecture reference. All at 10pt.

## Verdict (ranked)
| # | element | verdict | magnitude | fix |
|---|---|---|---|---|
| 1 | `opTailIc` bare-op branch (layout.zig:348-351) | DIFFERENCE — adds the italic correction after an UNScripted op (∫/∮). XeTeX make_op discards `delta=ic` for a no-script op (goto lab82, skips make_scripts); TeXbook p.170 ic applies to SCRIPTED ops (sup placement), not bare. ztex adds s(dop.ic)=4.44446 (display) / 1.94446 (text) after every bare ∫/∮. | +4.44pt / bare ∫ | VERIFY empirically; if confirmed remove the `n.tag==.op` branch (bare ops carry no tail kern). |
| 2 | glue_table 8×8 | EXACT — all 64 entries match XeTeX offset_table (xetex-math.c:3284) incl. script suppression | 0 | none |
| 3 | glue_em {0,3,4,5}/18 | EXACT thin=3mu med=4mu thick=5mu (thin 1.667, med 2.222, thick 2.778 at 10pt) | 0 | none |
| 4 | quadEm(style) | CORRECT — 1.0 / cmsy7 1.170641 / cmsy5 1.472241. (MicroTeX scales cmsy10 by 0.7 — its error, ztex right) | 0 | none |
| 5 | script/scriptscript glue suppression | EXACT — thin kept only for ord<->op, op->op, close->op, inner->op | 0 | none |
| 6 | bin demotion | EXACT vs XeTeX (left/right variants moot without \left) | 0 | none |
| 7 | roleOfCp | CORRECT — all classified codepoints match TeX mathcodes | 0 | none |
| 8 | leftRole/rightRole | CORRECT (fraction=>ord, script-op=>op) | 0 | none |
| 9 | layoutRow glue loop | CORRECT | 0 | none |

## +0.06pt/block drift NOT in this subsystem
Every glue cell, em fraction, quad, suppression, demotion is exact — 0.06pt is a fractional sub-mu error impossible here. Look outside (fraction nulldelimiterspace, scriptspace, display-op box, f32 rounding).

## XeTeX offset_table
ORD "02340001" OP "22*40001" BIN "33**3**3" REL "44*04004"
OPEN "00*00000" CLOSE "02340001" PUNCT "11*11111" INNER "12341011"
(0 none, 1 cond-thin, 2 thin, 3 cond-med, 4 cond-thick; ztex nibbles match all 64)
