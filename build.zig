const std = @import("std");

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

    // ── ztex.svg — serialize a draw list to SVG ───────────────
    const svg = b.addModule("ztex.svg", .{
        .root_source_file = b.path("src/svg.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex.layout", .module = layout },
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
        },
    });

    // ── ztex.tests — integration + regression (end-to-end) ────
    const tests = b.addModule("ztex.tests", .{
        .root_source_file = b.path("src/tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztex", .module = ztex },
            .{ .name = "ztex.parse", .module = parse },
            .{ .name = "ztex.atom", .module = atom },
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
    const mods = [_]struct { name: []const u8, module: *std.Build.Module }{
        .{ .name = "atom", .module = atom },
        .{ .name = "parse", .module = parse },
        .{ .name = "layout", .module = layout },
        .{ .name = "ztex", .module = ztex },
        .{ .name = "tests", .module = tests },
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
                .root_source_file = m.module.root_source_file.?,
                .target = target,
                .optimize = optimize,
                .imports = imports,
            });
            root_module.fuzz = true;
            root_module.link_libc = true;
            if (coverage_rt) |p| root_module.addObjectFile(.{ .cwd_relative = p });
        }
        const t = b.addTest(.{ .root_module = root_module });
        if (use_coverage) t.use_llvm = true; // instrumentation needs the LLVM backend
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // ── benchmark (build with -Doptimize=ReleaseSafe or ReleaseFast) ─
    const bench_exe = b.addExecutable(.{
        .name = "ztex-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztex", .module = ztex },
            },
        }),
    });
    const bench_step = b.step("bench", "Run benchmark harness (e.g. -Doptimize=ReleaseSafe)");
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.step.dependOn(b.getInstallStep());
    bench_step.dependOn(&run_bench.step);

    // ── golden generator (prints ready-to-paste regression.zig tables) ──
    const gen_exe = b.addExecutable(.{
        .name = "gen-goldens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_goldens.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztex", .module = ztex },
            },
        }),
    });
    const gen_step = b.step("gen-goldens", "Print golden tables for the breadth corpus");
    const run_gen = b.addRunArtifact(gen_exe);
    gen_step.dependOn(&run_gen.step);
}
