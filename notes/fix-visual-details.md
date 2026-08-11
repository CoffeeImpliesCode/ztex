# Fix visual details — 4 classical-formula defects

Fixed four vision-critique defects from the classical-formula battery
(Maxwell, Gaussian, Pythagorean trig, Schrödinger). Edits: `src/parse/parser.zig`,
`src/layout/layout.zig` only. Measurements at 36pt (ztex `-s 36`), compared to
the XeTeX (`xelatex` + `unicode-math`, display style) and KaTeX (0.16.28,
display mode) references. All ink geometry from the real Latin Modern Math OTF
outlines (fontTools) / the ref pipelines.

## 1. `\varepsilon` shape — Maxwell `\frac{\rho}{\varepsilon_0}`

- **Ours before**: `\varepsilon` → U+03F5 (GREEK LUNATE EPSILON SYMBOL ϵ) →
  math-italic U+1D716 `𝜖`. The lunate (curly) form.
- **Refs**: XeTeX+unicode-math emits `\varepsilon` → **U+03B5** (the ROUNDED
  epsilon) → math-italic U+1D700 `𝜀`; KaTeX emits U+03B5. Probe-verified in
  the XeTeX stext: `\epsilon` → U+1D716, `\varepsilon` → U+1D700 — unicode-math
  maps them OPPOSITE to classic Computer-Modern TeX.
- **Fix**: swapped `symbol_map`: `\epsilon` → 0x03F5, `\varepsilon` → 0x03B5.
  `mathItalic` already maps 0x03B5 (α–ω run → U+1D700) and 0x03F5 → U+1D716;
  both forms have metric + ink + accent-attach rows, so nothing else changed.
- **Measured after**: Maxwell render emits `𝜀` U+1D700 (ink height 17.1pt) —
  identical glyph to the XeTeX ref (17.0pt). Critique: the ε nit is gone
  ("the ε symbol matches well").
- **Nit delta**: `[crit] ε uses a different (lunate) symbol` → gone; ref
  critique-1 PASS (6 nits, none about ε).

## 2. Minus sign — Gaussian `\int_{-\infty}^{\infty} e^{-x^2}`

- **Ours before**: `-` parsed as a plain char → U+002D HYPHEN-MINUS. LM Math
  draws it as a SHORT hyphen: ink 0.265em wide / 0.245em tall, advance
  0.333em. The exponent minus rendered 6.68pt of ink at 25.2pt.
- **Refs**: XeTeX+unicode-math maps the math hyphen to the FULL-WIDTH
  MINUS SIGN U+2212 (ink 0.666em wide, advance 0.778em); KaTeX emits U+2212
  too. The ref minus ink at 25.1pt: 16.72pt wide — 2.5× ours.
- **Fix**: in `layoutChar`, `if (cp == 0x2D) mcp = 0x2212;` (before the
  math-italic mapping, so it applies to every math style). The box then takes
  the U+2212 metric advance (7.78pt@10 vs 3.33pt) and the U+2212 ink
  (0.270 asc, table) and is marked synthetic. `\text{a-b}` is unaffected —
  `layoutText` reads the source directly (XeTeX keeps the text hyphen there).
- **Measured after**: exponent minus ink 16.78pt wide vs ref 16.72pt; lower
  limit `-\infty` minus 16.78pt vs 16.72pt. Position advances now match
  (0.778em). Critique: the "too short minus" nit is gone (remaining nits are
  the pre-existing ∫ limits/spacing issues, out of scope here).
- **Nit delta**: `[crit] - sign too short` → gone.

## 3. `\sin^2` / `\cos^2` script placement — Pythagorean trig

- **Ours before** (TeX rule for a box base): raise = max(word_height −
  sup_drop, sup2). The `\sin` word's `i` dot (ink top 0.657em) dominated:
  sin^2 raise 17.36pt; cos^2 (x-height word 0.448em) fell to the sup2 floor
  13.07pt — a visible 4.3pt height difference between the two '2's.
- **Refs**: XeTeX shows the same structure (16.85 / 13.01). KaTeX places both
  '2's at nearly the same height: sin^2 15.15pt, cos^2 14.87pt at 36pt.
- **KaTeX rule measured** (katex source + HTML `top:` offsets + raster ink):
  `raise = max(sup1, word_height − supDrop_script × 0.7)` with sup1 =
  0.413em and supDrop at the script size 0.353em × 0.7 = 0.2471em (em of the
  base size). Both op-word '2's land on the 0.413em floor because their word
  heights − 0.2471 stay under it.
- **Fix**: in `layoutScript`, for an `.opname` base only: `sup_floor =
  s(4.13, size)` (0.413em) and `sup_base = base_h − s(2.471, size)`
  (0.2471em). All other bases keep the TeX/XeTeX rule (x^2 etc. unchanged —
  XeTeX-verified sup2 floor).
- **Measured after**: sin^2 raise 14.87pt, cos^2 14.87pt (identical). Vs
  KaTeX (katex_ref geometry: 15.01 / 14.73): Δ 0.14pt / 0.14pt — both well
  within the 0.3pt target (the small residual is the LM 'i' ink 0.657em vs
  KaTeX's 0.669em, font-driven). XeTeX still shows the old split (16.86 /
  13.02) — the task asked to match KaTeX here.
- **Nit delta**: `[crit] ^2 on sin and cos at different heights & offsets` →
  gone; ref critique-3 PASS (4 nits; the "slightly higher" minor = the
  0.28pt vs KaTeX + XeTeX's higher placement averaged by the vision model).

## 4. `\hat{H}` hat too low — Schrödinger

- **Ours before**: every accent mark sat on the base's baseline (XeTeX's
  natural position for x-height bases). The combining circumflex ink bottom
  (0.587em above baseline) overlapped the math-italic H ink top (0.683em) —
  the hat merged into the H.
- **Refs**: XeTeX raises the hat: ink bottom 0.819em (clearance 0.137em
  above the H ink top 0.682em); KaTeX raises it to 0.78em (clearance ~0.10em).
  A 13-base XeTeX probe (`\hat H M A x q d f b T \ell E I`, `\dot q`)
  established the rule: for a base whose ink top exceeds the LM Math
  MATH-table **AccentBaseHeight 0.45em**, the mark is raised by
  (base_ink_top − 0.45em); shorter bases keep the natural (baseline) position
  — measured clearance 0.1368em constant for every tall base.
- **Fix**: in `layoutAccent`, `raise = max(0, base_ink_top − 0.45) ×
  accent_size`, applied as the mark's shift (y-down: negative = up); the
  result box height grows to `max(bb.height, raise + mark_ink.asc × size)`.
  `\dot{q}` (q ink top 0.442em < 0.45) is untouched — raise 0.
- **Measured after**: hat ink bottom 0.820em, H ink top 0.683em, clearance
  0.137em — the XeTeX reference within 0.001em (0.04pt); hat ink top 0.967em
  vs ref 0.963em.
- **Nit delta**: `[crit] hat too low, merges into H` → gone; ref critique-4
  FAIL (6 nits, none about the hat placement — remaining nits are font-shape
  and spacing items out of scope).

## Constraints honored

- `\dot{q}`: q ink top 0.442em < 0.45em → no raise; dot stays on the q
  baseline at exactly the previous ink (0.677em top) — verified.
- `\sin x` thin space: glue path untouched; measured sin→x gap 6.0pt =
  3/18em at 36pt — unchanged.
- `\left\right`, `\sqrt`, big-op limits, `x^2` char-base scripts: untouched
  code paths; smoke corpus renders clean (`\sin x`, `\left(\frac{a}{b}\right)`,
  `\sqrt{x^2+1}`, `\lim_{x \to 0} \sin x`, `x^2+y^2`, `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`).

## Ref critique after (`scripts/critique.py --ref -s 36`)

| Formula | Verdict | The 4 target nits |
|---|---|---|
| Maxwell `\nabla \cdot E = \frac{\rho}{\varepsilon_0}` | PASS (6 nits) | "ε uses a different symbol" → **gone** |
| Gaussian `\int_{-\infty}^{\infty} e^{-x^2} dx = \sqrt{\pi}` | FAIL (7 nits) | "- sign too short" → **gone** (residual: pre-existing ∫ limits/spacing, out of scope) |
| Pyth `\sin^2 \theta + \cos^2 \theta = 1` | PASS (4 nits) | "^2 at different heights & offsets" → **gone** |
| Schrödinger `\hat{H} \psi = E \psi` | FAIL (6 nits) | "hat too low, merges into H" → **gone** (residual: font-shape/spacing minors) |

## Files

- `src/parse/parser.zig` — `symbol_map` epsilon/varepsilon swap (2 lines).
- `src/layout/layout.zig` — `layoutChar` minus mapping (cp 0x2D → 0x2212);
  `layoutAccent` AccentBaseHeight raise; `layoutScript` op-word sup rule
  (0.413em floor / 0.2471em drop).
