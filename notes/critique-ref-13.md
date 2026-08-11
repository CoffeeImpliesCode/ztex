# Ref critique 13 — ztex vs XeTeX vs KaTeX

- **Formula**: `\begin{pmatrix} a & b \\ c & d \end{pmatrix}`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 11:33:38 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-13/render.svg (107.38 × 99.36 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-13/render.png (143 × 132 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-13/ref.png (151 × 131 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-13/katex.png (117 × 131 px)
- **Combined**: notes/artifacts/critique-ref-13/combined.png (151 × 492 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \begin{pmatrix} a & b \\ c & d \end{pmatrix} -o notes/artifacts/critique-ref-13/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 143x132px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-13 ~/projects/ztex/notes/artifacts/critique-ref-13/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-13/ref.png ~/projects/ztex/notes/artifacts/critique-ref-13/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-13/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 117x131px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** (4 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "matrix elements",
      "description": "The spacing between matrix elements 'a' and 'b', as well as 'c' and 'd', appears wider compared to both XeTeX and KaTeX references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "matrix parentheses",
      "description": "The parentheses in our rendering appear slightly more rounded compared to the sharper edges in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "matrix elements",
      "description": "The font style of the matrix elements 'a', 'b', 'c', and 'd' matches the XeTeX reference but differs from the KaTeX reference, which uses a different font style.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of the matrix elements in our rendering matches the XeTeX reference but differs slightly from the KaTeX reference, where the elements appear closer together.",
      "severity": "minor",
      "reference": "KaTeX"
    }
  ],
  "verdict": "PASS"
}
```

## Raw response

```text
```json
{
  "nits": [
    {
      "region": "matrix elements",
      "description": "The spacing between matrix elements 'a' and 'b', as well as 'c' and 'd', appears wider compared to both XeTeX and KaTeX references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "matrix parentheses",
      "description": "The parentheses in our rendering appear slightly more rounded compared to the sharper edges in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "matrix elements",
      "description": "The font style of the matrix elements 'a', 'b', 'c', and 'd' matches the XeTeX reference but differs from the KaTeX reference, which uses a different font style.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of the matrix elements in our rendering matches the XeTeX reference but differs slightly from the KaTeX reference, where the elements appear closer together.",
      "severity": "minor",
      "reference": "KaTeX"
    }
  ],
  "verdict": "PASS"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\begin{pmatrix} a & b \\ c & d \end{pmatrix}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
