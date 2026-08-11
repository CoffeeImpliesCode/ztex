# Fix: big-op box WIDTH from the drawn LM-Math ink — `layout.zig`

Date: 2026-08-13. Scope: `src/layout/layout.zig` (bigOpInk table + layoutOp),
`src/layout/metrics.zig` (DisplayOp doc comment only). Follow-up to
`fix-pipeline-ink.md` (FixInk), which corrected the big-op box HEIGHT/DEPTH
from the drawn ink but left the WIDTH at cmex10. INTENTIONAL output change —
goldens regenerate; tests/goldens untouched. SKIP gates (no build/test/fmt).

## Root cause

`layoutOp` boxed every big op with the cmex10 design WIDTH (display:
∑ 14.44448, ∫ 5.55557, unscaled design values; text/script: the cmsy10 text
widths ∑ 10.55559, ∫ 4.72223) while DRAWING the Latin-Modern-Math glyph at
`glyph_size` (display: size_pt × scale; text/script: size_pt). The drawn
LMMath ink is ~1.8× wider than the cmex10 box (∑ ink 0.943em × gs, ∫ ink
0.553em × gs), so every downstream consumer that reads `bb.width` — limits
centering (`layoutOpLimits` vbox_w), the inter-atom advance (`layoutRow`
`x += cb.width`), the beside-script x (`layoutScript` `bb.width + ic`), and
the viewBox (`dl.width/height/depth` ← root box) — was sized for a glyph
~1.8× smaller than the ink actually drawn.

## Measured ink widths

CFF outline bounds via fontTools `BoundsPen` on `latinmodern-math.otf`
2.005, per-mille → em of the glyph font-size. Same font + method FixInk
used; the asc/desc reproduce the existing bigOpInk table exactly.

| op | cp | ink w (em) | ink asc (em) | ink desc (em) |
|---|---|---|---|---|
| ∑ | U+2211 | **0.943** | 0.750 | 0.250 |
| ∏ | U+220F | **0.831** | 0.750 | 0.250 |
| ∐ | U+2210 | **0.831** | 0.750 | 0.250 |
| ⋃ | U+22C3 | **0.734** | 0.750 | 0.272 |
| ⋂ | U+22C2 | **0.734** | 0.772 | 0.250 |
| ⨆ | U+2A06 | **0.734** | 0.764 | 0.264 |
| ∫ | U+222B | **0.553** | 0.805 | 0.306 |
| ∮ | U+222E | **0.553** | 0.805 | 0.306 |

## The change

`BigOpInk` gains a `w` field; `bigOpInk(op)` returns the em width above.
`layoutOp` drops its glyph/cmex10 width lookups and boxes the op by the
drawn ink in every style:

- display: `glyph_size = size_pt × dop.scale`; box width `= 0.943em × gs` (∑)
  etc. (was `dop.w`, cmex10).
- text/script/scriptscript: `glyph_size = size_pt`; box width `= ink.w ×
  size_pt` (was the cmsy10 text width).
- height/depth unchanged (`ink.asc/desc × glyph_size`, FixInk).
- `layoutOp` no longer needs the FontMetrics lookup path, so the `fm`
  parameter is removed from its signature (single call site updated).

Because every placement site already reads the box (not the codepoint), no
other formula changed — limits centering, beside-script x, the row advance
and the viewBox all pick up the real ink width automatically.

## Before/after box width per op (pt)

Display (gs = size_pt × scale; shown at size_pt 10 → gs 14/20, and at
size_pt 20 → gs 28/40 for the repro):

| op | before (cmex10 display) | after @10pt (gs 14/20) | after @-s 20 (gs 28/40) |
|---|---|---|---|
| ∑ | 14.44448 | 0.943 × 14 = 13.202 | 0.943 × 28 = **26.404** |
| ∏ | 12.77782 | 0.831 × 14 = 11.634 | 0.831 × 28 = 23.268 |
| ∐ | 12.77782 | 0.831 × 14 = 11.634 | 0.831 × 28 = 23.268 |
| ⋂ | 11.11115 | 0.734 × 14 = 10.276 | 0.734 × 28 = 20.552 |
| ⋃ | 11.11115 | 0.734 × 14 = 10.276 | 0.734 × 28 = 20.552 |
| ⨆ | 11.11115 | 0.734 × 14 = 10.276 | 0.734 × 28 = 20.552 |
| ∫ | 5.55557 | 0.553 × 20 = 11.060 | 0.553 × 40 = **22.120** |
| ∮ | 5.55557 | 0.553 × 20 = 11.060 | 0.553 × 40 = 22.120 |

Text/script (gs = size_pt): before ∑ 10.55559 / ∏∐ 9.44448 / ⋂⋃⨆ 8.33336 /
∫∮ 4.72223 (cmsy10 text widths) → after = ink em × size_pt (∑ 9.430,
∫ 5.530 at 10pt). At 10pt the relative geometry is preserved (ink scales
proportionally); only the absolute ink-derived width changes, per the fix.

## Which of the 5 defects each change fixes

Repro at `-s 20`: `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`.
Display ∑ gs 28 → box w 26.404; display ∫ gs 40 → box w 22.120; axis
s(2.5,20) = 5.

1. **∑ sup `n` not centered over the ink** — `layoutOpLimits` vbox_w =
   max(bb.width, sup_w, sub_w) = 26.404; sup x_shift = (26.404 − 4.2)/2 =
   11.10, so `n`'s center (13.2) = the ink's center (13.2). Before: box
   14.444 put `n`'s center at 7.2, ~6pt LEFT of the ink center.
   → fixed by the box-width change in layoutOp (vbox_w now the real ink).
2. **∑ term overlaps the ∑ ink** — `layoutRow` advances by cb.width
   (26.404) + thin glue (3.333); the fraction starts at 29.74, 3.33pt past
   the ink edge. Before: 17.78, i.e. 8.6pt INTO the ink.
   → fixed by the box-width change (inter-atom advance = ink width).
3. **SVG frame too small** — viewBox w/h come from the root row box
   (svg.zig: `dl.width`, `dl.height + dl.depth`), which sums the op box
   widths/heights; with the ink box nothing pokes out left/right/top/bottom.
   → fixed by the box-width change (frame width now includes the real ink;
   height/depth were already ink-based from FixInk).
4. **∫ sup `1` too far left (on top of the ink)** — beside-script x =
   bb.width + sup_gap = 22.120 + 4.44446 (dop.ic) = 26.56, 4.44pt past the
   ∫ ink edge. Before: 5.55557 + 4.44446 = 10.00, 12pt INSIDE the ink.
   → fixed by the box-width change (layoutScript x_shift reads bb.width).
5. **Subscripts cut off** — the ∫ sub `0` sits at bb.width (22.12, past the
   ink) and the ∫ side-script box spans 22.12 + sub_w + scriptspace; the ∑
   sub `i=1` centers under the 26.404 box at (26.404 − 11.36)/2 = 7.52 and
   the limits vbox depth = op_bottom(9) + k + sub_h + sub_d + bigop5 keeps
   the whole sub inside the viewBox. Before, both subs sat under/at the
   left edge of the ~2.8× wider ink and the box/viewBox right edge clipped.
   → fixed by the box-width change (subscript x placement and frame
   depth/width derive from the ink box).

## Unchanged (out of scope)

- `metrics.displayOp` `.ic` (italic correction) and `.scale` still drive the
  side-script gap and the drawn size; the cmex10 `.w/.h/.d` in that table
  are retained as documented reference values only (its doc comment now
  says so).
- Bigop spacing/limits gap params (bigop1–5) and glue: spacing facts,
  independent of the drawn glyph.
- Tests/goldens: not touched; goldens regenerate under the pipeline.
