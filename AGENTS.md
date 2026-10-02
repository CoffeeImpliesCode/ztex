# ztex

Zig 0.16 LaTeX-to-SVG renderer, with a CPU rasterizer. `zg` is the sole
dependency, supplying Unicode 16 width, graphemes, and text decoding. The
toolchain comes from devenv: `devenv.nix` provides zig 0.16, and the `.envrc`
selects that environment.

## Architecture

- `build.zig` publishes `ztex.atom`, `ztex.parse`, `ztex.layout`, `ztex.font`,
  `ztex.glyph`, `ztex.svg`, `ztex`, and `ztex.c`; the integration-test root is
  private. It wires the CLI, benchmark, per-module docs, `static-lib`, and
  real-header C/C++ consumer checks. Only CLI and benchmark install by default.
- `src/root.zig` is the facade. `ztex.render` measures from the bundled static
  tables; `ztex.Context` measures from the embedded Latin Modern faces. Both
  call one `renderPipeline`, so the two differ only in metric source. That
  helper is `pub` only so `src/context.zig` can reach it across files through a
  relative `@import("root.zig")`; it is internal, not host API.
  `Context.renderPixels` / `ztex.renderPixels` rasterize to a `PixelBuffer`.
  The facade re-exports `font` and `raster` alongside the modules.
- `src/parse/` lexes and parses to the atom tree. `src/atom.zig` is the
  parser/layout contract. `src/layout/` builds metrics, boxes, and drawables.
  `src/svg.zig` emits real outlines for every available glyph and uses text
  only for unavailable-glyph fallback. `src/mathglyph.zig` resolves MATH
  forms and streams assemblies for both SVG and CPU. `src/coverage.zig` is
  the bezier scanline rasterizer; `src/raster.zig` paints draw lists to PPM/PGM.
- `src/font.zig` parses OpenType/CFF and TrueType/glyf plus the OpenType MATH
  table: constants, per-glyph values, horizontal AND vertical variant ladders,
  and glyph assemblies. `FontFace` exposes them as `mathConstants`,
  `mathValues`, `variants`, `assembly`; a face without a MATH table (the four
  embedded LM Roman faces, any user font) answers null. The constants are
  borrowed once into `FontMetrics.math_constants` and read through
  `metrics.mathConstants`; the per-glyph values ride the
  `FontContext.metrics_cache` and reach layout through
  `metrics.fontItalicCorrection` and `metrics.fontTopAccentAttachment`. None of
  it is test-only. The rasterizer degrades to the base glyph for a face with
  no MATH. No draw path names a glyph id.
- `src/fonts/` is generated payload — LM Math plus LM Roman regular, italic,
  bold and bold-italic, five faces, ~1.19 MB of font bytes.
  `scripts/embed_font.py` regenerates it; do not hand-edit the arrays.
- `src/ztex_c.zig` and `include/ztex.h` are the C ABI: six `ztex_`-prefixed
  symbols over a caller-supplied allocator, integer status codes, and output
  copied into a caller buffer. `include/ztex.h` is hand-written and is the
  contract; keep the two in step.
- Keep the AST superflat: one node pool, child links as index runs, and a token
  table for O(1) source spans. Preserve provenance: source → token → atom → box
  → drawable.
- `DrawList` carries two bounds: the box bounds (`width`/`height`/`depth`, from
  the root box) and the exact ink bounds (`bounds()`, accumulated by
  `flatten`). Content extents come from the ink bounds. A glyph's horizontal
  ink extent is its advance box UNIONED with the real ink overhang the layout
  measured from the drawn face (`metrics.GlyphInk`, stashed by
  `layout.setCharOverhang`), so an italic `f`, a negative left side bearing or
  a combining mark is framed by what it paints, not by its advance alone.
- CFF cubics are split at both coordinate extrema before quadratic fitting.
  Each monotonic fit keeps its control within the endpoint interval. Preserve
  this enclosure: zero-padding framing must not hide an approximation overshoot.

## Conventions

- Use Zig 0.16 idioms: thread `std.Io` through I/O; use unmanaged containers with
  explicit allocator arguments, `.empty` literals, and `@import("root")`.
- Use explicit `gpa` or `arena` allocators, avoid hidden allocations, and clean up
  with `defer` or `errdefer`.
- Use explicit error sets; do not leak `anyerror` or discard values with `_ =`.
- Keep lines at or below 100 columns. Format with `zig fmt`; tests live beside code
  in `src/` and run with `zig build test`.
- Comments carry invariants, encodings, ownership rules, and TeX-measured
  values. Do not write comments that restate a signature or repeat a header,
  and do not put issue or audit IDs in source comments.
- SVG output carries units in exactly one place: `svg.render` writes the
  physical size on the root element (`width`/`height` with `pt`) and a
  unitless `viewBox`, and every inner coordinate, `font-size` and
  `stroke-width` is unitless. Putting `pt` on an inner coordinate scales it
  twice (96/72 × pt) and visibly clips the content.
- SVG glyph paths carry absolute geometry. Fallback math text declares
  `font-style="normal"` because LM Math glyphs are already italic.
  `font-style="italic"` belongs to text-italic and bold-italic fallback.
- Do not preserve dead code for backward compatibility.

## Commands

Run from the repository root:

- `direnv allow` enters devenv on first use or after `devenv.nix` changes.
- `zig build` installs `zig-out/bin/ztex` and `zig-out/bin/ztex-bench`.
- `zig build run -- -i 'x^2' -o out.svg -s 20 -p 4` writes SVG.
  `zig build run -- -i 'x^2'` writes to stdout.
- `ztex --help` lists the CLI. `--style display|text` picks the math style
  for the whole formula (display for a standalone equation, text for inline
  math). Raster output is selected by `--ppm`/`--pgm` or by an output path
  ending in `.ppm`, `.pnm`, or `.pgm`; there is no PNG encoder, so everything
  else is SVG.
- `zig build test` runs nine native test roots, the real-header ABI check, and
  real C89/C++ consumers. `--summary all` prints counts; read them from the command.
  `zig build test-layout -Dtest-filter='substring'` selects one root and matching tests.
  Roots include tests of path imports; named imports do not bring tests with them.
  `test-c-header` checks ABI parity; `test-c-consumers` runs both real hosts.
- `zig build bench` runs the ReleaseFast parse/layout/flatten benchmark.
  Override with `-Dbench-optimize=<Mode>`. `zig build bench -Dcpu=native`
  enables native vector features.
- `zig build docs` emits separate published-module roots to `zig-out/docs/<name>`.
- `zig build static-lib` builds `zig-out/lib/libztex.a` and installs
  `include/ztex.h` to `zig-out/include/ztex.h`. A C host links it with libm.
  GNU ld consumers also need `-Wl,-z,noexecstack`: the Zig 0.16 archive lacks
  `.note.GNU-stack`; without that flag the consumer has an executable stack.
- `zig-cov test` runs line coverage. `zig fmt --check .` checks formatting.
  `zlint` runs linting; prefer `~/.local/bin/zlint`.
- `gate` runs `bash scripts/gate.sh [zig-gate args...]`: zwanzig default rules over
  `src`, `tools`, and `build.zig` with two threads, then zig-gate. Missing or failing
  zwanzig stops the gate. `ZWANZIG_THREADS` accepts a positive decimal. Analyzer lookup
  is `ZWANZIG`, `~/.local/bin/zwanzig`, then `PATH`. Delegated gate tools prefer local
  `ziglint`, `zlint`, `zbc`, and `zig-cov` in `~/.local/bin`, then `PATH`; an absent
  optional tool may be skipped, so check which stages actually ran. Pass `--cov`
  for coverage. The final-wave run exercised fmt, build, tests, ast-check, zlint,
  advisory zbc and coverage; zwanzig and every required stage passed.
  `zbc` is advisory; its untruncated diagnostics are recorded in `audit2.md`, not
  suppressed. The wrapper's printed count excludes warnings and its output is truncated.
  The recursive-parser diagnostic misses the `max_nesting` counter:
  20 KB and 100 KB of nested input both fail cleanly with `error.NestingTooDeep`
  and a caret.
- `hyperfine 'zig build bench'` compares benchmark runs.

Start with `jj st`. Keep changes focused. Commit only after formatting, build, tests,
and lint pass. Never use Git commands.
