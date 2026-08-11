# metrics-fix.md — real Computer-Modern metrics for every relation/bin symbol

## Problem

`glyphEstimate` (width 0.5em = 5.0pt at 10pt, height 0.7em, depth 0.2em) was
the only metric for nearly every bin/rel/open/close codepoint that
`roleOfCp` (src/layout/layout.zig) classifies. Corpus divergence #2 in
`notes/corpus-diff.md`: the drawn glyphs (rendered from a real font) are wider
than the 5pt fallback box, so the following glyphs land 2.7–4.9pt too far
left; chains compound to ~5.4pt (worst: `→` 4.9pt, `≤ ≠ ∼ ⊆ ≈` 2.7pt,
`±` 2.7pt, literal `·` 2.2pt).

## Fix

`src/layout/metrics.zig` — 132 rows added to `metrics.table` (237 total, still
sorted ascending by codepoint, no duplicates). Every value is transcribed from
MicroTeX's symbol tables (`src/res/sym/*.def.cpp` → font + slot) and font
metric tables (`src/res/font/*.def.cpp`, em units × 10 → pt at 10pt). Font
ids in the `E(fontId, code, name)` rows are 0-based indices into MicroTeX's
`builtin_font_reg.cpp` order: 1=cmex10, 2=cmmi10, 5=cmmi10_unchanged,
7=stmary10, 8=cmsy10, 9=msam10, 0=msbm10, 18=cmr10.

Cross-checked against the real CM sources: MicroTeX's cmsy10 metrics match the
real `cmsy10.tfm` (tftopl) exactly for slots 33–126, and the slot→name pairing
matches Knuth's `symbol.mf` (→ = O41, ≤ = O34-metrics relocated to 183, etc.),
so the values below are the genuine Computer-Modern numbers.

## Added codepoints (cp, glyph, TeX name, font slot, w/h/d/ic at 10pt, Δ vs 5.0pt fallback)

### bin (roleOfCp)
| cp | glyph | name | font/slot | w | h | d | ic | Δ vs 5.0 |
|----|-------|------|-----------|-----|------|------|-----|----------|
| 0x00B1 | ± | \pm | cmsy10 167 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x00B7 | · | middle dot | cmsy10 (same as ⋅) | 2.7778 | 2.5 | 0 | 0 | −2.22 |
| 0x00D7 | × | \times | cmsy10 163 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x00F7 | ÷ | \div | cmsy10 165 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x2020 | † | \dagger | cmsy10 121 | 4.44446 | 6.94445 | 1.94445 | 0 | −0.56 |
| 0x2021 | ‡ | \ddagger | cmsy10 122 | 4.44446 | 6.94445 | 1.94445 | 0 | −0.56 |
| 0x2212 | − | minus | cmsy10 161 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x2213 | ∓ | \mp | cmsy10 168 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x2216 | ∖ | \setminus | cmsy10 110 | 5.00002 | 7.5 | 2.5 | 0 | 0 |
| 0x2217 | ∗ | \ast | cmsy10 164 | 5.00002 | 4.65279 | −0.34721 | 0 | 0 |
| 0x2218 | ∘ | \circ | cmsy10 177 | 5.00002 | 4.44446 | −0.55554 | 0 | 0 |
| 0x2219 | ∙ | \bullet | cmsy10 178 | 5.00002 | 4.44446 | −0.55554 | 0 | 0 |
| 0x2227 | ∧ | \wedge | cmsy10 94 | 6.66669 | 5.55557 | 0 | 0 | +1.67 |
| 0x2228 | ∨ | \vee | cmsy10 95 | 6.66669 | 5.55557 | 0 | 0 | +1.67 |
| 0x2229 | ∩ | \cap | cmsy10 92 | 6.66669 | 5.55557 | 0 | 0 | +1.67 |
| 0x222A | ∪ | \cup | cmsy10 91 | 6.66669 | 5.55557 | 0 | 0 | +1.67 |
| 0x2240 | ≀ | \wr | cmsy10 111 | 2.77779 | 6.94445 | 1.94443 | 0 | −2.22 |
| 0x228E | ⊎ | \uplus | cmsy10 93 | 6.66669 | 5.55557 | 0 | 0 | +1.67 |
| 0x2293 | ⊓ | \sqcap | cmsy10 117 | 6.66669 | 5.55557 | 0 | 0 | +1.67 |
| 0x2294 | ⊔ | \sqcup | cmsy10 116 | 6.66669 | 5.55557 | 0 | 0 | +1.67 |
| 0x2295 | ⊕ | \oplus | cmsy10 169 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x2296 | ⊖ | \ominus | cmsy10 170 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x2297 | ⊗ | \otimes | cmsy10 171 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x2298 | ⊘ | \oslash | cmsy10 174 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x2299 | ⊙ | \odot | cmsy10 175 | 7.77781 | 5.83334 | 0.83334 | 0 | +2.78 |
| 0x22C4 | ⋄ | \diamond | cmsy10 166 | 5.00002 | 4.44446 | −0.55554 | 0 | 0 |
| 0x22C6 | ⋆ | \star | cmmi10 63 | 5.00002 | 4.65279 | −0.34721 | 0 | 0 |
| 0x25B9 | ▹ | \triangleright | cmmi10 46 | 5.00002 | 4.65279 | −0.34721 | 0 | 0 |
| 0x25C3 | ◃ | \triangleleft | cmmi10 47 | 5.00002 | 4.65279 | −0.34721 | 0 | 0 |
| 0x25CB | ○ | \bigcirc | cmsy10 176 | 10.00003 | 6.94445 | 1.94445 | 0 | +5.00 |
| 0x2A3F | ⨿ | \amalg | cmsy10 113 | 7.50002 | 6.83332 | 0 | 0 | +2.50 |

### rel (roleOfCp)
| cp | glyph | name | font/slot | w | h | d | ic | Δ vs 5.0 |
|----|-------|------|-----------|-----|------|------|-----|----------|
| 0x2190 | ← | \leftarrow | cmsy10 195 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x2191 | ↑ | \uparrow | cmsy10 34 | 5.00002 | 6.94445 | 1.94443 | 0 | 0 |
| 0x2192 | → | \rightarrow | cmsy10 33 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x2193 | ↓ | \downarrow | cmsy10 35 | 5.00002 | 6.94445 | 1.94443 | 0 | 0 |
| 0x2194 | ↔ | \leftrightarrow | cmsy10 36 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x2195 | ↕ | \updownarrow | cmsy10 108 | 5.00002 | 7.5 | 2.5 | 0 | 0 |
| 0x2196 | ↖ | \nwarrow | cmsy10 45 | 10.00003 | 6.94445 | 1.94443 | 0 | +5.00 |
| 0x2197 | ↗ | \nearrow | cmsy10 37 | 10.00003 | 6.94445 | 1.94443 | 0 | +5.00 |
| 0x2198 | ↘ | \searrow | cmsy10 38 | 10.00003 | 6.94445 | 1.94443 | 0 | +5.00 |
| 0x2199 | ↙ | \swarrow | cmsy10 46 | 10.00003 | 6.94445 | 1.94443 | 0 | +5.00 |
| 0x21A6 | ↦ | \mapsto | cmsy10 55+33 composite | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x21A9 | ↩ | \hookleftarrow | ← 3\joinrel \rhook | 8.44449 | 4.63748 | −1.33125 | 0 | +3.44 |
| 0x21AA | ↪ | \hookrightarrow | \lhook 3\joinrel → | 8.44449 | 4.63748 | −1.33125 | 0 | +3.44 |
| 0x21BC | ↼ | \leftharpoonup | cmmi10 40 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x21BD | ↽ | \leftharpoondown | cmmi10 41 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x21C0 | ⇀ | \rightharpoonup | cmmi10 42 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x21C1 | ⇁ | \rightharpoondown | cmmi10 43 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x21D0 | ⇐ | \Leftarrow | cmsy10 40 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x21D1 | ⇑ | \Uparrow | cmsy10 42 | 6.11113 | 6.94445 | 1.94443 | 0 | +1.11 |
| 0x21D2 | ⇒ | \Rightarrow | cmsy10 41 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x21D3 | ⇓ | \Downarrow | cmsy10 43 | 6.11113 | 6.94445 | 1.94443 | 0 | +1.11 |
| 0x21D4 | ⇔ | \Leftrightarrow | cmsy10 44 | 10.00003 | 3.66875 | −1.33125 | 0 | +5.00 |
| 0x21D5 | ⇕ | \Updownarrow | cmsy10 109 | 6.11113 | 7.5 | 2.5 | 0 | +1.11 |
| 0x2208 | ∈ | \in | cmsy10 50 | 6.66669 | 5.39098 | 0.39098 | 0 | +1.67 |
| 0x2209 | ∉ | \notin | \not+\in composite | 6.66669 | 6.94445 | 1.94443 | 0 | +1.67 |
| 0x220B | ∋ | \ni | cmsy10 51 | 6.66669 | 5.39098 | 0.39098 | 0 | +1.67 |
| 0x221D | ∝ | \propto | cmsy10 47 | 7.77781 | 4.30555 | 0 | 0 | +2.78 |
| 0x2223 | ∣ | \mid | cmsy10 106 (\vert) | 2.77779 | 7.5 | 2.5 | 0 | −2.22 |
| 0x2224 | ∤ | \nmid | msbm10 45 | 2.77779 | 7.41110 | 2.51422 | 0 | −2.22 |
| 0x2225 | ∥ | \parallel | cmsy10 107 (\Vert) | 5.00002 | 7.5 | 2.5 | 0 | 0 |
| 0x2226 | ∦ | \nparallel | msbm10 44 | 5.00002 | 7.41110 | 2.51422 | 0 | 0 |
| 0x2234 | ∴ | \therefore | msam10 41 | 6.66669 | 6.92241 | 0 | 0 | +1.67 |
| 0x2235 | ∵ | \because | msam10 42 | 6.66669 | 6.92241 | 0 | 0 | +1.67 |
| 0x223C | ∼ | \sim | cmsy10 187 | 7.77781 | 3.66875 | −1.33125 | 0 | +2.78 |
| 0x2243 | ≃ | \simeq | cmsy10 39 | 7.77781 | 4.63748 | −0.36252 | 0 | +2.78 |
| 0x2245 | ≅ | \cong | composite (\sim + rule) | 7.77781 | 3.66875 | −1.33125 | 0 | +2.78 |
| 0x2248 | ≈ | \approx | cmsy10 188 | 7.77781 | 4.83122 | −0.16878 | 0 | +2.78 |
| 0x224D | ≍ | \asymp | cmsy10 179 | 7.77781 | 4.63748 | −0.36252 | 0 | +2.78 |
| 0x2250 | ≐ | \doteq | composite (dot over =) | 7.77781 | 3.66875 | −1.33125 | 0 | +2.78 |
| 0x2260 | ≠ | \ne | \not over = | 7.77781 | 6.94445 | 1.94443 | 0 | +2.78 |
| 0x2261 | ≡ | \equiv | cmsy10 180 | 7.77781 | 4.63748 | −0.36252 | 0 | +2.78 |
| 0x2262 | ≢ | \not\equiv | \not over ≡ | 7.77781 | 6.94445 | 1.94443 | 0 | +2.78 |
| 0x2264 | ≤ | \leq | cmsy10 183 | 7.77781 | 6.35971 | 1.35971 | 0 | +2.78 |
| 0x2265 | ≥ | \geq | cmsy10 184 | 7.77781 | 6.35971 | 1.35971 | 0 | +2.78 |
| 0x2266 | ≦ | \leqq | msam10 53 | 7.77781 | 7.55834 | 2.55834 | 0 | +2.78 |
| 0x2267 | ≧ | \geqq | msam10 61 | 7.77781 | 7.55834 | 2.55834 | 0 | +2.78 |
| 0x226A | ≪ | \ll | cmsy10 191 | 10.00003 | 5.39098 | 0.39098 | 0 | +5.00 |
| 0x226B | ≫ | \gg | cmsy10 192 | 10.00003 | 5.39098 | 0.39098 | 0 | +5.00 |
| 0x227A | ≺ | \prec | cmsy10 193 | 7.77781 | 5.39098 | 0.39098 | 0 | +2.78 |
| 0x227B | ≻ | \succ | cmsy10 194 | 7.77781 | 5.39098 | 0.39098 | 0 | +2.78 |
| 0x2282 | ⊂ | \subset | cmsy10 189 | 7.77781 | 5.39098 | 0.39098 | 0 | +2.78 |
| 0x2283 | ⊃ | \supset | cmsy10 190 | 7.77781 | 5.39098 | 0.39098 | 0 | +2.78 |
| 0x2286 | ⊆ | \subseteq | cmsy10 181 | 7.77781 | 6.35971 | 1.35971 | 0 | +2.78 |
| 0x2287 | ⊇ | \supseteq | cmsy10 182 | 7.77781 | 6.35971 | 1.35971 | 0 | +2.78 |
| 0x2291 | ⊑ | \sqsubseteq | cmsy10 118 | 7.77781 | 6.35971 | 1.35971 | 0 | +2.78 |
| 0x2292 | ⊒ | \sqsupseteq | cmsy10 119 | 7.77781 | 6.35971 | 1.35971 | 0 | +2.78 |
| 0x22A2 | ⊢ | \vdash | cmsy10 96 | 6.11113 | 6.94445 | 0 | 0 | +1.11 |
| 0x22A3 | ⊣ | \dashv | cmsy10 97 | 6.11113 | 6.94445 | 0 | 0 | +1.11 |
| 0x22A5 | ⊥ | \perp | cmsy10 63 | 7.77781 | 6.94445 | 0 | 0 | +2.78 |
| 0x22A8 | ⊨ | \vDash | msam10 178 | 6.11113 | 6.92241 | 0 | 0 | +1.11 |
| 0x22C8 | ⋈ | \bowtie | ▹ \joinrel ◃ composite | 8.55560 | 4.65279 | −0.34721 | 0 | +3.56 |
| 0x2322 | ⌢ | \frown | cmmi10 95 | 10.00003 | 3.57640 | −1.42360 | 0 | +5.00 |
| 0x2323 | ⌣ | \smile | cmmi10 94 | 10.00003 | 3.57640 | −1.42360 | 0 | +5.00 |
| 0x27F5 | ⟵ | \longleftarrow | ← \joinrel \relbar | 16.33340 | 3.66875 | −1.33125 | 0 | +11.33 |
| 0x27F6 | ⟶ | \longrightarrow | \relbar \joinrel → | 16.33340 | 3.66875 | −1.33125 | 0 | +11.33 |
| 0x27F7 | ⟷ | \longleftrightarrow | ← \joinrel → | 18.55562 | 3.66875 | −1.33125 | 0 | +13.56 |
| 0x27F8 | ⟸ | \Longleftarrow | ⇐ \joinrel \Relbar | 16.33340 | 3.66875 | −1.33125 | 0 | +11.33 |
| 0x27F9 | ⟹ | \Longrightarrow | \Relbar \joinrel ⇒ | 16.33340 | 3.66875 | −1.33125 | 0 | +11.33 |
| 0x27FA | ⟺ | \Longleftrightarrow | ⇐ \joinrel ⇒ | 18.55562 | 3.66875 | −1.33125 | 0 | +13.56 |
| 0x2A7D | ⩽ | \leqslant | msam10 54 | 7.77781 | 6.36665 | 1.36665 | 0 | +2.78 |
| 0x2A7E | ⩾ | \geqslant | msam10 62 | 7.77781 | 6.36665 | 1.36665 | 0 | +2.78 |
| 0x2AAF | ⪯ | \preceq | cmsy10 185 | 7.77781 | 6.35971 | 1.35971 | 0 | +2.78 |
| 0x2AB0 | ⪰ | \succeq | cmsy10 186 | 7.77781 | 6.35971 | 1.35971 | 0 | +2.78 |

### open/close (roleOfCp)
| cp | glyph | name | font/slot | w | h | d | ic |
|----|-------|------|-----------|-----|------|------|-----|
| 0x27E8 | ⟨ | \langle | cmsy10 104 | 3.8889 | 7.5 | 2.5 | 0 |
| 0x27E9 | ⟩ | \rangle | cmsy10 105 | 3.8889 | 7.5 | 2.5 | 0 |
| 0x2308 | ⌈ | \lceil | cmsy10 100 | 4.44446 | 7.5 | 2.5 | 0 |
| 0x2309 | ⌉ | \rceil | cmsy10 101 | 4.44446 | 7.5 | 2.5 | 0 |
| 0x230A | ⌊ | \lfloor | cmsy10 98 | 4.44446 | 7.5 | 2.5 | 0 |
| 0x230B | ⌋ | \rfloor | cmsy10 99 | 4.44446 | 7.5 | 2.5 | 0 |

### op (roleOfCp, text-style big operators)
| cp | glyph | name | font/slot | w | h | d | ic |
|----|-------|------|-----------|-----|------|------|-----|
| 0x22C0 | ⋀ | \bigwedge | cmex10 86 | 8.33336 | 0 | 10.00013 | 0 |
| 0x22C1 | ⋁ | \bigvee | cmex10 87 | 8.33336 | 0 | 10.00013 | 0 |
| 0x2A00 | ⨀ | \bigodot | cmex10 74 | 11.111145 | 0 | 10.00013 | 0 |
| 0x2A01 | ⨁ | \bigoplus | cmex10 76 | 11.111145 | 0 | 10.00013 | 0 |
| 0x2A02 | ⨂ | \bigotimes | cmex10 78 | 11.111145 | 0 | 10.00013 | 0 |
| 0x2A04 | ⨄ | \biguplus | cmex10 85 | 8.33336 | 0 | 10.00013 | 0 |
| 0x2A05 | ⨅ | \bigsqcap | stmary10 132 | 8.33336 | 0 | 10.00013 | 0 |

### corpus-common math symbols (beyond roleOfCp; task list)
| cp | glyph | name | font/slot | w | h | d | ic | Δ vs 5.0 |
|----|-------|------|-----------|-----|------|------|-----|----------|
| 0x2032 | ′ | \prime | cmsy10 48 | 2.75 | 5.55557 | 0 | 0 | −2.25 |
| 0x2033 | ″ | double prime | composite: 2 × \prime | 5.5 | 5.55557 | 0 | 0 | +0.5 |
| 0x2202 | ∂ | \partial | cmmi10 64 | 5.30904 | 6.94445 | 0 | 0.55555 | +0.31 |
| 0x2205 | ∅ | \emptyset | cmsy10 59 | 5.00002 | 7.5 | 0.55555 | 0 | 0 |
| 0x2207 | ∇ | \nabla | cmsy10 114 | 8.33336 | 6.83332 | 0 | 0 | +3.33 |
| 0x221A | √ | \surd | cmsy10 112 | 8.33336 | 0.39999 | 9.60001 | 0 | +3.33 |
| 0x221E | ∞ | \infty | cmsy10 49 | 10.00003 | 4.30555 | 0 | 0 | +5.00 |
| 0x2220 | ∠ | \angle | msam10 92 | 7.22224 | 6.92241 | 0 | 0 | +2.22 |
| 0x22EF | ⋯ | \cdots | composite: 3 × cdot | 8.33337 | 4.44446 | −0.55554 | 0 | +3.33 |

## Composite entries (no single CM glyph — TeX composes them)

Verified against plain.tex and MicroTeX's `core/formula_def.cpp`:

- `≠` = `\not=` — zero-width `\not` (cmsy10 54) over `=` (cmr10 61): w = ='s 0.777781em; h/d from `\not` (0.694445/0.194443).
- `≢` = `\not\equiv` (cmsy10 54 over cmsy10 180): w 0.777781em.
- `∉` = `\not\in` (cmsy10 54 over cmsy10 50): w 0.666669em.
- `≅` = `\sim` + vertical rule (`\mathpalette\@vereq\sim`): w = \sim (cmsy10 187) 0.777781em.
- `≐` = `\buildrel . \over =` (cmr10 61): w 0.777781em.
- `↦` = `\mapstochar\rightarrow` (cmsy10 55 w 0 + 33): w 1.000003em.
- `↩`/`↪` = arrow + 3×`\joinrel` (−2.6mu = −0.144444em each, MicroTeX macro_impl.h) + hook (cmmi10 44/45): w 0.844449em.
- `⋈` = `\triangleright\joinrel\triangleleft` (cmmi10 46/47): w 0.855560em.
- `⟵`–`⟹` = arrow + `\joinrel` + `\relbar`/`\Relbar` (cmsy10 161 / cmr10 61): w 1.633340em; `⟷`/`⟺` = two arrows + `\joinrel`: w 1.855562em.
- `⋯` = `\mathinner{\cdotp\cdotp\cdotp}` (cmsy10 162 ×3): w 0.833337em.
- `″` = `\prime\prime` (cmsy10 48 ×2): w 0.55em.

## Notes

- U+00B7 (·) gets the identical tuple as the existing U+22C5 (⋅) entry
  (cmsy10 middle dot, w 2.7778/h 2.5/d 0) — the corpus's literal `·` previously
  fell back to the 5pt box (2.2pt divergence) while U+22C5 already had a metric.
- U+003A (:) keeps its existing cmr10 metric (w 2.77779, h 4.30555). TeX's
  math `\colon` renders with the cmmi10 colon (h 1.05556 — much tighter
  vertically); the tighter look is a layout/parser concern (which font/slot
  `:` maps to), not a metrics-table value, so it is left untouched as
  instructed.
- `glyphEstimate` left as-is: it is now hit only by glyphs with no CM slot
  (e.g. emoji), which is the intended fallback.
- Tests added: full roleOfCp coverage (no fallback), exact-width assertions
  for the corpus-critical symbols, and a check that the worst offenders are
  wider than the 5.0pt estimate. Existing sort/positive-extent tests already
  cover the new rows.
