# audit-fraction — ztex layoutFraction vs MicroTeX FractionAtom + XeTeX make_fraction

Date 2026-08-12. Authoritative = XeTeX (xetex-math.c:2046-2162 make_fraction).
ztex = layout.zig:711-822. MicroTeX = atom_impl.cpp:224-309.

## VERDICT: CORRECT on every specified residual
- num1=6.76508 num2=3.93732 num3=4.43731 denom1=6.85951 denom2=3.44841 denom3=1.63 — all match cm.
- clearance 3*rt (display \over) / 7*rt (display \atop) / rt (text \over) / 3*rt (text \atop) — exact.
- kern1/kern2 rule-on-axis clearance — exact.
- \atop even-split of deficit — exact.
- \nulldelimiterspace 1.2pt fixed, unscaled, on BOTH \over and \atop; folded box width max+2.4;
  children +1.2; rule spans inner width — exact.

## Genuine deviations (negligible)
- R1: denominator not set in cramped style (small/indirect, matches MicroTeX).
- R2: half() truncation vs float /2 (negligible).

Nothing for the fix phase to correct in the fraction geometry.
