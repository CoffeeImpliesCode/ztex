# pipeline-metrics — STAGE 2 audit: ztex metrics.zig values, size scaling, optical selection

Date 2026-08-13. Authoritative reference: real CM TFM (tftopl on TeX Live 2025), MicroTeX
`src/res/font/*.def.cpp` + `tex_param.res.cpp`, tex.web make_scripts/mathsy, and direct XeTeX
`\showbox` measurements (plain xetex at 10pt; xelatex font-substitution warnings at 20pt).
Repo: ~/projects/ztex (Zig 0.16). READ-ONLY; this file only.

Method: parsed ztex `table`/`table7`/`table5`/`display_ops`/`glue`, dumped 14 CM TFMs with
tftopl, and compared row-by-row. Font per row resolved via the row's comment
("cmsy10 33" etc., MicroTeX def-file row numbering) and via authoritative LaTeX mathcodes
(fontmath.ltx / plain.tex mathchardefs) mapped to TFM slots.

---

## Headline verdict

**There is NO double-scaling bug, and the optical tables are exact.** `glyphAt` returns the
optical font's values in the same em×10 convention as the 10pt table; the layout scales once
with `s(v, size_pt) = v·size_pt/10`. At size_pt = 7.0 that lands on the true cmr7 width
(e.g. `!` 3.23415×0.7 = 2.264 pt = cmr7 TFM 0.46202em×7). Verified value-by-value against
the real TFMs:

- `table` (252 rows): 122 rows with explicit MicroTeX row citations **exact**; the only
  delta is 0x2026 `…` (the documented 3×\ldotp composite). MicroTeX def values themselves
  equal real TFM values for all 162 symbols checked via mathcodes.
- `table7` (201 rows) / `table5` (201 rows): **153/154 exact** vs cmr7/cmmi7/cmsy7 and
  cmr5/cmmi5/cmsy5 (the one "miss" is the `″` composite, 2×\prime, deliberately). The 7pt
  values are genuinely optical (e.g. `±` 8.92861 vs 7.77781×0.7 = 5.44), not 0.7×table10.
- `display_ops` (8 entries): **exact** vs cmex10 NEXTLARGER chars (∑ O130 = 14.44448 /
  1.00001 / 15.00012; ∫/∮ O111/O132 = 5.55557 / 0 / 22.22246 / ic 4.44446; ∏ O131,
  ∐ O141, ⋂⋃⨆ O107 — all verified by tftopl, incl. the base→next chain O120→O130).
- `glue` (GlueParams): all MicroTeX values ×10 **exact** (axis 2.5, rt 0.4, num1 6.76508,
  num2 3.93732, num3 4.43731, denom1 6.85951, denom2 3.44841, sup1 4.12892, sup2 3.62892,
  sup3 2.88889, sub1 1.5, sub2 2.47217, supdrop 3.86108, subdrop 0.5, bigop1-5, x_height
  4.30555). Layout's `sym_cmsy7`/`sym_cmsy5` (sup1-3, sub1-2) and `quadEm` (1.170641 /
  1.472241) equal cmsy7/cmsy5 TFM fontdimens ×10 **exactly**.
- `glyph`/`lookupAscii`: binary search is a correct lower-bound search over the sorted
  table (sortedness is test-asserted); `ascii_lut` is comptime-derived from the same table,
  so it is bit-identical by construction. Correct.

The prior audit's concern ("does glyphAt return the optical value and then ALSO scale it?")
resolves to **no** — the convention is uniform end to end; the optical tables were
transcribed from the real cmr7/cmmi7/cmsy7/cmr5/cmmi5/cmsy5 TFMs, not fabricated.

---

## Findings, ranked by impact

### F1 — Script/scriptscript SIZES are right only at a 10 pt base; at the CLI default 20 pt the scriptscript level is 17 % too small (size-band + size-model issue)
| | |
|---|---|
| ztex | `layoutScript`: `s_size = size_pt·0.7` (script), `size_pt·(0.5/0.7)` (scriptscript); `glyphAt` selects `table7` iff `size_pt ∈ (6.4, 7.6)`, `table5` iff `(4.5, 5.5)`, else linear scale of `table`. |
| reference | TeXbook model (0.7/0.5 of current) is exact at 10 pt (7/5 → cmr7/cmr5 ✓). LaTeX `\DeclareMathSizes` (fontmath.ltx): 10→7/5, 11→8/6, 12→8/6, 14.4→10/7, 17.28→12/10, **20→14.4/12**, 25→20/17.28. XeLaTeX at 20 pt confirms: "OML/cmm/m/it in size <13.99994> not available → size <14.4> substituted". |
| verdict | Correct at 10 pt (the corpus-verified size). Wrong at 20 pt (default `-s` and all tests): script 14.0 vs 14.4 (−2.8 %), scriptscript 10.0 vs **12.0 (−17 %)**. Wrong at 11/12 pt body: script 7.7/8.4 falls out of band → cmr10×0.77/0.84 linear, while TeX uses optical cmr8 (script 8) — widths up to ~10 % off. The bands are a proxy for "optical fonts exist at 7/5"; they fire exactly at 10 pt base and 14.4-pt scriptscript (7.2), and miss 11/12 pt. |
| magnitude | 2.0 pt on a 10 pt scriptscript glyph at 20 pt base (e.g. x-height 4.31 vs 5.17); 0.4 pt on scripts. |
| fix | Drive script sizes from a `\DeclareMathSizes`-style table (10→7/5, 12→8/6, 20→14.4/12, …) instead of pure multiplication; or document 10-pt-only fidelity and pick a 10 pt default. |

### F2 — `supdrop`/`subdrop` are size-scaled but TeX reads them from the SCRIPT-SIZE symbol font: constants 2.4722 / 0.5 pt, not `s(2.4722, size_pt)`
| | |
|---|---|
| ztex | `layoutScript`: `supdrop = s(2.4722, size_pt)`; `subdrop = s(gl.subdrop = 0.5, size_pt)` (10pt-base convention). |
| reference | tex.web §13827: `sup_drop = mathsy(18)`, `sub_drop = mathsy(19)`; §14894 `shift_up := height(z) − sup_drop(t)` with `t = script_size` (or `script_script_size`); `mathsy` resolves family 2 **at size code t** → cmsy7@7pt / cmsy5@5pt, whose native SUPDROP is 2.4722 pt at BOTH sizes (0.353171em×7 = 0.494446em×5) and SUBDROP 0.5 pt — **independent of the current style**. XeTeX `\showbox` confirms: `{x\over y}^2` sup shift 4.479 = 6.9512 − 2.4722; `\int^2` shift 5.5834 = 8.0556 − 2.4722 (both text style, 10 pt). |
| verdict | Wrong at every size except exactly 10 pt text. ztex gives 1.7305 at 7 pt (TeX 2.4722), 1.236 at 5 pt (TeX 2.4722), 4.944 at 20 pt (plain TeX 2.4722; LaTeX cmsy10@14.4 ≈ 5.56). subdrop 0.35/0.25/1.0 vs 0.5/0.5/0.72. |
| magnitude | Superscripts on box nuclei (fractions, \left..\right, ops) up to **1.24 pt too high** at scriptscript (10 pt base), **2.47 pt too low** at 20 pt text; subscripts 0.15–0.5 pt off. |
| fix | Use constant `supdrop = 2.4722`, `subdrop = 0.5` (native pt, unscaled) for 10-pt-base docs; if non-10-pt bases must work, compute from the script-size symbol font the format would load. (Previous audit-scripts residual #3 fixed the VALUE from 3.86108 to 2.4722 but kept the wrong scaling.) |

### F3 — `glyph`/`glyphAt`/`lookupAscii` ignore style: `\text{...}` and `\mathrm{...}` are laid out with cmmi10 (math-italic) widths, TeX uses cmr10 (roman)
| | |
|---|---|
| ztex | `glyph(fm, cp, style)` does `_ = style`; single entry per codepoint (documented). `layoutText` (`\text{hi}`) and `\mathrm` both hit the cmmi10 rows for A-Z/a-z. |
| reference | TeX: `\text`/`\mathrm` → family 0 = cmr10. Width deltas (10 pt): `f` cmmi 4.896 vs cmr 3.056 (**+1.84 pt, +60 %**), `i` +0.67, `j` +1.06, `T` −1.38, `V` −1.67, `Y` −1.69, `W` −0.83, `H` +0.81, `K` +0.72, most uppercase +0.4…+0.8. "hello": 21.23 vs 20.56 (+0.68 pt, +3.3 %). |
| verdict | Wrong for text-mode and \mathrm letters; right for math (italic) letters. |
| magnitude | Up to 1.84 pt per glyph at 10 pt (3.7 pt at the 20 pt default); a `\text{ff}` is ~60 % too wide. |
| fix | Add a roman (cmr10) table dimension keyed by `CharStyle` (values are all in hand: cmr10 TFM), or at minimum route `\text` through cmr10 rows. |

### F4 — `glyphEstimate` still catches 65 common math codepoints (the listed examples are covered; the gaps are Greek variants, triangles, \imath/\jmath/\hbar, suits, music)
| | |
|---|---|
| ztex | Table covers everything the task listed: \prime \partial \infty \nabla \angle \vdash \perp \neg \land \lor \Rightarrow \rightarrow and all long arrows (⟵…⟺), ≠ ∉ ≢ ≅ ≐ ↦ ↩ ↪ ⋈ ⋯ ″. |
| reference | Remaining gaps (real TFM width at 10 pt vs estimate 5.0): ζ 4.375, η 4.965, ι 3.539, κ 5.762, ν 4.940, ξ 4.375, ο 5.170, ρ 5.170, τ 4.372, υ 5.403, χ 6.257, ψ 6.514, ς/ϑ/ϖ/ϱ/ϵ variants; Ξ 6.667, Υ 7.778, Ψ 7.778; \imath 3.225, \jmath 3.840, \hbar ≈ 6.1 (cmmi ħ not in CM), \mho, \eth; △/\bigtriangleup **8.889** (estimate is 44 % narrow), ▽ 8.889, □ 8.889, ■, ◊; ♠♣♥♦, ♭♮♯; § ¶ © £ ¥; \measuredangle, \backprime, \nexists, \models, \nsim, \napprox, \nleq, \ngeq, \nsubseteq, \nsupseteq, \lll, \ggg. Heights are off too (estimate h=7.0 vs real 4.306 for ι → 63 % too tall). |
| verdict | The most common remaining offenders: ζ…ψ (12 letters, incl. `\chi` used in chi-squared), \triangle, \imath/\jmath (hats in physics/engineering), \hbar, suits/music, \S\P. Each renders at the 5.0/7.0/2.0 estimate box and — worse — draws the Unicode glyph at that wrong advance. |
| magnitude | −1.78…+3.89 pt per glyph at 10 pt; height errors to +2.7 pt. |
| fix | Add the 24 missing Greek rows (cmmi10 slots 11–33 + cmr10 0–10 — values verified above), cmmi10 123/124 (\imath/\jmath), cmsy10 52/53/54 (triangles), cmsy10 113/114 (♭/∇ already in), plus the text symbols from cmr10/cmsy10. |

### F5 — Big-op DISPLAY draw scale is a confirmed ink fudge; box is TFM-exact but drawn ink ≠ box
| | |
|---|---|
| ztex | `layoutOp` display branch: box = cmex next-larger (exact), drawn glyph = Unicode ∑/∫/∏ at `font-size = 10·scale` (1.4 / 2.0). |
| reference | cmex10 O130 ink box: h+d = 16.0 pt, advance 14.44 pt (at 10 pt design). Drawn Unicode ∑ at 14 pt has ink ≈ 12.6–14 pt (font-dependent) and its OWN advance (SVG `<text>` uses the font advance, not the box width) ≈ 13–14 pt ≠ 14.44 pt box. The 1.4/2.0 factors were tuned to a measured XeTeX ink height (≈1.4 em for ∑, ≈2.2 em for ∫) — i.e. an ink-height fudge, not the real cmex glyph. |
| verdict | Layout/limits are right (box values exact, limit gaps use the box, `ic` skew uses the real CHARIC 4.44446). The INK is short of the box by ~2 pt (∑) and ~2–4 pt (∫: box 22.22 pt vs ink at a 20 pt font), and the drawn advance misaligns following atoms by the font-vs-TFM advance difference. Same class as the audit-metrics headline (CM metrics + Latin-Modern ink). |
| magnitude | 2–4 pt ink/box mismatch on display ops; sub-pt advance error on neighbors. |
| fix | Draw the real cmex10 next-larger glyph paths at 10 pt (no scale), or accept as documented ink approximation; never rely on the scale to fix layout. |

### F6 — `denom3`/`sub3` GlueParams are dead values from no real source
| | |
|---|---|
| ztex | `glue()`: `denom3 = 1.63`, `sub3 = 1.333`, commented "standard Computer-Modern parameter set". |
| reference | MicroTeX has only num1-3, denom1-2, sup1-3, sub1-2 (no denom3/sub3); tex.web mathsy params stop at sub2 + supdrop/subdrop + delim1/2 + axis (22 total; no denom3/sub3). TeX's script-style fraction uses denom2 and script-style sub floors use the SCRIPT font's sub1/sub2 (cmsy7/cmsy5 — ztex's `symFor` already does this correctly). |
| verdict | Dead code — never read by layout (grep: only defined in metrics.zig). Misleading documentation, zero behavioral impact. |
| fix | Delete the two fields (or relabel as MicroTeX-extension notes). |

### F7 — (verified correct, previous residuals resolved)
- cmex10 is an external font at fixed 10 pt design for EVERY math size: confirmed in plain.tex
  line 483 (`\textfont3=\tenex \scriptfont3=\tenex \scriptscriptfont3=\tenex`) and LaTeX
  `omxcmex.fd` (`<->sfixed*cmex10`). So the text/script big-op box staying 10.55559 pt wide
  at 7 pt and 20 pt is CORRECT (old audit-bigop #4 premise "scale by size_pt" is false).
- `\ldots` = 3×\ldotp (8.33337) and `″` = 2×\prime composites are deliberate and correct
  (2.77779×3, 2.75×2 / 3.29366×2 / 4.40976×2).
- `layoutSpace` now uses `quadEm(style)` (cmsy7 1.170641, cmsy5 1.472241, verified vs TFM) —
  audit-metrics #1 fixed.
- Script floors at script style use cmsy7/cmsy5 sup1-3/sub1-2 (optically verified: `x_{a^2}`
  inner sup at 1.99998 = cmsy7 SUP3 0.285714em×7 = 2.0 ✓).

## Recommended fix order
1. F2 (supdrop/subdrop constants) — one-line change, systematic script-position error.
2. F1 (size table for non-10 pt bases; at least fix 20 pt scriptscript) — default CLI size.
3. F3 (\text/\mathrm roman metrics) — new cmr10 table slice.
4. F4 (Greek + \imath/\jmath + triangles rows) — data-only additions.
5. F6 cleanup; F5 draw real cmex glyphs when a vector path source exists.

## Evidence files
- `/tmp/metaudit/compare.py` (stage A/B), `verify3.py` (mathcode→TFM fidelity), `verify4.py`
  (7/5 pt tables vs cmr7/cmmi7/cmsy7, cmr5/cmmi5/cmsy5), `gaps.py` (text deltas + gap list),
  `*.pl` (tftopl dumps of all 14 CM TFMs), `/tmp/metaudit/xt/` (XeTeX \showbox proofs).
