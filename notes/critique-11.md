# Critique 11 — ztex render review

- **Formula**: `\sum_{i=1}^{n} x_i`
- **Size**: 32.0 pt, background: `white`
- **Rendered**: 2026-08-13 04:11:14 UTC
- **SVG**: notes/artifacts/critique-11/render.svg (107.63 × 115.61 pt)
- **PNG**: notes/artifacts/critique-11/render.png (144 × 154 px)
- **Render cmd**: `zig-out/bin/ztex -i \sum_{i=1}^{n} x_i -o notes/artifacts/critique-11/render.svg -s 32.0 -b white`
- **Convert cmd**: `PIL rasterize_svg (96dpi, 144x154px)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **FAIL** — The rendering has issues with big-op limit centering and subscript placement, leading to a FAIL verdict.

## Vision critique

### Parsed verdict

```json
{
  "verdict": "FAIL",
  "clipping": {
    "top_pct": 0,
    "bottom_pct": 0,
    "left_pct": 0,
    "right_pct": 0,
    "ink_bbox": [
      0.15,
      0.85,
      0.1,
      0.9
    ],
    "note": ""
  },
  "bigop_limits": [
    {
      "operator": "\\sum",
      "cx_op": 0.35,
      "cx_limit": 0.3,
      "offset_pct": 0.05,
      "visible": true,
      "note": "|cx_op - cx_limit| > 0.01, which is a FAIL."
    }
  ],
  "overlaps": [],
  "glyphs": [
    {
      "glyph": "\\sum",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "n",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "i=1",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "x_i",
      "complete": true,
      "note": ""
    }
  ],
  "scripts": [
    {
      "script": "n",
      "x": 0.3,
      "y": 0.2,
      "visible": true,
      "placement_ok": true,
      "note": ""
    },
    {
      "script": "i=1",
      "x": 0.3,
      "y": 0.4,
      "visible": true,
      "placement_ok": false,
      "note": "Placement is slightly off, should be more centered under \\sum."
    }
  ],
  "latex_likeness": {
    "score": 7,
    "top_deviations": [
      {
        "issue": "Big-op limit centering issue",
        "severity": "major"
      },
      {
        "issue": "Subscript placement slightly off",
        "severity": "minor"
      }
    ]
  },
  "summary": "The rendering has issues with big-op limit centering and subscript placement, leading to a FAIL verdict."
}
```

### Raw response

```text
```json
{
  "verdict": "FAIL",
  "clipping": {
    "top_pct": 0,
    "bottom_pct": 0,
    "left_pct": 0,
    "right_pct": 0,
    "ink_bbox": [0.15, 0.85, 0.10, 0.90],
    "note": ""
  },
  "bigop_limits": [
    {
      "operator": "\\sum",
      "cx_op": 0.35,
      "cx_limit": 0.30,
      "offset_pct": 0.05,
      "visible": true,
      "note": "|cx_op - cx_limit| > 0.01, which is a FAIL."
    }
  ],
  "overlaps": [],
  "glyphs": [
    {
      "glyph": "\\sum",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "n",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "i=1",
      "complete": true,
      "note": ""
    },
    {
      "glyph": "x_i",
      "complete": true,
      "note": ""
    }
  ],
  "scripts": [
    {
      "script": "n",
      "x": 0.30,
      "y": 0.20,
      "visible": true,
      "placement_ok": true,
      "note": ""
    },
    {
      "script": "i=1",
      "x": 0.30,
      "y": 0.40,
      "visible": true,
      "placement_ok": false,
      "note": "Placement is slightly off, should be more centered under \\sum."
    }
  ],
  "latex_likeness": {
    "score": 7,
    "top_deviations": [
      {
        "issue": "Big-op limit centering issue",
        "severity": "major"
      },
      {
        "issue": "Subscript placement slightly off",
        "severity": "minor"
      }
    ]
  },
  "summary": "The rendering has issues with big-op limit centering and subscript placement, leading to a FAIL verdict."
}
```
```

## Prompt used

```text
\
You are an adversarial critic for a LaTeX math renderer (ztex). Your job is to HUNT FOR DEFECTS in the rendered formula image. Assume defects exist. Inspect the image carefully; do not rubber-stamp.

GROUND TRUTH FORMULA: `\sum_{i=1}^{n} x_i`

The image is a PNG, 144x154 pixels. Report all positions as FRACTIONS of image width/height (0.0 = left/top edge, 1.0 = right/bottom edge), to 2-3 decimal places. If a measurement is ambiguous, say so and give your best estimate.

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
