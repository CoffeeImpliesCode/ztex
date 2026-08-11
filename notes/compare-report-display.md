# ztex vs XeTeX: display-style comparison (10pt)

Run 2026-08-12. XeTeX re-typeset at DISPLAY mode (`\[...\]`, was `$...$` inline):
`scripts/extract_geom.py` `render_xetex` updated; /tmp/cmp/xetex_{1..7}.json re-rendered.
Sanity: bare `\[\sum\]`/`\[\int\]` via pdfTeX = identical ink to XeTeX (13.9/22.1pt).
ztex unchanged (already display). Tool: `compare_engines.py --ours ztex_i --ref xetex_i`
(dx>0 ours right, dy>0 ours up, dxi = dx/ref size; threshold >0.5pt or >0.05 dxi; reports /tmp/cmp/display_cmp_i.json).

| i | formula              | pairs | unmatch | mean\|dx\| | max\|dx\| | max\|dy\| | max dxi |
|---|----------------------|-------|---------|------------|-----------|-----------|---------|
| 1 | x^2                  | 2     | 0/0     | 0.261      | 0.521     | 0.016     | 0.075   |
| 2 | x_2                  | 2     | 0/0     | 0.261      | 0.521     | 0.005     | 0.075   |
| 3 | \frac{a+b}{c-d}      | 6     | 0/0     | 0.030      | 0.066     | 0.051     | 0.007   |
| 4 | \sum_{i=1}^{n} x_i   | 7     | 0/0     | 3.612      | 5.581     | 5.065     | 0.800   |
| 5 | a\cdot b             | 3     | 0/0     | 0.025      | 0.046     | 0.000     | 0.005   |
| 6 | \int_0^1 x\,dx       | 5     | 1/1     | 5.369      | 6.991     | 4.463     | 1.002   |
| 7 | x^2+y^2              | 5     | 0/0     | 0.296      | 0.521     | 0.016     | 0.075   |

## Did the frac / big-op "2x" discrepancies disappear?
- Frac: YES. All 6 frac glyphs now 10pt vs 9.96pt (ratio 1.00; was 1.43, 6/6 style mismatches); F3 clean (max dx 0.066pt).
- Big-op: NO — a real operator-metric gap REMAINS; the old "2x" (font-size 20 vs 9.96) was partly an artifact: cmex10 operators sit on a ~2em design master, so font-size != visual size. Ink-level truth (rasterized PDFs + PIL/fontTools on LM Math):
  - ∑: ztex ink 20.0x21.0pt, adv 21.1pt | XeTeX 13.9x13.2pt, adv 13.3pt -> ztex 1.44x LARGER
  - ∫: ztex ink 22.0x13.0pt, adv 13.3pt | XeTeX 22.1x8.8pt, adv 5.5pt -> height PARITY,
    raw advance 2.4x too wide, yet effective post-∫ advance 6.65pt too short (below).

## Ranked real discrepancies (display style)
1. **∑ operator 1.44x too big (F4).** ztex draws display ∑ at 20pt (LM Math glyph = 1.0em);
   TeX's display ∑ is ~1.4em -> 13.9pt. Cascades: limits 3.7-5.6pt right / 5.1pt down,
   post-∑ operand +5.06pt right (max dxi 0.80). Only visible size error on the corpus.
2. **∫ limit layout + post-operator advance (F6).** XeTeX staggers limits horizontally
   (0 at x=294.0, 1 at x=298.4); ztex stacks both at x=2.97 -> 1 unmatched per side. TeX
   applies the ∫ tail (italic correction): operand lands 16.09pt after the ∫ origin vs
   ztex 9.44pt -> integrand run sits 6.65pt left. Largest delta: 6.99pt on '1'.
3. **Script x-advance 0.52pt right (F1, F2, F7; dxi 0.075).** Scripts raised ~0.02pt and
   advanced 0.52pt right of TeX in every script formula; subscript depth matches (-0.005pt).
4. **F7 cumulative drift:** '+' 0.44pt left, 'y' 0.40pt left, trailing '2' +0.12pt — kern/
   italic-correction accumulation on top of #3.

## Parity (display style)
- Frac (F3) and a·b (F5): max dx <= 0.066pt, no unmatched, style ratios 1.00.
- All script/text/frac sizes match: 7.0/9.96/9.96pt vs ztex 7/10/10 (ratio 1.00).
- ∫ ink HEIGHT matches (22.0 vs 22.1pt; 0.5% = mutool scale artifact); F4's n-limit
  reorder from the inline run is gone (pairs 7/7, no unmatched).

## Single most impactful
**ztex's display ∑ is 1.44x too large (20pt vs 13.9pt ink; 21.1pt vs 13.3pt advance)** — the
only visible operator-size error, driving F4's worst deltas (5.58pt dx, 5.07pt dy,
dxi 0.80). Fix: scale display operators to TeX's ~1.4em display metrics (≈13.95pt at 10pt
base for ∑) instead of a flat 2x; then re-check ∫ limit placement + italic correction.
