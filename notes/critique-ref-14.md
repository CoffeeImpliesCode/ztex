# Ref critique 14 — ztex vs XeTeX vs KaTeX

- **Formula**: `\begin{cases} x & x > 0 \\ -x & x \leq 0 \end{cases}`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 11:34:09 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-14/render.svg (209.43 × 120.96 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-14/render.png (279 × 161 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-14/ref.png (289 × 160 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-14/katex.png (226 × 160 px)
- **Combined**: notes/artifacts/critique-ref-14/combined.png (289 × 585 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \begin{cases} x & x > 0 \\ -x & x \leq 0 \end{cases} -o notes/artifacts/critique-ref-14/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 279x161px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-14 ~/projects/ztex/notes/artifacts/critique-ref-14/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-14/ref.png ~/projects/ztex/notes/artifacts/critique-ref-14/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-14/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 226x160px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (7 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the gap between the brace and the first term",
      "description": "The gap is slightly narrower compared to both references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the spacing between 'x' and '>' in the top row",
      "description": "The spacing is tighter than in the XeTeX reference but matches KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "the spacing between '-x' and '<=' in the bottom row",
      "description": "The spacing is tighter than in the XeTeX reference but matches KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "the size of the minus sign in '-x'",
      "description": "The minus sign appears slightly smaller compared to both references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the alignment of 'x' in the top row",
      "description": "The 'x' aligns well with both references.",
      "severity": "none",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the alignment of '-x' in the bottom row",
      "description": "The '-x' aligns well with both references.",
      "severity": "none",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the size of the '0' in both rows",
      "description": "The '0' matches the size in the XeTeX reference but is slightly larger than in KaTeX.",
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
      "region": "the gap between the brace and the first term",
      "description": "The gap is slightly narrower compared to both references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the spacing between 'x' and '>' in the top row",
      "description": "The spacing is tighter than in the XeTeX reference but matches KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "the spacing between '-x' and '<=' in the bottom row",
      "description": "The spacing is tighter than in the XeTeX reference but matches KaTeX.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "the size of the minus sign in '-x'",
      "description": "The minus sign appears slightly smaller compared to both references.",
      "severity": "minor",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the alignment of 'x' in the top row",
      "description": "The 'x' aligns well with both references.",
      "severity": "none",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the alignment of '-x' in the bottom row",
      "description": "The '-x' aligns well with both references.",
      "severity": "none",
      "reference": "XeTeX|KaTeX"
    },
    {
      "region": "the size of the '0' in both rows",
      "description": "The '0' matches the size in the XeTeX reference but is slightly larger than in KaTeX.",
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
Three stacked panes of the same formula: `\begin{cases} x & x > 0 \\ -x & x \leq 0 \end{cases}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
