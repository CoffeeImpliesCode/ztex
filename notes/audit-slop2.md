# Audit: AI slop markers (round 2) — AuditSlop2b

READ-ONLY audit. Evidence from targeted grep + ranged reads; no whole-file reads.

## S1 (deferred from prior audit) — what remains

Prior audit fixed S2-S5 and deferred S1: narration headers in atom/box/draw +
restating accessor comments. Still present:

- **src/atom.zig:1-11** header: `//! ztex.atom — superflat LaTeX atom (AST).` + 6 lines
  narrating the house superflat pattern (`cf. ~/projects/{vain,skript}`,
  "No pointers, no pointer chasing, no per-node allocation").
  **AND atom.zig:16-20 repeats it**: `// Provenance design (house superflat
  pattern, cf. ~/projects/{vain,skript}): the lexer pre-tokenizes...` — the
  same "house pattern" claim twice in one file. Keep the header; delete the
  token-section re-narration (the Token/span doc comments below it already
  explain provenance per-field).
- **src/layout/box.zig:1-10** header: `Same pattern as the atom AST: one flat
  array of fixed-size boxes...` — restates atom.zig's header + re-claims the
  provenance mapping. Trim to 2 lines (`ztex.layout.box — superflat TeX box
  model.` + the ChildRef/shared-header fact the reader needs).
- **src/layout/draw.zig:1-9** header: third repetition of the provenance
  promise ("so any output drawable maps back to its input text/tokens in
  O(1)"). One sentence suffices; drop the duplicated "terminal artifact"
  paragraph.
- **Restating accessor comments** (S1 remainder):
  - src/font.zig:267-318 — 8 accessors whose `///` doc merely restates the
    formula: `unitsPerEm` ("Font design size in font units per em"),
    `ascenderEm` ("Nominal ascent, em units (hhea.ascent ÷ upem)"), etc.
    Formula comments are fine on a private impl; on 8 pub getters they are
    restatement. Fold into one comment block or delete.
  - src/atom.zig:423-439 — `pushToken` "Append a token; returns nothing",
    `pushNode` "Append a single node; returns its index", `pushNodes`
    "Append a contiguous run of nodes; returns the index of the first" —
    names already say this.
  - src/parse/error.zig:70 `countCodepoints` "…", 82 `lineCol` "…", 97
    `sourceLine` "…" — doc comments restate the names (the *behavior* notes
    are useful; the first line of each is restatement).

## NEW findings

### H1. Audit-issue IDs leaked into source comments
Internal audit-session labels (H1/H2/H3/SIM1/SIM2/L2) are embedded in doc
comments where they mean nothing to a future reader:
- src/context.zig:21 `(SIM1/H1)`, 22 `(SIM2)`, 112 `(H2)`
- src/font.zig:18 `(SIM2)`
- src/main.zig:49 `(H3)`, 76 `(H2)`, 130 `(L2)`
- src/root.zig:27 `(SIM1/H1...)`, 39 `(H2)`
- src/layout/metrics.zig:102 `(SIM2)`, 116 `(SIM2)`
- src/layout/root.zig:20 `(SIM1/H1)`
- src/parse/error.zig:81 `(L2)`
Fix: strip the parenthetical IDs, keep the actual explanation
(e.g. main.zig:49 → "…a real CLI error instead of a silent transparent
background"). Mechanical, output-neutral.

### H2. Dead pub export chain `Style`
src/root.zig:14 `pub const Style = layout.Style;` and
src/layout/root.zig:14 `pub const Style = layout.Style;` — zero consumers
repo-wide (grep `ztex.Style|layout.Style|\.Style` finds only the decls).
Fix: delete both re-exports (canonical `Style` lives in layout.zig).

### H3. Dead pub export `box` in layout/root.zig:10
`pub const box = @import("box.zig");` — no consumer (`layout.box` unused;
layout.zig/draw.zig import box.zig directly; context/svg go through
`layout.draw`/`layout.metrics` only). Fix: delete the re-export.
(`pub const metrics` and `pub const draw` ARE consumed.)

### M1. Duplicated fraction comment block
src/layout/layout.zig:3489-3492 AND 3503-3506 both narrate "Numerator and
denominator are set one style level down" — two versions of the same
explanation back to back (first cites MicroTeX, second adds the cramped-bit
detail). Fix: merge into ONE comment (keep the cramped text, drop the
duplicate lead-in at 3489 or 3503).

### M2. Dead pub fn `lookupAscii`
src/layout/metrics.zig:2518 `pub fn lookupAscii` — only referenced by its own
tests (metrics.zig:3028-3032); layoutChar/layoutText call `glyphAt` directly,
so the promised O(1) ASCII fast path is never wired in. Fix: either call it
from layout.zig (`glyphAt`'s `.static` arm) or make it a private test helper.
As-is it is dead export surface with a doc comment describing a fast path
that production never takes.

### M3. Stale "legacy wrapper" dead fn `parseColor`
src/svg.zig:220-222 `pub fn parseColor` — used only by its own tests
(svg.zig:373-377); doc claims "Kept so existing callers compile unchanged"
but main.zig:50 uses `parseColorChecked`. The justification is stale; the fn
is dead. Fix: delete both fn and its 2-line doc (keep `parseColorChecked`),
or if kept for API stability, drop the "existing callers" claim.

### M4. Unused `fm` params forcing `_ = fm` discards
- src/layout/layout.zig:2638 `opTailIc(..., fm, ...)` — `_ = fm;` at 2642;
  fn only uses `bigOpInk` static tables. Param is dead.
- src/layout/layout.zig:4181 `textEmitMark(..., fm, ...)` — `_ = fm;` at 4192;
  fn only uses `metrics.glyphInk`. Param is dead.
Fix: drop the param from both signatures + call sites; removes the discard
statements (the only `_ = <param>` discards in production layout code).
metrics.zig:2528 `_ = cp;` in `glyphEstimateImpl` is similar but intentional
(unknown-glyph fallback); leave.

### L1. Eight unused pub getters on FontFace
src/font.zig:267-318 `unitsPerEm`, `ascenderEm`, `descenderEm`, `lineGapEm`,
`typoAscenderEm`, `typoDescenderEm`, `typoLineGapEm`, `winAscentEm`,
`winDescentEm` — all `pub`, all consumed only inside font.zig
(metrics fn:520-523 + tests). Export-surface slop. Fix: make non-pub or
group into one `metrics()` accessor.

### L2. Stale "prior attempt" narration
src/layout/layout.zig:496-499 `firstCodepoint` doc references "the previous
`Utf8View.init(...) catch null` fallback" and "zg substitutes U+FFFD" — a
migration story, not an API contract. Trim to the behavior
("Empty/malformed UTF-8 yields 0; genuine U+FFFD decodes len 3, kept").

### L3. `catch null` — all remaining instances justified
font.zig:371 (optional OS/2 table), svg.zig:221 (inside the dead `parseColor`
— dies with M3). No other error swallowing found: no `catch {}`,
no `orelse unreachable`, no `@panic` outside atom.zig:491 bounds assert.

## Comment narration — worst 5 quotes (fix target)

1. layout.zig:3503-3506 — duplicated fraction style narration (see M1).
2. atom.zig:16-20 — "Provenance design (house superflat pattern,
   cf. `~/projects/{vain,skript}`)…" repeats the file header verbatim-ish.
3. box.zig:3-4 — "Same pattern as the atom AST: one flat array of fixed-size
   boxes…" restates atom.zig's header.
4. font.zig:267-270 — "/// Font design size in font units per em
   (head.unitsPerEm)." restates `fn unitsPerEm`.
5. layout.zig:496-499 — "matching the previous `Utf8View.init(...) catch
   null` fallback" (migration narrative).

## Top-5 slop fixes by payoff

1. **Strip audit IDs (H1)** — 12 sites, mechanical, kills the most
   context-free noise; comments then read as facts not session trivia.
2. **Delete dead re-exports (H2/H3)** — `Style` ×2 + `box` in layout/root.zig;
   shrinks the pub surface of the crate root and the layout module.
3. **Merge duplicated fraction comment (M1)** — layout.zig:3489-3506, one
   block instead of two; removes the "which one is current?" trap.
4. **Remove unused `fm` params (M4)** — opTailIc + textEmitMark; kills the
   two `_ = fm` production discards and dead signature weight.
5. **Resolve `lookupAscii`/`parseColor` dead fns (M2/M3)** — wire the ASCII
   fast path into layoutChar (real perf win the doc already promises) and
   delete the stale legacy wrapper.
