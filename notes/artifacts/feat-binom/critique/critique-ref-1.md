# Ref critique 1 — ztex vs XeTeX vs KaTeX

- **Formula**: `\binom{n}{k}`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 10:20:24 UTC
- **SVG (ztex)**: notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/render.svg (77.50 × 88.27 pt)
- **PNG (ztex)**: notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/render.png (103 × 118 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/ref.png (116 × 131 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/katex.png (95 × 131 px)
- **Combined**: notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/combined.png (116 × 477 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \binom{n}{k} -o notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 103x118px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/feat-binom/critique/artifacts/critique-ref-1 ~/projects/ztex/notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/ref.png ~/projects/ztex/notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/feat-binom/critique/artifacts/critique-ref-1/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 95x131px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** (3 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the binomial coefficient parentheses",
      "description": "The parentheses in our rendering appear slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the gap between 'n' and 'k'",
      "description": "The vertical spacing between 'n' and 'k' in our rendering seems marginally tighter than in XeTeX but matches KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "the size of 'n' and 'k'",
      "description": "The glyphs 'n' and 'k' in our rendering seem slightly larger compared to XeTeX but match KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
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
      "region": "the binomial coefficient parentheses",
      "description": "The parentheses in our rendering appear slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the gap between 'n' and 'k'",
      "description": "The vertical spacing between 'n' and 'k' in our rendering seems marginally tighter than in XeTeX but matches KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "the size of 'n' and 'k'",
      "description": "The glyphs 'n' and 'k' in our rendering seem slightly larger compared to XeTeX but match KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    }
  ],
  "verdict": "PASS"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\binom{n}{k}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
