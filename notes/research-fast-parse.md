# Research — fast parsing in Zig (SIMD + ecosystem)

Side task findings feeding the ztex parser design. Sources: two research scouts
+ mitchellh.com/writing/everyone-should-know-simd.

## SIMD: `@Vector` fast byte-scanning (Zig 0.16)

Canonical loop shape (mitchellh): broadcast constants → loop one vector at a
time → vector op → reduce (`@reduce`/`@bitCast`/`@ctz`) → scalar tail.

- Cross-platform lane count: `std.simd.suggestVectorLength(T) ?comptime_int`.
  Returns null ⇒ scalar; dead-code-eliminates the vector block on no-SIMD
  targets. One source compiles to SSE/NEON/AVX2/AVX512.
- Primitives: `@Vector(N,T)`, `@splat`, `@reduce(.Or/.And/...)`, `@bitCast`
  (bool vector → `std.meta.Int(.unsigned, N)` mask), `@ctz`/`@clz`.
- `std.simd` helpers: `iota`, `firstTrue`, `countTrues`, `firstIndexOfValue`,
  `prefixScan`. (No `std.simd.zigVector` in 0.16.)
- **Caution**: default x86_64 build target = baseline SSE only (16×u8).
  Build with `-Dcpu=native` to unlock AVX2/512.

### Applied to ztex

`src/parse/lexer.zig` `scanUntilStructural(src, pos)`: jumps a run of ordinary
printable bytes to the next structural byte (`% \ { } ^ _` + whitespace) — the
lexer's real hot loop. Scalar dispatch still handles the ≤vector-neighborhood
around each hit. Covered by a differential test (SIMD vs scalar reference).

### Verdict

Pays off: whitespace skip, comment-to-EOL, ASCII identifier runs, all-ASCII
bulk chunk. Does NOT pay: single-char dispatch `{}^_\` and per-codepoint decode
(branch-dominated). Keep the per-token path scalar.

## Zig parsing ecosystem

- **No pure-Zig LaTeX math renderer exists.** `zigtex` and `eztex` are thin
  Zig wrappers over C++ MicroTeX / tectonic — nothing to fork. Build fresh,
  borrowing MicroTeX/KaTeX structural ideas.
- **`std.zig.Tokenizer`** (public API, stable in 0.16): DFA tokenizer +
  single-pass parser building an arena-backed AST. Best stdlib reference.
- **Validark/Accelerated-Zig-Parser** (~1.4 GB/s, SIMD/SWAR): SIMD bitstrings,
  perfect-hash keyword lookup, sentinel-overalloc. Aggressive, tracks master.
- **travisstaloch/simdjzon**: simdjson port, faster than C++ simdjson on their
  bench; weekly-tested vs master.
- **Hejsil/mecha**: parser-combinator lib (606★, MIT) — good API reference,
  not for perf-critical lexing.
- **Unicode**: `zg` (codeberg.org/atman/zg, v0.16.3 = 0.16-compatible) and
  `sakakibara/unicode-zig` (property lookup, grapheme/word segmentation, width).

## Superflat AST + provenance (from vain/skript)

Both `~/projects/{vain,skript}` use a superflat AST: one flat `ArrayList(Node)`
of AoS structs; child links are contiguous index runs (`first_child` +
`num_children`); a parallel token table carries byte offsets (`start`/`end`);
nodes reference tokens by `first_token`+`num_tokens` ⇒ O(1) node→source span.
Nodes are by-value temps flushed via `appendSlice`; a parent re-copies its
children immediately before itself (duplication protocol) so child runs are
contiguous. Typed index with null sentinel; single append-only arena; no
pointer chasing; leaf values re-read from source span.

This is the pattern ztex adopts for its atom tree and box pool, and the token
table doubles as the provenance backbone: source → token → atom → box →
drawable all carry byte spans.
