# Ref critique 3 — ztex vs XeTeX vs KaTeX

- **Formula**: `\big( \frac{a}{b} \big) \Big[ x \Big] \bigg\{ y \bigg\} \Bigg\langle z \Bigg\rangle`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 09:53:55 UTC
- **SVG (ztex)**: notes/critique-big/artifacts/critique-ref-3/render.svg (331.92 × 120.96 pt)
- **PNG (ztex)**: notes/critique-big/artifacts/critique-ref-3/render.png (443 × 161 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/critique-big/artifacts/critique-ref-3/ref.png (365 × 160 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/critique-big/artifacts/critique-ref-3/katex.png (355 × 160 px)
- **Combined**: notes/critique-big/artifacts/critique-ref-3/combined.png (443 × 608 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \big( \frac{a}{b} \big) \Big[ x \Big] \bigg\{ y \bigg\} \Bigg\langle z \Bigg\rangle -o notes/critique-big/artifacts/critique-ref-3/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 443x161px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/critique-big/artifacts/critique-ref-3 ~/projects/ztex/notes/critique-big/artifacts/critique-ref-3/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/critique-big/artifacts/critique-ref-3/ref.png ~/projects/ztex/notes/critique-big/artifacts/critique-ref-3/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/critique-big/artifacts/critique-ref-3/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 355x160px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (5 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "fraction bar",
      "description": "The fraction bar in the parenthesis is slightly thicker compared to both XeTeX and KaTeX.",
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
      "region": "curly braces around 'y'",
      "description": "The curly braces around 'y' are more rounded in our rendering compared to the sharper curves in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "angle brackets around 'z'",
      "description": "The angle brackets around 'z' have a different curvature and thickness compared to both references, appearing less sharp.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'x', 'y', and 'z' seems consistent with both references.",
      "severity": "none",
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
      "description": "The fraction bar in the parenthesis is slightly thicker compared to both XeTeX and KaTeX.",
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
      "region": "curly braces around 'y'",
      "description": "The curly braces around 'y' are more rounded in our rendering compared to the sharper curves in XeTeX and KaTeX.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "angle brackets around 'z'",
      "description": "The angle brackets around 'z' have a different curvature and thickness compared to both references, appearing less sharp.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "baseline alignment",
      "description": "The baseline alignment of 'x', 'y', and 'z' seems consistent with both references.",
      "severity": "none",
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
