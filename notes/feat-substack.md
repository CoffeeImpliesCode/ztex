# \substack + \pmod/\pod (FeatSubstackPmod)

Adds amsmath's script-size multi-line stack for limits and the parenthesized
mod to ztex. Files edited: `src/atom.zig` (new `.substack` tag),
`src/parse/parser.zig` (commands + parse fns), `src/layout/layout.zig`
(layoutSubstack + layoutPmod + dispatch). Nothing else touched; existing
output is byte-identical (all changes are additive — new tags/commands/
functions; the `\\` row separator now only breaks lines inside
`.substack_line` parse mode).

## Before

- `\substack`, `\pmod`, `\pod` → `error.UnknownCommand` (hard parse fail).
- `\\` outside `\left..\right` → `error.UnknownCommand` (unchanged; it only
  becomes a line separator inside \substack).

## After

- `\substack{a \\ b \\ c}` → `.substack` atom, children = the line rows.
- `\pmod{n}` → a row marked `pmod_row_data`: ['(', roman "mod" opname word,
  6mu space leaf, arg, ')']; `\pod{n}` → `pod_row_data`: ['(', arg, ')'].
- The synthesized glyphs (parens, mod letters) carry their codepoints in
  `data` and share the command token's span → marked synthetic in layout,
  so flatten dupes them instead of aliasing the "\pmod" source bytes.

## \substack layout (layoutSubstack)

Lines lay out at `\scriptstyle` (script size), uncramped (amsmath's
`\subarray` cells are `$\m@th\scriptstyle##$`); the size follows the
root-relative style ladder so the lines are script-sized from display/text
and from deeper styles too. Each line is centered in the stack box.

Stacking (amsmath.sty, the XeTeX/OT-math branch, with Latin Modern Math's
MATH-table constants at the SCRIPT size):

    \baselineskip = \Umathstacknumup + \Umathstackdenomdown
                  = (StackTopShiftUp 0.444em + StackBottomShiftDown 0.345em) · script
    \lineskip     = \Umathstackvgap = StackGapMin 0.120em · script
    \lineskiplimit = \lineskip
    sep_i = max(baselineskip, d_{i-1} + h_i + lineskip)   (the TeX \baselineskip rule)

Measured vs the XeTeX reference `\sum_{\substack{i=1 \\ j=1}}^{n} x_i x_j`
(36pt, display): the reference line separation is 20.09pt
(= d_prev + h_next + vgap — the digit-height lines beat the 19.88pt nominal
baselineskip). ztex reproduces 20.09pt (Δ < 0.01pt at 36pt; 0.02pt at 10pt).

The stack BOX is the raw stack — height = line-1 height, depth = last
line's baseline + depth (so every line's ink is bounded) — NOT amsmath's
`\vcenter`-shifted (H−D)/2 ± axis box. The measured reference under a
display ∑ places the line-1 baseline at `op_bottom + max(bigop2,
bigop4 − stack_h) + stack_h`: 38.99pt below the ∑ baseline in BOTH ztex
and the XeTeX ref (Δ 0.01pt). The \vcenter model would sit 3.9pt higher
and is ruled out by the measured geometry (XeTeX's OT-math \subarray
renders the raw box).

## \pmod/\pod layout (layoutPmod)

amsmath.sty:

    \pod#1{\allowbreak \if@display\mkern18mu\else\mkern8mu\fi (#1)}
    \pmod#1{\pod{{\operator@font mod}\mkern6mu#1}}

- Leading \mkern: 18mu (1em) in display math, 8mu in text/script/
  scriptscript. Verified: XeTeX `\[ a \equiv b \pmod{n} \]` (display math)
  → b→( gap = b advance + 18.01pt at 36pt ✓; XeTeX `$a \equiv b
  \pmod{n}$` (inline, even with \displaystyle) → 8mu (the critique --ref
  harness renders inline, so ITS XeTeX pane shows 8mu — a harness
  artifact; KaTeX `-d` and true display math show 18mu, matching ztex).
- \mkern6mu (6/18 em) between the roman "mod" word and the argument: ztex
  emits a 6/18-em space leaf; measured ref gap = d advance + 12.00pt at
  36pt ✓.
- No inter-atom glue anywhere in the composition (all pairs kern–(,
  (–mod, mod–6mu, 6mu–arg, arg–) are zero in the TeX glue table, and a
  \mkern suppresses letter kerning across it) — layoutPmod places the
  pieces back to back with the two explicit kerns.

Numeric match at 36pt vs KaTeX (`katex -d`, KaTeX_Main): every origin
(a, ≡, b, (, m, o, d, n, )) agrees within 0.02pt — the composition is
exactly KaTeX's. vs XeTeX display math the only deltas are (1) the roman
letter advances at sizes ≥17pt (below) and (2) the per-letter italic
correction XeTeX folds into char boxes (pre-existing, affects all rows).

## Known deltas (pre-existing, NOT introduced here)

1. **Optical-size roman metrics**: XeTeX's fontspec selects LMRoman17 for
   roman text at sizes ≥17pt (measured m/o/d/n advances 0.772/0.459/0.511em
   vs the 0.833/0.5/0.556 cmr10 values ztex uses). At 36pt the XeTeX "mod"
   word is 5.3pt narrower than ztex/KaTeX. At ≤12pt LMRoman10 == cmr10, so
   ztex matches exactly. Affects ALL roman rendering (\mathrm,
   \operatorname, opnames), not just \pmod.
2. **Per-letter italic correction in row advances** (XeTeX folds the
   MathItalicsCorrection into italic char boxes; ztex uses the hmtx
   advance): ~0.4pt/letter at 10pt, shifts the substack line centering by
   ic/2 (~0.28pt at 10pt).
3. **Display big-op drawn-ink vs box**: ztex's limits center on the
   operator BOX (the .v1 advance) like the ref; the critique's PIL
   rasterizer draws the .v1 variant aligned to the base ink center, so the
   superscript/limits appear slightly off the ∑ ink center vs XeTeX's
   .v1 ink. Purely visual (FixInk/FixBigOpWidth territory), the limits
   geometry itself matches.

## Critique verdicts (scripts/critique.py --ref)

- `\sum_{\substack{i=1 \\ j=1}}^{n} x_i x_j` @36pt: 5 nits (2 none, 3 minor).
  Geometry: line separation 20.09pt both (Δ0.01), line-1 baseline 38.99pt
  both (Δ0.01), ∑-relative horizontal centering identical; the 3 minors are
  the display-op ink artifact (#3) and a spacing nit refuted by geometry
  (x_i→x_j = 29.79 vs 29.78pt).
- Same formula @20pt (the critique default): PASS, 3 minor (superscript
  height, lower-limit centering vs the ∑ ink, inter-term spacing — all the
  display-op ink artifact, refuted by geometry: the line separation and
  placement scale exactly).
- `a \equiv b \pmod{n}` @36pt: 6 minor nits — b→( (18mu vs the inline-harness
  8mu, #1 in the list above), mod word width (LMRoman17, #2), paren/letter
  eyeball diffs. KaTeX match is exact (all origins Δ<0.02pt).
- `a \equiv b \pod{n}` @36pt: PASS, 5 minor (a→≡, ≡→b, b→( all verified
  IDENTICAL across ztex/KaTeX/XeTeX: 29.04/38.01pt; the b→( nit is the
  18mu-vs-8mu harness artifact again).
- `\pmod`/`\pod` @10pt: PASS — only glyph-ink eyeball nits (thickness,
  roundness); the ( spacing "matches KaTeX", and at 10pt the roman metrics
  are exact.

## Before / after renders

Before: `\substack{...}`, `\pmod{n}`, `\pod{n}` all failed with
`error.UnknownCommand` (the `\\` row separator was only valid after
`\left`); nothing rendered. After: the three render end to end at every
size; after-renders live under /tmp/substack (ztex_substack.svg,
ztex_pmod.svg, ztex_pod.svg at 10pt; ztex36_*.svg at 36pt; the
critique --ref 3-pane combined.png per formula in /tmp/substack/crit*).
Measured after vs the XeTeX reference at 36pt:

| construct | quantity | ztex | XeTeX ref | Δ |
|---|---|---|---|---|
| \substack lines | baseline sep | 20.09pt | 20.09pt | <0.01pt |
| \substack | line-1 baseline below ∑ | 38.99pt | 38.99pt | <0.01pt |
| \substack | ∑-relative line centering | box-centered | box-centered | 0 |
| \pmod | leading \mkern (display) | 18mu = 36.0pt | 36.01pt (display math) | 0.01pt |
| \pmod | mod→arg gap | d + 6mu | d + 6mu (12.0pt) | 0 |
| \pmod | paren advances | 0.389em | 0.389em | 0 |
| \pmod | word letters | 0.833/0.5/0.556em | 0.772/0.459/0.511em @36pt (LMRoman17) | optical-size gap, 0 at ≤12pt |
| \pmod vs KaTeX | all 9 origins | — | — | <0.02pt |

## Files

- src/atom.zig: `.substack` tag (after `.mathchoice`).
- src/parse/parser.zig: Command enum {substack,pmod,pod}, cmd_map entries,
  `substack_line` RowMode + `\\` line break in parseRow, `pmod_row_data=4`
  / `pod_row_data=5`, `substack()` / `pmod()` parse fns, parseCommand arms,
  5 new tests.
- src/layout/layout.zig: `pmod_row_data`/`pod_row_data` consts, layoutInner
  dispatch (pmod/pod rows + `.substack`), leftRole/rightRole `.substack =>
  .ord`, `layoutSubstack`, `layoutPmod`.
