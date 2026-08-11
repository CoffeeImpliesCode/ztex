# Critique 24 — ztex render review

- **Formula**: `a \cdot b + c`
- **Size**: 32.0 pt, background: `white`
- **Rendered**: 2026-08-13 05:11:53 UTC
- **SVG**: notes/artifacts/critique-24/render.svg (132.64 × 53.66 pt)
- **PNG**: notes/artifacts/critique-24/render.png (177 × 72 px)
- **Render cmd**: `zig-out/bin/ztex -i a \cdot b + c -o notes/artifacts/critique-24/render.svg -s 32.0 -b white`
- **Convert cmd**: `PIL rasterize_svg (96dpi, 177x72px)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** — geometric verifier clean; vision PASS


## Geometric verification

- **Ink bbox (gt)**: `[12.224, 11.2, 120.508, 36.064]` pt = `[0.0922, 0.2087, 0.9086, 0.672]` of the 132.636×53.664 pt canvas
- **Edge clipping (gt)**: top 0.0 pt, bottom 0.0 pt, left 0.0 pt, right 0.0 pt

**Geometric defect count: 0**

## Vision critique

### Parsed verdict

```json
{
  "verdict": "PASS",
  "clipping": {
    "top_pct": 0,
    "bottom_pct": 0,
    "left_pct": 0,
    "right_pct": 0,
    "ink_bbox": [
      0.08,
      0.92,
      0.25,
      0.75
    ],
    "note": ""
  },
  "bigop_limits": [],
  "overlaps": [],
  "glyphs": [
    {
      "glyph": "a",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "\\cdot",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "b",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "+",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "c",
      "complete": true,
      "note": ""
    }
  ],
  "scripts": [],
  "latex_likeness": {
    "score": 9,
    "top_deviations": [
      {
        "issue": "The spacing between 'a \\cdot b' could be slightly tighter.",
        "severity": "minor"
      }
    ]
  },
  "summary": "The formula appears correctly rendered without clipping, overlaps, or incomplete glyphs. The LaTeX-likeness is high with only minor spacing adjustments needed."
}
```

### Raw response

```text
```json
{
  "verdict": "PASS",
  "clipping": {"top_pct": 0, "bottom_pct": 0, "left_pct": 0, "right_pct": 0, "ink_bbox": [0.08, 0.92, 0.25, 0.75], "note": ""},
  "bigop_limits": [],
  "overlaps": [],
  "glyphs": [{"glyph": "a", "complete": true, "note": ""}, {"glyph": "\\cdot", "complete": true, "note": ""}, {"glyph": "b", "complete": true, "note": ""}, {"glyph": "+", "complete": true, "note": ""}, {"glyph": "c", "complete": true, "note": ""}],
  "scripts": [],
  "latex_likeness": {"score": 9, "top_deviations": [{"issue": "The spacing between 'a \\cdot b' could be slightly tighter.", "severity": "minor"}]},
  "summary": "The formula appears correctly rendered without clipping, overlaps, or incomplete glyphs. The LaTeX-likeness is high with only minor spacing adjustments needed."
}
```
```

## Prompt used

```text
\
You are an adversarial critic for a LaTeX math renderer (ztex). Your job is to HUNT FOR DEFECTS in the rendered formula image. Assume defects exist. Inspect the image carefully; do not rubber-stamp.

GROUND TRUTH FORMULA: `a \cdot b + c`

The image is a PNG, 177x72 pixels. Report all positions as FRACTIONS of image width/height (0.0 = left/top edge, 1.0 = right/bottom edge), to 2-3 decimal places. If a measurement is ambiguous, say so and give your best estimate.

Check EVERY item below; missing a check is a failure of this critique.

1. EDGE CLIPPING — is any ink cut off at an image border?
   - For each edge (top, bottom, left, right) estimate the percentage of the cut glyph that is missing (0 = no clipping).
   - Estimate the ink bounding box of the whole formula: [x_left, x_right, y_top, y_bottom] as fractions.
   - A glyph touching the border is a FAIL even if only a sliver is missing.

2. BIG-OP LIMIT CENTERING — for every operator with limits (\sum, \prod, \int, \bigcup, ...):
   - Estimate the horizontal center of the operator glyph: cx_op.
   - Estimate the horizontal center of each attached limit (numerator/limit above or below, or the endpoint limits of an \int): cx_limit.
   - Report |cx_op - cx_limit| as a fraction of image width. > 0.01 (1% of width) is a FAIL.
   - Also check each limit is fully visible and not merged with the operator glyph.

3. ADJACENT-TERM OVERLAP — do neighboring symbols or lines overlap or touch?
   - For each suspicious pair, name both glyphs, estimate the overlapped fraction of the smaller glyph, and give the location.
   - Overlap > 2% of the smaller glyph is a FAIL. Flag lines that punch through fraction bars or strike through other glyphs.

4. COMPLETE GLYPHS — is every glyph complete (no stubs, no missing strokes, no shorn serifs)?
   - Pay special attention to large operators (\int, \sum, \sqrt, tall parentheses) and wide accents.
   - A truncated glyph is a FAIL even if the cut is at the canvas edge (also report it under clipping).

5. SUBSCRIPTS & LIMITS — for every sub/superscript and every limit:
   - Is it visible (not blank, not fused into the base glyph)?
   - Is its placement correct relative to the base (subscript below/right, superscript above/right, limits above/below the operator)?
   - Report each script's center as (x, y) fractions and whether placement is OK.

6. LATEX-LIKENESS — does this look like a professional LaTeX render of the given formula?
   - Score 0-10 (10 = indistinguishable from LaTeX).
   - List the top visual deviations, each with severity minor/major.

ANSWER FORMAT — output ONLY one JSON object, no prose before or after:

{
  "verdict": "PASS" or "FAIL",
  "clipping": {"top_pct": 0, "bottom_pct": 0, "left_pct": 0, "right_pct": 0, "ink_bbox": [0, 0, 0, 0], "note": ""},
  "bigop_limits": [{"operator": "", "cx_op": 0.0, "cx_limit": 0.0, "offset_pct": 0.0, "visible": true, "note": ""}],
  "overlaps": [{"pair": "", "overlap_pct": 0.0, "location": "", "note": ""}],
  "glyphs": [{"glyph": "", "complete": true, "note": ""}],
  "scripts": [{"script": "", "x": 0.0, "y": 0.0, "visible": true, "placement_ok": true, "note": ""}],
  "latex_likeness": {"score": 0, "top_deviations": [{"issue": "", "severity": ""}]},
  "summary": "one or two sentences"
}

Set "verdict" to "FAIL" if ANY check above fails. Empty arrays mean no problems found in that category. Do not invent problems that are not visible; but hunt for real ones.

```
