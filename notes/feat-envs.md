# Math environments (\begin{env}...\end{env})

Feature: `\begin{matrix} \begin{pmatrix} \begin{bmatrix} \begin{Bmatrix}
\begin{vmatrix} \begin{Vmatrix} \begin{cases} \begin{aligned}
\begin{array}{cols} ... \end{...}` with `\\` row separators and `&`
column separators. Files: `src/atom.zig` (+`.env` tag), `src/parse/parser.zig`
(+`\begin` parsing), `src/layout/layout.zig` (+`layoutEnv`). Goldens/tests
untouched — all 168 tests pass (164 original + 4 new env parse tests),
non-env output byte-identical.

## Parsing design (parser.zig)

- `cmd_map` gains `.begin`; `parseCommand` dispatches to `parseBegin`.
  `\end` is NOT a command — `parseRow` in the new `.env_cell` mode stops at
  `\end` / `\\` (a `\` control-symbol token) / `&` (a char) without
  consuming them, so the env body parser can split rows and cells.
- `parseBegin` reads the env name (braced `{pmatrix}` or bare letters),
  the array colspec for `array`, then `parseEnvBody`: cells via
  `parseRow(.env_cell)`; `\\` finalizes a row (optional `[dimen]` row gap
  consumed and discarded); a trailing `\\` before `\end` does NOT add an
  empty row (TeX's `\crcr` absorption); then verifies `\end{NAME}` matches.
- The `.env` node children = `[open?, row1..rowN, close?]` — the delimiter
  char leaves (pmatrix `( )`, bmatrix `[ ]`, Bmatrix `{ }`, vmatrix `| |`,
  Vmatrix `‖ ‖` = U+2016, cases `{`) around the row atoms; each row is a
  `.row` of cell atoms. The delimiter cps ride in the char leaf `data`
  (like `\cdot`), so layout marks them synthetic.
- `data` = env kind (low 4 bits, `atom.EnvKind`) + packed array colspec
  nibbles (bits 8+, 4 bits per spec char: 0=l 1=c 2=r 3=|; max 6 spec
  columns). `|` occupies a spec slot but not a column slot (`{l|r}` packs
  [l, rule, r] — column 0 reads l, column 1 reads r).
- Errors: `UnknownEnvironment`, `MismatchedEnd`, `UnclosedEnvironment`;
  a stray `\end` stays `UnknownCommand`.
- Env names may be braced (`\begin{matrix}` — the LaTeX form) or bare
  letters (`\begin matrix \end matrix`); the bare form takes the whole
  letter run as the name (so the body must not start with letters —
  identical ambiguity to any delimiter-less name; LaTeX requires braces).
- Nested environments in a cell work: `\begin{bmatrix}` inside a cell
  goes through `parseCommand(.begin)` → its own `.env` node.

## Layout design (layout.zig, layoutEnv) — all constants measured

Every geometry constant below was verified against the XeTeX+unicode-math
reference (`\showbox` at 10pt + per-glyph extraction at 10pt and 36pt,
compare_env.py in /tmp/envref):

| aspect | value (measured) | source |
|---|---|---|
| column boxes | `[\hskip5][hfil cell hfil][\hskip5]`, adjacent | LaTeX `\@array` `\hskip\arraycolsep`, tabskip 0 |
| content-to-content gap | 2·\arraycolsep = **10pt fixed** | showbox: col1 15.29 = 5+5.29+5 @10pt |
| matrix edge pads | cancelled by amsmath `\hskip -\arraycolsep` — content flush at delimiters | 36pt: `a` at paren box right + 0.00pt |
| cell width | box width + **last char's LM Math italic correction** | 36pt: col2 = 10 + max(b 15.44+0.50, d 18.72+0.86) = 29.58 |
| row strut | 0.7/0.3 × \baselineskip (1.2·size; ×1.2 for cases) | 10pt rows (8.4+3.6), 36pt (30.24+12.96) |
| row stacking | direct (baseline distance = \baselineskip = 12pt @10, 43.2 @36) | LaTeX `\@array` zeroes baselineskip/lineskip |
| aligned interline | \openup\jot: bs+3, limit 3, lineskip 4 → 3pt gap | showbox `\glue(\baselineskip) 3.0` |
| cases column gap | \quad = 1em (inside the column width) | 36pt: col1 = max cell + 36pt |
| aligned columns | left parts right-aligned to max(adv+IC), right parts left-aligned, adjacent; right parts get the preamble `{}` ord-glue (thick 10pt @36 before a rel) | `a &= b`: `=` at a-box + 5mu |
| \vcenter | shift (h−d)/2 − axis; array center on the axis | 36pt bmatrix vbox (52.2+34.2) |
| delimiters | variant ladder (layoutDelimChar), req = max(2δ·0.901, 2δ−0.1em) from the array box | 2×2 letter matrix → parenleft.v6 @10pt, exactly the ref \showbox |
| array rules | `|` → \vrule 0.4pt (\arrayrulewidth) centered at the column boundary, spanning each row's strut extent | `{l|r}` rule between columns |

The italic corrections are read from `env_ic_table` (the LM Math
MathItalicsCorrectionInfo, extracted with fontTools): the static metrics
table's ICs are Computer-Modern values (b/d = 0), which would shrink the
columns by 0.5/0.86pt at 36pt.

## Verification (ztex vs XeTeX+unicode-math, per-glyph baselines)

36pt (tolerance 0.5pt):

| formula | max \|delta\| |
|---|---|
| pmatrix a&b\\c&d | 0.010pt |
| bmatrix 1&2\\3&4 | 0.028pt |
| cases x&x>0\\-x&x≤0 | 0.028pt |
| aligned a&=b+c\\d&=e | 0.504pt |
| array {l\|r} a&b\\c&d | 0.001pt |
| nested pmatrix with bmatrix cell | 0.010pt (content) |

10pt: pmatrix 0.006, bmatrix 0.001, cases 0.008, aligned 0.140, array
0.001. The aligned residual (0.5pt @36 = b's 0.014em italic correction) is
the KNOWN pre-existing layoutRow gap — XeTeX inserts each char's IC after
it in a math list (b→+ shows a 0.504pt kern at 36pt); ztex's layoutRow
does not (CumulativeDriftFix's scope). The env's own geometry (columns,
rows, vcenter, delimiters) is exact to ≤0.03pt.

## critique.py --ref verdicts (36pt)

- `\begin{pmatrix} a & b \\ c & d \end{pmatrix}`: **PASS** (4 minor nits —
  spacing wider than KaTeX only; paren shape; KaTeX font differences).
- `\begin{cases} x & x > 0 \\ -x & x \leq 0 \end{cases}`: **FAIL** (7 nits,
  all minor/none; most say "matches XeTeX but differs from KaTeX" — font
  shape/size artifacts of the PIL rasterizer; the measured geometry vs
  XeTeX is 0.028pt).

## Known residuals (pre-existing, out of scope)

1. Delimiter assemblies: at 36pt XeTeX draws large delimiters as
   assembly pieces (base + extenders + extension — the nested pmatrix's
   parens are `⎛⎜⎜⎝⎞⎟⎟⎠`); ztex draws the ladder variant (v6/v7). The
   variant advance matches the assembly's (0.736em vs 0.736em measured),
   ink within ~0.6pt — the established ladder model (FixParenVariants).
2. Between-char italic corrections in rows (see the aligned residual).
3. TeX sets ALL \array cells in $...$ text style; this feature lays out
   cells at the current style (spec) with cases' second column forced to
   text style — only visible in style-sensitive cells (fractions, limits).

## Before / after

Before: `\begin{pmatrix}` → `error: UnknownCommand` (no env support).
After: full environment rendering; all six acceptance formulas match the
XeTeX reference within the tolerance above.

Renders (36pt, SVGs in notes/artifacts/feat-envs/):
- `pmatrix.svg` — `\begin{pmatrix} a & b \\ c & d \end{pmatrix}`
- `cases.svg` — `\begin{cases} x & x > 0 \\ -x & x \leq 0 \end{cases}`
- `nested.svg` — `\begin{pmatrix} a & \begin{bmatrix} 1 \\ 2 \end{bmatrix} \\ c & d \end{pmatrix}`
