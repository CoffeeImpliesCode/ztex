# Ref critique 1 — ztex vs XeTeX vs KaTeX

- **Formula**: `\genfrac{[}{]}{0pt}{}{a}{b}`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 10:26:32 UTC
- **SVG (ztex)**: notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/render.svg (61.19 × 79.45 pt)
- **PNG (ztex)**: notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/render.png (82 × 106 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/ref.png (92 × 131 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/katex.png (68 × 131 px)
- **Combined**: notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/combined.png (92 × 480 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \genfrac{[}{]}{0pt}{}{a}{b} -o notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 82x106px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1 ~/projects/ztex/notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/ref.png ~/projects/ztex/notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/feat-binom/critique2/artifacts/critique-ref-1/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 68x131px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (6 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "bracket height",
      "description": "The brackets in our rendering are slightly taller than those in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "bracket thickness",
      "description": "The brackets in our rendering appear thicker compared to those in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "inter-term spacing",
      "description": "The vertical spacing between 'a' and 'b' in our rendering is slightly larger compared to XeTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'a' and 'b' in our rendering does not perfectly match the alignment seen in XeTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "bracket positioning",
      "description": "The brackets in our rendering are positioned slightly differently compared to KaTeX, affecting the overall appearance.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "glyph sizes",
      "description": "The size of 'a' and 'b' in our rendering appears slightly different from KaTeX, making them look less consistent.",
      "severity": "minor",
      "reference": "KaTeX"
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
      "region": "bracket height",
      "description": "The brackets in our rendering are slightly taller than those in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "bracket thickness",
      "description": "The brackets in our rendering appear thicker compared to those in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "inter-term spacing",
      "description": "The vertical spacing between 'a' and 'b' in our rendering is slightly larger compared to XeTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'a' and 'b' in our rendering does not perfectly match the alignment seen in XeTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "bracket positioning",
      "description": "The brackets in our rendering are positioned slightly differently compared to KaTeX, affecting the overall appearance.",
      "severity": "minor",
      "reference": "KaTeX"
    },
    {
      "region": "glyph sizes",
      "description": "The size of 'a' and 'b' in our rendering appears slightly different from KaTeX, making them look less consistent.",
      "severity": "minor",
      "reference": "KaTeX"
    }
  ],
  "verdict": "FAIL"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\genfrac{[}{]}{0pt}{}{a}{b}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
