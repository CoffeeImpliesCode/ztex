# Ref critique 5 — ztex vs XeTeX vs KaTeX

- **Formula**: `\sqrt{x^2+1}`
- **Size**: 40.0 pt, background: `white`
- **Rendered**: 2026-08-14 00:31:47 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-5/render.svg (169.84 × 77.99 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-5/render.png (226 × 104 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-5/ref.png (211 × 82 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-5/katex.png (207 × 79 px)
- **Combined**: notes/artifacts/critique-ref-5/combined.png (226 × 331 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \sqrt{x^2+1} -o notes/artifacts/critique-ref-5/render.svg -s 40.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 226x104px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-5 ~/projects/ztex/notes/artifacts/critique-ref-5/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-5/ref.png ~/projects/ztex/notes/artifacts/critique-ref-5/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-5/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 207x79px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** (5 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "superscript position",
      "description": "The superscript '2' in OURS appears slightly higher than in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "inter-term spacing",
      "description": "The space between 'x^2' and '+' in OURS is marginally wider compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of '+'",
      "description": "The '+' symbol in OURS seems slightly larger compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of '1'",
      "description": "The '1' in OURS appears slightly taller than in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'x^2 + 1' under the square root in OURS matches both references.",
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
      "region": "superscript position",
      "description": "The superscript '2' in OURS appears slightly higher than in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "inter-term spacing",
      "description": "The space between 'x^2' and '+' in OURS is marginally wider compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of '+'",
      "description": "The '+' symbol in OURS seems slightly larger compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of '1'",
      "description": "The '1' in OURS appears slightly taller than in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'x^2 + 1' under the square root in OURS matches both references.",
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
Three stacked panes of the same formula: `\sqrt{x^2+1}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
