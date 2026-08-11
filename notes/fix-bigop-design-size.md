# fix-bigop-design-size.md — display big ops at design size, advance-width boxes

Goal: match the unicode-math/XeTeX reference. Display big ops draw at DESIGN
size (1.0×, glyph ≈9.96pt at 10pt) instead of the fudged 1.4×/2.0× scales,
and the op box WIDTH is the Latin-Modern-Math hmtx ADVANCE (not the ink
bbox). Ink asc/desc (box height/depth) and the (h−d)/2 − axis centering shift
are unchanged.

## Edits

- `src/layout/layout.zig` — `layoutOp`: `glyph_size = size_pt` in EVERY
  style (removed the `size_pt * dop.scale` display branch and the 1.4em
  fallback). Renamed `BigOpInk.w` → `BigOpInk.advance` (the values were
  already the hmtx advances; the name now says so). Dropped the now-unused
  `style` parameter from `layoutOp` and its call site. Updated stale
  comments (opTailIc, layoutScript base_h/base_d, layoutOp doc).
- `src/layout/metrics.zig` — removed the `scale` field and values from
  `DisplayOp` (dead after the design-size change); only `ic` remains live
  (display-limit skew + post-op italic tail). `w` kept as the LM advance
  reference value (cmex h/d kept as reference-only). Comment updated.

## Advance vs ink-bbox widths (fontTools on latinmodern-math.otf 1.959)

| op | cp | advance em | ink bbox em | ink asc | ink desc |
|----|----|-----------|-------------|---------|----------|
| ∑ | U+2211 | 1.056 | 0.943 | 0.750 | 0.250 |
| ∏ | U+220F | 0.944 | 0.831 | 0.750 | 0.250 |
| ∐ | U+2210 | 0.944 | 0.831 | 0.750 | 0.250 |
| ⋃ | U+22C3 | 0.833 | 0.734 | 0.750 | 0.272 |
| ⋂ | U+22C2 | 0.833 | 0.734 | 0.772 | 0.250 |
| ⨆ | U+2A06 | 0.833 | 0.734 | 0.764 | 0.264 |
| ∫ | U+222B | 0.665 | 0.553 | 0.805 | 0.306 |
| ∮ | U+222E | 0.665 | 0.553 | 0.805 | 0.306 |

Note: the shared-context "advances" list (prod 0.831, bigcup 0.734, …) is
the INK-BBOX width, not the hmtx advance; verified directly with fontTools
(and font.zig's own tests assert sum 1.056 / int 0.665). The advance is the
TeX rule (char box width = hmtx advance) and is what the drawn glyph
occupies horizontally.

## Before/after geometry (display style, 10pt)

| op | old glyph size | old box w | new glyph size | new box w | XeTeX ref box w |
|----|---------------|-----------|----------------|-----------|-----------------|
| ∑ | 14 (1.4×) | 14.784 | 10 (1.0×) | 10.56 | 10.56 |
| ∏ | 14 | 13.216 | 10 | 9.44 | 9.44 |
| ∐ | 14 | 13.216 | 10 | 9.44 | 9.44 |
| ⋃ | 14 | 11.662 | 10 | 8.33 | 8.33 |
| ⋂ | 14 | 11.662 | 10 | 8.33 | 8.33 |
| ⨆ | 14 | 11.662 | 10 | 8.33 | 8.33 |
| ∫ | 20 (2.0×) | 13.3 | 10 (1.0×) | 6.65 | 6.65 |
| ∮ | 20 | 13.3 | 10 | 6.65 | 6.65 |

Box height/depth (ink asc/desc × glyph size, unchanged): ∑/∏/∐ 7.50/2.50,
⋃ 7.50/2.72, ⋂ 7.72/2.50, ⨆ 7.64/2.64, ∫/∮ 8.05/3.06 at 10pt.

## Measured verification (ztex -s 10, SVG text coords, origin-relative)

`\int_0^1 x\,dx`:
- ∫ glyph font-size 10pt (was 20pt) — design size ✓
- sub '0' at 6.65pt past the ∫ origin (was 13.3pt) = advance 0.665em × 10
  ✓ (reference: 4.07pt past the ink = advance 6.65 − LSB 2.58)
- sup '1' at 9.97pt = 6.65 + LM italic correction 3.32 (was 19.94pt) ✓
- `x` follows the script box (width 13.97 = 6.65+3.32+sup w+scriptspace)
  + thin — the opTailIc is not double-counted for beside-scripted ops

`\sum x`:
- ∑ glyph 10pt (was 14pt); x at 10.56 (advance) + thin 1.67 ✓

`\sum_{i=1}^{n} x_i`:
- limits vbox width = max(∑ advance 10.56, under-limit "i=1" row 10.892) =
  10.892, ∑ centered on it; x_i starts at vbox + thin ✓ (TeX: limits box is
  max(op, limits))

`\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx` (full chain, exact):
- '+' at 28.407 = 3.5 + 10.892 (vbox) + 1.667 (op→ord thin) + 10.126 (frac
  incl. 2×1.2 nulldelimiterspace) + 2.222 (ord→bin med)
- '∫' at 38.409 = '+' + 7.78 + 2.222 (bin→op med) — no drift ✓
- 'x' at 54.046 = ∫ script box 13.97 + thin; d, x follow at \, + widths —
  no drift ✓

`x + \sum y`:
- ∑ at 21.004 (x 5.28 + med 2.222 + '+' 7.78 + med 2.222); y at ∑ advance
  10.56 + thin — the old 1.4× sum pushed y +3.4pt right; now aligned ✓

`\int x` (bare-op tail):
- x at 6.65 (advance) + 3.32 (ic kern) + thin ✓

## Notes

- The beside-script placement code (sub at bb.width, sup at bb.width+ic)
  and the axis-centering shift were NOT touched — with the box at the
  advance × design size they land at the XeTeX positions automatically.
- Goldens/tests intentionally NOT regenerated (INTENTIONAL output change;
  parent regenerates). `zig build` compiles clean.
