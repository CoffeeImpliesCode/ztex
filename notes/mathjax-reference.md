# MathJax reference pane (4th renderer in --ref mode)

`scripts/critique.py --ref` compares ztex against three reference engines:
XeTeX, KaTeX and — since this change — **MathJax**. MathJax is the other
"web math" reference alongside KaTeX, with a different engine (and font)
underneath, and its SVG output is native path geometry (fonts turned into
outlines — crisp at any resolution, no font dependency).

## Install

Project-local npm install (no repo-root package.json involvement):

```bash
mkdir -p tools/mathjax && cd tools/mathjax
npm init -y && npm install mathjax-full     # mathjax-full 3.2.1
```

The npm package ships `js/` but NOT the built convenience entry
`js/tex-svg.js` (that file is a repo build artifact), and the package
`main` points at a component build that does not exist in the npm tarball
(`require('mathjax-full')` fails). The renderer wires the TeX input jax +
SVG output jax manually — exactly what tex-svg.js does:

```js
const { mathjax }   = require('mathjax-full/js/mathjax.js');
const { TeX }       = require('mathjax-full/js/input/tex.js');
const { SVG }       = require('mathjax-full/js/output/svg.js');
const { liteAdaptor } = require('mathjax-full/js/adaptors/liteAdaptor.js');
const { RegisterHTMLHandler } = require('mathjax-full/js/handlers/html.js');
const { AllPackages } = require('mathjax-full/js/input/tex/AllPackages.js');
const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const tex = new TeX({ packages: AllPackages });
const svgJax = new SVG({ fontCache: 'local' });
const html = mathjax.document('', { InputJax: tex, OutputJax: svgJax });
function tex2svg(math, options = {}) {
  if (options.display == null) options.display = false;
  return adaptor.outerHTML(html.convert(math, options));
}
```

Module resolution: the script first tries normal node_modules lookup (a
repo-root install would be picked up), then falls back to
`tools/mathjax` via `createRequire(path.join(toolsDir, 'package.json'))`.

## Renderer

`scripts/mathjax_render.mjs` — formula from argv or stdin, plus flags:

```
node scripts/mathjax_render.mjs 'FORMULA' [--display|--inline]
     [--size PT] [--scale N] [-o out.svg]
```

- `--display` (default: inline): `\displaystyle`-style rendering, matching
  the XeTeX `$\displaystyle ...$` and KaTeX `-d` display panes.
- `--size PT`: nominal font size (1em) in pt — the SAME `--size` the other
  panes render at.
- `--scale N`: final pixel-density multiplier (1 = 96 dpi = 4/3 px/pt,
  2 = 192 dpi = 8/3 px/pt, used by `--ref` mode).
- Output: the SVG with the `<mjx-container>` wrapper stripped (resvg
  requires `<svg>` as the document root) and `width`/`height` rewritten
  from ex units to **px**.

## ex -> pt scaling (the key part)

MathJax `tex2svg` output sizes the SVG in **ex** units
(`width="6.673ex" height="6.354ex" viewBox="0 -1562.5 2949.6 2808.5"`),
which no rasterizer can use directly. The conversion is exact and needs no
hardcoded ex constant:

- The viewBox is in **em/1000** units: MathJax's TeX font x-height is
  0.442em = 442 units, so 1ex = 442 viewBox units (verified: 2949.6 /
  6.673 = 442.0; 2808.5 / 6.354 = 442.0).
- To render at a nominal font size of `S` pt (1em = S pt, the same as the
  other panes) at 4/3 px/pt, each viewBox unit maps to
  `S / 1000 × (96/72) × scale` px:

```
px per unit = size_pt / 1000 * (96.0/72.0) * scale
width_px    = viewBox_width  * px_per_unit
height_px   = viewBox_height * px_per_unit
```

`mathjax_render.mjs` rewrites the svg `width`/`height` attributes to those
px values (viewBox untouched), so `resvg --background white in.svg out.png`
rasterizes at exactly the target density — no scaling knobs, no upscale.
Measured check: at `--size 20` the numerator x of `\frac{x_i}{n}` renders
12 px tall = 0.442em × 20pt × 4/3, the MathJax x-height at the same
nominal size as the CM-based panes (XeTeX/KaTeX x-height 0.431em — the
~2.5% difference is the MathJax font's own x-height, not a scale error;
the vision prompt explicitly ignores overall scale).

## Resolution consistency (no upscaling in the combined image)

The four panes used to be rendered at 96 dpi (4/3 px/pt) and
`combine_panes` scaled each pane to the common (max) width — the narrower
panes were UPSCALED (e.g. ztex 73px -> 85px at -s 20). Now every pane is
rendered at 2× (8/3 px/pt, 192 dpi) and the combined image only ever
downscales (LANCZOS) or keeps panes at ≥ 8/3 px/pt:

| pane      | renderer                                  | 2× density                   |
|-----------|-------------------------------------------|------------------------------|
| ztex      | PIL + LM OTFs (`convert_png(scale=2)`)    | 8/3 px/pt                    |
| XeTeX     | `mutool draw -r 192` (`render_ref dpi=192`)| 8/3 px/pt                   |
| KaTeX     | PIL (`render_katex_ref(scale=2)`)         | 8/3 px/pt                    |
| MathJax   | `mathjax_render.mjs --scale 2` + resvg    | 8/3 px/pt                    |

This needed a small `scale` parameter (default 1.0 — no behavior change)
on `critique.rasterize_svg` / `convert_png`, `critique.render_ref`
(`dpi`), `critique.render_katex_ref` and `katex_ref.render_katex_ref`.

**Canvas bug fixed along the way.** The original supersample loop created
the draw canvas as `w_px * ss` where `w_px` already included the new
`scale` factor — at scale=2 the canvas was 2× too big, so the final
downscale placed the content at 96dpi positions on a larger canvas (the
bottom half of the pane came out blank; verified on `\frac{a}{b}` at
scale=2: ink rows 8-123 of a 264px canvas vs 8-123 of 132px at scale=1).
Fixed in both `katex_ref.py` and `critique.py`: the draw canvas is now
`SUPERSAMPLE × final size` (`w_px * SUPERSAMPLE`), the draw stays at
`ss = SUPERSAMPLE × scale`, and the downscale is always ÷SUPERSAMPLE.
Regression-checked: scale=1 output is pixel-identical to the pre-change
baseline for both the ztex PIL raster and the KaTeX pane.

## Pane integration

`critique.run_ref_critique` now renders four panes into
`notes/artifacts/critique-ref-<n>/`:

```python
mathjax_png, mathjax_cmd, mathjax_convert_cmd = render_mathjax_ref(
    formula, workdir, size_pt=args.size, scale=REF_SCALE)
```

and stacks `(render.png, "ztex (ours)"), (ref.png, "XeTeX (reference)"),
(katex.png, "KaTeX (reference)"), (mathjax.png, "MathJax (reference)")`.

- `render_mathjax_ref` runs `node scripts/mathjax_render.mjs <formula>
  --display --size N --scale S -o mathjax.svg` then
  `resvg --background white mathjax.svg mathjax.png`.
- The ref prompt (`REF_PROMPT_TEMPLATE`) now says "Four stacked panes" and
  allows `"reference": "XeTeX|KaTeX|MathJax"` per nit.
- The report (`render_ref_report`) lists the MathJax PNG size and both
  commands; the report title is `ztex vs XeTeX vs KaTeX vs MathJax`.
- Display mode is used (`--display`), matching the XeTeX `\displaystyle`
  and KaTeX `-d` panes.

## Verification (measured)

- `\sum_{i=1}^{n} \frac{x_i}{n}` at -s 48: ztex 339×374, XeTeX 349×389,
  KaTeX 357×383, MathJax 378×359 — all at 8/3 px/pt (exactly 2× the 96dpi
  sizes); combined 378×1675, no pane below 8/3 px/pt effective.
- Numerator glyph (x-height) measured in every pane: 54-55 px = 20.25-
  20.6 pt ≈ x-height × 48 pt — the four engines render the formula at the
  same nominal size (ztex's own fraction parts are smaller — a ztex layout
  difference the critic is meant to catch, not a raster artifact).
- Vision check of the combined image: four labels in order (ztex, XeTeX,
  KaTeX, MathJax); the MathJax pane renders the sum with limits above/
  below and the fraction bar completely, no clipping, no artifacts.
- MathJax parses and renders the whole test corpus: integrals with thin
  spaces, `x^2+y^2`, `a\cdot b`, fractions, `\lim_{x\to 0}`, `\left(
  \right)`, `\sqrt`, `\sum`, `\prod`, Greek letters.
