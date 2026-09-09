# ztex

Zig 0.16 project (house scaffold). Purpose TBD — initialized to the same
conventions as `~/projects/{noapi, nogui, skript, wayland, notui}`.

## Stack

- **Language**: Zig 0.16 (module API, `std.Io`, Juicy Main)
- **Sole dep**: zg (Unicode 16: width, graphemes, text)
- **VCS**: jj — DO NOT USE GIT COMMANDS
- **Dev env**: devenv + direnv (`.envrc` → `use devenv`)
- **Linting**: zlint (`zlint.json` rules) + `zig fmt --check`
- **Toolchain**: `zig` from devenv (nixpkgs 0.16)
- **Lint/analyze tools**: the gate prefers local tools (`~/.local/bin/ziglint`, `~/.local/bin/zlint`, `~/.local/bin/zbc`, `~/.local/bin/zig-cov`, `~/.local/bin/zwanzig`) and falls back to `PATH`. The required analyzer resolves from `ZWANZIG`, then the local path, then `PATH`.

## Structure

```
build.zig          # modules: ztex.atom/parse/layout/ztex + exe + bench steps
build.zig.zon      # package manifest (fingerprint, paths)
devenv.nix         # nix dev env (zig, zlint, hyperfine, valgrind, perf-tools)
.envrc             # direnv → devenv hook
AGENTS.md          # this file
src/
├── root.zig       # facade: ztex.render(gpa, latex, pt) → DrawList
├── main.zig       # CLI: -i <latex> -o <file.svg> -s <pt> -p <pad>
├── atom.zig       # superflat atom AST (parse↔layout contract) + token spans
├── token.zig      # Token + Span (provenance currency)
├── svg.zig        # ztex.svg: draw list → SVG (baseline offset, escaping)
├── parse/         # ztex.parse module: lexer, parser → atom tree
├── layout/        # ztex.layout module: metrics, box, draw, layout
├── tests/         # ztex.tests: integration + regression + sanity
└── bench/         # benchmark harness (zig build bench)
notes/             # architecture, MicroTeX map, fast-parse research, coverage
```

Superflat AST (house pattern, cf. vain/skript): one flat node pool, child
links are index runs, token table gives O(1) source spans; provenance flows
source → token → atom → box → drawable.

## Commands

```bash
direnv allow        # enter devenv shell (first time / after devenv.nix edits)
zig build           # Debug build → zig-out/bin/ztex
zig build run -- -i 'x^2' -o out.svg -s 20 -p 4   # formula → SVG file
zig build run -- -i 'x^2'                # formula → SVG on stdout
zig build test      # unit + integration + regression tests (all modules)
zig build bench     # ReleaseFast benchmark (parse+layout+flatten throughput)
zig build bench -Dcpu=native   # unlock AVX2/512 (default = baseline SSE)
zig-cov test        # line coverage (installed zig-cov; ~49% baseline)
zig fmt --check .   # formatting gate
zlint               # lint (prefer ~/.local/bin/zlint; devenv nixpkgs is fallback)
gate                # required gate: bash scripts/gate.sh [zig-gate args...]; runs zwanzig default rules with 2 threads over src tools build.zig, then zig-gate; set ZWANZIG_THREADS to a positive decimal override or ZWANZIG to an executable path/command; missing or failing stages fail the gate
hyperfine 'zig build bench'  # stable cross-run timing
jj st               # working-copy status (never git)
```

## Conventions

- Tiger style: explicit allocators, no hidden allocations, `defer`/`errdefer`
  cleanup, named `gpa`/`arena` allocator params
- Zig 0.16 idioms only: `std.Io` threaded through I/O, unmanaged containers
  with explicit allocator args, `.empty` decl literals, `@import("root")`
- Error sets explicit; no `anyerror` leaks; no `_ =` discards
- `zig fmt` before finishing any change; lines ≤ 100 columns
- Unit tests live next to code in `src/`; run via `zig build test`
- No backwards compatibility: delete dead code, change directly

## Version control workflow (jj)

- Start every task from a CLEAN working state: run `jj st` first and confirm
  no uncommitted changes (nothing staged, nothing modified). If dirty, commit
  or stash the pending work BEFORE starting new work.
- One logical change per commit: after each fix or feature, immediately
  `jj commit -m "..."` with a focused message describing the change. NEVER
  accumulate uncommitted changes across multiple tasks.
- Commit only green work (gates pass: fmt, build, test, zlint). Never commit
  a red tree.
- Never use git commands.

## Development

- Use tools, always use `edit`/`write` for file changes — NEVER patch files
  with inline python/perl/sed/awk scripts, heredocs, or `echo >` redirection
- Read with `read`, search with `grep`/`glob`; shell is for builds/tests and
  one-shot fact queries only
- NEVER use web_* tools (broken) — for web search use the local server at
  `localhost:4444`; prefer reading primary sources directly
- Delegate aggressively: many small subagents over few big ones; give full
  instructions; assume subagents are dumb
- Parallelize: N independent files → N workers
