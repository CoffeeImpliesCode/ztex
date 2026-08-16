# ztex — Adversarial Audit Round 2

Five read-only lenses (2026-08-16), each with a full notes file:
- API complexity → notes/audit-api2.md
- Functionality gaps → notes/audit-functionality2.md
- Generality / embeddability → notes/audit-generality2.md
- Magic numbers / hard-coded data → notes/audit-magic-numbers2.md
- AI slop markers → notes/audit-slop2.md

Severity: **C** = soundness/remote-crash, **H** = correctness/contract,
**M** = design/cleanup, **L** = docs/minor. `[A1]` = fixed in round 1.

---

## C — critical

### C1. No recursion-depth limit → stack overflow on untrusted input
`src/parse/parser.zig` (parseRow/parseGroup/parseCommand/parseDelimiter mutual
recursion; only `delim_depth`, a correctness counter, parser.zig:664) and
`src/layout/layout.zig` (every layout* fn recurses per node). A few-KB input
of `\frac{\frac{...}}` or `{{{{...` nests ~1 level/byte → SIGSEGV; Zig cannot
catch it → host process dies. **Fix:** depth counter in Parser returning
`error.NestingTooDeep` (new parse.Error variant); matching depth guard in
layout for hand-built ASTs.

### C2. `Ast.child` @panic + BoxList asserts on the documented hand-built-AST path
`src/atom.zig:491` `@panic("Ast.child: child index out of bounds")`;
`src/layout/box.zig:161-190` asserts. layout.render documents "give it any
atom.Ast (ztex.parse or hand-built)" — a malformed hand-built tree aborts the
process. **Fix:** validate the tree once at the `layout.render` boundary
(children counts + depth) → `error.InvalidAst`; keep the panics as internal
invariant checks.

---

## H — high

### H1. Context is not thread-safe; undocumented
`src/context.zig` render mutates `FontContext.metrics_cache`
(std.AutoHashMapUnmanaged, font.zig:487-501) + arena on first render; two
threads on one Context = data race. The static facade `ztex.render` IS
shareable. **Fix:** document one-Context-per-thread (or external mutex).

### H2. `max_source_bytes` under-guards the ~2× node pool
`src/parse/root.zig:34` caps at `maxInt(u32)` but nodes ≈ 2× tokens: a
~2.15 GB input overflows `@intCast(nodes.len)` (atom.zig:430) → panic /
ReleaseFast truncation. **Fix:** cap at `maxInt(u32)/2` or guard nodes.len
before the cast.

### H3 (slop). Audit-issue IDs leaked into 12 source comments
`(SIM1/H1)`-style labels in context.zig:21-22,112, font.zig:18, main.zig:49,
76,130, root.zig:27,39, layout/metrics.zig:102,116, layout/root.zig:20,
parse/error.zig:81. Meaningless to future readers. **Fix:** strip the
parenthetical IDs, keep the explanations.

### H4 (slop). Dead pub re-exports
`pub const Style` (root.zig:14 AND layout/root.zig:14 — zero consumers),
`pub const box` (layout/root.zig:10), `pub const context` (root.zig:14).
**Fix:** delete.

---

## M — medium

### M1. Duplicated facade plumbing
`src/root.zig:34-41` vs `src/context.zig:108-113` — identical parse/deinit/
error-mapping bodies + the same design comment twice. **Fix:** one private
`renderPipeline` helper; both facades become 3-line wrappers.

### M2. Redundant `gpa` param on Context.render
`context.zig:102-106` takes gpa; `Context` already owns one (context.zig:63).
main.zig passes it three times; mismatched-allocator bug risk. **Fix:** drop
the param, use `self.gpa`.

### M3. `catch error.OutOfMemory` swallows future non-OOM layout errors
`src/root.zig:41`, `src/context.zig:91` — layout.render's error set is
anyerror ("only fails on allocation" is an assumption). **Fix:** narrow
layout.render to `error{OutOfMemory, InvalidAst}!DrawList` (after C2) and
match both arms at the catches.

### M4. `svg.writeFile` hardcodes cwd; fs in the library module
`src/svg.zig:168` `std.Io.Dir.createFile(.cwd(), ...)` — hosts can't choose
a directory; sandboxed hosts (WASM) can't use the module. **Fix:** take a
`std.Io.Dir` parameter; `svg.render` stays pure.

### M5. No exact ink-bounds API; heuristic svg margins
`src/layout/draw.zig:85-90` exposes box extents only; `src/svg.zig:63-71`
adds margins (0.08×max_size + 0.2em) because box under-binds ink. **Fix:**
compute a true ink bbox in flatten, expose `DrawList.bounds()`; svg margins
become exact.

### M6. Magic-number drift: same constant in two+ places
- supdrop/subdrop: metrics.zig glueImpl (2570-2571) AND layout.zig:2836-2837.
- scriptfactor 0.7/0.5: metrics.zig (2577-2578) AND layout.zig 490-491,
  1223, 2720-2723, 3497-3499.
- big-op advances/ics: metrics table (2608-2612) AND layout.zig BigOpInk
  (3167-3224) AND display branch (3229-3245) — three copies.
- 2.392 (v6 ink): layout.zig:48, 2088, 1974/1987, parser.zig:1973.
- axis 2.5: glueImpl AND layout.zig:898, 3128.
**Fix:** single source in GlueParams; remove the re-literals.

### M7 (slop). Dead/legacy public fns
- `lookupAscii` (metrics.zig:2518) — only its own tests; the O(1) ASCII fast
  path is never wired into layoutChar. **Fix:** wire it into glyphAt's
  `.static` arm, or make private.
- `parseColor` (svg.zig:220) — stale "legacy wrapper", only tests use it;
  main uses parseColorChecked. **Fix:** delete.
- 9-10 FontFace em-extent getters (font.zig:267-318) — test-only pub.
  **Fix:** privatize.
- `unreachable` in fail() (parser.zig:722) — safe by construction; replace
  with a real error arm.
- Unused `fm` params forcing `_ = fm` (layout.zig:2638 opTailIc, 4181
  textEmitMark). **Fix:** drop the params.

### M8 (slop). Duplicated fraction comment + S1 narration remainder
- layout.zig:3489-3506 — the "one style level down" rule narrated twice.
- S1 (deferred from round 1): atom.zig:1-11 header + 16-20 re-narration;
  box.zig:1-10 + draw.zig:1-9 restating headers; restating accessor docs
  (atom.zig:423-439 pushToken/pushNode, font.zig getters, parse/error.zig
  70/82/97).
**Fix:** merge/trim, keep the load-bearing (TeX-measured) comments.

---

## L — low (documented, mostly non-blocking)

- DrawList ink bounds undocumented (api L2) → covered by M5.
- err_info out-param ceremony tripled (api L1) → fixed by M1.
- Context non-copyable by doc only (api L3, general L2).
- svg.render anyerror → closed set (general L3) — fold into M4 work.
- Zig 0.16.0 exact pin + zg from codeberg, no C ABI (general M4): document
  the version contract; optional addStaticLibrary + C header for non-Zig
  hosts; vendor zg for offline.
- ~2.1 MB embedded fonts pulled by any ztex-facade consumer (general L4):
  document which module pulls it (layout-only hosts are free).
- No README/host-facing docs (general L5): allocator contract,
  thread-safety, lifetime rules, error contract, version pin.
- Stale "prior attempt" narration in firstCodepoint doc (layout.zig:496-499).
- Top-level style hardcoded `.display` (layout/root.zig) — hosts can't pick
  text style; add a style param to layout.render (recommended API addition).
- Magic: glyphEstimate fallback 0.5/0.7/0.2em (metrics.zig:2525-2537) is the
  only deliberately-wrong value in the render path — replace with an hmtx
  advance lookup when the font arm is active.
- Magic: the whole baked-metrics question — GlueParams + thousands of
  per-glyph values are Latin Modern measured-once; a runtime MATH-table query
  via font.zig is the eventual fix (large; the `.font` arm already exists).

---

## Functionality gaps (feature roadmap, NOT defects)

Top-5 by value (full table in notes/audit-functionality2.md; katex-features.md
is stale — ~10 features landed since): **\overset/\underset/\stackrel**,
**\phantom/\hphantom/\vphantom/\smash**, **\hspace/\kern/\mkern + \:/\ /**,
**\underbrace/\overbrace**, **\boxed + \color/\textcolor**. Then \dbinom/
\tbinom, \hline/\arraystretch, \tag, atom-class overrides, \coloneqq family,
\bigoplus/\iint families, \widehat/\widetilde, stretchy accents, colon
relations, \textit/\textbf family, \mathop..\mathinner.

---

## Triage queue (this pass)

1. **F1 parse** — C1 depth guard, H2 node-pool cap, parser fail() unreachable,
   slop IDs/comments in parse/*.
2. **F2 facade/context/main/font** — M1 renderPipeline dedupe, M2 gpa drop,
   H4 dead re-exports, FontFace getters private, H1 thread-safety doc,
   slop IDs in these files.
3. **F3 svg** — M4 writeFile Dir param, closed error sets, M7 parseColor
   delete; main.zig writeFile call site (contract).
4. **F4 layout/atom** — C2 tree validation at boundary, M3 error-set narrow,
   M6 magic drift de-dup, M7 lookupAscii wire, M8 comment merge/trim,
   M5 ink-bounds API, S1 headers.

Deferred: feature roadmap (above), runtime MATH-table query, C ABI, README.
