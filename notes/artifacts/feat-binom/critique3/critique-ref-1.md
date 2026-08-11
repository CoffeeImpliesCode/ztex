# Ref critique 1 — ztex vs XeTeX vs KaTeX

- **Formula**: `\genfrac{(}{)}{0.8pt}{1}{x}{y}`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 10:28:29 UTC
- **SVG (ztex)**: notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/render.svg (60.23 × 65.53 pt)
- **PNG (ztex)**: notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/render.png (80 × 87 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/ref.png (76 × 78 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/katex.png (65 × 80 px)
- **Combined**: notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/combined.png (80 × 320 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \genfrac{(}{)}{0.8pt}{1}{x}{y} -o notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 80x87px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1 ~/projects/ztex/notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/ref.png ~/projects/ztex/notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/feat-binom/critique3/artifacts/critique-ref-1/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 65x80px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** (5 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "parentheses",
      "description": "The parentheses in our rendering appear slightly thicker compared to both references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "horizontal line",
      "description": "The horizontal line separating x and y in our rendering is slightly thicker than in the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of the fraction in our rendering appears to be slightly higher compared to the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "glyph sizes",
      "description": "The size of the 'x' and 'y' glyphs in our rendering seems to match well with both references.",
      "severity": "none",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "inter-term spacing",
      "description": "The spacing between the parentheses and the fraction in our rendering appears consistent with both references.",
      "severity": "none",
      "reference": "XeTeX|KaTeX"
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
      "region": "parentheses",
      "description": "The parentheses in our rendering appear slightly thicker compared to both references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "horizontal line",
      "description": "The horizontal line separating x and y in our rendering is slightly thicker than in the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of the fraction in our rendering appears to be slightly higher compared to the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "glyph sizes",
      "description": "The size of the 'x' and 'y' glyphs in our rendering seems to match well with both references.",
      "severity": "none",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "inter-term spacing",
      "description": "The spacing between the parentheses and the fraction in our rendering appears consistent with both references.",
      "severity": "none",
      "reference": "XeTeX|KaTeX"
    }
  ],
  "verdict": "PASS"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\genfrac{(}{)}{0.8pt}{1}{x}{y}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
