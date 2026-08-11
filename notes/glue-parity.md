# Glue parity: fraction parts & script styles (MicroTeX / TeXBook vs ztex)

Date: 2026-08-12. Reference = MicroTeX (`clatexmath -headless`) + TeXBook p.181/p.170
(p.291 rule 15 for frac styles). All measured at 20pt base; SVGs in /tmp/zg.

## Reference rule (EXACT)

Inter-atom glue comes from the TeXBook p.181 table. MicroTeX encodes it in
`Glue::_table` (src/core/glue.cpp), indexed `k = style/2` where TexStyle
(src/utils/enums.h) is `display=0, display1=1, text=2, text1=3, script=4,
script1=5, scriptScript=6, scriptScript1=7` (`1` = cramped, which does NOT
change glue). So k=0→display, 1→text, 2→script, 3→scriptscript. ORD↔BIN
entries are `2200` and ORD↔REL `3300`: **med (4mu) and thick (5mu) glue are
present in display and text styles, and SUPPRESSED (0) in script and
scriptscript styles.** ztex copies this bit-for-bit (layout.zig glue_table,
nibbles display/text/script/scriptscript).

Fraction styles (MicroTeX Environment::numStyle/dnomStyle, src/core/core.cpp;
= TeXBook p.291 rule 15):
- display frac  → numerator text (2),  denominator text-cramped (3). Both k=1.
- text frac     → numerator script,     denominator script-cramped.  Both k=2.
- script frac   → numerator scriptscript, den scriptscript-cramped.  Both k=3.

So for a top-level (display) `\frac{a+b}{c-d}` BOTH parts are text style and
KEEP med glue. Glue inside a fraction part is suppressed ONLY when the frac is
itself text/script style (its parts drop to script/scriptscript). Cramped-ness
does not affect glue.

## Measured (both engines, 20pt; inter-glyph spans = glyph width + glue)

Top-level display fraction `\frac{x+1}{y-1}` — num and den BOTH glued:
- num: `x→+` span 15.88, `+→1` span 20.00 (both engines, identical coords)
- den: `y→-` span 14.25, `-→1` span 20.00 (both engines, identical coords)
- `\frac{a+b}{c-d}`: num `a→+` 15.02/`+→b` 20.00; den `c→-` 13.10/`-→d` 20.00.
- med glue = 4/18 em = 4.44 pt at 20pt; + width ≈ 15.56 so `+→x` = 20.0.
  ztex and MicroTeX produce byte-identical inter-glyph spans for every case.

Script-style suppression — `\frac{\frac{a+b}{c}}{d}` inner numerator is script:
- ztex: `a→+` 7.40, `+→b` 10.89  (≈ width(a), width(+): NO glue)
- MicroTeX: `a→+` 7.40, `+→b` 10.89 (identical)
- `x^{a+b}+c` superscript script: `a→+` 7.40 (no glue); top-level `+` still med.
- top-level `a_1+2`: script `_1` drops to script style, but the row `a_1 … +`
  is display/text, so med glue kept between the scripted box and `+`.

## ztex current behavior: MATCHES (claimed bug does not reproduce)

ztex `layoutFraction` (src/layout/layout.zig:574) sets BOTH numerator and
denominator to the same `part_style`: display→text, text→script,
script→scriptscript. For a display fraction both parts are `.text`, so both get
med glue — identical to MicroTeX (den being cramped in MicroTeX changes
nothing for glue). Verified empirically on a fresh build: the denominator of
`\frac{x+1}{y-1}` IS glued (span matches the numerator modulo glyph width).

## Conclusion / fix

No fix needed. The premise "ztex glues the numerator but suppresses the
denominator" is stale — ztex currently glues BOTH, and MicroTeX also glues
BOTH. Neither engine suppresses glue in the parts of a top-level fraction.
Glue is suppressed only in script/scriptscript styles, which is where both
engines already suppress it (nested/text fractions). MicroTeX does NOT
suppress both fraction parts; it suppresses neither for a display frac.
If a true discrepancy appears later, the lever is `part_style` in
layoutFraction (it must yield script/scriptscript for text/script fractions).
