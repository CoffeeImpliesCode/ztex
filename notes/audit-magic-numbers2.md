# Audit: magic numbers / hard-coded data

Lens: every magic constant in metrics.zig, layout.zig, atom.zig, parser.zig, svg.zig,
classified FONT-DERIVABLE / TEX-SPEC / ARBITRARY, plus same-number-in-two-places drift.
Repo already has a real-font backend (`FontMetrics.font` → font.zig via Context), so the
"static default" tables below are the fallback path `ztex.render` / `metrics.default`
uses — thousands of Latin-Modern values baked in instead of queried.

## C — FONT-DERIVABLE (exist in OT MATH table / hmtx / OS-2; baked here)

- **metrics.zig GlueParams** (2543-2580): `axis_height=2.5`(AxisHeight 0.25em), `rule_thickness=0.4`(FractionRuleThickness 0.04), `sup1/2=3.63`(SuperscriptShiftUp 0.363), `sup3=2.89`(SuperscriptShiftUpCramped), `sub1/2/3=2.47`(SubscriptShiftDown 0.247), `supdrop=1.75`(SuperscriptBaselineDropMax 0.25×0.7), `subdrop=1.4`(SubscriptBaselineDropMin 0.20×0.7), `bigop_spacing1..4=2.0/1.67/1.11/6.0`(UpperLimitGapMin 0.20, LowerLimitGapMin 0.167, UpperLimitBaselineRiseMin 0.111, LowerLimitBaselineDropMin 0.60), `scriptfactor=0.7`(ScriptPercentScaleDown), `scriptscriptfactor=0.5`(ScriptScriptPercentScaleDown), `x_height=4.30555`(OS/2 sxHeight). ALL live in the OT MATH/OS-2 tables; comments say "measured from latinmodern-math.otf with fontTools" — measured ONCE, frozen.
- **Per-glyph tables** — `table10`(179-564), `table_roman`(566+), `table7`(637+), `table5`(956+), `table_roman17`(1286+, real lmroman17 hmtx), `ink_table`(1402+), `env_ic_table`(layout.zig 1458+, LM Math ICs), `accent_attach`(2232+ = TopAccentAttachment), `DelimVariant`(1950+, = MathGlyphVariantRecords), `display op` table(2586+), `BigOpInk`(layout.zig 3167+, incl `.ic=3.32/5.91` = MathItalicsCorrection). Thousands of values, all from the same font, all baked.
- **layout.zig**: `StackTopShiftUp 0.444`/`StackBottomShiftDown 0.345`/`StackGapMin 0.120`(1224-1225, \substack), `RadicalDisplayStyleVerticalGap 0.148`/`RadicalVerticalGap 0.05`(2517), `fractionNumGapMin 0.04`/`fractionNumDisplayStyleGapMin 0.12`(3541-3542), `accent_base_height 0.45`(AccentBaseHeight, 756), `0.901`+`0.1` delim sizing (2014/2057/2156/2227: \delimiterfactor 901/1000 + \delimitershortfall 0.1em — see TEX-SPEC below; the *values* trace to TeX, the *numbers* are font-independent).
- **svg.zig** `linegap=0.2*max_size`(68) — LM Math hhea lineGap 0.2em; font-derivable.

## T — TEX-SPEC (legit; cite the rule)

- **metrics.zig** `num1..denom3 = 6.76508/3.93732/4.43731/6.85951/3.44841/1.63` — TeX \fontdimen8..13 of \textfont3 (cmex) fraction gaps, TeXBook App G. TEX-SPEC (fraction num/denom gaps are NOT in the OT MATH table).
- **layout.zig** `0.901`/`0.1` in make_delim floors (2014, 2057, 2156, 2227) — \delimiterfactor 901/1000, \delimitershortfall 0.1em (TeXBook §447; tex.web §1114). Correct.
- **layout.zig** `\nulldelimiterspace = 1.2`(3604) — TeX default 1.2pt. Correct.
- **layout.zig** `\arraycolsep 5.0` / `\arraystretch 1.2`(cases) / `\baselineskip 1.2×size` / strut `0.7/0.3`(1708-1712) — LaTeX \array defaults. Correct.
- **parser.zig** `\, 0.166`(thin 3mu), `\; 0.277`(thick 5mu), `\! -0.166`, `\quad 1.0`, `\qquad 2.0`(1104-1108), `\mkern6mu 6/18`(1896), `\mkern5mu 5/18`(1919), `\mkern6mu` pmod(1946) — mu units, 1em=18mu. Correct.

## A — ARBITRARY (hand-tuned / measured-once, highest priority)

- **metrics.zig glyphEstimateImpl** (2525-2537): fallback `width 0.5em, height 0.7em, depth 0.2em` for any glyph missing from the tables. Deliberately wrong for wide glyphs; the whole "65 gap codepoints" test suite (2871+) exists to paper over it. Highest-priority ARBITRARY.
- **svg.zig** `margin = 0.08 * max_size`(64): "Small safety slop... kept tight" — hand-tuned, not a font or TeX value.
- **layout.zig binomDelimReqEm** (2086-2091): display → `2.392`, else `1.094` — measured variant inks, hardcoded per style, content-independent.
- **layout.zig** `kern_leading = (12/18)*size_pt`(1394): aligned-env row lead (12mu \mkern12mu) — plausible TeX, but unlabeled as such; classify borderline T (verify against amsmath \openup\jot before trusting).

## ! — Same number in two places (drift risk)

1. **supdrop=1.75 / subdrop=1.4**: defined in metrics.zig glueImpl (2570-2571) AND re-literalized in layout.zig `s(1.75,..)/s(1.4,..)` (2836-2837). Two sources; a metrics change silently ignores layout. **#1 drift.**
2. **scriptfactor 0.7 / scriptscript 0.5**: glueImpl (2577-2578) AND bare literals 0.7/0.5 in layout.zig (styleScale 490-491, substack 1223, 2720-2723, 3497-3499) and the supdrop comment.
3. **Big-op advances**: metrics table (2608-2612: ∑10.56, ∫6.65, ic 3.32) duplicates layout.zig BigOpInk (3167-3224: 1.056/0.665, ic 3.32) AND display branch (3229-3245: 1.444/0.999, ic 5.91). int/oint carry the SAME .ic twice each. Three copies of one fact.
4. **2.392 (parenleft.v6 ink)**: layout.zig big_target_ink(48), binomDelimReqEm(2088), DelimVariant table (asc1.446+desc0.946, 1974/1987), parser.zig comment (1973).
5. **axis 2.5**: metrics glueImpl axis_height AND layout.zig `s(2.5,..)` in \not (898) + comments (3128).

## Top-5 constants to become font-queried

1. **GlueParams whole set** (metrics.zig 2545-2579) — the OT MATH constants (axis, rule_thickness, sup/sub shifts, scriptfactor, bigop gaps) frozen at 10pt; read them from the MATH table via font.zig instead of the measured-once literals.
2. **Per-glyph advance+ink tables** (table10/7/5, ink_table, table_roman17) — thousands of baked LM values; generate at init from font.zig hmtx + glyph bounds (the `.font` arm already can — static default duplicates it).
3. **BigOpInk + display-op + DelimVariant + accent_attach + env_ic** — MATH-table variant records & MathItalicsCorrection baked as structs; query the variant/MathGlyphInfo records.
4. **supdrop/subdrop/scriptfactor literals** (layout.zig 2836-2837, 490-491, 1223, 2723, 3497-3499) — de-duplicate into GlueParams single-source, then font-query.
5. **glyphEstimate 0.5/0.7/0.2em fallback** (metrics.zig 2525-2537) — replace with real glyph measurement or at least a font-advance lookup; currently the only deliberately-wrong value in the render path.
