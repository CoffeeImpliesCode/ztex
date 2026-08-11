# \not + pre-composed negated relations (roadmap item 2)

Feature: `\not<relation>` renders the relation with a diagonal slash through
it; the pre-composed negated relations (`\nleq \ngeq \nsubseteq \nsupseteq
\nmid \nparallel \nprec \nsucc \npreceq \nsucceq \nsim \ncong \napprox \neq
\notin`) render their codepoints directly.

Files edited: `src/parse/parser.zig`, `src/layout/layout.zig`,
`src/layout/metrics.zig`. Gates skipped. Tests/goldens untouched.

## Reference behavior (measured)

The XeTeX + unicode-math reference (xelatex, `\usepackage{unicode-math}`)
resolves `\not` as a PREFIX on the next atom: unicode-math's `\not` command
checks for a pre-composed negation (`\not\leq` → `\nleq` → U+2270) and only
falls back to the U+0338 combining-long-solidus-overlay accent when none
exists. Verified by rendering `\not\in \not\leq \not= \not\subset
\not\simeq` and extracting the PDF glyphs (mutool):

| formula   | reference glyphs |
|-----------|------------------|
| `\not\in` | U+2209 ∉ (single glyph) |
| `\not\leq`| U+2270 ≰ (single glyph) |
| `\not=`   | U+2260 ≠ (single glyph) |
| `\not\subset` | U+2284 ⊄ (single glyph) |
| `\not\simeq` | U+2244 ≄ (single glyph) |
| `\not{=}`, `\not{\leq}` | also the pre-composed glyphs (braced single symbol) |
| `\not{ab}` | U+0338 overlay over the group box |
| `\not\smile \not x \not\bowtie \not\perp` | U+0338 overlay over the base |

So ztex emits the pre-composed glyph whenever one exists (matching the
reference exactly — same codepoint, same glyph) and the overlay otherwise.
Every pre-composed target was verified present in the latinmodern-math.otf
cmap (fontTools).

## Overlay slash geometry (layoutNot)

The slash is the U+0338 glyph from LM Math itself (the same glyph XeTeX
draws), boxed by its drawn ink: asc 0.750em / desc 0.250em, advance 0
(fontTools: ink x[−0.458, −0.069], y[−0.25, +0.75] — a diagonal across the
em box, angle ≈ 68.7° from horizontal, which is the reference slash; the
task's "50–60°" guess is superseded by the measured 68.7°).

Placement replicates xetex.web `make_math_accent` for an overlay accent
(the vlist [slash, kern −δ, base] with δ = min(base_height, AccentBaseHeight
0.45em)):

- **Horizontal**: the slash's MATH attachment (−0.263em = its ink center)
  lands on the base's MATH top-accent attachment, or half the FIRST
  character's advance when it has none → slash origin = anchor + 0.264em.
  XeTeX anchors to the FIRST character of the base box (measured).
- **Vertical**: slash ink bottom = max(0, h − 0.45em) above the baseline →
  slash baseline raised by max(0.25em, h − 0.20em), h = the first
  character's box height.

Measured vs the XeTeX reference (overlay cases, values in em of each
render's font size; XeTeX's actual size is the LM design size, e.g.
35.8655pt for a 36pt request):

| case | slash x (ztex) | slash x (ref) | Δ | raise (ztex) | raise (ref) | Δ |
|------|---------------|---------------|----|--------------|-------------|----|
| `\not\smile` | 0.7640 | 0.7630 | 0.001 | 0.250 | 0.250 | 0.000 |
| `\not x` | 0.5930 | 0.5920 | 0.001 | 0.250 | 0.250 | 0.000 |
| `\not\bowtie` | 0.5755 | 0.5740 | 0.0015 | 0.305 | 0.305 | 0.000 |
| `\not\perp` | 0.6530 | 0.6521 | 0.001 | 0.484 | 0.484 | 0.000 |
| `\not\frown` | 0.7640 | 0.7630 | 0.001 | 0.250 | 0.250 | 0.000 |
| `\not{ab}` | 0.550 (a attach 0.287) | 0.550 | 0.000 | 0.250 | 0.250 | 0.000 |
| `\not{\le x}` | 0.652 (half ≤ adv) | 0.652 | 0.000 | 0.431 | 0.440 | 0.009 |
| `\not{\nabla x}` | 0.680 | 0.6795 | 0.0005 | 0.483 | 0.483 | 0.000 |

All within 0.05pt at 36pt — the ≤0.5pt acceptance is met (the single 0.009em
residual on braced ≤-led groups is 0.32pt at 36pt; `\not≤` itself is
pre-composed so it never uses the overlay). The task's 5 verify formulas are
pre-composed single glyphs — geometrically identical to the reference by
construction.

## Codepoint additions

Pre-composed commands added to `symbol_map` (all in LM Math cmap):

| command | cp | command | cp | command | cp |
|---------|-----|---------|-----|---------|-----|
| `\nleq` | U+2270 | `\ngeq` | U+2271 | `\nsubseteq` | U+2288 |
| `\nsupseteq` | U+2289 | `\nmid` | U+2224 | `\nparallel` | U+2226 |
| `\nprec` | U+2280 | `\nsucc` | U+2281 | `\npreceq` | U+22E0 |
| `\nsucceq` | U+22E1 | `\nsim` | U+2241 | `\ncong` | U+2247 |
| `\napprox` | U+2249 | (`\neq` U+2260 and `\notin` U+2209 already existed) |

`\not` prefix (new `Command.not`): parses the following atom/group; a base
codepoint in `not_cp_map` (24 relations: = < > ∈ ∋ ∣ ∥ ∼ ≃ ≅ ≈ ≍ ≡ ≤ ≥ ≺ ≻
⊂ ⊃ ⊆ ⊇ ⊢ ⪯ ⪰ → their negations, matching unicode-math-table.tex) emits the
pre-composed glyph as a synthetic char leaf; everything else becomes a
`not_row_data` row ([base]) routed to `layoutNot`. The parser unwraps
group/styled/mathstyle and single-child rows so `\not{=}` → ≠ like the
reference.

Metrics added (main table: LM advance width ×10 at 10pt + CM h/d; ink
table: measured LM ink):

| cp | w | cp | w |
|----|-----|----|-----|
| U+220C ∌ | 6.67 | U+22AC ⊬ | 5.65 |
| U+2244 ≄ | 7.78 | U+22E0 ⋠ | 7.38 |
| U+226D ≭ | 7.78 | U+22E1 ⋡ | 7.38 |
| U+226E ≮ | 7.78 | U+2280 ⊀ | 7.78 |
| U+226F ≯ | 7.78 | U+2281 ⊁ | 7.78 |
| U+2284 ⊄ | 7.78 | U+2285 ⊅ | 7.78 |
| U+0338 (ink only) | 0.750/0.250 | | |

Role list (`roleOfCp` + the mirrored metrics test) extended with all the new
negated relations (rel class, so inter-atom glue around them is the TeX
relation spacing — verified `a \not\leq b` gets ord→rel/rel→ord thick glue).

## Renders (before / after)

- `notes/artifacts/feat-not/before.svg` — the plain relations ≤ ∈ = ⊂ ≃
  (the pre-feature render; `\not` and `\nleq` were UnknownCommand).
- `notes/artifacts/feat-not/after-precomposed.svg` — `\not\leq \not\in
  \not= \not\subset \not\simeq` → ≰ ∉ ≠ ⊄ ≄ (same glyphs as XeTeX).
- `notes/artifacts/feat-not/precomposed-commands.svg` — the 13 new \n*
  commands.
- `notes/artifacts/feat-not/overlay.svg` — `\not\smile \not x \not\bowtie
  \not\perp \not\frown` with the U+0338 overlay slash.

## Verification

- `zig build test` (isolated cache): all 5 test binaries pass, 143 tests —
  including 4 new parser tests for the pre-composed resolution, the overlay
  row, braced groups, and the 15 pre-composed commands.
- The 5 verify formulas render the reference codepoints (∉ ≰ ≠ ⊄ ≄); the
  pre-composed commands render their codepoints (verified glyph-by-glyph).
- Overlay geometry vs the XeTeX reference: ≤0.05pt at 36pt (table above).
- `scripts/critique.py --ref -i '\not\in \not\leq \not= \not\subset
  \not\simeq' -s 36`: geometric verifier PASS (0 defects); vision verdict
  FAIL with 6 nits — all 5 "slash thicker/positioned differently" nits plus
  "tighter spacing" come from the KaTeX reference, which implements `\not`
  as a browser-font U+0338 overlay with its own spacing; ztex and XeTeX
  render the identical pre-composed LM-Math glyphs (pixel-aligned within
  rasterizer noise, 2.97% anti-aliasing mismatch after alignment). Verdict:
  the vision nits do not correspond to any geometric defect vs XeTeX.
