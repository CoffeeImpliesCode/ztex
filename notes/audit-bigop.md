# audit-bigop — ztex big-ops vs MicroTeX BigOperatorAtom + XeTeX make_op

Date 2026-08-12. Authoritative = XeTeX (xetex-math.c make_op/make_scripts, cmex TFM).
ztex = layout.zig layoutOp/layoutOpLimits/layoutScript/opTailIc/bigOpLimits + metrics.displayOp.

## Correct
limits/nolimits flag set (sum prod coprod bigcup bigcap bigsqcup = limits; int oint = nolimits).
display_ops box metrics (cmex next-larger O130/O111 etc). limits gaps / axis-centering / staggering.
beside-script geometry (scripted nolimits op).

## Residuals (ranked)
| # | issue | magnitude | fix |
|---|---|---|---|
| 1 | opTailIc adds ic after a BARE op (∫/∮) — XeTeX does NOT (make_op goto lab82, ic-kern only in scripted path) | +4.44446pt (display) / +1.94446pt (text) per bare ∫ | remove the bare-op ic from opTailIc (VERIFY empirically first) |
| 2 | drawn display-op glyph is the LMM Unicode codepoint scaled to 1.4x/2.0x font-size, NOT the real cmex next-larger glyph at base size | box dims correct but ink width/shape mismatch (∫ ink likely overflows the 5.56pt cmex advance) | draw the actual cmex glyph, or accept + tune |
| 3 | bare display/text ops NOT axis-centered (no-script ∫ sits on baseline; XeTeX centers on axis) | 13.56pt (display ∫) | axis-center bare display ops |
| 4 | text/script op box+glyph hardcoded to 10pt, not scaled by size_pt | scales wrong at non-10pt | scale by size_pt |
