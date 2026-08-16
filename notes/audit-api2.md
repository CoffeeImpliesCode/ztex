# API audit (lens: API complexity)

Targets: src/root.zig, src/context.zig, src/layout/root.zig, src/svg.zig,
src/parse/root.zig, src/font.zig. Read-only; no zig gates run. ~35 tool
calls; every claim has file:line.

## SIM1 verification — only ONE render pipeline remains: CONFIRMED

Exactly four `pub fn render` in the repo:
- src/layout/root.zig:24 — `layout.render` (the single shared layout body)
- src/root.zig:28 — facade `ztex.render` → calls layout.render (root.zig:41)
- src/context.zig:101 — `Context.render` → calls layout.render (context.zig:113)
- src/svg.zig:52 — `svg.render` (serializes a DrawList; not a pipeline)

Both facades route through `layout.render` with an explicit `FontMetrics`
argument; the metric source is the closed union (context.zig:61-81 builds
the `.font` arm; layout/root.zig:23-27 documents the contract). No
second/legacy layout body exists. The facades differ only in `fm`, but the
plumbing around it is duplicated verbatim (~20 lines): parse + `defer
ast.deinit()` + the `catch error.OutOfMemory` mapping and its comment
(root.zig:34-41 vs context.zig:108-113). SIM1 collapsed the pipelines but
left the wrapper duplication.

## Findings

### M1 — Duplicated facade plumbing; error-mapping comment in two places
- src/root.zig:34-41 and src/context.zig:108-113: identical bodies (parse,
  defer ast.deinit, `catch error.OutOfMemory`) with the same design comment
  (root.zig:36-40, context.zig:110-112). Any change to the error mapping or
  the "layout only fails on allocation" invariant must be made twice.
- Fix: one private `fn renderPipeline(gpa, fm, src, size_pt, err_info)`
  shared by both facades; the comment lives once. `ztex.render` becomes a
  3-line wrapper passing `&layout.metrics.default`; `Context.render` passes
  `&self.fm`.

### M2 — `Context.render` takes a redundant `gpa`; Context owns one already
- src/context.zig:63 (`gpa` field, used only by deinit at :86-88) vs the
  render signature src/context.zig:102-106 (its own `gpa` param).
- main.zig passes the same allocator three times: `Context.init(gpa)`
  (main.zig:72), `ctx.render(gpa, …)` (main.zig:81), `svg.writeFile(gpa, …)`
  (main.zig:91). The split invites a mismatched-allocator bug (deinit frees
  via the field, DrawList frees via the param) that nothing checks.
- Fix: drop the `gpa` param from `Context.render`; use `self.gpa`. Callers
  already store the allocator in the context.

### M3 — Dead public surface: re-exports with no external consumer
- src/root.zig:14 `pub const context = @import("context.zig")` — the module
  is never referenced (consumers use `ztex.Context`, root.zig:18). Grep for
  `ztex.context` across src/ matches only the module's own doc comment.
- src/layout/root.zig:10 `pub const box` — no consumer: layout.zig:11 and
  draw.zig:12 import box.zig directly, and nothing else references
  `layout.box` / `ztex.layout.box`.
- src/layout/root.zig:14 `pub const Style = layout.Style` — no consumer
  anywhere in src/ (grep `layout.Style|ztex.Style` → 0 hits).
- src/svg.zig:220 `pub fn parseColor` — test-only (svg.zig:374-377); the
  only production caller uses `parseColorChecked` (main.zig:68). The
  lenient variant exists solely so tests can avoid an error union.
- src/parse/root.zig:34,39 `max_source_bytes`/`sourceTooLong` — pub, but
  only `parse()` and in-file tests use them (parse/root.zig:49, 82-88).
  Justified by the "unit-test the 4 GiB boundary" comment, dead externally.
- Fix: delete the three re-exports; make `parseColor`/`sourceTooLong`/
  `max_source_bytes` private or move their tests to the checked variants.
  Keep `pub const parse/atom/layout/draw/svg` (root.zig:9-13): all have
  real consumers (main.zig:2-13, bench/main.zig:10, svg.zig:10-12,
  context.zig:29-34, tests/regression.zig:252).

### M4 — FontFace accessor surface is test-only (10 pub fns, 0 external callers)
- src/font.zig:268-340: `unitsPerEm`, `ascenderEm`, `descenderEm`,
  `lineGapEm`, `typoAscenderEm`, `typoDescenderEm`, `typoLineGapEm`,
  `winAscentEm`, `winDescentEm` (9 em-extent getters) + `hasGlyph` — all
  ten have zero external callers; `glyphIndex`/`advanceEm` ARE used
  (context.zig:49, font.zig:525-528).
- font.zig's only importer is context.zig (context.zig:30), which uses
  `FontContext.init/deinit/mathFace/romanFace/metrics` and `glyphIndex`
  only (context.zig:49). The nine em-extent getters + `hasGlyph` are
  consumed solely by font.zig's own tests (font.zig:548-552, 573-586) and
  `computeEmMetrics` (font.zig:521-523, which could read the private
  fields directly).
- Fix: make them private (getters over already-private fields) or
  explicitly document font.zig as a reusable library. As-is, ~50 lines of
  doc'd public API serve no host.

### M5 — `Text.bytes` has two ownership domains discriminated by a bool
- src/layout/draw.zig:32-35: `Text.bytes` is a slice into `src` when
  `synthetic == false`, or arena-duped into `DrawList.glyph_arena` when
  true; the flag is set deep in layout (src/layout/box.zig:94). A host that
  copies/moves draw items must know the flag to free — or not — bytes, and
  the DrawList must outlive the source string (documented at root.zig:22-24,
  context.zig:98-100).
- Fix (host API hardening): make every glyph run arena-owned (uniform
  lifetime: DrawList owns everything; src need not outlive it) or expose a
  `DrawList.ownsSourceSlice()` helper / doc example so hosts don't
  hand-roll the `synthetic` discipline.

### L1 — `err_info: ?*parse.Info` optional out-param on three public fns
- src/parse/root.zig:48, src/root.zig:32, src/context.zig:106: same
  nullable-pointer out-param + "filled before the error is returned"
  contract. Callers must pre-declare `var err_info: ztex.parse.Info =
  undefined;` (main.zig:80) and remember the "untouched on success / filled
  on error" rule. This is a defensible Zig idiom (errors carry no payload)
  but the ceremony is tripled by the M1 duplication.
- Fix: with M1's shared helper the contract is documented once; keep the
  typed `parse.Error!DrawList` return (main.zig:81-89 depends on the
  exhaustive match) — do NOT add a result-struct without touching that.

### L2 — DrawList ink bounds are unlabeled box extents
- src/layout/root.zig:50-52 copies the root box's width/height/depth into
  pub fields on DrawList (draw.zig:96-105). Semantics ("box extents, not
  drawn-ink bounds") are undocumented; the frame-fit lens
  (notes/fix-frame-fit.md) shows box h/d can miss drawn ink.
- Fix: document the fields as box extents, or compute true ink bounds in
  `flatten` (draw.zig:135) and expose them as a `bounds()` accessor —
  whichever the frame-fit fix lands on.

### L3 — Context ownership ceremony: heap-allocated fonts, "deinit exactly once"
- src/context.zig:72-80 (`init` heap-creates FontContext so the `fm` union
  arm's pointer stays stable), :86-89 (`deinit` destroys it). Rationale is
  documented (context.zig:10-18) and correct, but a by-value `Context` copy
  shares `fonts`/`fm`; nothing detects double-deinit or use-after-deinit
  (`self.* = undefined` is the only guard, :89).
- Minor: acceptable given the doc; note in the minimal API that hosts
  should treat Context as non-copyable (make `fonts` private with
  accessors).

## Minimal host API sketch

Current host journey (main.zig:72-94): `Context.init(gpa)` →
`ctx.render(gpa, src, size, &err_info)` → `svg.writeFile(gpa, io, path,
&dl, opts)` — three calls, four allocator/io args, one out-param.

Target:
1. `Context.init(gpa)` — unchanged (one allocator, once).
2. `Context.render(src, size_pt, err_info)` — gpa dropped (M2).
3. SVG: keep `svg.render(gpa, &dl, opts) ![]u8` + `svg.writeFile(...)`
   (already clean; writeFile's `io` param is the 0.16 idiom, svg.zig:165).
4. Ink bounds: `DrawList.bounds()` returning {width, height, depth} with
   documented box-vs-ink semantics (L2).
5. One-shot hosts (bench, tests): keep `ztex.render` as the static-table
   facade but implement it as the M1 shared helper + 3 lines.

Optional: `ztex.renderSvg(gpa, src, size, opts, err_info) ![]u8` for
"string in, string out" hosts (main.zig shrinks to ~10 lines); not
required — the DrawList → svg stage split suits geometry-needing hosts.

## Top-5 by payoff

1. M1 — Dedupe facade plumbing into one `renderPipeline` (root.zig:34-41 +
   context.zig:108-113): kills ~20 duplicated lines + the double error-map
   comment; single place to fix if layout's error set ever narrows.
2. M2 — Drop the redundant `gpa` from `Context.render` (context.zig:103):
   removes a real mismatched-allocator footgun and trims every call site.
3. M3 — Delete dead re-exports `pub const context` (root.zig:14),
   `pub const box`/`pub const Style` (layout/root.zig:10,14) and fold
   `parseColor` (svg.zig:220) into tests of `parseColorChecked`: shrinks
   the surface a host must read, zero behavior change.
4. M4 — Privatize the test-only FontFace em-extent accessors
   (font.zig:268-340): ~50 lines of unused public API; either document the
   module as a library or hide the getters behind the fields.
5. M5 — Resolve `Text.bytes` dual-ownership (draw.zig:33-35): make glyph
   runs uniformly arena-owned so hosts don't track the `synthetic` flag and
   `src` lifetime; the DrawList already has the arena, only the flag
   dispatch and the two callers in layout change.
