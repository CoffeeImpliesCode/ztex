# FixSqrtSurd — Radical (Surd) Rendering Defect

## Root Cause

`layoutSqrt` in `src/layout/layout.zig` scaled the **base** √ glyph (U+221A, ink
0.040/0.960 em) to `gs = H + D + clr + θ` — the full radicand height. For
`\sqrt{\frac{a+b}{c}}` at 30pt this produced font-size **67.66pt**, making the
surd 2.26× too wide (52.78pt ink vs XeTeX's 27.17pt).

XeTeX does **not** scale the base glyph. It draws √ at the current font size
(30pt) using the smallest **MATH-table vertical variant** (radical.v1–v4) whose
`AdvanceMeasurement` covers the radicand. For `\sqrt{\frac{a+b}{c}}` this is
**radical.v3** (2.401em, ink 1.450/0.950 em) — tall AND slim. The base glyph
(1.001em) only suffices for shallow radicands like `\sqrt{x}`.

## Fix Location

**A. layout (src/) — root cause**: `src/layout/layout.zig` `layoutSqrt`
(rewritten 2377–2514). Was: `layoutScaledChar(..., gs, ...)` scaling the base
glyph. Now: selects `metrics.radicalVariant(req_em)`, creates the char box
directly with the variant's advance/ink at `size_pt`, sets `radical_form` on
the box.

**B. rasterizer (scripts/) — variant resolution**: `scripts/critique.py` —
added `RADICAL_CPS`/`RADICAL_PUA` constants, radical variant patching in
`_variant_font`, radical handling in `rasterize_svg` (draws
`radical.vN` via patched font), and variant resolution in
`_glyph_ink_boxes` (geometric verifier). Mirrors the existing big-op
`data-op="v1"` and delimiter variant mechanisms.

## Before / After vs References (30pt)

### `\sqrt{\frac{a+b}{c}}`

| Metric             | Before (ours) | After (ours) | XeTeX ref   | KaTeX ref  | MathJax ref |
|--------------------|--------------|-------------|-------------|------------|-------------|
| SVG font-size      | 67.66pt      | 30.00pt     | ~29.89pt    | 30pt       | 30pt        |
| data-radical       | none         | v3          | (MATH v3)   | —          | —           |
| Surs ink width     | 52.78pt      | **27.27pt** | 27.17pt     | ~27.3pt    | ~27.3pt     |
| Surs ink height    | 67.66pt      | **72.00pt** | 72.36pt     | ~70.5pt    | ~72.0pt     |
| SVG width          | 135.00pt     | 102.61pt    | 109.9pt*    | 111.4pt*   | 109.1pt*    |
| SVG height         | 92.02pt      | 82.80pt     | 85.0pt*     | 82.1pt*    | 73.9pt*     |
| Geometric defects  | N/A          | **0**       | —           | —          | —           |
| Vision verdict     | FAIL (fat)   | **PASS**    | —           | —          | —           |

*ref pane includes 6pt standalone border.

Width diff vs XeTeX: |27.27 - 27.17| = **0.10pt** ✓ (< 2pt)  
Height diff vs XeTeX: |72.00 - 72.36| = **0.36pt** ✓ (< 2pt)

### `\sqrt{\int_0^1 x\,dx}` (SqrtInt)

| Metric             | After (ours) | XeTeX ref   |
|--------------------|-------------|-------------|
| Surs ink width     | 27.27pt     | 27.17pt     |
| Surs ink height    | 90.00pt     | 90.44pt     |
| data-radical       | v4          | (MATH v4)   |
| Geometric defects  | 0           | —           |
| Vision verdict     | PASS        | —           |

Width diff: 0.10pt ✓ | Height diff: 0.44pt ✓

## Files Changed

| File                        | Lines       | Change                                        |
|-----------------------------|-------------|------------------------------------------------|
| `src/layout/metrics.zig`    | 2151–2177   | `radical_variants` table (base+v1–v4, em ink), `radical_advance_measurements` (MATH AdvanceMeasurements), `radicalVariant()` selector |
| `src/layout/box.zig`        | 92–97       | `radical_form: u8 = 0` field on `Box`          |
| `src/layout/draw.zig`       | 49–51, 148  | `radical_form` on `Text` + carried through `flatten` |
| `src/svg.zig`               | 107–117     | Emit `data-radical="vN"` when `radical_form > 0` |
| `src/layout/layout.zig`     | 2377–2514   | Rewrite `layoutSqrt`: variant selection, draw at `size_pt` |
| `scripts/critique.py`       | 139–148, 508–522, 1165–1171, 1234–1244 | Constants, raster resolution, font patching, verifier resolution |

## Variant Selection Logic

`req_em = (H + D + clr + θ) / size_pt` → smallest variant whose MATH
`AdvanceMeasurement` (1.001, 1.201, 1.801, 2.401, 3.001) covers `req_em`:

| Formula                     | req_em | Variant |
|-----------------------------|--------|---------|
| `\sqrt{x}`                  | ~0.65  | base (0) |
| `\sqrt{x^2+1}`              | ~1.25  | v1      |
| `\sqrt{\frac{a+b}{c}}`      | ~2.26  | v3      |
| `\sqrt{\int_0^1 x\,dx}`     | ~3.0   | v4      |

## Verification

- `zig build` — compiles clean
- `zig build test` — all tests pass (exit 0)
- `zig fmt` — applied
- Geometric verifier: **0 defects** (surd tip at vinculum, width/height match refs)
- Vision critique: **PASS** (5 minor nits for main formula, 7 for SqrtInt — none about surd fatness)
- Surs tip above radicand: ink top at vinculum top (rule_top), surd hook extends into radicand area — matches XeTeX
- Surd tip overhang: ~0pt above vinculum (ink top aligned), 4.3pt below radicand bottom (matches XeTeX's 3.4pt)
