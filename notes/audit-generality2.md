# Audit: generality / embeddability of ztex as a library

Lens: allocator threading, Context lifecycle + thread-safety, output formats,
typed errors/OOM mapping, input-reachable panics, static state, OS deps,
module/dep footprint, host docs. Read-only; all evidence from the tree.

## What is good (keep)

- **gpa is threaded everywhere.** parse/layout/svg/context take the caller's
  allocator; no page/c_allocator/global_allocator anywhere in the library
  path. Embedded fonts are comptime `const` byte arrays (no hidden alloc).
- **No static mutable state.** Only file-scope `const` tables (layout.zig
  glue_em, metrics.zig rows, svg.zig named colors). The `&metrics.default`
  static-table path is therefore thread-safe per render (given a thread-safe
  gpa) — render() on the static facade is shareable.
- **Typed parse errors with Info context** (kind + span) and a **closed
  FontError** set with bounds-checked sfnt table validation
  (font.zig parseOwned: rejects truncated tables before any slicing;
  advanceEm's `n - 1` is guarded by `num_h_metrics == 0` rejection).
- **Clean module split**: `ztex.layout` standalone (no font data); only
  `ztex`/`context` pull font.zig + the ~2.1 MB embedded faces.
- DrawList carries source-span provenance on every primitive (host can map
  output → input).

## Findings (severity, file:line)

### C1 — No recursion-depth limit: attacker input → stack overflow → process abort
`src/parse/parser.zig` (parseRow/parseGroup/parseCommand/parseDelimiter mutual
recursion; no depth counter except `delim_depth`, which is a correctness
counter, not a cap — parser.zig:664) and `src/layout/layout.zig` (every
layout* fn recurses per node). A few-KB input of `\frac{\frac{...}}` or
`{{{{...` nests ~1 level/byte → stack overflow (SIGSEGV). Zig cannot catch
this: the host process dies. For any server embedding ztex with untrusted
input this is a remote crash. Fix: depth counter in Parser returning a typed
`error.NestingTooDeep` (add to parse.Error), and a matching depth guard in
layout (or iterative box layout). Cheap, high payoff.

### C2 — `Ast.child` panics on the documented hand-built-AST path
`src/atom.zig:491` `@panic("Ast.child: child index out of bounds")`;
`src/layout/box.zig:161-190` `std.debug.assert(idx < len)` in get/charData/
children. layout.render explicitly documents "give it any atom.Ast (from
ztex.parse or hand-built)" — a host building a tree with a wrong
num_children, or any future parser/layout invariant slip, aborts the whole
process instead of returning an error. Fix: return an error from child()
(or validate the tree once in layout.render), and convert the BoxList asserts
to errors at the API boundary. This is the class of bounds-check panics the
earlier audit added; only C1 is directly input-reachable today, but C2 is
reachable via the public API contract.

### H1 — Context is not thread-safe; undocumented
`src/context.zig` render takes `*Context` and the first render mutates
`FontContext.metrics_cache` (std.AutoHashMapUnmanaged, font.zig:487-501)
plus the backing ArenaAllocator — no synchronization anywhere. Two threads
rendering on one Context = data race (UB). The C1 doc comment explains the
`*Context` signature but not the threading consequence. Fix: document "one
Context per thread, or external mutex"; optionally a mutex or per-thread
cache later. Note the static facade `ztex.render` IS shareable (no cache).

### H2 — `max_source_bytes` gate is insufficient for the u32 node pool
`src/parse/root.zig:34` caps input at `maxInt(u32)` bytes, but the node pool
grows ~2× tokens and tokens ≈ src bytes: a ~2.15 GB input of repeated chars
overflows `@intCast(self.nodes.items.len)` (atom.zig:430 pushNode) → safe-mode
panic, ReleaseFast silent truncation (worse). The cap must bound the node
count, not the byte count: use `maxInt(u32) / 2` (or check nodes.len before
the cast). Also note the guard lives only in parse.parse — the lexer alone
would not enforce it (lexer.zig:73 `@intCast(start)`).

### M1 — OOM mapping swallows future non-OOM layout errors
`src/root.zig:41` and `src/context.zig:91`:
`layout.render(...) catch error.OutOfMemory`. layout.render's set is
anyerror ("only ever fails on allocation" — an assumption, not a type). The
day layout grows a real error (e.g. a depth guard from C1), it is silently
misreported as OutOfMemory to every caller. Fix: narrow layout.render to
`error{OutOfMemory}!draw.DrawList` so the catch is exhaustive and honest.

### M2 — `svg.writeFile` hardcodes cwd; file I/O in the library module
`src/svg.zig:168` `std.Io.Dir.createFile(.cwd(), ...)`. A host cannot write
to a chosen directory without chdir (process-global side effect), and
sandboxed hosts (WASM/browser/embedded) must avoid the svg module's only
fs entry. Fix: take a `std.Io.Dir` parameter, or move writeFile out of the
library into main.zig. svg.render stays pure (good).

### M3 — No exact ink-bounds API for hosts
`src/layout/draw.zig:85-90`: DrawList exposes only font-metric box
width/height/depth; `src/svg.zig:63-71` adds heuristic margins (0.08×max_size
+ 0.2em lineGap) precisely because the box can under-bind ink. Hosts needing
tight/tuned frames, hit-testing, or exact ink extents must re-derive from
primitives. Fix: compute a true ink bbox during flatten (max ascent/descent
over drawn text ink) and expose it on DrawList.

### M4 — Embeddability pins: Zig 0.16.0 exactly + one external dep
`build.zig.zon`: `minimum_zig_version = "0.16.0"`; std.Io/std.process.Init/
unmanaged-ArrayList APIs are 0.16-specific; zg 0.16.2 fetched from codeberg
by URL+hash (single supply-chain point; offline hosts must vendor it). No
C ABI, no addLibrary artifact — Zig-only consumers via `b.dependency`.
Fix: document the Zig-version contract; consider `addStaticLibrary` +
exported C header for non-Zig hosts; vendor zg for offline builds.

## Low (L)

- L1 `src/parse/parser.zig:722` `unreachable` for lexer kinds in fail().
  Safe by construction today (lex returns those errors directly) but a
  refactor that routes them through fail() becomes a panic; replace with a
  real error arm or a compile-time assertion.
- L2 DrawList is move-only, enforced by doc comment only (draw.zig:73-76);
  a by-value copy double-deinits glyph_arena. render() returns it by value,
  inviting the bug. Consider a `copy`-forbidden wrapper or at least a
  `clone()` that deep-copies.
- L3 `src/svg.zig:57` render returns `![]u8` (anyerror); should be a closed
  `error{OutOfMemory, NonFiniteCoordinate}![]u8` like parse.Error.
- L4 Embedded font payload ~2.1 MB (733 KB LM Math split across 5 files for
  the 1 MiB VCS limit, + 713 KB + 670 KB) links into any binary importing
  the ztex facade. Fine for desktop; heavy for web. Document which module
  pulls it (layout-only hosts are free).
- L5 No README/host-facing docs (repo root: AGENTS.md, audit.md only).
  Module doc comments are strong but cover none of: allocator contract,
  thread-safety (H1), lifetime rules (src alias + DrawList arena), error
  contract, version pinning.

## Top-5 embeddability gaps by payoff

1. Recursion-depth limit (C1) — remote crash on untrusted input; small fix.
2. Panic → error on the AST/BoxList accessors (C2) — process abort in a
   documented API path; small fix.
3. Context thread-safety contract (H1) — document + per-thread guidance;
   currently a silent data race.
4. Honest typed errors (M1 + L3) — narrow layout.render and svg.render error
   sets so the OOM mapping and anyerror returns are real contracts.
5. Ink-bounds API (M3) — hosts can't produce tight/exact frames today;
   heuristic margins are baked into svg.
