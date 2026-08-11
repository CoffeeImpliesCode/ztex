# Critique 33 — ztex render review

- **Formula**: `\lim_{x \to 0} f(x)`
- **Size**: 32.0 pt, background: `white`
- **Rendered**: 2026-08-13 05:23:06 UTC
- **SVG**: notes/artifacts/critique-33/render.svg (119.41 × 70.81 pt)
- **PNG**: notes/artifacts/critique-33/render.png (159 × 94 px)
- **Render cmd**: `zig-out/bin/ztex -i \lim_{x \to 0} f(x) -o notes/artifacts/critique-33/render.svg -s 32.0 -b white`
- **Convert cmd**: `PIL rasterize_svg (96dpi, 159x94px)`
- **Vision model**: qwen/qwen-2.5-vl-72b-instruct
- **Verdict**: **PASS** — geometric verifier clean; vision FAIL claims refuted (vision artifact)


## Geometric verification

- **Ink bbox (gt)**: `[11.469, 11.2, 104.979, 52.214]` pt = `[0.096, 0.1582, 0.8791, 0.7373]` of the 119.411×70.814 pt canvas
- **Edge clipping (gt)**: top 0.0 pt, bottom 0.0 pt, left 0.0 pt, right 0.0 pt

### Big-op / limit-op centering (gt)

| operator | limit | side | cx_op | cx_limit | offset (pt) |
|---|---|---|---|---|---|
| `lim` | `x→0` | below | 34.122 | 33.6 | **0.522** |

**Geometric defect count: 0**

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
      0.08,
      0.92,
      0.15,
      0.85
    ],
    "note": ""
  },
  "bigop_limits": [
    {
      "operator": "\\lim",
      "cx_op": 0.15,
      "cx_limit": 0.25,
      "offset_pct": 0.1,
      "visible": true,
      "note": "The limit 'x \\to 0' is not centered properly under '\\lim'."
    }
  ],
  "overlaps": [
    {
      "pair": "lim and f",
      "overlap_pct": 0.05,
      "location": "[0.15, 0.25]",
      "note": "There is a slight overlap between 'lim' and 'f', which affects readability."
    }
  ],
  "glyphs": [
    {
      "glyph": "\\to",
      "complete": false,
      "note": "The arrow in 'x \\to 0' appears incomplete, with a missing stroke."
    }
  ],
  "scripts": [
    {
      "script": "x \\to 0",
      "x": 0.25,
      "y": 0.35,
      "visible": true,
      "placement_ok": false,
      "note": "The subscript 'x \\to 0' is not placed correctly below '\\lim'."
    }
  ],
  "latex_likeness": {
    "score": 4,
    "top_deviations": [
      {
        "issue": "Improper alignment and spacing issues.",
        "severity": "major"
      },
      {
        "issue": "Incomplete rendering of some glyphs.",
        "severity": "minor"
      }
    ]
  },
  "summary": "The formula has several issues including improper alignment of limits, overlapping glyphs, and incomplete rendering of some symbols, leading to a significant deviation from LaTeX standards."
}
```

### Vision claim resolution (geometric confirm/refute)

| category | claim | geometric truth | disposition |
|---|---|---|---|
| overlaps | 1 overlap claim(s) | gt no ink-box intersections | **refuted (vision artifact)** |
| glyphs | \to incomplete | glyph ink box present | **refuted (vision artifact)** |
| scripts | x \to 0 misplaced | no geometric placement defect; script box clean | **refuted (no geometric counterpart)** |

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
    "ink_bbox": [0.08, 0.92, 0.15, 0.85],
    "note": ""
  },
  "bigop_limits": [
    {
      "operator": "\\lim",
      "cx_op": 0.15,
      "cx_limit": 0.25,
      "offset_pct": 0.10,
      "visible": true,
      "note": "The limit 'x \\to 0' is not centered properly under '\\lim'."
    }
  ],
  "overlaps": [
    {
      "pair": "lim and f",
      "overlap_pct": 0.05,
      "location": "[0.15, 0.25]",
      "note": "There is a slight overlap between 'lim' and 'f', which affects readability."
    }
  ],
  "glyphs": [
    {
      "glyph": "\\to",
      "complete": false,
      "note": "The arrow in 'x \\to 0' appears incomplete, with a missing stroke."
    }
  ],
  "scripts": [
    {
      "script": "x \\to 0",
      "x": 0.25,
      "y": 0.35,
      "visible": true,
      "placement_ok": false,
      "note": "The subscript 'x \\to 0' is not placed correctly below '\\lim'."
    }
  ],
  "latex_likeness": {
    "score": 4,
    "top_deviations": [
      {
        "issue": "Improper alignment and spacing issues.",
        "severity": "major"
      },
      {
        "issue": "Incomplete rendering of some glyphs.",
        "severity": "minor"
      }
    ]
  },
  "summary": "The formula has several issues including improper alignment of limits, overlapping glyphs, and incomplete rendering of some symbols, leading to a significant deviation from LaTeX standards."
}
```
```

## Prompt used

```text
\
You are an adversarial critic for a LaTeX math renderer (ztex). Your job is to HUNT FOR DEFECTS in the rendered formula image. Assume defects exist. Inspect the image carefully; do not rubber-stamp.

GROUND TRUTH FORMULA: `\lim_{x \to 0} f(x)`

The image is a PNG, 159x94 pixels. Report all positions as FRACTIONS of image width/height (0.0 = left/top edge, 1.0 = right/bottom edge), to 2-3 decimal places. If a measurement is ambiguous, say so and give your best estimate.

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
