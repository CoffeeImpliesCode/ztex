# Ref critique 4 — ztex vs XeTeX vs KaTeX

- **Formula**: `\left\{ x \middle| \frac{x}{2} \in S \right\}`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 09:56:15 UTC
- **SVG (ztex)**: notes/critique-big/artifacts/critique-ref-4/render.svg (163.45 × 79.05 pt)
- **PNG (ztex)**: notes/critique-big/artifacts/critique-ref-4/render.png (218 × 105 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/critique-big/artifacts/critique-ref-4/ref.png (242 × 104 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/critique-big/artifacts/critique-ref-4/katex.png (226 × 104 px)
- **Combined**: notes/critique-big/artifacts/critique-ref-4/combined.png (242 × 385 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \left\{ x \middle| \frac{x}{2} \in S \right\} -o notes/critique-big/artifacts/critique-ref-4/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 218x105px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/critique-big/artifacts/critique-ref-4 ~/projects/ztex/notes/critique-big/artifacts/critique-ref-4/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/critique-big/artifacts/critique-ref-4/ref.png ~/projects/ztex/notes/critique-big/artifacts/critique-ref-4/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/critique-big/artifacts/critique-ref-4/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 226x104px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (5 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the vertical bar",
      "description": "The vertical bar is thicker and taller compared to both references.",
      "severity": "major",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the fraction line",
      "description": "The fraction line appears slightly thicker than in the references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the gap between the vertical bar and the fraction",
      "description": "The gap is wider compared to the references, especially noticeable next to the vertical bar.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the size of the curly braces",
      "description": "The curly braces appear slightly larger compared to the references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the baseline alignment of 'x' and '\u2208'",
      "description": "The baseline alignment of 'x' and '\u2208' seems off compared to the references; 'x' appears slightly lower.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
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
            "region": "the vertical bar",
            "description": "The vertical bar is thicker and taller compared to both references.",
            "severity": "major",
            "reference": "XeTeX|KaTeX"
        },
        {
            "region": "the fraction line",
            "description": "The fraction line appears slightly thicker than in the references.",
            "severity": "minor",
            "reference": "XeTeX|KaTeX"
        },
        {
            "region": "the gap between the vertical bar and the fraction",
            "description": "The gap is wider compared to the references, especially noticeable next to the vertical bar.",
            "severity": "minor",
            "reference": "XeTeX|KaTeX"
        },
        {
            "region": "the size of the curly braces",
            "description": "The curly braces appear slightly larger compared to the references.",
            "severity": "minor",
            "reference": "XeTeX|KaTeX"
        },
        {
            "region": "the baseline alignment of 'x' and '∈'",
            "description": "The baseline alignment of 'x' and '∈' seems off compared to the references; 'x' appears slightly lower.",
            "severity": "minor",
            "reference": "XeTeX|KaTeX"
        }
    ],
    "verdict": "FAIL"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\left\{ x \middle| \frac{x}{2} \in S \right\}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
