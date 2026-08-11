# Ref critique 2 — ztex vs XeTeX vs KaTeX

- **Formula**: `\big( \frac{a}{b} \big) \Big[ x \Big] \bigg\{ y \bigg\} \Bigg\langle z \Bigg\rangle`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 09:52:25 UTC
- **SVG (ztex)**: notes/critique-big/artifacts/critique-ref-2/render.svg (331.92 × 120.96 pt)
- **PNG (ztex)**: notes/critique-big/artifacts/critique-ref-2/render.png (443 × 161 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/critique-big/artifacts/critique-ref-2/ref.png (365 × 160 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/critique-big/artifacts/critique-ref-2/katex.png (355 × 160 px)
- **Combined**: notes/critique-big/artifacts/critique-ref-2/combined.png (443 × 608 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \big( \frac{a}{b} \big) \Big[ x \Big] \bigg\{ y \bigg\} \Bigg\langle z \Bigg\rangle -o notes/critique-big/artifacts/critique-ref-2/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 443x161px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/critique-big/artifacts/critique-ref-2 ~/projects/ztex/notes/critique-big/artifacts/critique-ref-2/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/critique-big/artifacts/critique-ref-2/ref.png ~/projects/ztex/notes/critique-big/artifacts/critique-ref-2/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/critique-big/artifacts/critique-ref-2/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 355x160px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (5 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "fraction bar",
      "description": "The fraction bar in the parentheses is slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "spacing around 'x' in brackets",
      "description": "The space around 'x' within the square brackets appears wider than in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "spacing around 'y' in braces",
      "description": "The space around 'y' within the curly braces seems slightly larger compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "spacing around 'z' in angle brackets",
      "description": "The space around 'z' within the angle brackets is more pronounced compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "alignment of 'z' in angle brackets",
      "description": "The 'z' within the angle brackets is slightly lower compared to its position in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
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
      "region": "fraction bar",
      "description": "The fraction bar in the parentheses is slightly thicker compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "spacing around 'x' in brackets",
      "description": "The space around 'x' within the square brackets appears wider than in both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "spacing around 'y' in braces",
      "description": "The space around 'y' within the curly braces seems slightly larger compared to XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "spacing around 'z' in angle brackets",
      "description": "The space around 'z' within the angle brackets is more pronounced compared to both XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "alignment of 'z' in angle brackets",
      "description": "The 'z' within the angle brackets is slightly lower compared to its position in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    }
  ],
  "verdict": "FAIL"
}
```
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\big( \frac{a}{b} \big) \Big[ x \Big] \bigg\{ y \bigg\} \Bigg\langle z \Bigg\rangle`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
