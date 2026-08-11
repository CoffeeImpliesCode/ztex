# feat-binom — \binom + \genfrac (roadmap item 4)

Generalized fractions: `\binom{n}{k}` (ruleless fraction inside auto-sized
parens) and `\genfrac{left}{right}{thick}{style}{num}{den}` (six-arg
generalized fraction). Files: `src/atom.zig` (fraction-data thickness bits),
`src/parse/parser.zig`, `src/layout/layout.zig`. SKIP gates; goldens
regenerate — no golden covers the new commands (previously
`error.UnknownCommand`); `zig build test` passes unchanged for every
existing formula.

## Atom design

`fraction` node `data` gains a third field beside the existing line bit
(bit 0), forced-style code (bits 1-4) and \cfrac parts flag (bit 5):
**bits 6-21 = \genfrac's explicit rule thickness, Q8.8 fixed point** (1/256
pt resolution, up to 255.99 pt; `FractionBits.thick_shift`/`thick_mask`).
Accessors `atom.fracThicknessBits(pt)` / `atom.fracThickness(data)`; 0 =
"no explicit thickness" (plain \frac/\atop AND a 0pt genfrac — the line bit
distinguishes). No bit collisions (LimitsBits lives at 29/30 on op/opname
data only).

## Parser (src/parse/parser.zig)

- `\binom{num}{den}` → a `.fraction` with `fracData(false, null, false)`
  (atop gaps, no rule, NO forced style) wrapped in a `.left` node of
  [open '(', fraction, close ')'], data 0 — the exact `\left..\right`
  shape, so layout sizes the parens by the variant ladder from the
  fraction's extent and the construct sits on the fraction's baseline.
- `\genfrac{ld}{rd}{thick}{style}{num}{den}` → parses two delimiter args
  (`parseGenfracDelim`: a braced group with one delimiter char/command or
  empty; `.` = null like `\left.`), a thickness arg (`parseGenfracThickness`:
  a braced pt dimension, empty→0, negative clamps to 0), a style arg
  (`parseGenfracStyle`), then the num/den. Result: a `.fraction` with
  `fracData(thick > 0, style, false) | fracThicknessBits(thick)`; with ≥1
  delimiter it becomes a `.left` fence around the fraction, else a bare
  `.fraction` (`\genfrac{}{}{0pt}{}{a}{b}` == `\atop{a}{b}` byte-identical).

### Style-flag mapping — references win over the spec draft

The spec draft says "display-style flag (0=text, 1=display)". Both
references implement the OPPOSITE, verified empirically at 36pt:

- **XeTeX** (amsmath.sty `\@mathstyle`): `""` → current style (`\relax`),
  `"0"` → `\displaystyle`, `"1"` → `\textstyle`, `"2"` → `\scriptstyle`,
  else → `\scriptscriptstyle`.
- **KaTeX** (genfrac.js `stylArray = ["display","text","script",
  "scriptscript"]`): identical mapping; `""` → "auto" (current style).

Measured: `\binom{n}{k}` at 36pt display renders n/k at **36pt** (current
style, display-size parts — NOT script-size), and
`\genfrac{(}{)}{0.8pt}{1}{x}{y}` renders x/y at **25.2pt** (style 1 = text
→ script-size parts). ztex implements the reference mapping: "" → no force,
0 → display, 1 → text, 2 → script, 3 → scriptscript. This is what makes the
refs comparisons pass (the critique on `\genfrac{(}{)}{0.8pt}{1}{x}{y}`
reports "glyph sizes: x and y match well with both references").

## Layout (src/layout/layout.zig)

- `layoutFraction` honors the explicit thickness: `rt = fracThickness(data)
  if > 0 else s(gl.rule_thickness, eff_size)`. The genfrac thickness is an
  ABSOLUTE TeX dimension — it does NOT scale with the font size (measured
  XeTeX: `\frac` rule 1.4345pt vs `\genfrac{}{}{1pt}` rule 0.9963pt at 36pt
  — 0.4em scaled vs a constant 1pt). It flows into both the rule drawing
  and the clearance math (3·rt), like TeX's `\above`.
- `\binom`/`\genfrac` delimiters reuse `layoutLeftRight` unchanged: the
  variant ladder picks the smallest variant whose ink covers the fraction
  (TeX make_delim, δ = max(h−a, d+a), factor 0.901, shortfall 0.1em), the
  inner sits at shift 0 (baseline = the fraction's baseline — \binom is a
  "delimiter-wrapped atop", NOT centered on the axis like \frac), and the
  whole construct keeps the row baseline.

## Baseline semantics (measured vs refs)

At 36pt display, aligning on the fraction axis (= the row baseline for a
delimiter-wrapped atop): numerator shift ztex 24.354 vs XeTeX 24.28
(Δ 0.07), denominator ztex 24.694 vs XeTeX 24.61 (Δ 0.09); n–k baseline
distance Δ 0.16pt; paren width Δ 0.05pt. All ≤ 0.5pt. (ztex's num1/denom1
are already the LM-Math MATH-table constants 0.677/0.686em, matching
XeTeX+unicode-math.)

## Before / after renders (36pt, per-glyph x/y/font-size)

Before: `\binom`/`\genfrac` were `error.UnknownCommand` — the formulas
hard-failed.

After (`\binom{n}{k} \binom{n+1}{k-1} \binom{\frac{a}{b}}{c}` — see
notes/artifacts/feat-binom/after-binom-row.svg): each binom is a paren
fence around a ruleless fraction; parts at display size (36pt) for n/k, the
nested `\frac{a}{b}` parts at 25.2pt (text style inside the binom's
display fraction); no rules anywhere; the parens (variant ladder) cover the
fraction:
```
(   x=2.880  y=49.536  size 36
n   x=27.948  y=25.182  size 36
k   x=29.370  y=74.230  size 36
)   x=50.748  y=49.536  size 36
```

After (`\genfrac{[}{]}{0pt}{}{a}{b} \genfrac{}{}{1pt}{}{a}{b}
\genfrac{(}{)}{0.8pt}{1}{x}{y}` — notes/artifacts/feat-binom/after-genfrac-
row.svg): bracket-wrapped atop (no rule), bare fraction with an explicit
1pt rule (rect height exactly 1pt, parts at display size), and a text-style
fraction (x/y at 25.2pt) with a 0.8pt rule inside parens.

## Verification

- `zig build test`: all pass (7 new tests: atom thickness bits round-trip;
  parser binom fence shape, genfrac bare-atop == 0 encoding, explicit
  thickness bits, style-arg mapping incl. ""/"0"/"1"/"2"/"3"/other,
  delimiter fence + \lbrace + 0.8pt + style 1, dot delimiters + error
  cases). Existing formulas byte-identical (golden snapshots unchanged).
- `scripts/critique.py --ref` at 36pt:
  - `\binom{n}{k}`: **PASS** (3 minor nits — paren stroke thickness, n/k
    spacing vs XeTeX, glyph size vs XeTeX; all the systemic LM-Math-drawn
    vs CM-reference design nits seen on plain \frac; nothing structural).
  - `\genfrac{(}{)}{0.8pt}{1}{x}{y}`: **PASS** (5 nits, incl. two "none" —
    x/y glyph sizes match both references, paren spacing consistent;
    confirms the style-1=text mapping).
  - `\genfrac{[}{]}{0pt}{}{a}{b}`: FAIL (6 minor nits) —
    `\genfrac{}{}{1pt}{}{a}{b}`: FAIL (4 minor nits). All nits minor and
    systemic (bracket/rule thickness, a/b spacing/baselines vs the refs).
- Known divergence, honest report: XeTeX's amsmath sizes `\genfrac`
  delimiters from a FIXED phantom (`\Umathfractiondelsize` via
  `\genfrac@rule`), drawing continuously-scaled delimiters (measured
  non-ladder ink 1.628/1.456em for \binom parens — asymmetric!, 2.34/2.40em
  for the bracket genfrac) that are content-INDEPENDENT and can exceed the
  content's extent; KaTeX sizes from the content but with a larger cover
  floor. ztex sizes genfrac delimiters from the enclosed fraction by the
  standard TeX make_delim req (factor 0.901 + 0.1em shortfall), exactly the
  `\left..\right` path the spec asked to reuse — the refs' larger-variant
  choice on small contents is a reference-mechanism artifact, not a ztex
  structural error (ztex's variant always covers the fraction; \binom — the
  spec's explicit ≤0.5pt case — matches within 0.16pt and critiques PASS).
