# Font integration: layout.FontMetrics → FontContext, ztex.Context

Date: 2026-08-13. Scope: `src/layout/metrics.zig` (FontMetrics wiring),
`src/context.zig` (new), `src/root.zig` (export), `src/main.zig` (`--font`).
`src/font.zig` and all layout rules were NOT touched.

## What changed

`FontMetrics` (the function-pointer metric interface layout consumes) now
carries two new fields:

```zig
pub const FontMetrics = struct {
    font: ?*anyopaque = null,                 // the FontContext, opaque
    font_glyph: ?*const fn (self: *const FontMetrics, cp: u21,
                            style: atom.CharStyle) ?Glyph = null, // hook
    glyph: *const fn (self: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph,
    glyphEstimate: *const fn (self: *const FontMetrics, cp: u21, style: atom.CharStyle) Glyph,
    glue: *const fn (self: *const FontMetrics) GlueParams,
};
```

`glyph` and `glyphAt` (the size-aware variant layoutChar/layoutText use)
check the hook BEFORE the static tables; `staticGlyph` is the old table
lookup, made `pub` so the hook can reuse the rows' italic corrections. When
`font` is null (the bundled `metrics.default`), behavior is bit-for-bit the
previous static-table path — the layout/tests modules are untouched and all
their goldens pass unchanged.

### How FontMetrics reaches the FontContext (and why it is opaque)

`ztex.Context` (src/context.zig) owns a `font.FontContext` and wires it:

```zig
var c: Context = .{ .gpa = gpa, .fonts = fonts, .fm = metrics.default };
c.fm.font = @ptrCast(fonts);
c.fm.font_glyph = &contextGlyph;
```

The hook (`contextGlyph` in context.zig) casts the opaque pointer back to
`*font.FontContext` and serves real metrics:

- width  = `FontContext.metrics(face, cp, 10.0).width`  — the face's cached
  hmtx advance × 10pt (10pt base, so the layout's `s(v, size_pt)` scaling
  applies unchanged; LM is a 10pt design, so script sizes scale linearly)
- height = the face's OWN nominal hhea ascender × 10pt
- depth  = the face's OWN nominal hhea descender × 10pt
- italic correction = the static row's value (LM Math's MATH table is not
  parsed yet; sup/sub placement and the post-op tail keep today's values)

Style `.roman` (`\text`, `\mathrm`) selects `romanFace(false)` = LM Roman
regular; every other style selects `mathFace()` = LM Math — matching the
SVG's own font-family (Latin Modern Math for math runs, Latin Modern Roman
for upright runs).

The pointer is `?*anyopaque` rather than `?*const FontContext` for two
reasons, both constraints of the edit list:

1. **Module boundary.** `metrics.zig` lives in the `ztex.layout` module,
   which has no `font` import, and Zig 0.16 rejects relative imports that
   leave the module directory (`@import("../font.zig")` → "import of file
   outside module path"). build.zig is out of scope, so the concrete type
   cannot reach metrics.zig; the hook pattern keeps the concrete cast in
   context.zig, which (ztex module, same directory) imports font.zig
   directly.
2. **Cache mutation.** `FontContext.metrics()` is `*FontContext` (it fills
   the per-(face, cp) cache), so the stored pointer is non-const.

### Why the FontContext is heap-allocated inside Context

`Context.init` first stored the FontContext by value and set
`fm.font = &self.fonts`. That dangles: `return c` is NOT guaranteed to place
`c` at the caller's result location in this toolchain — `&c.fonts` pointed
at `init`'s stack frame, which stayed intact until the next call from
`main` reused that frame. `loadFromFile` (the `--font` path) was that next
call and clobbered the stale FontContext, producing a hash-map "incorrect
alignment" panic in `metrics()` on the first render. Without `--font` the
dead frame survived untouched and the bug stayed hidden — a textbook
stack-reuse heisenbug, isolated with a standalone repro (plain
`FontContext.init → loadFromFile → metrics` works; the by-value self-pointer
wrapper fails).

Fix: `init` heap-allocates the FontContext (`gpa.create`) and `fm.font`
points at the heap object, so the pointer is stable across the by-value
`init` return and any Context copies. `deinit` frees the arena then the
allocation; a Context must be deinit'd exactly once.

## The fallback chain: font → static table → estimate

Layout consumes metrics through `glyphAt(...) orelse glyphEstimate(...)` and
`glyph(...)`:

1. **Font** — hook installed, face maps the codepoint: real hmtx advance +
   nominal hhea extents (cached per (face, cp) in the FontContext).
2. **Static table** — face does not map the codepoint (e.g. ▹ ⤒ Ϝ ⧫ — LM
   Math lacks them; the table keeps their measured CM widths) or no hook:
   the bundled LM-advance tables, including the roman/7pt/5pt optical bands.
3. **glyphEstimate** — the deterministic 0.5em/0.7em/0.2em fallback, as
   before.

A codepoint the font maps but the table lacks (e.g. astral math alphanumerics
U+1D400, which LM Math covers) resolves from the font with a 0 italic
correction — strictly better than the old estimate.

## Context API

```zig
pub const Context = struct {
    gpa: std.mem.Allocator,
    fonts: *font.FontContext,          // heap-owned; see above
    fm: metrics.FontMetrics,           // wired at init
    pub fn init(gpa) !Context
    pub fn deinit(self: *Context) void
    pub fn loadFont(self: *Context, gpa, path) !*font.FontFace  // cached by path
    pub fn render(self: *const Context, gpa, src, size_pt) !draw.DrawList
};
```

`render` is the font-backed full pipeline (parse → layout with `&self.fm` →
flatten), mirroring `ztex.render` — which stays untouched for one-shot use
and for tests. `ztex.Context` is re-exported from root.zig alongside
`ztex.render`.

`main.zig` now always renders through a Context and accepts `--font <path>`
(repeatable) to load extra faces into the context's cache (deduped by path;
the metrics still come from the embedded LM faces, which are also what the
SVG names as its font-family).

## Verification

- `zig build run -- -i '\sum_{i=1}^{n} \frac{x_i}{n} + \int_0^1 x\,dx'
  -o out.svg -s 20 -b white` renders via the Context; the SVG is identical
  to the static-table baseline except f32 print noise ≤ 4e-6 pt (e.g.
  `32.676003` → `32.676`) — the font-backed advances (LM Math hmtx) equal
  the table's LM advances: x = 0.528em → 10.56pt at 20, ∑ = 1.056em →
  21.12pt, ∫ = 0.665em → 13.3pt (display scale unchanged).
- `\triangleright` (U+25B9, absent from LM Math) renders gracefully with the
  static-table CM width 10.00004pt at 20pt — NOT the 0.5em nominal — and
  U+1F600 falls through to glyphEstimate (tests in context.zig).
- Init-once-render-many: the context test renders "x" twice and asserts
  `fonts.metrics_cache.count() == 1` — the second render hit the cache.
- `zig build run -- -i x --font <lmroman10-regular.otf>` loads the extra
  face and renders (this exercised and fixed the stack-reuse bug above).
- Static path: `zig build test` — all five module suites pass (atom 6,
  parse 35, layout 38, ztex 17 incl. the new context tests, tests 18); the
  regression goldens (drawn through `ztex.render`) are unchanged.

## Known/expected deltas vs the static tables

- Widths match to f32 precision; the table stored rounded decimal copies
  (em × 10) of the same LM advances, the font path computes
  `hmtx ÷ upem × 10` — identical values, different last-bit rounding.
- `Glyph.height/depth` now report the face's nominal hhea extents (LM Math
  0.806/0.194em, LM Roman 1.127/0.290em) instead of the CM design box.
  Layout does not use these for char boxes (it boxes by the measured ink
  table × drawn size), so no rendered geometry changes from them.
- `\text`/`\mathrm` letters now measure from LM Roman regular (0.528em x,
  0.556em h, …); the table used LM Math advances for the roman rows. For
  most ASCII letters the two fonts agree to the printed precision; any
  difference is a real-font improvement and an intended output change.
- Italic corrections remain the static rows (no MATH-table parser yet).
