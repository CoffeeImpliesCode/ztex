# feat-mathchoice — \mathchoice{D}{T}{S}{SS}

Adds TeX's four-style choice primitive (XeTeX goody) to ztex.

## Branch-selection rule

The parser reads four required braced arguments — the display, text,
script, and scriptscript branches — into a new `.mathchoice` atom whose
children are `[D, T, S, SS]`.

Layout picks the branch by the CURRENT math style, exactly TeX's
`math_choice` (tex.web: the choice is by the style class; the cramped bit
is dropped):

| current style | branch |
|---|---|
| display | D (0) |
| text | T (1) |
| script | S (2) |
| scriptscript | SS (3) |

Only the chosen branch is laid out; the other three are never measured.

## Style forcing

The chosen branch is laid out with its OWN style forced, reusing the
`.mathstyle` (\displaystyle \textstyle ...) forcing from FeatStyleSwitches:
branch i is set at style i. Concretely the branch child runs through
`layoutInner` with

- style = the branch's style (= the current style by the selection rule),
- size = `size_pt * styleScale(branch) / styleScale(current)` — root-relative
  style-level sizing, the same ladder \dfrac uses,
- cramped = false — forced styles are uncramped.

So the D branch renders at the display size, the S branch at the script
size, etc. The uncramped bit is the observable TeX effect: a \mathchoice
inside a fraction denominator lays its branch out UNcramped, raising the
branch's superscripts by sup2 instead of sup3 (measured below).

Inter-atom class: the node is classified `ord` (like `.fraction` /
`.overline`) in leftRole/rightRole — a box atom. TeX splices the chosen
branch's atoms into the list, so exotic bin/rel branch contents would lose
their glue; branch contents are normally ord (fractions, letters).

## Files

- src/atom.zig — new `mathchoice` Tag (children = the four branches).
- src/parse/parser.zig — Command `.mathchoice`, cmd_map entry,
  parseCommand arm, `mathchoice()` helper (four `parseRequiredArg`).
- src/layout/layout.zig — `layoutInner` dispatch arm, `layoutMathChoice`
  fn, leftRole/rightRole `.mathchoice => .ord`.

## Before / after

Before: `\mathchoice` was not in cmd_map → `error.UnknownCommand`, parse
failure.

After (ztex -s 20, root renders in display style; the D/T/S/SS branches
hold the letters D/T/S/s mapped to their math-italic forms):

1. `\mathchoice{DD}{TT}{SS}{ss}` (display) → two glyphs `D` `D` at
   font-size 20pt (display size).
2. `x^{\mathchoice{DD}{TT}{SS}{ss}}` (superscript → script style) → two
   glyphs `S` `S` at font-size 14pt (script size).
3. `\textstyle \mathchoice{DD}{TT}{SS}{ss}` (text) → two glyphs `T` `T`
   at font-size 20pt (text size).
4. `\sum_{i=1}^{n} \mathchoice{\frac{1}{2}}{x}{y}{z}` (display row) → D
   branch: `1` `2` laid out EXACTLY like a plain display `\frac{1}{2}`
   (same x, same y, same font-size 20pt — byte-identical glyph records to
   the plain fraction render).
5. `x^{\mathchoice{DD}{TT}{\frac{1}{2}}{z}}` (superscript → script style)
   → S branch: the fraction at script size, parts at font-size 7pt
   (scriptscript size).
6. Uncramped forcing: `\frac{1}{a^2}` denominator raises its superscript
   by sup3 (measured raise 5.78pt at 20pt); `\frac{1}{\mathchoice{a^2}{a^2}{a^2}{a^2}}`
   lays the chosen T branch out uncramped — the superscript raise grows to
   sup2 (measured 7.26pt at 20pt), matching TeX math_choice.

Goldens change only for formulas that newly use \mathchoice (the parent
regenerates; existing goldens — x^2, \frac{1}{2}, \sum_{i=1}^{n} — are
untouched because the tag addition is additive and the regression dumper
prints unknown tags via @tagName).
