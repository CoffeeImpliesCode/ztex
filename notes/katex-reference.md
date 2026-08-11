# KaTeX reference renderer (scripts/katex_ref.py)

KaTeX ("the same purpose as this lib but for the web") is now a SECOND
master reference in the `--ref` comparison pipeline. `scripts/critique.py
--ref` renders THREE stacked panes: ztex (ours) / XeTeX / KaTeX, all at the
same nominal pt size, and the vision prompt compares OURS against BOTH
references.

## Installation

KaTeX comes from nixpkgs; the binary and fonts live in one nix store path:

```
nix profile install nixpkgs#katex     # or: nix-shell -p katex --run '...'
which katex    # /nix/store/...-katex-0.16.28/bin/katex
```

`katex_ref.katex_store_dir()` resolves the store dir from `katex` on PATH;
the dist fonts are at `<store>/lib/node_modules/katex/dist/fonts/*.woff2`
(20 faces: KaTeX_Main/-Bold/-Italic/-BoldItalic, KaTeX_Math-Italic,
KaTeX_Size1..4, AMS, Caligraphic, Fraktur, Script, SansSerif, Typewriter)
and the layout engine reference is `<store>/lib/node_modules/katex/dist/
katex.{js,mjs}` + `katex.css`.

## CLI invocation

The katex CLI has NO positional formula argument — it reads the LaTeX from
STDIN (`-i -` is not supported either):

```
printf '\\sum_{i=1}^{n} x_i' | katex -d -o out.html
```

`katex_ref.render_katex_ref()` runs `["katex", "-d", "-o", html]` with the
formula as stdin. `-d` = display mode (large operators, limits over/under —
matches the XeTeX `$\displaystyle...$` doc). The formula must be written to
a file or piped; passing it positionally silently renders an EMPTY formula.

## HTML -> geometry parsing (the KaTeX layout DSL)

KaTeX 0.16 HTML output is a self-describing layout (verified against
`dist/katex.js` `makeVList`/`buildHTML` and Chromium 151 measurements to
<=0.05 pt on the corpus):

* Root `.katex` has base font-size 1.21em of the wrapper; EVERY em value in
  the HTML is relative to this base. `katex_ref.py` sets the base =
  the requested pt size, so 1em = size_pt exactly (same nominal size as the
  ztex/XeTeX panes).
* `.katex-html` contains one `.base` per unbreakable chunk (KaTeX breaks
  after every `mbin`/`mrel`). The inline-block `.base`s share ONE line
  baseline B; glyph x positions accumulate across bases.
* A `.vlist-t` (inline-table) stacks content. Row 1 = [`.vlist` main cell,
  `.vlist-s` ZWSP strut cell (font-size 1px)], plus a second row (depth
  strut) when the list has depth (`.vlist-t2`). The ROW baseline is the
  ZWSP strut line; the main cell's BOTTOM sits ~0.1875px below the line
  baseline (measured constant — the 1px ZWSP line box).
* Every child wrap is `<span style="top:-Xem">` containing a `.pstrut` of
  explicit height P + the content. KaTeX's strut trick (empty
  inline-block baseline == bottom edge) pins the content baseline exactly:
  `content baseline = cell_bottom + (top + pstrut) em`.
* Glyph spans carry classes -> font faces (katex.css): `mathnormal` ->
  KaTeX_Math (italic), `op-symbol large-op` -> KaTeX_Size2, `small-op` ->
  KaTeX_Size1, `delimsizing sizeN` -> KaTeX_SizeN, default
  (mord/mbin/mrel/...) -> KaTeX_Main. `reset-sizeN sizeM` classes scale
  font-size by the katex.css size table (the LAST `sizeN` token is the
  target; `re.findall` order matters — `reset-size6 size3` = 0.7em).
* Geometry styles are inline em: `top` (vlist wraps AND relative shifts
  like the ∫ op's `top:-0.0011em`), `margin-left/right` (glues, italic
  corrections — the ∫ msupsub sub is pulled back by a negative margin),
  `left` (accent bodies), `border-right-width`/`border-top-width`
  (`\rule`), `border-bottom-width` (frac/overline lines).
* Rules: `.frac-line`/`.overline-line`/`.underline-line` span the vlist
  CELL width (`width:100%`) with their bottom edge on the wrap baseline.
* SVG stretchies: `.sqrt` surds are `.hide-tail` spans and braces/arrows
  are `.stretchy` spans, both `width:100%` of the cell (min-width floors
  them), left-aligned in the cell. Each contains `<svg><path d=.../></svg>`
  with `viewBox` 0 0 400000 N and `preserveAspectRatio` slice; the path is
  flattened (M/L/H/V/C/S/Q/T/Z, adaptive cubic/quad subdivision), scaled
  by max(box/vb), clipped to the box (Sutherland-Hodgman — the overline
  subpath is 400000 units wide!), and filled. Braces/arrows additionally
  split into absolute windows: `.brace-left` (0..25.1%),
  `.brace-center` (25..75%), `.brace-right` (74.9..100%), `.halfarrow-*`.

## Font conversion (woff2 -> ttf)

The browser pulls glyph advances from the woff2s; PIL needs ttfs. Every
`KaTeX_*.woff2` is decompressed once with fontTools
(`f.flavor = None; f.save(...)`) into
`$XDG_CACHE_HOME/ztex-katex/fonts/` (cache invalidation via mtime).
Per-glyph advance + ink bbox come from the converted font's hmtx and a
BoundsPen pass. KaTeX fonts carry NO space glyph — the browser falls back
to the fallback font's space advance (0.25em in Times), so U+0020/U+00A0
get a synthetic 0.25em advance with no ink. Glyph ink bboxes drive the
canvas size (96 dpi, 1pt = 4/3 px, 2x supersample + LANCZOS — same
rasterization as the ztex PIL rasterizer, so pane styles match).

## Pane integration (scripts/critique.py)

* `render_katex_ref(formula, workdir, size_pt)` — imports `katex_ref.py`
  (sibling module) and delegates; returns (png, cmd, convert_desc).
* `combine_side_by_side` -> `combine_panes(panes, path)`: N panes scaled
  to the same width, stacked vertically, each labeled (ztex (ours) /
  XeTeX (reference) / KaTeX (reference)), 2px dividers.
* `run_ref_critique` renders all three, combines, reports the KaTeX cmd +
  raster size, and the prompt now reads: "compare OURS against BOTH
  references" with a `reference: "XeTeX|KaTeX"` field per nit.
* The XeTeX pane behavior is unchanged.

## Verification

Corpus `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx` at 48pt: all 16
glyph baselines/x positions match Chromium's KaTeX render within 0.05 pt;
per-construct battery (sqrt incl. root index, \left...\right delimiters,
\lim, \binom, \underbrace, \text, \hat, \overline, nested fractions,
pmatrix) matches the browser layout (coarse ink diff <= ~2% where row
crops align). `scripts/critique.py --ref --no-critique` produces the
three-pane combined.png with all panes rendering the formula correctly.
