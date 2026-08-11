# Vision-model adversarial critic for ztex renders (two-stage propose/verify)

Use the vision model as an ADVERSARIAL PROPOSER: it hunts for rendering
defects instead of rubber-stamping. Every claim it makes is then VERIFIED by
a deterministic geometric check (SVG + Latin Modern font metrics) before it
is allowed to fail the verdict. The loop below is the QA gate for layout
changes.

## Pipeline

```
formula (LaTeX)
   -> ztex            (SVG)
   -> PIL + LM fonts  (PNG, 96 dpi: 1pt = 4/3 px)
   -> vision model    (OpenRouter, qwen/qwen-2.5-vl-72b-instruct)  PROPOSE
   -> geometric verifier (SVG + LM OTF outlines, fontTools BoundsPen)  VERIFY
   -> notes/critique-<n>.md   (render info + gt geometry + claim resolution + raw reply)
```

The geometric verifier runs ALWAYS (also with `--no-critique`) and computes
deterministic ground truth in SVG pt from the same geometry the PIL raster
draws:

- **ink_bbox_gt** — union of every glyph ink box (plus fraction bars and
  stroked lines), in pt and as fractions of the SVG width/height.
- **edge clipping gt** — max ink overflow past each canvas edge, in pt, plus
  the offending elements.
- **big-op limit centering gt** — for each big-op (`∑ ∫ ∏ ⋃ ⋂ ⨆ ∐`) and each
  TeX limit-op run (`\lim \max \min \sin ...`), the nearest row above/below
  that is not separated by a fraction bar and overlaps the operator's ink
  span is its limit row; `cx_op` vs `cx_limit` gives the offset in pt
  (defect if > 1% of the SVG width). Limit rows are split into horizontal
  clusters so a shared limit row serving two operators (e.g. `\prod ... +
  \bigcup ...`) is attributed correctly; `\int` side-endpoint limits are not
  over/under limits and are not measured.
- **overlap gt** — every pairwise ink-box intersection with area, % of the
  smaller box, and an `excluded` flag for intended overlaps (a limit
  touching its operator, a radical over its radicand).
- **glyph completeness gt** — every char whose ink box is empty (missing
  glyph / no outlines).

**Verdict merge.** The final verdict is the GEOMETRIC verdict (deterministic
and authoritative). A vision claim fails the render only when geometry
confirms it: clipping claim requires gt overflow > 0 on that edge, limit
offset claim requires gt offset > 1% of width, overlap claim requires a
non-excluded gt intersection, incomplete-glyph claim requires an empty gt
box. Claims geometry contradicts are reported as `refuted (vision artifact)`
and never fail the verdict. Because confirmation always corresponds to a
geometric defect, the merged verdict equals the geometric verdict; vision
errors (no key, HTTP failure) also never fail a geometrically clean render.

## Why the verifier exists (measured)

The vision model hallucinates plausibly: it flagged a `\sum` limit offset of
0.05 (fractions) that is geometrically 0.218 pt (threshold 1.61 pt at -s 48),
"overlaps" in `\sin x + \cos x` where glyph boxes have 1.6-2.6 pt gaps, an
"incomplete γ" whose ink box is complete, a fraction bar "overlapping b"
that is 10.7 pt away, and right-edge clipping on the resvg raster that is
0.0 pt in the SVG. All of these are now refuted geometrically and the
formulas PASS. Real defects are still caught: shifting the `n` limit 6 pt
off-center fails (`offset_pt 6.218 > 1.61`), an `x` pushed into the `∑`
fails (208 pt² overlap), and a glyph replaced by a non-printing char fails
(empty ink box).

`scripts/critique.py` runs the whole pipeline:

```bash
# full critique (needs OPENROUTER_API_KEY)
python3 scripts/critique.py -i '\int_0^1 x\,dx + \sum_{i=1}^{n} \frac{1}{i^2}'

# render only: emit prompt + image + JSON skeleton, skip the model call
python3 scripts/critique.py 'x^2' --no-critique

# tune the render / model
python3 scripts/critique.py -i '\sum_{i=1}^{n} x_i' -s 48 \
    --vision-model 'qwen/qwen-2.5-vl-72b-instruct' --out-dir notes
```

Per run it writes:
- `notes/critique-<n>.md` — render info, GEOMETRIC VERIFICATION (gt ink bbox,
  per-edge clipping, limit offsets, overlaps, empty glyphs, defect count),
  parsed verdict, per-claim CONFIRMED/REFUTED resolution, raw reply, prompt
- `notes/artifacts/critique-<n>/render.svg` — ztex output
- `notes/artifacts/critique-<n>/render.png` — PIL raster (96 dpi, 1pt = 4/3 px;
  size derives from the SVG's pt width/height)
- `notes/artifacts/critique-<n>/critique-<n>.prompt.txt` — prompt used

and prints one line, e.g.:

```
critique-1: PASS (0 defects) — geometric verifier clean; vision FAIL claims refuted (vision artifact)
```

Exit code is 0 on success; the verdict word (`PASS` / `FAIL`) is the machine
signal and equals the GEOMETRIC verdict: PASS iff no geometrically-confirmed
defect. Vision transport failures no longer produce their own status word —
a geometrically clean render PASSes even when the model was skipped or
errored (the report still records `SKIPPED` / `VISION-ERROR` / `UNPARSEABLE`
next to the vision section).

## Manual commands (what the script runs)

Render (built binary is fastest; `zig build run` recompiles if needed):

```bash
zig-out/bin/ztex -i '\int_0^1 x\,dx + \sum_{i=1}^{n} \frac{1}{i^2}' \
    -o out.svg -s 20 -b white
# equivalent via the build system:
zig build run -- -i '\int_0^1 x\,dx + \sum_{i=1}^{n} \frac{1}{i^2}' -o out.svg -s 20 -b white
```

Convert to PNG (rasterized by the script itself with PIL + the Latin Modern
OTFs; canvas, positions and font sizes all scale by 96/72 = 4/3 so 1pt = 4/3 px):

```bash
python3 - <<'EOF'
import sys; sys.path.insert(0, "scripts")
from critique import rasterize_svg
rasterize_svg("out.svg", "out.png")   # deterministic, 96 dpi
EOF
```

Raster caveats on this machine (measured):
- **PIL + the actual Latin Modern OTFs is the TRUSTWORTHY renderer.**
  `scripts/critique.py` draws every ztex `<text>` glyph with the real font
  at the declared pt font-size (baseline-anchored), plus fraction-bar
  `<rect>`s, in painter order — a faithful picture of the SVG geometry.
  Deterministic: identical SVG + fonts → identical PNG.
- `resvg` (0.48), `rsvg-convert` (2.62.3) and ImageMagick are BROKEN for
  ztex `<text>` on this host: they fall back to wrong fonts (glyphs shift
  and resize) and overflow the frame. The "right-edge cut" the critic used
  to catch is exactly resvg's artifact — the SVG itself carries a ~34pt
  right margin (0.35 × max glyph size, verified geometrically), so a cut
  there is NOT a ztex defect. Do not trust these renderers for judging
  layout.
- Fonts are resolved at runtime: the known devenv-profile path first, then
  a Nix-store glob, then `/usr/share/fonts` (`--font-dir` overrides).

## The adversarial prompt

The prompt (`PROMPT_TEMPLATE` in `scripts/critique.py`) forces the model to
hunt. Ground truth formula is embedded; every position must be reported as a
FRACTION of image width/height (2-3 decimals), never "a bit" or "roughly".
Six mandatory checks:

1. **Edge clipping** — % of each cut glyph missing per edge (top/bottom/
   left/right) + whole-formula ink bbox `[x_left, x_right, y_top, y_bottom]`.
   Any glyph touching a border is a FAIL.
2. **Big-op limit centering** — for each operator with limits (`\sum`,
   `\prod`, `\int`, ...): `cx_op` vs `cx_limit`; offset > 1% of image width
   is a FAIL; limits must be visible and not fused into the operator.
3. **Adjacent-term overlap** — overlap > 2% of the smaller glyph is a FAIL;
   flag strokes punching through fraction bars.
4. **Complete glyphs** — every glyph complete (no stubs, no shorn serifs);
   special attention to `\int`, `\sum`, `\sqrt`, tall parens, wide accents.
   A truncated glyph is a FAIL even at the canvas edge.
5. **Subscripts & limits** — visible (not blank/fused) and placed correctly
   relative to the base; each reported as `(x, y)` fractions.
6. **LaTeX-likeness** — score 0-10 plus top deviations with severity.

Answer format is strict JSON (the script parses it leniently if wrapped in
markdown fences):

```json
{
  "verdict": "PASS" | "FAIL",
  "clipping": {"top_pct": 0, "bottom_pct": 0, "left_pct": 0, "right_pct": 0,
               "ink_bbox": [0.0, 0.0, 0.0, 0.0], "note": ""},
  "bigop_limits": [{"operator": "", "cx_op": 0.0, "cx_limit": 0.0,
                    "offset_pct": 0.0, "visible": true, "note": ""}],
  "overlaps": [{"pair": "", "overlap_pct": 0.0, "location": "", "note": ""}],
  "glyphs": [{"glyph": "", "complete": true, "note": ""}],
  "scripts": [{"script": "", "x": 0.0, "y": 0.0, "visible": true,
               "placement_ok": true, "note": ""}],
  "latex_likeness": {"score": 10,
                     "top_deviations": [{"issue": "", "severity": ""}]},
  "summary": "one or two sentences"
}
```

"verdict" = FAIL if any check fails; empty arrays mean a clean category.

## Vision backend

- OpenRouter chat-completions (`OPENROUTER_API_KEY` env var), default model
  `qwen/qwen-2.5-vl-72b-instruct` (verified working from this machine;
  override with `--vision-model` or `ZTEX_VISION_MODEL`).
- No key / `--no-critique` → the script still renders, runs the geometric
  verifier, and writes the ready-to-use prompt + image + JSON skeleton with
  `"status": "not-run"`; an orchestrator (e.g. the harness `inspect_image`
  tool) can feed the PNG and prompt itself. The geometric verdict is still
  produced and printed.
- Verified on real renders: the model reads the formula correctly. Its
  defect claims are now filtered by the geometric verifier (see above); a
  vision `FAIL` with no geometrically-confirmed claim reads `PASS` with the
  claims listed as `refuted (vision artifact)` in the report.

## Fix loop

1. Render + critique: `python3 scripts/critique.py -i '<formula>'`
2. Read `notes/critique-<n>.md`; a geometric FAIL maps to a check category
   (clipping → svg.zig frame/unit handling, overlap → layout glue/metrics,
   off-center limit → big-op layout, empty glyph → font/text emission).
   The "Geometric verification" section states the gt numbers; the claim
   resolution table shows which vision claims were confirmed vs refuted.
3. Fix the Zig source, rebuild (`zig build`).
4. Re-run the same formula; the verdict must flip to PASS with the same
   category empty. Keep the old critique file for the diff.
5. Sweep the corpus (`scripts/gen_compare.py` / `compare_engines.py`) after
   a PASS to confirm no regressions elsewhere.

## Reference panes (XeTeX / KaTeX / MathJax)

`--ref` mode stacks FOUR panes — ztex / XeTeX / KaTeX / MathJax — and the
prompt compares OURS against ALL THREE references (each nit carries a
`reference: "XeTeX|KaTeX|MathJax"` field). The KaTeX pane is rendered by
scripts/katex_ref.py: the KaTeX CLI (nix, reads LaTeX from stdin) ->
per-glyph span geometry (vlist em layout) -> PIL raster with the converted
KaTeX fonts (woff2->ttf, cached under ~/.cache/ztex-katex). The MathJax
pane is rendered by scripts/mathjax_render.mjs (mathjax-full tex2svg ->
SVG with glyph outlines as embedded paths) + resvg. See
notes/katex-reference.md and notes/mathjax-reference.md for the details.

**Resolution consistency.** All four panes render at the SAME nominal pt
size (`--size`) and the SAME pixel density: `REF_SCALE` × 96 dpi =
8/3 px/pt (192 dpi, `REF_SCALE = 2` in scripts/critique.py). ztex uses
`convert_png(..., scale=REF_SCALE)`, XeTeX `mutool -r 192`, KaTeX
`render_katex_ref(..., scale=REF_SCALE)`, MathJax
`mathjax_render.mjs --scale 2`. `combine_panes` then scales every pane to
the common (max) width with LANCZOS only — no pane is ever upscaled below
8/3 px/pt in the combined image (previously the panes were rendered at
96 dpi and the narrower ones were upscaled in the combined image, e.g.
ztex 73px -> 85px).
