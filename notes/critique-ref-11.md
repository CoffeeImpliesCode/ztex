# Ref critique 11 — ztex vs XeTeX vs KaTeX

- **Formula**: `\overline{x+y}`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 09:22:15 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-11/render.svg (88.00 × 48.53 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-11/render.png (117 × 65 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-11/ref.png (127 × 64 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-11/katex.png (127 × 62 px)
- **Combined**: notes/artifacts/critique-ref-11/combined.png (127 × 250 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \overline{x+y} -o notes/artifacts/critique-ref-11/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 117x65px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-11 ~/projects/ztex/notes/artifacts/critique-ref-11/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-11/ref.png ~/projects/ztex/notes/artifacts/critique-ref-11/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-11/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 127x62px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (6 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the bar above x+y",
      "description": "The bar in our rendering appears slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between x and +",
      "description": "The spacing between 'x' and '+' in our rendering seems slightly tighter than in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between + and y",
      "description": "Similarly, the space between '+' and 'y' in our version is marginally closer than in the references.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of x",
      "description": "The 'x' in our rendering appears to be slightly larger compared to the references.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of y",
      "description": "The 'y' also seems a bit bigger in our version when compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'x + y' under the bar looks consistent with both references.",
      "severity": "none",
      "reference": "both"
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
      "region": "the bar above x+y",
      "description": "The bar in our rendering appears slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between x and +",
      "description": "The spacing between 'x' and '+' in our rendering seems slightly tighter than in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between + and y",
      "description": "Similarly, the space between '+' and 'y' in our version is marginally closer than in the references.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of x",
      "description": "The 'x' in our rendering appears to be slightly larger compared to the references.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of y",
      "description": "The 'y' also seems a bit bigger in our version when compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'x + y' under the bar looks consistent with both references.",
      "severity": "none",
      "reference": "both"
    }
  ],
  "verdict": "FAIL"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\overline{x+y}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
