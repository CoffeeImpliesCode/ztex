const std = @import("std");
const ztex = @import("ztex");

const usage =
    \\ztex — render LaTeX math to an SVG or a PPM/PGM raster.
    \\
    \\  -i <latex>    input formula (default: a sample)
    \\  -o <file>     write the output to file (default: stdout)
    \\  -s <pt>       font size in points (default 20)
    \\  -p <n>        padding around the formula: pt for SVG, px for a raster
    \\                (default 0)
    \\  --dpi <n>     raster resolution in DPI (default 96)
    \\  --ppm         write PPM (P6) 24-bit image
    \\  --pgm         write PGM (P5) 8-bit alpha mask
    \\  -b <color>    background: name or #RRGGBB[AA] (default: white; use
    \\                'none'/'transparent' for no background)
    \\  --bg <color>  alias for -b
    \\  -h, --help    show this help
    \\
    \\Raster output: pass --ppm or --pgm, or give -o a path ending in .ppm,
    \\.pnm or .pgm. Without one of those the output is SVG.
    \\
;

/// Exit status for a command-line usage error, kept apart from the status 1
/// of a render failure so a caller can tell a bad command from a bad
/// formula.
const usage_status: u8 = 2;

/// One `ztex.Context` is created per run — it owns the embedded Latin Modern
/// faces and the per-glyph metric cache, and the layout measures every glyph
/// from the real fonts through it.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var src: []const u8 = "\\frac{1}{2}+x^2+\\text{hi}";
    var out_path: ?[]const u8 = null;
    var size: f32 = 20;
    var pad: f32 = 0;
    var dpi: f32 = 96.0;
    var bg: ?ztex.draw.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }; // white
    var raster_format: ?ztex.raster.Format = null;

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // skip argv[0]
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i")) {
            src = arg_it.next() orelse {
                try printUsageError(io, "option '-i' needs a LaTeX formula\n");
                std.process.exit(usage_status);
            };
        } else if (std.mem.eql(u8, arg, "-o")) {
            out_path = arg_it.next() orelse {
                try printUsageError(io, "option '-o' needs an output path\n");
                std.process.exit(usage_status);
            };
        } else if (std.mem.eql(u8, arg, "-s")) {
            const v = arg_it.next() orelse {
                try printUsageError(io, "option '-s' needs a point size\n");
                std.process.exit(usage_status);
            };
            size = std.fmt.parseFloat(f32, v) catch {
                try printUsageErrorArg(io, "invalid font size for -s: '", v, "'\n");
                std.process.exit(usage_status);
            };
        } else if (std.mem.eql(u8, arg, "-p")) {
            const v = arg_it.next() orelse {
                try printUsageError(io, "option '-p' needs a padding length\n");
                std.process.exit(usage_status);
            };
            pad = std.fmt.parseFloat(f32, v) catch {
                try printUsageErrorArg(io, "invalid padding for -p: '", v, "'\n");
                std.process.exit(usage_status);
            };
        } else if (std.mem.eql(u8, arg, "--dpi")) {
            const v = arg_it.next() orelse {
                try printUsageError(io, "option '--dpi' needs a resolution in DPI\n");
                std.process.exit(usage_status);
            };
            dpi = std.fmt.parseFloat(f32, v) catch {
                try printUsageErrorArg(io, "invalid resolution for --dpi: '", v, "'\n");
                std.process.exit(usage_status);
            };
        } else if (std.mem.eql(u8, arg, "--ppm")) {
            raster_format = .rgba32;
        } else if (std.mem.eql(u8, arg, "--pgm")) {
            raster_format = .alpha8;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bg")) {
            const v = arg_it.next() orelse {
                try printUsageErrorArg(io, "option '", arg, "' needs a color\n");
                std.process.exit(usage_status);
            };
            bg = ztex.svg.parseColorChecked(v) catch |e| switch (e) {
                error.UnrecognizedColor => {
                    try printUsageErrorArg(io, "unrecognized background color '", v, "' (use a color name, #RRGGBB[AA], or 'none'/'transparent')\n");
                    std.process.exit(usage_status);
                },
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return;
        } else {
            try printUsageErrorArg(io, "unknown argument '", arg, "'; try 'ztex --help'\n");
            std.process.exit(usage_status);
        }
    }

    if (out_path) |p| {
        if (raster_format == null) {
            if (std.mem.endsWith(u8, p, ".ppm") or std.mem.endsWith(u8, p, ".pnm")) {
                raster_format = .rgba32;
            } else if (std.mem.endsWith(u8, p, ".pgm")) {
                raster_format = .alpha8;
            }
        }
    }
    var ctx = try ztex.Context.init(gpa);
    defer ctx.deinit();

    // A parse failure fills `err_info` (kind + span) before returning its
    // error value. `ctx.render` returns the TYPED facade error set, so we
    // match it exhaustively: every member except OutOfMemory/InvalidAst is
    // a parse front-end error whose Info was filled by lex/parse. The two
    // exceptions are not parse errors — `err_info` stays untouched — so
    // they propagate as-is.
    var err_info: ztex.parse.Info = undefined;
    const dl = ctx.render(src, size, &err_info) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.InvalidAst => return e,
        else => {
            // The arms above handle the only non-parse members, so `else`
            // is always a parse error whose Info was filled by lex/parse;
            // the cast just narrows the type for printParseError.
            try printParseError(gpa, io, @errorCast(e), err_info, src);
            std.process.exit(1);
        },
    };

    if (raster_format) |fmt| {
        const pad_u: u32 = @intFromFloat(@max(0.0, pad));
        var pix = try ztex.raster.rasterize(gpa, &ctx, &dl, .{
            .dpi = dpi,
            .padding = pad_u,
            .format = fmt,
            .bg = bg,
        });
        if (out_path) |path| {
            var file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            try pix.writePnm(io, file);
        } else {
            try pix.writePnm(io, std.Io.File.stdout());
        }
        return;
    }

    const opts: ztex.svg.Options = .{ .padding = pad, .background = bg };

    if (out_path) |path| {
        try ztex.svg.writeFile(gpa, init.io, std.Io.Dir.cwd(), path, &dl, opts);
    } else {
        const svg = try ztex.svg.render(gpa, &dl, opts);
        defer gpa.free(svg);
        try std.Io.File.stdout().writeStreamingAll(io, svg);
    }
}

/// Print `ztex: <msg>` to stderr. Every command-line problem leaves through
/// here and the following `std.process.exit(usage_status)`, so a bad
/// command line never surfaces as a Zig error return from `main`.
fn printUsageError(io: std.Io, msg: []const u8) !void {
    const f = std.Io.File.stderr();
    try f.writeStreamingAll(io, "ztex: ");
    try f.writeStreamingAll(io, msg);
}

/// Print `ztex: <msg><operand><tail>` to stderr. The operand is written
/// separately because it comes from the command line and must not be copied
/// into a fixed-size buffer.
fn printUsageErrorArg(
    io: std.Io,
    msg: []const u8,
    operand: []const u8,
    tail: []const u8,
) !void {
    const f = std.Io.File.stderr();
    try f.writeStreamingAll(io, "ztex: ");
    try f.writeStreamingAll(io, msg);
    try f.writeStreamingAll(io, operand);
    try f.writeStreamingAll(io, tail);
}

/// Print a caret-annotated parse error to stderr. The first line carries
/// the TeX-style message and the error-set name; the following lines echo
/// the offending source line with a caret under the span:
///
///     ztex: parse error: Unexpected '}' (UnexpectedRGroup) at line 2, col 12
///       \frac{1}{2}}
///               ^
fn printParseError(
    gpa: std.mem.Allocator,
    io: std.Io,
    e: ztex.parse.Error,
    info: ztex.parse.Info,
    src: []const u8,
) !void {
    const err_file = std.Io.File.stderr();
    const lc = ztex.parse.err.lineCol(src, info.span.start);
    var header: [160]u8 = undefined;
    const h = try std.fmt.bufPrint(
        &header,
        "ztex: parse error: {s} ({s}) at line {d}, col {d}\n",
        .{
            info.message(),
            @errorName(e),
            lc.line,
            lc.col,
        },
    );
    try err_file.writeStreamingAll(io, h);
    const line = ztex.parse.err.sourceLine(src, info.span.start);
    try err_file.writeStreamingAll(io, line);
    try err_file.writeStreamingAll(io, "\n");
    // `lc.col` is a CODEPOINT column, so `pad` and the caret width are
    // measured in codepoints too — aligned with how the echoed line renders.
    const pad = lc.col - 1;
    const line_cps = ztex.parse.err.countCodepoints(line);
    const caret_len = @max(@as(usize, 1), @min(info.span.len(), line_cps -| pad));
    const caret = try gpa.alloc(u8, pad + caret_len + 1);
    defer gpa.free(caret);
    @memset(caret, ' ');
    @memset(caret[pad .. pad + caret_len], '^');
    caret[pad + caret_len] = '\n';
    try err_file.writeStreamingAll(io, caret);
}
