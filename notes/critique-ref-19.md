# Ref critique 19 — ztex vs XeTeX vs KaTeX

- **Formula**: `\left( x^2 \right) \left\{ x^{x^{x^{x^x}}} \right.`
- **Size**: 30.0 pt, background: `white`
- **Rendered**: 2026-08-14 13:22:19 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-19/render.svg (154.83 × 77.61 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-19/render.png (206 × 103 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-19/ref.png (198 × 90 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-19/katex.png (194 × 112 px)
- **Combined**: notes/artifacts/critique-ref-19/combined.png (206 × 369 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \left( x^2 \right) \left\{ x^{x^{x^{x^x}}} \right. -o notes/artifacts/critique-ref-19/render.svg -s 30.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 206x103px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-19 ~/projects/ztex/notes/artifacts/critique-ref-19/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-19/ref.png ~/projects/ztex/notes/artifacts/critique-ref-19/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-19/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 194x112px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** (5 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "superscripts",
      "description": "The superscripts in the power tower are slightly more spread out compared to both references.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "superscripts",
      "description": "The superscripts in the power tower are slightly more spread out compared to both references.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "opening parenthesis",
      "description": "The opening parenthesis '(' appears slightly thicker than in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "closing brace",
      "description": "The closing brace '}' has a different curvature and thickness compared to the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of the expression within the parentheses seems consistent with both references.",
      "severity": "none",
      "reference": "both"
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
      "region": "superscripts",
      "description": "The superscripts in the power tower are slightly more spread out compared to both references.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "superscripts",
      "description": "The superscripts in the power tower are slightly more spread out compared to both references.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "opening parenthesis",
      "description": "The opening parenthesis '(' appears slightly thicker than in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "closing brace",
      "description": "The closing brace '}' has a different curvature and thickness compared to the KaTeX reference.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of the expression within the parentheses seems consistent with both references.",
      "severity": "none",
      "reference": "both"
    }
  ],
  "verdict": "PASS"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\left( x^2 \right) \left\{ x^{x^{x^{x^x}}} \right.`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
