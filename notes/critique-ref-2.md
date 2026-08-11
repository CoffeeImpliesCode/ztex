# Ref critique 2 — ztex vs XeTeX

- **Formula**: `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`
- **Size**: 48.0 pt, background: `white`
- **Rendered**: 2026-08-13 14:44:02 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-2/render.svg (348.64 × 138.81 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-2/render.png (465 × 185 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-2/ref.png (87 × 41 px)
- **Combined**: notes/artifacts/critique-ref-2/combined.png (862 × 200 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx -o notes/artifacts/critique-ref-2/render.svg -s 48.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 465x185px)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-2 ~/projects/ztex/notes/artifacts/critique-ref-2/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -o ~/projects/ztex/notes/artifacts/critique-ref-2/ref.png ~/projects/ztex/notes/artifacts/critique-ref-2/ref.pdf`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (8 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the subscript 'i=1' under the summation symbol",
      "description": "The subscript 'i=1' is positioned slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the superscript 'n' above the summation symbol",
      "description": "The superscript 'n' is positioned slightly lower than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the fraction '\\frac{x_i}{n}'",
      "description": "The fraction bar is slightly thicker and the glyphs are more spaced out compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the gap after the summation term before the plus sign",
      "description": "The gap is wider than in the reference, causing less tight spacing.",
      "severity": "minor"
    },
    {
      "region": "the integral symbol",
      "description": "The integral symbol appears slightly bolder and taller than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the subscript '0' under the integral symbol",
      "description": "The subscript '0' is positioned slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the superscript '1' above the integral symbol",
      "description": "The superscript '1' is positioned slightly lower than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the 'x dx' part after the integral",
      "description": "The 'x' and 'dx' are more spaced out compared to the reference.",
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
      "region": "the subscript 'i=1' under the summation symbol",
      "description": "The subscript 'i=1' is positioned slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the superscript 'n' above the summation symbol",
      "description": "The superscript 'n' is positioned slightly lower than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the fraction '\\frac{x_i}{n}'",
      "description": "The fraction bar is slightly thicker and the glyphs are more spaced out compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the gap after the summation term before the plus sign",
      "description": "The gap is wider than in the reference, causing less tight spacing.",
      "severity": "minor"
    },
    {
      "region": "the integral symbol",
      "description": "The integral symbol appears slightly bolder and taller than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the subscript '0' under the integral symbol",
      "description": "The subscript '0' is positioned slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the superscript '1' above the integral symbol",
      "description": "The superscript '1' is positioned slightly lower than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the 'x dx' part after the integral",
      "description": "The 'x' and 'dx' are more spaced out compared to the reference.",
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
