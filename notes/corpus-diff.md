# ztex vs XeTeX: broad-corpus layout divergence (10pt display)

Run 2026-08-12. Empirical sweep of 50 formulas (36 command corpus + 14 Unicode-symbol corpus)
at 10pt base, display style (`\[...\]` for XeTeX; ztex renders `.display` natively).
Data in `/tmp/cmp2/` (`ztex_{i}.json`, `xetex_{i}.json`, `res_{i}.json`, `*_u{i}.json`).
Tool: `compare_engines.py --ours ztex --ref xetex --baseline first-top` (dx>0 ours right, dy>0 ours up, dxi=dx/ref size).

**Key result: two dominant divergences — (1) `\int` limits stacked over/under instead of beside, and
(2) the `glyphEstimate` fallback width (0.5em = 5pt) for every relation/bin symbol not in the exact
metric table. Every style (script/text/frac size) matches (`style_mismatches = 0` everywhere; ratio 1.00).**

## Corpus 1 — command corpus (ztex + XeTeX both take the LaTeX form)

| formula | feature | pairs | un (ours/ref) | mean\|dx\| | max\|dx\| | max\|dy\| | max dxi |
|---|---|---|---|---|---|---|---|
| \\sum_{i=1}^{n} x_i | big-op/limit | 7 | 0/0 | 0.481 | 1.531 | 0.075 | 0.219 |
| \\prod_{k=1}^{m} x_k | big-op/limit | 7 | 0/0 | 0.616 | 1.455 | 0.091 | 0.209 |
| \\int_0^1 x\\,dx | big-op/limit | 4 | 2/1 | 8.225 | 9.963 | 2.463 | 1.429 |
| \\bigcup_{i=1}^{n} A_i | big-op/limit | 6 | 1/1 | 0.745 | 1.531 | 0.075 | 0.219 |
| \\bigcap_{i=1}^{n} A_i | big-op/limit | 6 | 1/1 | 0.745 | 1.531 | 0.075 | 0.219 |
| \\frac{1}{2} | frac | 2 | 0/0 | 0.000 | 0.000 | 0.051 | 0.000 |
| \\frac{a+b}{c-d} | frac | 6 | 0/0 | 0.030 | 0.066 | 0.051 | 0.007 |
| \\frac{x^2}{y^2} | frac+sup | 4 | 0/0 | 0.011 | 0.021 | 0.520 | 0.003 |
| \\frac{\\frac{a}{b}}{c} | frac/nested | 3 | 0/0 | 0.127 | 0.319 | 0.067 | 0.032 |
| \\frac{x_i}{n} | frac+sub | 3 | 0/0 | 0.075 | 0.203 | 0.052 | 0.020 |
| x^2 | sup | 2 | 0/0 | 0.011 | 0.021 | 0.016 | 0.003 |
| x_2 | sub | 2 | 0/0 | 0.011 | 0.021 | 0.005 | 0.003 |
| x_i^2 | sub+sup | 3 | 0/0 | 0.014 | 0.021 | 0.016 | 0.003 |
| x^{2y} | sup | 3 | 0/0 | 0.157 | 0.450 | 0.016 | 0.064 |
| x^2y^2 | sup/chain | 4 | 0/0 | 0.224 | 0.448 | 0.016 | 0.061 |
| x^{i_j} | sup+sub/chain | 3 | 0/0 | 0.135 | 0.385 | 0.038 | 0.077 |
| a \\cdot b | bin | 3 | 0/0 | 0.025 | 0.046 | 0.000 | 0.005 |
| a\\cdot b + c | bin | 5 | 0/0 | 0.051 | 0.109 | 0.000 | 0.011 |
| (a+b) | paren | 5 | 0/0 | 0.046 | 0.096 | 0.000 | 0.010 |
| [a,b] | paren | 5 | 0/0 | 0.036 | 0.067 | 0.000 | 0.007 |
| \\frac{1}{2}(x+y) | frac+paren | 7 | 0/0 | 0.333 | 0.572 | 0.051 | 0.057 |
| x + y | bin | 3 | 0/0 | 0.032 | 0.068 | 0.000 | 0.007 |

### Corpus 1 parse failures (ztex `UnknownCommand`)

| formula | reason |
|---|---|
| \\leq, \\ne, \\in, \\subseteq, \\colon, \\to, \\sim | ALL relation commands absent from parser `cmd_map` (`src/parse/parser.zig`) |
| \\left( ... \\right) | no `\\left`/`\\right` commands |
| \\alpha, \\Gamma, \\pi (any Greek cmd) | no Greek command names in `cmd_map` |
| \\pm, \\infty | no `\\pm`/`\\infty` commands |
| \\int\\limits_0^1 | no `\\limits` command (verified separately) |

**Consequence:** the parser recognises a dozen big-ops + \\frac/scripts/spaces but **no relation, Greek,
or sizing command**. The literal Unicode codepoints (≤ ≠ ∈ ⊆ → ∼ ± α Γ π ∞) DO lex as ordinary
printable runs and lay out correctly — so every command gap has a workable literal-Unicode path
that the metrics gap below then mis-spaces.

## Corpus 2 — Unicode-symbol corpus (ztex literal Unicode, XeTeX LaTeX command)

| ztex input (→ XeTeX) | feature | pairs | un | mean\|dx\| | max\|dx\| | max dxi |
|---|---|---|---|---|---|---|
| a ≤ b (\\le) | relation | 3 | 0/0 | 0.913 | 2.709 | 0.272 |
| a ≠ b (\\ne) | relation | 2 | 2/1 | 1.354 | 2.709 | 0.272 |
| x ∈ S (\\in) | relation | 3 | 0/0 | 0.544 | 1.599 | 0.161 |
| A ⊆ B (\\subseteq) | relation | 3 | 0/0 | 0.913 | 2.699 | 0.271 |
| a → b (\\to) | relation | 3 | 0/0 | 1.651 | 4.923 | 0.494 |
| x ∼ y (\\sim) | relation | 3 | 0/0 | 0.913 | 2.707 | 0.272 |
| 1 ≤ 2 ≤ 3 (\\le) | relation/chain | 5 | 0/0 | 2.167 | 5.418 | 0.544 |
| a · b (\\cdot) | bin | 3 | 0/0 | 1.457 | 2.194 | 0.220 |
| a · b + c (\\cdot) | bin | 5 | 0/0 | 1.727 | 2.194 | 0.220 |
| a ± b (\\pm) | bin | 3 | 0/0 | 0.913 | 2.712 | 0.272 |
| α + β (\\alpha+\\beta) | greek | 3 | 0/0 | 0.012 | 0.032 | 0.003 |
| Γ(x) (\\Gamma) | greek | 4 | 0/0 | 0.030 | 0.059 | 0.006 |
| π r^2 (\\pi) | greek+sup | 3 | 0/0 | 0.215 | 0.327 | 0.046 |
| ∞ (\\infty) | misc | 1 | 0/0 | 0.000 | 0.000 | 0.000 |
| x : y (\\colon) | relation | 3 | 0/0 | 2.242 | 3.927 | 0.394 |

## Per-feature aggregate (all ok formulas)

| feature | formulas | mean of mean\|dx\| | worst max\|dx\| | notes |
|---|---|---|---|---|
| big-op / limit | ∑ ∏ ∫ ⋃ ⋂ | 2.162 | 9.963 (∫) | ∫ dominates; ∑∏⋃⋂ ≈0.5–0.7 |
| relation | ≤ ≠ ∈ ⊆ → ∼ : (+chain) | 1.337 | 5.418 (chain) | every symbol via glyphEstimate |
| bin | · ± (literal) + \\cdot + x+y | 0.701 | 2.712 (±) | `\\cdot` cmd tight, literal `·` loose |
| paren | ( ) [ , ] frac( ) Γ( ) | 0.111 | 0.572 | small, compounding |
| script (sup/sub) | x^2 x_2 x_i^2 x^{2y} x^2y^2 x^{i_j} | 0.092 | 0.450 | single scripts ~0.02; multi-char ~0.4 |
| greek | α β Γ π (literal) | 0.086 | 0.327 | exact metrics ⇒ tight |
| frac | 1/2 a+b x²/y² nested x_i/n | 0.049 | 0.319 | near-perfect |
| misc | ∞ | 0.000 | 0.000 | single glyph, uninformative |

## Worst formulas (by max\|dx\|)

1. **\\int_0^1 x\\,dx** — mean\|dx\| **8.225**, max **9.963**, un **2/1**. By far the worst.
2. **1 ≤ 2 ≤ 3** — max **5.418** (two relations compound the fallback-width error).
3. **a → b** — max **4.923** (arrow real width ≈1em; fallback 0.5em).
4. **x : y** — max **3.927** (TeX `\\colon` packs tighter than ztex `:` width).
5. **a ± b** — max **2.712**.
6. **a ≤ b / x ∼ y / A ⊆ B / a ≠ b** — max ≈2.7 each.
7. **a · b / a · b + c** — max **2.194** (literal middle dot U+00B7 → fallback; `\\cdot` cmd is 0.046).
8. **\\sum / \\prod / \\bigcup / \\bigcap** — max 1.5pt on a limit script; ∑∏⋃⋂ otherwise clean.

## Ranked empirical divergences (by magnitude) → likely rule

1. **\\int limits over/under instead of beside** — `\\int_0^1` un 2/1, limit '1' 9.96pt left / 2.46pt up, integrand x,d ~7.6pt left (max dxi 1.43).
   ztex `layout.layoutScript`/`layoutOpLimits` stacks ANY display big-op's scripts over/under; TeX puts ∫ limits **beside** (only ∑∏⋃⋂⨆ take over/under). ∫ must opt out of limit mode → beside-scripts + the ∫ post-operator italic-correction tail (TeX advances past the ∫ origin; ztex's tail is too short, so the integrand run sits ~7.6pt left). This is the single worst feature.
2. **`glyphEstimate` fallback width 0.5em for every relation/bin not in the metric table** — `src/layout/metrics.zig` `glyphEstimate()` returns width 0.5em (5pt), height 0.7em, depth 0.2em for any unknown codepoint. Real widths: ≤≠∼±⊆≈7.78pt, →≈9.9pt. Every relation pushes the FOLLOWING glyph ~2.7pt left (≤) to ~4.9pt (→); chains compound (`1≤2≤3` → 5.42pt). **The metric table (`table`) covers ASCII, Greek (αβΓπ), and big-ops only — relations ≤≠∈⊆→∼ and ±,∞ are all fallback.**
3. **∫ post-operator advance (tail) too short** — `\\int_0^1 x\\,dx`: x/d/∫ 7.6pt left of XeTeX. TeX adds the ∫ italic correction as a post-operator tail; ztex's `layout.bigOpTail` yields ~6.6pt too little (cf. notes/compare-report-display.md). Drives #1's integrand offset.
4. **`\\colon` semantics** — `x : y` ztex ':' +2.80pt, y +3.93pt right. ztex `:` (U+003A, exact 2.7778pt, rel role) is wider/looser than TeX `\\colon` (tight relation). `:` needs `\\colon`-specific spacing or a metric entry.
5. **`\\ne` glyph decomposition** — ztex emits single `≠` (U+2260); XeTeX `\\ne` renders `=` + combining U+0338 (mutool). NW alignment can't merge → un 2/1; trailing b 2.71pt left. Not in `MATH_EQUIV` map in `compare_engines.py`.
6. **literal `·` (U+00B7) vs `\\cdot` (U+22C5)** — `\\cdot` has an exact metric (2.7778) ⇒ aligns (0.046pt); literal middle dot U+00B7 is NOT in the table ⇒ glyphEstimate ⇒ 2.19pt loose. Same symbol, different codepoint, divergent result.
7. **multi-character superscript drift** — `x^{2y}`, `x^2y^2`, `x^{i_j}`: trailing script glyph 0.39–0.45pt left (max dxi 0.06–0.08). Single-char scripts (x^2, x_2, x_i^2) are ~0.02pt (the earlier 0.52pt script advance was fixed). Remaining small script-width/kern accumulation.
8. **∑∏⋃⋂ display limits ~1.5pt** — limit scripts 1.0–1.5pt off (1.53pt on 'i'), ∑ glyph 0.39pt left; no unmatched. Display op metrics are close but limits still ~1.5pt (prior report had 5.5pt; improved). `\\bigcup`/`\\bigcap` also report 1/1 unmatched on the ⋃/⋂ glyph itself (codepoint ∪/⋃ vs ⋃/⋂ mismatch across engines).
9. **paren + post-frac drift** — `\\frac{1}{2}(x+y)` max 0.572pt (parenthesised operand drifts right); `(a+b)` 0.096, `[a,b]` 0.067. Small, compounding glue/kern accumulation.

## Bottom line
- **Big-op limit placement (∫) is the #1 layout defect**; **glyphEstimate metric coverage for relations/bins is the #2 defect** (every relation/bin falls back to a wrong 0.5em width).
- Parse gap is equally broad: **no relation, Greek, `\\left/\\right`, `\\pm/\\infty`, or `\\limits` commands exist in `cmd_map`** — relations can only be expressed as literal Unicode, which then hit the metrics gap.
- **Greek (exact metrics) and fractions are near-perfect** (<0.06pt); single-char scripts <0.03pt.
