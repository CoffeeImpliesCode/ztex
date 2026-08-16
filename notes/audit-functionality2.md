# Audit: functionality gaps (lens 2b — what's still missing vs TeX/KaTeX)

Date: 2026-08-16. READ-ONLY audit. Evidence: grep/read of `src/parse/parser.zig`
(cmd_map 155-276, mathstyle_map ~262, env_kind_map 2075-2084, text fn 1511,
parseScripts/limits 1006, binom 1343, genfrac 1374, mathchoice 1497, overunder
1643, substack 1660, parseBegin 1699, middle 2000, not ~1608), `src/layout/layout.zig`
(layoutText 3643, text_space_em 0.302 @3833, big_ladder_idx @43, layoutSubstack 1206),
`src/atom.zig`, `src/svg.zig` (draw.Color + parseColorChecked 194). Cross-checked
against notes/katex-features.md (snapshot 2026-08-14) and the 10 feat-*.md notes.

## 0. CRITICAL CONTEXT: the katex-features.md snapshot is stale

It was written 2026-08-14; ~10 features have landed since. Rows it lists as
MISSING are now DONE (feat notes exist): `\begin/\end` envs (feat-envs),
`\substack` (feat-substack), `\binom`+`\genfrac` (feat-binom), `\operatorname`+
`*` (feat-operatorname), `\mathchoice` (feat-mathchoice), `\big`..`\Bigg`+
`\middle` (feat-big), `\not`+precomposed (feat-not), `\overline/\underline`
(feat-overline), `\dfrac/\tfrac/\cfrac`+style switches (feat-styles),
`\limits/\nolimits/\displaylimits` (feat-limits). `\text` width is ALSO done:
layoutText emits 0.302em interword glue for `~`/space/`\ ` + escapes + text
accents (layout.zig:3643,3833). Nested envs work (parseBegin comment: envs,
groups, scripts, `\left..\right` all nest in a cell). Env set = 9:
matrix/pmatrix/bmatrix/Bmatrix/vmatrix/Vmatrix/cases/aligned/array
(env_kind_map parser.zig:2075).

## 1. Still-missing gaps (grep = 0 across src/ unless noted)

| Gap | Evidence | Value | Effort |
|---|---|---|---|
| `\overset \underset \stackrel` | no cmd/symbol entry | HIGH | M |
| `\underbrace \overbrace` | no entry (stretchy brace) | HIGH | M-H |
| `\phantom \hphantom \vphantom \smash` | no entry | HIGH | E |
| `\hspace \hskip \kern \mkern \mskip` + `\:` `\ ` `\enspace` `\negthinspace`… | cmd_map has only `\, \; \! \quad \qquad` (parser.zig:156-160); `\:` `\ ` absent | HIGH | E |
| `\boxed \fbox \fcolorbox \colorbox \color \textcolor` | no entry; svg.zig HAS draw.Color/parseColorChecked (infra!) | HIGH (boxed) / MED (color) | E-M |
| `\dbinom \tbinom` | no entry; `\binom`+`\genfrac` exist (parser.zig:1343) — style-forced binoms | MED | E |
| Stretchy accents `\widehat \widetilde \widecheck \overrightarrow \overleftarrow \underrightarrow…` + short forms `\' \` \^` | accents = 6 fixed only (dot hat bar vec ddot tilde, parser.zig:1177-1183) | MED-HIGH | M-H |
| Extensible arrows `\xrightarrow \xleftarrow …` (10) | no entry | MED | M-H |
| Big ops: `\bigoplus \bigotimes \bigodot \biguplus \bigvee \bigwedge \iint \iiint \oiint \intop \smallint` | cmd_map has 8: sum int prod coprod bigcup bigcap bigsqcup oint (parser.zig:174-187) | MED | E-M |
| Matrix extras: `\hline \hdashline \arraystretch` | no entry; array colspec `|` handled (parser.zig:1848) but hline missing | MED | E-M |
| Atom-class overrides `\mathop \mathbin \mathrel \mathord \mathopen \mathclose \mathpunct \mathinner \@binrel` | no entry; roleOfCp/leftRole/rightRole exist in layout | MED | E-M |
| Colon relations `\coloneqq \eqqcolon \dblcolon \vcentcolon…` (~28) | no entry; `\colon` symbol exists | MED (CS) | E |
| Text font family `\textit \textbf \textsf \texttt \textnormal \textrm… \mathit \mathnormal \boldsymbol \bm \pmb` | cmd_map has 7 styles (mathrm..mathtt, parser.zig:169-173); no text-fam, no bold-italic | MED | E-M |
| `\tag \notag \nonumber` | no entry | MED-LOW | E |
| Misc symbols (~50: `\nexists \beth \gimel \daleth \Finv \Game \hslash \mho \eth \flat \natural \sharp \backepsilon \varpropto \blacklozenge \bigstar \lozenge \checkmark \diagup \yen \pounds \S \P \dag \ddag …`) | symbol_map 183 cps, core 46 present | LOW | E |
| Remaining arrows (~32: tails, harpoons, `\nrightarrow` family) + bin ops (~35: `\dotplus \ltimes \rtimes \boxplus \circledast \Cap \Cup \lhd \unlhd…`) | 28 arrows / 31 binops present | LOW | E |
| `\raisebox \vcenter \rule \llap \rlap \mathllap \mathrlap \mathclap` | no entry | LOW | E-M |
| `\cancel \bcancel \xcancel \sout \phase` | no entry | LOW-MED | M |
| Macros `\def \gdef \edef \xdef \let \newcommand \renewcommand \relax \char \expandafter` | no entry (no macro engine) | MED (hand docs) | H |
| Web extras `\href \url \verb \includegraphics` | no entry | LOW | H |
| `\backprime`; `\mathring \acute \grave \breve \check` accents; `\dddot \ddddot \underbar` | no entry | LOW | E |
| Extra `\left` delimiters (`\lgroup \rgroup \lvert \rvert \lVert \rVert \uparrow \downarrow \updownarrow …`) | delim_map/ladder: 16 glyphs 8-step (big_ladder_idx layout.zig:43) | LOW-MED | E |

## 2. Partial rows from katex-features.md that STILL don't exist (the ask)

- Over/under lines → DONE (`\overline/\underline`, feat-overline). Braces
  (`\overbrace/\underbrace`) NOT done.
- Stacks → `\substack` DONE (feat-substack); `\overset/\underset/\stackrel`
  NOT done — the highest-value remaining stack gap.
- Delim sizing → `\big`-family + `\middle` DONE (feat-big). `\middle.`/`\big.`
  null-delim behavior matches.
- Styles → DONE (feat-styles). Note: top-level style still hardcoded
  `.display` (src/layout/root.zig) — style switches work INSIDE rows only.
- Fonts → 7 math styles DONE; `\mathit/\mathnormal/\boldsymbol/\bm/\pmb`
  NOT done.
- Text → `\text` DONE incl. width/escapes; `\textit/\textbf/\textsf/...`
  NOT done.
- Spacing → `\, \; \! \quad \qquad` only; `\:`/`\ ` (control space)/length
  args NOT done.
- Phantom/smash → NOT done.
- Operator syntax → `\operatorname` DONE (real mathop, `*` limits).
- Limits modifiers → DONE (force/force_beside bits, parser.zig:1006-1025).
- Mod/pmod → DONE (`\bmod \mod \pmod \pod`, parser.zig:1883-1955).
- Colon relations → NOT done.
- Atom classes → NOT done.
- Environments → 9 DONE; missing smallmatrix/dcases/rcases/drcases/gather/
  alignedat/align/split/equation/CD + `\hline \tag`.
- Math choice → DONE.
- Cancel/rule overlays → NOT done (`\boxed` highest).
- Misc layout (`\raisebox \rule \llap...`) → NOT done.

## 3. Top-5 missing features by value (frequency × difficulty)

1. **`\overset`/`\underset`/`\stackrel`** (HIGH, M) — annotation stacks are
   everywhere (`\overset{!}{=}`, `\underset{\theta}{\arg\max}`,
   `\stackrel{\text{def}}{=}`). All machinery exists: layoutSubstack stacks
   rows, layoutOverUnder draws rules, layoutScript stacks boxes. Factor a
   two-box stack fn. Highest ratio of value to effort left in the parser.
2. **`\phantom`/`\vphantom`/`\hphantom`/`\smash`** (HIGH, E) — alignment
   workhorse in real documents; trivially easy: layout measures the child and
   emits an empty box (smash → zero height/depth). One parser cmd, one layout
   path, no metrics work.
3. **`\hspace`/`\kern`/`\mkern` + `\:`/`\ `/`\enspace`/`\negthinspace`…**
   (HIGH, E) — fine spacing is a daily inline-math need; ztex has only 4 fixed
   kerns. `\:` (4/18em) and `\ ` (control space, 0.302em text space) are pure
   table entries; length-arg commands need one dim-parse helper (pattern
   exists: parseGenfracThickness parser.zig:1439). Also fixes `\,`-only
   handling of `\negmedspace`-style pairs.
4. **`\underbrace`/`\overbrace`** (HIGH, M-H) — annotated grouping in display
   math (formula explanations, piecewise proofs). Stretchy brace assembly via
   LM Math variant/extender ladder (ztex already resolves variant ladders for
   fences + the sqrt radical); needs a brace glyph path + the annotation
   script attach (reuse script/limits placement).
5. **`\boxed` + `\color`/`\textcolor`/`\colorbox`** (HIGH/MED, E-M) —
   `\boxed{...}` is the proof-annotation standard; a rule-rect already exists
   (fraction rule, overline) and svg.zig already has draw.Color +
   parseColorChecked (parser.zig never calls it — no \color command). Boxed =
   rect around child box; color = Color through Box → svg fill. Both are
   contained; the infra was built for them.

Honorable mentions: `\dbinom/\tbinom` (E, once `\binom` style-forcing exists),
`\hline/\arraystretch` (E-M, completes the env row work), `\tag` (E, display
numbering), atom-class overrides `\mathop/\mathbin/\mathrel` (E-M, unlocks
package-compatible macros), `\coloneqq` family (E, CS papers), `\bigoplus`-
family big ops + `\iint`-family (E-M, table entries), `\widehat/\widetilde`
(M-H, stats notation).

## 4. Method appendix

- Absence = grep of the name across src/parse + src/layout + src/atom.zig
  matched zero command-table entries (comment-only matches excluded).
- Feature presence anchored to parser.zig cmd_map/symbol_map/env_kind_map
  reads (lines cited above) + the 10 feat-*.md notes.
- No source edits, no zig gates run (per audit constraints).
