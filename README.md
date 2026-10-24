# ztex

Experimental LaTeX math renderer in Zig. It parses formulas into a flat atom tree,
produces a draw list, and renders SVG outlines or CPU raster images.
Bundled Latin Modern fonts provide glyphs and OpenType MATH metrics.

## Requirements and status

- Zig 0.17.0.
- `zg` v0.18.0 with the upstream Zig 0.17 compatibility patch from PR #108.
- `translate-c` 2.0.2 for the C header checks.
- Network access for the first dependency fetch.

The library needs no installed fonts for bundled glyphs. Missing SVG glyphs use
external text fonts; missing raster glyphs paint no ink. Font discovery can use
`fc-list`. Optional comparison scripts require their respective reference engines
and Python packages; they are separate from the library build.

## Build and run

```sh
zig build
zig build test
zig build test -Doptimize=safe
zig build static-lib
zig build docs
zig build bench
zig build run -- -i '\frac{a+b}{c-d}' -o formula.svg -s 20
zig build run -- -i 'x^2' -o formula.ppm --dpi 200
zig build run -- -i 'x_2' --style text --pgm -o formula.pgm
```

The default build installs the CLI and benchmark in `zig-out/bin`.
`static-lib` installs `zig-out/lib/libztex.a` and `zig-out/include/ztex.h`.
`docs` writes module documentation to `zig-out/docs`.
`test` includes native tests, header ABI checks, and linked C89/C++ consumers.
Use `test-atom`, `test-parse`, `test-layout`, `test-svg`, `test-ztex`, `test-tests`,
`test-c`, `test-font`, or `test-glyph` for one native root. A substring filter is
available through `-Dtest-filter='substring'`. C checks have separate
`test-c-header` and `test-c-consumers` steps.

SVG is the default CLI output. `--ppm`, `--pgm`, or a `.ppm`/`.pgm` output suffix
selects raster output. `-p` sets padding in points for SVG and pixels for raster.
Run `ztex --help` for all options. PPM composites RGBA over white; PGM stores
coverage multiplied by ink alpha.

## Zig integration

Fetch a chosen repository revision with Zig's package manager:

```sh
zig fetch --save=ztex 'git+https://github.com/CoffeeImpliesCode/ztex#main'
```

In the consumer's `build.zig`:

```zig
const dep = b.dependency("ztex", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ztex", dep.module("ztex"));
```

One-shot rendering uses static metric tables:

```zig
const ztex = @import("ztex");
var dl = try ztex.render(gpa, latex, .display, 20, null);
defer dl.deinit();
const svg = try ztex.svg.render(gpa, &dl, .{});
defer gpa.free(svg);
```

For repeated renders, retain a context with real-font metrics and a glyph cache:

```zig
var ctx = try ztex.Context.init(gpa);
defer ctx.deinit();
var pixels = try ctx.renderPixels(latex, .display, 20, .{ .dpi = 200 }, null);
defer pixels.deinit();
```

Use `.display` for standalone equations and `.text` for inline math.
`ztex.parse.supported_commands` enumerates accepted commands. The parser supports
fractions, scripts, radicals, stretchy delimiters, accents, matrices, arrays,
text styles, colors, and equation tags; it is not a complete TeX engine.

### Modules

| Module | Role |
| --- | --- |
| `ztex` | Rendering facade, `Context`, and raster output |
| `ztex.atom` | AST and source spans |
| `ztex.parse` | UTF-8 lexer and parser |
| `ztex.layout` | Metrics, boxes, and draw lists |
| `ztex.font` | OpenType decoding and font ownership |
| `ztex.glyph` | MATH glyph variants and assemblies |
| `ztex.svg` | SVG output |
| `ztex.c` | C ABI types and exported functions |

Sources follow this layout under `src/`; integration tests are in `src/tests/`.
`scripts/` contains font-table generation and reference-engine comparison tools.

## Ownership and errors

Call `deinit` once on each owning AST, draw list, context, outline, or pixel buffer.
Do not dispose both an owner and a value-copy of it. Free returned slices with
the allocator that produced them. ASTs borrow their source; draw lists can retain
source slices after the AST is disposed. Keep the source alive and unchanged.
Pixel buffers own their pixels independently of source and context.

Contexts and font caches require serialized access or one context per thread.
Static-table rendering is independent per call with immutable inputs and a
thread-safe allocator. Rendering performs no file I/O. File helpers take an
explicit `std.Io`; writes can leave partial files on error.

Sizes must be finite and positive. The parser bounds source size and nesting;
layout validates public AST inputs. Native errors remain Zig error sets. An
`err_info` argument receives a diagnostic only for syntax and source-limit errors,
not allocation failures. See the public declarations for individual error sets.

## C ABI

Include `ztex.h` and link `libztex.a` with `-lm`. The header supports C89 and C++.
The six entry points create/destroy a context, render SVG/raster, return a status
name, and copy the last error. All allocations use the supplied allocator callbacks;
keep them and their user data valid until context destruction.

LaTeX input is counted UTF-8. Output buffers are caller-owned. A size query uses
`out = NULL` and capacity zero; a successful render needs payload length plus one
byte for the trailing NUL, including raster output. Short buffers remain unwritten.
Output lengths exclude the NUL. Check status codes before reading output metadata.
See `include/ztex.h` for option defaults, limits, and callback requirements.

## License

No project LICENSE file is present. A project license has not been specified.
