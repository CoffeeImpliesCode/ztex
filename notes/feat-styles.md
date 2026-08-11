# feat-styles — \dfrac \tfrac \cfrac + style switches

Roadmap item 3: forced-style fractions and math-style switches.
Files: `src/atom.zig` (+MathStyle +FractionBits +`.mathstyle` tag),
`src/parse/parser.zig`, `src/layout/layout.zig`. Goldens regenerate (output
change is INTENTIONAL for the new commands; existing formulas are
byte-identical).

## Atom design

- `atom.MathStyle` enum (`display text script script_script`, values 0-3).
  Layout's `Style` is now an alias of it (`pub const Style = atom.MathStyle`),
  so the parser packs forced styles into node data without importing layout.
- `fraction` node `data` (was: `@intFromBool(line)` = 0/1, unchanged for
  plain \frac/\atop): `atom.FractionBits` —
  - bit 0: rule line (\frac vs \atop),
  - bits 1-4: forced-style code, 0 = none, else `MathStyle + 1`
    (\dfrac → display, \tfrac → text),
  - bit 5: `parts_display` (\cfrac — both parts in display style).
  Accessors: `atom.fracLine/fracForcedStyle/fracPartsDisplay`, encoder
  `atom.fracData(line, forced, parts_display)`. Plain \frac/\atop keep data
  0/1, so every existing golden and test is untouched.
- New tag `.mathstyle`: a forced math style; 1 child = a row of everything
  after the command; `data` = `@intFromEnum(MathStyle)`. Transparent in
  `leftRole`/`rightRole`/`unwrapAtom` like `.group`/`.styled`.
- FeatLimitsOverride's `LimitsBits` (bits 29/30 of op/opname data) and
  FeatOverUnderline's `.overline` tag coexist; no bit overlap.

## Parser semantics

- `\dfrac{num}{den}` / `\tfrac{num}{den}` / `\cfrac{num}{den}` parse like
  \frac (two required braced args) with `fracData(true, .display|.text,
  …)`; \cfrac = `fracData(true, .display, true)`.
- `\displaystyle \textstyle \scriptstyle \scriptscriptstyle` are
  INTERCEPTED BY NAME (`mathstyle_map`) in `parseRow` (rest-of-group TeX
  semantics — everything after the command is parsed as a sub-row and
  wrapped in `.mathstyle`, so `\displaystyle\sum_{i=1}^{n}` wraps the whole
  scripted sum) and in `parseScriptArg` (an unbraced script field opening
  with a switch wraps the field's single atom; a braced field is the usual
  group → row → mathstyle). `parseCommand` never sees them. Infix fractions
  compose: `{a \over \displaystyle b}` puts the display style in the
  denominator, `\displaystyle a \over b` wraps the whole fraction.

## Style-forcing semantics (layout)

- `.mathstyle` lays out its content with the FORCED style, at size ×
  `styleScale(forced)/styleScale(current)` (styleScale: D/T → 1.0, S →
  scriptfactor, SS → scriptscriptfactor — the same root-relative ladder
  layoutScript uses), and clears the cramped bit (forced styles are
  uncramped: the classic escape from a denominator's cramped textstyle).
  So `\scriptstyle` in display shrinks content to 7pt, `\displaystyle` in a
  script grows it back to 10pt — TeX's "the style determines the font size".
- `layoutFraction` computes `eff_style = forced orelse style` and
  `eff_size = size_pt × scale(eff)/scale(current)`:
  - gaps: num1/denom1 (+ 3·rt clearance) for eff display, num2/denom2
    (num3 for \atop) otherwise — all scaled by eff_size;
  - part style: one level down from eff (D→T, T→S, S/SS→SS), except
    \cfrac's `parts_display` → `.display` for both;
  - \cfrac parts are UNCRAMPED (amsmath's `\frac{\displaystyle..}
    {\displaystyle..}`), so their superscripts use sup1 instead of the
    cramped sup3 (measured: \cfrac denom sup raises 0.4pt higher than \frac
    at 10pt);
  - no force → eff == style, ratio 1.0 → byte-identical to the old path.
- \dfrac/\tfrac interact with FeatLimitsOverride's \limits bits through the
  script node's context style (limits decision unchanged: `\displaystyle`
  sum in text takes over/under limits; `\textstyle` sum keeps beside).

## Before / after renders (10pt, per-glyph x/y/font-size)

Before: `\dfrac` `\tfrac` `\cfrac` `\displaystyle` etc. were
`error.UnknownCommand` — the formulas hard-failed (not in cmd_map or
symbol_map).

After:

`\sum_{i=1}^{n} \dfrac{1}{2}` — the \dfrac inside the display sum's
SCRIPT context grows to display size: parts at **10pt** (text size) with
num1/denom1 gaps; the plain `\frac{1}{2}` in the same spot renders 3.5pt
parts with small gaps:
```
frac in limit:  1@7.14,3.13 size3.5   2@7.14,8.30 size3.5   (tight)
dfrac in limit: 1@5.52,7.46 size10    2@5.52,21.08 size10   (num1/denom1 gaps)
```

`\dfrac{1}{2} + \tfrac{1}{2}` — dfrac parts 10pt with display gaps
(y 7.46/21.08), tfrac parts **7pt** with text gaps (y 10.29/17.67).

`\displaystyle\sum_{i=1}^{n} \frac{1}{i}` — in the TEXT row the sum takes
over/under limits: n at y 3.894 (over), i=1 at y 26.303 (under), ∑ 10pt.
`\textstyle \sum_{i=1}^{n} x_i` — same row but beside limits: n at y 3.894
(superscript), i=1 at y 13.544 (subscript), ∑ 10pt base glyph.

`x^{\displaystyle \sum_{i=1}^{n} x_i}` — the \displaystyle in the
superscript grows the nested sum back to 10pt WITH over/under limits
(grow-back: 7 → 10pt).

`\cfrac{a^2}{b^2} + \frac{a^2}{b^2}` — cfrac parts uncramped: denom sup
y 19.42 vs frac's 19.83 (raised 0.4pt, sup1 vs sup3).

`\scriptstyle x + \scriptscriptstyle y` — x 7pt, y 5pt.

## Verification

- 134/134 tests pass (10 new: parser dfrac/tfrac/cfrac data bits, mathstyle
  rest-of-group wrap, braced/unbraced script-field switches, empty switch
  group; layout dfrac-in-script display size, tfrac text gaps, cfrac
  display parts, mathstyle size rescale both directions). Existing goldens
  byte-identical (plain fraction data 0/1).
- `scripts/critique.py --ref` (XeTeX + KaTeX references, 20pt):
  - `\dfrac{1}{2}`: FAIL, 4 minor nits — fraction-bar thickness, digit
    weight/curvature, digit height vs bar. All are the known LM-Math-drawn
    vs CM-reference design differences (identical nit class as a plain
    \frac render); NO size/style-misplacement nit — the display-size
    fraction matches the references.
  - `\textstyle \sum_{i=1}^{n} x_i`: FAIL, 5 minor nits — limit centering
    0.x pt, sup height, inter-term spacing, glyph size, baseline. Again the
    systemic spacing/font nits; the model correctly reads BESIDE limits
    (sup/sub), not display over/under — the switch works.
