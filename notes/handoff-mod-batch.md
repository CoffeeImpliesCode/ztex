# HANDOFF — Mod + display-∫ limits batch (2026-08-16)

## Repo / VCS
- ~/projects/ztex (Zig 0.16, jj ONLY — single squashed working-copy commit; do not use git).
- Gate: `zig fmt --check`, `zig build`, `zig build test`, `zlint`, `ziglint` (`gate` script). Corpus: `scripts/katex_corpus.py` (126 ss_data entries). Critique: `scripts/critique.py --ref` (ztex/XeTeX/KaTeX/MathJax 4-pane).

## Verified-landed (this batch, BEFORE the two failed agents)
1. `scripts/critique.py combine_panes`: native pane scales (no width-matching upscale) — the sizing-consistency fix. Verified: panes no longer distorted.
2. Parse-error context (`ztex.parse.err`): `Info{kind, span}` + `lineCol`/`sourceLine` helpers; main.zig prints caret errors. 175 tests passed at landing. CLI verified:
   - `\frac{1}{2}}` → "Unexpected '}' (UnexpectedRGroup) at line 1, col 12" + caret
   - `x^2 + \left(` → "Unclosed group (UnclosedGroup) at line 1, col 7" + caret under `\left(`
3. Text-style big-ops (FixTextOpSize, verified + notes/fix-text-ops.md): layoutOp draws non-display ops at FULL size_pt; box.bigop_form (.base/.variant) threaded box → svg.zig (`data-op="v1"`) → critique rasterizer/verifier (marker-driven .v1 resolution, display only). Text ∫ ink 33.33pt == XeTeX 33.22 / KaTeX 33.33 / MathJax 33.33. Limits stagger-aware verifier (XeTeX-validated; INTENTIONAL TeX stagger 4.97pt is no longer a false positive). LimitControls critique PASS at landing.

## IN THE TREE NOW, UNVERIFIED (both agents exited before finishing; tree COMPILES)
**ModComplete edits (metrics.zig + layout.zig + tests):**
- `table_roman17` (src/layout/metrics.zig ~1245): REAL LMRoman17-regular OTF advances (m 0.772, o 0.459, d 0.511 em) for the roman band.
- `band17(size_pt)` = size_pt >= 15 (measured: the XeTeX ref switches to lmroman17 at ≥15pt, NOT 17.28); `tableFor`/`glyphAt` intercept roman style in that band.
- layoutPmod/layoutPod/\mod leads are style-INVARIANT (8mu/8mu/12mu; the display 18mu variants REMOVED — the \if@display branch never fires in XeTeX array cells; ref rows 3-4 ≡ rows 1-2 confirmed at \fontsize{30}).
- IC-before-kern in layoutRow (`charIc`, n by value): a preceding char's IC joins the pmod/pod/mod lead kerns (NOT \bmod — glue, verified). Doc + tests updated (band17 test added).
- **2 GOLDEN TESTS NOW FAIL (intentional output change, goldens stale)**: `regression: draw-list snapshots` + `regression: svg snapshots` — `\text{hi}` at 20pt: i x 11.12 → 10.22 (band17 narrow LMRoman17 advances). REGENERATE the goldens (the test prints expected vs found — update the expected).

**DisplayIntVbox edits (box.zig + layout.zig):**
- box.zig: `disp_advance: f32 = 0` (set in layoutOp from bigOpInk(op,true).disp_advance = 0.999em for ∫/∮, == advance for others).
- layoutOpLimits (~2873-2929): `variant = bb.bigop_form == .variant`; `op_w = if (variant) bb.disp_advance*size_pt else bb.width` — display-∫ limits vbox now boxes by the .v1 advance (was base 0.665em → +∫ ink tail overlapped the next term 2.08pt vs XeTeX 7.9pt).
- AGENT FINDING — VERIFIED APPLIED (checked in the tree): the display-op limits stagger delta now uses `bb.disp_ic` (the .v1 italic correction 0.591em/2 = 8.83pt at 30), NOT the base displayOp.ic (0.332em): `delta = if (variant) s(bb.disp_ic, size_pt) else if (metrics.displayOp(bb.cp)) |dop| s(dop.ic, size_pt) else 0` at layoutOpLimits ~2874. Text-∫ keeps base ic (4.97pt) — unchanged. Wide-limit case (∑): XeTeX CENTERS the variant box in the wide vbox (x_shift = (vbox_w−op_w)/2) — the applied code should do the same; VERIFY.

## Test state NOW
- `zig build`: PASS. `zig build test`: 174/176 (2 fail = the stale `\text{hi}` goldens above — regenerate, do not "fix" the render).

## Next steps (ordered)
1. REGENERATE the 2 golden tests (draw-list + svg snapshots) for the intentional band17 change.
2. Verify DisplayIntVbox's stagger-delta finding: the display ∫ limits over/under in \int\limits_2^3 must sit at vbox-center ± (v1 ic 0.591em)/2 at 30pt (= ±8.83pt) vs the fresh \fontsize{30} ref; apply if missing. Keep text-∫ (base ic 4.97pt) unchanged.
3. Element-wise verify the Mod entry (array with a\bmod/pod/pmod/mod, display + text rows) vs fresh \fontsize{30} XeTeX ref ≤0.5pt/glyph: rows 3-4 ≡ rows 1-2; mod-word letters now lmroman17; \pmod parens hug (advance 11.67pt@30).
4. Verify LimitControls entry (display ∫\limits_2^3 + ∑\nolimits + text ∫\limits) vs the ref: the ∫ tail clears the next term (XeTeX ~7.9pt), limits centered/staggered per ref, text-∫ limits unchanged.
5. Full gates (fmt/build/test/zlint/ziglint) + `scripts/critique.py --ref` Mod + LimitControls + corpus battery count + fresh 4-pane gallery.
6. Write notes/fix-mod-lmroman17.md + notes/fix-display-limits-vbox.md (missing — both agents exited before writing them).
7. jj describe commit.

## Ref recipes
- \fontsize{30} XeTeX: \documentclass[preview,border=4pt]{standalone} + \usepackage{amsmath,unicode-math} + \fontsize{30}{36}\selectfont. xelatex → mutool (s)vg: /nix/store/xc6gf1n7fy1hnczm2lmbsyr5c4himwd5-mupdf-1.27.2-bin/bin/mutool draw -F svg. Parse: scripts/extract_geom.py eg.parse_xetex_svg; ref scale ≈29.8879 (actual PDF size).
- lmroman17 OTF: kpsewhich lmroman17-regular.otf (texlive store). LM Math OTF: /nix/store/wgpnygkr70hxa0vj5ka284cfc65bfzyn-devenv-profile/share/fonts/opentype/latinmodern-math.otf.

## Key files
src/layout/layout.zig (layoutOp ~3090, layoutOpLimits ~2790, layoutPmod ~1210, layoutRow IC call ~1073, charIc ~1556, envIc ~1483, bigOpInk ~3020) | src/layout/metrics.zig (table_roman17 ~1245, band17 ~1827, tableFor/glyphAt ~1834-1868) | src/layout/box.zig (bigop_form, disp_advance ~80-86) | src/svg.zig (data-op) | scripts/critique.py (combine_panes, marker raster/verifier) | src/parse/{error.zig,lexer.zig,parser.zig,root.zig} + main.zig (parse-error context).