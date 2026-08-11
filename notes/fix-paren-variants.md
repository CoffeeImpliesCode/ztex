# Fix: stretched delimiters via MATH size variants (constant stroke)

## Problem

ztex stretches `\left(...\right)` delimiters by scaling the BASE paren glyph
to a large font-size (e.g. 82.95 pt over `\frac{a}{b}` at -s 40, 101.30 pt
over `\frac{\partial L}{\partial \dot{q}}`). Scaling the base glyph scales its
stroke ~linearly with the font-size, so a tall paren is visibly THICKER than
a normal-size paren. XeTeX and KaTeX instead draw the OpenType MATH-table
SIZE VARIANTS (`parenleft.v1` .. `parenleft.v7`, etc.), which are designed
with a constant stroke at any size. The vision critic flagged this as a
"paren curvature and thickness" nit.

Measured stroke (PNG raster at 4/3 px/pt, widest horizontal black run of the
left paren over its ink rows):

| render | stroke max | stroke median |
|---|---|---|
| ztex BEFORE (scaled base @101.3pt) | 8 px | 6 px |
| ztex AFTER (parenleft.v7 @33.7pt) | 5 px | 4 px |
| XeTeX ref | 5 px | 3 px |
| KaTeX ref | 6 px | 5 px |
| normal-size ztex paren (40pt) | 4 px | 3 px |

The scaled paren was ~2x the normal stroke; the variant now sits in the
XeTeX/KaTeX band (3-5 px) with the SAME ink span as the scaled base.

## Fix (scripts/critique.py, PIL rasterizer only — ztex layout untouched)

### Detection

The base math size of an SVG = the largest font-size among glyphs that are
never stretched (everything except the 12 delimiter codepoints: letters,
digits, big ops, the radical). A delimiter `<text>` is STRETCHED iff its
declared font-size > base size. A delimiter at the base size (plain `f(x)`,
`\left\lfloor x \right\rfloor` when content fits) is drawn as the base glyph,
unchanged.

### Resolution (`_delimiter_resolution`)

For a stretched delimiter with declared font-size `S`:

1. `target = S * h_base_em` — the content height the scaled base glyph
   covers (its ink height; the layout centers delimiters on the axis and
   picks `S` so the base glyph covers the content).
2. `req_em = target / base_size` — required ink height in base-size em.
3. From `MathVariants.VertGlyphConstruction`, pick the SMALLEST variant with
   ink height >= `req_em` (largest variant when none covers). Ink heights are
   measured with fontTools `BoundsPen` on the real OTF outlines.
4. `variant_fontsize = target / h_variant_em` — draw the variant at the size
   where its ink EXACTLY spans the target height (not at the declared `S`,
   which would thicken it again).
5. Baseline shift = `c_variant_em * variant_fontsize - c_base_em * S` so the
   variant's ink center matches the scaled base's center (axis-centered).
   For LM Math every paren/bracket variant has its ink center 0.25 em above
   the baseline, so the shift is `0.25 * (variant_fontsize - S)` (negative:
   baseline moves up).

Rendering uses the same mechanism as the big-op `.v1` glyphs: the font is
patched in memory (fontTools) mapping private-use chars to the variant glyph
names, FreeType rasterizes the ACTUAL variant at its own font-size and
baseline. The geometric verifier (`_glyph_ink_boxes`) resolves the SAME
variant at the SAME size/shift, so geometry stays consistent with the raster.

Delimiter codepoints covered: `( ) [ ] { }` plus (present in ztex) the TeX
delimiters `\langle \rangle \lfloor \rfloor \lceil \rceil` (U+27E8/27E9,
U+230A/230B, U+2308/2309). All 12 have 7 single-piece variants in LM Math
(no extension parts). Big-op display-variant behavior is untouched (geometry
byte-identical on the `\sum_{i=1}^{n} x_i` corpus).

### Worked numbers

`\left( \frac{a}{b} \right)` at -s 40: `S` = 82.95 pt, base = 40 pt,
`h_base` = 0.996 em -> target = 82.62 pt; `req_em` = 2.065 ->
`parenleft.v5` (2.092 em) -> variant_fontsize = 82.62/2.092 = 39.5 pt
(≈ base size), shift = -10.9 pt.

d/dt formula: `S` = 101.30 pt, target = 100.90 pt; `req_em` = 2.52 ->
`parenleft.v7` (2.99 em) -> variant_fontsize = 33.7 pt, shift = -16.9 pt.

## Verification

- `\left( \frac{a}{b} \right)` at -s 40: paren stroke 6 -> 4 px (base parens
  3-4 px), ink span identical (y[9,118] px before and after), geometric
  verifier PASS (0 defects).
- Corpus sweep (big-ops, \langle, \lceil, \left\{, sqrt + parens, the d/dt
  formula): all PASS (0 defects).
- Big-op `.v1` geometry before/after: byte-identical.

## Critique nit delta (`--ref`, -s 40, same formula both runs)

`\frac{d}{dt} \left( \frac{\partial L}{\partial \dot{q}} \right) = \frac{\partial L}{\partial q}`

BEFORE (scaled base parens): 6 nits, including
[minor] "the parentheses around \frac{\partial L}{\partial \dot{q}} ... have
a slightly different curvature and thickness compared to the references" —
the thickness nit this fix targets.

AFTER (variant parens): 6 nits; the curvature-and-thickness nit is GONE. The
only remaining paren-related nit is a spacing nit ("parentheses slightly more
spaced out from the content"), which is a layout matter, not stroke thickness.
Other nits (fraction bar, ∂ shape, dot height) are unchanged / noise.

## Files

- `scripts/critique.py` — the only source file changed (constants +
  `_delimiter_variants`, `_glyph_ink_em`, `_delimiter_resolution`,
  `_delim_pua`; `_variant_font` patch; `rasterize_svg` two-pass draw;
  `_glyph_ink_boxes` + `_svg_geometry_elements` base-size plumbing).
- `notes/fix-paren-variants.md` — this note.
