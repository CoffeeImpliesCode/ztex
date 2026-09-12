# ztex API — Adversarial Review (round 1)

- **Original pass**: undated static reading of the public API surface, before
  round 2 (`audit2.md`, 2026-08-16).
- **Status pass**: 2026-10-01. Every finding below was re-checked against the
  current tree; the original line numbers were discarded.
- **Scope**: the public API surface — `src/root.zig`, `src/context.zig`,
  `src/atom.zig`, `src/parse/` (root, lexer, parser, error),
  `src/layout/` (root, box, draw, layout, metrics), `src/svg.zig`,
  `src/font.zig`, `src/main.zig`.
- **Method**: static reading only. Findings were never runtime-verified;
  anything not directly evidenced was marked `[INFERENCE]` at the time.

## Status legend

- **LANDED** — fixed in the current source. The line states where it now lives.
- **OPEN** — still present. The line carries the current `file:line`.

A finding that is only half addressed is marked **OPEN** with the landed half
named in the note, so the queue never overstates progress.

## Severity legend

**C** = soundness/UB/memory-safety, **H** = correctness or silent
misbehavior, **M** = design/footgun, **L** = docs/minor.

---

## C1. `Context.render` mutates shared state through a `*const` receiver

**Status: LANDED.** `Context.render` takes `*Context`
(`src/context.zig:117`) and says why (`src/context.zig:114-116`). The root
cause is gone too: `FontMetrics` is a closed union
(`src/layout/metrics.zig:120`) instead of four hand-installed fn pointers
behind a `?*anyopaque`, so there is no const receiver left to lie about. The
one remaining cast is the deliberate `.font`-arm unwrap in `contextGlyph`
(`src/context.zig:60`), whose non-const `*FontContext` is documented as
cache-mutating.

---

## C2. `loadFont` / `--font` is inert — no effect on metrics or output

**Status: LANDED** (the second remedy the finding offered: removal).
`Context` exposes only `init` / `deinit` / `render` / `renderPixels`
(`src/context.zig:86`, `src/context.zig:98`, `src/context.zig:117`,
`src/context.zig:127`); there is no `loadFont`, and the CLI usage text
(`src/main.zig:4-22`) has no `--font`.

---

## C3. `fracThicknessBits` panics/UB on large `\genfrac` thickness

**Status: LANDED.** The value is clamped into the Q8.8 range *before* the
float→int conversion (`src/atom.zig:234`). The `emToFixed` twin the finding
warned about no longer performs a conversion at all (see S2/SIM3).

---

## C4. `u32` byte-offset truncation / `@intCast` panic on >4 GiB source

**Status: LANDED.** `parse` rejects oversized input up front with
`error.SourceTooLarge` — declared at `src/parse/root.zig:23`, bounded at
`src/parse/root.zig:37`, enforced at `src/parse/root.zig:52`. The bound and
its rationale are documented at `src/parse/root.zig:28-37`; the boundary is
unit-tested at `src/parse/root.zig:85`.

---

## H1. Two parallel full pipelines, near-identical names, different metric sources

**Status: LANDED.** One pipeline, one explicit metric source:
`renderPipeline` (`src/root.zig:36`). `ztex.render` is a one-line wrapper
over it with `&layout.metrics.default` (`src/root.zig:51-63`);
`Context.render` delegates to the same helper with its `.font` arm
(`src/context.zig:117-124`). The duplicated layout body is gone.

---

## H2. Parse-error set is erased at the facade, then hardcoded in `main`

**Status: LANDED.** Both facades return the typed set
`parse.Error || error{InvalidAst}` (`src/root.zig:61`,
`src/context.zig:122`), and `main` matches it without re-enumerating the
names (`src/main.zig:122-135`).

---

## H3. Color parse failures silently produce a transparent background

**Status: LANDED.** `parseColorChecked` returns `null` only for the valid
`none`/`transparent` and `error.UnrecognizedColor` for anything else
(`src/svg.zig:231-251`); `main` turns that error into a message and a failing
exit (`src/main.zig:94`).

---

## M1. `null_node`/`null_child` sentinel `0` collides with a real index

**Status: LANDED** (the finding's "at minimum" remedy: document + check
every read, not reserve index 0). `0` is still a valid index, but the
invariant is now stated on every field that carries it
(`src/atom.zig:352`, `src/atom.zig:362`, `src/layout/box.zig:59`),
`Ast.child` panics instead of reading across the run
(`src/atom.zig:483`), and the layout boundary validates the whole
root-reachable subtree before use (`src/layout/root.zig:85`).

---

## M2. `Ast.child`, `Ast.node`, `BoxList.get` are unchecked; `child` reads across runs

**Status: OPEN.** Two of the three are checked: `Ast.child` panics on an
out-of-range index (`src/atom.zig:483`) and `BoxList.get` asserts
(`src/layout/box.zig:166`). `Ast.node` is still a bare
`self.nodes.items[idx]` with no bounds check (`src/atom.zig:475`), so a
hand-built `Ast` with a bad index still reaches an unchecked read on the
`node` path. In practice the layout-boundary validator rejects such a tree
first (`src/layout/root.zig:85`), but the accessor itself is unguarded.

---

## M3. `BoxList.children` returns a live slice that `create` invalidates

**Status: LANDED.** The invalidation contract is documented on the accessor:
the slice aliases `childrefs` storage and any `create`/`createLeaf` may
realloc it (`src/layout/box.zig:184-186`).

---

## M4. By-value structs with hidden ownership → double-free on copy

**Status: LANDED.** Every owning struct now carries the "do not copy" rule:
`DrawList` (`src/layout/draw.zig:104`), `Ast` (`src/atom.zig:390`),
`BoxList` (`src/layout/box.zig:138`), `Context` (`src/context.zig:17`,
restated on `deinit` at `src/context.zig:98`).

---

## M5. `Text.bytes` has two ownership domains with no discriminator

**Status: LANDED.** `Text.synthetic` is the discriminator
(`src/layout/draw.zig:38`, field at `src/layout/draw.zig:41`), documented
against the field and carried from the box in `flatten`
(`src/layout/draw.zig:234`).

---

## L1. "Exact node-pool bound" comment is false

**Status: LANDED.** The comment now states the reserve is a heuristic, not a
bound, and says the pool grows on demand (`src/parse/root.zig:66`).

---

## L2. Byte-based line/column misaligns the caret on multi-byte input

**Status: LANDED.** `countCodepoints` (`src/parse/error.zig:70`) and a
codepoint column in `lineCol` (`src/parse/error.zig:78`,
`src/parse/error.zig:81`); `main` measures both the caret offset and its
width in codepoints (`src/main.zig:229`).

---

## L3. XML escaping is incomplete: font-family unescaped

**Status: LANDED.** The family string is escaped like text content
(`src/svg.zig:107`), and every emitted coordinate passes `checkFinite`,
which errors instead of printing `nan`/`inf`
(`src/svg.zig:266`). `svg.render` consequently has a closed error set
(`src/svg.zig:58`).

---

## L4. Array colspec capacity miscounts `|` rules

**Status: LANDED.** A `|` still occupies a *slot* in the packed spec, but it
no longer consumes a *column* slot: `envColAlign` returns the c-th non-rule
nibble (`src/layout/layout.zig:1692`). The slot budget was also raised from
6 to 12 precisely so rules fit, documented at `src/atom.zig:109-130`
(`max_spec_cols` at `src/atom.zig:130`). Pinned by
`src/parse/parser.zig:2920`.

---

## L5. Command surface is split across four sites

**Status: LANDED** (the finding's second remedy). `supported_commands` is
generated at comptime from the union of the four dispatch tables
(`src/parse/parser.zig:522`, `src/parse/parser.zig:531`) and re-exported as
the single external answer (`src/parse/root.zig:13`, `src/parse/root.zig:16`).
Three tests keep it honest: exact-union coverage
(`src/parse/parser.zig:2987`), cross-table collision
(`src/parse/parser.zig:3022`), and per-command dispatch reachability
(`src/parse/parser.zig:3063`).

---

## L6. Doc drift: `--bg` accepted but undocumented

**Status: LANDED.** The usage text lists the alias
(`src/main.zig:17`).

---

## L7. `Span.len` underflows on a malformed span

**Status: LANDED.** Saturating subtraction, with the reason at the accessor
(`src/atom.zig:44`).

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
| M2 | Medium | atom | unchecked `child`/`node`/`get` | OPEN (`Ast.node`) |
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
consumer. Verified by whole-`src/` search on 2026-10-01.

### D1. `null_span` is dead — **LANDED**

Removed. `Span` is now defined without any sentinel
(`src/atom.zig:38-49`).

### D2. `null_child` is dead, and its test is tautological — **LANDED**

Both removed. Leaf creation uses `&.{}` plus `num_children = 0`
(`src/layout/box.zig:228`); the self-equality test is gone.

### D3. `null_node` is exported but internal-only — **LANDED**

Now a private `const` in its only consumer's file
(`src/atom.zig:365`).

### D4. `parse.lexer` / `parse.parser` are public with no external consumer — **LANDED**

Both are private imports now (`src/parse/root.zig:9`,
`src/parse/root.zig:10`); only `err` is re-exported
(`src/parse/root.zig:11`), alongside the new `supported_commands`
(`src/parse/root.zig:16`).

### D5. `ztex.render` (free fn) is the legacy pipeline, not the one `main` uses — **LANDED** (via H1/SIM1)

The metric-source distinction that made it a second public entry point is
gone; it is now a documented one-line wrapper over the shared pipeline
(`src/root.zig:51`).

---

## AI Slop

### S1. Over-commenting: narration and repeated architecture boilerplate — **OPEN**

Most of the named material is gone: the `atom.zig` header now states only
the invariant that module owns (`src/atom.zig:1-7`), the `box.zig` and
`draw.zig` headers are down to one and two lines
(`src/layout/box.zig:1`, `src/layout/draw.zig:1-2`), and the restating
accessor doc on `pushNode` is deleted (`src/atom.zig:424`).

One instance of the exact boilerplate this finding named survives: the
"house pattern, cf. `~/projects/{vain,skript}`" aside
(`src/parse/lexer.zig:4`). See also `audit2.md` M8, which tracks the same
narration.

### S2. Q16.16 fixed-point for space widths buys nothing, adds a UB surface — **LANDED**

`emToFixed`/`fixedToEm` are plain `@bitCast`s (`src/atom.zig:367`,
`src/atom.zig:371`, `src/atom.zig:375`), and the doc states why the old
encoding was worse. The `u32 data` field now holds exactly one encoding per
node tag (`f32` bits for `space`, raw enum for `style`/`BigOp`, bit-packed
for `fraction`).

### S3. Char-specific state bled into the generic `Box` AoS — **LANDED**

`Box` is the shared header only (`src/layout/box.zig:54`); char-only state
lives in `CharData` (`src/layout/box.zig:69`) in the parallel
`BoxList.chars` side table (`src/layout/box.zig:147`), reachable only through
`charData` / `charDataPtr` (`src/layout/box.zig:171`,
`src/layout/box.zig:177`).

### S4. `TODO(macros)` reserved slot — YAGNI — **LANDED**

`FontContext` no longer reserves a macro field; its fields are the allocator,
arena, I/O backend, three caches, and the three embedded faces
(`src/font.zig:1670-1692`).

### S5. `isParseError` re-enumerates the parse error set by hand — **LANDED**

Deleted. `main` matches the typed facade set (`src/main.zig:122-135`), so
there is no second list to drift.

---

## Simplification

### SIM1. Collapse the two render pipelines into one — **LANDED**

`renderPipeline` (`src/root.zig:36`); both facades are thin wrappers.

### SIM2. Replace `FontMetrics`'s function-pointer indirection with a closed union — **LANDED**

`union(enum) { static: StaticTables, font: FontHook }`
(`src/layout/metrics.zig:120`), with `FontHook` at
`src/layout/metrics.zig:106`. The `?*anyopaque` and the hand-installed
pointers are gone, and C1's const-lie goes with them.

### SIM3. Drop the Q16.16 machinery; store space width as an f32 bitcast — **LANDED**

`src/atom.zig:367-376`.

### SIM4. Move char payload out of the common `Box` — **LANDED**

Same change as S3: `src/layout/box.zig:69`, `src/layout/box.zig:147`.

### SIM5. Fold the former `token` module into `atom.zig` — **LANDED**

That module was deleted; its three public types now live in `src/atom.zig`
under a section header that marks the fold (`src/atom.zig:11`, types at
`src/atom.zig:13-49`).

### SIM6. Fix or delete the reserve bound comment — **LANDED**

Same change as L1: `src/parse/root.zig:66`.

---

## Prioritized cleanup queue — status as of 2026-10-01

1. **SIM2 + SIM1** — kill C1 and H1 at the root. **DONE**
   (`src/layout/metrics.zig:120`, `src/root.zig:36`).
2. **SIM3** — delete Q16.16, kill C3's twin UB surface. **DONE**
   (`src/atom.zig:371`).
3. **SIM4** — shrink `Box`, remove dead char state from non-char boxes.
   **DONE** (`src/layout/box.zig:69`).
4. **D1/D2/D3** — delete `null_span`, `null_child` (+ its tautological
   test), privatize `null_node`. **DONE** (`src/atom.zig:365`,
   `src/layout/box.zig:228`).
5. **SIM5, D4** — fold the token types, unpublish `parse.lexer`/`parse.parser`.
   **DONE** (`src/atom.zig:11`, `src/parse/root.zig:9`).
6. **S1, S4, SIM6** — trim narration/boilerplate, drop the `TODO(macros)`
   slot, fix the reserve comment. **PARTIAL**: S4 and SIM6 done
   (`src/font.zig:1670`, `src/parse/root.zig:66`); S1 still open on one
   surviving aside (`src/parse/lexer.zig:4`).

Two items the queue never listed remain open from this pass: M2's
`Ast.node` bounds check (`src/atom.zig:475`) and S1's last aside.