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

`writeFile` takes an explicit `std.Io.Dir` (`src/svg.zig:194`); `render`
stays pure (`src/svg.zig:54`). The CLI passes `std.Io.Dir.cwd()` explicitly
(`src/main.zig:162`).

### M5. No exact ink-bounds API; heuristic svg margins — **OPEN** (half landed)

The API landed: `flatten` accumulates an ink bbox
(`src/layout/draw.zig:134`) exposed through `DrawList.bounds()`
(`src/layout/draw.zig:160`, `src/layout/draw.zig:166`), and the struct doc
distinguishes the box bounds from the ink bounds
(`src/layout/draw.zig:109`).

The payoff did not: `svg.render` still builds its viewBox from the box
bounds plus a heuristic `0.08 × max_size` margin and a `0.2em` lineGap
(`src/svg.zig:62`) and never calls `bounds()`.

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

### M8 (slop). Duplicated fraction comment + S1 narration remainder — **OPEN**

The repeated module headers were trimmed to their load-bearing minimum
(`src/layout/box.zig:1`, `src/layout/draw.zig:1-2`, `src/atom.zig:1-7`) and
the restating accessor doc on `pushNode` is gone
(`src/atom.zig:424`). The house-pattern boilerplate this finding named
survives in exactly one place: the "house pattern, cf." aside
(`src/parse/lexer.zig:4`). Same open item as `audit.md` S1.

---

## L — low

- **DrawList ink bounds undocumented** — **LANDED**. Both bound sources and
  their difference are documented on the struct (`src/layout/draw.zig:109`)
  and on the accessor (`src/layout/draw.zig:160`). The remaining
  heuristic-margin problem is tracked by M5.
- **err_info out-param ceremony tripled** — **LANDED**. One `?*parse.Info`
  parameter, threaded through `renderPipeline` (`src/root.zig:36`).
- **Context non-copyable by doc only** — **LANDED**. Stated at
  `src/context.zig:17` and on `deinit` (`src/context.zig:98`); `Ast`,
  `DrawList`, and `BoxList` carry the same rule (`src/atom.zig:390`,
  `src/layout/draw.zig:104`, `src/layout/box.zig:138`).
- **svg.render anyerror → closed set** — **LANDED**
  (`src/svg.zig:58`, `error{ OutOfMemory, NonFiniteCoordinate }`).
- **Zig 0.16.0 exact pin + zg from codeberg, no C ABI** — **OPEN**. The pin
  landed (`minimum_zig_version = "0.16.0"`, `build.zig.zon:5`; zg v0.16.2
  from codeberg, `build.zig.zon:8`). The version-contract documentation, the
  optional `addStaticLibrary` + C header for non-Zig hosts, and vendoring zg
  for offline use did not.
- **~2.1 MB embedded fonts pulled by any ztex-facade consumer** — **OPEN**.
  Still undocumented which module pulls them; a layout-only host cannot avoid
  the facade import.
- **No README/host-facing docs** — **OPEN**. No README in the tree; the
  allocator, thread-safety, lifetime, and error contracts exist only as
  per-module doc comments.
- **Stale "prior attempt" narration in `firstCodepoint` doc** — **OPEN**. The
  doc still explains what the *previous* `Utf8View.init(...) catch null`
  fallback did (`src/layout/layout.zig:527`).
- **Top-level style hardcoded `.display`** — **OPEN**. `layout.render` still
  starts at display style with no style parameter
  (`src/layout/root.zig:49`); hosts cannot pick text style for a whole
  formula. Recommended API addition, still recommended.
- **`glyphEstimate` fallback 0.5/0.7/0.2em** — **OPEN**. Still the only
  deliberately-wrong value in the render path
  (`src/layout/metrics.zig:2875`); it needs an hmtx advance lookup when the
  `.font` arm is active.
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
   **LANDED**, M7 `lookupAscii` wire **LANDED**, M8 comment trim **OPEN**
   (`src/parse/lexer.zig:4`), M6 magic drift **LANDED**
   (`src/layout/metrics.zig:2918`, `src/layout/layout.zig:55`), M5 ink-bounds
   API **OPEN** (API landed, svg margins still heuristic,
   `src/svg.zig:62`).

Deferred and still deferred: the feature roadmap above, the runtime MATH-table
query, the C ABI, and a README.