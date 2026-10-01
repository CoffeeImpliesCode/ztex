# ztex

Zig 0.16 LaTeX-to-SVG renderer, with a CPU rasterizer. `zg` is the sole
dependency, supplying Unicode 16 width, graphemes, and text decoding. The
toolchain comes from devenv: `devenv.nix` provides zig 0.16, and the `.envrc`
selects that environment.

## Architecture

- `build.zig` defines the `ztex.atom`, `ztex.parse`, `ztex.layout`, `ztex.svg`,
  and `ztex` modules, plus the CLI, the benchmark, the golden generator, and
  the docs step.
- `src/root.zig` is the facade. `ztex.render` measures from the bundled static
  tables; `ztex.Context` measures from the embedded Latin Modern faces. Both
  call one private `renderPipeline`, so the two differ only in metric source.
  `Context.renderPixels` / `ztex.renderPixels` rasterize to a `PixelBuffer`.
- `src/parse/` lexes and parses to the atom tree. `src/atom.zig` is the
  parser/layout contract. `src/layout/` builds metrics, boxes, and drawables.
  `src/svg.zig` emits SVG with baseline offset and escaping. `src/raster.zig`
  rasterizes a draw list to PPM/PGM. `src/font.zig` parses OpenType/CFF.
- Keep the AST superflat: one node pool, child links as index runs, and a token
  table for O(1) source spans. Preserve provenance: source → token → atom → box
  → drawable.
- `DrawList` carries two bounds: the box bounds (`width`/`height`/`depth`, from
  the root box) and the exact ink bounds (`bounds()`, accumulated by
  `flatten`). Content extents come from the ink bounds; the horizontal ink edge
  is the glyph advance box, which is why a small frame margin remains.

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
- Do not preserve dead code for backward compatibility.

## Commands

Run from the repository root:

- `direnv allow` enters devenv on first use or after `devenv.nix` changes.
- `zig build` builds `zig-out/bin/ztex`.
- `zig build run -- -i 'x^2' -o out.svg -s 20 -p 4` writes SVG.
  `zig build run -- -i 'x^2'` writes to stdout.
- `ztex --help` lists the CLI. Raster output is selected by `--ppm`/`--pgm` or
  by an output path ending in `.ppm`, `.pnm`, or `.pgm`; there is no PNG
  encoder, so everything else is SVG.
- `zig build test` runs unit, integration, and regression tests across modules
  (244 tests). `zig build test --summary all` prints per-module counts.
- `zig build bench` runs the ReleaseFast parse/layout/flatten benchmark.
  Override with `-Dbench-optimize=<Mode>`. `zig build bench -Dcpu=native`
  enables native vector features.
- `zig build gen-goldens` prints ready-to-paste golden tables after an intended
  rendering change. `zig build docs` emits the API docs to `zig-out/docs`.
- `zig-cov test` runs line coverage. `zig fmt --check .` checks formatting.
  `zlint` runs linting; prefer `~/.local/bin/zlint`.
- `gate` runs `bash scripts/gate.sh [zig-gate args...]`: zwanzig default rules over
  `src`, `tools`, and `build.zig` with two threads, then zig-gate. Missing or failing
  stages fail the gate. `ZWANZIG_THREADS` accepts a positive decimal. Analyzer lookup
  is `ZWANZIG`, `~/.local/bin/zwanzig`, then `PATH`. Gate tools prefer local
  `ziglint`, `zlint`, `zbc`, `zig-cov`, and `zwanzig` in `~/.local/bin`, then `PATH`;
  a missing tool is skipped, not failed, so check that the stage actually ran.
- `hyperfine 'zig build bench'` compares benchmark runs.

Start with `jj st`. Keep changes focused. Commit only after formatting, build, tests,
and lint pass. Never use Git commands.
