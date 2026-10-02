//! Native modules, CLI, benchmark, API docs, and the opt-in C archive.
//! A dependency uses `module("ztex")` or a documented `ztex.*` module;
//! `artifact("ztex")` supplies the C archive, and `static-lib` installs its header.

const std = @import("std");

/// Registers the published modules and named build/check steps.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-cov coverage (Zig 0.16 has no native coverage; this uses the
    // fuzzer's SanitizerCoverage). Usage: build zig-cov, then
    //   zig-cov test
    // zig-cov injects -Dcoverage=true -Dcoverage-rt=<its runtime> itself;
    // passing -Dcoverage/-Dcoverage-rt explicitly conflicts.
    const use_coverage = b.option(bool, "coverage", "Instrument tests for zig-cov") orelse false;
    const coverage_rt = b.option([]const u8, "coverage-rt", "Path to zig-cov runtime object (.o)") orelse null;

    // Sole dependency: zg — Unicode 16 text/width/graphemes.
    const zg = b.dependency("zg", .{});

    // ── ztex.atom — shared AST (the parse ↔ layout contract) ──
    const atom = b.addModule("ztex.atom", .{
        .root_source_file = b.path("src/atom.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── ztex.parse — source → atom tree ───────────────────────
    const parse = b.addModule("ztex.parse", .{
        .root_source_file = b.path("src/parse/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.atom", .module = atom },
            .{ .name = "zg", .module = zg.module("zg") },
        },
    });

    // ── ztex.layout — atom tree + metrics → box tree → draw list ─
    const layout = b.addModule("ztex.layout", .{
        .root_source_file = b.path("src/layout/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.atom", .module = atom },
            .{ .name = "zg", .module = zg.module("zg") },
            .{ .name = "DisplayWidth", .module = zg.module("DisplayWidth") },
            .{ .name = "Graphemes", .module = zg.module("Graphemes") },
        },
    });

    // ── ztex.font — sfnt/CFF/TrueType parsing, MATH tables, embedded faces ──
    // Named, not path-imported: `ztex.svg` needs outlines to emit real
    // variant geometry, and a file module can belong to only one module.
    const ztex_font = b.addModule("ztex.font", .{
        .root_source_file = b.path("src/font.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.atom", .module = atom },
        },
    });

    // ── ztex.glyph — the one MATH selection both back ends draw ──────────
    const ztex_glyph = b.addModule("ztex.glyph", .{
        .root_source_file = b.path("src/mathglyph.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.font", .module = ztex_font },
        },
    });

    // ── ztex.svg — serialize a draw list to SVG ───────────────
    const svg = b.addModule("ztex.svg", .{
        .root_source_file = b.path("src/svg.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.layout", .module = layout },
            .{ .name = "ztex.font", .module = ztex_font },
            .{ .name = "ztex.glyph", .module = ztex_glyph },
        },
    });

    // ── ztex — facade: parse(latex) → DrawList ────────────────
    const ztex = b.addModule("ztex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.atom", .module = atom },
            .{ .name = "ztex.parse", .module = parse },
            .{ .name = "ztex.layout", .module = layout },
            .{ .name = "ztex.svg", .module = svg },
            .{ .name = "ztex.font", .module = ztex_font },
            .{ .name = "ztex.glyph", .module = ztex_glyph },
        },
    });

    // Private integration/regression root, not a dependency module.
    const tests = b.createModule(.{
        .root_source_file = b.path("src/tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex", .module = ztex },
            .{ .name = "ztex.parse", .module = parse },
            .{ .name = "ztex.atom", .module = atom },
        },
    });

    // ── ztex.c — C ABI root: the static library, and its own test root ──
    const c_abi = b.addModule("ztex.c", .{
        .root_source_file = b.path("src/ztex_c.zig"),
        .target = target,
        .optimize = optimize,
        // A C host usually links this archive into a PIE or a shared
        // object, so it is built PIC; plain executables never notice.
        .pic = true,
        .imports = &.{
            .{ .name = "ztex", .module = ztex },
        },
    });

    // ── ztex executable ────────────────────────────
    const exe = b.addExecutable(.{
        .name = "ztex",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztex", .module = ztex },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run ztex");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ── unit tests (one step per module) ───────────────────────
    const test_step = b.step("test", "Run all unit tests");
    const test_filter = b.option([]const u8, "test-filter", "Run tests matching this substring");
    const mods = [_]struct {
        name: []const u8,
        module: *std.Build.Module,
        root: std.Build.LazyPath,
    }{
        .{ .name = "atom", .module = atom, .root = b.path("src/atom.zig") },
        .{ .name = "parse", .module = parse, .root = b.path("src/parse/root.zig") },
        .{ .name = "layout", .module = layout, .root = b.path("src/layout/root.zig") },
        .{ .name = "svg", .module = svg, .root = b.path("src/svg.zig") },
        .{ .name = "ztex", .module = ztex, .root = b.path("src/root.zig") },
        .{ .name = "tests", .module = tests, .root = b.path("src/tests/root.zig") },
        .{ .name = "c", .module = c_abi, .root = b.path("src/ztex_c.zig") },
        .{ .name = "font", .module = ztex_font, .root = b.path("src/font.zig") },
        .{ .name = "glyph", .module = ztex_glyph, .root = b.path("src/mathglyph.zig") },
    };

    // Coverage wiring. The test roots below SHARE module instances (atom is
    // both its own test root and an import of parse/layout/svg/ztex/tests),
    // so tagging a shared module with the zig-cov runtime object would link
    // zig-cov-rt.o once per imported module → duplicate `zig_cov_ctor`.
    // Instead: every shared module gets fuzz instrumentation (per-file
    // counters + PC table), and each test artifact gets a per-artifact root
    // clone that carries the single link of the runtime object.
    if (use_coverage) {
        for (mods) |m| m.module.fuzz = true;
    }
    for (mods) |m| {
        var root_module = m.module;
        if (use_coverage) {
            var imports: []const std.Build.Module.Import = &.{};
            if (m.module.import_table.count() > 0) {
                const arr = b.allocator.alloc(
                    std.Build.Module.Import,
                    m.module.import_table.count(),
                ) catch @panic("OOM");
                for (m.module.import_table.keys(), m.module.import_table.values(), 0..) |name, mod, i| {
                    arr[i] = .{ .name = name, .module = mod };
                }
                imports = arr;
            }
            root_module = b.createModule(.{
                .root_source_file = m.root,
                .target = target,
                .optimize = optimize,
                .imports = imports,
            });
            root_module.fuzz = true;
            root_module.link_libc = true;
            if (coverage_rt) |p| root_module.addObjectFile(.{ .cwd_relative = p });
        }
        const t = b.addTest(.{
            .root_module = root_module,
            .filters = if (test_filter) |filter| &.{filter} else &.{},
        });
        if (use_coverage) t.use_llvm = true; // instrumentation needs the LLVM backend
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        const module_step = b.step(
            b.fmt("test-{s}", .{m.name}),
            b.fmt("Run {s} tests", .{m.name}),
        );
        module_step.dependOn(&run_t.step);
    }

    // ── benchmark ───────────────────────────────────────────
    // Benchmarks must measure optimized code, so they default to ReleaseFast
    // instead of the global Debug default. An explicit -Dbench-optimize wins;
    // an explicit -Doptimize (or --release) still steers the bench mode.
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimize mode for the benchmark artifact (default: ReleaseFast)",
    ) orelse if (optimize != .Debug) optimize else .ReleaseFast;
    const bench_exe = b.addExecutable(.{
        .name = "ztex-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{
                .{ .name = "ztex", .module = ztex },
            },
        }),
    });
    const bench_step = b.step(
        "bench",
        "Run benchmark harness (ReleaseFast; override with -Dbench-optimize)",
    );
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    bench_step.dependOn(&run_bench.step);

    // ── C ABI static library ──────────────────────────────────
    // A separate step, NOT part of the default install: a Zig-only user's
    // `zig build` still builds exactly what it built before.
    const c_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "ztex",
        .root_module = c_abi,
    });
    const install_c_lib = b.addInstallArtifact(c_lib, .{});
    const install_c_header = b.addInstallDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .prefix,
        .install_subdir = "include",
    });
    const c_lib_step = b.step(
        "static-lib",
        "Build the C ABI static library and install its header (zig-out/lib/libztex.a)",
    );
    c_lib_step.dependOn(&install_c_lib.step);
    c_lib_step.dependOn(&install_c_header.step);

    // Header translation is test-only; native dependencies do not need C parsing.
    const translated_header = b.addTranslateC(.{
        .root_source_file = b.path("include/ztex.h"),
        .target = target,
        .optimize = optimize,
    });
    const translated_environment = b.addTranslateC(.{
        .root_source_file = b.path("src/tests/c_environment.h"),
        .target = target,
        .optimize = optimize,
    });
    // A test runner replaces @import("root"), hiding the marker from ztex.c.
    const header_guard = b.addObject(.{
        .name = "ztex-c-header",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/c_abi_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "header", .module = translated_header.createModule() },
                .{ .name = "environment", .module = translated_environment.createModule() },
                .{ .name = "ztex.c", .module = c_abi },
            },
        }),
    });
    test_step.dependOn(&header_guard.step);
    b.step("test-c-header", "Check the real header against the Zig ABI").dependOn(
        &header_guard.step,
    );

    const c_consumer_step = b.step("test-c-consumers", "Run real C89 and C++ consumers");
    for ([_][]const u8{ "c", "cpp" }) |language| {
        const consumer_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        consumer_module.addIncludePath(b.path("include"));
        consumer_module.addCSourceFile(.{
            .file = b.path(if (std.mem.eql(u8, language, "c"))
                "src/tests/c_consumer.c"
            else
                "src/tests/cxx_consumer.cpp"),
            .flags = if (std.mem.eql(u8, language, "c"))
                &.{ "-std=c89", "-pedantic-errors", "-Wall", "-Wextra", "-Werror" }
            else
                &.{ "-std=c++11", "-pedantic-errors", "-Wall", "-Wextra", "-Werror" },
        });
        consumer_module.linkLibrary(c_lib);
        const consumer = b.addExecutable(.{
            .name = b.fmt("ztex-{s}-consumer", .{language}),
            .root_module = consumer_module,
        });
        const run_consumer = b.addRunArtifact(consumer);
        test_step.dependOn(&run_consumer.step);
        c_consumer_step.dependOn(&run_consumer.step);
    }

    const docs_step = b.step("docs", "Generate docs for every published module");
    for (mods) |m| {
        if (std.mem.eql(u8, m.name, "tests")) continue;
        var doc_module = m.module;
        var copied_sources: ?[4]std.Build.LazyPath = null;
        if (!std.mem.eql(u8, std.fs.path.basename(m.root.getPath(b)), "root.zig")) {
            // Autodoc chooses root.zig by convention, not the compiler's root filename.
            const sources = b.addWriteFiles();
            copied_sources = .{
                sources.addCopyDirectory(b.path("src"), "", .{
                    .exclude_extensions = &.{"root.zig"},
                }),
                sources.addCopyFile(b.path("src/parse/root.zig"), "parse/root.zig"),
                sources.addCopyFile(b.path("src/layout/root.zig"), "layout/root.zig"),
                sources.addCopyFile(b.path("src/tests/root.zig"), "tests/root.zig"),
            };
            const doc_root = sources.addCopyFile(m.root, "root.zig");
            const imports = b.allocator.alloc(
                std.Build.Module.Import,
                m.module.import_table.count(),
            ) catch @panic("OOM");
            var iter = m.module.import_table.iterator();
            var i: usize = 0;
            while (iter.next()) |entry| : (i += 1) {
                imports[i] = .{ .name = entry.key_ptr.*, .module = entry.value_ptr.* };
            }
            doc_module = b.createModule(.{
                .root_source_file = doc_root,
                .target = target,
                .optimize = optimize,
                .imports = imports,
            });
        }
        const doc_object = b.addObject(.{
            .name = b.fmt("ztex-{s}-docs", .{m.name}),
            .root_module = doc_module,
        });
        if (copied_sources) |paths| {
            for (paths) |path| path.addStepDependencies(&doc_object.step);
        }
        const install_docs = b.addInstallDirectory(.{
            .source_dir = doc_object.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = b.fmt("docs/{s}", .{m.name}),
        });
        docs_step.dependOn(&install_docs.step);
    }
}
