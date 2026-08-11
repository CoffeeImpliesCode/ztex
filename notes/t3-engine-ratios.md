# Paren ink-height / mod-letter x-height — 4 engines at 30 pt

Formula cell under test: `c \pmod{4}` (row 2, text style, of the 4-row array).
Paren ink = vertical extent of the `(` (or `)`) glyph. Mod-letter height = the
`x`-height, taken from the lowercase `o` of `mod` (a real mod letter, pure
x-height, no ascender/descender) — same choice for every engine.

Artifacts: `/tmp/verdict_Mod/artifacts/critique-ref-1/` — `render.png` (ours,
749×413 @192 dpi), `ref.png` (XeTeX), `katex.png` (KaTeX), `mathjax.png`
(MathJax). Panes in `combined.png` are scaled to a common width; since the ratio
is intra-pane (scale-invariant), the individual panes give the same number. All
four panes were rendered at `1pt = 192/72 = 8/3 px`.

Findings were reproduced independently three ways: (A) fontTools `BoundsPen` on
the real OTF outlines, (B) direct pixel measurement of the PNGs via connected
components (PIL, 192 dpi), and (C) driving the critiquer's own
`_delimiter_targets`/`_delimiter_resolution` (scripts/critique.py).

## Method (A) — font metrics

The `(` glyph ink height and the mod `o` x-height, read from the font files at
30 pt. For ztex and XeTeX the task specifies *parenleft base* from
`latinmodern-math.otf` and x-height from `lmroman10-regular.otf` (both present
in the texlive store). KaTeX uses `KaTeX_Main-Regular.ttf`; MathJax's paren and
`o` are both TEX-N (Computer Modern), read from the MathJax SVG paths
(`data-c=28` paren, `data-c=6F` `o`).

| engine | font | `(` ink (em) | `(` ink @30 pt | mod `o` ink (em) | `o` @30 pt | ratio (A) |
|--------|------|------|------|------|------|------|
| ztex | LM-Math `(` / LM-Roman `o` | 0.9960 | 29.88 pt | 0.4590 | 13.77 pt | **2.170** |
| XeTeX | LM-Math `(` / LM-Roman `o` | 0.9960 | 29.77 pt (0.996×29.888) | 0.4590 | 13.72 pt | **2.170** |
| KaTeX | KaTeX_Main | 1.0000 | 30.00 pt | 0.4580 | 13.74 pt | **2.183** |
| MathJax | TEX-N | 1.0000 | 30.00 pt | 0.4580 | 13.74 pt | **2.183** |

Note: ztex and XeTeX share the same fonts and scale out of the ratio, so (A)
gives ztex == XeTeX (2.170). This is exactly the "29.88 pt ours vs 29.77 pt
XeTeX" number the prior check found — i.e. it measures the **base glyph in the
SVG/font**, which is identical across engines. It cannot see the defect.

## Method (B) — raster

Same ratio measured from the actual PNG pixels (paren = tallest narrow ink
component in the `c \pmod{4}` row; `o` = the mod-letter x-height component,
taken from the font metric since the critiquer draws the `o` as a base
`<text>o</text>` at 30 pt — confirmed un-stretched: `o` is not a delimiter).

| engine | `(` ink (pt) | `(` ink (px) | mod `o` (pt) | ratio (B) |
|--------|------|------|------|------|
| ztex | **89.70** | **239** | 13.77 | **6.51** |
| XeTeX | 29.25 | 78 | 13.72 | 2.13 |
| KaTeX | 29.62 | 79 | 13.74 | 2.18 |
| MathJax | 29.62 | 79 | 13.74 | 2.18 |

The ztex `(` is 89.7 pt — the MATH size variant `parenleft.v7` (ink 2.990 em)
drawn at the base 30 pt. The references stay at the base paren (~29.6 pt).

## Verdict

**Yes — ztex stands out, decisively, but only in (B) the raster.** Its paren
ink-height / mod-letter height is **6.51**, vs **2.13–2.18** for all three
references — zex's ratio is **~2.98× (≈3×) the largest reference** and the only
one above ~2.2. The (A) font-metric view reads 2.170 (matches XeTeX) because it
measures the base `<text>(</text>` glyph sitting in the SVG, which is why the
prior "29.88 vs 29.77 = they match" check missed the complaint entirely.

`89.7 pt / 36 pt ≈ 2.5` row-heights → the user-perceived "3-lines-tall, giant,
thick" paren. The paren is also the thickest glyph on the page (a ~3×-taller
paren drawn at full em keeps proportionally heavy strokes), matching "thick".

## Mechanism (why zex alone balloons)

1. **ztex emits the correct SVG.** The current binary emits every `\pmod`/`\pod`
   paren as a base glyph:
   `<text x="29.47pt" … font-size="30pt" font-family="…Latin Modern Math…">(</text>`
   (ink 0.996 em = 29.88 pt). A standalone `c \pmod{4}` rasterizes correctly:
   `critique._delimiter_targets` reports `req = 0.800 em ≤ base ink 0.996 em`, so
   the paren is drawn at base (29.6 pt) — identical to XeTeX. So zex's *layout*
   is fine.

2. **The critiquer's rasterizer overrides it in the array.** `scripts/critique.py`
   does not trust the SVG's 30 pt; `rasterize_svg` reconstructs the delimiter
   size from geometry via `_delimiter_targets` (lines 812–985) +
   `_delimiter_resolution` (988–1055), and draws the resolved MATH variant in
   `_variant_font` (1062–1097). For the 4-row array the reconstruction is wrong:

   - **Cross-row delimiter pairing.** Delimiters are paired by x-position nesting
     (`stack`/`pairs`, lines 900–908) ignoring the row/baseline. The four rows
     place the `(` and `)` of `\pmod{4}` / `\pod{3}` at the *same* x in rows
     2&4 and 1&3, so openers cross-pair with closers from a *different row*
     (row-2 `(` ↔ row-4 `)`, etc.). Each "pair" therefore spans two rows.

   - **1-D (x-only) content filter.** `inside = [b for b in others if
     lo < (b[0]+b[2])/2 < hi]` (line 918) tests only the x-center, not y. The
     `mod`/`bmod` letters sit at the same x in *every* row, so the "enclosed
     content" of a pmod paren becomes the letters of **all four rows** — the
     full array height (~125 pt) — not just `mod 4`.

   - **make_delim floor blows up.** `delta = max(baseline−axis−top,
     bottom−baseline+axis)` ≈ array/2, then
     `minh = max(2·delta·0.901, 2·delta − 0.1em)` (lines 922–925, TeX
     `make_delim`). Result `req = 5.22–7.99 em` per paren — measured directly:

     ```
     '(' x=34.47 y=63.60  req=5.222em  -> parenleft.v7 @30pt => 89.70pt
     ')' x=123.40 y=63.60 req=7.988em  -> parenright.v7 @30pt => 89.70pt
     '(' x=203.50 y=27.60 req=7.622em  -> parenleft.v7  => 89.70pt   (\pod)
     ... (8 targets, all v7)
     ```

   - **Pick the tallest variant.** `req` (5–8 em) exceeds even the tallest
     MATH variant, `parenleft.v7` (2.990 em), so `_delimiter_resolution`
     (line 1042–1043) falls back to `max(variants)` and draws **v7 at the base
     30 pt** → ink `2.990 × 30 = 89.7 pt` (239 px). `(` / `)` advance 0.875 em
     = 70 px, matching the measured component width (71 px); two stacked parens
     (rows 2&4, same x) merge in the CC to the observed 382 px = 2×239. The
     reproduction `rasterize_svg(render.svg)` is pixel-identical to the on-disk
     `render.png` (same 364/382 px components).

3. **The references don't pass through this code.** XeTeX's paren is rasterized
   by `mutool` straight from the XeTeX PDF (faithful base glyph, 29.25 pt); the
   web refs use resvg/KaTeX/MathJax which also draw the amsmath *fixed*
   `\pmod`/`\pod` parens at base size. So every reference keeps ~30 pt; only
   zex's critiquer inflates them to 89.7 pt.

## Concrete bug sites (scripts/critique.py, read-only here)

- `_delimiter_targets` line 918: `inside = [b for b in others if lo < (b[0]+b[2])/2 < hi]` —
  add a y guard so a pair only counts content on its own row (the pmod pair at
  y≈63.6 pt should not see `bmod`/`mod` at y=27.6 / 99.6 / 135.6 pt).
- lines 900–908: pair openers↔closers by nesting only on x; also key on baseline
  so a row-2 `(` pairs with the row-2 `)` (same y), preventing cross-row pairing.
- (Downstream) even with a correct filter, `\pmod`/`\pod` are *fixed* parens
  (amsmath), so their content `mod 4` (0.70 em) < base ink (0.996 em) ⇒ no
  variant should be selected at all — `req 0.80 em` is the correct single-row
  result.

## Numbers at a glance

| engine | (A) font Metric ratio | (B) raster ratio | paren in PNG |
|--------|----------------------|------------------|--------------|
| **ztex** | 2.170 | **6.51** | **89.7 pt (parenleft.v7)** |
| XeTeX | 2.170 | 2.13 | 29.3 pt (base) |
| KaTeX | 2.183 | 2.18 | 29.6 pt (base) |
| MathJax | 2.183 | 2.18 | 29.6 pt (base) |

ztex is **largest only in (B)**: 6.51 vs ≤2.18 — ~3× the references, driven by
the critiquer stretching the array's `(` / `)` to `parenleft/right.v7`
(89.7 pt ≈ 2.5–3 row-heights). The "29.88 vs 29.77 match" was an (A)-level
(base-glyph) measurement and is blind to this raster-time stretch.
