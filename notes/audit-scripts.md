# audit-scripts — ztex layoutScript vs MicroTeX ScriptsAtom + XeTeX make_scripts

Date 2026-08-12. Authoritative = XeTeX (xetex-math.c:2410-2863 make_scripts; fontdimens xetex-XeTeXOTMath.cpp:78-87).
ztex layoutScript = src/layout/layout.zig:368-527. MicroTeX = atom_basic.cpp:446-591.

## Residual #1 (display-op subscript -0.09pt) — NOT REPRODUCED
ztex computes base_d = bb.depth + base_shift = 8.61123 (axis-shifted depth, NOT the raw 22.22 box depth) and
shift_down = max(8.61123+0.5, sub2=2.47217) = 9.11123, EXACTLY XeTeX make_scripts (9.11122 from \showbox).
The premise "ztex uses bb.depth=22.22" is false for the current code. NOT a bug.

## Real deviations (ranked)
| # | rule | ztex/MicroTeX | XeTeX | magnitude |
|---|---|---|---|---|
| 1 | both-script clearance | raise the SUPERSCRIPT to gain 4*rt | LOWER the SUBSCRIPT | up to 1.6pt (collision cases) |
| 2 | psi (0.8*x_height) | fires whenever 0.8*xh > (shift_up - sup.depth) | only applied INSIDE the clearance guard | up to ~0.5pt |
| 3 | sup_drop | hardcoded 2.4722 (display op) / 3.86108 (10pt) for all bases | read from script-size math-symbols font (cmsy7) for ALL bases | up to 1.39pt (tall bases) |
| 4 | cramped style | none — scripts in numerators/sqrt use sup2=3.62892 | TeX uses sup3=2.88889 in cramped styles | up to 0.74pt |

## Exact matches
script style selection (display/text->script, script->scriptscript, 0.7/0.5),
horizontal placement (sup at width+ic, sub at width), sup1/sup2/sub1/sub2 floors,
x_height/4, script_space 0.5 fixed.
