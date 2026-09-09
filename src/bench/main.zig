//! ztex bench — parse + layout + flatten throughput.
//!
//! Run via `zig build bench` (ReleaseFast), or directly for profiling:
//!   zig-out/bin/ztex-bench                  # corpus, 2000 passes
//!   zig-out/bin/ztex-bench -i '<formula>'   # one formula, 100000 iters
//!   zig-out/bin/ztex-bench -i '<formula>' -n 500000
//! Pipe through `hyperfine` for stable cross-run timing.

const std = @import("std");
const ztex = @import("ztex");

const corpus = [_][]const u8{
    "x",
    "x^2+\\frac{1}{2}",
    "a^2+b^2=c^2",
    "\\frac{\\frac{a}{b}}{\\frac{c}{d}}",
    "\\text{The quick brown fox jumps over the lazy dog.}",
    "\\mathbf{x}+\\mathrm{abc}+\\text{\u{03b1}\u{03b2}}",
    "\\cfrac{1}{a_1+\\cfrac{1}{a_2}}",
    "\\binom{n}{k}",
    "\\sqrt{a^2+b^2}",
    "\\sqrt[3]{\\frac{a}{b}}",
    "\\left( \\frac{x+1}{x-1} \\right)",
    "\\left\\{ \\frac{a}{b} \\right\\}",
    "\\int_0^1 x^2\\,dx",
    "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
    "\\begin{cases} x & x>0 \\\\ -x & x\\le 0 \\end{cases}",
    "\\alpha + \\beta \\le \\gamma",
};
const default_iters: usize = 100_000;

/// Monotonic clock in nanoseconds. `std.time.Timer` was removed in Zig 0.16;
/// this uses the low-level `clock_gettime(CLOCK.MONOTONIC)` syscall.
fn monoNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const out = std.Io.File.stdout();
    var fbuf: [1024]u8 = undefined;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var single: ?[]const u8 = null;
    var iters: usize = default_iters;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next();
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "-i")) {
            single = arg_it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "-n")) {
            iters = std.fmt.parseInt(usize, arg_it.next() orelse return error.MissingValue, 10) catch
                return error.BadIters;
        } else return error.UnknownArgument;
    }
    if (iters == 0) return error.BadIters;

    const start = monoNs();
    var total_draws: usize = 0;
    var count: u64 = 0;
    var peak_cap: usize = 0;
    if (single) |src| {
        _ = try ztex.render(gpa, src, 20, null); // warm up
        for (0..iters) |_| {
            const dl = try ztex.render(gpa, src, 20, null);
            total_draws += dl.len();
            count += 1;
            peak_cap = @max(peak_cap, arena.queryCapacity());
            _ = arena.reset(.retain_capacity); // steady-state per render
        }
    } else {
        _ = try ztex.render(gpa, corpus[0], 20, null); // warm up
        for (0..2000) |_| {
            for (corpus) |src| {
                const dl = try ztex.render(gpa, src, 20, null);
                total_draws += dl.len();
                count += 1;
                peak_cap = @max(peak_cap, arena.queryCapacity());
                _ = arena.reset(.retain_capacity);
            }
        }
    }
    const elapsed_ns = monoNs() - start;
    const per_render_ns = blk: {
        if (count > 0) {
            break :blk elapsed_ns / count;
        }
        return error.BadIters;
    };
    const drawable_avg: f64 = @floatFromInt(total_draws);
    const count_f: f64 = @floatFromInt(count);
    if (single) |src| {
        const report = try std.fmt.bufPrint(
            &fbuf,
            "bench: '{s}' x {d} renders in {d} ms\nper render: {d} ns | {d:.1} drawables | peak arena {d} KiB\n",
            .{ src, count, elapsed_ns / 1_000_000, per_render_ns, drawable_avg / count_f, peak_cap / 1024 },
        );
        try out.writeStreamingAll(io, report);
    } else {
        const report = try std.fmt.bufPrint(
            &fbuf,
            "bench: {d} formulas x 2000 passes = {d} renders in {d} ms\n" ++
                "per formula: {d} ns | {d:.1} drawables/formula | peak arena {d} KiB\n",
            .{ corpus.len, count, elapsed_ns / 1_000_000, per_render_ns, drawable_avg / count_f, peak_cap / 1024 },
        );
        try out.writeStreamingAll(io, report);
    }
    try out.writeStreamingAll(io, "tip: pipe through `hyperfine` for stable cross-run timing\n");
}
