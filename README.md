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

The package ships a C ABI alongside the Zig modules; see **C ABI** below.

## Modules

| Module | Root | Pulls the embedded fonts? |
| --- | --- | --- |
| `ztex.atom` | `src/atom.zig` | no |
| `ztex.parse` | `src/parse/root.zig` | no |
| `ztex.layout` | `src/layout/root.zig` | no |
| `ztex.svg` | `src/svg.zig` | no |
| `ztex` (facade) | `src/root.zig` | **yes** |

Importing `ztex` links five embedded Latin Modern faces, 1,193,544 bytes
(1.14 MiB) in total, because `Context` measures and rasterizes from them:

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
(`src/layout/roman_style_metrics.zig`, `src/layout/ink_metrics.zig`) read the
faces through it, so a table can never describe a font other than the one
ztex embeds.

`ztex.parse` and `ztex.layout` reach real fonts through an opaque
`metrics.FontHook` and never import `font.zig`, so a host that only wants
the static metric tables links none of those bytes. The facade also
re-exports `font` and `raster`, and `src/raster.zig` imports `font.zig`, so
the payload rides along with `ztex` either way.

## Fonts and metrics

`ztex.render` and `Context.render` are one pipeline; they differ only in
where a glyph's numbers come from.

- **Static tables** — `ztex.render` measures from `layout.metrics.default`,
  compiled-in numbers: the Computer Modern rows for the math face, GENERATED
  rows for the three LM Roman faces those tables do not describe (italic,
  bold and bold italic — the faces' own advances and their real ink bounds
  across ASCII, Latin-1 Supplement and Latin Extended-A/B), and GENERATED
  sparse ink-edge rows for all five faces, so a glyph is framed by the same
  outline it is drawn from. It touches no font file and holds no mutable
  state, so it is shareable across threads.
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
letterform. The layout metric hook and the rasterizer both call it.

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
- A face with **no** MATH table at all — every LM Roman text face, and any
  font a host loads itself — leaves the correction unknown, and layout keeps
  the static row's value. Absence stays absence; nothing is invented.
- Top accent attachment is forwarded only when the face records one.

Italic correction and top accent attachment therefore follow the glyph that
is actually drawn: in LM Math `𝑓` carries a 0.09em correction and `𝑥` a
0.329em top accent, while a text face reports neither. The face's raw
`mathValues` stay nullable — the resolution above happens in the cached
metric, not in the font's answer.

**Rasterization always needs a `Context`.** `raster.rasterize` resolves the
face from it for every run and every primitive it paints, including the
MATH size variants behind a display big operator, a stretchy `√`, and a
`\left`/`\right` fence. A face whose variant ladder is absent or too short
for the request degrades to the unstretched base glyph — legible, never
wrong-shaped from a foreign font's glyph numbering, and never a failed
render, because the raster API has no per-glyph error channel.

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
`user`, `alloc` and `dealloc` must stay valid until `ztex_context_destroy`.
`alloc` returns memory aligned for `max_align_t`, or NULL when it cannot;
`dealloc` receives the exact `len` its matching `alloc` was given. It is the
library's only source of memory: the parse, layout, SVG and pixel working set
of every render comes from it too, and is released before that render
returns. Growth is allocate, copy, free, so an arena works and a
size-tracking free list stays exact. A NULL from `alloc` is an ordinary
allocation failure and reports `ZTEX_OUT_OF_MEMORY`.

**Size query.** Both render entry points always write the payload size to
`out_length`, so `out = NULL, out_capacity = 0` is the size query. A buffer
that cannot hold the whole payload comes back UNWRITTEN with
`ZTEX_BUFFER_TOO_SMALL` — never half filled. The payload needs
`out_capacity >= size + 1`: the library always terminates it with a NUL, and
that NUL is the one byte `out_length` does not count.
`ztex_render_raster` also writes `out_width` and `out_height` whenever the
render itself succeeded, including on the size query; a failed render leaves
them alone. Its payload is `width * height * 4` bytes in `ZTEX_PIXEL_RGBA32`
and `width * height` in `ZTEX_PIXEL_ALPHA8`.

**SVG options.** `ztex_svg_options` is `ztex_render_svg`'s own knob struct and
may be NULL for the default rendering: `padding` in points on every side,
`background` as a packed `0xRRGGBBAA` (`ZTEX_COLOR_NONE` for none), and two
NUL-terminated CSS font-family lists — `math_font_family` for the math runs,
`upright_font_family` for `\text`, `\mathrm`, `\mathbf`. NULL on either keeps
ztex's own stack. Both are escaped on the way out, so a quote in one cannot
break out of the attribute.

**Styles.** `style` is `ZTEX_STYLE_DISPLAY` (0), `ZTEX_STYLE_TEXT` (1),
`ZTEX_STYLE_SCRIPT` (2) or `ZTEX_STYLE_SCRIPT_SCRIPT` (3); any other code is
`ZTEX_INVALID_ARGUMENT`. The first two are the ordinary choices — see **Math
style** below; the last two are legal, but an unusual starting style for a
whole formula.

**Raster options.** `ztex_raster_options` takes `dpi`, `scale`, a pixel
`padding`, a `ZTEX_PIXEL_*` format, and `fg`/`bg` as packed `0xRRGGBBAA`
colors (`ZTEX_COLOR_NONE` for no background). A NULL pointer means the
defaults — 96 dpi, 1x scale, RGBA — but a ZEROED struct is
`ZTEX_INVALID_ARGUMENT`, because dpi 0 is not a resolution. `fg` is the ink
color of every primitive no color scope covers; a primitive an explicit
`\color` or `\textcolor` scope covers paints its own color instead, and the
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

**Who frees what.** Every byte the library takes comes from your allocator:
the context block, and the five embedded Latin Modern faces plus the glyph
metric cache it owns, which `ztex_context_destroy` gives back through the same
`dealloc`; plus each render's working set, which is released before that
render returns. Rendered output is never handed back as a pointer — it is
copied into a buffer you own, and you free that. The string
`ztex_status_name` returns lives as long as the process; never free it.

**Threads.** A `ztex_context` is NOT thread-safe — the first render fills a
glyph metric cache. Use one context per thread, or serialize access.

The header is plain C89 and self-contained, so a C++ host includes it from
inside its own `extern "C"` block.

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

`ztex.svg.writeFile` takes an explicit `std.Io.Dir` so a host picks the
directory. The render path touches no directory at all; the only `cwd()` uses
left are `font.zig`'s own font-file loading, which a host reaches only by
driving a `FontContext` itself.

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

**Variants in SVG are hints, not geometry.** A display big operator, a
stretchy `√`, and a `\left`/`\right` fence taller than its base glyph come
from the MATH variant ladder, which no SVG renderer applies on its own: the
run is emitted at its declared `font-size` with the base cmap glyph. The
document therefore carries a marker the rasterizer and the comparison
verifier read and resolve — `data-op="v1"`, `data-radical="vN"`,
`data-fixed-req`, `data-delim-form="vN"`, `data-delim-req` — so a consumer
that understands them reproduces the layout's choice. A plain browser shows
the unstretched base glyph. This is a real difference between the two back
ends, not a rounding error: only the raster path resolves the variants.

**Raster.** `raster.rasterize` (or `ztex.renderPixels` /
`Context.renderPixels`) paints the same content into a `PixelBuffer` from the
same ink bounds: pt → px is `(dpi / 72) * scale`, `padding` is added in
PIXELS on both axes, and one extra pixel column and row is left past the ink
so edge antialiasing is never clamped at the last row. Glyph outlines are
filled by analytic quadratic-Bézier scanline coverage; rules are exact
rectangle fills; a `line` is a butt-capped band around the segment at
constant width, matching svg.zig's `<line>`, which declares no cap — a round
cap would paint past the ink the frame stops at. `PixelBuffer.pixels` is
`width * height * 4` for `.rgba32` and `width * height` for `.alpha8`, with
`stride` carrying the row pitch. The CFF cubic-to-quadratic fit preserves
coordinate extrema and stays inside the original ink bounds, so approximation
cannot add ink outside the frame.

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

## Commands

`ztex.parse.supported_commands` is the union of the four dispatch tables,
generated at comptime from them, so it cannot drift. It is the answer for a
host that must enumerate what parses. What follows is the recent additions,
grouped the way a formula reaches for them:

- **Scripts over and under a base** — `\overset{top}{base}`,
  `\underset{bot}{base}`, `\stackrel{top}{base}`. Each is a `\mathop` with
  forced limits, so the script sits centred over or under the base.
- **Braces** — `\underbrace{x}` and `\overbrace{x}`, each taking an optional
  `_` / `^` annotation, as in `\underbrace{x}_{n}`.
- **Invisible boxes** — `\phantom{x}` reserves the argument's width, height
  and depth, `\hphantom` its width only, `\vphantom` its height and depth
  only; none of the three paints anything.
- **`\smash`** is the odd one out: it KEEPS the content visible and keeps
  the argument's advance, and zeroes only the vertical extents. The optional
  argument picks the axes, as in amsmath: `\smash[t]{x}` drops the height,
  `\smash[b]{x}` the depth, and bare `\smash{x}` is `[tb]` — both, which
  leaves `\hphantom`'s geometry with the glyphs still drawn. An argument
  that is not `t`, `b` or `tb` is a parse error at the option text.
- **Text faces** — `\textit{…}`, `\textbf{…}` and `\text{…}`. The argument
  is ONE raw byte run in ONE face, so nesting is found inside it rather than
  split into separate runs: `\textit{\textbf{ab}}` is one run in bold
  italic, and so is the partial nest `\textbf{a\textit{b}c}`. Nesting
  COMBINES rather than overwrites, so `\textit{\textbf{ab}}` and
  `\textbf{\textit{ab}}` are the same face; a run nested deeper than 500
  levels fails with `error.NestingTooDeep` instead of overflowing the
  layout's face-scope stack. The bytes stay verbatim — no Unicode math
  remapping, because these are the LM Roman text faces, not the MATH italic
  one.
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
  row. `\arraystretch{n}` is a group-local assignment: it scales the row
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
- **Wide accents** — `\widehat{x}` and `\widetilde{x}` take a mandatory
  braced group. A ONE-character argument lays out exactly as `\hat` and
  `\tilde` do — the real combining mark, on the base's top-accent
  attachment — while every multi-character argument gets the extensible form
  however short it is: `\widehat{xy}` is about 1em wide and still carries a
  hat over both letters. That form is ONE connected stroke spanning the
  argument, a hat with a single apex or a wave with one crest and one
  trough, never a run of repeated marks, which reads as a sawtooth row of
  little hats rather than an accent. It is `rule_thickness` wide — the font's
  own rule weight, the same one the fraction bar and an `\hline` use — floats
  inside the narrow mark's own ink band so its feet never reach down through
  the argument, and is fitted edge to edge: the ink starts on the base's left
  edge and ends on its right.
- **Spacing** — `\hspace{<dim>}`, `\kern<dim>`, `\mkern<dim>`, plus `\:` (the
  medium math space) and `\ ` (the interword space). The unit in the
  dimension decides how layout scales the skip.
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
- **Colon relations** — `\coloneqq` (with `\coloneqqs`, `\Coloneqq`,
  `\Coloneqqs`, `\coloneq`), `\Colon` and `\ratio`.

## Ownership and lifetime

Every type that owns memory says so on the type, and none may be copied by
value:

- **`Ast`** — `init`/`deinit` paired 1:1. `ast.src` aliases the caller's slice
  and is never copied.
- **`DrawList`** — owns its primitives and a glyph arena holding the bytes of
  synthesized glyphs (`∑`, stretchy variants) that have no source bytes.
  `Text.bytes` is source-aliased when `Text.synthetic` is false and
  arena-owned when true; read the flag before retaining a slice.
- **`BoxList`** — same rule.
- **`Context`** — same rule, plus more than it frees. It heap-allocates its
  `FontContext` (a self-pointer into it must outlive `init`'s frame), which
  owns one arena holding all five embedded faces and every per-(face,
  codepoint) metric cache entry. It also points at borrowed memory:
  `Context.fm.font.math_constants` is the LM Math face's own decoded MATH
  block, and `fonts` is the heap block `deinit` destroys. Copying a `Context`
  by value shares the `FontContext`, so two `deinit` calls free it twice.
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
- **`Context` is NOT shareable**, and neither is `raster.rasterize`, which
  takes a `*Context`: the first render lazily fills the font metric cache and
  the arena, and rasterization reads those faces and the cache. Two threads
  through one Context race on that state. Use one Context per thread, or
  guard a shared one with an external mutex.

## Errors

Error sets are closed and never `anyerror`. The parse, layout, SVG and raster
sets are explicit:

- `ztex.parse.Error` — lexer and parser failures, all carrying a position. The
  CLI renders these with a caret under the offending span.
- `layout.render` returns `error{ OutOfMemory, InvalidAst }`. `InvalidAst`
  means the tree was malformed; it is detected by a single validation walk at
  the layout boundary, so a hand-built AST fails cleanly instead of panicking
  deep in layout.
- `ztex.svg.render` returns `error{ OutOfMemory, InvalidArgument,
  NonFiniteCoordinate }`. Padding must be finite and non-negative; a negative
  margin is rejected rather than emitted as a negative frame.
- `raster.rasterize` returns `error{ OutOfMemory, InvalidArgument,
  OutputTooLarge, NonFiniteCoordinate } || font.FontError`. It rejects
  non-positive or non-finite DPI/scale with `InvalidArgument`, non-finite ink
  bounds with `NonFiniteCoordinate`, and unrepresentable dimensions, stride
  or payload with `OutputTooLarge`, before allocating pixels. A missing glyph
  or empty outline draws nothing; a stretchy item without a usable variant
  degrades to the base glyph.

When you supply the `err_info` out-parameter, it is filled only on a parse
failure, and is left untouched on success or any non-parse error.

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

## Provenance

Every drawable carries the byte span of the source it came from, so a glyph in
the output maps back to its input in O(1). The span is exact through the
constructs that would otherwise break it: `\tag{1}`'s digits alias their own
source bytes rather than a synthesized copy, `\boxed`'s four rules carry the
span of the box they frame, an `\hline` carries the span of its own token, and
a synthesized glyph (`∑` from `\sum`, a stretchy variant) carries the span of
the construct that produced it even though no source bytes exist for it. The
wide accent's stroke carries the span of the whole `\widehat{…}` it spans.