# Ref critique 12 — ztex vs XeTeX vs KaTeX

- **Formula**: `\mathchoice{\frac{a}{b}}{c}{d}{e}`
- **Size**: 20.0 pt, background: `white`
- **Rendered**: 2026-08-14 10:12:07 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-12/render.svg (16.18 × 43.51 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-12/render.png (22 × 58 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-12/ref.png (34 × 65 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-12/katex.png (30 × 64 px)
- **Combined**: notes/artifacts/critique-ref-12/combined.png (34 × 281 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \mathchoice{\frac{a}{b}}{c}{d}{e} -o notes/artifacts/critique-ref-12/render.svg -s 20.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 22x58px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-12 ~/projects/ztex/notes/artifacts/critique-ref-12/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-12/ref.png ~/projects/ztex/notes/artifacts/critique-ref-12/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-12/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 30x64px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** (6 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the fraction bar",
      "description": "The fraction bar in OURS appears slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between 'a' and the fraction bar",
      "description": "The gap above the fraction bar for 'a' in OURS is marginally larger than in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between 'b' and the fraction bar",
      "description": "The gap below the fraction bar for 'b' in OURS is slightly smaller compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of 'a'",
      "description": "The size of 'a' in OURS seems to be slightly larger compared to XeTeX but matches KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "glyph size of 'b'",
      "description": "The size of 'b' in OURS matches KaTeX but appears slightly larger compared to XeTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "baseline alignment of 'c', 'd', 'e'",
      "description": "The baseline alignment of 'c', 'd', and 'e' in OURS matches both XeTeX and KaTeX.",
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
      "region": "the fraction bar",
      "description": "The fraction bar in OURS appears slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between 'a' and the fraction bar",
      "description": "The gap above the fraction bar for 'a' in OURS is marginally larger than in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between 'b' and the fraction bar",
      "description": "The gap below the fraction bar for 'b' in OURS is slightly smaller compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "glyph size of 'a'",
      "description": "The size of 'a' in OURS seems to be slightly larger compared to XeTeX but matches KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "glyph size of 'b'",
      "description": "The size of 'b' in OURS matches KaTeX but appears slightly larger compared to XeTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "baseline alignment of 'c', 'd', 'e'",
      "description": "The baseline alignment of 'c', 'd', and 'e' in OURS matches both XeTeX and KaTeX.",
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
Three stacked panes of the same formula: `\mathchoice{\frac{a}{b}}{c}{d}{e}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
