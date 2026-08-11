# Ref critique 10 — ztex vs XeTeX vs KaTeX

- **Formula**: `\sum\nolimits_{i=1}^{n} x_i`
- **Size**: 20.0 pt, background: `white`
- **Rendered**: 2026-08-14 09:16:44 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-10/render.svg (75.41 × 40.84 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-10/render.png (101 × 54 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-10/ref.png (112 × 61 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-10/katex.png (110 × 62 px)
- **Combined**: notes/artifacts/critique-ref-10/combined.png (112 × 237 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \sum\nolimits_{i=1}^{n} x_i -o notes/artifacts/critique-ref-10/render.svg -s 20.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 101x54px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-10 ~/projects/ztex/notes/artifacts/critique-ref-10/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-10/ref.png ~/projects/ztex/notes/artifacts/critique-ref-10/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-10/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 110x62px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** (5 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "big-op limit centering",
      "description": "The upper limit 'n' in our rendering is slightly off-center compared to both references.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "subscript position",
      "description": "The subscript 'i=1' in our rendering appears slightly higher than in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "inter-term spacing",
      "description": "The space between the summation symbol and 'x_i' in our rendering is marginally wider than in the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "glyph size of 'x'",
      "description": "The 'x' in 'x_i' in our rendering is slightly larger compared to the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'x_i' in our rendering matches the XeTeX reference but is slightly different from the KaTeX reference.",
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
      "region": "big-op limit centering",
      "description": "The upper limit 'n' in our rendering is slightly off-center compared to both references.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "subscript position",
      "description": "The subscript 'i=1' in our rendering appears slightly higher than in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "inter-term spacing",
      "description": "The space between the summation symbol and 'x_i' in our rendering is marginally wider than in the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "glyph size of 'x'",
      "description": "The 'x' in 'x_i' in our rendering is slightly larger compared to the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'x_i' in our rendering matches the XeTeX reference but is slightly different from the KaTeX reference.",
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
Three stacked panes of the same formula: `\sum\nolimits_{i=1}^{n} x_i`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
