# fix-el-details — Euler-Lagrange rendering defects

Formula: `\frac{d}{dt} \left( \frac{\partial L}{\partial \dot{q}} \right) = \frac{\partial L}{\partial q}` at 40pt (ztex) vs XeTeX+unicode-math (xelatex, `\fontsize{40}{48}`, display, mutool per-glyph extraction — note XeTeX's classic point conversion renders the "40pt" ref at 39.8506pt).

Files: `src/layout/layout.zig`, `src/layout/metrics.zig` (parser.zig untouched — `\partial` stays 0x2202; the math-style mapping lives in layout like the letters). SKIP gates. Goldens regenerate (no golden covers `\partial`, accents, or `\left..\right` — `zig build test` passes unchanged).

## 1. \partial → U+1D715 (math-italic partial)

- `layout.zig mathItalic()`: `0x2202 → 0x1D715`, the systematic companion of the letter mapping (Math Alphanumeric Symbols block). Math style (`$...$`) renders the math-italic form; `\mathrm{\partial}` keeps U+2202.
- `metrics.zig`: U+1D715 rows added to `table`/`table7`/`table5` (w = 5.31 = the LM Math hmtx advance 0.531em; h/d/ic from the U+2202 rows) and `ink_table` (0.716/0.022 — LM Math draws both forms with identical vertical extents, measured with fontTools).
- Validated by `hasGlyph` like the letters; the box and the SVG now carry U+1D715.

Measured (fontTools, latinmodern-math.otf 2.005): U+2202 adv 0.586em, ink (0.056,-0.022,0.529,0.716); U+1D715 adv 0.531em, ink (0.040,-0.022,0.566,0.716). The XeTeX ref emits u1D715 (`data-text="&#x1d715;"` confirmed in the mutool SVG).

| | before | after | ref |
|---|---|---|---|
| glyph | U+2202 (adv 0.586em) | U+1D715 (adv 0.531em) | U+1D715 |
| ∂→L gap | 0 | 0 | 2.47pt (∂ MATH italic-correction kern 0.063em — ztex applies no post-ord ic kerns; pre-existing spacing difference owned by the glue/ic work, not this task) |

## 2. Accent shifted right over the slanted base

Reference measurement (`\dot{q}` in the formula, ref at 39.85pt, from the mutool SVG + font outlines):
- dot ink center = q_origin + 0.349em (= u1D45E's MATH-table **MathTopAccentAttachment** 0.349em — XeTeX's accent rule with unicode-math).
- q ink center = 0.246em (ink bbox (0.040,-0.194,0.452,0.442) ÷ 2). The task brief's "q ink center 0.177em / dot 0.17em right of it" is a mis-measurement (0.347 − 0.177 arithmetic held, but the true q ink center is 0.246em); the accurate mechanism is the MATH attachment — the dot sits 0.103em right of the q INK CENTER, which is what the actual ref measures.
- old ztex: mark origin = box center + 0.264em → dot ink at bb.width/2 = 0.223em — LEFT of the q ink center.

Fix (`layoutAccent`): mark origin x = base's MathTopAccentAttachment × size + 0.264 × size (0.264em = the combining marks' ink offset from their origin, the mark's own attachment). The base's drawn glyph is found by descending the base box (a braced base is a group→row hbox with cp 0) to its LAST char box, using that char's cp + x_shift. Bases without a row fall back to the old box-center placement (composites, unmeasured glyphs).

`metrics.zig`: `accent_attach` table — MathTopAccentAttachment (em) for every letter/Greek/symbol form the parser can produce as an accent base (both base and math-italic mapped cps, ~170 rows, extracted from the font MATH table).

| | before | after | ref | Δ vs ref |
|---|---|---|---|---|
| dot ink rel q origin | 0.223em (8.9pt) | 0.349em (13.94pt) | 0.349em (13.89pt) | +0.05pt |
| dot ink − q ink center | −0.023em (−0.9pt) | +0.103em (4.10pt) | +0.103em (4.09pt) | +0.02pt |

## 3. \left..\right parens: MATH size-variant boxes at base size

- `metrics.zig`: `delim_ladder` — for the 12 delimiters `( ) [ ] { } ⟨ ⟩ ⌈ ⌉ ⌊ ⌋`, the base entry + 7 MATH-table size variants, each with the hmtx advance and ink asc/desc (em), measured with fontTools (VertGlyphConstruction + BoundsPen + hmtx). Every LM variant keeps its ink center at 0.25em (asc − desc = 0.5em), so the axis-centered shift `(h−d)/2 − axis` = 0.
- `layoutLeftRight`: required ink height by TeX make_delim (tex.web §1114, as transcribed by MicroTeX FencedAtom): δ = max(h − a, d + a); ink ≥ max(2·δ·901/1000, 2·δ − shortfall), shortfall = 0.1em. Pick the SMALLEST variant whose ink (asc+desc) covers it (the LARGEST when none does). The ladder's base entry covers a plain `\left(x\right)` — byte-identical to the old un-stretched render (same advance 0.389em, same ink 0.748/0.248).
- `layoutDelimChar`: the box = variant advance × size and variant ink × size at the BASE font size — no font-size scaling (scaling the base glyph thickens the stroke linearly; the variants keep a constant stroke). The SVG emits the base delimiter char at the base font-size; the rasterizer resolves the variant from the MATH table (FixParenVariants — see Residuals). Delimiters without a ladder (`\left|`) fall back to the old continuous scaled-base path (`layoutScaledChar`, still used by `\sqrt`).

Selection verified against the ref: the Euler formula's floor is 87.0pt at 39.85 → **parenleft.v6** (2.392em) — the exact variant the XeTeX ref draws (measured ink span 2.392em). `\left( \frac{a}{b} \right)` at 40pt → v5.

| | before | after | ref |
|---|---|---|---|
| paren font-size | 101.3pt (scaled base) | 40pt (base) | 39.85pt (base) |
| paren variant | base glyph scaled | parenleft.v6 (adv 0.736em, ink 1.446/0.946) | parenleft.v6 |
| fraction ink center vs visible paren-gap center | 20.6pt off | 1.4pt off | 1.8pt off (the ref itself is not exactly centered) |

Content is exactly centered between the variant boxes for symmetric delimiters: gap center = (left ink right edge + right ink left edge)/2 = open-box width + content/2 for LM Math's ink-in-advance design.

## Verification

- `zig build test` passes unchanged (the golden corpus has no `\partial`/accents/`\left..\right`).
- `\sqrt{x^2+1}`, `\sum_{i=1}^{n} x_i`, `\left( \frac{a}{b} \right)`, `\left\{ \right\}`, `\langle \rangle`, `\lfloor \rfloor`, `\left(x\right)` (non-stretched, byte-identical), `\left|` (fallback) all render; 10pt Euler renders.
- Frame/viewBox bounds the paren ink (v6 ink top 3.2pt > 0).

## Residuals / coordination

1. **scripts/critique.py rasterizer**: `_delimiter_resolution` detects stretched delimiters ONLY via declared font-size > base size. The new layout emits base-size delimiters, so the PIL raster/geometric verifier draw the BASE paren glyph (small), not the variant. FixParenVariants/PilCritique/VerifyCritic own critique.py (out of this task's EDIT-ONLY scope); the verifier needs to derive the required height from the layout box (minh from the TeX rule) instead of the declared size. Flagged to Main.
2. **Post-ord italic-correction kerns**: the ref kerns the MATH italic correction after ∂ (0.063em → 2.47pt ∂L gap) and after d (0.024em → 0.92pt dt gap); ztex applies no ord ic kerns (pre-existing, affects every multi-char row — the glue/ic/drift work owns it). The ∂L fraction width is 2.3pt narrower than the ref because of this; the glyph/advance fix itself is exact.
