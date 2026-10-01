# ztex API — Adversarial Review (round 1)

- **Original pass**: undated static reading of the public API surface, before
  round 2 (`audit2.md`, 2026-08-16).
- **Status pass**: 2026-10-01, re-opened twice the same day after each
  drifted citation was corrected; no finding changed status.
- **Re-audit**: 2026-10-02, after the feature wave that closed the round-2
  roadmap (`\boxed`, `\color`/`\textcolor`, `\hline`, `\textit`/`\textbf`,
  `\mathbin`), added the LM Roman italic and bold-italic faces (five embedded
  faces now), moved the real ink overhang into the ink bounds, wired the MATH
  constants and per-glyph values into layout, and fixed the SVG-unit,
  synthetic-italic, stack-rel and big-integral-codepoint defects. No finding
  below changed status. Two further defects — a colored array cell losing its
  trailing italic correction, and `pending_stretch` leaking into a later
  sibling environment — are accepted but NOT closed here; `audit2.md` records
  each with its own invariant.
  Citations are now `path` + symbol rather than `path:line`: the line numbers
  had drifted twice, and a symbol survives the next edit that moves code.
- **Scope**: the public API surface — `src/root.zig`, `src/context.zig`,
  `src/atom.zig`, `src/parse/` (root, lexer, parser, error),
  `src/layout/` (root, box, draw, layout, metrics, ink_metrics), `src/svg.zig`,
  `src/font.zig`, `src/main.zig`.
- **Method**: static reading only. Findings were never runtime-verified;
  anything not directly evidenced was marked `[INFERENCE]` at the time.

## Status legend

- **LANDED** — fixed in the current source. The line names where it lives now,
  by symbol.
- **OPEN** — still present. The line names the construct by symbol.

A finding that is only half addressed is marked **OPEN** with the landed half
named in the note, so the queue never overstates progress.

## Severity legend

**C** = soundness/UB/memory-safety, **H** = correctness or silent
misbehavior, **M** = design/footgun, **L** = docs/minor.

---

## C1. `Context.render` mutates shared state through a `*const` receiver

**Status: LANDED.** `Context.render` takes `*Context` (`src/context.zig`,
`Context.render`) and says why in its doc comment. The root cause is gone too:
`FontMetrics` is a closed union (`src/layout/metrics.zig`, `FontMetrics`)
instead of four hand-installed fn pointers behind a `?*anyopaque`, so there is
no const receiver left to lie about. The one remaining cast is the deliberate
`.font`-arm unwrap in `contextGlyph` (`src/context.zig`), whose non-const
`*FontContext` is documented as cache-mutating.

---

## C2. `loadFont` / `--font` is inert — no effect on metrics or output

**Status: LANDED** (the second remedy the finding offered: removal).
`Context` exposes only `init` / `deinit` / `render` / `renderPixels`
(`src/context.zig`); there is no `loadFont`, and the CLI usage text
(`src/main.zig`, the `usage` constant) has no `--font`.

---

## C3. `fracThicknessBits` panics/UB on large `\genfrac` thickness

**Status: LANDED.** `fracThicknessBits` (`src/atom.zig`) clamps into the Q8.8
range *before* the float→int conversion. The `emToFixed` twin the finding
warned about no longer performs a conversion at all (see S2/SIM3).

---

## C4. `u32` byte-offset truncation / `@intCast` panic on >4 GiB source

**Status: LANDED.** `parse` rejects oversized input up front with
`error.SourceTooLarge` (`src/parse/root.zig`: `Error`, `max_source_bytes`,
`sourceTooLong`, enforced in `parse`), with the node-pool rationale documented
on the bound and the boundary unit-tested by the `sourceTooLong` test in the
same file.

---

## H1. Two parallel full pipelines, near-identical names, different metric sources

**Status: LANDED.** One pipeline, one explicit metric source:
`renderPipeline` (`src/root.zig`). `ztex.render` is a one-line wrapper over it
with `&layout.metrics.default`; `Context.render` delegates to the same helper
with its `.font` arm (`src/context.zig`). The duplicated layout body is gone.

The helper is `pub` — `src/context.zig` calls it through a relative
`@import("root.zig")`, so a private file-level fn would not be reachable from
the other file. It is still internal: its doc comment says so, and
`ztex.render` / `Context.render` remain the public entry points. Being `pub`
inside the `ztex` module is not the same as being host API; the C header and
`README.md` never mention it.

---

## H2. Parse-error set is erased at the facade, then hardcoded in `main`

**Status: LANDED.** Both facades return the typed set
`parse.Error || error{InvalidAst}` (`ztex.render` and `Context.render`), and
`main` matches it without re-enumerating the names (`src/main.zig`, `main`).

---

## H3. Color parse failures silently produce a transparent background

**Status: LANDED.** `parseColorChecked` returns `null` only for the valid
`none`/`transparent` and `error.UnrecognizedColor` for anything else. It now
lives in `src/atom.zig` (`atom.parseColorChecked`), not `src/svg.zig`: the
parser needs the same eleven names and hex forms for `\color`/`\textcolor`, so
the one table is shared and a typo is reported identically in the CLI and in a
formula. `main` (`-b`/`--bg`) turns the error into a message and a failing exit.

---

## M1. `null_node`/`null_child` sentinel `0` collides with a real index

**Status: LANDED** (the finding's "at minimum" remedy: document + check
every read, not reserve index 0). `0` is still a valid index, but the
invariant is now stated on `Node.first_child` / `Node.num_children`
(`src/atom.zig`) and on `Box.first_child` / `Box.num_children`
(`src/layout/box.zig`), `Ast.child` panics instead of reading across the run,
and the layout boundary validates the whole root-reachable subtree before use
(`src/layout/root.zig`: `validateAst`, called at the top of `render`).

---

## M2. `Ast.child`, `Ast.node`, `BoxList.get` are unchecked; `child` reads across runs

**Status: LANDED.** All three are guarded. `Ast.node` carries a bounds assert
(`src/atom.zig`) — compiled out of ReleaseFast, where the check would sit on
the hottest accessor in layout, and measured to leave the benchmark unchanged.
`Ast.child` panics on an out-of-range index, and `BoxList.get` asserts
(`src/layout/box.zig`). The layout-boundary validator still rejects a
malformed tree before layout runs, so the assert is a backstop for hand-built
ASTs rather than the primary guard.

---

## M3. `BoxList.children` returns a live slice that `create` invalidates

**Status: LANDED.** The invalidation contract is documented on the accessor
(`BoxList.children`, `src/layout/box.zig`): the slice aliases `childrefs`
storage and any `create`/`createLeaf` may realloc it.

---

## M4. By-value structs with hidden ownership → double-free on copy

**Status: LANDED.** Every owning struct now carries the "do not copy" rule:
`DrawList` (`src/layout/draw.zig`), `Ast` (`src/atom.zig`), `BoxList`
(`src/layout/box.zig`), `Context` (`src/context.zig`), restated on
`Context.deinit`.

---

## M5. `Text.bytes` has two ownership domains with no discriminator

**Status: LANDED.** `Text.synthetic` is the discriminator (`src/layout/draw.zig`),
documented against the field and carried from the box in `flatten`.

---

## L1. "Exact node-pool bound" comment is false

**Status: LANDED.** The comment now states the reserve is a heuristic, not a
bound, and says the pool grows on demand (the node-pool reserve note in
`src/parse/root.zig`).

---

## L2. Byte-based line/column misaligns the caret on multi-byte input

**Status: LANDED.** `countCodepoints` and a codepoint column in `lineCol`
(`src/parse/error.zig`); `main` measures both the caret offset and its width
in codepoints (`src/main.zig`).

---

## L3. XML escaping is incomplete: font-family unescaped

**Status: LANDED.** The family string is escaped like text content
(`escapeAppend`, `src/svg.zig`), and every emitted coordinate passes
`checkFinite`, which errors instead of printing `nan`/`inf`. `svg.render`
consequently has a closed error set
(`error{ OutOfMemory, NonFiniteCoordinate }`).

---

## L4. Array colspec capacity miscounts `|` rules

**Status: LANDED.** A `|` still occupies a *slot* in the packed spec, but it
no longer consumes a *column* slot: `envColAlign` returns the c-th non-rule
nibble (`src/layout/layout.zig`). The slot budget was also raised from 6 to
12 precisely so rules fit (`EnvBits.max_spec_cols`, `src/atom.zig`), pinned by
the colspec test in `src/parse/parser.zig`.

---

## L5. Command surface is split across four sites

**Status: LANDED** (the finding's second remedy). `supported_commands`
(`src/parse/parser.zig`) is generated at comptime from the union of the four
dispatch tables — `cmd_map`, `mathstyle_map`, `symbol_map`, `delim_map` — and
re-exported as the single external answer (`src/parse/root.zig`). Three tests
keep it honest: exact-union coverage, cross-table collision, and per-command
dispatch reachability (all three named in `src/parse/parser.zig`). A fourth
comptime constant, `supported_distinct_count`, recomputes the union
independently, so a hand-added name with no backing table breaks the count
match instead of merely echoing the list's own length.

---

## L6. Doc drift: `--bg` accepted but undocumented

**Status: LANDED.** The usage text lists the alias (`src/main.zig`, `usage`).

---

## L7. `Span.len` underflows on a malformed span

**Status: LANDED.** Saturating subtraction, with the reason at the accessor
(`Span.len`, `src/atom.zig`).

---

## Summary

| # | Severity | Area | Finding | Status |
|---|----------|------|---------|--------|
| C1 | Critical | context | `render` mutates cache through `*const` | LANDED |
| C2 | Critical | context/font | `loadFont`/`--font` is a no-op | LANDED (removed) |
| C3 | Critical | atom | `fracThicknessBits` overflow | LANDED |
| C4 | Critical | parse | `u32` source-size cap | LANDED |
| H1 | High | facade | two pipelines, same shape | LANDED |
| H2 | High | facade/main | parse error erased then hardcoded | LANDED |
| H3 | High | svg/main | bad color → transparent | LANDED |
| M1 | Medium | atom/box | `0` sentinel collides | LANDED (documented + checked) |
| M2 | Medium | atom | unchecked `child`/`node`/`get` | LANDED |
| M3 | Medium | box | `children()` slice invalidation | LANDED (documented) |
| M4 | Medium | draw/context | by-value owning structs | LANDED (documented) |
| M5 | Medium | draw | `Text.bytes` ownership | LANDED |
| L1 | Low | parse | false node-pool bound comment | LANDED |
| L2 | Low | parse/main | byte-based caret column | LANDED |
| L3 | Low | svg | unescaped family, non-finite coords | LANDED |
| L4 | Low | atom/layout | array colspec `|` miscount | LANDED |
| L5 | Low | parse | split command table | LANDED |
| L6 | Low | main | `--bg` undocumented | LANDED |
| L7 | Low | atom | `Span.len` underflow | LANDED |

---

## Stale / Dead API

Dead exported symbols carry maintenance weight and widen the surface for no
consumer. Verified by whole-`src/` search on 2026-10-01 and re-checked
2026-10-02.

### D1. `null_span` is dead — **LANDED**

Removed. `Span` is now defined without any sentinel (`src/atom.zig`).

### D2. `null_child` is dead, and its test is tautological — **LANDED**

Both removed. Leaf creation uses `&.{}` plus `num_children = 0`
(`BoxList.createLeaf`, `src/layout/box.zig`); the self-equality test is gone.

### D3. `null_node` is exported but internal-only — **LANDED**

Now a private `const` in its only consumer's file (`src/atom.zig`).

### D4. `parse.lexer` / `parse.parser` are public with no external consumer — **LANDED**

Both are private imports now (`src/parse/root.zig`); only `err` is re-exported
alongside `Info` / `Kind` and the `supported_commands` list.

### D5. `ztex.render` (free fn) is the legacy pipeline, not the one `main`
uses — **LANDED** (via H1/SIM1)

The metric-source distinction that made it a second public entry point is
gone; it is now a documented one-line wrapper over the shared pipeline
(`src/root.zig`).

---

## AI Slop

### S1. Over-commenting: narration and repeated architecture boilerplate — **LANDED**

All of the named material is gone. The `atom.zig` header states only the
invariant that module owns, the `box.zig` and `draw.zig` headers are down to
one and two lines (`src/layout/`), and the restating accessor doc on
`pushNode` is deleted (the declaration in `src/atom.zig` now carries no doc
comment). The last survivor of the exact boilerplate — the "house pattern,
cf. `~/projects/{vain,skript}`" aside — is gone from the lexer header
(`src/parse/lexer.zig`), which now states only the token-table contract. The
TeX-measured values, bit layouts, and ownership rules this finding said to
keep are all still present. See also `audit2.md` M8.

### S2. Q16.16 fixed-point for space widths buys nothing, adds a UB surface — **LANDED**

`emToFixed`/`fixedToEm` are plain `@bitCast`s (`src/atom.zig`), and the doc
states why the old encoding was worse. The `u32 data` field now holds exactly
one encoding per node tag (`f32` bits for `space`, raw enum for
`style`/`BigOp`, bit-packed for `fraction`).

### S3. Char-specific state bled into the generic `Box` AoS — **LANDED**

`Box` is the shared header only; char-only state lives in `CharData` in the
parallel `BoxList.chars` side table, reachable only through `charData` /
`charDataPtr` (`src/layout/box.zig`).

### S4. `TODO(macros)` reserved slot — YAGNI — **LANDED**

`FontContext` no longer reserves a macro field; its fields are the allocator,
arena, I/O backend, three caches, and the five embedded faces (`src/font.zig`).

### S5. `isParseError` re-enumerates the parse error set by hand — **LANDED**

Deleted. `main` matches the typed facade set (`src/main.zig`), so there is no
second list to drift.

---

## Simplification

### SIM1. Collapse the two render pipelines into one — **LANDED**

`renderPipeline` (`src/root.zig`); both facades are thin wrappers.

### SIM2. Replace `FontMetrics`'s function-pointer indirection with a closed union — **LANDED**

`union(enum) { static: StaticTables, font: FontHook }` (`FontMetrics`,
`src/layout/metrics.zig`), with `FontHook` alongside it. The `?*anyopaque` and
the hand-installed pointers are gone, and C1's const-lie goes with them.

### SIM3. Drop the Q16.16 machinery; store space width as an f32 bitcast — **LANDED**

`emToFixed` / `fixedToEm` (`src/atom.zig`).

### SIM4. Move char payload out of the common `Box` — **LANDED**

Same change as S3: `CharData` and `BoxList.chars` in `src/layout/box.zig`.

### SIM5. Fold the former `token` module into `atom.zig` — **LANDED**

That module was deleted; its three public types now live in `src/atom.zig`
under a section header that marks the fold.

### SIM6. Fix or delete the reserve bound comment — **LANDED**

Same change as L1: the node-pool reserve note in `src/parse/root.zig`.

---

## Prioritized cleanup queue — status as of 2026-10-02

1. **SIM2 + SIM1** — kill C1 and H1 at the root. **DONE**
   (`FontMetrics`, `renderPipeline`).
2. **SIM3** — delete Q16.16, kill C3's twin UB surface. **DONE**
   (`emToFixed` / `fixedToEm`).
3. **SIM4** — shrink `Box`, remove dead char state from non-char boxes.
   **DONE** (`CharData` / `BoxList.chars`).
4. **D1/D2/D3** — delete `null_span`, `null_child` (+ its tautological
   test), privatize `null_node`. **DONE**.
5. **SIM5, D4** — fold the token types, unpublish `parse.lexer`/`parse.parser`.
   **DONE**.
6. **S1, S4, SIM6** — trim narration/boilerplate, drop the `TODO(macros)`
   slot, fix the reserve comment. **DONE**.

Both items the queue never listed are closed too: M2's `Ast.node` bounds check
and S1's last aside.

Every item above is still DONE. The 2026-10-02 wave changed the code behind
these entries but added no finding to this round: the new defects it surfaced
are recorded in `audit2.md`.

The wave did move one remedy this queue cites: `renderPipeline` became `pub` so
`src/context.zig` can reach it across files (see H1). That widens the module's
symbol table without adding a host-facing entry point — the host API is still
`ztex.render` / `Context.render`, and `include/ztex.h` and `README.md` never
name it.

**Final-wave verification completed.** The integrated tree passes all 422
tests, the full build, the required zwanzig analyzer, fmt, ast-check and zlint.
`bash scripts/gate.sh --cov` passed; zbc's advisory diagnostics and its wrapper's
truncated reporting are recorded in `audit2.md`. Static-library and API-doc builds passed.
A C89 consumer exercised all six exports with 325 matched allocations, and the
header passed C++17 compilation. Actual CLI renders covered 60 formulas in SVG,
PGM and PPM; the SVGs were inspected in Chromium with all five embedded faces.
Sixteen padded-versus-zero-padding raster probes found no ink outside the
zero-padding frame. `audit2.md` records counts, coverage and remaining limits.