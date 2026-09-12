# ztex

Zig 0.16 LaTeX-to-SVG renderer. It uses Juicy Main and `zg`, the sole dependency,
for Unicode 16 width, graphemes, and text. The toolchain comes from devenv.
The `.envrc` file selects that environment.

## Architecture

- `build.zig` defines the `ztex.atom`, `ztex.parse`, `ztex.layout`, and `ztex`
  modules, CLI, and benchmark.
- `src/root.zig` exposes `ztex.render(gpa, latex, pt) -> DrawList`.
- `src/parse/` lexes and parses to the atom tree. `src/atom.zig` is the parser/layout
  contract. `src/layout/` builds metrics, boxes, and drawables. `src/svg.zig` emits
  SVG with baseline offset and escaping.
- Keep the AST superflat: one node pool, child links as index runs, and a token
  table for O(1) source spans. Preserve provenance: source → token → atom → box
  → drawable.

## Conventions

- Use Zig 0.16 idioms: thread `std.Io` through I/O; use unmanaged containers with
  explicit allocator arguments, `.empty` literals, and `@import("root")`.
- Use explicit `gpa` or `arena` allocators, avoid hidden allocations, and clean up
  with `defer` or `errdefer`.
- Use explicit error sets; do not leak `anyerror` or discard values with `_ =`.
- Keep lines at or below 100 columns. Format with `zig fmt`; tests live beside code
  in `src/` and run with `zig build test`.
- Do not preserve dead code for backward compatibility.

## Commands

Run from the repository root:

- `direnv allow` enters devenv on first use or after `devenv.nix` changes.
- `zig build` builds `zig-out/bin/ztex`.
- `zig build run -- -i 'x^2' -o out.svg -s 20 -p 4` writes SVG.
  `zig build run -- -i 'x^2'` writes to stdout.
- `zig build test` runs unit, integration, and regression tests across modules.
- `zig build bench` runs ReleaseFast parse/layout/flatten benchmarks.
  `zig build bench -Dcpu=native` enables native vector features.
- `zig-cov test` runs line coverage. `zig fmt --check .` checks formatting.
  `zlint` runs linting; prefer `~/.local/bin/zlint`.
- `gate` runs `bash scripts/gate.sh [zig-gate args...]`: zwanzig default rules over
  `src`, `tools`, and `build.zig` with two threads, then zig-gate. Missing or failing
  stages fail the gate. `ZWANZIG_THREADS` accepts a positive decimal. Analyzer lookup
  is `ZWANZIG`, `~/.local/bin/zwanzig`, then `PATH`. Gate tools prefer local
  `ziglint`, `zlint`, `zbc`, `zig-cov`, and `zwanzig` in `~/.local/bin`, then `PATH`.
- `hyperfine 'zig build bench'` compares benchmark runs.

Start with `jj st`. Keep changes focused. Commit only after formatting, build, tests,
and lint pass. Never use Git commands.
