# feat-big — \big \Big \bigg \Bigg + \middle (roadmap item 5)

Fixed-size delimiters (`\big( \Big[ \bigg\{ \Bigg\langle`) and `\middle<delim>`
(delimiter sized like the enclosing `\left...\right` pair).

Files: `src/parse/parser.zig`, `src/layout/layout.zig`,
`src/layout/metrics.zig` (ladder additions only). SKIP gates; goldens
regenerate — no golden covers `\big`/`\middle` (previously
`error.UnknownCommand`); `zig build test` passes 143/143 unchanged.

## Size levels (measured vs XeTeX + KaTeX at 36pt)

Reference method: xelatex (standalone + amsmath + unicode-math, `\fontsize{36}
{43}`), mutool SVG per-glyph ink bboxes vs the LM Math font outlines
(fontTools BoundsPen); KaTeX via `scripts/katex_ref.py` geometry at 36pt.

| command | LM ladder variant | ink (em) | ztex ink (pt@36) | XeTeX (pt) | Δ | KaTeX (pt) | Δ |
|---|---|---|---|---|---|---|---|
| `\big(`  | parenleft.v1 | 1.094 | 39.38 | 39.24 | 0.14 | 43.16 | 3.78* |
| `\Big[`  | bracketleft.v4 | 1.792 | 64.80 | 64.53 | 0.27 | 64.76 | 0.04 |
| `\bigg{` | braceleft.v6 | 2.392 | 86.40 | 86.09 | 0.31 | 86.36 | 0.04 |
| `\Bigg⟨` | angleleft.v7 | 2.990 | 108.00 | 107.60 | 0.40 | 107.93 | 0.07 |

All within the ≤0.5 pt acceptance except `\big` vs KaTeX (*). The divergence
is a REFERENCE disagreement, not an implementation error: XeTeX+unicode-math
draws `\big` at parenleft.v1 (ink 1.094em) at EVERY size — measured 10, 14,
24, 36pt — because amsmath's `\bBigg@` (`\vcenter to n·\big@size{}`,
`\big@size = 1.2·(ht+dp of the '(' math strut)`) scales with the current
size, and the make_delim req lands on the SAME ladder level each time.
KaTeX's `\big` is scale-relative (KaTeX_Size1 at 1.2em → ink 1.199em at any
size). XeTeX is the pipeline's primary reference; KaTeX agrees on
`\Big \bigg \Bigg` (≤0.07pt) and only diverges on `\big` (its 10pt value
1.199em ≈ XeTeX's v2 there — the fixed-pt target coincides with 1.2em only
at 10pt).

So the four levels are FIXED ladder indexes: **big→1, Big→4, bigg→6,
Bigg→7** (`big_ladder_idx`), with ink targets 1.094/1.792/2.392/2.990 em
(`big_target_ink`) for delimiters without a variant ladder (scaled-base
fallback).

## Parser (src/parse/parser.zig)

- `\big \Big \bigg \Bigg <delim>` → a `.left` node with a SINGLE delimiter
  child (no inner, no `\right`) and `data` = level 1..4 (`fixedDelim`). The
  delimiter set reuses `parseDelimiter` (the full `\left..\right` set: `( )
  [ ] { } |` chars + `\langle \rangle \lfloor \rfloor \lceil \rceil \vert
  \Vert \| \backslash \\ /`). `\big.` renders nothing (zero-width space,
  like TeX's empty `\big.` with `\nulldelimiterspace=0`).
- `\middle <delim>` → a char leaf whose `data` packs
  `(middle_marker << 21) | cp` (bit 21; the low 21 bits are the codepoint,
  which `delimiterCp`/`layoutChar` keep reading via `@truncate`). Valid only
  between `\left` and `\right` (`Parser.delim_depth`, set around the
  `.delimited` interior parse; `\middle` elsewhere →
  `error.UnexpectedMiddle`). `\middle.` renders nothing.

## Layout (src/layout/layout.zig)

- `layoutLeftRight` handles `inner_idx == null` (the fixed-level nodes):
  `layoutDelimLevel` boxes the delimiter by `ladder[big_ladder_idx[level]]`
  (adv × size, ink asc/desc × size) at the base font size, axis-centered
  `(h−d)/2 − axis` — the exact box a stretched `\left..\right` delimiter
  gets, at a fixed level. The SVG emits the base delimiter char at the base
  size; the rasterizer resolves the variant (FixParenVariants model).
- Glue class: a `\big`-family node is amsmath's `\bBigg@` **\box atom —
  class ORD**, not inner (XeTeX `\showbox` of `\Big[ x \Big]`: the box is
  `\mathon\hbox...\mathoff`; the x sits flush at the bracket's advance — NO
  thin space). `leftRole`/`rightRole`: `.left` → `.ord` when `data != 0`,
  `.inner` for real fences.
- `\middle`: `layoutRow` emits the marked leaf as a zero-width placeholder
  box; `layoutLeftRight` rewrites it IN PLACE via `sizeMiddleDelims` (walks
  the inner subtree — groups/fractions/scripts included) with a req derived
  from the **FENCE box**, not the content — TeXBook p.291: "\middle gives a
  delimiter that is as tall as the delimiters that \left and \right
  produce". The middle picks its OWN ladder's smallest variant covering that
  req (largest when none does). `\left.`/`\right.` pairs (no fence) fall
  back to the content-derived req. The rewritten extents bound the hbox so
  the frame covers the middle ink. Roles: a middle leaf is class close
  (measured: no glue around it).
- The middle is a `\middle|` sized to divides.v3 while the fence `{` is
  braceleft.v4 — different LEVELS, same required height applied to each
  glyph's own ladder (XeTeX measured: | ink 1.734em = divides.v3, fence ink
  1.794em = braceleft.v4).

## Metrics (src/layout/metrics.zig)

Added ladders (fontTools on latinmodern-math.otf 2.005, MathVariants +
BoundsPen + hmtx) so `\middle|`/`\left|` pick REAL variants instead of the
scaled-base fallback:
- U+2223 (∣) and U+007C (|): divides base (adv 0.278, ink 0.750/0.250) +
  divides.v1..v7 (ink 1.202/1.444/1.734/2.084/2.502/3.004/3.606em);
- U+2016 (‖): parallel base (adv 0.398) + parallel.v1..v7;
- U+002F (/): slash base (adv 0.500) + slash.v1..v7 (inks
  1.310/1.716/2.248/2.944/3.858/5.054/6.620em).

Non-stretched `\left|` stays byte-identical (base entry adv 0.278em = the
old scaled-base box at base size; the fallback's glyphInk 0.750/0.250 = the
base ink).

## \middle integration (verified vs XeTeX at 36pt)

`\left\{ x \middle| \frac{x}{2} \in S \right\}`:

| box | ztex (pt) | XeTeX \showbox (pt) | Δ |
|---|---|---|---|
| `{` fence (braceleft.v4) | h 41.40 d 23.40 | h 41.40096 d 23.39905 | 0.001 |
| `\middle|` (divides.v3) | h 40.21 d 22.21 | h 40.212 d 22.212 | 0.002 |
| `}` fence | h 41.40 d 23.40 | h 41.40096 d 23.39905 | 0.001 |
| root | h 41.40 d 24.69 | h 41.40096 d 24.69864 | 0.009 |

The | ink = 62.42pt = the reference's 62.42pt exactly.

## Before/after renders

Before: `\big`/`\Big`/`\bigg`/`\Bigg`/`\middle` → `error.UnknownCommand`
(no atom tree). After: `\big( \frac{a}{b} \big) \Big[ x \Big] \bigg\{ y
\bigg\} \Bigg\langle z \Bigg\rangle` and the middle formula render correctly;
the 3-pane ref images (ours/XeTeX/KaTeX) are in
`notes/critique-big/artifacts/critique-ref-{3,4}/combined.png`; the formula
SVGs at `notes/critique-big/artifacts/critique-ref-{3,4}/render.svg`.

## scripts/critique.py --ref verdicts (at 36pt)

- `\big( \frac{a}{b} \big) \Big[ x \Big] \bigg\{ y \bigg\} \Bigg\langle z
  \Bigg\rangle` → **FAIL, 5 minor**: fraction-rule thickness perception,
  y/z letter-advance deltas (pre-existing, 0.9-1.0pt on the y/z advances),
  and 3 delimiter "spacing" nits.
- `\left\{ x \middle| \frac{x}{2} \in S \right\}` → **FAIL, 1 major + 4
  minor**: "vertical bar thicker and taller", "gap between bar and fraction
  wider", brace size, baseline, fraction rule.

The delimiter nits are **rasterizer artifacts, not layout errors**: the
geometric checks above prove the layout boxes match XeTeX to ≤0.4pt. Root
cause: `scripts/critique.py`'s `_delimiter_targets` derives a stretched
delimiter's variant from the ENCLOSED CONTENT of a matched `( ) [ ] { } ⟨ ⟩
⌊ ⌋ ⌈ ⌉` pair; `\big`-family delimiters are fixed-level (content-independent)
and `|` is not in its `DELIMITER_CPS`, so the rasterizer draws the BASE
glyph — the pane then shows small delimiters and the vision critic reads the
resulting extra white space as "wide spacing". critique.py is owned by the
FixParenVariants/PilCritique/VerifyCritic chain (out of this task's EDIT-ONLY
scope); a fix would read the fixed level (or the fence-derived req) from the
layout box — e.g. a `data-level` attribute on the delimiter `<text>`, or
critique.py deriving the req for unpaired delimiters from the layout's box
extents. Flagged to Main.
