# Pipeline Stage 1 Audit: ztex parse (lexer/parser → atom tree) vs MicroTeX + TeX

Date: 2026-08-13. READ-ONLY audit; no zig gates run.

Files audited (read fully):
- `src/parse/lexer.zig` (302 ln), `src/parse/parser.zig` (490 ln), `src/parse/root.zig`
- `src/token.zig` (Span), `src/atom.zig` (atom tree, ScriptBits, BigOp, CharStyle)
- Layout cross-check only (to judge what the parse tree can express): `src/layout/layout.zig` (roleOfCp, bigOpCodepoint), `src/layout/metrics.zig` (glyph/style), `src/layout/draw.zig`

References:
- MicroTeX `src/core/parser.cpp` (1057 ln: full TeX-style parser with macros, environments, prime handling, array mode), `src/core/macro_def.cpp` (≈250 macro commands + 26 environments), `src/core/formula_def.cpp` (predefined formulas: operator names, arrows, etc.), `src/res/builtin/tex_symbols.res.cpp` (630 builtin symbols with TeXBook atom classes: 170 ord / 250 rel / 112 bin / 24 op / 8 open / 8 close / 11 punct / 17 acc)
- TeX math semantics per tex.web math-command cases + plain.tex mathcodes. Claims marked **[TEX-EMPIRICAL]** were verified by running `tex`/`latex` (TeX Live available at /run/current-system/sw/bin).

---

## 1. Executive summary (ranked by impact)

| # | Finding | Failure mode | Magnitude |
|---|---------|--------------|-----------|
| 1 | Command set is 24 commands vs MicroTeX's ~900+ (630 symbols + ~250 macros + ~50 predefined formulas + 26 environments) | `error.UnknownCommand` → **whole formula rejected** | Catastrophic: essentially every real-world formula |
| 2 | `\atop` implemented with the wrong syntax (2-arg `\atop{a}{b}`; TeX's is infix `{a \atop b}`) | Real TeX `{a \atop b}` → `error.MissingArgument`; `\atop{a}{b}` errors in TeX [TEX-EMPIRICAL] | High |
| 3 | `\left`/`\right`/`\middle`, `\sqrt`, `\operatorname`, `\limits`/`\nolimits`, `\begin{env}`, `\over`/`\choose`/`\brace`/`\brack`, operator names (`\sin \lim \log…`), all Greek, all relations, all arrows, all accents | UnknownCommand | Catastrophic (see #1; listed separately because these are the specific common-formula killers) |
| 4 | `'` (prime) is an ordinary char atom → baseline apostrophe glyph | Wrong glyph/position (no error) | High: `f'(x)`, `x'`, `A'` render wrong |
| 5 | `\mathbf`/`\mathbb`/`\mathcal`/`\mathfrak`/`\mathsf`/`\mathtt` parse to `.styled` correctly, but the metrics layer ignores `style` (`_ = style` in `glyph`/`glyphAt`/`lookupAscii`) | Visual no-op: `\mathbb{R}` renders as plain `R`, `\mathbf{x}` not bold | Medium (silent wrong output) |
| 6 | Scripts attach to the immediately preceding atom **including glue**: `x\,^2` → script base is the `\,` space leaf | Wrong script base vs TeX (TeX skips glue, attaches to `x`) [TEX-EMPIRICAL: `$x\,^2$` parses clean] | Medium-low |
| 7 | Row-leading `^`/`_` (`^2`, `x_^2`, `x+^2`) → hard `error.UnexpectedScript`; TeX recovers with "Missing { inserted" / "Missing } inserted" and renders [TEX-EMPIRICAL] | Hard error where TeX renders | Low-medium |
| 8 | Missing spaces `\:` `\>` `\enspace` `\hspace`; `\ ` (control space) → UnknownCommand | UnknownCommand | Low |
| 9 | Parser assigns no role/class to char atoms; roles deferred to layout `roleOfCp` table, which diverges from plain.tex mathcodes for some ASCII (`*` is Bin in TeX, `.ord` here; `'` prime; `&`/`~`/`#`/`$`/`%` are structural/special in TeX, ordinary chars here) | Wrong spacing or wrong glyph | Low-medium |
| 10 | `$…$`, `$$…$$`, `\(…\)` math-mode delimiters not recognized — rendered as literal chars | Wrong output for wrapped input | Depends on API contract (ztex is fragment-only) |

The single dominant cause of "significantly flawed output" for real-world formulas is **finding #1**: the parser's command table (`cmd_map`, parser.zig:56-80) accepts exactly 24 commands. Anything else is a hard parse error, so a formula containing `\alpha` or `\leq` fails *entirely* — not a wrong render, a rejected formula.

---

## 2. Lexer (src/parse/lexer.zig)

**Correct:**
- Whitespace (` `, `\t`, `\r`, `\n`) skipped entirely — matches TeX math-mode space handling (spaces ignored; only `\,` etc. add glue). MicroTeX does the same (`skipWhiteSpace`, and the `case ' '` branch adds no atom in math mode).
- Comments `%`→EOL skipped (lexer.zig:75-80) — matches TeX mouth behavior.
- Command names: maximal run of ASCII letters; else a single codepoint control symbol (lexer.zig:88-105) — matches TeX control-word vs control-symbol rules. `\,` → name `,`, `\\` → name `\`. Both are then looked up in cmd_map.
- UTF-8 validated per codepoint with correct byte spans (lexer.zig:107-114).
- `^`/`_`/`{`/`}` are structural tokens (lexer.zig:31-42).
- `[`/`]` remain ordinary chars (test "brackets are ordinary chars") — correct: TeX treats them as ord/close chars with mathcodes, not structure. (MicroTeX also keeps them as chars.)

**Divergences (low impact):**
- `[`/`]` as ordinary chars means `\sqrt[3]{x}`-style optional args can't be consumed — but `\sqrt` is unknown anyway (finding #1).
- `&` lexes as an ordinary char. In TeX, `&` is an alignment tab (catcode 4) and errors outside alignment ("Misplaced alignment tab character"); MicroTeX throws `ex_parse` for `&` outside array mode (parser.cpp `case '&'`). ztex renders a literal `&`. Divergence.
- `#` (macro parameter, error in TeX math), `$` (math shift, ends math mode in TeX), `~` (unbreakable space in TeX math, `sptrOf<SpaceAtom>()` in MicroTeX) all lex as ordinary chars. ztex renders them literally.
- `'` (U+0027) and `"` lex as ordinary chars; TeX's math scanner special-cases `'` (mathcode "8000 → prime superscript) and MicroTeX also accumulates `"` / `’` / `‵` into primes (parser.cpp PRIME/DQUOTE cases). ztex renders both as baseline chars (finding #4).
- `°` (U+00B0) is an ordinary char; TeX/MicroTeX preprocess it to `^{\circ}` (parser.cpp preprocess). Minor.

---

## 3. Parser → atom tree (src/parse/parser.zig)

**Structure produced** matches the intended TeX atom model for the supported subset:
- `row` (hlist of atoms), `group` (transparent `{…}`), `char` (leaf), `script` (base+sup+sub), `fraction` (num/den + line flag), `space` (glue, Q16.16 em width), `text` (opaque run, CharStyle data), `styled` (1 child, CharStyle data), `op` (BigOp leaf).
- **Script bits** (atom.zig ScriptBits sup=1, sub=2) — verified correct: sup-only / sub-only / both recorded, children normalized to `[base, sup?, sub?]` (parser.zig:187-215). Matches TeX: `x^2`, `x_2`, `x^2_3`, `x_2^3` all attach to the base and error on doubles.
- **Double script** `x^2^3` → `error.DoubleScript` — matches TeX "Double superscript" [TEX-EMPIRICAL, LaTeX errors].
- **Nested scripts** `x^{y^2}` — parseScriptArg routes braced args through parseGroup → inner row → works.
- **Scripts on composites** `\frac{1}{2}^2`, `\sum_{i=1}^n` — parseAtom(parseSingleAtom → parseScripts) attaches correctly; big-op scripts stay op-role downstream (layout.zig leftRole).
- **`\atop`** produces a `fraction` with line=false, data 0 (parser.zig:307-312) — the node itself is right, but the *syntax* is wrong (finding #2).
- **Spaces**: `\,`=0.166em, `\;`=0.277em, `\!`=−0.166em, `\quad`=1em, `\qquad`=2em (parser.zig:246-250) — these match TeX mu values (3/5/−3 mu at 18mu/em). Missing `\:`/`\>` (4mu=0.222em), `\enspace`, `\hspace`.
- **`\cdot`** → char leaf with data override 0x22C5 (parser.zig:288-290); layout `nodeCp` reads the override, `roleOfCp(0x22C5)` → bin. Correct.
- **Big ops**: 8 ops → `BigOp` enum (parser.zig:295-297); layout maps to codepoints (layout.zig:821-837: ∑ ∏ ∫ ∐ ⋃ ⋂ ⨆ ∮). Missing `\bigvee \bigwedge \bigoplus \bigotimes \bigodot \biguplus \bigsqcap \iint \iiint \iiiint \idotsint`.
- **`\text{...}`** (parser.zig:315-330): opaque span scanned for balanced braces; raw bytes re-read from source. Correct for simple text; nested `$…$` math or commands inside are not parsed (TeX allows `\text{$x$}`; MicroTeX parses `$…$` inside mbox). Always CharStyle.roman. Low impact.

**Divergences:**
- **`\atop` syntax** (finding #2, high): TeX `\atop` is an infix generalized-fraction delimiter: `{a \atop b}` [TEX-EMPIRICAL: plain TeX accepts; `\atop{a}{b}` errors with "Emergency stop"]. ztex implements the 2-arg form `\atop{a}{b}` (parseCommand `.atop` → parseRequiredArg×2), so every real TeX usage `{a \atop b}` dies at the second `parseRequiredArg` with `error.MissingArgument`. The only command in ztex whose *syntax* is TeX-incompatible.
- **`\frac` args must be braced**: TeX/LaTeX `\frac12` works (macro `\frac#1#2`) [TEX-EMPIRICAL]; ztex `parseRequiredArg` demands `{` → `error.MissingArgument`. Low frequency, real formulas do use `\frac12`.
- **Scripts after glue** (finding #6): `x\,^2` attaches the script to the `\,` space leaf. TeX math list handling attaches scripts to the preceding *atom*, skipping glue/penalty nodes [TEX-EMPIRICAL: `$x\,^2$` compiles clean; rendered as x with the superscript]. ztex's parseScripts runs per-atom immediately after parsing the base atom, so a space between base and script steals the script.
- **Row-leading scripts** (finding #7): `^2`, `+^2`, `x_^2` → `error.UnexpectedScript` (parseRow parser.zig:131-133). TeX recovers: `$^2$` → "Missing { inserted" then renders; `$x_^2$` → "Missing } inserted" then renders [TEX-EMPIRICAL]. ztex hard-errors the whole formula.
- **`\text` inside scripts/rows**: fine.

---

## 4. Command mapping: the gap (EXHAUSTIVE)

ztex `cmd_map` (parser.zig:56-80) = **24 commands**:
`\,` `\;` `\!` `\quad` `\qquad` (5 spaces) · `\frac` `\atop` (2 fractions) · `\text` `\mathrm` `\mathbf` `\mathbb` `\mathcal` `\mathfrak` `\mathsf` `\mathtt` (8 text/styles) · `\cdot` (1) · `\sum` `\int` `\prod` `\coprod` `\bigcup` `\bigcap` `\bigsqcup` `\oint` (8 big ops).

Reference scale: MicroTeX ships **630 builtin symbols** (tex_symbols.res.cpp; TeXBook page-445 set with classes) + **~250 macro commands** (macro_def.cpp) + **~100 predefined formulas** (formula_def.cpp: operator names, arrows, `\ldots`, `\notin`, …) + **26 environments** (matrix, pmatrix, bmatrix, cases, align, array, …) + runtime TeXSymbols.xml. Every command below is in MicroTeX's tables but NOT in cmd_map → `error.UnknownCommand` → whole formula rejected. Names in bold are the highest-frequency in real-world formulas.

### 4.1 Greek letters — ALL missing (UnknownCommand)
Small: `\alpha \beta \gamma \delta \epsilon \varepsilon \zeta \eta \theta \vartheta \iota \kappa \lambda \mu \nu \xi \pi \varpi \rho \varrho \sigma \varsigma \tau \upsilon \phi \varphi \chi \psi \omega \digamma \varkappa`
Capitals: `\Gamma \Delta \Theta \Lambda \Xi \Pi \Sigma \Upsilon \Phi \Psi \Omega` (+ var- forms `\varGamma`…)
Breaks: `\pi r^2`, `\theta`, `\lambda`, `\Delta x`, `\Omega`, `\varepsilon`, `\varphi` — anywhere.

### 4.2 Relations — ALL missing
`\leq \leqq \leqslant \ge \geq \geqq \geqslant \neq \ne \equiv \not\equiv \sim \simeq \approx \approxeq \cong \propto \doteq \doteqdot \asymp \bowtie`
`\in \ni \notin \subset \supset \subseteq \supseteq \subseteqq \supseteqq \subsetneq \supsetneq \sqsubset \sqsupset \sqsubseteq \sqsupseteq`
`\mid \nmid \parallel \nparallel \shortmid \perp \vdash \dashv \models \vDash \Vdash \nvDash`
`\prec \succ \preceq \succeq \precsim \succsim \precapprox \succapprox \ll \gg \lll \ggg \lessgtr \gtrless`
`\smile \frown \between \pitchfork \asymp \fallingdotseq \risingdotseq \backsim \backsimeq \eqsim \eqcirc \thicksim \thickapprox \triangleq \circeq \lesssim \gtrsim \lessapprox \gtrapprox \lesseqgtr \gtreqless \lesseqqgtr \gtreqqless \lessdot \gtrdot \lesseqgtr \leqslant \geqslant \eqslantless \eqslantgtr \ngtr \nless \ngeq \nleq \ngeqq \nleqq \ngeqslant \nleqslant \gneq \lneq \gneqq \lneqq \gnsim \lnsim \gnapprox \lnapprox \nsim \ncong \nprec \nsucc \npreceq \nsucceq \precneqq \succneqq \precnsim \succnsim \precnapprox \succnapprox \varsubsetneq \varsupsetneq \varsubsetneqq \varsupsetneqq \subsetneq \supsetneq \subsetneqq \supsetneqq \nsupseteq \nsubseteq \nsupseteqq \nsubseteqq \ntriangleleft \ntriangleright \ntrianglelefteq \ntrianglerighteq`
Breaks: `x \leq y`, `a \in S`, `\notin`, `\subseteq`, `\perp`, `\mid`, `\models`, `\equiv`, `\approx`, `\propto`, `\vdash`.

### 4.3 Binary operators — only `\cdot` supported; ALL others missing
`\times \div \pm \mp \ast \star \circ \bullet \oplus \ominus \otimes \oslash \odot \cap \cup \setminus \wedge \vee \land \lor \dagger \ddagger \sqcap \sqcup \uplus \wr \triangleleft \triangleright \lhd \rhd \unlhd \unrhd \diamond \Diamond \lozenge \bigtriangleup \bigtriangledown \triangle \Box \square \boxplus \boxminus \boxtimes \boxdot \divideontimes \ltimes \rtimes \leftthreetimes \rightthreetimes \curlyvee \curlywedge \dotplus \centerdot \intercal \doublebarwedge \barwedge \veebar \Yup \Ydown \Yleft \Yright \amalg \plusmn`
Breaks: `a \times b`, `A \cup B`, `x \pm y`, `P(A \cap B)`, `\oplus`, `\otimes`, `\wedge`, `\vee`, `\setminus`, `\circ`.

### 4.4 Arrows — ALL missing
`\to \rightarrow \leftarrow \leftrightarrow \Rightarrow \Leftarrow \Leftrightarrow \mapsto \longmapsto \longrightarrow \longleftarrow \longleftrightarrow \Longrightarrow \Longleftarrow \Longleftrightarrow \nearrow \searrow \swarrow \nwarrow \uparrow \downarrow \updownarrow \Uparrow \Downarrow \Updownarrow \hookrightarrow \hookleftarrow \rightleftharpoons \leftrightharpoons \rightrightarrows \leftleftarrows \rightleftarrows \leftrightarrows \twoheadrightarrow \twoheadleftarrow \rightarrowtail \leftarrowtail \curvearrowright \curvearrowleft \circlearrowright \circlearrowleft \Rrightarrow \Lleftarrow \rightsquigarrow \leftrightsquigarrow \leadsto \dashrightarrow \dashleftarrow \mapsto \longmapsto \Mapsto \xrightarrow \xleftarrow`
Breaks: `x \to \infty`, `f: A \to B`, `\lim_{x \to 0}`, `\Rightarrow`, `\Leftrightarrow`, `\uparrow`, `\mapsto`.

### 4.5 Operator names (predefined formulas in MicroTeX) — ALL missing
`\sin \cos \tan \cot \sec \csc \arcsin \arccos \arctan \sinh \cosh \tanh \coth \sech \csch \arcsec \arccsc \log \ln \lg \exp \lim \limsup \liminf \injlim \projlim \varinjlim \varprojlim \max \min \sup \inf \arg \ker \dim \hom \det \gcd \deg \Pr \bmod \pmod \mod \pod \operatorname`
Breaks: `\sin \theta`, `\log n`, `\lim_{x \to 0} f(x)`, `\max_{i}`, `\det(A)`, `\operatorname{tr}(A)`, `\gcd(a,b)`, `\exp(x)`, `\arg\min`.

### 4.6 Structure / delimiters — ALL missing
`\left \right \middle \left. \right| \big \Big \bigg \Bigg \bigl \bigr \Bigl \Bigr \biggl \biggr \Biggl \Biggr`
`\sqrt \sqrt[n] \surd \overbrace \underbrace \overleftarrow \underleftarrow \overrightarrow \underrightarrow \overleftrightarrow \underleftrightarrow \overline \underline \widehat \widetilde \overparen \underparen \overbrack \underbrack`
`\over \atop(infix) \choose \brace \brack \above \atopwithdelims \overwithdelims \abovewithdelims \genfrac \dfrac \tfrac \dbinom \tbinom \binom \cfrac \stackrel \overset \underset \substack`
Breaks: `\sqrt{x}`, `\sqrt[3]{x}`, `\left( \frac{a}{b} \right)`, `\left\{ … \right\}`, `\overline{AB}`, `\binom{n}{k}`, `{a \over b}`, `{n \choose k}`, `\underbrace{…}_{…}`, `\vec`, accents below.

### 4.7 Accents — ALL missing
`\hat \widehat \tilde \widetilde \bar \vec \dot \ddot \dddot \ddddot \breve \check \acute \grave \mathring \accent \underaccent \accentset \overset \underset \undertilde`
Breaks: `\hat{x}`, `\bar{x}`, `\vec{v}`, `\dot{x}`, `\ddot{x}`, `\tilde{n}`, `\widehat{AB}`, `\acute{e}`.

### 4.8 Other symbols — ALL missing
`\infty \partial \nabla \forall \exists \nexists \neg \lnot \top \bot \emptyset \varnothing \angle \measuredangle \sphericalangle \triangle \Box \Diamond \ell \hbar \hslash \imath \jmath \Re \Im \wp \aleph \beth \gimel \daleth \prime \backprime \backslash \ldots \cdots \vdots \ddots \iddots \colon \S \P \flat \natural \sharp \clubsuit \diamondsuit \heartsuit \spadesuit \dag \ddag \copyright \pounds \yen \euro \checkmark \maltese \therefore \because \square \blacksquare \blacktriangle \blacktriangledown \star \bigstar \smallint \textmu \degree`
Breaks: `\infty`, `x \to \infty`, `\partial f / \partial x`, `\nabla`, `\forall \varepsilon > 0`, `\exists`, `\emptyset`, `\neg`, `\ldots`, `\cdots`, `\prime`, `\aleph`.

### 4.9 Style / size / math-mode switches — ALL missing
`\displaystyle \textstyle \scriptstyle \scriptscriptstyle \tiny … \Huge \normalsize \large \Large \LARGE \huge`
`\mathop \mathord \mathbin \mathrel \mathopen \mathclose \mathpunct \mathinner \nolimits \limits \mathchoice`
Breaks: `\sum\limits_{i=1}^{n}` (extremely common), `\int\nolimits`, `\displaystyle\frac{…}{…}`, `\mathop{\mathrm{lim}}`.

### 4.10 Environments / alignment — ALL missing (`\begin` → UnknownCommand)
`matrix smallmatrix pmatrix bmatrix Bmatrix vmatrix Vmatrix cases array align aligned flalign alignat alignedat gather gathered multline split eqnarray tabular`
`\hline \multicolumn \multirow \cr \\ \hline \noalign \intertext \rowcolor \cellcolor \columncolor \newcolumntype`
Breaks: `\begin{pmatrix} a & b \\ c & d \end{pmatrix}`, `\begin{cases} x & x>0 \end{cases}`, `\begin{aligned} … \end{aligned}`.

### 4.11 Boxes / graphics / color / misc — ALL missing
`\mbox \hbox \vbox \fbox \boxed \framebox \raisebox \rule \phantom \hphantom \vphantom \smash \strut \kern \hspace \vspace \llap \rlap \clap \mathllap \mathrlap \mathclap \scalebox \rotatebox \resizebox \reflectbox \shadowbox \ovalbox \doublebox`
`\color \textcolor \colorbox \fcolorbox \definecolor \fgcolor \bgcolor`
`\tag \label \ref \eqref \quad(ok) \hfill \vfill \unicode \char \symbol \DeclareMathOperator \newcommand \renewcommand \newenvironment`
Breaks: `\boxed{E=mc^2}`, `\textcolor{red}{x}`, `\tag{1}`, `\phantom{x}`, `\fbox{…}`, `\hspace{2em}`.

### 4.12 Control-symbol commands — ALL missing
`\{ \} \\ \% \& \# \$ \_ \| \backslash \langle \rangle \lfloor \rfloor \lceil \rceil \lbrace \rbrace \vert \Vert \uparrow \downarrow \updownarrow \lgroup \rgroup \lmoustache \rmoustache \lbag \rbag \llbracket \rrbracket \lq \rq \textendash \textemdash \textdollar \textpercent \textampersand \underscore \mathsharp \matharobase`
`\ ` (control space) → name `" "`, not in cmd_map → UnknownCommand (TeX: unbreakable space).
Breaks: `\{x\}`, `\|v\|`, `\langle \phi \rangle`, `\lfloor x \rfloor`, `\text{a\%b}`.

### 4.13 What ztex DOES support (the complete list)
`\,` `\;` `\!` `\quad` `\qquad` — `\frac` `\atop` — `\text` `\mathrm` `\mathbf` `\mathbb` `\mathcal` `\mathfrak` `\mathsf` `\mathtt` — `\cdot` — `\sum` `\int` `\prod` `\coprod` `\bigcup` `\bigcap` `\bigsqcup` `\oint`.

Of these, `\atop`'s syntax is wrong (finding #2) and the six style commands are visual no-ops downstream (finding #5). Effectively **~17 commands render correctly**.

---

## 5. Role / codepoint handling

- The parser assigns **no role/class** to `char` atoms (makeChar → plain `.char` leaf, data 0; parser.zig:281-284). TeX assigns ord/bin/rel/open/close/punct/inner at math-list construction time; MicroTeX does the same via SymbolAtom types. ztex defers all of it to layout's `roleOfCp` (layout.zig:208-252), which infers from the codepoint at layout time.
- Consequence A: the unicode-input path works — literal `≤` (U+2264) → rel, `∈` (U+2208) → rel, `→` (U+2192) → rel, `+`/`−` → bin, `=` `<` `>` → rel, `(` `[` `{` → open, `)` `]` `}` → close, `,` `;` → punct, `∑` (U+2211) → op. So formulas written with literal unicode symbols render with correct spacing. This is the only escape hatch for the missing commands, and it's partial (fonts/metrics must still have the glyphs).
- Consequence B: the role table is a fixed ztex-owned list that diverges from plain.tex mathcodes in places:
  - `'` (0x27): not in any table → ord. TeX mathcode "8000 = prime (special-cased by the math scanner) — wrong glyph AND wrong role (finding #4).
  - `*` (0x2A): not in bin table → ord. TeX mathcode "2203 = Bin (renders `a * b` with bin spacing); ztex renders tight.
  - `!` (0x21) and `?` (0x3F): not in close table → ord. TeX mathcodes "5021 / "503F = class 5 (Close).
  - `&` `#` `$` `%` `~` `_` `^`: structural/special in TeX, ordinary ord chars here (or structural tokens for `_` `^`).
  - `:` (0x3A) → rel — matches TeX mathcode "303A. `+ - = < > , ; ( ) [ ] { }` all match plain.tex classes (bin/rel/punct/open/close); `/` `.` `|` → ord, matching TeX classes 0 (ord).
  - Big-op codepoints and `\cdot` override (data != 0 → nodeCp) are handled correctly.
- The parser-side roles that DO exist (node tags) are correct: `op` → BigOp, `space` → glue, `fraction`/`script`/`styled` composites report their first/last child's role downstream (layout.zig:256-279), and scripted big ops stay op-role. Matches TeX.

---

## 6. What matches TeX / MicroTeX (credit where due)

1. Atom tree shape for the supported subset: row/script/fraction/space/text/styled/op/group is a faithful subset of TeX's math list (ord_noad/op_noad/fraction_noad/…). The superflat encoding (contiguous child runs, token spans) is sound.
2. ScriptBits presence flags (sup=1, sub=2) and `[base, sup?, sub?]` child order — correct for both `x^2_3` and `x_3^2`.
3. Double-script → error (TeX: "Double superscript").
4. `\frac{num}{den}` → fraction node with line=true; `\atop{a}{b}` (its own syntax) → line=false. Correct node semantics.
5. Space widths \, \; \! \quad \qquad — exact TeX mu values.
6. `\cdot` → U+22C5 with bin role — correct.
7. Big-op set (8) mapped to correct codepoints and TeX limit behavior downstream (bigOpLimits).
8. Lexer: comment/whitespace handling, control-word vs control-symbol naming, UTF-8 validation, span provenance.
9. Errors are clean and specific (UnknownCommand, MissingArgument, MissingScript, DoubleScript, UnclosedGroup, UnexpectedRGroup).

---

## 7. Magnitude assessment

Test formulas against the 24-command set (whole formula rejected on any unknown command):

| Formula | Result |
|---|---|
| `x^2 + y^2 = z^2`, `E=mc^2`, `\frac{1}{2}`, `\sum_{i=1}^{n} i`, `\int_0^1 x\,dx`, `\sqrt…` → fails | works (except `\sqrt`) |
| `\pi r^2`, `\alpha + \beta`, `\sin x`, `\lim_{x\to 0}`, `a \leq b`, `a \in S`, `x \to \infty`, `\left(\frac{a}{b}\right)`, `\bar{x}`, `\hat{\theta}`, `f: A \to B` | **UnknownCommand → whole formula fails** |
| `f'(x)`, `x'`, `\mathbb{R}`, `\mathbf{x}` | renders, but wrong (baseline apostrophe / non-bold) |

Impact: the parse stage covers maybe 5–10% of the LaTeX command surface. The single highest-leverage fix is growing `cmd_map` to the MicroTeX symbol table (630 entries with classes — the data already exists in MicroTeX's `tex_symbols.res.cpp` and `TeXSymbols.xml`) plus the operator-name predefined formulas, `\left/\right`, `\sqrt`, `\limits/\nolimits`, and `\operatorname`. Second priority: fix `\atop` to TeX's infix syntax (or add `\over` and friends). Third: prime handling and the style-visual-no-op.
