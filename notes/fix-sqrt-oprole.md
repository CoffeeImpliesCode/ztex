# Fix: stretchy \sqrt + vinculum, and the OP role for operator words

Two real layout bugs found by the multi-reference critique, fixed in
`src/parse/parser.zig` + `src/layout/layout.zig` (no other files touched;
`metrics.zig` unchanged — the U+221A ink extents 0.040/0.960 em were already
in the ink table).

## Bug 1 — \sqrt was a plain base-size √ with no vinculum

Before: `\sqrt{x^2+1}` parsed to a row `[char(√), radicand]` and the √ was
laid out as an ordinary character: drawn at the text size, ink 0.96em below
the baseline, no stretching, no overbar. Measured from the old critique-22
artifact (32pt): the √ ink spanned ~32pt while the radicand was ~24pt tall,
the radical's top hook sat ~6pt below the radicand's top, and the SVG had
no rule element — "radical shorter/less curved" with no vinculum.

Fix (TeX rule 11 / XeTeX make_radical, measured against XeTeX+unicode-math+
LM Math and KaTeX):

- The parser marks the \sqrt row with `data = sqrt_row_data (1)`; ordinary
  rows always carry 0, so the marker is unambiguous. `layoutInner` routes
  marked rows through the new `layoutSqrt` (which reuses the existing
  delimiter machinery `layoutScaledChar` + the ink table).
- `layoutSqrt` lays out the radicand in cramped style (same size), then:
  - clearance `clr` = 0.148em in display/text, 0.05em in script/scriptscript
    (the LM Math MATH-table RadicalDisplayStyleVerticalGap / RadicalVerticalGap
    — the classic θ + x-height/4 and 5θ/4 give the same numbers);
  - drawn size `gs = max(H + D + clr + θ, size)` — the base √ glyph's 1.0em
    ink covers the radicand's full extent + clearance + rule, never smaller
    than the text size (XeTeX draws shallow radicands with a text-size
    radical whose bar overhangs below the baseline);
  - TeX's clearance adjustment: `delta = max(0, 0.96·gs − (H + D + clr))`,
    `clr += delta/2` — the radical glyph's ink depth usually exceeds the
    need, so half the excess raises the vinculum;
  - the glyph is anchored so its ink top (the hook tip, 0.04·gs above its
    baseline) sits at the vinculum's top `H + clr + θ` — the bar then
    descends `gs − rule_top` below the baseline, covering the depth;
  - the vinculum is a `.rule` leaf of thickness θ at `[H+clr, H+clr+θ]`,
    spanning exactly the radicand's width (measured XeTeX: the rule runs
    from the radicand's left edge to its right edge; the hook connects it
    to the bar);
  - `\sqrt[n]{x}`: the degree is set at 0.5×size (XeTeX measured 4.98pt at
    10pt), its bottom raised to `rule_top − 0.4·gs` (60% of the radical's
    ink height per RadicalDegreeBottomRaisePercent), its left edge
    0.278·deg_size (RadicalKernBeforeDegree) right of the radical bar.

Before/after ink vs the references (10pt, XeTeX measured from mutool SVG +
fontTools outlines):

| metric                    | before            | after          | XeTeX ref     |
|---------------------------|-------------------|----------------|---------------|
| `\sqrt{x}` rule top       | — (no rule)       | 8.10 pt        | 8.06 pt       |
| `\sqrt{x}` bar bottom     | −9.56 pt (unscaled)| −1.90 pt      | −1.90 pt      |
| `\sqrt{x^2+1}` rule top   | —                 | 9.43 pt        | 10.26 pt      |
| `\sqrt{x^2+1}` bar bottom | −9.56 pt          | −0.83 pt       | −1.70 pt      |
| vinculum spans            | —                 | radicand width | radicand width|

The `\sqrt{x}` case matches XeTeX to ≤0.05 pt (the delta adjustment is
exactly XeTeX's own). `\sqrt{x^2+1}` sits 0.8 pt lower because XeTeX's
assembled radical overshoots its request (discrete assembly sizes) — a
minor, principled difference (0.148em is KaTeX's clearance too).

## Bug 2 — operator words lacked the OP role

Before: `.opname` atoms (\sin \cos \log …) returned role ord from
leftRole/rightRole, so `\sin x` had NO space (ord→ord = none). TeX: these
are \mathop atoms — role OP — and op→ord gets thin glue.

Fix: `.opname => .op` in both leftRole and rightRole, and the `.script`
case now reports op for bases that are big operators OR operator words
(`\sin^2 x`, `\lim_{x\to0}` are still ops). Nothing else changes:
\lim/\max/\min still route through layoutOpLimits in display, `\sin^2 x`
still attaches its superscript at the word's right edge with no glue before
it, and no italic-correction tail is added after the words (TeX: roman
letters have ic 0; opTailIc only fires for `.op` big ops).

Measured (10pt, ours vs XeTeX):

| pair             | ours   | XeTeX |
|------------------|--------|-------|
| sin → x          | 1.67 pt (thin 3/18 em) | 1.66 pt |
| cos → x          | 1.67 pt (thin)        | 1.66 pt |
| x → +            | 2.22 pt (med)         | 2.21 pt |
| + → cos          | 2.22 pt (med)         | 2.22 pt |

`a \sin x` also gets the ord→op thin (1.67 pt), matching TeX.

## Critique nit delta (scripts/critique.py, -s 40)

- `\sqrt{x^2+1}`: **PASS** (was FAIL: "radical shorter/less curved", no
  vinculum). Remaining 5 nits are all pre-existing and unrelated to the
  radical: superscript '2' position, spacing around '+', '+'/ '1' glyph
  sizes — plus a "baseline under the root matches" note. Geometric
  verifier: 0 defects, 0 clipping; the `√ × rule` ink intersection is
  correctly excluded as "radical over its radicand".
- `\sin x + \cos x`: **PASS** — "cos and x spacing matches", "sin/cos glyph
  sizes consistent"; the thin spaces are now present (the old render had
  none). Remaining nits (spacing "slightly tighter" around sin/x, +/cos,
  '+' thickness) are ≤1 px at 96 dpi — vision-model noise, both panes
  render at the same nominal thin/med spacing as XeTeX and KaTeX.
- `\sqrt{\frac{a}{b}}` (tall radicand): geometric verifier 0 defects, 0
  clipping — the radical covers the fraction (vision's "sqrt overlaps the
  fraction bar" claim refuted: that is the radical's own bar over its
  radicand, excluded by design).

## Files

- `src/parse/parser.zig`: `sqrt_row_data` const; `sqrt()` marks the row.
- `src/layout/layout.zig`: `sqrt_row_data` const; `.row` routing in
  layoutInner; `layoutSqrt` (after layoutScaledChar); `.opname => .op` and
  the `.script` op-base check in leftRole/rightRole.
- `metrics.zig`: unchanged (U+221A ink already present).
