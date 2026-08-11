# feat-operatorname — \operatorname is a real mathop (roman opname)

Status: implemented, verified (geometry vs XeTeX + KaTeX, critique --ref, 156/156 tests).

## Semantics (from the ground truth, amsopn.sty)

`\operatorname{...}` is amsmath's declarable operator name. amsopn.sty:

```latex
\DeclareRobustCommand{\operatorname}{%
  \@ifstar{\qopname\newmcodes@ m}%
          {\qopname\newmcodes@ o}}%
\DeclareRobustCommand{\qopname}[3]{%
  \mathop{#1\kern\z@\operator@font#3}%
  \csname n#2limits@\endcsname}
\let\nmlimits@\displaylimits   % starred ("m")
\def\nolimits@{\@ifnextchar\limits{\nolimits\@gobble}{\nolimits}}  % unstarred ("o")
```

- unstarred → `\mathop{\operator@font{...}}\nolimits` — OP role, upright roman
  content, scripts BESIDE the word (`\operatorname{tr}^2` like `\sin^2`).
- starred → `\mathop{\operator@font{...}}\displaylimits` — same, but
  display-style over/under limits centered on the word (`\operatorname*{arg\,max}_{x}`
  puts "x" under the word in display, beside in text style — measured).

ztex maps this onto the EXISTING `.opname` machinery (the \sin/\lim path):
opname `data` 0 = nolimits (unstarred), 1 = displaylimits (starred) — the
same bit the parser already sets for the limit-taking words (\lim \max …).
Before this change `\operatorname` was aliased to `\mathrm` (a `.styled`
roman word with ORD role: no op spacing, no limits, no `*` form).

## Implementation — EDIT ONLY src/parse/parser.zig (+ tests)

- `cmd_map`: `"operatorname"` → new `Command.operatorname` (was
  `.style_roman`, the \mathrm alias).
- `parseCommand` switch: `.operatorname => self.operatorname(ast, cmd_tok)`.
- New `operatorname()`:
  - consumes an optional `*` suffix token (`\operatorname*` and
    `\operatorname *` both star; the lexer emits `*` as a char token —
    whitespace is already skipped — so the peek matches TeX's `\@ifstar`
    exactly; the star is never rendered);
  - `parseRequiredArg` parses the braced content as a NORMAL MATH ROW;
  - creates an `.opname` node: single child = the content row, `data` =
    1 if starred else 0, span = command (incl. `*`) through the content.
- `src/layout/layout.zig`: NO changes. The opname path already lays the
  child row out roman (upright), reports role OP (thin glue to ord/op/inner,
  none to open — TeX's op→open = 0, so `tr(A)` has no gap, matching both
  refs), and routes data=1 words through the display limits machinery.

## Literal spaces inside \operatorname

Measured ground truth: **XeTeX and KaTeX BOTH drop literal spaces** inside
`\operatorname` (the argument is math mode; amsopn's `\newmcodes@` only
reclasses `'` `*` `.` `/` `:`). `\operatorname{tr }(A)` renders "tr(A)" in
both refs. ztex matches by parsing the content as a math row (the lexer
skips whitespace). Explicit spaces (`\operatorname{arg\,max}`) render at
their normal mu width inside the word: ztex `\,` = 5.975pt at 36pt vs
XeTeX 5.954pt (Δ 0.02pt). This resolves the shared-context line "spaces
inside \operatorname{tr } are rendered as regular spaces" — a literal
space is dropped like TeX/KaTeX; a `\,`/`\;` space renders as a regular
space (verified).

## Before / after vs the references

Measured with scripts/compare_engines.py (per-glyph align, 36pt and 10pt
display `\[...\]`, XeTeX+unicode-math and KaTeX 0.16.28):

- `\operatorname{tr}(A)` — **10pt: max|dx| = 0.043pt, verdict ok**. Word
  width 7.81pt vs XeTeX 7.77pt. **36pt vs KaTeX: word width 28.116pt —
  EXACT** (KaTeX_Main "tr" advance == ztex's roman table). 36pt vs XeTeX
  differs 1.4–2.7pt on the letters: XeTeX switches to the LMRoman17
  OPTICAL size at 36pt; ztex scales the 10pt-base metrics linearly — the
  known pre-existing optical-font gap (affects \sin and plain letters
  identically, verified).
- OP spacing (10pt): `\operatorname{tr} A` → thin 1.667pt (3mu) vs XeTeX
  1.672pt (Δ 0.005); `\mathrm{tr} A` → 0 glue (both); `\operatorname{tr}
  + A` → `+` demoted to ord, thin 1.667 vs XeTeX 1.671; `\operatorname{tr}(A)`
  → 0 glue before `(` (op→open = 0; both refs show the paren flush).
- `\operatorname*{arg\,max}_{x} f(x)` (display): under-limit x centered on
  the word (ztex center +0.51pt vs word center; XeTeX +0.47 — Δ 0.04pt),
  under-gap 29.016pt vs XeTeX 28.833 (Δ 0.18pt), script size 25.2pt vs
  25.11 (the 0.7 factor). The `\,` = 5.975pt vs XeTeX 5.954 (Δ 0.02pt).
  Text style (`\textstyle`, matching inline `$...$`): the star's subscript
  goes BESIDE — ztex 3.46pt below baseline vs XeTeX inline 3.45pt.
- `\operatorname{arg\,max}_{x} f(x)` (unstarred, display): subscript beside
  at word end + 0.28pt (XeTeX + 0.4pt, the scriptspace) — matches.
- `\sin^2 x + \operatorname{tr}(A)` — the \operatorname word behaves like
  \sin: tr/(/) at ≤0.10pt at 10pt (verdict ok); remaining deltas (sin^2
  superscript dy 0.67pt) are pre-existing.
- `\operatorname{tr}^2 x` — superscript attaches at the word's right edge
  (Δ 0.01pt); thin after the scripted op = 1.667pt exact.

Residuals are pre-existing, NOT operatorname-specific: the f(x) after a
limits vbox drifts 0.78–1.28pt left (same construct with `\lim_{x\to 0}
f(x)`: 1.31pt — the known cumulative drift); the superscript-2 box is
0.47pt narrower (LM Math digit advance 0.568em vs ztex's cmmi10 0.5em).

## Critique verdict (scripts/critique.py --ref, 36pt, vision vs XeTeX + KaTeX)

- `\operatorname{tr}(A)` → **FAIL (4 minor nits)**: 'r' bolder, tr–(
  ink gap 0.27pt wider, parens 0.4% taller, 'A' weight. All four are
  FONT-INK differences (ztex draws LM Roman; XeTeX at 36pt uses LMRoman17
  optical; KaTeX uses CM-derived KaTeX_Main) — the pre-existing
  draw-font vs metrics-font gap (AuditMetrics/AuditFont scope). The two
  geometry-relevant claims are near-zero: the ADVANCE gap tr→( is 0pt in
  both ztex and XeTeX; paren height dev 0.4%.
- Baselines with the same nits: `\sin(x)` → **PASS** (4 nits), `\mathrm{tr}(A)`
  (the old alias) → **PASS** (5 nits, including the geometry confirmations
  "baseline alignment matches" and "spacing between tr and ( consistent").
  The FAIL/PASS difference is run-to-run vision judgment on the same-class
  font nits; no nit reports a layout defect in the opname rendering.

## Tests

5 new in-file tests in src/parse/parser.zig (opname word + nolimits data,
star consumption + limits data + `\,` space atom in the content row,
`\operatorname *` whitespace-star, scripts attach to the opname base,
missing-argument errors). Full suite: 156/156 pass.
