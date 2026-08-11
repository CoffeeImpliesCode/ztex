# Fix raster: TEXT/SCRIPT big-ops draw the CMAP base glyph

## Problem

The critique rasterizer (`scripts/critique.py`, the FixStrictRound3 `.v1`
machinery) resolved the MATH-table display variant (e.g. `integral.v1`,
`summation.v1`) for **every** big-op codepoint, regardless of the font-size
the layout declared. ztex emits a DISPLAY operator at the base math size
(30pt at `-s 30`) and a TEXT/SCRIPT one at a style-scaled size (17.7pt for
`\textstyle\int`), so the text ∫ was drawn with the tall `.v1` form at
17.7pt — a ~39pt-tall glyph that looked nearly display-size. Every other
engine (XeTeX/KaTeX/MathJax) draws the small base form for a text-style
operator, so the critic kept reporting "the second integral is the same
size as the display one" for LimitControls.

## Fix (EDIT ONLY scripts/critique.py)

New rule: a big-op is **DISPLAY** when its declared font-size equals the
pane's base math size (`_base_math_size` = the largest non-delimiter
font-size in the pane); **TEXT/SCRIPT** when smaller.

- `_display_bigop(size_pt, base_size)` — the discriminator. `base_size is
  None` (a pane with no non-delimiter text) keeps the legacy DISPLAY
  resolution: there is no smaller reference size to discriminate against.
- `rasterize_svg` (PIL draw): the `BIGOP_PUA` variant substitution is gated
  on `_display_bigop(size_pt, base_size)`. A TEXT/SCRIPT big-op falls
  through to the normal `_face_for` path → CMAP base glyph at the declared
  size.
- `_glyph_ink_boxes` (geometric verifier): same gate — the `.v1` glyph
  substitution (outline + hmtx advance) applies only to DISPLAY big-ops, so
  the verifier measures exactly the ink the raster draws.
- `_delimiter_targets` computes enclosed-content extents through
  `_glyph_ink_boxes`, so stretched delimiters around a text-style big-op
  now use the base glyph too — consistent with the raster.
- Display big-op `.v1` behavior is untouched (it matches the refs).

## Measurements (base 30pt, `-s 30`)

Formula: `\displaystyle\int\limits_2^3 3x^2\,dx + \sum\nolimits^n_{i=1}i +
\textstyle\int\limits_x^y z` (SVG `/tmp/rtx/verify.svg`, ink heights via the
verifier's OTF BoundsPen path, exact):

| glyph | size (pt) | form | ink height (pt) |
|---|---|---|---|
| ∫ display | 30.000 | integral.v1 | 66.66 |
| ∫ text | 17.744 | integral base | **19.71** (was 39.43 with the old v1-at-17.7 rule) |
| ∑ display | 30.000 | summation.v1 | 42.00 |
| ∑ ∏ ⋃ text | 23.684 / 24.537 | base (1.000 / 1.022 em) | = size (23.68 / 25.08) |

- Text ∫ ink 19.71pt = 1.111em × 17.744 — exactly the base form at the
  declared size (the task's expected "~19.7pt"). The old rule drew 39.43pt
  (2.222em × 17.744, i.e. the `.v1` at the text size), 2.0× too tall.
- Text/display ink ratio now 0.296 (base-form-at-17.7 vs `.v1`-at-30); the
  font-size ratio 17.744/30 = 0.591 is what the text ∫ ink is relative to
  the display op's *base* form (1.111em × 30 = 33.33pt).
- Display `.v1` unchanged: 66.66pt in both the verifier and the PIL raster
  (66.75pt on-pixel); a lone-op pane and a plain `\int_0^1 x\,dx +
  \sum_{i=1}^{n} \frac{x_i}{n}` pane measure identically to pre-fix.

### Reference engines (same formula, 30pt, from their own geometry/fonts)

| engine | display ∫ ink | text ∫ ink | text/display |
|---|---|---|---|
| XeTeX (LM Math) | 66.40 (integral.v1) | 33.22 (base) | 0.500 |
| KaTeX (Size2/Size1) | 66.66 | 33.33 | 0.500 |
| MathJax (TEX-LO/SO) | 53.04 (1.768em) | 33.33 (1.111em) | 0.628 |
| ztex (fixed) | 66.66 (v1 at 30) | 19.71 (base at 17.7) | 0.296 |

All engines draw the text-style ∫ as the **base** 1.111em form — the same
form ztex now draws (XeTeX's text ∫ glyph is `integral`, the identical LM
Math base glyph). ztex additionally renders it at the layout's declared
17.7pt (the layout's style-scaling design, unchanged — Zig side is out of
scope per the task). The old raster's `.v1`-at-17.7 made the text ∫ 2× too
tall and visually collided with the display form.

## Critique verdict (task item 4)

`python3 scripts/critique.py --ref -s 30 '\displaystyle\int\limits_2^3
3x^2\,dx + \sum\nolimits^n_{i=1}i + \textstyle\int\limits_x^y'` → report
`notes/critique-ref-21.md`, vision qwen/qwen-2.5-vl-72b-instruct:

**Verdict: FAIL (7 nits)** — all minor: ∫ stroke thinner, ∑ superscript 'n'
slightly high, 'i=1' more italic, gap after ∫ term slightly wide, '+' after
∑ slightly large, display ∫ limit '2'/'3' slightly off-center, baseline
alignment. **The "second integral same size as the display one" complaint
is RESOLVED** — no nit mentions the text-style ∫'s size; the critic sees it
as clearly smaller, matching the references.

## Pre-existing layout issue surfaced (out of scope, Zig side)

The verifier flags the text ∫'s above-limit 'y' as off-center (offset 9.4pt
vs the 3.2pt threshold). The layout places the 'y' limit at a fixed x
(285.14pt) that was tuned against the wider `.v1` box; with the correct
narrow base form the offset grows (5.4pt → 9.4pt). This is the known
"limit horizontal staggering" layout defect (FixTeXParity scope), not a
rasterizer defect: the verifier now measures the true ink and correctly
reports it. EDIT-ONLY constraint (critique.py + notes) forbids touching
`src/layout/layout.zig`.
