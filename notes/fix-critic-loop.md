# fix-critic-loop — three confirmed rendering defects

Task: fix the critic-loop defects on `\lim`-style limits, nested-script spacing, and
`\left...\right` delimiter sizing. Edits confined to `src/parse/parser.zig`,
`src/layout/layout.zig`, `src/atom.zig` (new tags). Intentional output change: the
`\lim`/`\left` renders change; goldens were not touched (none of the golden corpus
formulas — x, x^2, x_2, x^2+y_1, \frac{1}{2}, \sum_{i=1}^{n}, \text{hi},
\mathbf{ab} — involve operator words or \left...\right, so `zig build test` passes
unchanged).

All renders: `zig-out/bin/ztex -i <formula> -o <svg> -s 32 -b white` (display style,
32pt); pixels rasterized with the project's trusted PIL pipeline (scripts/critique.py
`rasterize_svg`, 96 dpi, 1pt = 4/3 px). XeTeX references produced locally with
`xelatex` + `\showbox` (both `lmodern` and `unicode-math` + `\setmathfont{Latin
Modern Math}`, which is the font ztex draws).

---

## Fix 1 — limit-taking operator words place scripts over/under in display

**Defect (critique-12):** `\lim_{x \to 0} f(x)` rendered "x→0" BESIDE the word as a
subscript (x at y=39.94, x=55.65 — right of the word), not centered UNDER it.

**Root cause:** parser.zig's `opname()` produced a `.styled` (roman) wrapper node, so
`layoutScript` classified every operator word as an ordinary box and attached
scripts beside. TeX's fontmath.ltx defines only
`\lim \limsup \liminf \max \min \sup \inf \det \gcd \Pr \arg \ker \dim \hom \deg`
as `\mathop` with limits by default; the trig/log words
(`\sin \cos \tan \cot \sec \csc \arcsin … \log \ln \lg \exp`, `\mod \bmod`) are
`\mathop\nolimits` (regular sub/superscripts — `\sin^2 x`).

**Change:**
- `atom.zig`: new `.opname` tag — 1 child = the letters row, always roman; `data` =
  1 for limit-taking words, 0 otherwise. Also new `.left` tag (fix 3).
- `parser.zig`: `opname()` now creates `.opname` with the limit flag from a new
  comptime `limitOpName()` set (the 15 names above); `parseLeftRight()` creates a
  `.left` node instead of a plain `.row`.
- `layout.zig`:
  - `layoutInner`/`leftRole`/`rightRole`: `.opname` renders as the roman word row
    (role stays `ord` — the known thin-op-glue deviation is unchanged), `.left` is
    an `inner` atom.
  - `layoutScript`: display style + `.opname` with the limit flag → the
    `layoutOpLimits` path (same as big-op limits).
  - `layoutOpLimits`: the base's axis shift `(h−d)/2 − axis` is applied ONLY to
    glyph bases (`bb.kind == .char`, the ∑-family ink boxes); an operator WORD base
    stays on the baseline — XeTeX places the "lim" row at shift 0 inside the limits
    vbox. Delta (limits skew) is already 0 for a word (its cp is 0).

**Geometry (32pt):** before — "x→0" baseline y=39.94, x from 55.65 (right of the
"lim" word ending at ~44); after — "x→0" baseline y=51.72, centered under "lim"
(x→0 spans x=11.2..56.6; the word "lim" is centered in the 45.43pt vbox at
+0.49pt). Under-gap: the x→0 row baseline sits exactly k = max(bigop2, bigop4 −
sub.height) = 1.6667pt below the word's baseline (unscaled cmex parameter), so the
x→0 ink top is 1.667pt below the "lim" ink bottom — no ink overlap.

**TeX reference (XeTeX \showbox, `\lim_{x\to 0} x`):**
- lmodern: `\vbox(6.88875+7.17766)x16.49297` = [lim row (h 6.88875, d 0) ; kern
  **1.66666** ; x→0 row (h 4.511) ; kern 1.0]. Both rows centered by fil glue —
  the vbox width is the max of the two, and no op shift is applied (the stack sits
  on the baseline).
- unicode-math (LM Math): same structure, kern **1.66982**, x→0 row h 4.648,
  trailing kern 1.19987.
ztex's vbox (k 1.66667, row centered, no word shift) reproduces this structure
exactly; the parity numbers above match to <0.01pt.

**Verified:** `\lim_{x \to 0} f(x)`, `\limsup_{n \to \infty} a_n`,
`\max_{i \in S} f(i)` all render the subscript centered under the word;
`\lim\limits_{x\to 0} x` behaves identically (`\limits` is consumed as a no-op);
`\frac{\lim_{x\to 0} y}{z}` (text style) keeps scripts BESIDE, as TeX does outside
display style; `\sin^2 x` keeps a beside superscript (byte-identical render).

---

## Fix 2 — nested-script spacing (`x^{i_j}`)

**Defect (critique-10):** vision critic flagged the inner subscript "j" as "too
close to / slightly overlapping the x".

**Verification (no layout change needed):** the nested-script path in
`layoutScript` is already TeX-correct:
- the inner sub "j" is placed at x_shift = width(i) (the sub-gap is 0 — TeX
  make_scripts: the subscript starts at the base's right edge, no leading space),
  with \scriptspace 0.5pt folded into the script box width after the sub;
- the outer sup starts at width(x) + italic correction of x.

Measured (32pt, unchanged before/after — the two SVGs are byte-identical): j's box
left = 28.608 + 6.227 = 34.835, where 6.227 = the drawn i's advance (2.78em ×
22.4/10); j's ink left (LM Math j has a −0.040em left sidebearing) = 34.19 vs the
i's ink right 34.14 → 0.05pt overlap, negligible; x's ink right (0.516em × 32 =
27.71) vs i's ink left (29.35) leaves a 1.64pt gap — there is NO geometric overlap
with the x.

**TeX reference (XeTeX + unicode-math \showbox, x^{i_j}):**
```
\hbox(8.47519+0.11)x12.488
.\lmm x (10pt)
.\hbox(4.641+2.75418)x6.768, shifted -3.83418   <- script box (i_j)
..\lmm i (7pt)                                  <- i at x=0
..\hbox(3.335+1.025)x3.44, shifted 1.72919      <- sub box (j)
```
Script box width 6.768 = i advance 2.828 + sub box 3.44 (j advance 2.94 +
scriptspace 0.5) + 0 — i.e. the sub box starts at width(i) and the scriptspace pads
AFTER it. ztex's structure is identical (sub at width(i), scriptspace after).

The critic's visual flag traces to a FONT-SELECTION difference, not the layout:
ztex draws the cmap glyphs 'i'/'j' (advances 0.278em / 0.306em), while
XeTeX+unicode-math uses the optical-size variants u1D456.st / u1D457.sts (0.404em /
0.588em — ~45% wider), which makes the TeX subscript look denser. Switching glyph
selection is font/context territory (context.zig/font.zig/svg.zig), outside this
task's file list, so the geometry is verified and documented rather than changed.

---

## Fix 3 — `\left...\right` delimiters sized to the content

**Defect (critique-11/12 era):** `\left( \frac{a}{b} \right)` rendered the parens at
plain size (32pt) over a ~58pt fraction — the fraction poked far past the parens.

**Root cause:** `parseLeftRight` emitted a plain `.row` of delimiter chars laid out
by `layoutRow` at ordinary size; nothing stretched them.

**Change:**
- `atom.zig`/`parser.zig`: new `.left` tag, children [open?, inner, close?]
  (delimiter char leaves; absent for `\left.` / `\right.`).
- `layout.zig`: new `layoutLeftRight` — lays out the inner, then scales each
  delimiter glyph (LM Math normal paren/bracket/bar glyphs scale linearly: ink
  asc/desc 0.748/0.248em for ( ), 0.750/0.250 for [ { | — metrics.glyphInk) so the
  delimiter ink covers the content:
  - total: S ≥ (content_height + content_depth + 2·pad) / (ink.asc + ink.desc),
    pad = axis/2;
  - per side (TeX make_delim's h_d ≥ h−a, d_d ≥ d+a, adapted to the fixed
    asc:desc ratio of the scaled glyph): S ≥ (h − axis)/half and S ≥ (d +
    axis)/half, half = (asc+desc)/2;
  - clamp S ≥ size_pt so small content (`\left( x \right)`) keeps ordinary-size
    delimiters (byte-identical to the previous render).
  Each delimiter is centered on the math axis (baseline shift (h−d)/2 − axis, the
  same axis formula used for big-op glyphs); the inner sits on the row baseline, so
  the fraction rule stays on the axis. `layoutScaledChar` builds the delimiter box
  (layoutChar's construction at an explicit drawn size).

**Geometry (32pt):** parens drawn at 66.55pt (before: 32pt). Paren ink top y=23.29
vs fraction ink top y=28.45 (a ascender) → 5.16pt cover above; paren ink bottom
y=89.58 vs fraction bottom y=86.74 (b descender) → 2.84pt cover below; paren
vertical center y=56.44 = the fraction rule = the math axis. No overlap, clear
cover on both sides. `\left[ \right]`, `\left| \right|`, `\left\langle
\right\rangle`, and nested `\left( \left( ... \right) \right)` (outer 74.59pt over
inner 66.55pt) all stretch the same way; `\left. x \right.` and `\left. x \right|`
(null delimiters) behave.

**TeX reference (XeTeX + unicode-math \showbox, `\left( \frac{a}{b} \right)`):**
```
\hbox(11.46028+6.97073)x19.62999
.\vbox(11.46+6.46)x5.97, shifted -0.00027      <- open paren, covers the fraction
.\hbox(11.19072+6.97073)x7.68999               <- fraction (+ 2×1.2pt null pads)
.\vbox(11.46028+6.97073)x5.97, shifted -0.00027 <- close paren
```
The parens cover the fraction's height+depth (11.19072 + 6.97073) with ~0.27pt
extra, centered on the axis (vbox shift ≈ 0 → paren center ≈ axis). ztex covers
with a slightly larger margin (1.6/0.9pt at 10pt) because the scaled normal paren
keeps the 3:1 asc:desc shape of the LM glyph while TeX's cmex/lmex extension
glyphs grow symmetric — same "covers the content" behavior, deliberately chosen
per the task's prescription ("size the parens to the content height via the font …
paren ink covering ~content height").

---

## Regression check

- `zig build test`: all module unit tests + integration + regression pass (the
  golden corpus has no \lim/\left/\sin formulas, so no goldens changed).
- `\sin x + \cos x` render is byte-identical to the pre-fix artifact
  (notes/artifacts/critique-7/render.svg): the operator-word glyphs, roman style,
  and ord-role spacing are unchanged.
- `x^{i_j}` render is byte-identical to the pre-fix SVG (fix 2 is verify-only).
- `\sum_{i=1}^{n} x_i` and `\int_0^1 x\,dx` (glyph big-op paths) unchanged.
