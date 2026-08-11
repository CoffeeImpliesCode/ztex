# Ref critique 9 — ztex vs XeTeX vs KaTeX

- **Formula**: `\int\limits_0^1 x\,dx`
- **Size**: 20.0 pt, background: `white`
- **Rendered**: 2026-08-14 09:16:01 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-9/render.svg (56.43 × 77.94 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-9/render.png (75 × 104 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-9/ref.png (97 × 117 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-9/katex.png (93 × 110 px)
- **Combined**: notes/artifacts/critique-ref-9/combined.png (97 × 420 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \int\limits_0^1 x\,dx -o notes/artifacts/critique-ref-9/render.svg -s 20.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 75x104px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-9 ~/projects/ztex/notes/artifacts/critique-ref-9/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-9/ref.png ~/projects/ztex/notes/artifacts/critique-ref-9/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-9/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 93x110px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (7 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the gap after the integral",
      "description": "The gap after the integral symbol is slightly wider compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the 'x' glyph size",
      "description": "The 'x' glyph appears slightly larger than in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the 'd' glyph size",
      "description": "The 'd' glyph appears slightly larger than in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the 'x dx' spacing",
      "description": "The spacing between 'x' and 'dx' is slightly tighter compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the upper limit '1'",
      "description": "The upper limit '1' is slightly offset to the right compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the lower limit '0'",
      "description": "The lower limit '0' is slightly offset to the right compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "big-op limit centering",
      "description": "The limits on the integral symbol are not perfectly centered vertically compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
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
      "region": "the gap after the integral",
      "description": "The gap after the integral symbol is slightly wider compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the 'x' glyph size",
      "description": "The 'x' glyph appears slightly larger than in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the 'd' glyph size",
      "description": "The 'd' glyph appears slightly larger than in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the 'x dx' spacing",
      "description": "The spacing between 'x' and 'dx' is slightly tighter compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the upper limit '1'",
      "description": "The upper limit '1' is slightly offset to the right compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the lower limit '0'",
      "description": "The lower limit '0' is slightly offset to the right compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "big-op limit centering",
      "description": "The limits on the integral symbol are not perfectly centered vertically compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "both"
    }
  ],
  "verdict": "FAIL"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\int\limits_0^1 x\,dx`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
