# Ref critique 3 — ztex vs XeTeX

- **Formula**: `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`
- **Size**: 48.0 pt, background: `white`
- **Rendered**: 2026-08-13 15:58:17 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-3/render.svg (365.77 × 171.29 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-3/render.png (488 × 228 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-3/ref.png (87 × 41 px)
- **Combined**: notes/artifacts/critique-ref-3/combined.png (976 × 243 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx -o notes/artifacts/critique-ref-3/render.svg -s 48.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 488x228px)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-3 ~/projects/ztex/notes/artifacts/critique-ref-3/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -o ~/projects/ztex/notes/artifacts/critique-ref-3/ref.png ~/projects/ztex/notes/artifacts/critique-ref-3/ref.pdf`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (7 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the sum symbol",
      "description": "The lower limit 'i=1' is slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the fraction \\frac{x_i}{n}",
      "description": "The 'x_i' and 'n' glyphs appear bolder compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the plus sign between the sum and the integral",
      "description": "The spacing before the plus sign is wider than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the integral symbol",
      "description": "The integral symbol appears slightly thinner compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the upper limit of the integral",
      "description": "The '1' is positioned slightly lower than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the lower limit of the integral",
      "description": "The '0' is positioned slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the 'dx' after the integral",
      "description": "The 'd' and 'x' are more spaced out compared to the reference.",
      "severity": "minor"
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
      "region": "the sum symbol",
      "description": "The lower limit 'i=1' is slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the fraction \\frac{x_i}{n}",
      "description": "The 'x_i' and 'n' glyphs appear bolder compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the plus sign between the sum and the integral",
      "description": "The spacing before the plus sign is wider than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the integral symbol",
      "description": "The integral symbol appears slightly thinner compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the upper limit of the integral",
      "description": "The '1' is positioned slightly lower than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the lower limit of the integral",
      "description": "The '0' is positioned slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the 'dx' after the integral",
      "description": "The 'd' and 'x' are more spaced out compared to the reference.",
      "severity": "minor"
    }
  ],
  "verdict": "FAIL"
}
```
```

## Prompt used

```text
\
Left half = ztex render, right half = XeTeX reference of the same formula: `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`.

List EVERY visual nit in the LEFT (ztex) half compared to the reference: inter-term spacing, glyph sizes, superscript/subscript positions, big-op limit centering, baseline alignment, overlaps, anything that differs. Be specific with regions ('the gap after the integral is too wide', 'the upper limit n sits 2px left of center'). Do NOT nit about overall scale (the halves are scaled to the same height). If an element matches the reference, say so. Output JSON: {"nits": [{"region": str, "description": str, "severity": "minor|major"}], "verdict": "PASS|FAIL"}.

```
