# Mod entry — lmroman17 optical band + IC-before-kern + style-invariant leads

## Status: VERIFIED (no code changes needed)

All 44 glyphs of the Mod corpus entry match the fresh \fontsize{30} XeTeX reference
within **≤ 0.0175 pt** (max), well under the 0.5 pt tolerance. Rows 3–4 are identical
to rows 1–2. The 176-test suite passes. `zig fmt --check` passes.

The three fixes from the prior (cancelled) agent are already in the tree and correct:

1. **`band17(size_pt) = size_pt >= 15`** + **`table_roman17`** in `metrics.zig` —
   XeTeX/fontspec's LMRoman17 optical-size feature starts the 17 pt design at a *requested*
   size of 15 pt, not 17.28 pt (measured on the ref: `\mathrm{mx}` m advance 0.816 em at
   14.9 pt = 12 pt design, 0.772 em at 15.0 pt = 17 pt design). `tableFor`/`glyphAt`
   intercept roman style in this band and return the real LMRoman17-regular.otf advances
   (fontTools-verified: m 0.772, o 0.459, d 0.511 em). Below 15 pt the LM Math advance
   is correct (LM Math has no optical sizes).

2. **IC-before-kern in `layoutRow`** (`charIc` + `envIc`) — TeX's `math_trans` appends a
   character's italic correction when the next atom is a `\mkern` (a kern). `\pmod`/`\pod`/`\mod`
   begin with their leading `\mkern`, so a directly preceding char's IC joins the lead kern.
   `\bmod` starts with `\mskip` (a glue, not a kern), so it gets no IC — verified, unchanged.

3. **Style-invariant leads** in `layoutPmod`/`layoutMod` — 8 mu / 12 mu in *every* style.
   XeTeX's `\if@display` 18 mu branch never fires inside `\array` cells (cells are `\m@th`
   text-mode lists), so `\displaystyle` rows render pixel-identical to text rows.

---

## Formula rendered at -s 30

```latex
\begin{array}{cc} a \bmod 2 & b \pod 3 \\
                   c \pmod{4} & d \mod{56} \\
      \displaystyle a\bmod 2 & \displaystyle b \pod 3 \\
      \displaystyle c\pmod{4} & \displaystyle d \mod{56} \end{array}
```

## Before — analytical residuals eliminated by the fixes

Without the three fixes, the Mod entry would have the following per-glyph residuals
(> 0.5 pt, each fix addresses a distinct set):

### Fix 1: `band17`/`table_roman17` (roman letters at 30 pt use LM Math instead of LMRoman17)

| Glyph | Before (LM Math) | After (LMRoman17) | Residual |
|-------|-----------------|-------------------|----------|
| m (mod word) | 24.99 pt | 23.16 pt | +1.83 pt |
| o (mod word) | 15.00 pt | 13.77 pt | +1.23 pt |
| d (mod word) | 16.68 pt | 15.33 pt | +1.35 pt |

Cascading position errors from these advance differences:

| Position | Before | After | Residual |
|----------|--------|-------|----------|
| Row 1: a→o | 49.19 pt | 47.36 pt | +1.83 pt |
| Row 1: a→d | 64.19 pt | 61.13 pt | +3.06 pt |
| Row 1: a→2 | 90.87 pt | 84.80 pt | +6.07 pt |
| Row 2: d→(56) | 66.67 pt | 62.26 pt | +4.41 pt |

The `\text{hi}` golden at 20 pt also depended on this: without `band17`, `h` advance was
5.0 em (cmr10/LM Math = 10.0 pt at 20 pt) → `i` at x=10.0; with `band17`, `h` advance is
5.11 em (LMRoman17 = 10.22 pt at 20 pt) → `i` at x=10.22 (golden `T:i,10.22,0,20`).

### Fix 2: IC-before-kern (no IC applied before pmod/pod/mod leads)

| Position | Before (no IC) | After (with IC) | Residual |
|----------|----------------|-----------------|----------|
| Row 1: b→( (pod) | 26.20 pt | 26.62 pt | -0.42 pt |
| Row 2: c→( (pmod) | 26.86 pt | 27.61 pt | -0.75 pt |
| Row 2: d→m (mod) | 35.60 pt | 36.32 pt | -0.72 pt |
| Row 4: d→m (mod) | 35.60 pt | 36.32 pt | -0.72 pt |

ICs: b (U+1D44F) IC = 0.014 em → 0.42 pt; c (U+1D450) IC = 0.025 em → 0.75 pt; d (U+1D451) IC = 0.024 em → 0.72 pt.

### Fix 3: Style-invariant leads (display rows use 18 mu instead of 8/12 mu)

| Position | Before (18 mu display) | After (8/12 mu) | Residual |
|----------|------------------------|-----------------|----------|
| Row 3: b→( (pod, display) | 42.87 pt | 26.62 pt | +16.25 pt |
| Row 4: c→( (pmod, display) | 43.00 pt | 27.61 pt | +15.39 pt |
| Row 4: d→m (mod, display) | 43.53 pt | 36.32 pt | +7.21 pt |

The 18 mu / 8 mu = 10/18 em = 16.67 pt at 30 pt; 18 mu / 12 mu = 6/18 em = 10.00 pt at 30 pt.

---

## After — measured per-glyph diff vs fresh XeTeX ref (relative to row start, XeTeX normalized to 30 pt)

| Row | Glyph | ztex rel (pt) | XeTeX rel (pt) | diff (pt) |
|-----|-------|---------------|----------------|-----------|
| 1 | 𝑎 | 0.0000 | 0.0000 | +0.0000 |
| 1 | m | 24.2031 | 24.2044 | +0.0013 |
| 1 | o | 47.3631 | 47.3644 | +0.0013 |
| 1 | d | 61.1331 | 61.1344 | +0.0013 |
| 1 | 2 | 84.7963 | 84.7989 | +0.0026 |
| 1 | 𝑏 | 155.5430 | 155.5389 | -0.0041 |
| 1 | ( | 182.1663 | 182.1489 | -0.0174 |
| 1 | 3 | 193.8363 | 193.8189 | -0.0175 |
| 1 | ) | 208.8363 | 208.8189 | -0.0175 |
| 2 | 𝑐 | 0.0000 | 0.0000 | +0.0000 |
| 2 | ( | 27.0733 | 27.0600 | -0.0133 |
| 2 | m | 38.7433 | 38.7448 | +0.0014 |
| 2 | o | 61.9033 | 61.9048 | +0.0014 |
| 2 | d | 75.6733 | 75.6748 | +0.0014 |
| 2 | 4 | 101.0032 | 101.0064 | +0.0032 |
| 2 | ) | 116.0032 | 116.0064 | +0.0032 |
| 2 | 𝑑 | 137.6732 | 137.6664 | -0.0068 |
| 2 | m | 173.9932 | 173.9982 | +0.0050 |
| 2 | o | 197.1532 | 197.1582 | +0.0050 |
| 2 | d | 210.9232 | 210.9282 | +0.0050 |
| 2 | 5 | 236.2531 | 236.2598 | +0.0068 |
| 2 | 6 | 251.2531 | 251.2598 | +0.0068 |
| 3 | 𝑎 | 0.0000 | 0.0000 | +0.0000 |
| 3 | m | 24.2031 | 24.2044 | +0.0013 |
| 3 | o | 47.3631 | 47.3644 | +0.0013 |
| 3 | d | 61.1331 | 61.1344 | +0.0013 |
| 3 | 2 | 84.7963 | 84.7989 | +0.0026 |
| 3 | 𝑏 | 155.5430 | 155.5389 | -0.0041 |
| 3 | ( | 182.1663 | 182.1489 | -0.0174 |
| 3 | 3 | 193.8363 | 193.8189 | -0.0175 |
| 3 | ) | 208.8363 | 208.8189 | -0.0174 |
| 4 | 𝑐 | 0.0000 | 0.0000 | +0.0000 |
| 4 | ( | 27.0733 | 27.0600 | -0.0133 |
| 4 | m | 38.7433 | 38.7448 | +0.0014 |
| 4 | o | 61.9033 | 61.9048 | +0.0014 |
| 4 | d | 75.6733 | 75.6748 | +0.0015 |
| 4 | 4 | 101.0032 | 101.0064 | +0.0032 |
| 4 | ) | 116.0032 | 116.0064 | +0.0032 |
| 4 | 𝑑 | 137.6732 | 137.6664 | -0.0067 |
| 4 | m | 173.9932 | 173.9982 | +0.0050 |
| 4 | o | 197.1532 | 197.1582 | +0.0050 |
| 4 | d | 210.9232 | 210.9282 | +0.0050 |
| 4 | 5 | 236.2531 | 236.2598 | +0.0068 |
| 4 | 6 | 251.2531 | 251.2598 | +0.0068 |

**Max absolute diff: 0.0175 pt. All ≤ 0.5 pt.**

### Row 3–4 ≡ Row 1–2

| Position | Row 1 | Row 3 | Match? |
|----------|-------|-------|--------|
| a→m | 24.2031 | 24.2031 | ✅ identical |
| a→o | 47.3631 | 47.3631 | ✅ identical |
| a→2 | 84.7963 | 84.7963 | ✅ identical |

| Position | Row 2 | Row 4 | Match? |
|----------|-------|-------|--------|
| c→( | 27.0733 | 27.0733 | ✅ identical |
| d→5 (start of \mod{56}) | 236.2531 | 236.2531 | ✅ identical |
| d→6 | 251.2531 | 251.2531 | ✅ identical |

### Key spot-checks

- **a→m bmod gap** = 24.2031 pt (ztex) vs 24.2044 pt (XeTeX norm) → diff 0.0013 pt.
  Computed: math-italic 𝑎 advance (5.29 em × 3 = 15.87 pt) + 5 mu (8.334 pt) = 24.20 pt.
  Note: the task constraints mention "24.8 pt" but the measured XeTeX reference is 24.20 pt;
  the "24.8 pt" appears to be a typo — both ztex and XeTeX produce 24.20 pt.

- **\pmod parens hug content**: `(` advance = 3.89 em (LM Math) × 3 = 11.67 pt at 30 pt.
  The `(`→`3` gap in `\pod 3` (Row 1) = 11.6700 pt (ztex) vs 11.6700 pt (XeTeX) → diff 0.0000 pt.
  The `(`→`4` gap in `\pmod{4}` (Row 2) = 13.77 + 15.33 + 10.0 = 39.10 pt... actually the
  full `\pmod` content width is measured by the parens. The `(` at Row 2 is at rel 27.07,
  `)` is at rel 116.00; paren-to-paren width = 88.93 pt.

## Verification method

- **ztex SVG**: `zig build run -- -i '...' -s 30 -o /tmp/ztex_mod.svg`
- **XeTeX ref**: `\documentclass[preview,border=4pt]{standalone}\usepackage{amsmath}\usepackage{unicode-math}\fontsize{30}{36}\selectfont$\displaystyle \begin{array}{cc}...\end{array}$` → xelatex → mutool draw -F svg. XeTeX font matrix scale = 29.8879 (normalized to 30 pt in comparison).
- **Comparison**: per-glyph x positions, grouped by row (y), normalized to row-start-relative coordinates, XeTeX scaled by 30/29.8879. See `compare_mod.py` methodology.

## Test results

- `zig fmt --check src/layout/layout.zig src/layout/metrics.zig` → exit 0 ✅
- `zig build` → success ✅
- `zig build test` → **176/176** tests pass ✅
  - atom: 83 ✅
  - ztex: 18 ✅
  - root: 7 ✅
  - layout: 51 ✅ (includes pmod/pod/mod tests)
  - tests: 17 ✅
- `metrics.test.metrics: roman letters at script sizes scale the LM Math advance` ✅
- `layout.test.layout: pmod composes kern, parens, mod word, 6mu gap and arg` ✅
- `layout.test.layout: pod omits the mod word and keeps the 8mu kern in text style` ✅
