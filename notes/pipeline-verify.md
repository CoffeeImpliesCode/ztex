# Verification Pipeline Audit — `compare_engines.py` + `extract_geom.py`

Full-pipeline STAGE 5 audit. Question: does the verification correctly measure
ztex vs XeTeX, or is it broken/masking real errors? READ-ONLY audit of
`scripts/compare_engines.py` (679 ln), `scripts/extract_geom.py` (184 ln), and
sample data in `/tmp/cmp2/`, `/tmp/cmp/`, `/tmp/final_cmp/`. Findings ranked
by severity. Each finding is verified by code walk, real data, or a synthetic
probe with a known answer (probes run against the module directly).

---

## R1. THE HEADLINE: the pipeline measures BOX POSITIONS, never INK — it cannot detect the font/ink mismatch the user suspects. CONFIRMED.

**What the parsers read:**
- `parse_ztex_svg` returns `(glyph, x, y, font-size)` from `<text x y font-size>` elements — the layout box baseline origin. The ztex SVG contains **no ink at all**: `src/svg.zig` emits only `<text>` elements; the ink is whatever the viewer's font renderer draws for the `font-family` chain `"Latin Modern Math, Latin Modern Roman, DejaVu Serif, serif"`. If LM Math is missing/uninstalled, the fallback silently changes the ink while the `<text>` attributes stay identical.
- `parse_xetex_svg` returns `(glyph, e, f, size)` from `<use data-text transform="matrix(...)">`. The mutool SVG *does* embed the real glyph **paths** in `<defs>` (verified in `/tmp/final_cmp/ref.svg`: `glyph-1-1` is a 21.6pt-tall ∫ outline), and the parser **throws them away**.
- `normalize()` keeps only `glyph/x/y/size` (+ optional `bbox` that `extract_geom.py` never emits). The comparison input format has **no ink channel at all** — an ink-only defect cannot even be expressed.

**Consequence (matches the user's hypothesis):** the comparison sees baseline
origins, which ztex's layout keeps near-parity with XeTeX (see R6), and reports
"close" while the drawn ink can be wrong. Quantified ink-level proof using
font metrics (fontTools on the installed Latin Modern Math OTF) and the mutool
path data in `ref.svg`:

| glyph | XeTeX drawn ink (from SVG paths) | ztex drawn ink (LM Math × font-size) | verdict |
|---|---|---|---|
| ∑ (10pt vs 14pt) | 12.94w × 13.61h pt | 13.21w × 14.00h pt | +2% / +3% — fine, calibration works |
| ∫ (9.96pt vs 20pt) | 8.63w × 21.59h pt | 11.06w × 22.20h pt | **+28% wider** — a real, visible ink defect |

`res_1.json` (∑) and `display_cmp_4.json` report the ∑ as "0.39pt left" /
"aligned" — nothing about ink. The 28%-too-wide ∫ is invisible to every
output the tool produces. **The verification cannot see the defect it was
built to catch.**

**What it SHOULD measure (recommendation):** per-glyph ink bounding boxes.
- XeTeX side: the ink paths are *already in the SVG* — parse the `<defs>` paths + `<use>` transforms and compute ink bboxes (I did this in 10 lines; `glyph-1-0`/`glyph-1-1` gave exact cmex10 ink).
- ztex side: the SVG declares `font-family` + `font-size`; the ink bbox is computable exactly from the OTF metrics (as above), or by rasterizing the SVG with fontconfig-resolved fonts and measuring dark-pixel bboxes.
Then compare aligned glyphs on ink bbox (position AND size), not baseline+font-size. That catches the ∫ width error, off-center ink, and font-fallback changes.

---

## R2. Big-op SIZE is measured in incomparable units, and the discrepancy is silently invisible (or dropped entirely).

**Units differ by design:** ztex emits the `<text font-size>` scale it applies
to its (smaller-design) glyph — 14 for script-style big ops, 20 for display
(`metrics.zig` `display_ops`, scale 1.4/2.0, "chosen so the drawn ink matches
the measured XeTeX display size"). XeTeX/mutool emits the font matrix scale of
the op font — 9.96 for display (cmex10 at design size), whose *ink* is the big
glyph. So ztex 14/20 vs xetex 9.96 is a **false size_ratio 1.405/2.008** if read
as ink size — the numbers reference different designs.

**But worse, it is never reported:**
- `style(size, base)` classifies both 14/20 (ztex) and 9.96 (xetex) as `"text"`
  (thresholds 0.5/0.8 × base 10). `style_mismatches` stays 0, and `_sentence`
  only prints size when a style is non-`text` — so the ratio 1.41/2.01 never
  reaches stats or the human output. Probe B (sizes 20 vs 9.96, identical
  positions): `size_ratio=[2.008, 1.004]`, `style_mismatches=0`,
  top_issues=["ztex's ∑ is aligned."]. A 2× font-size discrepancy reads as
  "aligned".
- For big ops where engines use different codepoints for the same visual glyph
  (`\bigcup`: ztex ⋃ U+22C3 vs xetex ∪ U+222A; same for ⋂/∩, ∏/Π, ∮), the
  pair is *not* in `MATH_EQUIV`, so NW scores a mismatch (-4) vs gap-both (-2),
  gaps both, and the glyph lands in `unmatched` **on both sides** — no delta,
  no size comparison, and the human output prints **false** "Missing in ztex:
  ∪" / "Missing in xetex: ⋃" (present-but-different glyphs reported as
  absent). Verified: `res_4.json` human output says exactly that; probe C
  reproduces it.
- Net effect: the single largest ink-relevant quantity in the corpus (big-op
  scale) is either invisible (∑) or turned into a bogus missing report (⋃/∪).

Fix: extend `MATH_EQUIV` (∪↔⋃, ∩↔⋂, Π↔∏, ∮↔∯ — or better, equate on
"TeX op slot" not codepoint); compare ink bbox height (or the op's
design-size constant) instead of raw font-size; surface `size_ratio` in
sentences regardless of style class.

---

## R3. `first-top` baseline shift poisons every delta when the engines emit different first glyphs (the `\int` case).

`baseline_shift(ours, ref, "first-top")` aligns `ours[0]` to `ref[0]`. For
`\int_0^1 x\,dx` ztex emits the lower limit first (`1, ∫, x, d, x`) while
XeTeX emits the op first (`∫, 1, 0, x, d, x`). First-top therefore subtracts
the offset between a script-size '1' and an op-baseline '∫' from *every*
glyph. Real consequence in `res_3.json`:
- reported: "ztex's 1 is 9.96pt left", "ztex's x/d/x are 7.6pt left, 2.05pt down";
- true (∫-aligned, synthetic probe D): the '1' is 6.7pt off, x/d/x are 4.4pt
  off horizontally and **0.05pt** vertically — ztex's body glyphs are almost
  perfectly aligned to its own ∫; the report misattributes a ±4pt error onto
  the wrong glyphs and inflates it to ±10pt.
- The worst real defect here — ztex's ∫ box advance is ~4.4pt too narrow — is
  never quantified, because the ∫ is reorder-dropped (R4).

**All three strategies collapse to first-top on real data:** `mode` needs
repeated baseline y's (rare: 3 glyphs → all unique → picks the first, same as
first-top; probe H shows identical output); `bbox-center` falls back to
first-top because `extract_geom.py` never emits `bbox`. So there is no working
alternative strategy today.

Fix: compute the offset from a glyph that exists in both sequences and is
known to be on the main baseline (e.g., first *matched* delta whose y is the
mode of the alignment's matched rows), or drop the offset for reordered
prefixes.

---

## R4. NW alignment: order-locked by design; correct at what it does, but reorder = silent loss of all geometry.

Needleman–Wunsch on glyph identity with match 4 / normeq 2 / mismatch -4 /
gap -1. Verified behaviors:
- Same-order sequences align exactly (selftest + probes E1/E2: a uniform row
  shift is absorbed, a single-glyph +1pt shift yields dx=-1.0 — correct).
- `\int`'s interleaved limits (ztex `1,∫,…` vs xetex `∫,1,0,…`): NW never
  crosses; it gaps both ∫s and flags "Reorder: ∫" (good, honest), and the
  tie between two equal-scoring paths is broken arbitrarily. The reordered
  glyph is then excluded from deltas, so its position/size is **never
  quantified** — see R3.
- Substitution handling is misleading: because gap (-1)×2 beats mismatch (-4),
  a wrong glyph is reported as missing-on-both-sides ("Missing in ztex: ∪")
  rather than as a substitution delta. `entry["glyph_ref"]` (the
  substitution path) is effectively dead code for any real corpus.

---

## R5. Minor bugs / dead features

- **`--selftest` is unreachable via the CLI.** `argparse` requires
  `--ours/--ref/--out` and errors out *before* the selftest branch runs, so the
  documented `python3 scripts/compare_engines.py --selftest` exits 2. The 35
  checks pass when invoked by import (`ce._selftest()`).
- **`bbox-center` strategy is dead code** for records produced by
  `extract_geom.py` (no `bbox` field is ever written).
- **Cross-engine size comparisons assume a common base.** `BASE_SIZE` is
  ztex 10 / micro 20 / xetex 10; comparing micro vs ztex yields size_ratio ≈
  2.0 for every glyph and meaningless `dxi/dyi`. Only same-base pairs (ztex↔
  xetex) are sound — nothing enforces this.
- `parse_ztex_svg` regex requires `[\d.]+` — emits like `x="0"` match fine, but
  any negative coordinate or exponent notation would silently drop glyphs.
- Sample-data caveat: `/tmp/cmp2/work/uz_*.svg` and the PDFs are **stale**
  (uz_3.svg contains `x ∈ S`, not `\int_0^1 x\,dx`; `xetex_1.pdf` text-extracts
  "a≤b"). The JSON records the comparison consumes are internally consistent,
  but the underlying renders cannot be re-verified from `work/`.

---

## R6. What the pipeline did get right (corpus audit)

Ran `compare()` over all 21 non-u `res_*.json` in `/tmp/cmp2/`:
- 19/21 formulas near-parity (mean|dx| ≤ 0.75pt, mean|dy| ≤ 0.19pt) — the
  layout *boxes* genuinely match XeTeX for ordinary glyphs.
- `\int_0^1 x\,dx` is flagged as broken (max|dx| 9.96, reorder ∫, "Missing in
  ztex: 0") — the upper-limit '0' is genuinely absent from the ztex record and
  the ∫ box advance is short, so a defect IS surfaced, but with wrong deltas
  and magnitudes (R3).
- `\bigcup`/`\bigcap` are flagged with **false** missing reports (R2).

So: the tool is a sound *box-layout* comparator for same-order, same-codepoint
glyphs at matched baselines, and a misleading one for big ops, reorders, and
anything ink-level.

## Bottom line

The verification measures layout-box baselines, not drawn ink. That is
exactly the failure mode the user suspected: near-parity boxes → "close"
verdict, while the ink (the 28%-too-wide ∫, any font-fallback change, any
off-center glyph) is invisible by construction. It should measure ink bboxes
(the XeTeX SVG already contains them; the ztex side is computable from its
declared font+size or via rasterization), and it should fix the big-op
codepoint equivalence, first-top offset, and size reporting (R2–R4) so the
numbers it does report are true.
