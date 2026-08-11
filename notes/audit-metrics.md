# audit-metrics — ztex metrics.zig + char/space/text vs MicroTeX + XeTeX

Date 2026-08-12. Authoritative = XeTeX (real cm TFM). MicroTeX = table source (cmr/cmmi/cmsy/cmex .def.cpp em x 10).

## Headline finding — the "looks worse" cause (architectural)
ztex LAYS OUT with Computer Modern TFM metrics (correct, faithful transcription) but DRAWS SVG <text>
with font-family "Latin Modern Math, Latin Modern Roman, DejaVu Serif" whose ink geometry
(x-height/cap/advance) differs from CM. The box w/h/d only position siblings — never shape/clip the
drawn glyph — so ink is Latin Modern's while positions are CM's. The ink does NOT sit where the metrics
predict. This is the primary reason the render looks substantially different from XeTeX (which uses
actual CM/LM fonts).

To fix: draw with a font whose ink matches CM metrics (the CM OTFs cmunrm/cmunit/cmunsy, or a
MathJax/KaTeX path), OR accept CM metrics + Latin Modern ink as a documented limitation.

## Other findings
| # | issue | magnitude | fix |
|---|---|---|---|
| 1 | layoutSpace (\, \; \quad) not style/quad-aware — thin/med/thick mu-spaces use 1em quad in scripts, NOT the cmsy7/cmsy5 quad | ~17% too narrow in script styles | use quadEm(style)/18 like inter-atom glue |
| 2 | display-op draw scale is LMM-ink fudge (1.4/2.0) not real cmex | ink width/shape mismatch | (see audit-bigop) |
| 3 | glyphEstimate gaps: \neg \ldots \ell \Re \Im \wp and ASCII \# \% \& \_ \$ still missing | those chars render at 0.5em estimate | add real metrics |
| 4 | glyphAt script tables (cmr7/cmmi7/cmsy7, cmr5/cmmi5/cmsy5) + size/10 scaling | verified CORRECT and MORE faithful than MicroTeX (which linearly scales cmr10 by 0.7/0.5) | none |
