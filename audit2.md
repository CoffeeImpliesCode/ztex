# ztex — Adversarial Audit Round 2

- **Original pass**: 2026-08-16, five read-only lenses (API complexity,
  functionality gaps, generality/embeddability, magic numbers, AI-slop
  markers).
- **Status pass**: 2026-10-01. Every finding below was re-checked against the
  current tree; the original line numbers were discarded. The five per-lens
  note files this round was assembled from are not part of the repository —
  the findings they produced are reproduced inline below and nowhere else.
- **Scope**: the same tree as `audit.md`, plus `src/raster.zig` and
  `build.zig.zon`.
- **Method**: static reading only; nothing here was runtime-verified.

## Status legend

- **LANDED** — fixed in the current source. The line states where it now lives.
- **OPEN** — still present. The line carries the current `file:line`.

A finding that is only half addressed is marked **OPEN** with the landed half
named in the note, so the queue never overstates progress.

## Severity legend

**C** = soundness/remote-crash, **H** = correctness/contract,
**M** = design/cleanup, **L** = docs/minor.

---

## C — critical

### C1. No recursion-depth limit → stack overflow on untrusted input — **LANDED**

The parser now carries a depth counter and fails with
`error.NestingTooDeep`: error member at `src/parse/parser.zig:35`, counter at
`src/parse/parser.zig:692`, guard at `src/parse/parser.zig:847`. The `Kind`
carries it end to end (`src/parse/error.zig:34`), and both the trip case and
the exact boundary are pinned (`src/parse/root.zig:269`,
`src/parse/root.zig:289`).

The layout half — recursion over hand-built ASTs — is covered by the
iterative boundary validator, which walks a worklist instead of recursing
(`src/layout/root.zig:85`), so a pathological tree cannot overflow the
validator's own stack either.

### C2. `Ast.child` @panic + BoxList asserts on the documented hand-built-AST path — **LANDED**

`layout.render` validates the root-reachable subtree once, before touching
the box pool: child counts against each tag's arity, child indices in bounds,
and a tree-shaped reachable graph (`src/layout/root.zig:85`, called at
`src/layout/root.zig:35`). A malformed hand-built tree now returns
`error.InvalidAst` (`src/layout/root.zig:34`); the `Ast.child` @panic
(`src/atom.zig:485`) and the `BoxList` asserts (`src/layout/box.zig:166`)
stay as internal invariant checks that a validated tree never trips.

---

## H — high

### H1. Context is not thread-safe; undocumented — **LANDED**

The module header states the rule and both remedies — one Context per thread,
or an external mutex — and names the static facade as the shareable path
(`src/context.zig:10`). The header also explains the heap allocation
(`src/context.zig:17`) and why `render` is not a const operation
(`src/context.zig:114`).

### H2. `max_source_bytes` under-guards the ~2× node pool — **LANDED**

The bound is halved to `maxInt(u32)/2` with the node-pool reasoning spelled
out (`src/parse/root.zig:28-37`), and the boundary is unit-tested without a
multi-GiB allocation (`src/parse/root.zig:85`).

### H3 (slop). Audit-issue IDs leaked into source comments — **LANDED**

Every `(C1)`-style parenthetical is gone: a search for the pattern across
`src/` returns nothing. The sites that carried them — the parser's depth
field (`src/parse/parser.zig:692`), its `fail()` lexer-only arm
(`src/parse/parser.zig:757`), the nesting guard
(`src/parse/parser.zig:847`), and the `lookupAscii` fast-path test
(`src/layout/metrics.zig:3342`) — now read without the label and keep their
explanations.

### H4 (slop). Dead pub re-exports — **LANDED**

All four are gone. `ztex.layout` now re-exports only `metrics`, `draw`, and
`layout` (`src/layout/root.zig:9-11`) — `Style` and `box` are gone. `ztex`
imports `context.zig` privately (`src/root.zig:20`) and publishes only
`Context` (`src/root.zig:24`), so the old `pub const Style` and
`pub const context` are both removed.

---

## M — medium

### M1. Duplicated facade plumbing — **LANDED**

One private helper, `renderPipeline` (`src/root.zig:36`). Both facades are
thin wrappers over it (`src/root.zig:51`, `src/context.zig:117`); the
`err_info` out-param and the error mapping are threaded exactly once.

### M2. Redundant `gpa` param on `Context.render` — **LANDED**

The parameter is gone; the facade allocates with `self.gpa`
(`src/context.zig:117`).

### M3. `catch error.OutOfMemory` swallows future non-OOM layout errors — **LANDED**

`layout.render` has a closed set,
`error{ OutOfMemory, InvalidAst }` (`src/layout/root.zig:34`), and the
facade lets both propagate unmapped instead of catching
(`src/root.zig:33`). `main` then matches exactly those two by name and
treats everything else as a parse error (`src/main.zig:122-135`).

### M4. `svg.writeFile` hardcodes cwd; fs in the library module — **LANDED**

`writeFile` takes an explicit `std.Io.Dir` (`src/svg.zig:222`); `render`
stays pure (`src/svg.zig:54`). The CLI passes `std.Io.Dir.cwd()` explicitly
(`src/main.zig:162`).

### M5. No exact ink-bounds API; heuristic svg margins — **LANDED**

`DrawList.bounds()` now returns a named `InkBounds`
(`src/layout/draw.zig:130`) carrying `min_x`/`min_y` alongside the span, and
both consumers frame from it. `svg.render` builds the viewBox, the baseline
offset, and every primitive shift from the ink bbox
(`src/svg.zig:66`), offsetting by the ink ORIGIN rather than assuming it is
zero — a fraction's first ink is its numerator inset by TeX's nulldelimiterspace,
so `min_x` is positive there. `raster.rasterize` uses the same basis with a
private `Origin` (`src/raster.zig:146`), so SVG and raster agree on the content
extent.

The heuristic vertical margin is gone: vertical ink extents are exact (a char
box's h/d IS the drawn glyph's ink), so the ink top now lands on the frame
edge. Two terms survive with stated reasons — horizontal advance-box slack,
because the accumulated ink's horizontal extent is the glyph ADVANCE rather
than the true ink edge, and the browser lineGap below the baseline, because
bounding only the glyph ink clips the bottom in a browser. Measured effect at
20pt: frames are 3.2pt (= 2 × 0.08em) shorter, and 2 of the 5 regression
formulas also tightened horizontally where the box over-bound.

### M6. Magic-number drift: same constant in two+ places — **LANDED**

Every constant this finding named now has exactly one source:

- baseline drops: `GlueParams.supdrop`/`subdrop`
  (`src/layout/metrics.zig:2918`), consumed through `gl` at
  `src/layout/layout.zig:3106`;
- script-size factors: `src/layout/metrics.zig:2925`, consumed through `gl`
  (`src/layout/layout.zig:522`) — no re-literal of 0.7/0.5 anywhere;
- `axis_height`: read from `gl` at every use
  (`src/layout/layout.zig:1025`, `src/layout/layout.zig:1831`,
  `src/layout/layout.zig:2232`);
- big-operator advances/ics: the table moved into the metrics module as the
  single source (`src/layout/metrics.zig:1944`,
  `src/layout/metrics.zig:1961`), consumed at
  `src/layout/layout.zig:2914`;
- the 2.392em (parenleft.v6) constant: the ink ladder
  (`src/layout/layout.zig:48`) is now aliased once as
  `ams_delim_req_em` (`src/layout/layout.zig:55`) and read through that
  alias by `binomDelimReqEm` (`src/layout/layout.zig:2212`).

### M7 (slop). Dead/legacy public fns — **LANDED**

`parseColor` is deleted — only `parseColorChecked` remains
(`src/svg.zig:231`), and `main` is its only caller
(`src/main.zig:94`). `lookupAscii` is wired into `glyphAt`'s non-band path
(`src/layout/metrics.zig:2147`, `src/layout/metrics.zig:2156`) instead of
being test-only. `fail()`'s `unreachable` is now an explicit panic arm on
the lexer-only kinds (`src/parse/parser.zig:735`,
`src/parse/parser.zig:757`). The unused `fm` parameters are dropped from
`opTailIc` (`src/layout/layout.zig:2899`) and `textEmitMark`
(`src/layout/layout.zig:4370`).

`unitsPerEm` stays public on the evidence, contrary to the original finding:
the rasterizer scales glyph outlines by it in production
(`src/raster.zig:390`). `ascenderEm`/`descenderEm` are likewise used in
production (`src/font.zig:1904`). No accessor in this group is dead.

### M8 (slop). Duplicated fraction comment + S1 narration remainder — **LANDED**

The repeated module headers were trimmed to their load-bearing minimum
(`src/layout/box.zig:1`, `src/layout/draw.zig:1-2`, `src/atom.zig:1-7`) and
the restating accessor doc on `pushNode` is gone
(`src/atom.zig:424`). The last "house pattern, cf." aside is gone from the
lexer header (`src/parse/lexer.zig:1-6`), which now states only the token-table
contract. The stale "previous `Utf8View.init(...)` fallback" narration on
`firstCodepoint` was rewritten to describe the current decode rule
(`src/layout/layout.zig:528`). Same items as `audit.md` S1.

---

## L — low

- **DrawList ink bounds undocumented** — **LANDED**. Both bound sources and
  their difference are documented on the struct (`src/layout/draw.zig:109`)
  and on the accessor (`src/layout/draw.zig:185`); `InkBounds` itself
  documents the non-zero-origin case (`src/layout/draw.zig:124`). The margin
  problem this deferred to M5 is closed there.
- **err_info out-param ceremony tripled** — **LANDED**. One `?*parse.Info`
  parameter, threaded through `renderPipeline` (`src/root.zig:36`).
- **Context non-copyable by doc only** — **LANDED**. Stated at
  `src/context.zig:17` and on `deinit` (`src/context.zig:98`); `Ast`,
  `DrawList`, and `BoxList` carry the same rule (`src/atom.zig:390`,
  `src/layout/draw.zig:104`, `src/layout/box.zig:138`).
- **svg.render anyerror → closed set** — **LANDED**
  (`src/svg.zig:58`, `error{ OutOfMemory, NonFiniteCoordinate }`).
- **Zig 0.16.0 exact pin + zg from codeberg, no C ABI** — **LANDED** (the
  contract half). The pin was already there (`build.zig.zon:5`, `minimum_zig_version
  = "0.16.0"`; zg v0.16.2 from codeberg, `build.zig.zon:8`); the version contract
  is now documented for hosts in `README.md`, including the no-C-ABI fact. The
  optional `addStaticLibrary` + C header for non-Zig hosts remains out of scope:
  it is an API addition, not a defect.
- **Embedded fonts pulled by any ztex-facade consumer** — **LANDED**, and the
  original finding was wrong on both counts. The payload is ~0.9 MiB of font
  bytes (964,100 B measured by counting the `0xNN` entries across
  `src/fonts/`), not 2.1 MB — that figure counted Zig source, which is ~6 bytes
  per font byte. And a layout-only host CAN avoid them: only `src/root.zig` and
  `src/context.zig` import `font.zig`; `ztex.layout` reaches fonts through the
  opaque `metrics.FontHook` and links none of those bytes. Both facts are now
  documented on the facade (`src/root.zig:7-12`) and in `README.md`.
- **No README/host-facing docs** — **LANDED**. `README.md` now carries the
  host-facing contract: the version pin, the module table and its font weight,
  the ownership/lifetime rules for every owning type, the allocator contract,
  thread safety for both facades, the closed error sets, and the input limits.
- **Stale "prior attempt" narration in `firstCodepoint` doc** — **LANDED**. The
  doc no longer explains what the *previous* `Utf8View.init(...) catch null`
  fallback did; it states the current decode rule directly
  (`src/layout/layout.zig:528-531`).
- **Top-level style hardcoded `.display`** — **LANDED**. Every entry point now
  takes the math style the formula starts in: `layout.render`
  (`src/layout/root.zig:35`), `renderPipeline` (`src/root.zig:42`), both
  facades and both raster entry points. The CLI exposes it as
  `--style display|text` (`src/main.zig:90`). Behaviour is TeX's: a text-style
  `\frac{1}{2}` is 9.24 × 26.90pt at 20pt against display's 13.20 × 44.57pt,
  and a text-style `\sum` moves its limits beside the operator, going wider and
  shorter (57.78 × 29.64pt vs 42.31 × 55.16pt). Pinned by a test at
  `src/root.zig`.
- **`glyphEstimate` fallback 0.5/0.7/0.2em** — **LANDED**, and the original
  finding was wrong about the mechanism. `glyphImpl` already consults the font
  first (`src/layout/metrics.zig`), so the estimate only fires for a codepoint
  absent from BOTH the wired font and the static tables — for which there is no
  hmtx advance to look up and a deterministic box is the right answer. Emoji
  and CJK take this path; they are emitted with a correct span and advance and
  simply have no glyph in Latin Modern Math. The estimate is a last resort,
  not a wrong measurement.
- **Baked MATH metrics** — **OPEN** by design. `GlueParams` plus thousands of
  per-glyph values are Latin Modern measured once; a runtime MATH-table query
  through `font.zig` remains the eventual fix, and the `.font` arm already
  exists (`src/layout/metrics.zig:120`).

---

## Functionality gaps (feature roadmap, NOT defects)

Re-verified against the parser on 2026-10-01: **none** of the following
command names is recognized, so the original top-5 ordering still holds.
Top-5 by value: **\overset/\underset/\stackrel**,
**\phantom/\hphantom/\vphantom/\smash**, **\hspace/\kern/\mkern + \:/\ /**,
**\underbrace/\overbrace**, **\boxed + \color/\textcolor**. Then \dbinom/
\tbinom, \hline/\arraystretch, \tag, atom-class overrides, \coloneqq family,
\bigoplus/\iint families, \widehat/\widetilde, stretchy accents, colon
relations, \textit/\textbf family, \mathop..\mathinner.

---

## Triage queue — status as of 2026-10-01

1. **F1 parse** — C1 depth guard **LANDED**, H2 node-pool cap **LANDED**,
   parser `fail()` unreachable **LANDED**, slop IDs **LANDED**.
2. **F2 facade/context/main/font** — M1 **LANDED**, M2 **LANDED**,
   H4 **LANDED**, FontFace getters **LANDED** (all three are used in
   production), H1 thread-safety doc **LANDED**, slop IDs in these
   files **LANDED**.
3. **F3 svg** — M4 **LANDED**, closed error sets **LANDED**, M7 `parseColor`
   delete **LANDED**; the `main.zig` call site carries the `std.Io.Dir`
   explicitly (`src/main.zig:162`).
4. **F4 layout/atom** — C2 tree validation **LANDED**, M3 error-set narrow
   **LANDED**, M7 `lookupAscii` wire **LANDED**, M8 comment trim **LANDED**
   (`src/parse/lexer.zig:1-6`, `src/layout/layout.zig:528`), M6 magic drift
   **LANDED** (`src/layout/metrics.zig:2918`, `src/layout/layout.zig:55`),
   M5 ink bounds **LANDED** (`src/layout/draw.zig:130`, `src/svg.zig:66`,
   `src/raster.zig:146`).

Deferred and still deferred: the feature roadmap above, the runtime MATH-table
query, and the C ABI. Of the items this pass left open, the top-level style
parameter and the `glyphEstimate` entry have since closed — the first is now
the `style` argument on every entry point, the second was closed as
not-a-defect on re-check. One stays open by design: the baked Latin Modern
tables behind the `.font` arm, an architectural change rather than a repair.