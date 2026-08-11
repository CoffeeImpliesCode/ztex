# Ref critique 1 — ztex vs XeTeX vs KaTeX

- **Formula**: `\genfrac{}{}{1pt}{}{a}{b}`
- **Size**: 36.0 pt, background: `white`
- **Rendered**: 2026-08-14 10:29:00 UTC
- **SVG (ztex)**: notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/render.svg (27.20 × 78.32 pt)
- **PNG (ztex)**: notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/render.png (36 × 104 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/ref.png (45 × 103 px)
- **PNG (KaTeX ref)**: ~/projects/ztex/notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/katex.png (41 × 108 px)
- **Combined**: notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/combined.png (45 × 405 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \genfrac{}{}{1pt}{}{a}{b} -o notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/render.svg -s 36.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 36x104px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1 ~/projects/ztex/notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/ref.png ~/projects/ztex/notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/ref.pdf`
- **KaTeX cmd**: `katex -d -o ~/projects/ztex/notes/artifacts/feat-binom/critique4/artifacts/critique-ref-1/katex.html`
- **KaTeX convert cmd**: `KaTeX 0.16.28 PIL raster (96dpi, 41x108px, 2x supersample + LANCZOS)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (4 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the fraction bar",
      "description": "The fraction bar in OURS appears slightly thicker compared to both references.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between numerator and denominator",
      "description": "The vertical spacing between 'a' and 'b' in OURS seems slightly larger than in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "the baseline alignment of 'a'",
      "description": "The baseline of 'a' in OURS does not perfectly align with the baselines in the references, appearing slightly lower.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the baseline alignment of 'b'",
      "description": "The baseline of 'b' in OURS also appears slightly different from the references, being marginally higher.",
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
      "region": "the fraction bar",
      "description": "The fraction bar in OURS appears slightly thicker compared to both references.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the gap between numerator and denominator",
      "description": "The vertical spacing between 'a' and 'b' in OURS seems slightly larger than in the XeTeX reference.",
      "severity": "minor",
      "reference": "XeTeX"
    },
    {
      "region": "the baseline alignment of 'a'",
      "description": "The baseline of 'a' in OURS does not perfectly align with the baselines in the references, appearing slightly lower.",
      "severity": "minor",
      "reference": "both"
    },
    {
      "region": "the baseline alignment of 'b'",
      "description": "The baseline of 'b' in OURS also appears slightly different from the references, being marginally higher.",
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
Three stacked panes of the same formula: `\genfrac{}{}{1pt}{}{a}{b}`. Top = ztex render (ours), middle = XeTeX reference, bottom = KaTeX reference (web LaTeX).

Compare OURS against BOTH references. List EVERY visual nit in OURS vs either reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the panes are scaled to the same width). If an element matches the references, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major", "reference": "XeTeX|KaTeX"}], "verdict": "PASS|FAIL"}.

```
