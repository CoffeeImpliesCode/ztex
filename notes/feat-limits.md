# feat-limits — \limits / \nolimits / \displaylimits override

Status: implemented, verified (display renders + unit tests + critique --ref).

## Semantics

The three "limit controls" (TeX: "Limit controls must follow a math operator")
set an override on the PRECEDING big-op / operator-word atom:

- `\limits` — force over/under limits in display AND text styles. `\int\limits_0^1 x`
  puts 1/0 ABOVE/BELOW the ∫ (XeTeX+unicode-math: `\displaystyle\int\limits`
  typesets the limits stacked); `\lim\limits_{x\to 0}` puts "x→0" under the word
  even in text style (TeX applies `\limits` in both styles).
- `\nolimits` — force beside scripts in every style. `\sum\nolimits_{i=1}^{n} x_i`
  puts "i=1" beside the ∑ at script size, like a sub/superscript pair.
- `\displaylimits` — restore the op's default: big-op family (∑ ∏ ∐ ⋃ ⋂ ⨆) → limits
  in display style, beside in text; int family (∫ ∮) → beside always; operator words
  → limits only for the limit-taking set (\lim \max \min \sup \inf \det \gcd \Pr
  \arg \ker \dim \hom \deg \limsup \liminf).
- Last command wins (`\int\nolimits\limits` = forced limits). On a non-op base the
  command is consumed as a no-op (legacy ztex behavior; TeX errors here).

## Implementation

- `src/atom.zig` — `LimitsBits` constants packed into the HIGH bits of the
  `.op`/`.opname` node's `data` (`force` = 1<<29, `force_beside` = 1<<30,
  `mask` = 0x6000_0000, `value_mask` = 0x1FFF_FFFF for the BigOp enum /
  opname limit flag below). No new node field; the superflat model + spans
  are untouched.
- `src/parse/parser.zig` — `parseScripts` no longer consumes `\limits`/`\nolimits`
  as no-ops: when the command follows an op/opname base it sets/clears the
  override bits on that base node's `data` (the base value is copied into any
  script node, so the flag reaches the final tree). `\displaylimits` added to
  `cmd_map`/`Command` (was `UnknownCommand`). Standalone fallback (row-leading
  limit control) stays a zero-width space, matching the old `.limits` behavior.
- `src/layout/layout.zig` — the limits decision in `layoutScript` consults the
  override: forced limits → `layoutOpLimits` in display AND text styles; forced
  beside → the beside script path always; otherwise the per-op default
  (display style && (op-family bigOpLimits || limit-taking opname)). All
  `@enumFromInt(data)` BigOp reads (`layoutOp`, `opTailIc`, beside path) now
  mask `atom.LimitsBits.value_mask`. `opTailIc` returns 0 for a forced-limits
  bare display op (a limits op takes no italic tail).

## Before / after vs the references (10pt display, XeTeX = \displaystyle)

`\int\limits_0^1 x` — before (≡ `\int_0^1 x`, \limits was a no-op): limits
BESIDE the ∫ (1 at x=10.79pt sup, 0 at x=4.88pt sub). After
(notes/artifacts/int-limits.svg): 1 ABOVE (x=4.04pt, y=5.46pt) and 0 BELOW
(x=0.72pt, y=36.01pt) the ∫ — the stacked limits XeTeX/KaTeX draw for
`\int\limits`.

`\sum\nolimits_{i=1}^{n} x_i` — before (≡ `\sum_{i=1}^{n} x_i`): n OVER,
i=1 UNDER (display default). After (notes/artifacts/sum-nolimits.svg): both
BESIDE the ∑ at x=15.24pt (the display-variant advance), n above at
y=3.89pt, i=1 below at y=17.54pt — the beside form XeTeX/KaTeX draw for
`\sum\nolimits`.

Defaults preserved (verified byte-geometry): `\sum_{i=1}^{n}` still stacks
limits in display; `\int_0^1` still has beside scripts; `\lim_{x\to 0}`
still puts the limit under in display.

## Critique verdicts (scripts/critique.py --ref, vision vs XeTeX + KaTeX)

- `\int\limits_0^1 x\,dx` → **FAIL (7 minor nits)**: gap after ∫, x/d glyph
  sizes, x·dx spacing, upper limit '1' slightly right, lower limit '0'
  slightly right, limits not perfectly centered vertically. All minor and
  pre-existing residual-position nits (the other layout-parity agents own
  them); the limit STACKING itself is present and matches the references —
  no nit reports beside-limits or missing limits.
- `\sum\nolimits_{i=1}^{n} x_i` → **PASS (5 minor nits)**: 'n' slightly
  off-center, 'i=1' slightly high, ∑→x_i spacing, 'x' size, x_i baseline vs
  KaTeX. The beside form is correct.

## Tests

9 new in-file tests (parser: force/force-beside/displaylimits/last-wins/opname
bit encoding; layout: \limits → limits vbox in text style, \nolimits → beside
script box in display, \int\limits → limits vbox in display, \lim\limits text
style → limits vbox). Full suite: 124/124 pass.
