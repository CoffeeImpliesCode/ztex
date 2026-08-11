# Fix: delimiter-variant detection from the layout's intended height

`scripts/critique.py` — the PIL rasterizer and the geometric verifier resolve
the MATH size-variant a `\left..\right` delimiter must draw. After the layout
change (src/layout/layout.zig `layoutLeftRight`/`layoutDelimChar`), every
delimiter `<text>` is emitted at the BASE math size: the layout picks the
variant from the content extent and draws it at the base font size — the
intended size is NOT in the SVG. The old detection ("stretched iff
font-size > base math size") never fired, so the critique drew the small base
paren over a tall fraction and the geometric verifier measured the base ink.

## The heuristic (reconstructs the layout's TeX make_delim floor)

`_delimiter_targets(elements, w, h, font_dir, base_size)` recovers the
required delimiter ink from the SVG geometry:

1. **Pair delimiters.** Stack over x-sorted delimiter `<text>`s, matching each
   closer to the nearest unmatched opener of its type (`DELIM_PAIRS`) — TeX
   nesting.
2. **Enclosed content extent.** Union the ink boxes of the OTHER elements
   (text chars, fraction-bar rects, stroked lines) whose center x falls
   between the pair's delimiter ink boxes (`lo`, `hi`). Delimiter chars of a
   nested pair also count toward the enclosing pair. Background rects
   (full-canvas fill) are excluded; big-op display variants are resolved like
   the raster draws them.
3. **TeX make_delim floor** (tex.web §1114, identical to layout.zig
   `layoutLeftRight`): with the delimiter baseline `y`, axis `a = 0.25·size`
   (ztex `GlueParams.axis_height` 2.5/10pt),
   `δ = max(y − a − extent_top, extent_bottom − y + a)`,
   `minh = max(2·δ·901/1000, 2·δ − 0.1·size)` (shortfall 0.1em),
   `req_em = minh / size`.
4. A delimiter is **stretched** iff `req_em` exceeds its base glyph's ink
   (the ladder's entry 0). The map key is `(x, y, content)` so the rasterizer
   and the verifier resolve the SAME delimiters.

`_delimiter_resolution(path, cp, size_pt, req_em)` then picks the SMALLEST
MATH size variant whose ink covers `req_em` (the largest when none does) and
draws it **at the declared size** (`size_v = size_pt`) with the baseline
shifted so the variant ink center matches the base glyph's center — 0 for LM
Math, where every delimiter ink center sits on the MATH axis (0.25em). The
old `variant_fontsize = target / variant_ink` rescaling is gone: the layout
boxes the delimiter by the variant extents at the base size, so the critique
must draw the variant at that same size to match the reference ink (e.g. v6
ink 2.392em × 39.85pt ≈ base size — the XeTeX reference measurement).

## Test formulas (all at `-s 40`)

| formula | req_em | resolved variant (both delimiters) | verifier |
|---|---|---|---|
| `\left( \frac{a}{b} \right)` | 1.794 | parenleft/right.**v5** (2.092em) | 0 defects |
| `\frac{d}{dt} \left( \frac{\partial L}{\partial \dot{q}} \right) = \frac{\partial L}{\partial q}` | 2.185 | parenleft/right.**v6** (2.392em) | 0 defects |
| `f(a)` | 0.470 | base glyph (not stretched) | 0 defects |
| `\left[ x \right]` | 0.470 | base glyph (TeX: base bracket covers) | 0 defects |
| `\left\{ \frac{1}{2} \right\}` | 2.085 | braceleft/right.**v5** | 0 defects |
| `\left\langle \frac{a}{b} \right\rangle` | 1.794 | uni27E8/27E9.**v4** | 0 defects |
| `\lfloor \frac{1}{2} \rfloor` | 2.085 | uni230A/230B.**v5** | 0 defects |
| `\lceil \frac{1}{2} \rceil` | 2.085 | uni2308/2309.**v5** | 0 defects |
| `\left( \left[ \frac{a}{b} \right] + c \right)` | outer 1.794 / inner 1.794 | parens v5, brackets v4 | 0 defects |
| `f\left(\frac{1}{x}\right)` | 2.085 | parens v5 | 0 defects |
| `x_{\left( \frac{a}{b} \right)}` (script size 28pt) | 1.101 | parens v2 | 0 defects |
| `\left( \right)` (empty) | — | base glyphs | 0 defects |
| `x^2 + y^2`, `\sum_{i=1}^{n} x_i` (no delimiters) | — | — | 0 defects |

The variant picks reproduce the layout's own choices exactly (the metrics.zig
ladder is derived from the same font measurements): the EL floor 87.4pt →
v6, the `a/b` floor 71.8pt → v5 (v4 ink 1.792em just misses), `1/2` floor
83.4pt → v5, `⟨⟩` floor → v4 (⟨ has v4 ink 1.8em ≥ 1.794).

## Before / after renders

Measured ink extents on the actual critique PNGs (1pt = 4/3 px):

- `\left( \frac{a}{b} \right)` — after: paren ink 82.5pt covers the fraction
  ink 72pt (v5 at 40pt = 83.7pt). Before (base glyph at 40pt): 39.8pt — the
  parens were dwarfed by the fraction.
- Euler–Lagrange — after: paren ink 95.2pt covers the ∂L/∂q̇ fraction ink
  90.0pt (v6 at 40pt = 95.7pt). Before: 39.8pt base parens.
- `f(a)` — after: paren ink 39.0pt (base glyph), unchanged.
- Fraction centering between the parens: 0.04pt off the paren-gap center
  (was 20.6pt right of center before the layout fix) — the old nit is gone.

Artifacts: `notes/artifacts/critique-ref-7/` (EL, ours + XeTeX + KaTeX
panes), `notes/artifacts/critique-ref-8/` (`\left( \frac{a}{b} \right)`).

## Verifier consistency

- `_glyph_ink_boxes` takes the same `delim_targets` map, so the verifier
  measures the SAME variant ink (variant outline + hmtx advance at `size_v`,
  shifted baseline) the PIL raster draws.
- Intended wrap-around adjacency: a stretched delimiter legitimately wraps
  its content and the LM variant ink can graze it (measured sub-0.5pt
  slivers on `\lfloor \frac{1}{2} \rfloor` — ⌊ ink reaches x=24.3pt while the
  fraction starts at x=24.2pt — also present in the XeTeX reference). The
  verifier now excludes delimiter↔enclosed-content intersections (reason
  "delimiter wrapping its content"), same category as the existing
  radical-over-radicand and op-beside-script exclusions. `compute_geometry`
  threads the spans from `_delimiter_targets` to know each pair's enclosed
  elements.

## Files touched

- `scripts/critique.py`: constants (`DELIM_PAIRS`, `DELIM_MIN_COVER`,
  `DELIM_SHORTFALL_EM`, `AXIS_HEIGHT_EM`), shared `_parse_svg_primitives`,
  `_base_math_size`, `_delimiter_targets`, `_delimiter_resolution` rewrite,
  `_glyph_ink_boxes` (targets map), `rasterize_svg` + `_svg_geometry_elements`
  (shared parse + targets), `compute_geometry` (wrap exclusions).
- No Zig changes; no zig gates run.
