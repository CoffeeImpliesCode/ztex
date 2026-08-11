# Fix: metric widths from Latin Modern Math advances — layout advance == rendered advance

Date: 2026-08-13. Scope: `src/layout/metrics.zig` (all width values), `src/layout/layout.zig` (`bigOpInk.w` + one test). INTENTIONAL output change — goldens regenerate; tests/goldens untouched. SKIP gates (build/test run for evidence only, per the task).

## Root cause

metrics.zig transcribed COMPUTER MODERN advance widths (cmr10/cmmi10/cmsy10/cmex10 from MicroTeX's font def tables), while the SVG draws Latin Modern Math (`latinmodern-math.otf`). The two fonts' advances differ (x 0.5715 vs 0.5280em, n 0.6002 vs 0.5560, i 0.3445 vs 0.2780, ∑ 1.4444 vs 1.0560, ∫ 0.5556 vs 0.6650), so the layout advance never matched the rendered glyph: the row/frame geometry (measured from the metric advance) disagreed with the drawn ink, the next atom overlapped the ink, and the frame clipped right/bottom. Big-op boxes used the ink-bbox width (∑ 0.943em) instead of the LM advance (1.056em), so the displayed big-op advance was also short. XeTeX with default Latin Modern uses the same LM metrics, so this improves XeTeX parity too.

## Method

For every codepoint in `table` (317), `table_roman` (52), `table7`/`table_roman7` (201/52), `table5`/`table_roman5` (201/52) and `display_ops` (8), measured the hmtx ADVANCE of `latinmodern-math.otf` (fontTools `hmtx[cmap[cp]][0] ÷ unitsPerEm`; unitsPerEm 1000, so advances are exact per-mille). Widths are stored in the existing em×10 convention (pt at 10pt), so the layout's `size_pt/10` scaling yields the true points at any size. LM Math is a single 10pt-design OTF with NO optical 7pt/5pt variants, so the 7pt/5pt tables carry the SAME em×10 values as the 10pt tables — the layout's size factor yields exactly LM advance × 0.7 at 7pt and × 0.5 at 5pt (linear scaling replaces the old optical cmr7/cmmi7/cmsy7, cmr5/... values). Height/depth and italic corrections are UNCHANGED (ink h/d were already LM; italic corrections are spacing facts, kept as the CM values).

Five codepoints are absent from LM Math (no glyph): Ϝ U+03D8, ▹ U+25B9, ◃ U+25C3, ⤒ U+2912, ⧫ U+29EB (AMS-only; the renderer draws a fallback font). They KEEP their measured CM widths (documented per row) so the fallback advance stays close.

## The change

`metrics.zig`: every `.w` in the six tables and `display_ops` replaced with the LM Math advance (874 rows changed; 9 rows kept for the 5 missing codepoints). Table and function doc comments updated (header, per-table, display_ops, default). Width tests that pinned CM numbers updated to the LM values (test names adjusted: 'exact Latin-Modern-Math advances', 'roman letters at script sizes scale the LM Math advance', etc.).

`layout.zig`: `bigOpInk.w` now the LM Math hmtx ADVANCE in em of the drawn glyph (was the ink-bbox width):

| op | U+ | old ink-bbox w | NEW hmtx advance w |
|---|---|---|---|
| `.sum` | U+2211 ∑ | 0.943 | 1.056 |
| `.prod` | U+220F ∏ | 0.831 | 0.944 |
| `.coprod` | U+2210 ∐ | 0.831 | 0.944 |
| `.bigcup` | U+22C3 ⋃ | 0.734 | 0.833 |
| `.bigcap` | U+22C2 ⋂ | 0.734 | 0.833 |
| `.bigsqcup` | U+2A06 ⨆ | 0.734 | 0.833 |
| `.int` | U+222B ∫ | 0.553 | 0.665 |
| `.oint` | U+222E ∮ | 0.553 | 0.665 |

asc/desc (ink extents) unchanged. The layout.zig 'text row width sums' test updated (15.00005 → 15.0 for LM a+b+c).

`metrics.zig` italic corrections (task item 5, secondary): LM Math carries OpenType MATH-table italicsCorrections (1002 glyphs), so every table `ic` where LM MATH has a value was replaced with LM em×10 (e.g. x 0 → 0.16, f 1.0764 → 0.79, ∫ 1.94446 → 3.32); glyphs without a MATH ic keep the CM value. `display_ops.ic` for ∫/∮ = 3.32 (0.332em × 10), measured in XeTeX + Latin Modern Math: the post-∫ kern is 3.32pt at 10pt and 6.64pt at 20pt (the LM MATH ic is em-relative and scales with size_pt, unlike the cmex10 CHARIC it replaces). `layout.zig`: `layoutScript` sup_gap and the `layoutOpLimits` skew delta now apply `s(dop.ic, size_pt)` (was the unscaled cmex design value 4.44446).

## Per-glyph LM advances and before/after widths

Convention: widths are em×10 (pt at 10pt). 'LM' = latinmodern-math.otf hmtx advance ÷ 1000. Old = previous CM value.

### Big operators (also the display_ops `.w` = LM×10)

| cp | glyph | LM adv (em) | old | new (em×10) |
|---|---|---|---|---|
| U+220F | ∏ | 0.944 | 12.777815 | 9.44 |
| U+2210 | ∐ | 0.944 | 12.777815 | 9.44 |
| U+2211 | ∑ | 1.056 | 14.44448 | 10.56 |
| U+222B | ∫ | 0.665 | 5.55557 | 6.65 |
| U+222E | ∮ | 0.665 | 5.55557 | 6.65 |
| U+22C2 | ⋂ | 0.833 | 11.111145 | 8.33 |
| U+22C3 | ⋃ | 0.833 | 11.111145 | 8.33 |
| U+2A06 | ⨆ | 0.833 | 11.111145 | 8.33 |

### Headline glyphs (bug-report measurements)

| cp | glyph | LM adv (em) | old (em×10) | new (em×10) |
|---|---|---|---|---|
| U+0078 | x | 0.528 | 7.15289 | 5.28 |
| U+006E | n | 0.556 | 7.50012 | 5.56 |
| U+0069 | i | 0.278 | 4.02783 | 2.78 |
| U+0030 | 0 | 0.5 | 6.80567 | 5 |
| U+002B | + | 0.778 | 10.278 | 7.78 |
| U+2212 | − | 0.778 | 10.8335 | 7.78 |
| U+003D | = | 0.778 | 10.278 | 7.78 |
| U+0028 | ( | 0.389 | 5.41675 | 3.89 |
| U+0029 | ) | 0.389 | 5.41675 | 3.89 |
| U+002F | / | 0.5 | 7.3612 | 5 |
| U+0061 | a | 0.5 | 6.80567 | 5 |
| U+0062 | b | 0.556 | 7.50012 | 5.56 |
| U+0063 | c | 0.444 | 6.1112 | 4.44 |
| U+0064 | d | 0.556 | 7.50012 | 5.56 |
| U+0065 | e | 0.444 | 6.1112 | 4.44 |
| U+0066 | f | 0.306 | 4.37506 | 3.06 |
| U+0067 | g | 0.5 | 6.80567 | 5 |
| U+0068 | h | 0.556 | 7.50012 | 5.56 |
| U+006A | j | 0.306 | 4.37506 | 3.06 |
| U+006B | k | 0.528 | 7.15289 | 5.28 |
| U+006C | l | 0.278 | 4.02783 | 2.78 |
| U+006D | m | 0.833 | 10.97241 | 8.33 |
| U+006F | o | 0.5 | 6.80567 | 5 |
| U+0070 | p | 0.556 | 7.50012 | 5.56 |
| U+0071 | q | 0.528 | 7.15289 | 5.28 |
| U+0072 | r | 0.392 | 5.41675 | 3.92 |
| U+0073 | s | 0.394 | 5.4862 | 3.94 |
| U+0074 | t | 0.389 | 5.41675 | 3.89 |
| U+0075 | u | 0.556 | 7.50012 | 5.56 |
| U+0076 | v | 0.528 | 7.15289 | 5.28 |
| U+0077 | w | 0.722 | 9.58349 | 7.22 |
| U+0079 | y | 0.528 | 7.15289 | 5.28 |
| U+007A | z | 0.444 | 6.1112 | 4.44 |
| U+221A | √ | 0.833 | 10.9724 | 8.33 |
| U+03B1 | α | 0.641 | 9.13321 | 6.41 |
| U+2229 | ∩ | 0.667 | 9.44458 | 6.67 |
| U+222A | ∪ | 0.667 | 9.44458 | 6.67 |
| U+2208 | ∈ | 0.667 | 9.44458 | 6.67 |
| U+221E | ∞ | 1 | 13.6113 | 10 |
| U+2202 | ∂ | 0.586 | 7.48962 | 5.86 |
| U+2207 | ∇ | 0.833 | 11.528 | 8.33 |

### Full before/after — main `table` (317 rows)

```
    cp glyph      LM em        old        new
U+0021 !          0.278    2.77779       2.78
U+0023 # \# (cmr10 35)   0.833    8.33336       8.33
U+0024 $ \$ (cmr10 36)     0.5    5.00002          5
U+0025 % \% (cmr10 37)   0.833    8.33336       8.33
U+0026 & \& (cmr10 38)   0.778    7.77781       7.78
U+0028 (          0.389     3.8889       3.89
U+0029 )          0.389     3.8889       3.89
U+002B +          0.778    7.77781       7.78
U+002C ,          0.278    2.77779       2.78
U+002D - (cmsy10 minus)   0.333    7.77781       3.33
U+002E .          0.278    2.77779       2.78
U+002F /            0.5    5.00002          5
U+0030 0            0.5    5.00002          5
U+0031 1            0.5    5.00002          5
U+0032 2            0.5    5.00002          5
U+0033 3            0.5    5.00002          5
U+0034 4            0.5    5.00002          5
U+0035 5            0.5    5.00002          5
U+0036 6            0.5    5.00002          5
U+0037 7            0.5    5.00002          5
U+0038 8            0.5    5.00002          5
U+0039 9            0.5    5.00002          5
U+003A :          0.278    2.77779       2.78
U+003B ;          0.278    2.77779       2.78
U+003C < (cmmi10)   0.778    7.77781       7.78
U+003D =          0.778    7.77781       7.78
U+003E > (cmmi10)   0.778    7.77781       7.78
U+0041 A           0.75    7.50002        7.5
U+0042 B          0.708     7.5851       7.08
U+0043 C          0.722    7.14722       7.22
U+0044 D          0.764    8.27917       7.64
U+0045 E          0.681    7.38195       6.81
U+0046 F          0.653    6.43057       6.53
U+0047 G          0.785    7.86249       7.85
U+0048 H           0.75    8.31251        7.5
U+0049 I          0.361    4.39585       3.61
U+004A J          0.514    5.54514       5.14
U+004B K          0.778    8.49307       7.78
U+004C L          0.625    6.80557       6.25
U+004D M          0.917     9.7014       9.17
U+004E N           0.75   8.034725        7.5
U+004F O          0.778    7.62776       7.78
U+0050 P          0.681    6.42014       6.81
U+0051 Q          0.778    7.90555       7.78
U+0052 R          0.736     7.5929       7.36
U+0053 S          0.556    6.13195       5.56
U+0054 T          0.722    5.84376       7.22
U+0055 U           0.75    6.82777        7.5
U+0056 V           0.75    5.83334        7.5
U+0057 W          1.028    9.44446      10.28
U+0058 X           0.75    8.28474        7.5
U+0059 Y           0.75    5.80557        7.5
U+005A Z          0.611     6.8264       6.11
U+005B [          0.278    2.77779       2.78
U+005D ]          0.278    2.77779       2.78
U+005F _ \_ (cmr10 95)   0.333    2.77779       3.33
U+0061 a            0.5     5.2859          5
U+0062 b          0.556    4.29167       5.56
U+0063 c          0.444    4.32756       4.44
U+0064 d          0.556    5.20488       5.56
U+0065 e          0.444    4.65627       4.44
U+0066 f          0.306    4.89586       3.06
U+0067 g            0.5    4.76969          5
U+0068 h          0.556   5.761595       5.56
U+0069 i          0.278    3.44513       2.78
U+006A j          0.306    4.11807       3.06
U+006B k          0.528    5.20604       5.28
U+006C l          0.278     2.9838       2.78
U+006D m          0.833    8.78014       8.33
U+006E n          0.556    6.00235       5.56
U+006F o            0.5    4.84723          5
U+0070 p          0.556    5.03126       5.56
U+0071 q          0.528    4.46414       5.28
U+0072 r          0.392   4.511595       3.92
U+0073 s          0.394     4.6875       3.94
U+0074 t          0.389    3.61113       3.89
U+0075 u          0.556    5.72458       5.56
U+0076 v          0.528    4.84724       5.28
U+0077 w          0.722    7.15918       7.22
U+0078 x          0.528    5.71528       5.28
U+0079 y          0.528    4.90282       5.28
U+007A z          0.444     4.6505       4.44
U+007B { (cmsy10)     0.5    5.00002          5
U+007C | (cmsy10)   0.278    2.77779       2.78
U+007D } (cmsy10)     0.5    5.00002          5
U+00A3 £ \pounds (cmti10 36 sterling sign)    0.75    7.69093        7.5
U+00A5 ¥ \yen (msam10 85)    0.75    7.50002        7.5
U+00A7 § \S (cmsy10 120)   0.444    4.44447       4.44
U+00A9 © \copyright (c + OMS circle composite)   0.683    11.1084       6.83
U+00AC ¬ \neg (cmsy10 58)   0.667    6.66669       6.67
U+00B1 ± \pm (cmsy10 167)   0.778    7.77781       7.78
U+00B6 ¶ \P (cmsy10 123)   0.611    6.11113       6.11
U+00B7 · middle dot (cmsy10, same as U+22C5 ⋅)   0.278     2.7778       2.78
U+00D7 × \times (cmsy10 163)   0.778    7.77781       7.78
U+00F0 ð \eth (msbm10 103)     0.5    5.55557          5
U+00F7 ÷ \div (cmsy10 165)   0.778    7.77781       7.78
U+0131 ı \imath (cmmi10 123)   0.278    3.22456       2.78
U+0237 ȷ \jmath (cmmi10 124)   0.306     3.8403       3.06
U+0391 Α           0.75    7.50002        7.5
U+0392 Β          0.708     7.5851       7.08
U+0393 Γ (cmr10 slot 161)   0.625    6.25002       6.25
U+0394 Δ (cmr10 slot 162)   0.833    8.33336       8.33
U+0398 Θ (cmr10 slot 163)   0.778    7.77781       7.78
U+039B Λ (cmr10 slot 164)   0.694    6.94446       6.94
U+039E Ξ (cmr10 slot 165)   0.667    6.66669       6.67
U+03A0 Π (cmr10 slot 166)    0.75    7.50002        7.5
U+03A3 Σ (cmr10 slot 167)   0.722    7.22224       7.22
U+03A5 Υ (cmr10 slot 168)   0.778    7.77781       7.78
U+03A6 Φ (cmr10 slot 169)   0.722    7.22224       7.22
U+03A8 Ψ (cmr10 slot 170)   0.778    7.77781       7.78
U+03A9 Ω (cmr10 slot 171)   0.722    7.22224       7.22
U+03B1 α          0.641    6.39702       6.41
U+03B2 β          0.558    5.65626       5.58
U+03B3 γ          0.586    5.17731       5.86
U+03B4 δ          0.474    4.44445       4.74
U+03B5 ε          0.535    4.05904       5.35
U+03B6 ζ           0.53    4.37502        5.3
U+03B7 η           0.53    4.96532        5.3
U+03B8 θ          0.488    4.69444       4.88
U+03B9 ι          0.308    3.53937       3.08
U+03BA κ           0.53     5.7616        5.3
U+03BB λ          0.537    5.83336       5.37
U+03BC μ           0.53     6.0255        5.3
U+03BD ν          0.502    4.93983       5.02
U+03BE ξ           0.53    4.37502        5.3
U+03BF ο (cmmi10 111 italic o; CM has no omicron)     0.5    4.84723          5
U+03C0 π          0.586    5.70027       5.86
U+03C1 ρ          0.488    5.17015       4.88
U+03C2 ς \varsigma   0.474    3.62848       4.74
U+03C3 σ          0.599    5.71414       5.99
U+03C4 τ           0.53    4.37155        5.3
U+03C5 υ           0.53     5.4028        5.3
U+03C6 φ          0.641    5.95835       6.41
U+03C7 χ          0.641    6.25692       6.41
U+03C8 ψ          0.641    6.51392       6.41
U+03C9 ω          0.641    6.22455       6.41
U+03D1 ϑ \vartheta    0.53     5.9144        5.3
U+03D5 ϕ \varphi   0.641    6.54167       6.41
U+03D6 ϖ \varpi   0.836     8.2813       8.36
U+03F1 ϱ \varrho   0.488    5.17015       4.88
U+03F5 ϵ \varepsilon   0.414    4.66318       4.14
U+2020 † \dagger (cmsy10 121)   0.444    4.44446       4.44
U+2021 ‡ \ddagger (cmsy10 122)   0.444    4.44446       4.44
U+2026 … \ldots (composite: 3 × \ldotp, cmmi10 58)   0.837    8.33337       8.37
U+2032 ′ \prime (cmsy10 48)   0.311       2.75       3.11
U+2033 ″ composite: 2 × \prime   0.511        5.5       5.11
U+2035 ‵ \backprime (msam10 56)   0.311       2.75       3.11
U+210F ℏ \hbar (msbm10 126)   0.576     5.4028       5.76
U+2111 ℑ \Im (cmsy10 61)   0.554    7.22224       5.54
U+2113 ℓ \ell (cmmi10 96)   0.417     4.1667       4.17
U+2118 ℘ \wp (cmmi10 125)   0.636    6.36459       6.36
U+211C ℜ \Re (cmsy10 60)   0.828    7.22224       8.28
U+2127 ℧ \mho (msbm10 102)   0.722    7.22224       7.22
U+2135 ℵ \aleph (cmsy10 64)   0.611    6.11113       6.11
U+2190 ← \leftarrow (cmsy10 195)       1   10.00003         10
U+2191 ↑ \uparrow (cmsy10 34)     0.5    5.00002          5
U+2192 → \rightarrow (cmsy10 33)       1   10.00003         10
U+2193 ↓ \downarrow (cmsy10 35)     0.5    5.00002          5
U+2194 ↔ \leftrightarrow (cmsy10 36)       1   10.00003         10
U+2195 ↕ \updownarrow (cmsy10 108)     0.5    5.00002          5
U+2196 ↖ \nwarrow (cmsy10 45)       1   10.00003         10
U+2197 ↗ \nearrow (cmsy10 37)       1   10.00003         10
U+2198 ↘ \searrow (cmsy10 38)       1   10.00003         10
U+2199 ↙ \swarrow (cmsy10 46)       1   10.00003         10
U+21A3 ↣ \rightarrowtail (msam10 26)   1.192   11.11115      11.92
U+21A6 ↦ \mapsto (composite: \mapstochar →)   0.977   10.00003       9.77
U+21A9 ↩ \hookleftarrow (← 3\joinrel \rhook)   0.997    8.44449       9.97
U+21AA ↪ \hookrightarrow (\lhook 3\joinrel →)   0.997    8.44449       9.97
U+21BC ↼ \leftharpoonup (cmmi10 40)       1   10.00003         10
U+21BD ↽ \leftharpoondown (cmmi10 41)   1.012   10.00003      10.12
U+21C0 ⇀ \rightharpoonup (cmmi10 42)       1   10.00003         10
U+21C1 ⇁ \rightharpoondown (cmmi10 43)   1.012   10.00003      10.12
U+21C4 ⇄ \rightleftarrows (msam10 29)   1.018   10.00003      10.18
U+21D0 ⇐ \Leftarrow (cmsy10 40)       1   10.00003         10
U+21D1 ⇑ \Uparrow (cmsy10 42)   0.611    6.11113       6.11
U+21D2 ⇒ \Rightarrow (cmsy10 41)       1   10.00003         10
U+21D3 ⇓ \Downarrow (cmsy10 43)   0.611    6.11113       6.11
U+21D4 ⇔ \Leftrightarrow (cmsy10 44)       1   10.00003         10
U+21D5 ⇕ \Updownarrow (cmsy10 109)   0.611    6.11113       6.11
U+2200 ∀ \forall (cmsy10 56)   0.666    5.55557       6.66
U+2202 ∂ \partial (cmmi10 64)   0.586    5.30904       5.86
U+2203 ∃ \exists (cmsy10 57)   0.556    5.55557       5.56
U+2204 ∄ \nexists (msbm10 64)   0.556    5.55557       5.56
U+2205 ∅ \emptyset (cmsy10 59)     0.5    5.00002          5
U+2207 ∇ \nabla (cmsy10 114)   0.833    8.33336       8.33
U+2208 ∈ \in (cmsy10 50)   0.667    6.66669       6.67
U+2209 ∉ \notin (composite: \not \in)   0.667    6.66669       6.67
U+220B ∋ \ni (cmsy10 51)   0.667    6.66669       6.67
U+220F ∏ \prod    0.944   9.444475       9.44
U+2210 ∐ \coprod   0.944   9.444475       9.44
U+2211 ∑ \sum     1.056   10.55559      10.56
U+2212 − minus (cmsy10 161)   0.778    7.77781       7.78
U+2213 ∓ \mp (cmsy10 168)   0.778    7.77781       7.78
U+2215 ╱ \diagup (msbm10 30)   0.568    8.88891       5.68
U+2216 ∖ \setminus (cmsy10 110)   0.568    5.00002       5.68
U+2217 ∗ \ast (cmsy10 164)     0.5    5.00002          5
U+2218 ∘ \circ (cmsy10 177)   0.412    5.00002       4.12
U+2219 ∙ \bullet (cmsy10 178)     0.5    5.00002          5
U+221A √ \surd (cmsy10 112)   0.833    8.33336       8.33
U+221D ∝ \propto (cmsy10 47)   0.778    7.77781       7.78
U+221E ∞ \infty (cmsy10 49)       1   10.00003         10
U+2220 ∠ \angle (msam10 92)   0.778    7.22224       7.78
U+2221 ∡ \measuredangle (msam10 93)   0.778    7.22224       7.78
U+2222 ∢ \sphericalangle (msam10 94)   0.778    7.22224       7.78
U+2223 ∣ \mid (cmsy10 106 \vert)   0.278    2.77779       2.78
U+2224 ∤ \nmid (msbm10 45)   0.388    2.77779       3.88
U+2225 ∥ \parallel (cmsy10 107 \Vert)     0.5    5.00002          5
U+2226 ∦ \nparallel (msbm10 44)   0.556    5.00002       5.56
U+2227 ∧ \wedge (cmsy10 94)   0.667    6.66669       6.67
U+2228 ∨ \vee (cmsy10 95)   0.667    6.66669       6.67
U+2229 ∩ \cap (cmsy10 92)   0.667    6.66669       6.67
U+222A ∪ \cup (cmsy10 91)   0.667    6.66669       6.67
U+222B ∫ \int     0.665    4.72223       6.65
U+222E ∮ \oint    0.665    4.72223       6.65
U+2234 ∴ \therefore (msam10 41)   0.516    6.66669       5.16
U+2235 ∵ \because (msam10 42)   0.516    6.66669       5.16
U+223C ∼ \sim (cmsy10 187)   0.773    7.77781       7.73
U+2240 ≀ \wr (cmsy10 111)    0.28    2.77779        2.8
U+2241 ≁ \nsim (msbm10 28)   0.773    7.77781       7.73
U+2243 ≃ \simeq (cmsy10 39)   0.778    7.77781       7.78
U+2245 ≅ \cong (sim+rule composite)   0.778    7.77781       7.78
U+2246 ≆ \simneqq (composite: \not over ≃)   0.778    7.77781       7.78
U+2247 ≇ \ncong (msbm10 29)   0.778    7.77781       7.78
U+2248 ≈ \approx (cmsy10 188)   0.773    7.77781       7.73
U+2249 ≉ \napprox (composite: \not over ≈)   0.773    7.77781       7.73
U+224D ≍ \asymp (cmsy10 179)   0.778    7.77781       7.78
U+2250 ≐ \doteq (dot-over-= composite)   0.778    7.77781       7.78
U+2260 ≠ \ne (composite: \not over =)   0.778    7.77781       7.78
U+2261 ≡ \equiv (cmsy10 180)   0.778    7.77781       7.78
U+2262 ≢ \not\equiv (composite: \not over ≡)   0.778    7.77781       7.78
U+2264 ≤ \leq (cmsy10 183)   0.778    7.77781       7.78
U+2265 ≥ \geq (cmsy10 184)   0.778    7.77781       7.78
U+2266 ≦ \leqq (msam10 53)   0.778    7.77781       7.78
U+2267 ≧ \geqq (msam10 61)   0.778    7.77781       7.78
U+226A ≪ \ll (cmsy10 191)       1   10.00003         10
U+226B ≫ \gg (cmsy10 192)       1   10.00003         10
U+2270 ≰ \nleq (msbm10 2)   0.778    7.77781       7.78
U+2271 ≱ \ngeq (msbm10 3)   0.778    7.77781       7.78
U+227A ≺ \prec (cmsy10 193)   0.778    7.77781       7.78
U+227B ≻ \succ (cmsy10 194)   0.778    7.77781       7.78
U+2282 ⊂ \subset (cmsy10 189)   0.778    7.77781       7.78
U+2283 ⊃ \supset (cmsy10 190)   0.778    7.77781       7.78
U+2286 ⊆ \subseteq (cmsy10 181)   0.778    7.77781       7.78
U+2287 ⊇ \supseteq (cmsy10 182)   0.778    7.77781       7.78
U+2288 ⊈ \nsubseteq (msbm10 42)   0.778    7.77781       7.78
U+2289 ⊉ \nsupseteq (msbm10 43)   0.778    7.77781       7.78
U+228E ⊎ \uplus (cmsy10 93)   0.667    6.66669       6.67
U+2291 ⊑ \sqsubseteq (cmsy10 118)   0.778    7.77781       7.78
U+2292 ⊒ \sqsupseteq (cmsy10 119)   0.778    7.77781       7.78
U+2293 ⊓ \sqcap (cmsy10 117)   0.667    6.66669       6.67
U+2294 ⊔ \sqcup (cmsy10 116)   0.667    6.66669       6.67
U+2295 ⊕ \oplus (cmsy10 169)   0.778    7.77781       7.78
U+2296 ⊖ \ominus (cmsy10 170)   0.778    7.77781       7.78
U+2297 ⊗ \otimes (cmsy10 171)   0.778    7.77781       7.78
U+2298 ⊘ \oslash (cmsy10 174)   0.778    7.77781       7.78
U+2299 ⊙ \odot (cmsy10 175)   0.778    7.77781       7.78
U+22A2 ⊢ \vdash (cmsy10 96)   0.611    6.11113       6.11
U+22A3 ⊣ \dashv (cmsy10 97)   0.611    6.11113       6.11
U+22A4 ⊤ \top (cmsy10 62)   0.778    7.77781       7.78
U+22A5 ⊥ \perp (cmsy10 63)   0.778    7.77781       7.78
U+22A8 ⊨ \vDash (msam10 178)   0.612    6.11113       6.12
U+22C0 ⋀ \bigwedge (cmex10 86)   0.833    8.33336       8.33
U+22C1 ⋁ \bigvee (cmex10 87)   0.833    8.33336       8.33
U+22C2 ⋂ \bigcap   0.833    8.33336       8.33
U+22C3 ⋃ \bigcup   0.833    8.33336       8.33
U+22C4 ⋄ \diamond (cmsy10 166)     0.5    5.00002          5
U+22C5 ⋅ \cdot (cmsy10 middle dot)   0.278     2.7778       2.78
U+22C6 ⋆ \star (cmmi10 63)     0.5    5.00002          5
U+22C8 ⋈ \bowtie (composite: ▹ \joinrel ◃)   0.623    8.55560       6.23
U+22D8 ⋘ \lll (msam10 110)   1.285   13.33338      12.85
U+22D9 ⋙ \ggg (msam10 111)   1.285   13.33338      12.85
U+22EF ⋯ \cdots (composite: 3 × cdot)   0.776    8.33337       7.76
U+2308 ⌈ \lceil (cmsy10 100)   0.444    4.44446       4.44
U+2309 ⌉ \rceil (cmsy10 101)   0.444    4.44446       4.44
U+230A ⌊ \lfloor (cmsy10 98)   0.444    4.44446       4.44
U+230B ⌋ \rfloor (cmsy10 99)   0.444    4.44446       4.44
U+2322 ⌢ \frown (cmmi10 95)       1   10.00003         10
U+2323 ⌣ \smile (cmmi10 94)       1   10.00003         10
U+25A0 ■ \blacksquare (msam10 4)   0.778    7.77781       7.78
U+25A1 □ \square (msam10 3)   0.778    7.77781       7.78
U+25B3 △ \triangle (cmsy10 52)   0.968    8.88891       9.68
U+25BD ▽ \bigtriangledown (cmsy10 53)   0.968    8.88891       9.68
U+25CA ◊ \lozenge (msam10 6)   0.572    6.66669       5.72
U+25CB ○ \bigcirc (cmsy10 176)   0.796   10.00003       7.96
U+2660 ♠ \spadesuit (cmsy10 127)   0.778    7.77781       7.78
U+2661 ♡ \heartsuit (cmsy10 126)   0.778    7.77781       7.78
U+2662 ♢ \diamondsuit (cmsy10 125)   0.778    7.77781       7.78
U+2663 ♣ \clubsuit (cmsy10 124)   0.778    7.77781       7.78
U+266D ♭ \flat (cmmi10 91)   0.388     3.8889       3.88
U+266E ♮ \natural (cmmi10 92)   0.388     3.8889       3.88
U+266F ♯ \sharp (cmmi10 93)   0.388     3.8889       3.88
U+2713 ✓ \checkmark (msam10 88)   0.833    8.33336       8.33
U+27E8 ⟨ \langle (cmsy10 104)   0.389     3.8889       3.89
U+27E9 ⟩ \rangle (cmsy10 105)   0.389     3.8889       3.89
U+27F5 ⟵ \longleftarrow (← \joinrel \relbar)   1.463   16.33340      14.63
U+27F6 ⟶ \longrightarrow (relbar joinrel)   1.463   16.33340      14.63
U+27F7 ⟷ longleftrightarrow (joinrel)   1.442   18.55562      14.42
U+27F8 ⟸ \Longleftarrow (⇐ \joinrel \Relbar)   1.457   16.33340      14.57
U+27F9 ⟹ \Longrightarrow (Relbar joinrel)   1.457   16.33340      14.57
U+27FA ⟺ \Longleftrightarrow (joinrel)   1.534   18.55562      15.34
U+2A00 ⨀ \bigodot (cmex10 74)   1.111  11.111145      11.11
U+2A01 ⨁ \bigoplus (cmex10 76)   1.111  11.111145      11.11
U+2A02 ⨂ \bigotimes (cmex10 78)   1.111  11.111145      11.11
U+2A04 ⨄ \biguplus (cmex10 85)   0.833    8.33336       8.33
U+2A05 ⨅ \bigsqcap (stmary10 132)   0.833    8.33336       8.33
U+2A06 ⨆ \bigsqcup   0.833    8.33336       8.33
U+2A2F ⨯ \times (cmsy10 2)   0.778    7.77781       7.78
U+2A3F ⨿ \amalg (cmsy10 113)    0.75    7.50002        7.5
U+2A7D ⩽ \leqslant (msam10 54)   0.778    7.77781       7.78
U+2A7E ⩾ \geqslant (msam10 62)   0.778    7.77781       7.78
U+2AAF ⪯ \preceq (cmsy10 185)   0.778    7.77781       7.78
U+2AB0 ⪰ \succeq (cmsy10 186)   0.778    7.77781       7.78
```

`table_roman` (52), `table7` (201), `table_roman7` (52), `table5` (201), `table_roman5` (52) carry the same LM em×10 values (roman letters = the same LM Math advance; 7pt/5pt = linear scaling). The old optical cmr7/cmmi7/cmsy7/cmr5 values are in git history.

## Verification (resvg)

Formula: `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`, rendered at `-s 20` and `-s 48` with `-p 20`, converted with the task's resvg 0.48.0 (`/nix/store/yc4ffvi450g4hsg9lp8p0nq4v2xi1y3p-resvg-0.48.0/bin/resvg`).

**DPI note:** the ztex SVG declares `width="…pt"` with a pt-valued viewBox; per the SVG spec a `pt` length = 96/72 = 1.333 CSS px = 1.333 user units, so at resvg's default 96dpi every coordinate is converted once into user units and the viewport scale applies again — the content renders at 1.333× its layout geometry and wide formulas push past the viewBox (clipped at the frame). This is a PRE-EXISTING svg.zig unit defect, independent of the width fix (it clips the pre-change build identically) and OUT OF SCOPE (task: edit only metrics.zig/layout.zig). The intended semantics — 1 user unit = 1 pt, which is what the layout computes in — is obtained with `resvg --dpi 72` (1pt = 1px = 1 user unit), which is what the measurements below use.

`resvg --dpi 72 f20.svg f20.png` — ink bbox vs frame (user units = pt):

| render | frame (pt) | content area (pt, pad 20) | rendered ink bbox (pt) | right margin | bottom margin | fits? |
|---|---|---|---|---|---|---|
| f20 (-s 20) | 222.34 | 123.06 | x[35,188] y[34,88] | 14.34 | 15.06 | YES |
| f48 (-s 48) | 472.84 | 239.08 | x[57,419] y[53,185] | 33.84 | 34.08 | YES |

The ink sits fully INSIDE the content area (frame minus the 20pt padding) on all four sides at both sizes — the padding is whitespace, nothing clips. Rendered ink bbox ≈ content area, i.e. layout advance ≈ render advance. (The ∫-limits skew with the scaled delta widens the frame by ~2.2pt at -s 20 vs the CM 4.44446 design ic; the fit margin stays comfortably positive.)

### Per-glyph advance checks in the render (dpi 72 = user units = pt)

| glyph | size | LM advance | layout pen-to-pen | render check |
|---|---|---|---|---|
| x | 20pt | 0.528×20 = 10.56pt | 150.58 → 164.46 = 10.56 + thin 3.33 | ink left 151 = pen 150.58 + 0.012em×20 ✓ |
| d | 20pt | 0.556×20 = 11.12pt | 164.46 → 175.58 | ink left 165 = pen + 0.034em×20 ✓ |
| n | 20pt | 0.556×20 = 11.12pt | (fraction denominator) | cluster x[71,80] = pen 70.02 + 0.032em×20 ✓ |
| ∑ | 28pt (display gs) | 1.056×28 = 29.57pt | box width 29.57 (bigOpInk.w × gs) | ink x[35,61] = pen 34 + [0.056,0.999]em×28 ✓ |
| ∫ | 40pt (display gs) | 0.665×40 = 26.6pt | box width 26.6 | ink x[111,132] = pen 108.7 + [0.056,0.609]em×40 ✓ |

All 15 text elements of the formula render at exactly their layout positions (cluster analysis matches the SVG x/y to the pixel); the rendered advance between consecutive pens equals the LM-advance layout.

## Tests

`zig build test`: 99/101 pass. The 2 failures are `regression: draw-list snapshots` and `regression: svg snapshots` — golden-pinned output snapshots; this task is an INTENTIONAL output change (goldens regenerate; tests/goldens untouched, per the task). All metrics/layout unit tests pass, including the updated width tests.

