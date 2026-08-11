# ztex — coverage reality and plan

## 1. Zig 0.16: no native coverage

Research conclusion (2026-08, cf. MicroTeX survey and Zig 0.16 build/test
docs): Zig has no built-in test-coverage mode. `zig test --coverage` does not
exist. `-femit-branch-hints`/gcov targets the C path, not Zig test code. The
only SanitizerCoverage available is via the fuzzer (`fuzz=true` in the build,
LLVM instrumentation), and turning that into per-file line coverage requires a
third-party tool, `zig-cov` (github.com/ericsssan/zcov). It works but needs
build wiring and an LLVM backend; it is not a `zig build test` drop-in.

## 2. Measured coverage: zig-cov (SanitizerCoverage via fuzzer)

Measured 2026-08-12, Zig 0.16.0 (LLVM backend), Debug. zig-cov is installed
at `~/tools/zcov` (symlinked as `~/.local/bin/zig-cov`);
its runtime object is `~/tools/zcov/zig-out/lib/zig-cov-rt.o`.
Instrumentation requires `use_llvm = true` + `fuzz = true` (the fuzzer's
inline 8-bit counters + PC table), and `Debug`/`ReleaseSafe` only — the
self-hosted backend and ReleaseFast/ReleaseSmall emit nothing.

### Recipe

1. `build.zig` already carries the `-Dcoverage` / `-Dcoverage-rt` options and
   applies them to the five test artifacts. The wiring had to be fixed once:
   ztex's test roots SHARE module instances (e.g. `ztex.atom` is both its own
   test root and an import of parse/layout/svg/ztex/tests), so tagging a
   shared module with the runtime object linked `zig-cov-rt.o` once per
   imported module and failed with `duplicate symbol: zig_cov_ctor`. Fix:
   every shared module gets `fuzz = true` once, and each test artifact gets a
   per-artifact root clone (same source + imports) that carries the single
   link of the runtime object + `link_libc`.
2. Run from the repo root:

   ```
   zig-cov test
   ```

   That is the exact working command. zig-cov injects
   `-Dcoverage=true -Dcoverage-rt=<its own zig-cov-rt.o>` itself and merges
   the `.zcov` files emitted by all five instrumented test binaries. Passing
   `-Dcoverage` / `-Dcoverage-rt` explicitly conflicts with the injected
   flags (`error: Flag '-Dcoverage' conflicts with option '-Dcoverage=true'`).
3. Report formats: `--format=summary` (default), `lcov`, `json`,
   `cobertura`, `html`, `github`; `--output=FILE` writes to a file
   (e.g. `zig-cov test --format=lcov --output=coverage.lcov`).
   Plain `zig build test` is unaffected and still passes.

### Per-file line coverage (2026-08-12)

| File | Lines covered | % |
|---|---|---|
| src/token.zig | 6/7 | 85.7% |
| src/parse/parser.zig | 173/269 | 64.3% |
| src/parse/lexer.zig | 93/157 | 59.2% |
| src/atom.zig | 44/78 | 56.4% |
| src/layout/metrics.zig | 41/74 | 55.4% |
| src/tests/regression.zig | 32/59 | 54.2% |
| src/parse/root.zig | 26/53 | 49.1% |
| src/layout/box.zig | 29/61 | 47.5% |
| src/layout/layout.zig | 154/350 | 44.0% |
| src/svg.zig | 16/37 | 43.2% |
| src/tests/integration.zig | 30/70 | 42.9% |
| src/tests/sanity.zig | 44/115 | 38.3% |
| src/layout/draw.zig | 51/140 | 36.4% |
| src/layout/root.zig | 8/25 | 32.0% |
| src/root.zig | 15/48 | 31.3% |
| src/tests/root.zig | 2/2 | 100.0% |
| **ztex total (src/)** | 764/1555 | 49.1% |
| zg dependency (DisplayWidth 61.5%, code_point 53.8%, ascii 50.0%, Graphemes 21.3%) | 66/168 | 39.3% |
| **Grand total (incl. zg)** | 830/1713 | 48.5% (exact blocks 41.0%, 846/2061) |

Caveats, per zig-cov's own docs:
- **Line coverage is approximate.** Coverage points are chosen for fuzzing
  benefit, not at every branch; Sema marks error-handling branches as points
  of interest and declines others (panic branches, "not valuable on either
  branch"). zig-cov attributes each source line to the last point at or
  before it — exact for straight-line code.
- The functions column is always 0/0 (fuzz instrumentation has no function
  granularity); line coverage is the only meaningful number.
- The integration/regression/sanity suites run from the `tests` artifact, so
  end-to-end paths are only credited there; per-module unit tests cover the
  rest. draw.zig/layout.zig/root.zig are the weakest — consistent with the
  known gaps below.

## 3. Coverage is a proxy

The regression snapshots (notes/testing.md §3) are the real guard: they pin
every geometry decision end to end, which is the artifact users see. The
zig-cov numbers exist to catch dead/untested branches snapshots cannot see
(error paths, edge codepoints, style combinations) — treat a drop in
layout.zig/draw.zig/parse coverage as the signal to add tests, not to chase
100%.
