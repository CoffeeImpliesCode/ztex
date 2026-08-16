const std = @import("std");
const ztex = @import("ztex");

const usage =
    \\ztex — render LaTeX math to an SVG.
    \\
    \\  -i <latex>   input formula (default: a sample)
    \\  -o <file>    write SVG to file (default: stdout)
    \\  -s <pt>      font size in points (default 20)
    \\  -p <px>      SVG padding (default 0)
    \\  -b <color>   background: name or #RRGGBB[AA] (default: white; use
    \\               'none'/'transparent' for no background)
    \\  --bg <color>  alias for -b
    \\  -h, --help   show this help
    \\
;

/// Render a LaTeX formula to SVG. With `-o`, writes an SVG file; otherwise
/// prints the SVG to stdout. One `ztex.Context` is created per run — it owns
/// the embedded Latin Modern faces and the per-glyph metric cache, and the
/// layout measures every glyph from the real fonts through it.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var src: []const u8 = "\\frac{1}{2}+x^2+\\text{hi}";
    var out_path: ?[]const u8 = null;
    var size: f32 = 20;
    var pad: f32 = 0;
    var bg: ?ztex.draw.Color = .{ .r = 255, .g = 255, .b = 255 }; // white

    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = arg_it.next(); // skip argv[0]
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-i")) {
            src = arg_it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "-o")) {
            out_path = arg_it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "-s")) {
            size = std.fmt.parseFloat(f32, arg_it.next() orelse return error.MissingValue) catch
                return error.BadSize;
        } else if (std.mem.eql(u8, arg, "-p")) {
            pad = std.fmt.parseFloat(f32, arg_it.next() orelse return error.MissingValue) catch
                return error.BadPadding;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bg")) {
            const v = arg_it.next() orelse return error.MissingValue;
            // parseColorChecked distinguishes the valid "no background"
            // values (none/transparent → null) from a typo, which is a real
            // CLI error instead of a silent transparent background (H3).
            bg = ztex.svg.parseColorChecked(v) catch |e| switch (e) {
                error.UnrecognizedColor => {
                    try std.Io.File.stderr().writeStreamingAll(
                        io,
                        "ztex: unrecognized background color '",
                    );
                    try std.Io.File.stderr().writeStreamingAll(io, v);
                    try std.Io.File.stderr().writeStreamingAll(
                        io,
                        "' (use a color name, #RRGGBB[AA], or 'none'/'transparent')\n",
                    );
                    std.process.exit(1);
                },
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return;
        } else {
            return error.UnknownArgument;
        }
    }

    var ctx = try ztex.Context.init(gpa);
    defer ctx.deinit();

    // A parse failure fills `err_info` (kind + span) before returning its
    // error value. `ctx.render` returns the TYPED parse.Error (H2), so we
    // match it exhaustively: every member except OutOfMemory is a parse
    // front-end error whose Info was filled by lex/parse; OutOfMemory (and
    // any future non-parse member) propagates and leaves `err_info` unused.
    var err_info: ztex.parse.Info = undefined;
    const dl = ctx.render(gpa, src, size, &err_info) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            try printParseError(gpa, io, e, err_info, src);
            std.process.exit(1);
        },
    };
    const opts: ztex.svg.Options = .{ .padding = pad, .background = bg };

    if (out_path) |path| {
        try ztex.svg.writeFile(gpa, init.io, path, &dl, opts);
    } else {
        const svg = try ztex.svg.render(gpa, &dl, opts);
        defer gpa.free(svg);
        try std.Io.File.stdout().writeStreamingAll(io, svg);
    }
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
    // `lc.col` is a CODEPOINT column (L2), so `pad` and the caret width are
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
