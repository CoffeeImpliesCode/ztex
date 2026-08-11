# Ref critique 8 — ztex vs XeTeX vs KaTeX

- **Formula**: `\left( \frac{a}{b} \right)`
- **Size**: 40.0 pt, background: `white`
- **Rendered**: 2026-08-14 05:56:24 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-8/render.svg (83.00 × 98.08 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-8/render.png (111 × 131 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-8/ref.png (111 × 114 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-8/katex.png (101 × 115 px)
- **Combined**: notes/artifacts/critique-ref-8/combined.png (111 × 424 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \left( \frac{a}{b} \right) -o notes/artifacts/critique-ref-8/render.svg -s 40.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 111x131px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-8 ~/projects/ztex/notes/artifacts/critique-ref-8/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-8/ref.png ~/projects/ztex/notes/artifacts/critique-ref-8/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-8/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 101x115px, 2x supersample + LANCZOS)`
- **Vision model**: (not called)
- **Verdict**: **not-run** (0 nits)

## Nits (JSON)

```json
{
  "status": "not-run",
  "reason": "skipped by --no-critique"
}
```

## Raw response

```text
(no raw response)
```

## Prompt used

```text
\
Three stacked panes of the same formula: `\left( \frac{a}{b} \right)`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
