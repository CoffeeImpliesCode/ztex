# Pipeline STAGE 4 fixes — svg.zig pt units (F2) + per-style fonts (F4)

Date: 2026-08-13. Files: src/svg.zig (main), src/layout/draw.zig (minimal).
Fixes pipeline-svg.md findings F2 (HIGH) and F4 (MEDIUM). F1/F3 (big-op
placement/size) are handled by a sibling task (layout/metrics geometry); F5/F6
documented only.

## F2 — pt units (renders at 0.75× without them)

The draw list is in points (`-s 20` = 20pt), but svg.zig emitted unitless
numbers. SVG user units are px, so a browser rendered the output at 96/72 =
0.75× the declared size.

Fix: every length attribute now carries an explicit `pt` unit:
- `<svg width="…pt" height="…pt" viewBox="0 0 … …">` — width/height in pt;
  viewBox stays unitless (its user units are pinned to pt by width/height).
- `<text x="…pt" y="…pt" font-size="…pt">`, `<rect x/y/width/height="…pt">`,
  `<line x1/y1/x2/y2/stroke-width="…pt">`, background `<rect>` likewise.

Verified in Chromium (headless, 96dpi): a `-s 60` render's x ink measures
34px = 25.83pt × 4/3, i.e. the output is exactly the declared pt size
(previously it would have been 0.75×).

## F4 — per-style font-family / font-style (\text, \mathrm upright)

The draw list's Text primitive had no style field, so every run was emitted
with one fixed math family — LMMath's default glyphs are italic, so
`\text{hi}`/`\mathrm{ab}` rendered italic.

Fix (two parts):

1. src/layout/draw.zig (minimal — the Text primitive lacked the field):
   - `Text` gains `style: atom.CharStyle` (no default; every producer sets it).
   - `flatten`'s char branch copies `b.style` (already carried per box by
     layout: `\text`/`\mathrm` → `.roman`, variables → `.italic`, `\mathbf`
     → `.bold`, `\sum`/`\int` synthetic ops → `.italic`).
   - `pub const atom = @import("ztex.atom")` so svg.zig can name the type
     (the ztex.svg module imports only ztex.layout; kept edits to the two
     allowed files).

2. src/svg.zig:
   - New `Options.text_font_family` (default "Latin Modern Roman, DejaVu
     Serif, serif"); `font_family` is now documented as the math family.
   - `fontSpec(style, opts)` maps each CharStyle to
     family + font-style (+ font-weight):
     | CharStyle | family | font-style | font-weight |
     |---|---|---|---|
     | italic (math) | math family | italic | — |
     | roman (\text, \mathrm) | text family | normal | — |
     | bold (\mathbf) | text family | normal | bold |
     | bb / cal / frak | math family (LMMath has the glyphs) | normal | — |
     | sans | DejaVu Sans, sans-serif | normal | — |
     | mono | DejaVu Sans Mono, monospace | normal | — |
   - Each `<text>` emits font-style (and font-weight when non-empty).

Empirics: Chromium does NOT synthesize oblique on top of LMMath's already
italic shapes when font-style="italic" is set (probed with 48pt A + 60pt x
side-by-side screenshots: italic and unstyled math runs render identically,
both slanted). So emitting font-style="italic" is safe with LMMath present
and additionally makes the LM Roman Italic / DejaVu Serif Italic fallbacks
correct when LMMath is absent (F5 mitigation). The family switch is what
makes \text/\mathrm upright: verified — `x\text{x}` at 60pt renders a
right-leaning math x and a symmetric upright text x; `\text{hi}` and
`\mathrm{ab}` emit `font-family="Latin Modern Roman, DejaVu Serif, serif"
font-style="normal"`.

## Verification (rendered with the rebuilt binary, `-s 20 -p 0 -b none`)

- `x` → `<text x="0pt" y="8.6111pt" font-size="20pt" font-family="Latin
  Modern Math, …" font-style="italic"` ✓ (italic math, pt units)
- `\text{hi}` → `font-family="Latin Modern Roman, DejaVu Serif, serif"
  font-style="normal"` ✓ (upright)
- `\mathrm{ab}` → roman family + normal ✓
- `\sum_{i=1}^{n} \frac{x_i}{n}` → pt units on every text/rect; variables and
  the ∑ in the math family italic; fraction bar rect `height="0.8pt"` ✓
- `zig build -Doptimize=ReleaseSafe` passes. `zig build test`: 95/98 pass.
  The 3 failures are all expected:
  1. `regression: svg snapshots` — this task's INTENTIONAL output change
     (goldens regenerate; not touched).
  2. `regression: draw-list snapshots` + `layout: big operator limits …` —
     big-op geometry (∑ font-size 28 = 20×1.4, new shifts) from the sibling
     F1/F3 fix in layout/metrics; unrelated to this change (no layout
     geometry touched here).

## Notes

- Padding (`-p`) is in the same pt space as the layout; comment updated to
  say pt. CLI help in main.zig untouched (out of scope).
- `viewBox` keeps unitless numbers — correct per SVG spec (viewBox takes
  plain numbers; width/height carry the units).
- No changes to tests/goldens per the task constraints.
