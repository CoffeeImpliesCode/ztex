# Ref critique 7 — ztex vs XeTeX vs KaTeX

- **Formula**: `\frac{d}{dt} \left( \frac{\partial L}{\partial \dot{q}} \right) = \frac{\partial L}{\partial q}`
- **Size**: 40.0 pt, background: `white`
- **Rendered**: 2026-08-14 05:56:13 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-7/render.svg (264.69 × 110.08 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-7/render.png (353 × 147 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-7/ref.png (368 × 144 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-7/katex.png (382 × 144 px)
- **Combined**: notes/artifacts/critique-ref-7/combined.png (382 × 505 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \frac{d}{dt} \left( \frac{\partial L}{\partial \dot{q}} \right) = \frac{\partial L}{\partial q} -o notes/artifacts/critique-ref-7/render.svg -s 40.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 353x147px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-7 ~/projects/ztex/notes/artifacts/critique-ref-7/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-7/ref.png ~/projects/ztex/notes/artifacts/critique-ref-7/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-7/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 382x144px, 2x supersample + LANCZOS)`
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
Three stacked panes of the same formula: `\frac{d}{dt} \left( \frac{\partial L}{\partial \dot{q}} \right) = \frac{\partial L}{\partial q}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
