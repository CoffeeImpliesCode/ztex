# Big-op layout rules fix (\int/\oint \nolimits)

Date: 2026-08-12 · Files: `src/layout/layout.zig` only (atom.zig untouched)

Driver: notes/corpus-diff.md ranks `\int_0^1` the worst divergence vs XeTeX
(mean|dx| 8.2pt, max 9.96pt, unmatched 2/1). Root cause: layoutScript sent
EVERY display-style big op to layoutOpLimits (over/under), but in TeX
`\int`/`\oint` are `\intop\nolimits` (fontmath.ltx) — their limits are BESIDE
as script-size sub/superscripts. Only `\sum \prod \coprod \bigcup \bigcap
\bigsqcup` take display over/under limits.

## Change 1 — per-op limits flag

New helper `bigOpLimits(op: atom.BigOp) bool` (beside `bigOpCodepoint`):

- true: sum, prod, coprod, bigcup, bigcap, bigsqcup
- false: int, oint

Kept in layout.zig as a helper (allowed by spec); the atom.BigOp enum needs
no field, so atom.zig is untouched. Note: the atom.zig BigOp doc comment
("scripts become limits in display style") is now only true for limits ops —
left as-is per edit scope.

layoutScript routes to layoutOpLimits only when
`base_atom.tag == .op and style == .display and bigOpLimits(...)`; otherwise
the op falls through to the normal beside-script path (TeX \nolimits). For
the beside case the op box is already the display box (layoutOp returns the
displayOp box in display style) and scripts are laid beside at script size
(size × 0.7).

Geometry, `\int_0^1` display, 10pt:
- Before: vbox, ∫ centered on axis at shift (0−22.22246)/2 − 2.5 = −13.61;
  sup above, sub below; width = max(5.55557, sup_w, sub_w).
- After: beside box, ∫ on baseline at x=0, sup at x=10.00003, sub at x=5.55557.
- Reference: XeTeX — ∫ advance 5.556, sup at 10.0, sub at 5.556.

`\sum_{i=0}^n` display: behavior unchanged (vbox, staggering, gaps).

## Change 2 — beside-sup x-offset for a display nolimits op

In layoutScript's sup_ic computation, when the base is a display-style big op
with limits=false (∫/∮), the superscript italic gap uses the DISPLAY
variant's italic correction instead of the small glyph's:

- Before: table (small glyph) ic for ∫ = 1.94446 → sup at 5.55557 + 1.94446
  = 7.50003 (wrong).
- After: displayOp(∫).ic = 4.44446 → sup at 5.55557 + 4.44446 = 10.00003.
- Reference: XeTeX puts the ∫ sup at ∫_advance + ic = 5.556 + 4.444 = 10.0pt;
  the subscript stays at ∫_advance = 5.556 (sub_gap = 0, unchanged).

## Change 3 — opTailIc must not double-count

The post-op italic tail now applies ONLY to a bare op (any style) or a
display-LIMITS op (its vbox carries no ic). The `.script` branch now guards
on `bigOpLimits(...)`:

- Before: any display-style scripted op got the display ic tail — for the
  beside-scripted ∫_0^1 the ic was already inside the script box width (sup
  placed at bb.width + ic), so the row advance counted it twice.
- After: beside-scripted ops (limits=false) return 0. Limits ops still return
  the display ic (all currently 0: ∑/∏/⋃/⋂/⨆/∐ display ic = 0), so ∑ display
  behavior is bit-identical; bare display ∫ keeps its 4.44446 tail
  (measured post-∫ advance 16.15pt = box + ic + thin).

## Change 4 — text-style big-op box uses real metrics

layoutOp's non-display (text/script) branch replaced the made-up
`w = 0.8·size, h = 0.7·size, d = 0` with the real cmex10 text-size box from
metrics.table (looked up via lookupAscii → glyph → estimate, same pattern as
layoutChar). At 10pt:

| op | before | after (table) |
|----|--------|---------------|
| ∑  | 8.0 × 7.0 + 0   | w=10.55559, h=0, d=10.00013 |
| ∫ ∮ | 8.0 × 7.0 + 0  | w=4.72223, h=0, d=11.11122 |
| ∏ ∐ | 8.0 × 7.0 + 0  | w=9.444475, h=0, d=10.00013 |
| ⋂ ⋃ ⨆ | 8.0 × 7.0 + 0 | w=8.33336, h=0, d=10.00013 |

The beside-script placement (Change 1/2 path) then uses these real dims, so
inline `\int_0^1`: sup at 4.72223 + 1.94446 (table ic) = 6.66669, sub at
4.72223.

## Reference values kept exact

- displayOp ic: ∫/∮ = 4.44446pt; ∑/∏/∐/⋃/⋂/⨆ = 0.
- displayOp boxes: ∑ O130 w=14.44448 h=1.00001 d=15.00012; ∫ O111 w=5.55557
  h=0 d=22.22246.
- ∑/∏/⋃/⋂ over/under limits + staggering unchanged (they measure
  ~0.5–1.5pt, near-parity).
- ∫ beside-scripts set at script size (size × 0.7).

## Constraints honored

- Superflat box model, spans/provenance, `.synthetic` flag: preserved
  (layoutOp still creates one `.char` box with `synthetic = true`).
- Verification skipped per instructions (no build/test/fmt/ziglint run).
- Goldens WILL regenerate — tests/goldens intentionally untouched.
