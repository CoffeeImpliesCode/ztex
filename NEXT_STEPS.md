# Next steps after API conformance

## Goal and boundaries

Close analyzer and packaging gaps first. Then address documentation, portability, and measurement.
Do not redesign the public API without a confirmed defect.

This is a plan-only continuation of the API evolution work. The source baseline is
`058fdbb141d3a3862f835dcbb697cfb12de99b8a`, with Zig 0.16.0.
Existing execution evidence covers x86_64 Linux. Each new result must name its source,
compiler, target, optimization mode, command, and limits.

Keep the established ownership, allocator, I/O, and C-capacity contracts unchanged.
No consumer migration is planned. A confirmed defect that requires a contract change must include
all affected callers and documentation.

## 1. Triage every remaining zbc diagnostic

**Priority:** Highest. Resolve concrete correctness risks before portability or optimization work.

**Scope:** Current analyzer output, affected renderer code, and `audit2.md`.

1. Capture fresh, untruncated JSON output. The gate's printed count is not the total.
2. Classify every diagnostic as a confirmed defect, proven false positive, or unresolved analyzer
   limitation.
3. Prioritize unchecked numeric conversions, index narrowing, and slice bounds.
4. For each confirmed defect, add a boundary regression before the fix.
5. Run the corrected consumer path in the affected optimization modes.
6. Record retained diagnostics and the invariants the analyzer cannot prove.

Do not distort code or suppress diagnostics merely to obtain a clean report.

**Acceptance:** No diagnostic remains unclassified. Each real defect has failing-before and
passing-after evidence. Retained diagnostics have specific evidence, not a blanket dismissal.

## 2. Make package verification reproducible

**Scope:** `build.zig.zon`, existing build routes and consumer fixtures, and release-check tooling.

1. Diagnose the direct-checkout fetch timeout with controlled reduced copies and tracing.
2. Establish the cause before changing packaging behavior. Do not assume caches caused the timeout.
3. Convert the successful staged-package exercise into a repeatable check.
4. Stage exactly the declared `.paths` entries.
5. Fetch and extract the content-hashed payload.
6. Compile external consumers of all eight published modules.
7. Build the CLI, benchmark, and C archive from the extracted payload.
8. Run strict C89 and C++11 hosts against the installed package header and archive.
9. Render actual SVG and PGM output with the packaged CLI.

Use exported dependency routes. Do not assume a dependency installs artifacts under the parent's
`zig-out` directory.

**Acceptance:** A documented source-packaging route completes within a bounded timeout and passes
the consumer exercise. Explain the original timeout rather than only bypassing it.

## 3. Remove generated-doc errors and refresh evidence

**Scope:** Pinned `zg` generation, the docs build, `README.md`, and `audit2.md`.

1. Trace the EOF/newline errors to their producer in `zg v0.16.2`.
2. Fix generation at the source. Do not hand-edit cache files or generated tables.
3. Update the dependency pin only after regeneration and verification.
4. Rebuild documentation for all eight published modules.
5. Inspect every module root and representative symbol links in a managed browser.
6. Add a dated post-conformance evidence section to `audit2.md`.
7. Preserve historical results. Supersede the stale statement that SVG only paints base glyphs.

**Acceptance:** Documented ztex routes render correctly. Eliminate dependency diagnostics or attribute
them precisely. Do not reuse old test or diagnostic counts as fresh results.

## 4. Add bounded portability evidence

**Scope:** The existing header guard, static library, and external consumers.

Start with compile-only probes for these targets:

- 32-bit Linux: exercise pointer-width and allocation assumptions.
- AArch64 Linux: exercise another ABI.

1. Run the real-header check and static-library build in ReleaseSafe for each target.
2. Compile native and C consumers for each target.
3. Execute consumer hosts where a suitable runtime is available.
4. Record a compiler, target, and optimization-mode matrix.
5. Distinguish reached compilation from observed execution in every result.

**Acceptance:** Each claim has target-specific evidence. Cross-compilation alone does not expand
the advertised support contract.

## 5. Establish performance baselines

**Scope:** `src/bench/main.zig` and an external end-to-end consumer.

Source reading at the baseline shows that the benchmark measures static parse, layout, and flatten.
It does not measure font-backed SVG or raster rendering. Its warm-up is inside the timed interval.

1. Move warm-up outside steady-state timing.
2. Handle clock errors explicitly.
3. Measure small, typical, large, and near-limit valid formulas.
4. Record time, allocation counts, and peak live memory.
5. Measure Context SVG and CPU rendering separately.
6. Compare equivalent workloads with the same correctness checks.
7. Record compiler flags, CPU features, workload identifiers, and measurement boundaries.

Do not bypass AST validation to manufacture a speedup.

**Acceptance:** Results are repeatable and workload-scoped. Optimize only against a measured
regression or an explicit product budget.

## 6. Close the integration wave

**Dependency:** Complete the applicable fixes and checks above before final verification.

Run executable checks serially:

```sh
direnv exec . bash scripts/gate.sh --cov
direnv exec . zig build test docs static-lib -Doptimize=ReleaseSafe -j2 --summary all
```

1. Repeat unchecked-mode boundary checks where affected.
2. Repeat packaged native and C consumers where affected.
3. Exercise actual CLI rendering where affected.
4. Inspect generated documentation in a managed browser where affected.
5. Record the exact source, compiler, target, mode, commands, outcomes, and remaining limits.

**Acceptance:** Every changed behavior has exercised evidence. Do not automatically commit the mixed
working tree.

## Execution ownership and order

- Start with diagnostic triage, then clean packaging.
- Investigations in steps 1 through 3 can proceed independently.
- Assign one integration owner to shared `build.zig` and documentation changes.
- Keep executable gates serial after integration.
- Preserve unrelated and pre-existing user changes.
