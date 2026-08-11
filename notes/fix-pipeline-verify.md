# Fix: verification pipeline now measures INK, not box baselines

Follow-up to `notes/pipeline-verify.md` (audit R1-R5). The pipeline could not
see the ink: ztex SVGs carry only `<text>` (font-referencing glyphs), the
xetex SVG glyph paths were discarded by the parser, and the comparator had no
ink channel at all — so a 28%-too-wide `\int` reported "aligned". Fixed in
`scripts/extract_geom.py` (producer: ink bboxes per glyph) and
`scripts/compare_engines.py` (comparator: ink deltas, stable baseline,
big-op equivalence, reorder geometry, reachable selftest, ink self-check).

## What changed

### scripts/extract_geom.py
- **ztex ink**: the SVG declares `font-family="Latin Modern Math, …"` and the
  glyph ink is whatever the font renderer draws. The ink bbox is now computed
  exactly from the Latin Modern Math OTF metrics (fontTools `BoundsPen`) at
  the declared `font-size`, cached per run. Font located via `fc-match`
  (fallback: known Nix store paths). No font/fontTools -> records without ink
  (comparator degrades gracefully). Confirmed against a rasterized render
  (rsvg): predicted LM Math ink matches the drawn pixels within ~0.2pt.
- **xetex ink**: both mutool SVG generations handled:
  - classic `<use data-text transform="matrix(a,0,0,-a,e,f)"/>` with defs
    paths in em units — bbox x matrix (y-down page coords);
  - newer `<use xlink:href="#glyph-N-M" x y/>` with defs paths already in pt
    (y-down from the use origin) and *no text* — glyph text, baseline y and
    font size recovered from a parallel `mutool draw -F stext` XML (written
    next to the SVG by `render_xetex`; chars paired positionally after
    sorting by (y, x), verified 1:1 on real data).
- **path bboxes are exact**: new `_path_bbox` parses M/L/C/H/V/Z (absolute
  and relative) and evaluates exact cubic-bezier extents, so control points
  never inflate the bbox (the old point-based regex also mis-tokenized
  mutool's compact numbers like `.70700076-.65063479` and dropped `V`/`H`
  commands). Malformed paths fall back to a point bbox, never crash.
- **micro ink**: the existing defs bbox is emitted as `ink` (same
  approximation the size field already used).
- ztex `<text>` regex now accepts `pt` unit suffixes and negative/exponent
  coordinates (`x="0pt"` emitted by current ztex builds; `x="0"` by older).
- Per-glyph records now carry `"ink": [xmin, ymin, xmax, ymax]` in the same
  y-down page coordinates as x/y.

### scripts/compare_engines.py
- **`normalize`** carries `ink` through (scaled; vertical axis flipped with y
  when `up == false`, so ink lives in the same y-up space as x/y).
- **`delta`** adds an ink channel: `dix` (left edge), `diy` (top edge),
  `dwi`/`dhi` (extent deltas), `width_ratio`/`height_ratio`, normalized
  `dxi`/`dyi`, plus the raw bboxes. `_merged` unions ink for merge/split
  pairs. `_ink_anomaly` flags pairs whose ink deviates >15% on extent
  (ratio vs ref ink) or position (`|dix|`/`|diy|` normalized by the ref font
  size — absolute ink edges, i.e. what the eye sees; a big-op whose
  *baseline convention* differs between engines is not flagged when the ink
  lands in the same place).
- **R3 baseline fix**: `baseline_shift` "mode" (now the default) computes
  oy from the median y-offset of aligned pairs that are on the main text row
  on **both** sides (text-size on both engines, so a XeTeX big op at
  9.96pt never captures the offset against ztex's 14/20pt op), ox from the
  median over all aligned columns. A differing first glyph (reordered
  `\int` limits) no longer poisons every delta. `first-top` kept for
  back-compat; `bbox-center` now uses real ink centers.
- **R2 size + big ops**: `_sentence` always reports the size relation
  (`(size ratio 1.41)`, or the script-height clause), and `MATH_EQUIV` gains
  the big-op pairs ⋃↔∪ (U+22C3↔U+222A), ⋂↔∩ (U+22C2↔U+2229), ⨆↔⊔
  (U+2A06↔U+2294), plus explicit ∐ and ∮ identities — `\bigcup`/`\bigcap`
  align instead of reporting false "Missing" on both sides.
- **R4 reorders**: reordered glyphs are still excluded from deltas (NW cannot
  cross) but now carry their geometry (`dx`, `dy`, plus `dix`/`diy` when ink
  exists) computed against the counterpart; the human output prints them.
- **Ink reporting**: per-pair sentences gain an `(ink: …)` clause when the
  ink deviates >5% (extent and/or position); the summary line adds
  ink_pairs/n_ink_anomalies/mean|dix|/max_width_dev/max_height_dev; a
  `verdict` (ok/layout/structure/ink) ends every report, and `verdict: INK
  DEFECT` lists the anomalous glyphs. Top issues are ranked by the largest of
  box delta / ink position / ink extent, so ink-only defects surface.
- **R5 selftest reachable**: `--selftest` now runs before the required-arg
  check (`--ours/--ref/--out` validated only otherwise). 49 checks,
  including the new ink-defect self-check: a synthetic `\int` whose ink is
  28% wider must produce verdict `ink` (control: matching inks -> `ok`).

## Verification

### Headline: `/tmp/final_cmp` (stale ztex `ours.svg` vs new-format xetex `ref.svg`)

Before: `res_1.json`/`display_cmp_4.json` reported the `∑` as "0.39pt left" /
"aligned"; the 28%-too-wide `\int` was invisible (its ink was never measured;
in `res_3.json` it was reorder-dropped entirely).

After (`python3 scripts/compare_engines.py --ours ours.json --ref ref.json`):

```
ztex's ∫ is 0.46pt right and 0.05pt up (size ratio 2.01)
  (ink: 2.44pt (+28%) wider, ink left edge 1.03pt right, ink top 16.03pt up).
ztex's ∑ is 0.63pt left and 0.04pt up (size ratio 1.41)
  (ink: ink top 10.32pt up).
...
verdict: INK DEFECT — 5 ink-anomalous glyphs: i, n, ∑, ∫
```

The `\int` ink width defect (28% wider than cmex10) is now flagged, and the
stale render's extra defect (∫/∑ ink ~10-16pt too high, clipped off-page —
confirmed by rasterizing both SVGs) is surfaced too. The `i`/`n` flags are
script-size font-design differences (LM Math single optical size scaled to
7pt vs TeX's optically-sized 7pt fonts: `i` 28% narrower, `n` 16% narrower) —
real, visible ink differences, ranked below the big-op defects.

### Current ztex build, full corpus (`scripts/extract_geom.py` re-run)

| formula | verdict | notes |
|---|---|---|
| `x^2`, `x_2`, `x^2+y^2` | ok | box |dx| ≤ 0.06pt, ink within 10% |
| `\frac{a+b}{c-d}` | ink | `b` +34% wider, `−` -56% narrower / +46% taller (LM Math hyphen vs cmsy minus) |
| `\sum_{i=1}^{n} x_i` | ink | script `i`/`n` width differences; ∑ ink position actually matches (diy ≈ 0.04pt) — the 10.5pt `dy` is TeX's raised big-op baseline, reported in the box channel only |
| `a\cdot b` | ink | `b` +34% wider |
| `\int_0^1 x\,dx` | ink | **`∫` ink +25% wider (11.06 vs 8.84pt) — the headline defect, on the current build**; ink left edge +0.51pt |

The `∫`/`∑` inks are positioned correctly on the current build (diy ≈ 0.0),
so no false vertical flags — the width defect alone drives the verdict.

### R2/R3 on the audit's `/tmp/cmp2` records (no ink channel — comparator degrades)

- `\bigcup_{i=1}^{n} A_i` / `\bigcap…`: before — false "Missing in ztex: ∪ /
  Missing in xetex: ⋃". After — 7/7 pairs matched, no unmatched, verdict
  `layout` (limits dx 0.8-1.5pt, the real drift).
- `\int_0^1 x\,dx`: before — "1 is 9.96pt left", "x/d/x 7.6pt left, 2.05pt
  down" (first-top poisoning). After — x/d/x at 0.00-0.04pt; the reordered
  ∫ is quantified: `Reorder (ztex vs xetex): ∫ (1 glyph) — ∫: dx=4.41pt
  dy=0.05pt` (the audit's "∫ box advance ~4.4pt too narrow" is now visible);
  `1` at its true 2.30pt/4.51pt; "Missing in ztex: 0" retained (genuinely
  absent).

### Selftest

`python3 scripts/compare_engines.py --selftest` -> `selftest: 49 checks
passed`, exit 0 (previously exit 2: argparse rejected `--selftest` before the
branch could run).

## Known limitations (unchanged / out of scope)
- Cross-engine size comparisons (micro vs ztex) remain unsound (different
  `BASE_SIZE`); the ink channel makes same-base pairs (ztex↔xetex) sound.
- Current mutool emits `data-text="\uFFFD"` for cmex10 big ops (no
  ToUnicode), so freshly extracted xetex big-op *text* is unrecoverable;
  the `MATH_EQUIV` pairs cover the toolchains that do map them, and the
  final_cmp (newer mutool) data carries no text at all (recovered via stext).
- The summary line's stats are computed pre-px-conversion (pre-existing
  inconsistency, unchanged).
