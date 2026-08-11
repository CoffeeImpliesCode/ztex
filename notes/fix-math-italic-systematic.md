# Fix: math-italic glyph selection — systematic Unicode series + Greek

Replace the hardcoded ASCII-only math-italic mapping (`mathItalicCp`,
a-z → U+1D44E… from the earlier FixMathItalic) with a COMPUTED mapping over
the Unicode Math Alphanumeric Symbols block (U+1D400–U+1D7FF), and extend
it to lowercase Greek (and the TeX variant forms), each mapped cp validated
against the ACTIVE metric source (font cmap / static table) before emission.

Files: `src/layout/layout.zig`, `src/layout/metrics.zig`, `src/font.zig`.
No test/golden edits (goldens unaffected — see "Test impact" below).

## Series arithmetic (layout.zig `mathItalic(cp) ?u21`)

The math-italic forms are NOT ad-hoc: each style series is a contiguous run
in the block. The mapping is a handful of range checks + offsets:

| Input run | Series start | Offset | Output run |
|---|---|---|---|
| Latin capital A–Z (U+0041..005A) | U+1D434 | cp − 'A' | U+1D434..U+1D44D |
| Latin small a–z (U+0061..007A) | U+1D44E | cp − 'a' | U+1D44E..U+1D467 |
| Greek small α–ω (U+03B1..03C9) | U+1D6FC | cp − U+03B1 | U+1D6FC..U+1D714 |
| Variants ϵ/ϑ/ϱ/ϕ/ϖ (U+03F5/03D1/03F1/03D5/03D6) | — (explicit slots) | — | U+1D716/1D717/1D71A/1D719/1D71B |

Special cases, all verified against the XeTeX + unicode-math reference
(mutool extraction of xelatex PDFs, this ticket):
- `h` U+0068 → **U+210E ℎ** (Planck constant): U+1D455 (math-italic h) is
  UNASSIGNED in Unicode and absent from LM Math; XeTeX emits `&#x210e;`.
- ς U+03C2 (final sigma) lies INSIDE the α–ω run, so the series covers it
  → U+1D70D (no special case needed).
- Greek CAPITALS are deliberately NOT mapped: unicode-math's TeX-style math
  keeps uppercase Greek upright. Probe: `\Gamma(x)` → `&#x0393;` (U+0393
  upright), `(`, `&#x1d465;`, `)`. So `\Gamma(x)` stays upright. The
  U+1D6E2..U+1D6FA capital series (off = cp − U+0391) is left to a future
  \varGamma/\mathit-capitals path.

Variant slot names (UnicodeData <compat> decompositions, python
unicodedata): 1D716←03F5, 1D717←03D1, 1D718←03F0 (ϰ, not parsed),
1D719←03D5, 1D71A←03F1, 1D71B←03D6.

## Font-cmap validation (spec point 2)

Emission is gated on the mapped cp being RENDERABLE by the active metric
source:

- `font.zig`: new `FontFace.hasGlyph(cp) bool` (wrapper over the existing
  `glyphIndex` cmap lookup — format-12 first, format-4 fallback).
- `metrics.zig`: new `FontMetrics.hasGlyph(fm, cp, style) bool`:
  - a wired font (`fm.font != null`) → `font_glyph` hook result != null —
    i.e. the FACE's cmap has the cp (the hook, `contextGlyph`, returns null
    for unmapped codepoints). If the font lacks the math-italic glyph the
    base cp is kept.
  - no font (bundled static tables) → `staticGlyph` != null. The tables
    cover the U+1D4xx Latin series (and U+210E) but NOT the U+1D6xx Greek
    series, so the static path keeps Greek upright — "fall back
    gracefully". The WIDTH/ink of mapped Greek glyphs is served by the font
    path only.

`layoutChar`/`layoutText`: `mathItalic(cp) orelse keep; if
metrics.hasGlyph(fm, mapped, style) { emit mapped } else { emit base }`,
gated on style == .italic (roman \text/\mathrm/\sin and bold stay upright
ASCII). The metrics fallback chain (glyphAt(mapped) → glyphAt(base) →
glyphEstimate) is unchanged; a mapped box keeps the `synthetic` flag.

Also added to `metrics.zig`: 30 real ink rows for the math-italic Greek
series (U+1D6FC..U+1D714 + U+1D716/1D717/1D719/1D71A/1D71B) measured with
fontTools BoundsPen on latinmodern-math.otf, so the frame bounds the newly
drawn slanted ink instead of the 0.750/0.250 design bound.

## Before/after advances (pt at 10pt = em × 10, LM Math hmtx)

| glyph | U+ | before (upright) | after (math-italic) | Δ |
|---|---|---|---|---|
| α | 03B1→1D6FC | 6.41 | 6.40 | −0.01 |
| β | 03B2→1D6FD | 5.58 | 5.66 | +0.08 |
| γ | 03B3→1D6FE | 5.86 | **5.18** | −0.68 |
| Γ | 0393 (kept) | 6.25 | 6.25 | 0.00 |
| x | 0078→1D465 | 5.28 | 5.72 | +0.44 (FixMathItalic) |
| ε | 03B5→1D700 | 5.35 | 4.66 | −0.69 |
| ϵ | 03F5→1D716 | 4.14 | 4.06 | −0.08 |
| θ | 03B8→1D703 | 4.88 | 4.69 | −0.19 |
| ϑ | 03D1→1D717 | 5.30 | 5.91 | +0.61 |
| ϕ | 03D5→1D719 | 6.41 | 5.96 | −0.45 |
| π | 03C0→1D70B | 5.86 | 5.70 | −0.16 |
| ϖ | 03D6→1D71B | 8.36 | 8.28 | −0.08 |
| ϱ | 03F1→1D71A | 4.88 | 5.17 | +0.29 |
| ς | 03C2→1D70D | 4.74 | 3.63 | −1.11 |

Measured ztex box widths (single-glyph renders, -s 10): 𝛼 6.40, 𝛽 5.66,
𝛾 5.18 — match the LM Math math-italic hmtx exactly.

## Render comparison (artifacts/)

- `frac-before-after-48.png`: \frac{\alpha+\beta}{\gamma} at 48pt, left =
  before (upright Greek), right = after (math-italic). Vision inspection:
  "right-side versions exhibit a consistent rightward slant" vs upright.
- `render-after-frac48.png`, `render-after-greeks48.png`: after-state PIL
  renders (real LM OTFs, scripts/critique.py rasterizer).
- `xetex-greek-reference.svg`: XeTeX+unicode-math probe (`\alpha+\beta`,
  `\Gamma(x)`, `\frac{\alpha+\beta}{\gamma}`) — reference codepoints
  1D6FC/1D6FD/1D6FE, Γ upright 0393.
- 10pt side-by-side `frac-before-after.png`.

## Verification (all run, all pass)

- `\frac{\alpha+\beta}{\gamma}` emits **𝛼 U+1D6FC / 𝛽 U+1D6FD / 𝛾 U+1D6FE**
  (SVG `<text>𝛼</text>` etc.), widths 6.40/5.66/5.18pt — the reference
  math-italic advances.
- `\Gamma(x)` emits **Γ U+0393** (upright, unchanged), then ( and 𝑥 U+1D465.
- `x` still emits U+1D465 (0.572em).
- Variants: \varepsilon→U+1D716, \vartheta→U+1D717, \varrho→U+1D71A,
  \varphi→U+1D719, \varpi→U+1D71B, \varsigma→U+1D70D — all present in the
  LM Math cmap (fontTools-verified).
- `\alpha^2` lays out 𝛼 with its superscript at the box edge.
- PIL render of \frac{\alpha+\beta}{\gamma} at 32pt: geometric verifier
  PASS, 0 defects, no clipping; vision: Greek letters slanted, all glyphs
  complete — the old "beta/gamma curvature"/"incomplete gamma" critique
  nits (vision artifacts on the old resvg render, refuted by the geometric
  verifier) do not recur.
- Full `zig build test`: 5/5 steps pass (added 1 in-file test: static path
  maps `x`→U+1D465 but keeps `\alpha` U+03B1, since the static tables lack
  U+1D6xx).
- Test impact: NONE beyond the added test — the regression goldens exercise
  the STATIC path, where Latin was already mapped (FixMathItalic) and Greek
  stays upright (no static U+1D6xx rows), so every golden stays
  byte-identical. Only FONT-path renders change (Greek now math-italic).

## Notes / observations

- unicode-math emits `\epsilon`→U+1D716 and `\varepsilon`→U+1D700
  (probe-verified) — the REVERSE of ztex's parser slot assignment
  (`\epsilon`→03B5, `\varepsilon`→03F5, same for \phi/\varphi). This is a
  pre-existing parser-level divergence (the parser follows the AMS/cmmi10
  convention); out of scope here — the variant mapping follows the
  UnicodeData compat slots exactly as specified.
- The math-italic Greek forms are distinct font records in LM Math (outline
  deltas verified with fontTools; e.g. italic α's first contour point sits
  ~0.32em higher), though their ink extents match the upright rows.
- The static (no-font) path keeps Greek upright by design; a future task
  could add U+1D6xx rows to the static tables to unify the no-font output
  with the font path.
