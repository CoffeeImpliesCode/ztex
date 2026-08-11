# Ref critique 22 — ztex vs XeTeX vs KaTeX vs MathJax

- **Formula**: `\begin{array}{cc} a \bmod 2 & b \pod 3 \\ c \pmod{4} & d \mod{56} \\ \displaystyle a\bmod 2 & \displaystyle b \pod 3 \\ \displaystyle c\pmod{4} & \displaystyle d \mod{56} \end{array}`
- **Size**: 30.0 pt, background: `white`
- **Rendered**: 2026-08-15 22:59:52 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-22/render.svg (281.05 × 154.80 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-22/render.png (749 × 413 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-22/ref.png (766 × 415 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-22/katex.png (760 × 400 px)
- **PNG (MathJax ref)**: ~/projects/ztex/notes/artifacts/critique-ref-22/mathjax.png (894 × 416 px)
- **Combined**: notes/artifacts/critique-ref-22/combined.png (894 × 1716 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \begin{array}{cc} a \bmod 2 & b \pod 3 \\ c \pmod{4} & d \mod{56} \\ \displaystyle a\bmod 2 & \displaystyle b \pod 3 \\ \displaystyle c\pmod{4} & \displaystyle d \mod{56} \end{array} -o notes/artifacts/critique-ref-22/render.svg -s 30.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (192dpi, 749x413px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-22 ~/projects/ztex/notes/artifacts/critique-ref-22/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 192 -o ~/projects/ztex/notes/artifacts/critique-ref-22/ref.png ~/projects/ztex/notes/artifacts/critique-ref-22/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/critique-ref-22/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (192dpi, 760x400px, 4x supersample + LANCZOS)`
- **MathJax cmd**: `node ~/projects/ztex/scripts/mathjax_render.mjs \begin{array}{cc} a \bmod 2 & b \pod 3 \\ c \pmod{4} & d \mod{56} \\ \displaystyle a\bmod 2 & \displaystyle b \pod 3 \\ \displaystyle c\pmod{4} & \displaystyle d \mod{56} \end{array} --display --size 30.0 --scale 2 -o ~/projects/ztex/notes/artifacts/critique-ref-22/mathjax.svg`
- **MathJax convert cmd**: `resvg --background white ~/projects/ztex/notes/artifacts/critique-ref-22/mathjax.svg ~/projects/ztex/notes/artifacts/critique-ref-22/mathjax.png`
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
Four stacked panes of the same formula: `\begin{array}{cc} a \bmod 2 & b \pod 3 \\ c \pmod{4} & d \mod{56} \\ \displaystyle a\bmod 2 & \displaystyle b \pod 3 \\ \displaystyle c\pmod{4} & \displaystyle d \mod{56} \end{array}`. Top = ztex render (ours), then XeTeX, KaTeX, and MathJax (bottom) — the three web/TeX references.

Compare OURS against ALL THREE references. List EVERY visual nit in OURS vs any reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX|MathJax"}], "verdict": "PASS|FAIL"}.

```
