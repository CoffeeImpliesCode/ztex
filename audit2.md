# ztex — Adversarial Audit Round 2

- **Original pass**: 2026-08-16, five read-only lenses (API complexity,
  functionality gaps, generality/embeddability, magic numbers, AI-slop
- **Status pass**: 2026-10-01, re-opened the same day to correct every
  drifted `file:line` citation and to re-verify the roadmap against the
  parser. The five per-lens note files this round was assembled from are not
  part of the repository — the findings they produced are reproduced inline
  below and nowhere else.
- **Re-audit**: 2026-10-02, after the feature wave that closed the whole
  roadmap below, the SVG unit and stack-rel fixes, and the ink-overhang and
  MATH-metadata work. No finding changed status; three entries below now carry
  a follow-up note because the wave changed the answer they were resting on.
  Citations are `path` + symbol rather than `path:line`: the line numbers
  drifted twice, and a symbol survives the next edit that moves code.
- **Scope**: the same tree as `audit.md`, plus `src/raster.zig` and
  `build.zig.zon`.
- **Method**: static reading only; nothing here was runtime-verified.

## Status legend

- **LANDED** — fixed in the current source. The line names where it lives now,
  by symbol.
- **OPEN** — still present. The line names the construct by symbol.

A finding that is only half addressed is marked **OPEN** with the landed half
named in the note, so the queue never overstates progress.

## Severity legend

**C** = soundness/remote-crash, **H** = correctness/contract,
**M** = design/cleanup, **L** = docs/minor.

---

## C — critical

### C1. No recursion-depth limit → stack overflow on untrusted input — **LANDED**

The parser now carries a depth counter and fails with
`error.NestingTooDeep`: the error member in `Parser.Error`, the `depth` field
and the guard at the top of `parseRow`, with `max_nesting` itself the exported
bound (`src/parse/parser.zig`, `max_nesting = 500`). `Kind.nesting_too_deep`
carries it end to end (`src/parse/error.zig`), and both the trip case and the
exact boundary are pinned by tests in `src/parse/root.zig`.

The raw-text leaves have their own bound, `atom.max_text_nesting` (also 500),
enforced in the parser's `scanBracedGroup`: `\textit{\textbf{…}}` keeps the
whole argument as ONE `.text` leaf and layout opens a face scope per inner
command, so a nested run needs a layout-side stack and gets its own limit.

The layout half — recursion over hand-built ASTs — is covered by the
iterative boundary validator, which walks a worklist instead of recursing
(`validateAst`, `src/layout/root.zig`), so a pathological tree cannot overflow
the validator's own stack either.

### C2. `Ast.child` @panic + BoxList asserts on the documented hand-built-AST path — **LANDED**

`layout.render` validates the root-reachable subtree once, before touching
the box pool: child counts against each tag's arity, child indices in bounds,
and a tree-shaped reachable graph (`validateAst`, called at the top of
`render`). A malformed hand-built tree returns `error.InvalidAst`; the
`Ast.child` @panic (`src/atom.zig`) and the `BoxList` asserts
(`src/layout/box.zig`) stay as internal invariant checks that a validated tree
never trips.

The arity table grew with the wave — `\hline` is a leaf legal only at an
environment row boundary, and the new `.boxed` / `.color` / `.textcolor` /
`.textit` / `.textbf` tags each carry exactly one child — so the validator
covers them by the same declaration.

---

## H — high

### H1. Context is not thread-safe; undocumented — **LANDED**

The module header states the rule and both remedies — one Context per thread,
or an external mutex — and names the static facade as the shareable path
(`src/context.zig`). The header also explains the heap allocation and why
`render` is not a const operation.

### H2. Source-byte headroom did not enforce node-index capacity — **LANDED**

`max_source_bytes` remains `maxInt(u32)/2`, with its input boundary tested
without a multi-GiB allocation. That heuristic is not the node-pool guarantee:
`Ast.pushNode`, `pushNodes` and `createNode` now check the complete new run
against `maxInt(u32)` before narrowing an index or requesting capacity.
Representational exhaustion returns `OutOfMemory`, like an allocator unable to
grow the pool. `createNode` reserves its children and parent together, so it
does not copy a run that cannot have its parent. The oversized-run regression
failed before the fix because the allocator received the impossible request;
it now passes, along with the exact last-run and first-overflow boundaries.

### H3 (slop). Audit-issue IDs leaked into source comments — **LANDED**

Every `(C1)`-style parenthetical is gone: a search for the pattern across
`src/` returns nothing. The sites that carried them — the parser's depth
field, its `fail()` lexer-only arms, the nesting guard, and the `lookupAscii`
fast-path test — now read without the label and keep their explanations.

### H4 (slop). Dead pub re-exports — **LANDED**

All four are gone. `ztex.layout` re-exports `metrics`, `draw` and `layout` and
`box` is a private import (`src/layout/root.zig`); the `Style` alias this
round removed came back as the parameter type of `render`, not as a dead
re-export. `ztex` imports `context.zig` privately (`src/root.zig`) and
publishes only `Context`, so the old `pub const context` is still gone.

---

## M — medium

### M1. Duplicated facade plumbing — **LANDED**

One helper, `renderPipeline` (`src/root.zig`). Both facades are thin wrappers
over it (`ztex.render` and `Context.render`); the `err_info` out-param and the
error mapping are threaded exactly once.

**Re-audit note (2026-10-02).** The helper is no longer file-private: it is
`pub` because `src/context.zig` calls it through a relative
`@import("root.zig")`, which a file-level `fn` cannot satisfy. Its doc comment
still marks it internal, and the host-facing surface did not grow —
`include/ztex.h` and `README.md` name `ztex.render` / `Context.render` only.

### M2. Redundant `gpa` param on `Context.render` — **LANDED**

The parameter is gone; the facade allocates with `self.gpa` (`Context.render`,
`src/context.zig`).

### M3. `catch error.OutOfMemory` swallows future non-OOM layout errors — **LANDED**

`layout.render` has a closed set, `error{ OutOfMemory, InvalidAst }`
(`src/layout/root.zig`), and the facade lets both propagate unmapped instead
of catching (`renderPipeline`, `src/root.zig`). `main` then matches exactly
those two by name and treats everything else as a parse error (`src/main.zig`).

### M4. `svg.writeFile` hardcodes cwd; fs in the library module — **LANDED**

`writeFile` takes an explicit `std.Io.Dir` (`src/svg.zig`); `render` stays
pure. The CLI passes `std.Io.Dir.cwd()` explicitly (`src/main.zig`).

### M5. No exact ink-bounds API; heuristic svg margins — **LANDED**

`DrawList.bounds()` returns a named `InkBounds` (`src/layout/draw.zig`)
carrying `min_x`/`min_y` alongside the span, and both consumers frame from it.
`svg.render` builds the viewBox, the baseline offset, and every primitive shift
from the ink bbox (`src/svg.zig`), offsetting by the ink ORIGIN rather than
assuming it is zero — a fraction's first ink is its numerator inset by TeX's
nulldelimiterspace, so `min_x` is positive there. `raster.rasterize` uses the
same basis with a private `Origin` (`src/raster.zig`), so SVG and raster agree
on the content extent.

The heuristic vertical margin is gone: vertical ink extents are exact (a char
box's h/d IS the drawn glyph's ink), so the ink top lands on the frame edge.

**Re-audit note (2026-10-02).** The horizontal term this finding left open —
"the accumulated ink's horizontal extent is the glyph ADVANCE rather than the
true ink edge", absorbed by 0.08em of margin per side — is now closed at the
source instead of in the frame. The layout measures each drawn glyph's real
ink edges from the face it is painted from (`metrics.GlyphInk`, generated
into `src/layout/ink_metrics.zig` and read through `metrics.glyphInkAt`),
stashes them on the char box (`layout.setCharOverhang`, one assignment per
producer, from the same lookup that boxed the glyph), and `flatten` unions them
into the running ink bbox. The horizontal ink edge is therefore the advance box
UNIONED with the real overhang: a math-italic `j`, every combining mark and the
italic/bold `f` hook land inside the frame instead of being shaved off it, and
a glyph whose ink fits its advance box still gets exactly the old extent (both
overhangs are 0 there, so the union is the advance box). What is left on the
frame is the caller's `padding` and the browser line-gap below the baseline
(Latin Modern Math's 0.2em, which a browser includes in the text line box and
which bounding only the glyph ink would clip). The 0.08em margin term is
deleted.

### M6. Magic-number drift: same constant in two+ places — **LANDED**

Every constant this finding named now has exactly one source:

- baseline drops: `GlueParams.supdrop`/`subdrop` (`src/layout/metrics.zig`),
  consumed through `gl` in `src/layout/layout.zig`;
- script-size factors: the `GlueParams` rows beside them, consumed through
  `gl` — no re-literal of 0.7/0.5 anywhere;
- `axis_height`: read from `gl` at every use in `src/layout/layout.zig`;
- big-operator advances/ics: `metrics.BigOpInk` / `bigOpInk`
  (`src/layout/metrics.zig`), consumed in `src/layout/layout.zig`;
- the 2.392em (parenleft.v6) constant: `big_target_ink` in
  `src/layout/layout.zig` is aliased once per target style
  (`ams_delim_req_display_em`, `ams_delim_req_small_em`) and read through those
  aliases by `binomDelimReqEm`.

**Re-audit note (2026-10-02).** Two more constants joined the same treatment
with the wave: `\fboxsep` / `\fboxrule` are single literals
(`fboxsep_pt = 3.0`, `fboxrule_pt = 0.4`, `src/layout/layout.zig`) read by
`layoutBoxed`, because `\boxed` must not scale them with the font size; and
the parser's nesting bound is published once (`max_nesting` in
`src/parse/parser.zig`) with the raw-text leaf bound beside it
(`atom.max_text_nesting`).

### M7 (slop). Dead/legacy public fns — **LANDED**

`parseColor` is deleted — only `parseColorChecked` remains, and it has since
moved out of `src/svg.zig` into `src/atom.zig` (`atom.parseColorChecked`), so
the parser's `\color` / `\textcolor` argument shares the CLI's name table
instead of re-listing it; its callers are now `main` (`-b`/`--bg`) and the
parser's `parseColorSpec`. `lookupAscii` (`src/layout/metrics.zig`) is wired
into `glyphAt`'s non-band path instead of being test-only. `fail()`'s
`unreachable` is now an explicit panic arm on the lexer-only kinds
(`src/parse/parser.zig`). The unused `fm` parameters are dropped from
`opTailIc` and `textEmitMark` (`src/layout/layout.zig`).

`unitsPerEm` stays public on the evidence, contrary to the original finding:
the rasterizer scales glyph outlines by it in production (`src/raster.zig`).
`ascenderEm`/`descenderEm` (`src/font.zig`) are likewise used in production —
the nominal-metrics builder in `FontContext.metrics` reads both. No accessor in
this group is dead.

### M8 (slop). Duplicated fraction comment + S1 narration remainder — **LANDED**

The repeated module headers were trimmed to their load-bearing minimum
(`src/layout/box.zig`, `src/layout/draw.zig`, `src/atom.zig`) and the
restating accessor doc on `pushNode` is gone (the declaration in
`src/atom.zig` now carries no doc comment). The last "house pattern, cf."
aside is gone from the lexer header (`src/parse/lexer.zig`), which now states
only the token-table contract. The stale "previous `Utf8View.init(...)`
fallback" narration on `firstCodepoint` was rewritten to describe the current
decode rule (`src/layout/layout.zig`). Same items as `audit.md` S1.

---

## L — low

- **DrawList ink bounds undocumented** — **LANDED**. Both bound sources and
  their difference are documented on the struct and on the accessor
  (`DrawList.bounds`, `src/layout/draw.zig`); `InkBounds` itself documents
  the non-zero-origin case. The margin problem this deferred to M5 is closed
  there, and the 2026-10-02 overhang work extended the same doc: the
  horizontal ink extent is the advance box UNIONED with the measured ink
  edges, which is the one sentence a reader of the struct needs and did not
  have before.
- **err_info out-param ceremony tripled** — **LANDED**. One `?*parse.Info`
  parameter, threaded through `renderPipeline` (`src/root.zig`).
- **Context non-copyable by doc only** — **LANDED**. Stated on `Context` and on
  `Context.deinit` (`src/context.zig`); `Ast`, `DrawList`, and `BoxList` carry
  the same rule (`src/atom.zig`, `src/layout/draw.zig`, `src/layout/box.zig`).
- **svg.render anyerror → closed set** — **LANDED**
  (`error{ OutOfMemory, NonFiniteCoordinate }`).
- **Zig 0.16.0 exact pin + zg from codeberg, no C ABI** — **LANDED**, both
  halves. The pin was already there (`minimum_zig_version = "0.16.0"` and zg
  v0.16.2 from codeberg, `build.zig.zon`) and the version contract is
  documented for hosts in `README.md`. The C ABI the round called out of scope
  now exists: a `static-lib` build step (`build.zig`) producing
  `zig-out/lib/libztex.a`, the hand-written header `include/ztex.h`, and the
  adapter `src/ztex_c.zig` with six `ztex_`-prefixed exports —
  `ztex_context_create`, `ztex_context_destroy`, `ztex_status_name`,
  `ztex_render_svg`, `ztex_render_raster`, `ztex_last_error`.
- **Embedded fonts pulled by any ztex-facade consumer** — **LANDED**, and the
  original finding was wrong on both counts. The payload is font bytes, not
  Zig source (which is ~6 bytes per font byte); and it is more faces than two.
  And a layout-only host CAN avoid them: only `src/root.zig`,
  `src/context.zig` and `src/raster.zig` import `font.zig`; `ztex.layout`
  reaches fonts through the opaque `metrics.FontHook` and links none of those
  bytes. Both facts are documented on the facade (`src/root.zig`) and in
  `README.md`.

  **Re-audit note (2026-10-02).** The face list is now FIVE, not three: LM
  Math plus LM Roman regular, italic, bold and bold-italic
  (`FontContext.init`, `src/font.zig`) — the four text faces are real faces,
  never a slanted or emboldened copy of another, and `FontContext.faceForStyle`
  resolves each style to exactly one of them. The measured payload is
  1,193,544 B (~1.14 MiB), counted as `0xNN` initializers across `src/fonts/`
  and the `lmmath/part*.zig` splits: 733,736 + 111,536 + 118,828 + 111,240 +
  118,204. The "three faces, ~0.91 MiB" figures recorded above were true of
  the 2026-10-01 tree and are kept here as that pass's measurement; they are
  now stale in `README.md` and in the `src/root.zig` module header, which is
  reported to the integration owner rather than silently edited from here.
- **No README/host-facing docs** — **LANDED**. `README.md` now carries the
  host-facing contract: the version pin, the module table and its font weight,
  the C ABI section, the command surface, the ownership/lifetime rules for
  every owning type, the allocator contract, thread safety for both facades,
  the closed error sets, and the input limits.
- **Stale "prior attempt" narration in `firstCodepoint` doc** — **LANDED**. The
  doc no longer explains what the *previous* `Utf8View.init(...) catch null`
  fallback did; it states the current decode rule directly
  (`src/layout/layout.zig`).
- **Top-level style hardcoded `.display`** — **LANDED**. Every entry point now
  takes the math style the formula starts in: `layout.render`
  (`src/layout/root.zig`), `renderPipeline` (`src/root.zig`), both facades and
  both raster entry points. The CLI exposes it as `--style display|text`
  (`src/main.zig`). Behaviour is TeX's: a text-style `\frac{1}{2}` is
  9.24 × 26.90pt at 20pt against display's 13.20 × 44.57pt, and a text-style
  `\sum` moves its limits beside the operator, going wider and shorter
  (57.78 × 29.64pt vs 42.31 × 55.16pt). Pinned by a test in `src/root.zig`.
- **`glyphEstimate` fallback 0.5/0.7/0.2em** — **LANDED**, and the original
  finding was wrong about the mechanism. `glyphImpl` already consults the font
  first (`src/layout/metrics.zig`), so the estimate only fires for a codepoint
  absent from BOTH the wired font and the static tables — for which there is no
  hmtx advance to look up and a deterministic box is the right answer. Emoji
  and CJK take this path; they are emitted with a correct span and advance and
  simply have no glyph in Latin Modern Math. The estimate is a last resort,
  not a wrong measurement.
- **Baked MATH metrics** — **LANDED**. The `OPEN by design` note is retired:
  `font.zig` parses the OpenType MATH table into a `MathData` payload (reached
  from the face during `parseOwned`) and `FontFace` exposes it as
  `mathConstants` / `mathValues` / `variants` / `assembly` (`src/font.zig`). The
  rasterizer resolves every stretchy glyph through those ladders and
  assemblies instead of a switch over 62 literal Latin Modern glyph ids
  (`src/raster.zig`; the old ids survive only as test expectations). A face
  with no MATH table answers null and degrades to the base glyph rather than
  failing.

  The `GlueParams` rows in the static tables are still baked Latin Modern
  constants, and the `.static` metric arm still answers `mathConstants(fm) ==
  null` so every baked row stands.

  **Re-audit note (2026-10-02).** The 2026-10-01 pass closed this on the
  ladders and assemblies alone and said explicitly that `mathConstants` and
  `mathValues` were "parsed and exposed but read nowhere outside tests". That
  half is no longer true. `Context` now borrows the math face's constants once
  into `FontMetrics.math_constants` (`src/context.zig`), and layout reads them
  through `metrics.mathConstants(fm)`: the `.font` arm of `metrics.glue`
  overwrites `axis_height`, the script-size factors and the baseline drops with
  the table's own values, and `metrics.accentBaseHeightEm` reads the accent
  base. Per glyph, `FontContext.metrics` folds `face.mathValues(gid)` into the
  cached `GlyphMetrics` (one cache search per (face, codepoint), scaled per
  request), and layout reads it through `metrics.fontItalicCorrection` and
  `metrics.fontTopAccentAttachment` — the accent base for a text accent and
  the script delta for a superscript. On a face with a MATH table, missing
  italic-correction coverage resolves to zero; on a face without MATH it stays
  null and permits the static fallback. Top-accent attachment remains nullable.

---

## Functionality gaps (feature roadmap, NOT defects)

Re-verified against `src/parse/parser.zig` on 2026-10-01 and again on
2026-10-02. **The roadmap is closed.** The four gaps this section left open on
2026-10-01 — `\boxed` + `\color`/`\textcolor`, `\hline`,
`\textit`/`\textbf`, and `\mathbin` — are now recognized, laid out and drawn.
Nothing here is deferred.

Landed before the 2026-10-02 wave:

- **\overset / \underset / \stackrel**
- **\underbrace / \overbrace**, each with an optional `_` / `^` annotation
- **\phantom / \hphantom / \vphantom / \smash**
- **\hspace / \kern / \mkern**, plus **\:** and **\ **
- **\dbinom / \tbinom**
- the atom-class overrides **\mathop / \mathord / \mathrel / \mathopen /
  \mathclose / \mathpunct / \mathinner**
- the colon-relation family **\coloneqq / \coloneqqs / \Coloneqq /
  \Coloneqqs / \coloneq / \Colon / \ratio**
- the big n-ary family and the big integrals **\bigodot \bigoplus \bigotimes
  \biguplus \bigsqcap \bigvee \bigwedge \bigstar \bigint \bigiint \bigiiint**

Landed in the 2026-10-02 wave, with the semantics each one actually got. The
point of listing them is that "recognized by the parser" is a much weaker claim
than "behaves like the TeX macro", and these are the behaviours a host can
observe:

- **\boxed** — LaTeX's `\fbox{\m@th$\displaystyle#1$}`: the frame goes OUTSIDE
  the content, the content keeps its baseline, and the body is set in DISPLAY
  style even when `\boxed` appears in inline math. `\fboxsep` (3pt) and
  `\fboxrule` (0.4pt) are ABSOLUTE physical dimensions, never scaled by the
  font size, so `\boxed` at 10pt and at 40pt have the same gap and frame
  (`layoutBoxed`, `fboxsep_pt`, `fboxrule_pt`, `src/layout/layout.zig`). The
  four rules are `.rule` boxes, so they take the enclosing color scope like any
  primitive: an uncolored `\boxed` paints on the host's own foreground.
- **\color / \textcolor** — `\color` is a DECLARATION. `parseRow` intercepts it
  (never `parseCommand`), so the color covers the REST of the current row and
  is restored when the row — or the group / cell / env body owning it — ends.
  `\textcolor` is an ordinary one-child group, so `a\textcolor{red}{=}b`
  measures exactly `a\mathord{=}b` while `a\color{red}=b` keeps the relation
  glue. Both carry `0xRRGGBBAA` in the node's `data` and read the name table
  through `atom.parseColorChecked`, so a typo is reported identically in the
  CLI and in a formula. `none` / `transparent` are TRANSPARENT INK, not "no
  scope": the scope exists and records `{0,0,0,0}`. An explicit black is a
  real override that beats the host foreground. Layout wraps the child in a
  transparent `.hbox` scope box and moves nothing; `flatten` resolves the
  nearest non-null ancestor, which paints rules and text alike.
- **\hline** — a `.hline` LEAF, legal ONLY at an environment row boundary: an
  entry in the `.env` node's child run, never a cell and never a row, so a
  leading, intermediate or trailing rule never fabricates an empty row and
  repeated rules stay separate entries. Every other position — top level,
  inside a group, inside a fraction, inside a cell — fails with the typed
  `error.MisplacedHline` (`Kind.misplaced_hline`, `src/parse/error.zig`), caret
  on the `\hline` itself. `layoutEnv` walks ROW entries and places each rule at
  the boundary it sits on.
- **\textit / \textbf** — a raw-text run in a REAL LM Roman face, not math
  italic: the parser keeps the whole argument as ONE `.text` leaf spanning the
  outer braces (the layout text renderer re-reads the bytes from that span), so
  `\textbf{a\textit{b}c}` and `\textit{\textbf{ab}}` are the same single leaf
  and differ only in the face scopes layout opens inside it. Nesting COMBINES
  (`atom.combineTextStyles`) rather than overwrites, so both nests are bold
  italic and the outer face is restored when the inner run ends. A space
  inside a run takes that run's own face. The balanced scan is depth-bounded by
  `atom.max_text_nesting`, which fails at the opening brace.
- **\mathbin** — joins the atom-class override family and classifies as a bin.

---

## Consumer-facing defects found during the 2026-10-02 wave

These are NEW findings, not restatements of anything above. Most were found by
rendering into a real consumer rather than by reading, which is why none of the
earlier passes saw them: nothing in the source was wrong on its own terms.

1. **SVG double conversion (H, correctness) — FIXED.** `svg.render` wrote
   `pt` on the inner `<text x=… font-size=…>` coordinates as well as on the
   root `width`/`height`. The root already declares the physical size and a
   `viewBox` whose user unit IS one point, so a second `pt` on an inner
   coordinate is a second 96/72 conversion: the content came out 4/3 too
   large and was visibly clipped. The root keeps `width`/`height` in `pt`; the
   `viewBox` and every inner coordinate, `font-size` and `stroke-width` are
   unitless (`src/svg.zig`, `render`).
2. **Synthesized slant on math italic (M, rendering) — FIXED.** Math runs
   declared `font-style="italic"`, but LM Math's math-italic glyphs are
   ALREADY italic, so a browser synthesized a second slant on top of them.
   `.italic` now emits `font-style="normal"`; `.text_italic` and
   `.bold_italic` keep `italic`, because those styles are the upright family
   that needs a real slant (`fontSpec`, `src/svg.zig`).
3. **\stackrel stacked UNDER (H, correctness) — FIXED.** The `\overset` /
   `\underset` / `\stackrel` row node tags itself with a distinct `data`
   marker per direction (`overset_row_data`, `underset_row_data`,
   `stackrel_row_data`, `src/layout/layout.zig`). The layout arm tested
   `n.data != overset_row_data`, which is true for `\stackrel` as well as for
   `\underset`, so `\stackrel` was stacked below its base instead of above. It
   now tests `n.data == underset_row_data`, naming only `\underset`.
4. **Wrong codepoints for \bigiint / \bigiiint (H, correctness) — FIXED.**
   `\bigiint` and `\bigiiint` are the ORDINARY double and triple integral
   (U+222C / U+222D); the tree was drawing the CONTOUR integral pair
   (U+222F / U+2230), which the enum and the parser already name as
   `\oiint` / `\oiiint`. U+222C and U+222D share an identical advance and
   bounding box with the pair they replaced, so NO metric number changes —
   only the drawn contour was wrong (`src/layout/layout.zig`).
5. **A colored array cell lost its trailing italic correction (H,
   correctness) — FIXED.** `Q.x` in an array cell measured 21.6pt plain
   and 19.8pt with a color scope on the cell, at 20pt. `cellTrailingIc`
   (`src/layout/layout.zig`) walks to the cell's last atom to read the MATH
   italic correction XeTeX appends after it, and that walk did not descend
   through a `.color` / `.textcolor` wrapper, so a colored cell's last
   character was invisible to the `\halign` column width and the column lost
   the correction. The invariant is in that walk: reaching the cell's last
   atom must traverse every transparent wrapper — `.group`, `.styled`,
   `.mathstyle`, `.color`, `.textcolor` — and follow a `.row` / `.script` to
   its LAST child, exactly as an uncolored cell does. A colored column has to
   measure like a plain one. The CLI now places `Q` at 21.6pt in all three
   cases: plain, `\color{red}f` and `\textcolor{red}{f}`.
6. **Cell-local stretch leaked into a LATER SIBLING environment (H,
   correctness) — FIXED.** Two sibling environments that should sit on a
   24pt pitch measured 48pt: the SECOND matrix was sized as if the FIRST one's
   stretch still applied. The parser now separates the factor from whether
   the current cell assigned it. Each cell, group, delimiter pair and nested
   environment saves and restores that state. Only an explicit first-row cell
   assignment changes the current environment's row factor; plain cells cannot
   overwrite it and nested bodies cannot claim an enclosing assignment.
   The CLI now measures the second sibling matrix's row pitch at 24pt after a
   cell-local factor of 2 in the first matrix. This is independent of column
   spacing or `\arraycolsep`.
7. **CFF approximation escaped the ink bounds (H, correctness) — FIXED.**
   The two-quadratic fit in `CffInterp.appendCubic` could leave the original
   cubic's bounds. For U+1D453 its apex reached 705.115 units instead of 705:
   at 60pt and 720dpi, six antialiased pixels appeared above the zero-padding
   frame. The fitter now splits at both coordinate extrema and constrains
   each monotonic quadratic's control to its endpoint interval. The original
   extrema remain endpoints; the approximation cannot paint beyond them.
   The real-outline regression failed before this fix and passes afterward.
8. **Wide tilde exceeded its accent band (H, correctness) — FIXED.**
   The old `t / turn` overlap grew toward half a chord as consecutive chords
   became collinear. A 22pt-wide wave painted 4.057pt in a 3.84pt band.
   `wideAccentStroke` now uses `half * tan(turn / 2)` and fits the joined
   stroke's reach, not just its centreline, inside the band. Its first
   extremum is the crest, followed by the trough.
9. **Hostile render arguments could wrap or trap (H, contract) — FIXED.**
   SVG refuses negative padding with `InvalidArgument`; raster validates
   positive finite DPI/scale, finite ink bounds and checked frame/stride/byte
   arithmetic before pixel allocation. The C ABI maps these to its existing
   statuses and preserves all output parameters on failure. An actual C89
   probe returned status 1 for SVG padding -1000 and status 7 for raster
   padding 2147483648; length, width and height sentinels stayed 123.

Items 5 and 6 are independent scope walks — one in the layout column-width
path, one in the parser's environment-body state — not one shared bug.

Observed effect of (1) on a `\boxed` formula measured in a browser: 25.07 wide
against the old 33.4267.

### Final integrated verification

- `zig build install static-lib docs test --summary all -j2`: **64/64 steps
  passed; 422/422 tests passed**. Roots: atom 16, parse 131, layout 111, svg 9,
  ztex 87, tests 53 and c 15.
- `bash scripts/gate.sh --cov`: **passed**. Required zwanzig analyzed 43 files
  with 21 rules and reported no issues. fmt, build, tests, ast-check and zlint
  passed; zbc ran as advisory rather than being skipped.
- Coverage: **54.2% lines (7257/13390)** and **42.5% exact blocks
  (8731/20522)**. These totals include tests; they are not a production-only
  measurement. No branch counters were recorded.
- Static-library and API-doc builds passed in the integrated build above.
  GCC C89 consumer and G++ C++17 header checks passed. The consumer exercised
  all six exports, counted non-NUL input, SVG/RGBA/alpha8, scoped paint, spans,
  exact buffer sizing and OOM recovery, with **325 matched allocations**.
- GNU ld initially warned about the archive's missing `.note.GNU-stack`,
  and `readelf` confirmed an RWE stack. Linking with `-Wl,-z,noexecstack`
  removed the warning and produced an RW stack; the same consumer still passed.
  This required GNU ld link flag is documented in README and AGENTS.
- Actual CLI output: **60 formulas × SVG/PGM/PPM = 180 successful renders**.
  Seven family sheets were visually inspected. Chromium inspected all 60 SVGs
  with the five exact embedded faces loaded: frames, scoped color, text faces,
  rules/rows/tags, accents, limits/braces, spacing/visibility and big operators.
- **16 padded-versus-zero-padding raster probes passed**, including large
  integrals at 1200dpi and italic/text overhangs, smash, accents and tall glyphs
  at 720dpi. No ink appeared outside the unpadded frame; core differences were
  at most one gray level. No padding workaround was added.
- `ruff check scripts/embed_font.py` passed. The generator's exact embedded-font
  reader was exercised; an independent review reproduced all 5178 ink rows and
  the three 366-row styled metric tables from those bytes.

zbc remains advisory. Its gate wrapper counts only `error(` lines and truncates
the displayed diagnostics, so "6 potential issues" is not a total. An untruncated
JSON run over the same 43 project files returned **97 diagnostics: 5 errors
and 92 warnings**. The four error-severity slices are `MathAssembly.part`'s
offsets 2/4/6/8: its `i < parts.len / 10` precondition guarantees a complete
10-byte record. The fifth is parser recursion, guarded by `max_nesting`.
The numeric/index warnings are not suppressed or claimed collectively solved.
The Q8.8 clamp, 16-bit inverse mask and child-count guard are in source; all
node-pool append paths now enforce their u32 capacity through
`checkNodeCapacity`, with a failing-before/passing-after allocation-boundary
regression. zbc does not prove those helper preconditions.

Known rendering limit remains unchanged: SVG carries MATH variants as hints
and paints base cmap glyphs in a plain browser; raster resolves the variant
ladders and assemblies. This wave does not claim equal SVG/raster outlines
for stretched glyphs.

---

## Triage queue — status as of 2026-10-02

1. **F1 parse/atom** — C1 depth guard **LANDED**, H2 source bound and checked
   node-index capacity **LANDED**,
   parser `fail()` unreachable **LANDED**, slop IDs **LANDED**.
2. **F2 facade/context/main/font** — M1 **LANDED**, M2 **LANDED**,
   H4 **LANDED**, FontFace getters **LANDED** (all three are used in
   production), H1 thread-safety doc **LANDED**, slop IDs in these
   files **LANDED**.
3. **F3 svg** — M4 **LANDED**, closed error sets **LANDED**, M7 `parseColor`
   delete **LANDED**; the `main.zig` call site carries the `std.Io.Dir`
   explicitly.
4. **F4 layout/atom** — C2 tree validation **LANDED**, M3 error-set narrow
   **LANDED**, M7 `lookupAscii` wire **LANDED**, M8 comment trim **LANDED**,
   M6 magic drift **LANDED**, M5 ink bounds **LANDED**.
5. **Wave defects 1-4** (SVG double `pt`, synthesized math-italic slant,
   `\stackrel` direction, `\bigiint`/`\bigiiint` codepoints) — **FIXED**.
6. **Wave defect 5** — colored array cell loses its trailing italic
   correction (`cellTrailingIc` wrapper traversal) — **FIXED**, CLI measured.
7. **Wave defect 6** — cell-local stretch leaks into a later sibling
   environment (parser cell/environment state restoration) — **FIXED**, CLI
   measured. Independent of item 6 above.
8. **Wave defects 7-9** — CFF ink enclosure, wide-tilde band and hostile
   render arguments — **FIXED**, regressions and actual CLI/C probes passed.

Deferred and still deferred from the original round: nothing. The remainder of
the feature roadmap above closed in the 2026-10-02 wave; the other two items
this pass deferred had already closed — the top-level style parameter is the
`style` argument on every entry point, and the C ABI is the `static-lib` step
described under the low findings. Final integrated verification is complete;
the advisory and rendering limits above are not hidden by that result.

The baked Latin Modern glue rows remain, but only for the `.static` arm: the
`.font` arm overwrites `axis_height`, the script-size factors and the baseline
drops from the face's own MATH constants, the per-glyph italic correction and
top accent attachment come from the face's MATH values, and the rasterizer
reads variant ladders and assemblies from that same table at draw time.