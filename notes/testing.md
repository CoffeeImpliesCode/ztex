# ztex — testing strategy

Adapted from MicroTeX (no unit tests: golden-SVG corpus render, HAVE_LOG box-tree dump, MEM_CHECK valgrind pass), translated to the flat superflat pipeline: parse → atom pool → box pool → draw.

## 1. Component tests — the bulk, in-file, next to code

`test` blocks inside each module, run by `zig build test` (one
step per module: atom, parse, layout, ztex). No fixtures.

- lexer.zig: token kinds + byte spans, comments/whitespace,
  utf-8 validation, errors (DanglingEscape, InvalidUtf8),
  SIMD-vs-scalar `scanUntilStructural` differential test.
- parser.zig: every command (`\frac` `\atop` `\text` `\,` `\;`
  `\quad` `\qquad` `\!` `\sum`…`\oint` `\mathrm`…`\mathtt`),
  script folding (sup/sub/sub-only/DoubleScript), groups, every
  error path (UnknownCommand, MissingArgument, MissingScript,
  UnclosedGroup, UnexpectedRGroup, UnexpectedScript).
- atom.zig / box.zig: flat-pool invariants — contiguous child runs, span resolution, childref placement, NULL sentinels.
- layout/layout.zig: box kinds (char, hbox, vbox, rule, script),
  0.7× script scale, op limits, fraction rule vs `\atop`.
- metrics.zig: sorted table, glyph hits, estimate fallback, glue sanity.
- draw.zig: flatten — char→text, rule→rect, glue/strut→nothing,
  painter-order walk, provenance spans on every primitive.

## 2. Integration tests — src/tests/integration.zig (planned)

MicroTeX's headless render, end to end: call
`ztex.render(gpa, latex, pt)` and assert primitive kinds, counts,
x/y positions, sizes, `src_start`/`src_end` provenance. E.g.
`\frac{1}{2}+x` → 1 rect + N text; the bar's span covers the
`\frac` command. Exercises the facade; parser errors propagate
here too.

## 3. Regression tests — src/tests/regression.zig (planned)

MicroTeX's golden-SVG + HAVE_LOG dump, adapted to the draw list:
- golden draw-list snapshots (kind, coords, size, span) over a
  fixed corpus — the bench corpus + error-adjacent inputs;
- indented atom-tree dumps (tag + span per node).

Any layout change that alters output breaks a snapshot;
regenerate only on intentional changes — the exact geometry is pinned.

## 4. Memory / perf

- valgrind over the corpus = MEM_CHECK analog: `valgrind --leak-check=full --error-exitcode=1 zig-out/bin/ztex`
- `zig build bench` — ReleaseFast harness (src/bench/main.zig):
  ns/formula + drawables/formula over a 6-formula corpus.
- `hyperfine 'zig build bench'` for stable wall timing.
- valgrind, hyperfine, perf-tools are in devenv.nix.

## 5. How to run

    zig build test                   # component tests
    zig build bench                  # perf harness (ReleaseFast)
    valgrind --leak-check=full --error-exitcode=1 zig-out/bin/ztex
    hyperfine 'zig build bench'      # stable wall timing

CI: compile + `zig build test`; golden regression + valgrind run locally until snapshots land.
