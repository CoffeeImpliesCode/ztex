# fix-pipeline-metrics — F3 (roman \text/\mathrm metrics) + F4 (glyphEstimate gaps)

Date 2026-08-13. Repo: ~/projects/ztex (Zig 0.16). EDIT SCOPE: `src/layout/metrics.zig`
(+ its tests) only. INTENTIONAL output change — goldens regenerate; tests/goldens untouched.

## F3 — style-keyed roman (cmr10) metrics

**Problem (audit F3):** `glyph`/`glyphAt`/`lookupAscii` ignored `CharStyle`; Latin letters
A-Z/a-z resolved from the single cmmi10 (math-italic) rows, so `\text{...}` and `\mathrm{...}`
were laid out with italic widths. TeX typesets roman in family 0 = cmr10 ('f' was +1.84pt,
+60%; "hello" +0.68pt at 10pt).

**Fix:**
- New `tableRoman` (cmr10 letters A-Z a-z, 52 rows), `tableRoman7` (cmr7), `tableRoman5`
  (cmr5) — optical script/scriptscript partners. Values transcribed from cmr10/cmr7/cmr5 TFM
  (tftopl, em × 10 convention; identical to MicroTeX cmr*.def.cpp).
- `isRomanLetter(cp)` + `tableFor(cp, style, size_pt)`: roman-style letters pick the cmr10
  family tables; everything else keeps the existing math tables.
- `glyphAt`, `glyph` (fn pointer), `lookupAscii` (+ new comptime `roman_ascii_lut`) are now
  style-aware. Non-letter codepoints unchanged (digits/ops/punct/uppercase-Greek rows were
  already cmr10 in `table`).
- Verification (TeX-measured): `\mathrm{ab}` = 10.55559 (a 5.00002 + b 5.55557),
  `\mathrm{hello}` = 20.5556 (old cmmi sum 21.23273); f 3.05557, T 7.22224, V 7.50002,
  W 10.27781, Y 7.50002, H 7.50002, K 7.77781 — all match cmr10 TFM and XeTeX \showbox.

## F4 — the 65 glyphEstimate-fallback codepoints

Added 65 rows with real CM metrics (font + TFM slot, every value sourced, never invented):

- **Lowercase Greek** ζ η ι κ ν ξ ο ρ τ υ χ ψ → cmmi10 slots 16,17,19,20,23,24,26,28,29,31,32
  (plain.tex mathchardefs = greekl.mf = tftopl; values match audit F4: ζ 4.375, ι 3.539,
  χ 6.257, ψ 6.514, …). ο (U+03BF) → cmmi10 slot 111 = italic 'o' (MicroTeX base.def.cpp
  `E(5,111,omicron)`; Knuth's cmmi10 has no omicron glyph — the audit's 5.170 was ρ's width).
  Variants ς ϑ ϕ ϖ ϱ ϵ → cmmi10 38,35,39,36,37,34; Ϝ \digamma → msbm10 122.
- **Uppercase Greek** Ξ Υ Ψ → cmr10 slots 4,7,9 (6.66669 / 7.77781 / 7.77781).
- **ı ȷ** → cmmi10 123,124 (3.22456, 3.8403 — measured). **ℏ** → msbm10 126 (5.4028;
  amssymb AMSb "7E, MicroTeX E(0,126,hbar)). **℧** → msbm10 102 (7.22224). **ð** → msbm10 103.
- **Shapes** △ ▷→ cmsy10 52/53 (8.88891 — the F4 44%-narrow estimate), □ ■ → msam10 3/4,
  ◊ ⧫ → msam10 6/7, ✓ → msam10 88.
- **Suits** ♠ ♡ ♢ ♣ → cmsy10 127,126,125,124 (7.77781/6.94445/1.29629). **Music**
  ♭ ♮ ♯ → cmmi10 91,92,93 (3.8889; plain \flat="015B etc.).
- **Text** § ¶ → cmsy10 120,123 (plain \S \P = \mathhexbox278/27B; measured). £ → cmti10 36
  "Sterling sign" (italp.mf; \mathsterling, measured 7.69093/6.94444/0). ¥ → msam10 85
  (amsfonts \yen AMSa "55; 7.50002/6.75/ic .25). © → c + OMS-circle composite (LaTeX
  \textcopyright, measured 11.1084/7.49817/2.49939).
- **Relations** ∡ ∢ → msam10 93,94; ‵ → msam10 56; ∄ → msbm10 64; ≁ \nsim → msbm10 28;
  ≇ \ncong → msbm10 29; ≰ ≱ ⊈ ⊉ → msbm10 2,3,42,43 (7.77781/7.93829/3.02742); ⋘ ⋙ →
  msam10 110,111; ↣ ⇄ → msam10 26,29; ╱ \diagup → msbm10 30; ⨯ → cmsy10 2 (\times).
- **Composites** (TeX composes; measured) ≆ \simneqq = \not over ≃, ≉ \napprox = \not over ≈
  (7.77781/6.94444/1.94443 — the \not zero-width slash dominates h/d); ⤒ \baruparrow =
  \bar over ↑ (cmsy10 34, 5.00002/6.94445/1.94443).
- **Skipped (no real CM source):** none in `table` — all 65 audit codepoints covered.
  Note: gaps.py's "0x22B7 \models" and "0x2912 \rightarrowtail" were mislabeled; \models
  maps to U+22A8 (already present, msam10 178) and 0x2912 is \baruparrow (added as the
  \bar↑ composite). 0x2247 was mislabeled \nsim (it is ≇ \ncong, msbm10 29); the true
  \nsim U+2241 = msbm10 28 was added too.

All values cross-checked three ways: tftopl TFM dumps, MicroTeX def files
(src/res/font/*.def.cpp cloned from NanoMichael/MicroTeX), and live TeX \showbox/\the\wd
measurements (pdftex plain + LaTeX+amssymb, TeX Live 2025).

## Tests (metrics.zig)

- Extended "digits letters operators greek are covered" with the 65 new codepoints.
- New: "the 65 glyphEstimate-gap codepoints resolve with real CM metrics" (exact widths +
  wide-vs-5.0pt checks).
- New: "roman style letters use cmr10 widths, italic uses cmmi10" (13 letter deltas,
  \mathrm{ab} 10.55559, hello 20.5556 vs italic 21.23273).
- New: "roman letters at script sizes use the optical cmr7/cmr5" (glyphAt 7pt/5pt bands +
  lookupAscii fast path).

## Status / gates skipped

- `zig build test`: all 41 metrics tests pass. 4 failures elsewhere, all expected or
  peer-owned (EDIT ONLY metrics.zig; goldens regenerate per instruction):
  1. `layout: text yields one char box per grapheme` — hardcodes the OLD cmmi10 width
     13.90513; correct new value is 15.00005 (cmr10 a+b+c). Needs a one-line expectation
     update in src/layout/layout.zig (outside my edit scope).
  2. `layout: big operator limits in display style become a vbox` — pre-existing/peer
     in-flight (layout.zig modified 01:30 by other tasks; the path uses displayOp/cmex,
     untouched by this change).
  3. regression draw-list + svg snapshots — intentional goldens change (F3 widths).
