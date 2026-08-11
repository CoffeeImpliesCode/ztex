# Ref critique 4 — ztex vs XeTeX

- **Formula**: `\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx`
- **Size**: 48.0 pt, background: `white`
- **Rendered**: 2026-08-13 21:58:47 UTC
- **SVG (ztex)**: notes/artifacts/critique-ref-4/render.svg (399.37 × 217.70 pt)
- **PNG (ztex)**: notes/artifacts/critique-ref-4/render.png (532 × 290 px)
- **PNG (XeTeX ref)**: ~/projects/ztex/notes/artifacts/critique-ref-4/ref.png (468 × 199 px)
- **Combined**: notes/artifacts/critique-ref-4/combined.png (532 × 550 px)
- **Render cmd (ztex)**: `zig-out/bin/ztex -i \sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx -o notes/artifacts/critique-ref-4/render.svg -s 48.0 -b white`
- **Convert cmd (ztex)**: `PIL rasterize_svg (96dpi, 532x290px, 2x supersample + LANCZOS)`
- **Ref cmd (xelatex)**: `xelatex -interaction=nonstopmode -halt-on-error -output-directory=~/projects/ztex/notes/artifacts/critique-ref-4 ~/projects/ztex/notes/artifacts/critique-ref-4/ref.tex`
- **Ref convert cmd (mutool)**: `nix-shell -p mupdf --run mutool draw -F png -r 96 -o ~/projects/ztex/notes/artifacts/critique-ref-4/ref.png ~/projects/ztex/notes/artifacts/critique-ref-4/ref.pdf`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** (8 nits)

## Nits (JSON)

```json
{
  "nits": [
    {
      "region": "the subscript 'i=1' under the summation symbol",
      "description": "The subscript 'i=1' appears slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the superscript 'n' above the summation symbol",
      "description": "The superscript 'n' appears slightly lower than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the fraction '\\frac{x_i}{n}'",
      "description": "The 'x_i' and 'n' in the fraction appear slightly larger compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the plus sign '+' between the summation and the integral",
      "description": "The plus sign '+' has more space around it compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the integral symbol '\\int'",
      "description": "The integral symbol '\\int' appears slightly thinner compared to the reference.",
      "severity": "minor"
    },
    {
      "region": "the subscript '0' under the integral symbol",
      "description": "The subscript '0' appears slightly higher than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the superscript '1' above the integral symbol",
      "description": "The superscript '1' appears slightly lower than in the reference.",
      "severity": "minor"
    },
    {
      "region": "the 'x dx' inside the integral",
      "description": "The 'x dx' appears slightly larger compared to the reference.",
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
            "description": "The subscript 'i=1' appears slightly higher than in the reference.",
            "severity": "minor"
        },
        {
            "region": "the superscript 'n' above the summation symbol",
            "description": "The superscript 'n' appears slightly lower than in the reference.",
            "severity": "minor"
        },
        {
            "region": "the fraction '\\frac{x_i}{n}'",
            "description": "The 'x_i' and 'n' in the fraction appear slightly larger compared to the reference.",
            "severity": "minor"
        },
        {
            "region": "the plus sign '+' between the summation and the integral",
            "description": "The plus sign '+' has more space around it compared to the reference.",
            "severity": "minor"
        },
        {
            "region": "the integral symbol '\\int'",
            "description": "The integral symbol '\\int' appears slightly thinner compared to the reference.",
            "severity": "minor"
        },
        {
            "region": "the subscript '0' under the integral symbol",
            "description": "The subscript '0' appears slightly higher than in the reference.",
            "severity": "minor"
        },
        {
            "region": "the superscript '1' above the integral symbol",
            "description": "The superscript '1' appears slightly lower than in the reference.",
            "severity": "minor"
        },
        {
            "region": "the 'x dx' inside the integral",
            "description": "The 'x dx' appears slightly larger compared to the reference.",
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
