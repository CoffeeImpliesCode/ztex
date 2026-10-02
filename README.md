# ztex

A LaTeX math renderer for Zig 0.16. Parses LaTeX math into a superflat atom
tree, lays it out into a painter-ordered draw list, and serializes that to SVG
or rasterizes it to a PPM/PGM bitmap. It depends on `zg` alone, for Unicode
width, grapheme segmentation, and text decoding.

This file is the host-facing contract. For internal architecture see
`AGENTS.md`; the two adversarial review passes are `audit.md` and `audit2.md`.

## Version contract

- **Zig 0.16.0 is the tested toolchain.** The manifest requires at least
  `0.16.0`; that is a floor, not an exact-version gate. The code uses its
  `std.Io`, unmanaged-container, and `std.Build` APIs. Other compiler versions
  are not covered by this contract.
- **`zg` v0.16.2**, fetched from codeberg.org and content-hashed in
  `build.zig.zon`. The fetch needs network on a cold cache; `zig-pkg/` holds the
  unpacked package and is gitignored.

The package ships a C ABI alongside the Zig modules; see **C ABI** below.

## Modules

| Module | Root | Role |
| --- | --- | --- |
| `ztex.atom` | `src/atom.zig` | Flat AST and provenance contract |
| `ztex.parse` | `src/parse/root.zig` | UTF-8 source to AST |
| `ztex.layout` | `src/layout/root.zig` | Metrics, boxes, and draw lists |
| `ztex.font` | `src/font.zig` | OpenType decoding and owned font context |
| `ztex.glyph` | `src/mathglyph.zig` | Face-specific glyph forms and streaming assemblies |
| `ztex.svg` | `src/svg.zig` | Outline-backed SVG serialization |
| `ztex` | `src/root.zig` | Facade, reusable `Context`, and `raster` |
| `ztex.c` | `src/ztex_c.zig` | C ABI types/statuses; link the archive for exported functions |

The integration-test root is private to the build. `renderPipeline` is an
internal cross-file helper, not supported host API. Low-level boxes have the
named route `@import("ztex.layout").box`; raster types have the route
`@import("ztex").raster`.

The five bundled Latin Modern faces total 1,193,544 bytes (1.14 MiB).
Zig analyzes declarations lazily: importing the facade does not itself prove
that a binary links every face. Embedded-context and outline-rendering paths
reach these payloads:

| Face | Bytes | Reached by |
| --- | --- | --- |
| LM Math | 733,736 | every style but the four below; the only face with a MATH table |
| LM Roman regular | 111,536 | `CharStyle.roman` — `\text`, `\mathrm`, `\operatorname`, `\tag` |
| LM Roman italic | 118,828 | `CharStyle.text_italic` — `\textit` |
| LM Roman bold | 111,240 | `CharStyle.bold` — `\mathbf` |
| LM Roman bold italic | 118,204 | `CharStyle.bold_italic` — `\textit{\textbf{…}}`, either order |

The counts are the generated modules' own bytes, not a grep: the byte
literal of each `pub const <name> = [_]u8{ … }` declaration, following a
split face through the `++` parts it imports — LM Math is the five
`src/fonts/lmmath/partN.zig` chunks — so a `0xNN` in a comment or a doc
example is never counted. `scripts/embed_font.py`'s `read_embedded` is that
reader; it also cross-checks a face against the byte count its module header
declares, wherever the header carries one, so a truncated initializer fails
the count instead of shipping. The generated metric tables
(`src/layout/roman_style_metrics.zig`, `src/layout/math_style_metrics.zig`,
`src/layout/ink_metrics.zig`) read the faces through it, so a table can never
describe a font other than the one ztex embeds.

`ztex.parse` and `ztex.layout` reach real fonts through an opaque
`metrics.FontHook` and never import `font.zig`; their static-table paths do
not need the bundled font payload. The facade re-exports `font` and `raster`,
but which declarations a consumer uses determines its analyzed dependencies.

## Fonts and metrics

`ztex.render` and `Context.render` are one pipeline; they differ only in
where a glyph's numbers come from.

- **Static tables** — `ztex.render` measures from `layout.metrics.default`:
  generated advances and ink bounds for all four LM Roman faces, the math
  alphabets, horizontal MATH accents/braces and vertical MATH fences, plus
  Computer Modern fallback rows for the remaining math repertoire. The
  Roman rows cover ASCII and Latin Extended-A/B at every size; there is no
  optical-size switch to an unbundled face. Layout needs no font parser or
  mutable state. SVG and pixel output still resolve real glyph outlines.
- **Real fonts** — `Context.render` measures from the embedded face the
  rasterizer will later draw the run from, served from a per-(face,
  codepoint) metric cache that the first render fills and every later render
  hits.

Both paths agree on WHICH face a style draws from, so a run can never
measure from one face and be drawn from another.
`FontContext.faceForStyle` maps `CharStyle.roman` to LM Roman regular,
`.text_italic` to LM Roman italic, `.bold` to LM Roman bold, `.bold_italic`
to LM Roman bold italic, and every other style to LM Math — whose
math-italic, double-struck, script, fraktur, sans and mono glyphs are
already styled, so routing those to a Roman face would draw the wrong
letterform. `faceForCodepoint` uses that face when it carries the glyph,
otherwise LM Math when it does. Metrics and both backends share this routing.

**Fallback.** A codepoint nothing resolves falls through in order: the real
face's metric, then the generated text row, then the Computer Modern table
for the style and size band — which keeps CM widths for codepoints Latin
Modern does not cover — then a fixed 0.5em × 0.7em × 0.2em estimate. Nothing
fails, and nothing invents a glyph id.

**MATH data.** LM Math is the only embedded face with an OpenType MATH
table, so it supplies every MATH constant layout reads — axis height, script
sizes, glue, rule thicknesses — borrowed from the owned face itself:
`Context.fm.font.math_constants` is a pointer into the face's decoded block
for the life of the `Context`, never a per-render copy that could outlive
it. Per-glyph values follow three rules:

- On a face that HAS a MATH table, a glyph the table records no italic
  correction for reports an **effective correction of zero**, so script
  placement still follows the face. The cached metric carries that resolved
  value.
- A face with **no** MATH table — including every embedded LM Roman text
  face — leaves the correction unknown, and layout keeps the static row's
  value. A host-loaded font can have a MATH table; absence stays absence.
- Top accent attachment is forwarded only when the face records one.

Italic correction and top accent attachment therefore follow the glyph that
is actually drawn: in LM Math `𝑓` carries a 0.09em correction and `𝑥` a
0.329em top accent, while a text face reports neither. The face's raw
`mathValues` stay nullable — the resolution above happens in the cached
metric, not in the font's answer.

**Rasterization needs a `Context`.** `raster.rasterize` resolves each run's
face through it. `ztex.glyph` resolves MATH forms for both SVG and CPU:
display big operators, radicals, fixed and stretchy fences, horizontal
accents and braces. Assemblies stream every required part, with the font's
connector overlap constraints; they have no fixed part-count ceiling.
A face without a construction uses its base glyph. An unavailable glyph
stays external text in SVG and paints no glyph in the CPU output.
Rules use the exact rectangle/pixel intersection area at partial-pixel edges.
RGBA and alpha masks apply the foreground alpha to that coverage once.

## C ABI

`zig build static-lib` builds a position-independent static library and
installs the header beside it:

- `zig-out/lib/libztex.a`, from `src/ztex_c.zig`
- `zig-out/include/ztex.h`, the checked-in `include/ztex.h`

The step is not part of the default install, so a Zig-only host's
`zig build` builds exactly what it built before. Link the archive with
libm (`-lm`): it calls `roundf`, plus the `exp`/`log` pair behind the font
decoder's `std.math.pow`.

On GNU ld, add `-Wl,-z,noexecstack` when linking the Zig 0.16 archive. Its
object lacks `.note.GNU-stack`; without that flag, GNU ld warns and creates
an executable stack. The library does not require executable stack memory.

Six exported symbols, all prefixed `ztex_`:

- `ztex_context_create` — allocate a context from your allocator
- `ztex_context_destroy` — release it through the same `dealloc` (`void`)
- `ztex_status_name` — a status code's name, a static string owned by the
  library (`const char *`)
- `ztex_render_svg` — render one formula into your buffer
- `ztex_render_raster` — the same, to a pixel buffer
- `ztex_last_error` — the last failure's text, into your buffer

**Allocator.** `ztex_allocator` is `{ alloc, dealloc, user }`.
`ztex_context_create` copies the struct, so it may be a temporary, but
`user`, `alloc`, and `dealloc` must stay valid until context destruction.
`alloc` returns memory aligned for `max_align_t`, or NULL when it cannot;
`dealloc` receives the exact `len` its matching `alloc` was given. All library
allocations use these callbacks. Render scratch is released before return;
valid font/cache allocations can persist until context destruction. Growth
is allocate, copy, free; a size-tracking free list stays exact. A NULL return
reports `ZTEX_OUT_OF_MEMORY`. Callbacks run on the calling thread and must
not reenter the same context.

**Size query.** Both render entry points write `out_length` only on
`ZTEX_OK` or `ZTEX_BUFFER_TOO_SMALL`; `out = NULL, out_capacity = 0` queries
the fully rendered payload size. A short buffer remains UNWRITTEN — never
half filled. It needs `out_capacity >= size + 1`: a trailing NUL is written
on success and is excluded from `out_length`, including for raster bytes.
Raster width/height are committed on those same two outcomes. Every other
status leaves the payload and all output metadata unchanged.
Raster payloads have `width * height * 4` bytes in `ZTEX_PIXEL_RGBA32` and
`width * height` in `ZTEX_PIXEL_ALPHA8`.

**SVG options.** `ztex_svg_options` is `ztex_render_svg`'s own knob struct and
may be NULL for the default rendering: `padding` in points on every side,
`background` as a packed `0xRRGGBBAA` (`ZTEX_COLOR_NONE` for none), and two
NUL-terminated CSS font-family lists for unavailable-glyph text fallback:
`math_font_family` for math and `upright_font_family` for upright text.
Known glyphs are outlines, so these lists do not replace their faces. NULL
keeps ztex's own stack. Both lists are XML-escaped.

**Styles.** `style` is `ZTEX_STYLE_DISPLAY` (0), `ZTEX_STYLE_TEXT` (1),
`ZTEX_STYLE_SCRIPT` (2) or `ZTEX_STYLE_SCRIPT_SCRIPT` (3); any other code is
`ZTEX_INVALID_ARGUMENT`. The first two are the ordinary choices — see **Math
style** below; the last two are legal, but an unusual starting style for a
whole formula.

**Raster options.** `ztex_raster_options` takes `dpi`, `scale`, a pixel
`padding`, a `ZTEX_PIXEL_*` format, and `fg`/`bg` as packed `0xRRGGBBAA`
colors (`ZTEX_COLOR_NONE` for no background). A NULL pointer means
96 DPI, 1x scale, zero padding, RGBA, opaque black foreground, and no
background. A non-NULL struct supplies every field: zero foreground means
transparent ink, not an omitted default. A ZEROED struct is
`ZTEX_INVALID_ARGUMENT` because DPI 0 is not a resolution.
`fg` is the ink color of every primitive no color scope covers; an explicit
`\color` or `\textcolor` scope supplies its own color instead. The
SCOPE decides rather than the value — so an explicit black, or a transparent
`\color{transparent}`, beats a light `fg` instead of being read as "no color
given". In `ZTEX_PIXEL_ALPHA8` a mask byte is coverage times the ALPHA byte
of the ink (`fg`'s for ordinary ink, the formula's own color inside `\color`
and `\textcolor`), so `fg`'s red, green and blue never reach a mask, and the
canvas is always transparent — `bg` is ignored there.

**Status codes.** `ztex_context_create`, `ztex_render_svg`,
`ztex_render_raster` and `ztex_last_error` return an `int`; `ZTEX_OK` (0) is
success, and no Zig error union crosses the boundary. `ztex_context_destroy`
returns `void` and `ztex_status_name` a `const char *`. The remaining codes
are `invalid_argument` 1, `parse_error` 2, `invalid_ast` 3, `out_of_memory`
4, `non_finite_coordinate` 5, `buffer_too_small` 6, `output_too_large` 7,
`font_error` 8. `ztex_status_name` never returns NULL, and reads "unknown
status" for a code this build does not know.

**Last error.** `ztex_last_error` copies the text of the last failure on a
context into your buffer, NUL-terminating within `capacity`, and always
writes the FULL text length to `out_length` — so `out_length >= capacity`
means the tail was cut. The text is bounded at 255 bytes and recording it
never allocates; every render clears it first, so a failed render replaces
it and a successful one leaves it empty. With nothing to report the call
answers `ZTEX_OK`, writes `out_length = 0` and touches no buffer byte; a NULL
buffer or a zero capacity with text to report answers
`ZTEX_INVALID_ARGUMENT` and leaves the text readable.

**Strings.** The LaTeX source is counted UTF-8: exactly `latex_length` bytes
are rendered, `strlen` is never called on it, and it needs no NUL terminator.
A byte that is not valid UTF-8 fails the parse. A NULL source is an empty
formula, and is only valid with `latex_length` 0. Every other string is
NUL-terminated: both font-family options you pass in, and everything the
library hands back. Lengths and capacities are 32-bit, so a payload above
4 GiB - 2 bytes fails with `ZTEX_OUTPUT_TOO_LARGE` instead of truncating.
For raster this total-payload limit is checked before pixel allocation;
earlier parse/layout/font working-set allocations are not prohibited.

**Who frees what.** Every byte the library takes comes from your allocator:
the context block, and the five embedded Latin Modern faces plus the glyph
metric cache it owns, which `ztex_context_destroy` gives back through the same
`dealloc`; plus render scratch, released before return, and cached metrics,
retained until context destruction. Rendered output is never handed back as a pointer — it is
copied into a buffer you own, and you free that. The string
`ztex_status_name` returns lives as long as the process; never free it.

**Threads.** A `ztex_context` is NOT thread-safe — the first render fills a
glyph metric cache. Use one context per thread, or serialize access.

The header is self-contained C89 and wraps its declarations in `extern "C"`
automatically for C++ consumers. The real header is checked against the Zig
ABI types and exercised by C and C++ consumers in `zig build test`.

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

Rasterize to a `PixelBuffer` in one call — this builds a temporary context:

```zig
var pix = try ztex.renderPixels(gpa, latex, .display, 20, .{ .dpi = 200 }, null);
defer pix.deinit();
try pix.writePnm(io, file); // PPM for .rgba32, PGM for .alpha8
```

or from a context you already hold — the only way to rasterize a draw list
you built yourself, since the rasterizer resolves every glyph through the
context's faces:

```zig
var pix = try ctx.renderPixels(latex, .display, 20, .{ .format = .alpha8 }, null);
defer pix.deinit();
```

One formula reaching most of the surface at once — nested text faces, a
colour scope, a frame, a ruled array, a wide accent and an equation number:

```latex
\boxed{\color{red} E = mc^2}\qquad
\textbf{a}\textit{b}c\quad
\begin{array}{l|c}
  \hline
  \widehat{abc} & \widetilde{xyz} \\
  \hline
\end{array}
\tag{1}
```

`ztex.svg.writeFile(gpa, io, dir, path, dl, opts)` takes explicit I/O and a
directory. Rendering itself performs no file I/O. File writes are not atomic:
rendering fails before creation, but a create/write error or cancellation
may leave the destination empty or partially written.

Embedded `FontContext.init(gpa)` needs no I/O. Explicit disk/discovery calls
are `fonts.loadFromFile(gpa, io, path)` and `fonts.findFont(io, name)`.
The latter searches ambient font paths and may run `fc-list`; a `null` result
is a memoized best-effort miss, not a detailed discovery error. Relative
paths are cwd-relative. I/O capabilities are borrowed per call, not stored.
Discovery is blocking and suppresses I/O failures, including cancellation.
If no later candidate succeeds, the resulting miss is cached until context
destruction. Use explicit `loadFromFile` when the caller needs an I/O error.

### API migration

- `glyph.requestFor(bytes, .{ .bigop_variant = ..., .delim_req = ... })`
  replaces the positional boolean/form/length argument sequence. All options
  are named, and precedence/units are documented on `RequestOptions`.
- `face.smallPrimeGid(cp)` replaces the free `font.smallPrimeGid(cp)`.
  Unencoded bundled-font IDs are exposed only for an exact bundled LM Math
  face; another font keeps its own cmap prime at script sizes.
- `FontContext.loadFromFile` and `findFont` take per-call `std.Io`;
  `FontContext` no longer captures a global I/O capability.
- `raster.Options.max_bytes` is the native pixel-payload cap. It adds no
  change to dimensions/stride or the C header's fixed-width fields.
- `ztex.tests` is not a published dependency module. Use supported native
  modules or the C header/archive, not the library's integration-test root.

### Build and verification

`zig build` installs the CLI and benchmark. `zig build static-lib` installs
the C archive/header. `zig build docs` emits published-module roots under
`zig-out/docs/{atom,parse,layout,svg,ztex,c,font,glyph}`.

`zig build test` includes native unit/integration/regression roots, actual
header ABI comparison, and linked C89/C++ consumers. `--summary all` prints
counts; `-Doptimize=ReleaseSafe` retains safety checks in optimized code.
Use `zig build test-layout -Dtest-filter='substring'` for a focused native
root, `test-c-header` for the compile-time object check, or `test-c-consumers`
for the real hosts. The object root reaches the actual private C export
types; it is not a zero-test runner. New C exports must also be entered in
the private source type list used by that check.

## Output back ends

Both back ends consume the same `draw.DrawList` and frame from the same
source, `DrawList.bounds()` — the INK bounds `flatten` accumulated, not the
box bounds. Every glyph's horizontal extent is its advance box UNIONED with
the real ink edges measured from the face it is drawn from, so a glyph that
leans past its advance (math italic, a display `∑` variant) is inside the
frame rather than shaved off it; vertically the ink is exact. The box
`width`/`height`/`depth` fields remain the laid-out root box and can
under-bind or over-bind; nothing frames from them.

**SVG.** `ztex.svg.render` returns an owned `[]u8`. The `<svg>` element
declares its physical size — `width="…pt" height="…pt"` — and its `viewBox`
is unitless, `0 0 w h`, which makes one user unit equal one point. Every
coordinate inside the document is then unitless too: positions, `rect` and
background sizes, `stroke-width`, `font-size`. The `pt` on the outer
attributes is what pins the rendered size; carrying it inside as well would
scale every coordinate twice. A non-finite coordinate is rejected
(`error.NonFiniteCoordinate`) rather than emitted.

**SVG paints real outlines.** Every glyph present in the resolved face is
an absolute filled `<path>`, including ordinary text, the selected MATH
variant, and every part of an assembly. The geometry is the same font
outline the CPU paints; no browser font substitution, synthetic slant or
text-baseline rounding changes it. Assemblies and connected radical vincula
use one path so translucent ink is composited once across their joins.
Thin decoration bands are filled paths too, avoiding browser hairline-stroke rounding.

Known glyphs need no installed font, but are not selectable browser text.
The `data-text`, `data-x`, `data-y` and `font-size` attributes identify each
outlined run; they do not control its geometry. A missing glyph leaves an
escaped `<text>` fallback. A known prefix is still outlined, and the
unresolved tail starts at that prefix's advance. Family options affect only
this fallback. `svg.Options.fonts` borrows a caller's `FontContext`; without
one, SVG lazily opens the bundled faces once per document.

**Raster.** `raster.rasterize` (or `ztex.renderPixels` /
`Context.renderPixels`) paints the same content into a `PixelBuffer` from the
same ink bounds: pt → px is `(dpi / 72) * scale`, `padding` is added in
PIXELS on both axes, and one extra pixel column and row is left past the ink
so edge antialiasing is never clamped at the last row. Glyph outlines are
filled by analytic quadratic-Bézier scanline coverage; rules are exact
rectangle fills; a `line` is a butt-capped band at constant width, matching
SVG's filled quadrilateral. A round cap would paint beyond its ink bounds.
Glyph clipping and scanline coverage use margin-free coordinates. Padding
shifts pixel indices only, so it cannot change glyph antialiasing.
`PixelBuffer.pixels` has `height * stride` bytes; dimensions and stride are
`u32`, but row offsets and total native payload length are `usize`.
`raster.Options.max_bytes` bounds the pixel block before its allocation and
defaults to `maxInt(usize)`. It does not bound scratch or context caches.
The C boundary uses the stricter 32-bit length/NUL limit described above.
The CFF cubic-to-quadratic fit preserves coordinate extrema and stays inside
the original ink bounds, so approximation cannot add ink outside the frame.

RGBA stores straight alpha. PPM cannot carry alpha, so its encoder mattes
RGBA over white; it does not discard the alpha byte. PGM stores coverage.
The CPU unions connected MATH assembly and radical-vinculum coverage before
applying ink alpha, without rounding connector joins to whole pixels.

## Math style

Every entry point takes the math style the formula starts in — the four
`atom.MathStyle` values, which are the `ZTEX_STYLE_*` codes on the C side:

- `.display` — a standalone equation: fractions full size, `\sum` limits
  stacked above and below.
- `.text` — math set inline in running prose: fractions and big operators
  at text size, `\sum` limits beside the operator.
- `.script` and `.script_script` — the two script sizes. Legal as a starting
  style, but a host almost always wants `.display` or `.text` and lets a
  script shrink itself.

TeX fixes this per formula, and a host rendering inline math must pass
`.text`, or its fractions come out display-sized. `\displaystyle`,
`\textstyle`, `\scriptstyle` and `\scriptscriptstyle` override it from inside
the formula, and the override carries the whole size ladder with it — a
`\displaystyle` in a subscript still comes out smaller than one in the
formula's body. The CLI exposes the two ordinary ones as
`--style display|text`.

Script sizes follow the MATH scale-down percentages continuously: LM Math
uses 70% and 50%. LaTeX's document class can choose discrete sizes instead
(for example, a 6pt script at an 8pt base instead of 5.6pt). Such references
do not have the same size contract.

## Commands

`ztex.parse.supported_commands` is the union of the four dispatch tables,
generated at comptime from them, so it cannot drift. It is the answer for a
host that must enumerate what parses. What follows is the recent additions,
grouped the way a formula reaches for them:

- **Scripts over and under a base** — `\overset{top}{base}`,
  `\underset{bot}{base}`, `\stackrel{top}{base}`. Each is a `\mathop` with
  forced limits, so the script sits centred over or under the base.
  Spacing uses the font's MATH upper/lower limit gaps and baseline floors;
  outer operator padding is not added between the base and annotation.
- **Braces** — `\underbrace{x}` and `\overbrace{x}`, each taking an optional
  `_` / `^` annotation, as in `\underbrace{x}_{n}`.
  Native horizontal variants take the largest rung that fits the nucleus;
  a narrower nucleus keeps the base brace, and requests past the ladder
  use its glyph assembly.
  The underbrace starts at the nucleus's depth. The overbrace baseline is
  `AccentBaseHeight` below its top; the glyph's tips remain above the body.
- **Radicals** — display style uses the larger radical clearance gap.
  Text, script and scriptscript styles use the compact gap, including
  text-style cells in `cases` and arrays.
  The index reserves its net degree-kern width before the surd. Tall
  assemblies distribute legal connector overlap without adding height steps.
  The glyph's connecting cap remains framed for empty and narrow nuclei.
- **Invisible boxes** — `\phantom{x}` reserves the argument's width, height
  and depth, `\hphantom` its width only, `\vphantom` its height and depth
  only; none of the three paints anything.
- **`\smash`** is the odd one out: it KEEPS the content visible and keeps
  the argument's advance, and zeroes only the vertical extents. The optional
  argument picks the axes, as in amsmath: `\smash[t]{x}` drops the height,
  `\smash[b]{x}` the depth, and bare `\smash{x}` is `[tb]` — both, which
  leaves `\hphantom`'s geometry with the glyphs still drawn. An argument
  that is not `t`, `b` or `tb` is a parse error at the option text.
- **Text faces** — `\textit{…}`, `\textbf{…}` and `\text{…}` preserve raw
  text without Unicode math remapping. Nested face commands combine and
  restore their surrounding scope: `\textbf{a\textit{b}c}` paints `a` and `c`
  bold and `b` bold italic. Nesting either face order gives bold italic;
  more than 500 levels fails with `error.NestingTooDeep`. Only the supported
  raw-text escapes and scope commands are accepted. An unsupported command
  such as `\text{\sqrt{x}}` is `error.UnknownCommand` at its source span,
  not silently dropped text.
- **Color** — `\color{<spec>}` is a DECLARATION: it applies to the rest of
  the row and ends where the row, group, cell or environment body does. It
  is class-transparent, so a colored relation keeps its relation glue.
  `\textcolor{<spec>}{…}` colors only its braced argument, and that group
  reports `ord` — a colored relation under `\textcolor` loses its glue,
  exactly as xcolor's does. The spec is a braced color name, `#RRGGBB` or
  `#RRGGBBAA`; `none` and `transparent` mean transparent INK, so the scope
  still exists and the glyph simply paints nothing. A primitive inside a
  color scope takes that scope's color on BOTH back ends, and in a raster
  buffer it is that color's alpha byte the mask carries.
- **`\boxed{x}`** — amsmath's `\fbox{\m@th$\displaystyle x$}`. The four
  rules sit OUTSIDE the content, 3pt of `fboxsep` plus a 0.4pt `fboxrule` on
  every side, and the body is set in DISPLAY style whatever style surrounds
  it, so `\boxed{\frac{a}{b}}` in a denominator still shows a display
  fraction.
- **Arrays, rules and row spacing** — `\begin{array}{l|c}` takes a column
  spec of `l`, `c`, `r` and `|`; the amsmath environments `matrix`,
  `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`, `Vmatrix`, `cases` and
  `aligned` need no spec. `\hline` draws one full-width rule where it sits,
  which is BETWEEN rows: leading, interior and trailing positions are all
  legal, and anywhere else — a row body, a cell, a group, outside an
  environment — it is `error.MisplacedHline` rather than a fabricated empty
  row. Adjacent double rules keep the 2pt separation; ordinary matrix fences
  retain the 5pt outer column spacing. Empty rows and nested cells do not
  invent or inherit another environment's rules.
  `\arraystretch{n}` is a group-local assignment: it scales the row
  strut (0.7em above and 0.3em below the baseline) of subsequent environments.
  A first-row cell can also set the current environment's factor; the last
  such assignment wins. The assignment ends with that cell, so later cells,
  nested environments and sibling environments read the enclosing factor.
  With no assignment the per-environment default applies: `cases`
  is 1.2, as amsmath sets it, and everything else is 1. `\arraystretch{0}`
  is the encoding for "no assignment", so it takes that default rather than
  collapsing the strut.
- **`\tag{n}`** — amsmath's equation number: set upright in amsmath's own
  parentheses, centred on the axis after the formula with a `\mintagsep`
  gap. The digits alias their real source bytes, so each drawn glyph keeps
  its span inside `\tag{…}`.
- **Wide accents** — `\widehat{…}` and `\widetilde{…}` choose the largest
  native horizontal MATH rung whose advance fits the nucleus plus italic
  correction. This also applies to a wide single glyph such as `M`; a
  narrow `\hat` or `\tilde` always keeps the base combining mark. The native
  hat preserves the face's curve and stroke weight, not a scaled chevron.
  Past LM Math's finite tilde ceiling, a multi-character `\widetilde`
  retains ztex's extensible convention: one connected wave spanning the
  argument, with one crest and one trough. Braces use native horizontal
  MATH variants and assemblies, not square line approximations.
- **Spacing** — `\hspace{<dim>}`, `\kern<dim>`, `\mkern<dim>`, plus `\:` (the
  medium math space) and `\ ` (the interword space). The unit in the
  dimension decides how layout scales the skip.
  `\colon` is an ordinary atom with amsmath's explicit 2mu before and 6mu
  after; it is not a relation. Prime runs use single, double, triple and
  quadruple-prime glyphs greedily, and an explicit exponent continues the
  same superscript field.
- **Fraction variants** — `\dbinom{n}{k}` and `\tbinom{n}{k}` are `\binom`
  with the style forced to display and text, so both the parts and the
  amsmath fixed parens size that way even inside a script.
- **Big operators** — the amsmath `\slimits@` n-ary family `\bigodot`
  `\bigoplus` `\bigotimes` `\biguplus` `\bigsqcap` `\bigvee` `\bigwedge`
  `\bigstar`, and the big integrals `\bigint` `\bigiint` `\bigiiint`.
- **Atom classes** — `\mathop`, and the forced-class primitives `\mathord`
  `\mathrel` `\mathbin` `\mathopen` `\mathclose` `\mathpunct` `\mathinner`.
  A plain binary operator such as `+` or `-` already takes the binary class;
  use `\mathbin` to force that class — and its medium glue — onto a symbol
  the tables would class otherwise. The class is recorded, not the glyph:
  the forced row draws the same character and only the spacing changes.
- **Colon relations** — `\coloneqq`, `\coloneqqs` and `\coloneq` draw `:=`.
  `\Coloneqq` and `\Coloneqqs` draw `::=` from native glyph parts because
  LM Math has no U+2A74 glyph. `\Colon` draws `::`, and `\ratio` draws `:`.

## Ownership and lifetime

Owning values have one disposal obligation. Moving a value is allowed;
copying it shares the allocations and does not create another owner:

- **`Ast`** — `init`/`deinit` paired 1:1. `ast.src` aliases the caller's slice
  and is never copied.
- **`DrawList`** — owns its primitives and a glyph arena holding the bytes of
  synthesized glyphs (`∑`, stretchy variants) that have no source bytes.
  `Text.bytes` is source-aliased when `Text.synthetic` is false and
  arena-owned when true; read the flag before retaining a slice.
- **`BoxList`** — owns its pools; release it once. Node/box indices remain
  stable across appends, but pointers into growable pools do not.
- **`Context`** — same rule, plus more than it frees. It heap-allocates its
  `FontContext` (a self-pointer into it must outlive `init`'s frame), which
  owns one arena holding all five embedded faces and every per-(face,
  codepoint) metric cache entry. It also points at borrowed memory:
  `Context.fm.font.math_constants` is the LM Math face's own decoded MATH
  block, and `fonts` is the heap block `deinit` destroys. Copying a `Context`
  by value shares the `FontContext`, so two `deinit` calls free it twice.
- **`PixelBuffer`** — owns pixels independently of source and context.
- **`FontFace`** — a standalone `fromBytes` face owns its copy; a face
  borrowed from `FontContext` must not be disposed by its borrower.
  If a standalone face is passed to `FontContext.metrics`, it must stay
  alive, unchanged, and at its address until that context is disposed:
  metric rows are cached by face address and have no separate invalidation.
- **`Outline`** — owns raw-font-unit contours; release with its recorded
  allocator once. Borrowed MATH-table views instead die with their face.

Call `deinit` exactly once per owner. All aliases into its storage become
invalid. In particular, disposing both an owner and its copy is a double free.
An AST's borrowed source must stay alive and unchanged while used; a draw
list can outlive the AST but still borrows the original source.

## Allocators

Allocators are explicit per operation or retained by an initialized owner.
Keep a retained allocator's backing state and identity valid through the
owner's disposal and any independently owned results it produced. Do not
replace an owning value's allocator field while allocations remain live.
Free returned byte slices with the allocator that produced them. Rendering
with a persistent `Context` reuses its font/cache owner; one-shot pixel
rendering builds and disposes a temporary context.

## Thread safety

- **Static-table `ztex.render` is independent per call.** Use a thread-safe
  allocator and keep shared source/metric inputs immutable.
- **`svg.render` is independent with its own temporary faces.** Passing
  `Options.fonts` shares mutable font/cache state and requires serialization.
- **`Context` / `FontContext` are not concurrently shareable without a lock.**
  Cache mutations and disposal must not overlap any use. `raster.rasterize`
  borrows a context under the same rule. Use one context per thread or an
  external mutex; reentrancy is not an implicit synchronization mechanism.

## Errors

Error sets are closed and never `anyerror`. The parse, layout, SVG and raster
sets are explicit:

- `ztex.parse.Error` — syntax/source-limit failures and `OutOfMemory`.
  Only the former carry a filled diagnostic; the CLI prints their caret span.
- `layout.Error` — `OutOfMemory`, `InvalidAst`, `InvalidArgument`, plus
  `metrics.StretchError` for font-backed stretch decoding. `layout.render`
  validates reachable token runs, source spans, payloads, child links, and
  depth before recursive layout. Hand-built malformed trees fail cleanly.
  Low-level `layout.layout` and `draw.flatten` require validated structures;
  they do not repeat the boundary check.
- All native render entry points require finite, positive `size_pt` and
  return `InvalidArgument` before parsing/allocating when it is invalid.
- `svg.Error` — `OutOfMemory`, `InvalidArgument`, `NonFiniteCoordinate`,
  plus `font.FontError`. Padding must be finite and non-negative.
  `svg.WriteError` adds file creation/writing errors, including cancellation.
- `raster.Error` — `OutOfMemory`, `InvalidArgument`, `OutputTooLarge`,
  `NonFiniteCoordinate`, plus `font.FontError`. Non-positive/non-finite
  DPI/scale is invalid; non-finite ink bounds are a coordinate error.
  Dimensions, stride, total length, and `max_bytes` are checked before pixels
  are allocated. Missing glyphs/empty outlines paint nothing; unusable MATH
  forms degrade to the base glyph.

A supplied `err_info` is filled only on syntax/source-limit failure, not on
`OutOfMemory`. Success and other failures leave its previous value unchanged.

## Input limits

`ztex.parse.parse` rejects a source above `max_source_bytes` (half of
`maxInt(u32)`) with `error.SourceTooLarge`. Source byte offsets are `u32`
throughout the provenance chain.

AST pool indices are also `u32`. `Ast` mutators refuse an unrepresentable new
node run with `OutOfMemory` before narrowing an index or requesting capacity;
the source-byte limit is not a replacement for this check on hand-built trees.
Node indices remain stable across appends, but the backing allocation can move.

Parse nesting is capped at `max_nesting` with `error.NestingTooDeep`, so
deeply nested input fails rather than overflowing the stack; a `\text` /
`\textit` / `\textbf` argument nested deeper than `atom.max_text_nesting`
(also 500) fails the same way, because layout's face-scope stack has the same
bound.

Hand-built AST layout is capped at `atom.max_ast_depth` (2000 node levels),
with `InvalidAst` beyond it. This is distinct from the parser's nesting
counter and also bounds the subsequent recursive box/flatten path.

## Provenance

Every drawable carries the byte span of the source it came from, so a glyph in
the output maps back to its input in O(1). The span is exact through the
constructs that would otherwise break it: `\tag{1}`'s digits alias their own
source bytes rather than a synthesized copy, `\boxed`'s four rules carry the
span of the box they frame, an `\hline` carries the span of its own token, and
a synthesized glyph (`∑` from `\sum`, a stretchy variant) carries the span of
the construct that produced it even though no source bytes exist for it.
An accent glyph or long-tilde band carries its whole accent command's span.