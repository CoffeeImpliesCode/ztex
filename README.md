# ztex

A LaTeX math renderer for Zig 0.16. Parses LaTeX math into a superflat atom
tree, lays it out into a painter-ordered draw list, and serializes that to SVG
or rasterizes it to a PPM/PGM bitmap. It depends on `zg` alone, for Unicode
width, grapheme segmentation, and text decoding.

This file is the host-facing contract. For internal architecture see
`AGENTS.md`; the two adversarial review passes are `audit.md` and `audit2.md`.

## Version contract

- **Zig 0.16.0 exactly.** `build.zig.zon` pins `minimum_zig_version = "0.16.0"`.
  This code uses 0.16 APIs that do not exist in earlier or later point releases
  (`std.Io` threading, unmanaged containers, the `std.Build` module API). A
  different 0.16.x may build; an earlier or later minor will not.
- **`zg` v0.16.2**, fetched from codeberg.org and content-hashed in
  `build.zig.zon`. The fetch needs network on a cold cache; `zig-pkg/` holds the
  unpacked package and is gitignored.

There is no C ABI. The package exposes Zig modules only.

## Modules

| Module | Root | Pulls the embedded fonts? |
| `ztex.atom` | `src/atom.zig` | no |
| `ztex.parse` | `src/parse/root.zig` | no |
| `ztex.layout` | `src/layout/root.zig` | no |
| `ztex.svg` | `src/svg.zig` | no |
| `ztex` (facade) | `src/root.zig` | **yes** |

Importing `ztex` links ~0.9 MiB of embedded Latin Modern Math and Roman faces,
because `Context` measures from them. `ztex.parse` and `ztex.layout` reach real
fonts through an opaque `metrics.FontHook` and never import `font.zig`, so a host
that only wants the static metric tables links none of those bytes.

## Using it

One-shot render, static metric tables:

```zig
var dl = try ztex.render(gpa, latex, .display, 20, null);
defer dl.deinit();
const svg = try ztex.svg.render(gpa, &dl, .{});
defer gpa.free(svg);
```

Many renders, real fonts, one context:

```zig
var ctx = try ztex.Context.init(gpa);
defer ctx.deinit();
var dl = try ctx.render(latex, .display, 20, null);
defer dl.deinit();
```

Rasterize either path to a `PixelBuffer`:

```zig
var pix = try ztex.renderPixels(gpa, latex, .display, 20, .{ .dpi = 200 }, null);
defer pix.deinit();
try pix.writePnm(io, file); // PPM for .rgba32, PGM for .alpha8
```

`ztex.svg.writeFile` takes an explicit `std.Io.Dir` so a host picks the
directory; nothing in the library assumes the working directory.

## Math style

Every entry point takes the math style the formula starts in:

- `.display` — a standalone equation: fractions full size, `\sum` limits
  stacked above and below.
- `.text` — math set inline in running prose: fractions and big operators
  at text size, `\sum` limits beside the operator.

TeX fixes this per formula, and a host rendering inline math must pass
`.text`, or its fractions come out display-sized. `\displaystyle`,
`\textstyle`, `\scriptstyle` and `\scriptscriptstyle` override it from inside
the formula. The CLI exposes it as `--style display|text`.

## Ownership and lifetime

Every type that owns memory says so on the type, and none may be copied by
value:

- **`Ast`** — `init`/`deinit` paired 1:1. `ast.src` aliases the caller's slice
  and is never copied.
- **`DrawList`** — owns its primitives and a glyph arena holding the bytes of
  synthesized glyphs (`∑`, stretchy variants) that have no source bytes.
  `Text.bytes` is source-aliased when `Text.synthetic` is false and
  arena-owned when true; read the flag before retaining a slice.
- **`BoxList`**, **`Context`** — same rule.
- **`PixelBuffer`** — caller frees.

In every case, `deinit` must be called exactly once. A copy of one of these
types deinitializes the same allocations twice.

## Allocators

Every entry point takes an explicit allocator and returns an error union; no
allocation is hidden. Returned byte slices are owned by the caller and must be
freed with the allocator that produced them. `DrawList` internally builds its
arena on the allocator you pass.

## Thread safety

- **`ztex.render` / `ztex.svg.render` are shareable.** They measure from
  immutable static tables and hold no mutable state.
- **`Context` is NOT shareable.** The first render lazily fills the font metric
  cache and arena, so two threads rendering through one Context race on that
  state. Use one Context per thread, or guard a shared one with an external
  mutex.

## Errors

Error sets are closed and explicit, never `anyerror`:

- `ztex.parse.Error` — lexer and parser failures, all carrying a position. The
  CLI renders these with a caret under the offending span.
- `layout.render` returns `error{ OutOfMemory, InvalidAst }`. `InvalidAst`
  means the tree was malformed; it is detected by a single validation walk at
  the layout boundary, so a hand-built AST fails cleanly instead of panicking
  deep in layout.
- `ztex.svg.render` returns `error{ OutOfMemory, NonFiniteCoordinate }` — a
  non-finite coordinate is rejected rather than emitted.

When you supply the `err_info` out-parameter, it is filled only on failure and
is untouched on success.

## Input limits

`parse.parse` rejects a source above `max_source_bytes` (half of `maxInt(u32)`)
with `error.SourceTooLarge`. Byte offsets are `u32` throughout the provenance
chain — source, token, atom, box, drawable — and that bound keeps every offset
representable even when the node pool runs about twice the token count. Parse
nesting is capped at `max_nesting` with `error.NestingTooDeep`, so deeply
nested input fails rather than overflowing the stack.

## Provenance

Every drawable carries the byte span of the source it came from, so a glyph in
the output maps back to its input in O(1).