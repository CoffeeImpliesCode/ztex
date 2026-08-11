# Fix: text-style big-op beside-limits follow XeTeX's rule

## The XeTeX rule (measured, XeTeX + unicode-math at 10pt and 30pt)

A non-display (text/script) big operator with beside scripts attaches them as:

- **Superscript at the base advance** — text ∫: 0.665em.
- **Subscript at advance − the base italic correction** — text ∫:
  0.665 − 0.332 = 0.333em. XeTeX tucks the SUBSCRIPT in by the glyph's lean.

The previous fix had them SWAPPED (sub at the advance 0.665em, sup at
advance + ic 0.997em), which was the opposite of XeTeX's actual behavior —
the "positioning on the second integral still broken" report.

Display `\intop\nolimits` beside scripts are a different, already-correct
rule (sup at the .v1 variant advance 0.999em, sub at 0.999 − .v1 ic 0.591 =
0.408em) — **not touched**.

## Change (src/layout/layout.zig, `layoutScript` op branch, non-display else)

Before:

```zig
sup_ic = s(ink.ic, size_pt);  // sup at advance + ic (0.997em) — wrong
sub_ic = 0;                   // sub at advance (0.665em) — wrong
```

After:

```zig
sup_ic = 0;                                   // sup at advance (0.665em)
sub_ic = -s(ink.ic, size_pt);                 // sub at advance − ic (0.333em)
```

`ink.ic` for the base ∫ is 3.32pt at 10pt (0.332em, the LM Math base-glyph
MathItalicsCorrection from `bigOpInk`). Ops with ic 0 (∑ ∏ ∐ ⋃ ⋂ ⨆) put both
scripts at the advance — unchanged by this rule.

Kept as-is: the text ∫ drawn as the base form at `size_pt × base_asc/disp_asc`
(glyph_size in `layoutOp`), the display nolimits branch, `\limits`/`\nolimits`
overrides, the limits vbox, and all vertical placements.

## Verification (ztex `zig build run`, `-s 30`, text style)

`\textstyle\int_0^1 x\,dx` — positions relative to the ∫ box origin:

| glyph | before (wrong) | after | XeTeX target | Δ |
|---|---|---|---|---|
| sub `0` | 19.95pt (0.665em) | 9.99pt (0.333em) | 9.99pt | 0.00 |
| sup `1` | 23.27pt (0.776em) | 19.95pt (0.665em) | 19.95pt | 0.00 |
| next `x` (row advance) | 41.67pt | 35.95pt | 35.95pt | 0.00 |

The sub at 9.99pt sits at the base-form ink edge (∫ ink ≈ 9.81pt wide at the
17.74pt drawn size) without overlapping. The row advance
(script box = max(sup extent, sub extent) + 0.5pt scriptspace, then the op→ord
thin 5.0pt at 30pt) reproduces XeTeX exactly.

Other big ops at `-s 30` (ic = 0 → both scripts at the advance):

- `\textstyle\sum_0^1`: sup 31.68pt = 1.056em × 30, sub 31.68pt ✓
- `\textstyle\prod_0^1`: sup 28.32pt = 0.944em × 30, sub 28.32pt ✓
- `\textstyle\bigcup_0^1`: sup 24.99pt = 0.833em × 30, sub 24.99pt ✓

Not broken (re-verified at `-s 30`):

- Display `\int_0^1`: sup 29.97pt (0.999em), sub 12.24pt (0.408em) — .v1 rule
  unchanged.
- `\sum_{i=1}^{n}` display: limits vbox, limits centered on the ∑.
- `\int\limits_0^1`: limits vbox (1 over, 0 under).

`zig build` compiles clean (0.16.0). Gates skipped per instructions; goldens
regenerate elsewhere. Edit confined to src/layout/layout.zig.
