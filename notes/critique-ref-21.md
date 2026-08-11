# Ref critique 21 — ztex vs XeTeX vs KaTeX vs MathJax

- **Formula**: `\displaystyle\int\limits_2^3 3x^2\,dx + \sum\nolimits^n_{i=1}i + \textstyle\int\limits_x^y`
- **Size**: 30.0 pt, background: `white`
- **Rendered**: 2026-08-14 14:44:30 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-21/render.svg (297.68 × 116.90 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-21/render.png (794 × 312 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-21/ref.png (838 × 333 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-21/katex.png (835 × 312 px)
- **PNG (MathJax ref)**: ~/projects/ztex/notes/artifacts/critique-ref-21/mathjax.png (810 × 298 px)
- **Combined**: notes/artifacts/critique-ref-21/combined.png (838 × 1327 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \displaystyle\int\limits_2^3 3x^2\,dx + \sum\nolimits^n_{i=1}i + \textstyle\int\limits_x^y -o notes/artifacts/critique-ref-21/render.svg -s 30.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (192dpi, 794x312px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-21 ~/projects/ztex/notes/artifacts/critique-ref-21/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 192 -o ~/projects/ztex/notes/artifacts/critique-ref-21/ref.png ~/projects/ztex/notes/artifacts/critique-ref-21/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-21/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (192dpi, 835x312px, 4x supersample + LANCZOS)`
- **MathJax cmd**: `node ~/projects/ztex/scripts/mathjax_render.mjs \displaystyle\int\limits_2^3 3x^2\,dx + \sum\nolimits^n_{i=1}i + \textstyle\int\limits_x^y --display --size 30.0 --scale 2 -o ~/projects/ztex/notes/artifacts/critique-ref-21/mathjax.svg`
- **MathJax convert cmd**: `resvg --background white ~/projects/ztex/notes/artifacts/critique-ref-21/mathjax.svg ~/projects/ztex/notes/artifacts/critique-ref-21/mathjax.png`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (7 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "integral symbol",
      "description": "The integral symbol in OURS appears slightly thinner compared to XeTeX and MathJax.",
      "severity": "minor",
      "reference": "XeTeX|MathJax"
    },
    {
      "region": "superscript 'n' on summation",
      "description": "The superscript 'n' in OURS is positioned slightly higher than in KaTeX and MathJax.",
      "severity": "minor",
      "reference": "KaTeX|MathJax"
    },
    {
      "region": "subscript 'i=1' on summation",
      "description": "The subscript 'i=1' in OURS is slightly more italicized compared to XeTeX and MathJax.",
      "severity": "minor",
      "reference": "XeTeX|MathJax"
    },
    {
      "region": "gap after integral term",
      "description": "The gap between the integral term and the summation term in OURS is slightly wider compared to KaTeX and MathJax.",
      "severity": "minor",
      "reference": "KaTeX|MathJax"
    },
    {
      "region": "plus sign after summation",
      "description": "The plus sign following the summation in OURS is slightly larger compared to XeTeX and MathJax.",
      "severity": "minor",
      "reference": "XeTeX|MathJax"
    },
    {
      "region": "integral limits",
      "description": "The positioning of the lower limit '2' and upper limit '3' in OURS is slightly off-center compared to XeTeX and MathJax.",
      "severity": "minor",
      "reference": "XeTeX|MathJax"
    },
    {
      "region": "overall baseline alignment",
      "description": "The baseline alignment of terms in OURS does not perfectly match the references, especially noticeable around the summation and integral signs.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX|MathJax"
    }
  ],
  "verdict": "FAIL"
}
```

## Raw response

```text

```json
{
  "nits": [
    {
      "region": "integral symbol",
      "description": "The integral symbol in OURS appears slightly thinner compared to XeTeX and MathJax.",
      "severity": "minor",
      "reference": "XeTeX|MathJax"
    },
    {
      "region": "superscript 'n' on summation",
      "description": "The superscript 'n' in OURS is positioned slightly higher than in KaTeX and MathJax.",
      "severity": "minor",
      "reference": "KaTeX|MathJax"
    },
    {
      "region": "subscript 'i=1' on summation",
      "description": "The subscript 'i=1' in OURS is slightly more italicized compared to XeTeX and MathJax.",
      "severity": "minor",
      "reference": "XeTeX|MathJax"
    },
    {
      "region": "gap after integral term",
      "description": "The gap between the integral term and the summation term in OURS is slightly wider compared to KaTeX and MathJax.",
      "severity": "minor",
      "reference": "KaTeX|MathJax"
    },
    {
      "region": "plus sign after summation",
      "description": "The plus sign following the summation in OURS is slightly larger compared to XeTeX and MathJax.",
      "severity": "minor",
      "reference": "XeTeX|MathJax"
    },
    {
      "region": "integral limits",
      "description": "The positioning of the lower limit '2' and upper limit '3' in OURS is slightly off-center compared to XeTeX and MathJax.",
      "severity": "minor",
      "reference": "XeTeX|MathJax"
    },
    {
      "region": "overall baseline alignment",
      "description": "The baseline alignment of terms in OURS does not perfectly match the references, especially noticeable around the summation and integral signs.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX|MathJax"
    }
  ],
  "verdict": "FAIL"
}
```
```

## Prompt used

```text
\
Four stacked panes of the same formula: `\displaystyle\int\limits_2^3 3x^2\,dx + \sum\nolimits^n_{i=1}i + \textstyle\int\limits_x^y`. Top = ztex render (ours), then XeTeX, KaTeX, and MathJax (bottom) — the three web/TeX references.

Compare OURS against ALL THREE references. List EVERY visual nit in OURS vs any reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX|MathJax"}], "verdict": "PASS|FAIL"}.

```
