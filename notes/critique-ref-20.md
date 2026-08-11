# Ref critique 20 — ztex vs XeTeX vs KaTeX

- **Formula**: `\big( \frac{a}{b} \big)`
- **Size**: 30.0 pt, background: `white`
- **Rendered**: 2026-08-14 13:22:43 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-20/render.svg (48.39 × 65.26 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-20/render.png (65 × 87 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-20/ref.png (74 × 89 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-20/katex.png (71 × 89 px)
- **Combined**: notes/artifacts/critique-ref-20/combined.png (74 × 334 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \big( \frac{a}{b} \big) -o notes/artifacts/critique-ref-20/render.svg -s 30.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 65x87px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-20 ~/projects/ztex/notes/artifacts/critique-ref-20/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-20/ref.png ~/projects/ztex/notes/artifacts/critique-ref-20/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-20/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 71x89px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (4 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "parentheses",
      "description": "The parentheses in our rendering appear slightly thicker compared to both references.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "fraction bar",
      "description": "The fraction bar in our rendering is slightly thicker than in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of the fraction within the parentheses seems slightly off in our rendering compared to the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "spacing around fraction",
      "description": "The spacing around the fraction inside the parentheses appears tighter in our rendering compared to the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
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
      "region": "parentheses",
      "description": "The parentheses in our rendering appear slightly thicker compared to both references.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "fraction bar",
      "description": "The fraction bar in our rendering is slightly thicker than in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of the fraction within the parentheses seems slightly off in our rendering compared to the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "spacing around fraction",
      "description": "The spacing around the fraction inside the parentheses appears tighter in our rendering compared to the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    }
  ],
  "verdict": "FAIL"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\big( \frac{a}{b} \big)`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
