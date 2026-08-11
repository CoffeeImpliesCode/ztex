# KaTeX 0.16.28 feature surface vs ztex — parity gap list

Date: 2026-08-14. READ-ONLY research (no source edits, no zig gates).
Grounding: KaTeX source at
`/nix/store/3si7yawkjxy9mfc2p7x2c865lz3hyx2x-katex-0.16.28/lib/node_modules/katex/src`
(functions/*.js, symbols.js, macros.js, environments/*.js) + `bin/katex` CLI
probes. ~260 CLI probes: **every command listed below as KaTeX-supported
parses in KaTeX 0.16.28** (probes marked FAIL produced zero). ztex side read
from `src/parse/parser.zig` (cmd_map 74 commands, symbol_map 183 codepoints,
delim_map), `src/atom.zig` (11 node tags), `src/layout/layout.zig` (11 layout
constructs), `src/layout/metrics.zig` (delim_ladder 16 stretchable delimiters).
Top-level style is hardcoded `.display` (`src/layout/root.zig`, `src/context.zig`).

KaTeX surface counts: 45 function modules; 543 math-mode symbol entries
(symbols.js: rel 238, textord 113, bin 69, mathord 51, open 13, close 15, op
20, accent 11, punct 4, inner 4, spacing 5); 338 macro definitions
(macros.js); 24 named environments (array.js/cd.js); 13 stretchy-delimiter
sizes in delimiter.js.

Legend: **SUPPORTED** = parse + layout match KaTeX semantics. **PARTIAL** =
parses but wrong/limited semantics. **MISSING** = unknown command in ztex.

## 1. Command-category table

| Category | KaTeX 0.16.28 surface | ztex | Status |
|---|---|---|---|
| Greek lowercase | 29 standard + variants (`\varepsilon \vartheta \varpi \varrho \varsigma \varphi`, `\digamma \varkappa \varcoppa \coppa \sampi \stigma`, `\omicron`, dotless `\imath \jmath`) | 29 standard + 6 variants + `\imath \jmath`; **no** `\digamma \varkappa \varcoppa \coppa \sampi \stigma \omicron` | PARTIAL |
| Greek uppercase | `\Gamma \Delta \Theta \Lambda \Xi \Pi \Sigma \Upsilon \Phi \Psi \Omega` + macro-aliases `\Alpha \Beta \Epsilon \Zeta \Eta \Iota \Kappa \Mu \Nu \Omicron \Rho \Tau \Chi` | the 11 distinct-shape ones only | PARTIAL |
| Relations (core) | `\leq \geq \neq \in \ni \notin \subset \supset \subseteq \supseteq \sim \simeq \cong \approx \propto \equiv \ll \gg \prec \succ \preceq \succeq \vdash \dashv \perp \parallel \mid \asymp \doteq \models \bowtie \frown \smile` + `\sqsubseteq \sqsupseteq \doteqdot \eqsim \circeq \triangleq \bumpeq \Bumpeq \between \pitchfork \Subset \Supset \sqsubset \sqsupset \subseteqq \supseteqq \subsetneq \subsetneqq \supsetneq \supsetneqq \gvertneqq \lvertneqq \precapprox \preccurlyeq \precnapprox \precneqq \precnsim \curlyeqprec \curlyeqsucc \gtrsim \lesssim \lessapprox \gtrapprox \gtrless \lessgtr \gtreqless \lesseqgtr \gtreqqless \lesseqqgtr \gtrdot \lessdot \thicksim \thickapprox \backsimeq \backsim \fallingdotseq \risingdotseq \eqcirc \approxeq` | core 38 only (has `\leqq \geqq`) | MISSING: ~70 relation variants (most of amsmath set) |
| Negated relations | `\not` (combining U+0338 overlay) + ~45 precomposed: `\nless \ngtr \nleq \ngeq \nleqslant \ngeqslant \nsubseteq \nsupseteq \nsubseteqq \nsupseteqq \nmid \nparallel \nshortmid \nshortparallel \nprec \nsucc \npreceq \nsucceq \nsim \ncong \napprox \nvdash \nvDash \nVdash \nVDash \ntriangleleft \ntriangleright \ntrianglelefteq \ntrianglerighteq \lnapprox \lneq \lneqq \lnsim \gnapprox \gneq \gneqq \gnsim \precnapprox \precneqq \precnsim \succnapprox \succneqq \succnsim` | only `\notin` | MISSING (whole family + `\not`) |
| Arrows (fixed) | ~60: single/double/left-right, `\mapsto \longmapsto \longrightarrow \longleftarrow \longleftrightarrow \Longrightarrow \Longleftarrow \Longleftrightarrow \leftarrowtail \rightarrowtail \twoheadrightarrow \twoheadleftarrow \rightleftarrows \leftleftarrows \rightrightarrows \leftrightarrows \leftrightharpoons \rightleftharpoons \rightsquigarrow \leftrightsquigarrow \looparrowleft \looparrowright \curvearrowleft \curvearrowright \circlearrowleft \circlearrowright \Lsh \Rsh \multimap \upharpoonleft \upharpoonright \downharpoonleft \downharpoonright \upuparrows \downdownarrows \nrightarrow \nleftarrow \nLeftarrow \nRightarrow \nleftrightarrow \nLeftrightarrow \dashrightarrow \dashleftarrow` | 28: base singles/doubles + `\mapsto \longmapsto` + 4 diagonals + 2 hooks + 4 harpoons | PARTIAL (missing ~35) |
| Extensible arrows | `\xrightarrow \xleftarrow \xleftrightarrow \xRightarrow \xLeftarrow \xLeftrightarrow \xmapsto \xhookleftarrow \xhookrightarrow \xrightharpoondown` (stretch with content) | — | MISSING |
| Binary ops | `\pm \mp \times \div \ast \star \circ \bullet \oplus \ominus \otimes \oslash \odot \wedge \vee \cup \cap \sqcup \sqcap \setminus \dagger \ddagger \diamond \wr \uplus \amalg \triangleleft \triangleright \bigcirc` + `\dotplus \divideontimes \ltimes \rtimes \leftthreetimes \rightthreetimes \boxplus \boxminus \boxtimes \boxdot \circledast \circledcirc \circleddash \barwedge \veebar \doublebarwedge \curlyvee \curlywedge \centerdot \intercal \Cap \Cup \doublecap \doublecup \smallsetminus \trianglelefteq \trianglerighteq \vartriangleleft \vartriangleright \lhd \rhd \unlhd \unrhd` | 31 core | PARTIAL (~35 missing) |
| Big operators | `\sum \prod \coprod \int \oint \bigcup \bigcap \bigsqcup \bigodot \bigoplus \bigotimes \biguplus \bigvee \bigwedge \iint \iiint \oiint \oiiint \iiiint \intop \smallint` (+ unicode literals) | 8: `\sum \prod \coprod \int \oint \bigcup \bigcap \bigsqcup` | PARTIAL |
| Delimiters (stretchable) | `( ) [ ] { } \langle \rangle \lfloor \rfloor \lceil \rceil | \Vert \backslash / . \lgroup \rgroup \lmoustache \rmoustache \lparen \rparen \lvert \rvert \lVert \rVert \uparrow \downarrow \updownarrow \Uparrow \Downarrow \Updownarrow \surd` (13 size ladders) | `( ) [ ] { } \langle \rangle \lfloor \rfloor \lceil \rceil \| \Vert \backslash / .` (8-step ladder, 16 glyphs) | PARTIAL |
| Delimiter sizing | `\left \right` (auto) + `\big \Big \bigg \Bigg` × `l m r` + `\middle` | `\left \right` auto only; **no** `\big`-family, **no** `\middle` | PARTIAL |
| Accents (fixed) | `\hat \bar \vec \dot \ddot \tilde \acute \grave \breve \check \mathring` + short forms `\' \` \^ \~ \= \. \u \v \H \r \c` + `\textcircled \dddot \ddddot \underbar` | `\hat \bar \vec \dot \ddot \tilde` (6) | PARTIAL |
| Accents (stretchy) | `\widehat \widetilde \widecheck \overleftarrow \overrightarrow \overleftrightarrow \underleftarrow \underrightarrow \underleftrightarrow \utilde \underlinesegment \undergroup` | — | MISSING |
| Over/under lines | `\overline \underline` | — | MISSING |
| Braces | `\overbrace \underbrace` (stretchy) | — | MISSING |
| Fractions | `\frac \over \atop \choose \dfrac \tfrac \cfrac \binom \dbinom \tbinom \genfrac \above \brack \brace \abovefrac \atopfrac \abovewithdelims \atopwithdelims \overwithdelims` | `\frac \over \atop \choose` (infix + braced) | PARTIAL |
| Stacks | `\overset \underset \stackrel \substack` | — | MISSING |
| Styles | `\displaystyle \textstyle \scriptstyle \scriptscriptstyle` (forced subtree styles) | — | MISSING (layout has internal Style enum, top-level fixed `.display`) |
| Fonts | `\mathrm \mathbf \mathbb \mathcal \mathfrak \mathsf \mathtt \mathit \mathnormal \boldsymbol \bm \mathsfit \pmb \bf \rm \it \cal \sf \tt` | `\mathrm \mathbf \mathbb \mathcal \mathfrak \mathsf \mathtt` (7) | PARTIAL (`\mathit` = default italic, trivial; `\boldsymbol/\pmb` need bold-italic metrics) |
| Text | `\text \textnormal \textrm \textsf \texttt \textit \textbf \textup \textmd \emph \hbox \mbox` | `\text` (roman, raw-span) | PARTIAL |
| Spacing | `\, \; \! \: \quad \qquad \enspace \enskip \thinspace \medspace \thickspace \negthinspace \negmedspace \negthickspace \hspace \hspace* \hskip \kern \mkern \mskip \nobreakspace \space \allowbreak \nobreak` | `\, \; \! \quad \qquad` (fixed em) | PARTIAL (`\:` and `\ ` missing; no length-arg commands) |
| Phantom/smash | `\phantom \hphantom \vphantom \smash \mathstrut` | — | MISSING |
| Operator words | `\sin \cos \tan \cot \sec \csc \arcsin \arccos \arctan \sinh \cosh \tanh \coth \log \ln \lg \exp \lim \limsup \liminf \max \min \sup \inf \arg \ker \dim \det \gcd \Pr \hom \deg` + `\argmax \argmin \injlim \projlim \varinjlim \varprojlim \varliminf \varlimsup \ch \cosec \cotg \ctg \cth \arcctg \arctg` | 38 names incl. `\sech \csch \arcsec \arccsc \mod \bmod`; limit-taking set matches TeX (`\lim \max \min \sup \inf \det \gcd \Pr \arg \ker \dim \hom \deg \limsup \liminf`) | PARTIAL |
| Operator syntax | `\operatorname` (space-aware, `\operatorname*` = `\operatornamewithlimits`), `\mathop` (explicit atom class) | `\operatorname` aliased to `\mathrm` (braced arg, spaces lost, no `*`) | PARTIAL |
| Limits modifiers | `\limits \nolimits \displaylimits` (override op default) | consumed as no-ops; per-op default always wins | PARTIAL (**wrong for `\int\limits`**) |
| Mod/pmod | `\bmod \mod \pmod \pod` (TeX spacing) | `\bmod \mod` as opname words; no `\pmod \pod` | PARTIAL |
| Colon relations | `\coloneqq \Coloneqq \Coloneq \coloneq \eqcolon \Eqcolon \Eqqcolon \eqqcolon \dblcolon \vcentcolon \ratio \colonapprox \Colonapprox \coloncolonequals \coloncolon \Colonsim \colonsim \simcolon \simcoloncolon \approxcolon \approxcoloncolon \colonminus \minuscolon \minuscoloncolon \equalscolon \equalscoloncolon \ordinarycolon` (~28) | `\colon` (ASCII `:` glyph) | PARTIAL |
| Atom classes | `\mathord \mathop \mathbin \mathrel \mathopen \mathclose \mathpunct \mathinner \@binrel` | — | MISSING (role override; layout has roleOfCp machinery) |
| Environments | `matrix pmatrix bmatrix Bmatrix vmatrix Vmatrix` (+`*`), `smallmatrix subarray array darray cases dcases rcases drcases`, `align align* aligned split alignat alignat* alignedat`, `gathered gather gather*`, `equation equation*`, `CD`; row sep `\\ \cr`, `\hline \hdashline`, `\arraystretch`, `\tag \notag \nonumber` | — (no `\begin`/`\end` at all) | MISSING |
| Math choice | `\mathchoice{D}{T}{S}{SS}` (style-dependent subtree) | — | MISSING |
| Cancel/rule overlays | `\cancel \bcancel \xcancel \sout \phase \boxed \fbox \fcolorbox \colorbox \color \textcolor` | — | MISSING |
| Misc layout | `\raisebox \vcenter \rule \llap \rlap \mathllap \mathrlap \mathclap` | — | MISSING |
| Macros/programming | `\def \gdef \edef \xdef \let \futurelet \newcommand \renewcommand \providecommand \relax \char \expandafter \noexpand` | — | MISSING |
| Web extras | `\href \url \includegraphics \verb \htmlClass \htmlId \htmlStyle \htmlData \html@mathml` | — | MISSING (low priority) |
| Misc symbols | `\infty \partial \nabla \prime \ldots \cdots \vdots \ddots \ell \Re \Im \wp \aleph \forall \exists \neg \top \bot \emptyset \angle \triangle \square \surd \clubsuit \diamondsuit \heartsuit \spadesuit \hbar \therefore \because` + `\nexists \backprime \beth \gimel \daleth \complement \Finv \Game \hslash \mho \eth \flat \natural \sharp \deg \backepsilon \varpropto \smallfrown \smallsmile \measuredangle \sphericalangle \varnothing \blacklozenge \blacksquare \blacktriangle \blacktriangledown \blacktriangleleft \blacktriangleright \bigstar \lozenge \maltese \checkmark \diagup \diagdown \yen \pounds \S \P \dag \ddag \degree \angle \copyright \textellipsis \ldots` | 46 core (`\varnothing` yes, `\hbar \therefore \because` yes) | PARTIAL (~50 missing) |
| Punctuation | `\colon \ldotp \cdotp \mathellipsis` | `\colon` only | PARTIAL |
| Primes | `'` `''` `'''`→ U+2032/33/34, `\prime`, `\backprime` | `'`-chains + `\prime`; no `\backprime` | PARTIAL |
| `\sqrt` | `\sqrt[n]{x}` (stretchy radical + vinculum) | `\sqrt[n]{x}` | SUPPORTED |

SUPPORTED in full: `\frac \over \atop \choose \sqrt \left/\right` (16 delimiters), `\text`, `\, \; \! \quad \qquad`, `\cdot`, 8 big ops with display limits, 38 operator words, 6 accents, 7 font styles, 183 symbols.

## 2. Prioritized gap list (frequency × difficulty → roadmap)

Difficulty: E = easy (table entry / small layout tweak), M = medium (new
layout construct), H = hard (new subsystem). Frequency: real-world inline +
display math.

| # | Gap | Freq | Diff | Notes |
|---|---|---|---|---|
| 1 | `\overline` / `\underline` | very high | M | Rule over/under a box. ztex already draws rules (fraction line, sqrt vinculum) — reuse axis/rule machinery; new atom tag + layout fn. |
| 2 | `\not` + negated relations | very high | E–M | `\not=` `\not\subset` `\not\equiv` are everywhere. `\not` = combining U+0338 overlay (KaTeX/unicode-math approach). Then add ~45 precomposed ams relations as symbol entries (glyphs exist in LM Math). |
| 3 | `\dfrac`/`\tfrac` + `\displaystyle`/`\textstyle`/`\scriptstyle`/`\scriptscriptstyle` | very high | M | Style forcing on a subtree. Layout already carries a Style enum; need parser commands that stamp the style and a styled-style atom propagating to children (and to scripts, cramped). `\dfrac` = `\frac` in forced display. |
| 4 | `\binom`/`\dbinom`/`\tbinom` (+ `\genfrac` as the general form) | high | M | `\frac` without rule + parens. `\genfrac{ld}{rd}{thickness}{style}{n}{d}` covers `\binom \dfrac \tfrac \above` — one parser cmd, one layout path. |
| 5 | `\big`/`\Big`/`\bigg`/`\Bigg` (+`l/m/r`) + `\middle` | high | M | 8-step delim ladder already exists in metrics — just expose sizes 1–4 with the ladder step it maps to; `\middle` needs parser support inside `\left…\right` (delimiter node with 3+ children). |
| 6 | `\overset`/`\underset`/`\stackrel` | high | M | Two stacked boxes with alignment; the script/limits machinery (layoutScript/layoutOpLimits) already stacks boxes — factor a small stack fn. |
| 7 | matrix/cases/aligned environments | very high (display) | H | Array layout: rows/cols, `&`/`\\` parsing, column gaps, `\hline`, delimiters around matrix/pmatrix/cases. New `array` atom + layout fn + parser `\begin/\end` support. Single biggest display-math gap. |
| 8 | `\operatorname` (proper) + `\operatornamewithlimits` | high | E | Currently aliased to `\mathrm`: not a mathop (wrong glue role), loses spaces, no `*` limits variant. Make it an opname-style node with space-preserving text run + limits flag. |
| 9 | `\limits`/`\nolimits`/`\displaylimits` overrides | medium | E | ztex consumes them as no-ops → `\int\limits_0^1` renders beside-scripts (wrong; TeX/KaTeX put them over/under). Store an override flag on the script node; layout uses it instead of the op default. |
| 10 | `\pmod`/`\pod` (+ `\mod` spacing) | medium | E | `\pmod n` = " (mod n)" — needs parens + spacing, not an opname. Trivial. |
| 11 | `\phantom`/`\vphantom`/`\hphantom`/`\smash` | medium | E | Layout-only boxes (measure child, draw nothing; smash → zero height/depth). No parse complexity. |
| 12 | Text font family: `\textit \textbf \textsf \texttt \textnormal \textrm \textup \textmd \emph` + `\mathit \mathnormal` | medium | E–M | Font tables (lmroman_regular/italic) exist; map `\textrm`→roman, `\textit`→italic, `\textbf`→bold… `\mathit` ≈ default italic (no-op). |
| 13 | `\boldsymbol`/`\bm`/`\pmb` | medium | M | Bold-italic: needs bold-italic metrics/font data (LM Math bold or synthetic stroke). `\pmb` = fake bold (overlay strokes) — fallback path. |
| 14 | `\substack` | medium | M | Stacked rows in script style for `\sum_{\substack{i\\j}}`. Needs mini row-stack (same machinery as #6, or tiny array). |
| 15 | `\mathchoice` | medium | M | Style-dependent subtree: parse 4 args, lay out the one matching current style. Enables macro parity (`\dfrac` etc. in package code). |
| 16 | Stretchy accents + braces: `\widehat \widetilde \overrightarrow \overleftarrow \underbrace \overbrace` | medium | M–H | Stretchy glyph assembly (ztex already builds a stretchy radical for `\sqrt`); wide hats/tildes/braces need LM Math variants/extender or drawn paths. |
| 17 | `\hspace`/`\hskip`/`\kern`/`\mkern`/`\mskip` + `\:` `\enspace` `\thinspace` `\medspace` `\thickspace` `\negthinspace`… | medium | E | Parse a length arg (pt/em/mu units), emit a space atom. `\:` (4/18 em) and `\ ` (control space) are the frequent ones — just table entries. |
| 18 | More big ops: `\bigoplus \bigotimes \bigodot \biguplus \bigvee \bigwedge \iint \iiint \oiint \oiiint \iiiint \intop \smallint` | medium | E–M | Symbol/op table entries + display glyphs. `\iint`-family needs double-glyph drawing or dedicated ink entries. `\intop` = limits-`\int`; `\smallint` = text-size `\int`. |
| 19 | Atom-class overrides `\mathbin \mathrel \mathop \mathord \mathopen \mathclose \mathpunct \mathinner \@binrel` | medium | E–M | Role override on a subtree — layout roleOfCp/leftRole/rightRole already classify; add a node that forces a role. Power-tool for package-compatible macros. |
| 20 | Colon relations `\coloneqq \eqqcolon \dblcolon …` (~28) | medium (CS math) | E | Compose `:` + `=` with rel role, or real glyphs (U+2254/U+2255 etc. exist in LM Math). Mostly a macro/table expansion. |

Also worth tracking (below top-20): extensible arrows `\xrightarrow` (M–H,
stretchy-arrow construction), user macros `\def/\newcommand` (H, macro
expansion — KaTeX's whole gullet; matters for hand-written docs), `\cancel
\sout \boxed` (E, rule overlays), `\tag` (E, display numbering), arrow
delimiters in `\left` (`\lgroup \lvert \lVert \uparrow …`, E–M, ladder
extension), `\raisebox \rule \vcenter` (E–M), `\llap/\rlap/\mathllap`-family
(E–M), remaining ~35 arrows / ~35 binary ops / ~50 misc symbols (E, table
entries — pure coverage), `\ldots`-family dots macros (E), `\left. \right.`
already OK, `\middle` folded into #5.

## 3. XeTeX inline-math goodies

Commands the assignment flagged as "TeX commands not commonly in KaTeX" —
**verified against KaTeX 0.16.28: KaTeX supports all of them** (CLI probe:
`\limits \nolimits \displaylimits \operatorname \operatornamewithlimits
\dfrac \tfrac \cfrac \overset \underset \stackrel \substack \genfrac
\mathchoice \hbox \mbox \coloneqq \not \pmod \pod \middle \big… \mathop`
all parse OK). So they are **ztex parity targets regardless of engine**; the
useful XeTeX-specific framing is what ztex does *differently* from both:

1. **`\limits`/`\nolimits`/`\displaylimits`** — real overrides in TeX/KaTeX.
   ztex eats them as no-ops, so `\int\limits_0^1` and `\sum\nolimits_i` both
   render the default (`\int` beside, `\sum` over/under) — wrong for the
   explicit forms. Highest-impact inline-math behavioral bug in this list.
2. **`\operatorname`** — TeX/KaTeX: a `\mathop` whose content is set in text
   mode (spaces survive), optional `*` = limits. ztex: alias of `\mathrm`
   (braced arg only, spaces dropped, ordinary role → wrong glue).
3. **`\mathchoice`** — the engine behind style-dependent definitions
   (`\dfrac` in LaTeX is `\mathchoice`-based). Needed before user macros can
   be compatible.
4. **`\substack`** — `\sum_{\substack{i\le n\\ j\le m}}` is idiomatic inline
   math; needs stacked script rows (script-style stack).
5. **`\hbox`/`\mbox`** — classic inline text escape; ztex has `\text` only.
   `\hbox` differs from `\text` in TeX (no space handling); KaTeX treats
   both as `\text`.
6. **`\dfrac`/`\tfrac`/`\cfrac`** — style-forcing fractions; ztex needs the
   style-forcing machinery of gap #3.
7. **`\coloneqq` family** — mathtools colon-relations, now standard in
   papers; KaTeX composes from `:`/`=`; XeTeX+unicode-math uses real glyphs
   (U+2254). Either approach works in ztex.
8. **`\not`** — TeX primitive (negation overlay); KaTeX implements it as
   U+0338 combining overlay (same as unicode-math). ztex has only
   precomposed `\notin`.
9. **`\bmod`/`\mod`/`\pmod`/`\pod`** — TeX spacing variants. ztex's
   `\bmod`/`\mod` render as roman words but with op-role spacing, not TeX's
   binary/relation spacing; `\pmod \pod` absent.
10. **`\displaystyle`/`\textstyle`… switches** — XeTeX allows changing style
    mid-formula (`\displaystyle\sum`); KaTeX same. ztex: fixed `.display`.

Plain-TeX/XeTeX primitives that even KaTeX lacks or degrades (for reference,
mostly not worth chasing): `\everymath`, `\mathcode`/`\delcode`/`\mathchardef`,
`\nonscript` glue suppression (KaTeX parses `\nonscript` but only as a
kern-guard), `\penalty`/`\leaders`, `\mathpalette` (KaTeX: expand-only
macro), `\mkern` in mu units (KaTeX: supported), `\` control space
(KaTeX: supported via `\ `). The genuinely useful XeTeX-only item for
*inline* math is `\limits` semantics (#1) plus `\mskip`/`\mkern` fine
spacing; everything else in this section is already covered by KaTeX.

## 4. Method / verification appendix

- KaTeX source extraction: `names:` arrays in functions/*.js (45 modules),
  `defineSymbol` group tags in symbols.js (543 math entries),
  `defineMacro` in macros.js (338), `defineEnvironment` in
  environments/array.js + cd.js (24 envs), `delimiters` size tables in
  delimiter.js.
- CLI grounding: every command named above was probed with
  `katex '<cmd>' --output html`; failures = 0. Sampled all 24 environments
  (single- and multi-row bodies), all delimsizing sizes, macro defs
  (`\def\foo{x}\foo`), `\begin{matrix}a&b\\c&d\end{matrix}`,
  `\operatorname{arg max}`, `\int\limits_0^1`, `\not\subset`, `\substack`,
  `\coloneqq`, `\mathchoice`, `\genfrac`, `\cfrac[l]`, `\xrightarrow{n}`,
  `\underbrace{a+b}_{c}`, `\text{hi}_{1}`, `\left\uparrow…\right\downarrow`.
- ztex side: read of parser.zig (cmd_map/symbol_map/delim_map/parseRow/
  parseScripts/parseCommand), atom.zig (Tag enum), layout.zig (layoutInner
  dispatch + layout* fns), metrics.zig (delim_ladder 16 glyphs, accent_attach
  rows). No source edits, no zig gates run.
- Known-verifiable ztex absences (grep count 0 across src/parse): `overset
  underset overline underline overbrace underbrace binom dbinom tbinom
  dfrac tfrac cfrac genfrac displaystyle textstyle scriptstyle begin middle
  hspace hskip kern mkern mskip phantom smash mathchoice pmod pod not pmb
  mathop substack bigl Bigg iint oiint smallint intop mathit mathnormal
  mathbin mathrel vcenter raisebox rule boxed cancel color`.
