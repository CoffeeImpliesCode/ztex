# Fix: unpaired stretched delimiters draw the MATH .v1 variant (not the scaled base glyph)

EDIT ONLY: `scripts/critique.py`. Python, no Zig gates. Fixes the critique
rasterizer's "bold brace" defect: an UNPAIRED stretched delimiter
(`\left\{ ... \right.`, `\bigl(` etc.) was drawn as the declared glyph at
the declared (scaled) font-size — scaling thickens the stroke ~linearly —
instead of the constant-stroke MATH size variant XeTeX/KaTeX draw.

## The three stretched-delimiter forms the SVG can carry

The ztex layout (`src/layout/layout.zig`) emits delimiter `<text>`s with no
variant information; the rasterizer reconstructs the drawn glyph. Three
forms:

| form | SVG signal | intended draw | rule |
|---|---|---|---|
| `\left( x \right)` PAIRED | both delimiters at the BASE size | MATH variant from the enclosed content (TeX make_delim 2δ), at base size | `_delimiter_targets` pairing + `mode "pair"` (unchanged) |
| `\left\{ ... \right.` UNPAIRED (null partner) | the lone delimiter at a SCALED size (`layoutDelimScaled` emits the base glyph at the font-size whose axis-centered ink covers the content exactly — 57.066pt for the tower at -s 30) | MATH variant whose ink covers that target, drawn at target/variant_ink (constant stroke) | NEW `mode "scaled"` |
| `\big( \frac{a}{b} \big)` FIXED LEVEL | both delimiters at the BASE size, box = the FIXED ladder entry (`layoutDelimLevel`; the level lives only in the parse, not the SVG) | the fixed ladder variant at base size | NEW `mode "level"` via box-advance recovery |

Before the fix, the unpaired form was drawn as the base glyph at 57.066pt
(the bold brace — the layout's scaled size was not honored as a variant
request), and the `\big` form took the content-driven req (wrong: for
`\big( \frac{a}{b} \big)` it resolved parenleft.v4 = 1.792em ink; XeTeX
draws the fixed parenleft.v1 = 1.094em).

## Detection and resolution (scripts/critique.py)

### Unpaired scaled fences (`mode "scaled"`)

In `_delimiter_targets`, after the open/close pairing pass, every delimiter
text that (a) was NOT matched to a partner and (b) declares a font-size
greater than the base math size is an unpaired stretched fence. Its target
is its OWN base-glyph ink at the declared size (the layout already sized
it: `layoutDelimScaled` uses `gs = max(size, need/(asc+desc))`). The
resolution:

- target_pt = base glyph ink height at the declared size;
- req_em = target_pt / base_size (the required ink in em of the BASE size);
- pick the SMALLEST MATH variant with ink ≥ req_em (the largest when none
  does — covers any target);
- draw it at variant_fontsize = target_pt / variant_ink_em (the "own" size,
  so the stroke stays constant and the ink covers the target exactly);
- axis-center: baseline shift = c_v·size_v − c_b·size_pt (0 for LM Math's
  parens/braces, whose variant ink centers all sit at 0.25em).

The tower `{` (font-size 57.066pt, base 30pt): target = 57.066pt →
req 1.902em → braceleft.v5 (ink 2.1em) at 27.17pt — ink 57.07pt, covering
the tower exactly, stroke = the base-size stroke (measured below).

### \big family fixed levels (`mode "level"`)

`\big/\Big/\bigg/\Bigg` box the FIXED ladder entry (v1/v4/v6/v7) at the
base size; the level is not in the SVG. Recovered from the box advance:
the layout places the first enclosed atom flush at the delimiter's box
edge (no inter-atom glue), so

    gap = (first enclosed text x) − (open delimiter x)

equals the fixed level's hmtx advance × size. The raster:

1. resolves the content-driven req as usual (`mode "pair"`);
2. if that resolution's own variant advance agrees with the measured gap
   (within DELIM_CONSISTENT_TOL_EM = 0.05em), the pair is a `\left..\right`
   pair — keep it (a content-driven `\left( \frac{a}{b} \right)` box
   matches its variant; verified: gap 21.09pt = parenleft.v5 adv 19.89 +
   the fraction's internal 1.2pt offset, within tolerance);
3. otherwise it is a fixed-level pair: match the gap against the ladder
   advances (DELIM_GAP_TOL_EM = 0.02em) and draw the matched level's
   variant at the base size.

Results measured at -s 30 (`\big( x \big)` etc.): gap 12.66 → v1,
17.91 → v4, 22.08 → v6, 26.25 → v7 — the exact ladder levels. The
fraction case `\big( \frac{a}{b} \big)`: gap 13.86pt = v1 adv 12.66 + the
fraction's internal offset 1.2pt, which lands closer to v2 (13.74pt) —
the raster draws parenleft.v2 (1.194em ink). This is one ladder rung above
XeTeX's v1 but a constant-stroke variant (previously the content-driven
v4 = 1.792em, 18pt too tall). The residual ambiguity is inherent: the
fixed level is not in the SVG, and the fraction's internal offset (0.04em)
overlaps the v1→v2 advance spacing (0.036em).

Note: the parser rejects `\bigl`/`\bigr` (UnknownCommand), so the
`\bigl( \frac{a}{b} \bigr)` acceptance formula is exercised as
`\big( \frac{a}{b} \big)` (the supported side-less form, same layout path
`layoutDelimLevel`).

## Geometric verifier mirror

`_glyph_ink_boxes` shares `_delimiter_targets` + `_delimiter_resolution`,
so the verifier measures the SAME variant ink the raster draws for all
three modes (the unpaired brace measures braceleft.v5 at 27.17pt; the
tower formula reports ink bbox top 4.565pt = the variant's ink top, and
0 geometric defects).

## Before → after stroke measurement (tower `\left\{ ... \right.` at -s 30)

Brace stroke thickness (median/mean of horizontal ink runs through the
brace, in pt; raster at 96 dpi):

| render | stroke median | stroke mean |
|---|---|---|
| BEFORE: base `{` at the declared 57.066pt (the bold brace) | 3.75pt | 4.29pt |
| AFTER: braceleft.v5 at 27.17pt | 3.00pt | 2.88pt |
| XeTeX reference: braceleft.v4 at 29.89pt | 3.00pt | 3.01pt |
| base `{` at 30pt (un-stretched, reference stroke) | 3.00pt | 3.04pt |

The fixed brace stroke equals the base-size stroke and the XeTeX
reference; the bold look is gone. Ink extent: brace 4.57..61.63pt,
tower top 4.73pt — the variant covers the tower (the scaled-base draw's
intent) exactly.

## Verification

- `python3 scripts/critique.py -i '\left( x^2 \right) \left\{ x^{x^{x^{x^x}}} \right.' -s 30`
  → `critique-44: PASS (0 defects)`; `{` resolves braceleft.v5@27.17,
  parens unchanged (parenleft.v1@30, paired/base).
- `python3 scripts/critique.py -i '\big( \frac{a}{b} \big)' -s 30`
  → `critique-45: PASS (0 defects)`; parens resolve parenleft.v2@30
  (constant-stroke ladder variant; the fixed level is one rung above
  XeTeX's v1 because the fraction's internal offset, 0.04em, exceeds the
  v1→v2 advance spacing — the level is not in the SVG).
- `--ref` 3-pane runs:
  - tower → `critique-ref-19: PASS (5 nits)` — all minor (tower superscript
    spread, raster-antialiasing "slightly thicker" parens, LM-vs-KaTeX brace
    glyph curvature); NO bold-brace / short-brace nit — the defect is gone.
  - `\big( \frac{a}{b} \big)` → `critique-ref-20: FAIL (4 nits)` — all
    minor raster/glue nits ("parentheses slightly thicker" = the known
    PIL-antialiasing +4% ink effect, not the ladder size); the previous
    content-driven v4 (1.792em ink, 53.8pt) would have drawn ~18pt too
    tall and been flagged as such.
- Fixed along the way: `_extract_json` brace-balancing is now string-aware —
  vision nit descriptions quote literal braces ("The closing brace '}' …"),
  which a naive depth counter mis-parsed as the JSON's own delimiters
  (UNPARSEABLE verdicts on every delimiter critique).
- Regression (14 delimiter forms × 10/30/48pt, geometric verifier):
  paired `\left..\right` unchanged; unpaired scaled fences resolve their
  variant at every size; `\big/\Big/\bigg/\Bigg` recover exactly
  L1/L4/L6/L7 at every size.
- Known residual (documented, layout-side): `\left[ x^{x^{x}} \right.` now
  reports 1 overlap (`[`↔`𝑥`, 4.6% of the smaller): the layout's
  scaled-base box advance (0.278em × 35.286 = 9.8pt) is narrower than the
  drawn variant's ink (bracketleft.v2@29.4 → 11.8pt), so the following
  atom sits closer than in XeTeX (which advances by the variant, 12.5pt).
  The faithful variant draw exposes the tight placement; fixing it needs a
  layout-side box change (out of scope: EDIT ONLY critique.py).

