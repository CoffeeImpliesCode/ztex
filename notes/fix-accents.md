# fix-accents — minimal accent support (\dot \hat \bar \vec \ddot \tilde)

Files: `src/parse/parser.zig`, `src/layout/layout.zig`, `src/layout/metrics.zig`.

## Accent codepoints

Each accent command parses to an "accent row" (a `.row` node with `data =
accent_row_data` = 2, the same sentinel pattern as `sqrt_row_data` = 1),
children `[base, mark]`: the base atom (single atom or braced group, parsed
via `parseScriptArg`) plus a `.char` leaf carrying the combining-mark
codepoint in its `data` (like `\cdot`), so layout resolves the glyph and
flatten marks the box synthetic (the mark's utf-8 does not match the source
span `\dot`).

| command | codepoint | mark |
|---|---|---|
| `\dot`  | U+0307 | combining dot above |
| `\hat`  | U+0302 | combining circumflex |
| `\bar`  | U+0304 | combining macron |
| `\vec`  | U+20D7 | combining right arrow above |
| `\ddot` | U+0308 | combining diaeresis |
| `\tilde`| U+0303 | combining tilde |

Scripts after an accent (`\dot q^2`) attach to the whole accent row via the
normal `parseAtom` path — TeX's mathaccent behavior.

## Placement rule (`layoutAccent`)

Measured on latinmodern-math.otf 2.005 (fontTools BoundsPen + hmtx) and a
XeTeX reference render (`\dot{q}\hat{x}\bar{x}\vec{v}\ddot{x}\tilde{n}`,
xelatex + unicode-math, 10pt, mutool per-glyph extraction):

1. The mark is drawn AT THE BASE SIZE on the SAME baseline as the base
   (XeTeX: every glyph, marks included, sits on y = 7.427). LM Math draws
   every combining mark's ink 0.554–0.746em ABOVE its own baseline and
   0.106–0.416em tall; on the base baseline the mark's ink bottom (0.521em)
   lands ~x_height/4 (0.108em) above an x-height base's ink top (0.442em) —
   the font's own accent design. No vertical shift is needed.
2. The mark's ink is centered at −0.264em from the glyph origin (all six
   marks; the marks are designed to combine with a PRECEDING glyph), so the
   origin is placed at `base_width/2 + 0.264 × size` — the ink centers on
   the base box (XeTeX centers the same way via the MATH accent
   attachment).
3. The mark box has width 0 (zero hmtx advance in LM Math — accents never
   widen the base, TeX's zero-width accents) and height/depth from
   `metrics.glyphInk` (added ink rows: asc 0.734/0.746/0.640/0.677/0.672/
   0.711, desc 0). The result box keeps the base's width and depth; its
   HEIGHT grows to `max(base_height, mark_ink_top)` so the frame/viewBox
   bounds the mark ink (TeX: an accent noad's height is max(base, accent)).
   Verified: `clipping = 0` on the geometric verifier for every accent
   formula.

The SVG emits the mark as a separate `<text>` (math font family, so the PIL
rasterizer/verifier — and a browser — pick the Latin Modern Math face,
which carries the combining marks; the roman text face does not). The PIL
critique raster and the geometric verifier draw the mark from the real LM
Math outlines at the positioned baseline, so it lands exactly where the box
says. A BROWSER may compose the standalone combining char differently
(small mark at its baseline) — acceptable per spec; the positioned box is
the correct geometry.

### Deviation from the spec's literal numbers (measured)

The spec said "a small char box at ~0.5x the base size" with "the accent
baseline just above the base's ink top, ~x_height/4 clearance". That model
assumes the mark's ink starts AT its baseline. The real LM Math ink sits
0.521–0.609em ABOVE the baseline, so the literal combination (0.5× size +
raised baseline) produces a 0.53pt dot floating 3.94pt above the base —
subpixel at 96 dpi (PIL raster: max ink pixel 188/255, i.e. effectively
invisible; the acceptance "shows a dot above the q" fails) and ~3.7pt of
ink poking past the 0.08×max_size frame margin. Full size on the base
baseline instead matches the XeTeX reference pixel-for-pixel (dot ink
0.571–0.677em above the baseline; crisp 55–102/255 pixels at 96 dpi) and
produces exactly the intended x_height/4 gap (0.571 − 0.442 = 0.129em),
with the mark ink top bounding the box (no clipping). Known limitation:
accents over TALL bases (fractions, big operators) are not raised to clear
the base ink (TeX raises via AccentBaseHeight); out of scope for this
minimal pass.

## Before / after — `\dot{q}`

Before: `\dot` was not in `cmd_map` → parse error `UnknownCommand` (the
documented parser gap; the whole Euler-Lagrange formula failed to parse).

After: parses and renders — artifacts under
`notes/artifacts/fix-accents/`:

- `dotq-after.png` — `\dot{q}` at 20pt (PIL raster of the ztex SVG).
- `six-accents-ztex.png` — `\dot{q}\quad\hat{x}\quad\bar{x}\quad\vec{v}
  \quad\ddot{x}\quad\tilde{n}` at 20pt.
- XeTeX reference for the same six at 20pt:
  `/tmp/accent-ref/xe20/ref.png`.

Verification: `\frac{d}{dt} \left( \frac{\partial L}{\partial \dot{q}}
\right) = \frac{\partial L}{\partial q}` parses and renders at 10pt and
48pt; `\dot{q} \hat{x} \bar{x} \vec{v} \ddot{x} \tilde{n}` all render with
their mark visible above the base; geometric verifier reports zero defects
(clipping, overlaps, empty glyphs) on all renders; `zig build test` passes
unchanged.
