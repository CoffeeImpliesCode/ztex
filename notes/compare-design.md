# Glyph-Alignment Comparison Design — `compare_engines.py`

Spec for the engine-vs-reference glyph geometry comparator. Replaces the
SVG-parsing `scripts/compare_geom.py` with a record-based, delta-reporting
tool. Inputs are JSON arrays of per-glyph records; the tool never touches
SVGs or rasters.

## Input JSON schema (two files, `--ours` and `--ref`)

```json
{
  "engine": "ztex" | "xelatex",
  "formula": "\\sum_{i=1}^{n} x_i",
  "unit": "pt",
  "up": true,
  "base_size_pt": 20.0,
  "glyphs": [ {"glyph": "∑", "x": 10.5, "y": 12.0, "size": 40.0} ]
}
```

`(x,y)` = glyph baseline (or known ref point), same convention per engine.
`up` = true if y-axis points up (TeX/PDF), false if down (SVG/HTML). `glyphs`
in render (left→right) order. `size` = rendered font size (or glyph height).

## 1. Normalization (`normalize`)

1. **Axis**: if `up == false`, negate `y` so both are y-up.
2. **Unit**: scale `x,y,size` to points.
3. **Order**: sort by `x` (stable); equal `x` → descending `y` (sup above sub).

Both engines render the same formula, so a logical glyph may appear at
different `size` per style (text vs script vs scriptscript). Keep every record;
style is inferred from `size` relative to `base_size_pt`.

## 2. Alignment (`align`)

Same-glyph, same-order runs → Needleman–Wunsch (NW) on glyph identity:

```
match(a,b)   = glyph_equal(a,b) ? 4 : (glyph_normeq(a,b) ? 2 : -4)
gap_penalty  = -1
```

`glyph_equal`: exact codepoint. `glyph_normeq`: NFC canonical equivalence
(joins ligature splits / combining-mark differences). NW output = aligned
index vectors (ours→ref), gap sentinels `-1`.

- **Missing glyphs**: left gapped → `missing` in `unmatched`, not a delta.
- **Reference merges ours**: two ours glyphs → one ref glyph → `merge` (report
  merged ref vs sum of ours pair: x = first of pair, y = mean).
- **Ours splits ref**: symmetric.
- **Reorders**: flagged, excluded from deltas.
- **Tie-break**: prefer diagonal (match) over gaps.

## 3. Per-glyph delta (`delta`)

For each aligned pair (ours `o`, ref `r`), after baseline alignment:

```
dx  = o.x - r.x          # >0 => ours right of ref
dy  = o.y - r.y          # >0 => ours above ref (y-up)
dxi = dx / r.size        # normalized by ref size
dyi = dy / r.size
sr  = o.size / r.size    # size ratio; ~1.0 => style matches
```

`style(cls) = "scriptscript" if size<0.5*b else "script" if size<0.8*b else
"text"` (b = base_size_pt). Flag a `style_mismatch` when the engines disagree
on the style class of the same glyph.

## 4. Baseline alignment (`baseline_shift`)

Remove ONE global 2D offset before deltas so an origin/bbox-height mismatch
doesn't dominate. Strategy (default `first-top`):

- **first-top**: align `o[0]` to `r[0]` baseline. Robust when the formula
  starts with a same-baseline glyph.
- **bbox-center**: if records carry `bbox`, align formula bbox centers.
- **mode**: align the y-mode (most common baseline) — good when `o[0]` is a
  tall operator (∑, ∫).

`ox, oy` reported as `baseline_offset` (a pure global shift is visible
separately from per-glyph deltas).

## 5. Aggregation (`summarize`)

```
n_pairs, n_unmatched(ours), n_unmatched(ref), n_merge, n_style_mismatch
mean|dx|, max|dx|, mean|dy|, max|dy|
max|dxi|, max|dyi|
top_k = glyph pairs with largest norm sqrt(dx²+dy²)
```

## Output format

**JSON**:

```json
{
  "formula": "\\sum_{i=1}^{n} x_i",
  "baseline_offset": {"dx": 0.0, "dy": 0.0},
  "stats": {"pairs": 9, "ours_unmatched": 0, "ref_unmatched": 0,
            "merges": 0, "style_mismatches": 0,
            "mean_abs_dx": 0.31, "max_abs_dx": 1.2,
            "mean_abs_dy": 0.05, "max_abs_dy": 0.2,
            "max_norm_dxi": 0.03, "max_norm_dyi": 0.005},
  "deltas": [ {"glyph": "∑", "dx": 1.2, "dy": 0.2, "dxi": 0.03, "dyi": 0.005,
               "size_ours": 40.0, "size_ref": 40.0, "size_ratio": 1.0,
               "style_ours": "text", "style_ref": "text"} ],
  "unmatched": [{"side": "ours", "glyph": "𝔭"}],
  "top_issues": ["XeTeX's ∑ is 1.20pt right and 0.20pt up"]
}
```

**Human-readable** (stdout):

```
XeTeX's ∑ is 1.20pt right and 0.20pt up.
ztex's 2 is 0.90pt left (script height 9.3 vs ref 9.3; ratio 1.00).
Missing in ztex: 𝔭 (1 glyph).
```

Direction from signs: dx>0 right, <0 left; dy>0 up, <0 down. pt→px via
`px = pt * (base_size_pt/20) * 96/72` (or `--dpi`).

## Structure

Single module `scripts/compare_engines.py`:
`--ours a.json --ref b.json --out res.json [--baseline first-top|bbox-center|mode] [--top 5] [--px]`.
Pure functions `normalize`, `align`, `delta`, `baseline_shift`, `summarize`,
each unit-testable. Renderer-side JSON extraction is a separate concern
(later replaces the SVG parsing in `compare_geom.py`).
