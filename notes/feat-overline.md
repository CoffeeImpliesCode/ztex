# Feature: \overline and \underline (roadmap item 1)

A rule drawn ABOVE (`\overline`) or BELOW (`\underline`) the content,
spanning exactly the content's width at a small clearance, matching the
XeTeX (+unicode-math) and KaTeX references.

## Atom / layout design

**Atom** (`src/atom.zig`): a new tag `.overline` — "`\overline{x}` /
`\underline{x}`: 1 child = the content (a single atom or braced group);
`data` = 0 over / 1 under". A dedicated tag was chosen over a 4th
row-`data` marker (rows already overload `data` for sqrt=1, accent=2, and
the `op`/`opname` `data` high bits now carry `LimitsBits`); a first-class
tag keeps the layout switch explicit.

**Parser** (`src/parse/parser.zig`): `Command.overline`/`.underline` +
`cmd_map` entries + two `parseCommand` cases → a new `overunder` helper.
The argument is ONE following atom or braced group via `parseScriptArg`
(the same helper the accents use; TeX's argument is a math field, so
`\overline x` works and `\overline{xy}` overlines the group). The node
carries `data = 0 over / 1 under`. Scripts after it (`\overline{x}^2`)
attach through the ordinary `parseAtom` path like any base.

**Layout** (`src/layout/layout.zig`): `layoutOverUnder`, a faithful port of
tex.web `overbar`/`make_over` and `make_under`:

- Rule thickness `rt = rule_thickness` (the TeX `default_rule_thickness`,
  a font dimension: 0.4pt at 10pt = 0.04em, scaled by size).
- Clearance `3·rt` from the content's box edge (TeX's `overbar_rule`-free
  formula; the old "0.4pt" folklore value is wrong — tex.web uses
  `3*default_rule_thickness`).
- `\overline`: content laid out CRAMPED (`make_over`'s
  `cramped_style(cur_style)` — scripts in the content squeeze, e.g. a
  `\frac` numerator's superscript drops from sup2 to sup3). The vlist is
  `[kern rt, rule rt, kern 3·rt, content]`: the box height grows by `5·rt`
  (the leading kern puts the rule BELOW the box top), the depth is
  unchanged; the rule's bottom edge sits at `height(content) + 3·rt`.
- `\underline`: content keeps the current (uncramped) style
  (`make_under`'s `clean_box(nucleus, cur_style)`). The vlist is
  `[content, kern 3·rt, rule rt]`: the box depth grows by `4·rt`, the
  height is unchanged; the rule's top edge sits at
  `depth(content) + 3·rt` below the baseline.
- The rule is a `.rule` leaf (height = depth = rt/2, so the emitted rect
  is exactly rt thick) placed at shift `-(H + 3·rt + rt/2)` (over) /
  `+(D + 3·rt + rt/2)` (under), spanning the content width; the result is
  an `.hbox` with the content at shift 0.
- Roles: `leftRole`/`rightRole` report `.ord` (TeX's over_noad/under_noad
  are ordinary), so inter-atom glue around them is the ord spacing.

## Measured clearance vs the references

Rendered at 36pt, `\displaystyle`, XeTeX + unicode-math (latinmodern-math
2.005). XeTeX draws at 35.865pt for `\fontsize{36}` (0.375% scale
correction), so the comparison is done in em (÷ glyph size); absolute pt
positions are reported for the criterion.

| formula | ztex clearance (rule inner edge − content ink) | XeTeX clearance | Δ (em) |
|---|---|---|---|
| `\overline{AB}` | 4.320pt = 0.1200em | 4.304pt = 0.1200em | 0.0000 |
| `\overline{x+y}` | 4.320pt = 0.1200em | 4.288pt = 0.1196em | 0.0004 |
| `\overline{\frac{a}{b}}` | 4.320pt = 0.1200em | 4.291pt = 0.1197em | 0.0003 |
| `\underline{x}` | 4.320pt = 0.1200em | 4.313pt = 0.1203em | −0.0003 |
| `\underline{AB}` | 4.320pt = 0.1200em | 4.304pt = 0.1200em | 0.0000 |
| `\overline{\underline{x}}` (outer/inner) | 0.1200 / 0.1200em | 0.1197 / 0.1203em | ≤0.0003 |

Rule thickness: 1.440pt (ztex) vs 1.435pt (XeTeX) = 0.04em both. KaTeX
0.16.28's `.overline-line`/`.underline-line` are also `border-bottom-width:
0.04em` with the same 3·rt-style clearance — the three engines agree on
0.04em / 0.12em.

**Rule y-positions (the acceptance criterion, ≤ 0.5pt at 36pt):**

| formula | rule(s) | ztex center | XeTeX center | Δ |
|---|---|---|---|---|
| `\overline{AB}` | over | 30.816pt | 30.701pt | +0.115 |
| `\overline{x+y}` | over | 30.988pt | 30.891pt | +0.097 |
| `\overline{\frac{a}{b}}` | over | 46.010pt | 45.772pt | +0.238 |
| `\overline{\frac{a}{b}}` | frac rule | 8.799pt | 8.661pt | +0.121 |
| `\underline{x}` | under | 4.524pt | 4.545pt | −0.021 |
| `\underline{AB}` | under | 4.320pt | 4.339pt | −0.019 |
| `\overline{\underline{x}}` | over | 30.814pt | 30.736pt | +0.078 |
| `\overline{\underline{x}}` | under | 4.523pt | 4.544pt | −0.021 |

(centers in pt above the content baseline; the residual is the 36 vs
35.865pt scale and pre-existing fraction internals — the ztex fraction rule
itself carries a 0.84pt offset vs XeTeX that predates this feature).

Scripts on the construct match too: `\overline{x}^2` puts the superscript
baseline at 16.812pt (ztex) vs 16.748pt (XeTeX) above the baseline — the
existing sup_drop path consumes the taller box height correctly (Δ 0.064pt).

## Critique

`python3 scripts/critique.py -i '\overline{x+y}' -s 36 --ref` →
`notes/critique-ref-11.md`: **FAIL (6 nits, all minor)** — "bar appears
slightly thicker", "x/+ gaps slightly tighter", "glyph sizes slightly
larger", baseline consistent. All nits trace to the 36 vs 35.865pt render
scale and pre-existing inter-atom glue; NONE concerns the rule's position,
width, or clearance.

`python3 scripts/critique.py -i '\overline{x+y}' -s 36` (geometric
verifier, deterministic) → `notes/critique-41.md`: **PASS (0 defects)** —
vision claims refuted by the geometry check.

## Before / after

Before: `\overline`/`\underline` were `UnknownCommand` hard errors
(`zig-out/bin/ztex -i '\overline{AB}'` → `error: UnknownCommand`).

After (36pt): `notes/artifacts/feat-overline/corpus.png` — the six
verification formulas stacked:
`\overline{AB}`, `\overline{x+y}`, `\overline{\frac{a}{b}}`,
`\underline{x}`, `\underline{AB}`, `\overline{\underline{x}}`. Per-formula
SVGs in `notes/artifacts/feat-overline/f{0..5}.svg`.

## Files touched

- `src/atom.zig` — new `Tag.overline` (+ doc)
- `src/parse/parser.zig` — `Command.overline/.underline`, `cmd_map`
  entries, `parseCommand` cases, `overunder()` helper
- `src/layout/layout.zig` — `layoutInner` case, `leftRole`/`rightRole`
  `.ord`, new `layoutOverUnder()`

No changes to existing atoms' output: 134/134 tests pass (`zig build
test`), including the in-flight `\limits`/`\displaylimits` and
`.mathstyle` work by other peers (LimitsBits and mathstyle logic
preserved untouched).
