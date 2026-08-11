# Font infrastructure: src/font.zig (OTF/TTF parser, embedded LM fonts, FontContext)

Date: 2026-08-13. Scope: new files only — `src/font.zig`, `src/fonts/*.zig`. The
existing hard-coded metric tables (`src/layout/metrics.zig`) and all other
modules are UNTOUCHED; wiring them to this module is the follow-up (F2).

## Why

Fixed font metrics aren't viable for a math renderer; the system must handle
multiple fonts gracefully. The common use case is: initialize a context ONCE,
then render many small equations. `FontContext` exists for exactly that — it
holds loaded/parsed font faces plus metric caches, and its `metrics()` calls
are the primary metric source (replacing the static table's role).

## Files

| file | content | size |
|---|---|---|
| `src/font.zig` | sfnt parser (`FontFace`), `FontContext`, tests | ~830 lines |
| `src/fonts/lmmath.zig` | aggregator: `pub const lmmath_otf = part0.bytes ++ … ++ part4.bytes;` | 539 B |
| `src/fonts/lmmath/part0..4.zig` | Latin Modern Math bytes, `pub const bytes = [_]u8{ … };` (733,736 B total) | 5 × ~880 KB |
| `src/fonts/lmroman_regular.zig` | LM Roman 10 regular, `pub const lmroman10_regular_otf` (111,536 B) | ~670 KB |
| `src/fonts/lmroman_italic.zig` | LM Roman 10 italic, `pub const lmroman10_italic_otf` (118,828 B) | ~713 KB |

Sources (nix store, this machine):
- `/nix/store/d7aacxb9a8jfjgpkd0hk11wksh3sx9fr-lmmath-1.959/share/fonts/opentype/latinmodern-math.otf`
- `/nix/store/whmfn34z3b5hdihz7zqinlwkw5gv9l6g-lmodern-2.005/texmf-dist/fonts/opentype/public/lm/lmroman10-{regular,italic}.otf`

Notes on the embed format:
- Bytes are `[_]u8` comptime arrays (per the task: raw byte const arrays, no
  `@embedFile`). 4096-byte chunks joined with `++`; zig fmt collapses the
  chain to one line, so each file is a single line carrying a
  `// ziglint-ignore: Z024` marker (line-length rule).
- The lmmath file is split into 5 parts because jj refuses to snapshot new
  files over 1 MiB (`snapshot.max-new-file-size`); each part is ~880 KB of
  source (< 1 MiB), byte-exact against the source OTF (verified).

## API

### `FontFace` — one parsed font

```zig
pub const FontFace = struct {
    pub fn fromBytes(gpa: std.mem.Allocator, data: []const u8) !FontFace // owns a copy
    pub fn deinit(self: *FontFace) void                                  // no-op for arena-managed faces
    pub fn unitsPerEm(self: *const FontFace) u16                         // head.unitsPerEm
    pub fn ascenderEm(self) f32                                          // hhea.ascent / upem
    pub fn descenderEm(self) f32                                         // -hhea.descent / upem (positive)
    pub fn lineGapEm(self) f32                                           // hhea.lineGap / upem
    pub fn typoAscenderEm / typoDescenderEm / typoLineGapEm / winAscentEm / winDescentEm // OS/2 (0 when absent)
    pub fn glyphIndex(self, cp: u21) ?u32                                // cmap lookup (format 12, then 4)
    pub fn advanceEm(self, gid: u32) f32                                 // hmtx / upem (em units)
};
```

Parser scope: sfnt container + `head`, `hhea`, `hmtx`, `cmap` (formats 4 and
12), `maxp`, `OS/2` (optional). Both OTF (`OTTO`, CFF) and TTF
(`0x00010000`, glyf) scalers are accepted — only metric tables are read,
never outlines. Big-endian, bounds-checked reads throughout; table checksums
deliberately not verified (optional per spec). Errors:
`FontError{InvalidSfnt, MissingTable, InvalidTable, UnsupportedCmap}`.
The `gpa` field is null for context-owned faces so `deinit` is a no-op
(arena frees everything).

### `GlyphMetrics`

```zig
pub const GlyphMetrics = struct { width: f32, height: f32, depth: f32, line_gap: f32 };
```
All in points at the requested size.

### `FontContext` — the "init once, render many" core

```zig
pub const FontContext = struct {
    pub fn init(gpa: std.mem.Allocator) !FontContext       // loads embedded LM Math + LM Roman (regular + italic)
    pub fn deinit(self: *FontContext) void                 // arena release; invalidates all faces/paths
    pub fn loadFromFile(self, gpa, path) !*FontFace        // parse + cache by path (deduped)
    pub fn findFont(self, name: []const u8) ?[]const u8    // disk discovery (see below); memoized
    pub fn mathFace(self) *FontFace                        // embedded LM Math
    pub fn romanFace(self, italic: bool) *FontFace         // embedded LM Roman regular/italic
    pub fn metrics(self, face, cp: u21, size_pt: f32) GlyphMetrics  // cached per (face, cp)
};
```

- `init` loads the three embedded fallbacks (LM Math is the default math
  face; the Roman faces serve `\text`/`\mathrm`). File I/O uses the std
  single-threaded `Io` instance (`std.Io.Threaded.global_single_threaded`)
  — font loading/discovery is one-shot and needs no concurrency; `deinit`
  is `arena.deinit()` + nothing else.
- A `// TODO(macros)` comment reserves the slot where F2 will hang the macro
  table (name → expansion).
- `metrics`: height/depth/line_gap come from the face's OWN nominal extents
  (hhea ascender/descender/lineGap) — real font data, NOT the hard-coded
  table; these bounds hold for every glyph. Width is the glyph's real hmtx
  advance. A codepoint with no glyph gets a 0.5 em advance with the same
  nominal extents (caller decides how to draw it).
- `findFont` search order: explicit well-known roots
  (`/run/current-system/sw/share/fonts`, `/usr/share/fonts`,
  `/usr/local/share/fonts`, nix profiles) → `$XDG_DATA_HOME/fonts` →
  `$HOME/.local/share/fonts` → `/nix/store` scan (top-level names containing
  "lm"/"font", probing `share/fonts`, depth-limited walk) → `fc-list` output.
  Matching is case-insensitive on the basename or a prefix of it
  ("latinmodern-math" finds "latinmodern-math.otf"). Results AND misses are
  memoized per name; returned paths are arena-owned.
- `envGet` reads `/proc/self/environ` on Linux (no libc dependency); other
  platforms skip the env-based roots.

## Cache design

- One arena owns every long-lived allocation: faces (struct + byte copy),
  `faces` map (path → face), `found` map (name → path, `""` = known miss),
  `metrics_cache` entries, and joined paths. `deinit` is one arena free.
- `metrics_cache: AutoHashMapUnmanaged(CacheKey, GlyphMetrics)` keyed by
  `(face*, cp)`, storing EM metrics (size_pt = 1) so one entry serves every
  size; the query multiplies by `size_pt`. Lookup is O(1); a miss computes
  from the parsed tables (O(log n) cmap + O(1) hmtx) and inserts.
- `metrics()` is infallible by contract: on OOM it skips the insert and
  recomputes next time (`catch |err| switch (err) { error.OutOfMemory => {} }`).
- `loadFromFile` uses the caller's `gpa` for the transient read buffer and
  copies into the arena once; repeated loads are a single map hit.
- Faces never migrate: `*FontFace` pointers (faces map values, math/roman/
  italic fields, cache keys) stay valid until `deinit`.

## Measured values (tests assert these; none guessed)

Measured with fontTools 4.63 on the actual OTFs, cross-checked by a
byte-level python port of this parser (identical offsets/gids/advances):

| metric | LM Math | LM Roman regular | LM Roman italic |
|---|---|---|---|
| unitsPerEm | 1000 | 1000 | 1000 |
| hhea ascender em | 0.806 | 1.127 | 1.125 |
| hhea descender em | 0.194 | 0.290 | 0.290 |
| hhea lineGap em | 0.200 | 0.000 | 0.000 |
| OS/2 sTypo asc/desc/gap em | 0.806 / 0.194 / 0.200 | — | — |
| OS/2 usWinAscent/Descent em | 3.560 / 3.060 | — | — |
| cmap formats | 4 + 12 (+6) | 4 (+6) | 4 (+6) |
| numGlyphs / numberOfHMetrics | 4802 / 4802 | 821 / 821 | 821 / 821 |
| advanceEm('x') | 0.528 | 0.528 | 0.464 |
| advanceEm('n') | 0.556 | — | — |
| advanceEm(U+2211 ∑) | 1.056 | n/a (no glyph) | n/a |
| advanceEm(U+222B ∫) | 0.665 | n/a | n/a |
| metrics(ctx, 'x', 20pt).width | 10.56 | — | — |

(All em values are hmtx/upem or hhea/upem; upem 1000 makes them exact
per-mille. The ∑/∫/x/n advances match the values already in
`notes/fix-lm-metrics.md`.)

## F2 integration: wiring into FontMetrics

The layout module consumes metrics through
`FontMetrics` (src/layout/metrics.zig), a struct of function pointers
(`glyph`, `glyphEstimate`, `glue`) — explicitly designed for swapping in a
real font implementation. The plan:

1. Build a `FontContext` once at startup (or lazily behind a global), and
   construct a `FontMetrics` whose `glyph`/`glyphEstimate` closures call
   `ctx.metrics(face, cp, size_pt)`:
   - math glyphs → `ctx.mathFace()`
   - `\text`/`\mathrm` → `ctx.romanFace(italic)` (italic decided by
     `atom.CharStyle`)
2. `metrics()` returns `GlyphMetrics{width, height, depth, line_gap}` at the
   requested `size_pt`, which maps 1:1 to the existing `Glyph` shape
   (width/height/depth + italic correction — the italic correction still
   needs a source; LM Math's MATH table is not parsed yet, so keep the
   current per-row `ic` or 0 until a MATH-table parser lands).
3. Keep `loadFromFile`/`findFont` for any font the user points at; the
   embedded fallbacks guarantee LM Math + LM Roman exist even with no
   system fonts.
4. The `size_pt/10` scaling convention in `metrics.zig` (em × 10 at 10pt)
   can be dropped for the font path: `metrics()` already returns points at
   the real size.

Regression risk: nominal (hhea) ascent/descent bound all glyphs, so boxes
and the SVG frame stay correct for every glyph — including the ones the
static table estimated. Widths change from the table's LM-Math advances to
the same font's hmtx (identical for covered glyphs; the static table was
already LM-Math-accurate per `fix-lm-metrics.md`).
