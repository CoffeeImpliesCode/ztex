# Ref critique 6 — ztex vs XeTeX vs KaTeX

- **Formula**: `\sin x + \cos x`
- **Size**: 40.0 pt, background: `white`
- **Rendered**: 2026-08-14 00:32:23 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-6/render.svg (238.63 × 65.60 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-6/render.png (318 × 87 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-6/ref.png (284 × 55 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-6/katex.png (293 × 56 px)
- **Combined**: notes/artifacts/critique-ref-6/combined.png (318 × 263 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \sin x + \cos x -o notes/artifacts/critique-ref-6/render.svg -s 40.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 318x87px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-6 ~/projects/ztex/notes/artifacts/critique-ref-6/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-6/ref.png ~/projects/ztex/notes/artifacts/critique-ref-6/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-6/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 293x56px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** (6 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the '+' symbol",
      "description": "The '+' symbol in our rendering appears slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "spacing between 'sin' and 'x'",
      "description": "The spacing between 'sin' and 'x' in our rendering is slightly tighter than in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "spacing between '+' and 'cos'",
      "description": "The spacing between '+' and 'cos' in our rendering is slightly different from both XeTeX and KaTeX, appearing marginally closer.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "spacing between 'cos' and 'x'",
      "description": "The spacing between 'cos' and 'x' in our rendering matches both XeTeX and KaTeX.",
      "severity": "none",
      "reference": "both"
    },
    {
      "region": "glyph size of 'sin' and 'cos'",
      "description": "The glyph sizes of 'sin' and 'cos' in our rendering appear consistent with both XeTeX and KaTeX.",
      "severity": "none",
      "reference": "both"
    },
    {
      "region": "glyph size of 'x'",
      "description": "The glyph size of 'x' in our rendering matches both XeTeX and KaTeX.",
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
      "region": "the '+' symbol",
      "description": "The '+' symbol in our rendering appears slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "spacing between 'sin' and 'x'",
      "description": "The spacing between 'sin' and 'x' in our rendering is slightly tighter than in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "spacing between '+' and 'cos'",
      "description": "The spacing between '+' and 'cos' in our rendering is slightly different from both XeTeX and KaTeX, appearing marginally closer.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "spacing between 'cos' and 'x'",
      "description": "The spacing between 'cos' and 'x' in our rendering matches both XeTeX and KaTeX.",
      "severity": "none",
      "reference": "both"
    },
    {
      "region": "glyph size of 'sin' and 'cos'",
      "description": "The glyph sizes of 'sin' and 'cos' in our rendering appear consistent with both XeTeX and KaTeX.",
      "severity": "none",
      "reference": "both"
    },
    {
      "region": "glyph size of 'x'",
      "description": "The glyph size of 'x' in our rendering matches both XeTeX and KaTeX.",
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
Three stacked panes of the same formula: `\sin x + \cos x`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
