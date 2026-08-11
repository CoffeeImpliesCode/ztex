# Pipeline Stage 1 Fix: parser command coverage (Greek, relations, operators, sqrt, left/right, primes, atop)

Date: 2026-08-13. Fixes findings #1-#4 of notes/pipeline-parse.md. Files changed: `src/parse/parser.zig` ONLY (lexer and atom.zig untouched — every new construct maps onto existing atom tags; no new Tag, so `layout.zig`'s exhaustive `layoutInner` switch is unaffected).

## What changed

### 1. `symbol_map` (~190 single-glyph commands → codepoint)
New comptime `std.StaticStringMap(u21)` consulted in `parseCommand` after `cmd_map` misses. Each entry produces a `.char` leaf with the codepoint in `data` — the exact `\cdot` mechanism (layout reads `nodeCp`, `roleOfCp`, metrics; box marked synthetic). Covered:

- **Greek lowercase** (U+03B1–U+03C9 + TeX variants): `\alpha \beta \gamma \delta \epsilon \varepsilon \zeta \eta \theta \vartheta \iota \kappa \lambda \mu \nu \xi \pi \varpi \rho \varrho \sigma \varsigma \tau \upsilon \phi \varphi \chi \psi \omega`
- **Greek uppercase**: `\Gamma \Delta \Theta \Lambda \Xi \Pi \Sigma \Upsilon \Phi \Psi \Omega`
- **Relations**: `\leq \le \leqq \geq \ge \geqq \neq \ne \in \ni \notin \subset \supset \subseteq \supseteq \sim \simeq \cong \approx \propto \equiv \ll \gg \prec \succ \preceq \succeq \vdash \dashv \perp \parallel \mid \asymp \doteq \models \bowtie \frown \smile`
- **Arrows**: `\leftarrow \rightarrow \to \leftrightarrow \Leftarrow \Rightarrow \Leftrightarrow \iff \implies \impliedby \uparrow \downarrow \updownarrow \Uparrow \Downarrow \Updownarrow \mapsto \nearrow \searrow \swarrow \nwarrow \hookleftarrow \hookrightarrow \leftharpoonup \leftharpoondown \rightharpoonup \rightharpoondown`
- **Binary ops**: `\pm \mp \times \div \ast \star \circ \bullet \oplus \ominus \otimes \oslash \odot \wedge \vee \land \lor \cup \cap \sqcup \sqcap \setminus \dagger \ddagger \diamond \wr \uplus \amalg \triangleleft \triangleright \bigcirc`
- **Misc**: `\infty \partial \nabla \prime \ldots \cdots \vdots \ddots \ell \Re \Im \wp \aleph \forall \exists \neg \lnot \top \bot \emptyset \varnothing \angle \triangle \square \surd \clubsuit \diamondsuit \heartsuit \spadesuit \backslash \lbrace \rbrace \vert \Vert \langle \rangle \lfloor \rfloor \lceil \rceil \therefore \because \colon \hbar \imath \jmath`

`\cdot` stays in `cmd_map` (unchanged). Every codepoint above is either in the metrics table (real CM values) or falls back to `glyphEstimate` — see §4 for the exact set still missing metrics.

### 2. Operator words (`\sin \lim \log` …) → roman styled word
New `.opname` command kind. The name's letters become `.char` leaves (ASCII codepoint in `data`, all sharing the command token's span), grouped in a row wrapped in a `.styled` node with `CharStyle.roman` — i.e. exactly the `\mathrm{sin}` rendering path. Scripts attach to the styled node, so `\sin^2 x`, `\lim_{x \to 0}`, `\max_i` all work; `\limits` after a name is skipped (see §5).

Covered: `\sin \cos \tan \cot \sec \csc \arcsin \arccos \arctan \sinh \cosh \tanh \coth \sech \csch \arcsec \arccsc \log \ln \lg \exp \lim \limsup \liminf \max \min \sup \inf \arg \ker \dim \det \gcd \Pr \hom \deg \mod \bmod`. `\operatorname{...}` maps to the existing `.style_roman` (`\mathrm` semantics — braced arg parsed as a row).

Known deviation: the styled word carries role `ord` (layout has no op-class atom for words), so TeX's thin space between an operator and its argument is not emitted (`\sin x` renders tight). Cosmetic; accepted for this pass.

### 3. `\left ... \right` → row of plain delimiters
New `.left` command. `parseLeftRight` consumes the delimiter, parses the interior with a new `RowMode.delimited` (stops at `\right` or `}`), consumes `\right` + its delimiter, and returns a `.row` of `[open-char, inner-row, close-char]`. Delimiters render at ordinary size (no stretching — layout has no delimiter scaling), but every common `\left(\right)` / `\left\{...\right\}` / `\left|...\right|` / `\left\langle...\right\rangle` form now parses AND shows its parens/braces/bars. `\left.` / `\right.` are null delimiters (no char). Scripts after the construct attach to the row: `\left(\frac{a}{b}\right)^2` works.

Delimiters accepted: chars `( ) [ ] |`, `.` (null), and commands `\{ \} \langle \rangle \lfloor \rfloor \lceil \rceil \lbrace \rbrace \vert \Vert \| \\ \backslash /`. A stray `\right` (outside `\left`) → `error.UnexpectedRGroup` (TeX's "Extra \right"); a missing `\right` → `error.UnclosedGroup`.

### 4. `\sqrt` → surd + radicand row
New `.sqrt` command. `\sqrt{x}` → row `[√(U+221A), radicand]`. `\sqrt[n]{x}` parses the optional degree `[n]` and attaches it as a superscript on the surd (renders √ⁿ x). No overbar is drawn (layout has no radical-rule node) — noted as pending layout work, but the construct parses and renders the surd + content.

### 5. `\limits` / `\nolimits` → consumed as no-ops
`parseScripts` skips `\limits`/`\nolimits` command tokens between a base and its `^`/`_`, so `\sum\limits_{i=1}^{n}` attaches the scripts to the big op exactly as before (ztex layout already places op scripts as display limits; the switch is a no-op for it). As standalone atoms (`x\limits`) they become a zero-width space leaf (invisible). The skipped token rides inside the script node's token span, so provenance stays exact.

### 6. Prime fix (`'` → superscript U+2032)
`parseAtom` now scans trailing `'` chars after the base and its scripts, accumulating them into ONE superscript: `f'(x)` → `f^{′}`, `f''(x)` → `f^{″}` (U+2033), `f'''(x)` → `f^{‴}` (U+2034). The prime wrap happens AFTER `parseScripts`, so `x_1'` keeps its subscript and gains the prime (TeX noad semantics); `x'^2` still errors (the `^2` is left as a row-leading script → `UnexpectedScript`, TeX's "Double superscript"). A row-leading `'` (no base) still renders as a baseline apostrophe char (no error).

### 7. `\atop` / `\over` / `\choose` → TeX infix syntax
`parseRow` now intercepts these three command names and splits the row: everything before the delimiter becomes the numerator, everything after (to the row's end) the denominator, and the whole row becomes a `.fraction` — `{a \atop b}` now parses as TeX intends (previously `error.MissingArgument`). `\over` → fraction with rule (line=true), `\atop`/`\choose` → no rule (line=false); `\choose` additionally wraps the fraction in `( )` chars. At top level the fraction is wrapped in a row to preserve ztex's "root is always a row" convention (and the old `\atop{a}{b}` tests' structure). A second delimiter in one group (`{x \atop y \atop z}`) → `error.MissingArgument` (TeX: "Ambiguous"). The old 2-arg `.atop` path is retained in `parseCommand` for the odd script-position case (`x^\atop`), which parseRow never sees.

## Acceptance check (all render to SVG, verified via `zig build run -i`)
`\frac{\alpha+\beta}{\gamma}`, `x \leq y`, `\sin x + \cos x`, `\sqrt{x^2+1}`, `\sum_{i=1}^{n} x_i`, `\left( \frac{a}{b} \right)`, `f'(x)`, `\infty`, `\alpha\beta\gamma\delta`, `a \in S` — plus `{a \atop b}`, `{n \choose k}`, `\lim_{x \to 0} f(x)`, `\sum\limits_{i=1}^{n}`, `f''(x)`, `\sqrt[3]{x}`, `\left\{ x \right\}`, `\operatorname{tr}(A)`.

Error paths preserved: `\nosuchcmd` → UnknownCommand, `x^2^3` → DoubleScript, `\frac{1}` → MissingArgument, `x}` → UnexpectedRGroup, `^x` → UnexpectedScript, `\left( x` → UnclosedGroup, `\right)` → UnexpectedRGroup.

## Tests
All `parse`/`parser`/`root` module tests pass (the two `\atop` tests keep passing: root stays a row whose first child is the line=false fraction). The 3 remaining `zig build test` failures at write time are in `layout`/`regression` only (display-op vbox shift; SVG `pt`-unit goldens) — caused by the concurrent layout/svg fixes (FixMetricsStyle, FixSvgUnits) whose goldens regenerate; none touch the parser.

## Known gaps (still `UnknownCommand`, for future passes)
Accents (`\hat \bar \vec \dot`), `\overline \underline`, `\binom` (use `\choose`), environments (`\begin{matrix}`), `\middle`, `\big\Big...` sizing, `\displaystyle`-family switches, `\text{...}`-only subset of boxes/colors. `\frac12` (unbraced arg) still requires `{ }`. `x\,^2` still attaches the script to the glue (finding #6, unchanged).

## Metrics gaps (codepoints that fall back to `glyphEstimate`)
Parser now emits these codepoints but the metrics table lacks them: Greek `Ξ Υ Ψ ζ η ι κ ν ξ ρ ς τ υ χ ψ ϑ ϕ ϖ ϱ ϵ` (03B6-03C9 subset, 03D1/03D5/03D6/03F1/03F5), `‖` (2016), `•` (2022), `≣` (2263), `≼ ≽` (227C/227D), `⋮` (22EE), `⋰` (22F0), `□` (25A1), `△` (25B3), `♠♥♦♣` (2660-2663), `⟼` (27FC). They still parse and render at estimated 0.5em width — see notes/fix-pipeline-metrics.md for adding real CM metrics.
