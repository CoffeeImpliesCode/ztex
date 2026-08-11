# ztex API — Adversarial Review

Scope: public API surface — `root.zig`, `context.zig`, `parse/`, `atom.zig`, `token.zig`, `layout/` (root, box, draw, metrics), `svg.zig`, `main.zig`.
Method: static reading of source. Findings are not runtime-verified; anything not directly evidenced is marked `[INFERENCE]`.

Severity legend: **C** = soundness/UB/memory-safety, **H** = correctness or silent misbehavior, **M** = design/footgun, **L** = docs/minor.

---

## C1. `Context.render` mutates shared state through a `*const` receiver

**Evidence:** `render(self: *const Context, …)` (`context.zig:99`) passes `&self.fm` — a `*const FontMetrics` — into layout. `contextGlyph(self: *const FontMetrics, …)` (`context.zig:43`) does `@ptrCast(@alignCast(self.font orelse return null))` to reach a `*font.FontContext` through the **non-const** `font: ?*anyopaque` (`metrics.zig:98`), then calls `f.metrics(...)`. `metrics()` does `self.metrics_cache.put(...)` (`font.zig:543-553`) — a mutation of the HashMap.

**Impact:** Two threads rendering on a shared `*const Context` race on `metrics_cache`. The `const` qualifier on `render` and on `FontMetrics` is a lie: the "const" receiver mutates reachable state. Anyone who trusts `*const` for concurrency gets a data race.

**Fix:** Make `render` take `*Context` (non-const), or make the cache externally synchronized, or make the cache per-render. Do not advertise a const-correct render that mutates.

---

## C2. `loadFont` / `--font` is inert — no effect on metrics or output

**Evidence:** The only font-backed metric path is `contextGlyph`, which selects `f.romanFace(false)` or `f.mathFace()` (`context.zig:45`). `mathFace`/`romanFace` return the **embedded** faces (`font.zig:497-505`). `loadFromFile` stores loaded faces in `self.faces` (`font.zig:510-511`), but nothing in the metric or SVG path reads `self.faces`. The SVG font-family comes from `Options.font_family` (`svg.zig:20`), which `loadFont` does not touch.

**Impact:** The CLI advertises `--font <path>` "load an extra font file into the render context" (`main.zig:13-15,52-54`) and `Context.loadFont` is public (`context.zig:90-92`). The loaded face is parsed and cached, then never used: metrics still come from embedded Latin Modern, and the SVG still names Latin Modern. The feature is a parse-and-discard no-op. Users will reasonably expect `--font` to change rendering and it cannot.

**Fix:** Either wire loaded faces into glyph selection and font-family emission, or remove `loadFont`/`--font` until it does something.

---

## C3. `fracThicknessBits` panics/UB on large `\genfrac` thickness

**Evidence:** `fracThicknessBits` (`atom.zig:188-192`): `@intFromFloat(@round(@max(pt, 0) * 256.0))` into an `i32`, then `@intCast`. For `pt` above ~8.4e6 (so `pt*256` exceeds `i32` max 2.1e9), `@intFromFloat` is a safety panic in Debug/ReleaseSafe and UB in ReleaseFast. The input is a parsed TeX dimension from `\genfrac{...}{...}{thick}{...}` — attacker-controllable formula text.

**Impact:** A crafted formula (`\genfrac{}{}{100000000pt}{}{1}{2}`) crashes the CLI in safe builds, and is UB in `ReleaseFast`. `emToFixed` (`atom.zig:311-313`) has the same unclamped `@intFromFloat` but is only fed table constants internally.

**Fix:** Clamp to the Q8.8 range **before** the float→int conversion (`@min(pt, 255.99)`), or use a checked float→int. Do the same for `emToFixed` if it stays public.

---

## C4. `u32` byte-offset truncation / `@intCast` panic on >4 GiB source

**Evidence:** `Span` uses `u32` offsets (`token.zig:38-40`); lexer `emit` does `@intCast(start)` (`lexer.zig:70-76`); parser token spans are `u32`.

**Impact:** A >4 GiB source buffer panics the lexer (safe mode) or silently truncates provenance (ReleaseFast). Low likelihood for real LaTeX, but the library accepts arbitrary `[]const u8` with no length check and no documented limit.

**Fix:** Document a size limit or reject inputs above a bound up front with a real error.

---

## H1. Two parallel full pipelines, near-identical names, different metric sources

**Evidence:** `ztex.render` (`root.zig:25-34`) runs parse+layout with the **static** tables (`layout.render` hardcodes `&metrics.default`, `layout/root.zig:37`). `Context.render` (`context.zig:99-125`) runs the same pipeline with **real font** metrics. Both return an identically-shaped `draw.DrawList`.

**Impact:** `ztex.render` and `ctx.render` are one-character-apart names producing silently different measurements. A caller who grabs the free function instead of the context gets static-table glyphs; nothing in the type or the name signals the difference.

**Fix:** Make the metrics source an explicit parameter of `layout.render` (and `ztex.render`), so there is one pipeline and `Context.render` calls it instead of inlining the entire layout body (`context.zig:106-125` duplicates `layout/root.zig:26-48`). Delete the duplicate.

---

## H2. Parse-error set is erased at the facade, then hardcoded in `main`

**Evidence:** `parse.parse` returns the typed `parse.Error!atom.Ast` (`parse/root.zig:25`), but `ztex.render`/`Context.render` return `!draw.DrawList` (anyerror). `main.zig:92-110` hardcodes the 13 parse-error names in `isParseError` to decide whether to print a caret-annotated message.

**Impact:** Add a parser error variant and the facade type erasure hides it; `isParseError` silently stops recognizing it, and users get a bare `error.NewThing` with no position/caret. The two lists (`parse.Error` and `isParseError`) drift.

**Fix:** Thread the typed `parse.Error` through `render` (e.g. `parse.Error!draw.DrawList` with OOM mapped separately), so `main` matches exhaustively instead of re-enumerating.

---

## H3. Color parse failures silently produce a transparent background

**Evidence:** `parseColor` returns `null` for anything unrecognized (`svg.zig:163-183`); `main` does `bg = ztex.svg.parseColor(v)` with no error (`main.zig:50-51`).

**Impact:** `-b blak` (typo) silently drops the background rather than failing. Silent data loss on bad CLI input, indistinguishable from the legitimate `-b none`.

**Fix:** Distinguish `none`/`transparent` (valid null) from unrecognized input (error). Return an error union or validate in `main`.

---

## M1. `null_node`/`null_child` sentinel `0` collides with a real index

**Evidence:** `first_child: u32` with "0 = null/leaf" (`atom.zig:300`, `box.zig:61`); `null_node = 0` (`atom.zig:308`), `null_child = 0` (`box.zig:94`). Node/box index 0 is valid and can be a first child.

**Impact:** Correctness rests entirely on `num_children == 0` disambiguating "leaf" from "child 0". Any code that tests `first_child == 0` to mean "no children" is silently wrong. The superflat pattern is already index-bug-prone; this sentinel choice removes the one safety that an explicit "no child" marker would give.

**Fix:** Reserve index 0 as a true null (start pools at 1, or use `std.math.maxInt(u32)` as null), or at minimum add a checked accessor and audit every `first_child` read.

---

## M2. `Ast.child`, `Ast.node`, `BoxList.get` are unchecked; `child` reads across runs

**Evidence:** `Ast.child(idx, i)` returns `first_child + i` with no `i < num_children` check (`atom.zig:414-417`). `node()`/`get()` index arrays directly (`atom.zig:409-411`, `box.zig:118-120`).

**Impact:** An out-of-range `child` silently returns the **next node in the pool** — under the duplication protocol that is a garbage copy of another subtree, not a crash. Out-of-range `node`/`get` are OOB reads (UB in ReleaseFast). Hand-built trees (the API explicitly supports them, `layout/root.zig:3-4`) get silent corruption instead of a trap.

**Fix:** Bounds-check in `child`/`node`/`get` (panic on misuse), or make them return optional/error. These are cold-path accessors; the cost is negligible.

---

## M3. `BoxList.children` returns a live slice that `create` invalidates

**Evidence:** `children()` returns `childrefs.items[first .. first+n]` (`box.zig:123-130`). `create` appends to `childrefs` (`box.zig:145-146`), which can realloc and dangle that slice. The layout code avoids this via the `scratch`-save/restore protocol (`box.zig:104-105`, `create` copies placements), but that protection is internal, not enforced by the API.

**Impact:** A consumer who holds a `children()` slice and then calls `create` (a natural pattern when hand-building boxes) has a dangling pointer → UAF. The public API does not document this invalidation rule.

**Fix:** Document the invalidation contract, or make `children` index-based (return a `Children` iterator that re-reads indices, not a slice), or copy.

---

## M4. By-value structs with hidden ownership → double-free on copy

**Evidence:** `DrawList` holds `glyph_arena` (ArenaAllocator) and an ArrayList (`draw.zig:75-106`); `Context` holds `*FontContext` + `gpa` (`context.zig:58-92`); both are returned by value (`root.zig:30`, `context.zig:105`). `Context` documents "deinit must be called exactly once" (`context.zig:17`); `DrawList`/`Ast` do not.

**Impact:** An accidental copy of the returned struct duplicates the arena/pointer; both copies `deinit` → double free. Zig forbids no way to detect this at compile time without a move-only idiom.

**Fix:** At minimum document "do not copy" on every owning struct (`DrawList`, `Ast`, `Context`, `BoxList`). Better: consider non-copyable patterns (return `*DrawList` owned by caller, or `pub fn move`).

---

## M5. `Text.bytes` has two ownership domains with no discriminator

**Evidence:** In `flatten`, non-synthetic bytes alias `src` (`draw.zig:135`); synthetic bytes are duped into `out.glyph_arena` (`draw.zig:132-133`). The `Text` struct carries only `bytes` (`draw.zig:33-34`); the `synthetic` flag exists on `Box` (`box.zig:77`) but is **not** propagated to `Text`.

**Impact:** A downstream consumer of the draw list cannot tell whether `Text.bytes` is borrowed (caller must keep `src` alive) or owned (freed by `DrawList.deinit`). The provenance contract is split across the type and an implicit lifetime rule.

**Fix:** Carry `synthetic` (or an ownership enum) on `Text`, or unify: always dupe into the arena so `bytes` is uniformly owned by the list.

---

## L1. "Exact node-pool bound" comment is false

**Evidence:** `parse/root.zig:32-35` claims "every tree has nodes = 2·treesize − 1 … so 2·(tokens+1) caps the pool … never reallocates." That is the full-binary-tree leaf↔node formula, which does not hold for the n-ary/unary atom AST. Counterexample: a single char `x` parses to a root `.row` + one `.char` leaf — 2 nodes, 1 leaf, so `2·leaves−1 = 1 < 2`. (The formula only holds for full binary trees; the atom AST has unary `group`/`styled`/`overline` nodes and arbitrary-arity `row`s.)

**Impact:** Not a correctness bug — `ensureTotalCapacity` is a hint and the ArrayList grows on demand. But the documented invariant is wrong, and "never reallocates" is false: one token can expand to several nodes (`\sin` → 6 nodes from 1 token, so the pool under-reserves by ~3× and reallocs).

**Fix:** Fix or remove the comment; state the reserve as a heuristic, not an exact bound.

---

## L2. Byte-based line/column misaligns the caret on multi-byte input

**Evidence:** `lineCol` counts bytes ("column counts BYTES", `error.zig:64-66`); `printParseError` derives `caret_len` from `line.len -| pad` (`main.zig:144`), mixing byte columns with display width.

**Impact:** For a UTF-8 source with a multi-byte char before the error, the caret sits mid-codepoint / misaligned. Documented but degrades the one place error UX matters.

**Fix:** Count codepoints for the column, or render the source line with the caret by codepoint offset.

---

## L3. XML escaping is incomplete: font-family unescaped

**Evidence:** `escapeAppend` covers `& < > "` (`svg.zig:196-206`) but `Options.font_family`/`text_font_family` are emitted raw into the attribute (`svg.zig:93`). Numeric attrs use `{d}` (`svg.zig:94`), which would emit `nan`/`inf` verbatim if layout ever produces a non-finite coordinate.

**Impact:** A font-family containing a `"` breaks the SVG / enables attribute injection (developer-controlled, so low); non-finite metrics would corrupt output instead of failing.

**Fix:** Escape `font_family`/`text_font_family`; assert finiteness (or `isFinite`-guard) on all emitted coordinates.

---

## L4. Array colspec capacity miscounts `|` rules

**Evidence:** `envData` packs `|` as a column nibble (`atom.zig:126-129`), so a leading rule consumes a slot; `max_spec_cols = 6` (`atom.zig:95`) counts rules as columns.

**Impact:** `|c|c|c|c|c|c` (6 columns + leading rule = 7 spec chars) truncates to 6, silently dropping the 6th column's alignment. Ruled arrays with the maximum column count lose their rightmost spec.

**Fix:** Separate rule positions from column alignments in the packing, or bump the budget to account for rules.

---

## L5. Command surface is split across four sites

**Evidence:** Supported commands live in `cmd_map` (`parser.zig:155-259`), `mathstyle_map` (`parser.zig:266-271`), `symbol_map` (`parser.zig:278+`), and inline interception in `parseRow`/`parseScriptArg` for style switches (`parser.zig:264-265`).

**Impact:** No single place answers "what does this parser support". Adding a command requires knowing which of four mechanisms it belongs to; a reviewer cannot eyeball the grammar surface.

**Fix:** Centralize the command→dispatch table, or add a single generated `supported_commands` list with a test asserting every map entry is exercised.

---

## L6. Doc drift: `--bg` accepted but undocumented

**Evidence:** `main.zig:49` accepts `--bg` as an alias for `-b`; the help text documents only `-b` (`main.zig:11-12`).

**Fix:** Document `--bg` or remove the alias.

---

## L7. `Span.len` underflows on a malformed span

**Evidence:** `Span.len` returns `end - start` on `u32` (`token.zig:42-44`). The lexer never emits `end < start`, but the type is public and hand-constructible.

**Impact:** A hand-built span with `end < start` underflows to a huge `usize`. Not reachable through `parse`, but the public provenance type is unguarded.

**Fix:** Saturating subtraction (`end -| start`).

---

## Summary

| # | Severity | Area | Finding |
|---|----------|------|---------|
| C1 | Critical | context | `render` mutates cache through `*const` — thread-unsafe const-lie |
| C2 | Critical | context/font | `loadFont`/`--font` is a no-op for metrics and output |
| C3 | Critical | atom | `fracThicknessBits` UB/panic on huge `\genfrac` thickness |
| C4 | Critical | token/lexer | >4 GiB source panics/truncates `u32` offsets |
| H1 | High | facade | two pipelines, different metrics, same shape, near-identical names |
| H2 | High | facade/main | typed parse error erased then hardcoded in `isParseError` |
| H3 | High | svg/main | bad color silently → transparent background |
| M1 | Medium | atom/box | `0` sentinel collides with real child index |
| M2 | Medium | atom/box | unchecked `child`/`node`/`get`; `child` reads across runs |
| M3 | Medium | box | `children()` slice invalidated by `create` |
| M4 | Medium | draw/context | by-value owning structs → double-free on copy |
| M5 | Medium | draw | `Text.bytes` ownership not encoded on the type |
| L1–L7 | Low | misc | bound-comment falsehood, byte-caret misalign, font-family unescaped, colspec `|` miscount, split command table, `--bg` drift, `Span.len` underflow |

Highest-value fixes first: **C1** (make the mutation honest), **C2** (either make `--font` work or remove it), **C3** (clamp before conversion), **H1** (single pipeline with an explicit metrics parameter).
---

## Stale / Dead API

Dead exported symbols carry maintenance weight and widen the surface for no consumer. Verified by whole-`src/` search.

### D1. `null_span` is dead

Defined `atom.zig:20`, zero references anywhere in `src/`. Remove.

### D2. `null_child` is dead, and its test is tautological

Defined `box.zig:94`; production code never reads it — `create`/`createLeaf` use `&.{}` plus `num_children = 0`, never the sentinel. Its only "use" is `test "boxlist: NULL_CHILD sentinel is zero"` (`box.zig:212-213`), which asserts the constant equals itself. Delete both the constant and the test.

### D3. `null_node` is exported but internal-only

`atom.zig:308`; the sole reader is `createLeaf` (`atom.zig:403`), inside the same file. Make it private.

### D4. `parse.lexer` / `parse.parser` are public with no external consumer

`parse/root.zig:9-11` re-exports `lexer`, `parser`, `err`. Only `err` is used outside the module (`main.zig:127,140`). `lexer`/`parser` are implementation details; exposing them freezes an internal shape that no caller needs.

### D5. `ztex.render` (free fn) is the legacy pipeline, not the one `main` uses

`root.zig:25` exists alongside `Context.render` (`context.zig:99`). `main.zig:71` calls `ctx.render`; `ztex.render` is now exercised only by `tests/` and `bench/`. It is not dead, but it is the static-metric twin of the real pipeline (see H1) — a second public entry point that differs only by metric source.

---

## AI Slop

### S1. Over-commenting: narration and repeated architecture boilerplate

The four flat-pool modules open with near-identical "superflat / house pattern / provenance source→token→atom→box→drawable" headers (`atom.zig:1-11`, `token.zig:1-7`, `box.zig:1-10`, `draw.zig:1-9`) — one invariant restated four times.

Accessors carry restating doc comments that add nothing over the signature: `pushNode` "Append a single node; returns its index" (`atom.zig:356-357`), `pushToken` "Append a token; returns nothing" (`atom.zig:351-352`). These are noise, not why.

The load-bearing comments (XeTeX measured values, TeX semantics, bit layouts) are worth keeping. The narration and boilerplate are not.

### S2. Q16.16 fixed-point for space widths buys nothing, adds a UB surface

`emToFixed`/`fixedToEm` (`atom.zig:310-318`) pack em widths into `u32` Q16.16. The only values stored are table constants like `1/6`, `5/18`, `6/18` em (`parser.zig:1231-1232,1824,1847,1874`) — fractions that Q16.16 does **not** represent exactly (1/6 = 10922.66…) and f32 represents to the same or better relative error at this magnitude. So the fixed point buys no exactness, but it costs: two conversion helpers, an opaque `u32` payload, and the same unclamped `@intFromFloat` UB hazard as C3.

The `u32 data` field also carries three *different* encodings — Q16.16 (space), Q8.8 (`fraction` thickness), raw enum (`style`/`BigOp`) — for one field type. Inconsistent conventions, more cognitive load, more conversion sites.

### S3. Char-specific state bled into the generic `Box` AoS

`Box` (`box.zig:55-92`) carries `cp`, `style`, `size`, `synthetic`, `bigop_form`, `disp_advance`, `disp_ic` — seven fields read only for `.char` boxes — on every `.rule`/`.glue`/`.strut`/`.hbox`/`.vbox`/`.script` box. A fraction or radical layout allocates many rule/glue/hbox boxes, each paying ~30 dead bytes and the cache cost of the larger AoS. The file advertises "fixed-size AoS, no per-node allocation" as a pure win, but specialized state has accumulated in the common struct.

`disp_advance`/`disp_ic` are set in exactly one place (`layoutOp`) and read in exactly one (`layoutOpLimits`); they belong in a per-char side table keyed by box index, not on every box.

### S4. `TODO(macros)` reserved slot — YAGNI

`font.zig:463-464` reserves an empty `FontContext` field for a future macro table, with a comment admitting "nothing else is needed now". Dead weight; delete until the feature exists.

### S5. `isParseError` re-enumerates the parse error set by hand

`main.zig:92-110` hardcodes all 13 parse-error names because the facade erased the typed error (H2). This is the classic slop failure mode: the same list exists in `parse.Error` and in `main`; they will drift. The fix is H2's (thread the typed error), which deletes the duplicated list.

---

## Simplification

These are the highest-leverage structural cleanups, ordered by payoff.

### SIM1. Collapse the two render pipelines into one

Give `layout.render` a `metrics: FontMetrics` parameter (or add `renderWith`), and make `Context.render` call it instead of inlining the entire body (`context.zig:106-125` duplicates `layout/root.zig:26-48`: box-list init, three reserves, layout call, flatten, bounds copy). Deletes ~15 duplicated lines, removes H1, and makes the metric source explicit.

### SIM2. Replace `FontMetrics`'s function-pointer indirection with a closed union

`FontMetrics` (`metrics.zig:90-110`) is four fn pointers + an opaque `?*anyopaque`, abstracting over exactly two concrete implementations: the static tables and the `Context` font hook. A `union(enum) { static: StaticTables, font: *font.FontContext }` gives the same two cases with:
- no `?*anyopaque` → no `@ptrCast(@alignCast)` → C1's const-lie disappears,
- no hand-installed `glyph`/`glue`/`glyphEstimate` fn pointers to forget,
- compile-time exhaustiveness instead of "did you set all four pointers".

This is the root-cause fix for C1.

### SIM3. Drop the Q16.16 machinery; store space width as an f32 bitcast

Delete `emToFixed`/`fixedToEm` (`atom.zig:310-318`) and store `@bitCast(@as(u32, em))` in `space.data`. Removes S2, removes a public UB surface, and is *more* precise for arbitrary em values (f32 roundtrip beats Q16.16 truncation). One encoding fewer.

### SIM4. Move char payload out of the common `Box`

Split `Box` into the shared header (`kind`/`width`/`height`/`depth`/child-refs/span) and a char-specific side table (`cp`, `style`, `size`, `synthetic`, `bigop_form`, `disp_advance`, `disp_ic`), indexed by box index and only allocated/read when `kind == .char`. Shrinks the common struct ~30 bytes (S3) and removes the "rule box can carry a bogus `cp`" class of bug.

### SIM5. Fold `token.zig` into `atom.zig`

`token.zig` is 54 lines and its only public types (`Span`, `Token`, `Tag`) are already re-exported by `atom` (`atom.zig:16-20`) "so consumers import only ztex.atom". If that is the goal, make it true: move the types and delete the forwarding layer, which also removes the `atom.Tag` (node) vs `atom.TokenTag` (token) vs `token.Tag` name collision.

### SIM6. Fix or delete the reserve bound comment

`parse/root.zig:32-35` claims `2·(tokens+1)` is an exact node-pool bound ("never reallocates"), which is false — one token can expand to several nodes (see L1). Either state it as a heuristic ("reserve a reasonable over-bound; the pool grows if exceeded") or drop `Ast.reserve` and let the ArrayLists grow — the win is negligible either way, the false invariant is the cost.

---

## Prioritized cleanup queue

1. **SIM2 + SIM1** — kill C1 and H1 at the root (opaque cast + duplicated pipeline).
2. **SIM3** — delete Q16.16, kill C3's twin UB surface.
3. **SIM4** — shrink `Box`, remove dead char state from non-char boxes.
4. **D1/D2/D3** — delete `null_span`, `null_child` (+ its tautological test), privatize `null_node`.
5. **SIM5, D4** — fold `token.zig`, unpublish `parse.lexer`/`parse.parser`.
6. **S1, S4, SIM6** — trim narration/boilerplate, drop the `TODO(macros)` slot, fix the reserve comment.

