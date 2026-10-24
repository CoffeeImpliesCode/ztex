//! ztex_c — the C ABI over the ztex render pipeline.
//!
//! Everything here is an adapter, not a second implementation: the
//! parse → layout → svg/raster work belongs to `ztex.Context`,
//! `ztex.svg.render` and `ztex.raster.rasterize` (reached through
//! `Context.renderPixels`). What this module owns is the C-shaped contract:
//!
//! - No Zig error union crosses the boundary. Four entry points return
//!   `c_int` — a `Status` — and the text of the last failure on a context
//!   is readable with `ztex_last_error`. The other two return what they
//!   describe instead: `ztex_context_destroy` is `void`, and
//!   `ztex_status_name` a pointer to a static, NUL-terminated name.
//! - No rendered output reaches C as a heap pointer: it is copied into the
//!   caller's buffer, which the caller frees. Everything the library DOES
//!   allocate — the context block, the faces and glyph cache that block
//!   owns, and the parse/layout/SVG/pixel working set of each call — comes
//!   from the CALLER's allocator. The per-call set is released before the
//!   call returns; `ztex_context_destroy` hands the rest back through the
//!   same `dealloc`.
//! - Only the font-family options and the strings ztex hands back are
//!   NUL-terminated. The LaTeX source is COUNTED UTF-8: the pipeline
//!   renders exactly `latex_length` bytes and never reads the byte after
//!   them, so the C `const char *` needs no terminator and `strlen` is
//!   never called on it. A byte that is not valid UTF-8 fails the parse.
//!
//! Lengths and capacities are 32-bit so `include/ztex.h` needs no
//! <stdint.h> (C89 has none); a payload above `max_payload` fails with
//! `.output_too_large` instead of truncating, and leaves `out_length`
//! untouched. That fixes the layout of the integer types the header spells
//! out — `int` and `unsigned int`, each 32 bits — which is what the
//! `comptime` gate below checks for the target this is built for. It is a
//! claim about that target, not about every target C can name.
//!
//! `include/ztex.h` is the authoritative contract, and it is the only
//! supported way to reach these entry points. They are `export fn`, so they
//! publish C names and no Zig ones: they are deliberately not `pub`, and the
//! `ztex` facade does not re-export them, so nothing native can call one by
//! name. That keeps the surface one declaration per function instead of two
//! that could drift, and it is why `include/ztex.h` is the contract a
//! consumer reads. The two are held together by the `comptime` seam below:
//! when this module is built against the translated real header, it hands
//! every export's actual type to `src/tests/c_abi_check.zig`, which compares
//! them with the header field by field. Nothing in the shipped library
//! compiles C — no other build resolves that seam.

const std = @import("std");
const ztex = @import("ztex");

const Style = ztex.layout.Style;
const Color = ztex.draw.Color;
const Format = ztex.raster.Format;

/// Failure codes the int-returning entry points report: C-shaped, an
/// integer rather than an error union. `ztex_status_name` names one.
pub const Status = enum(c_int) {
    ok = 0,
    /// A null context or out-parameter — a null OUTPUT buffer is the size
    /// query, not this — an unknown style or pixel-format code, a
    /// size_pt/dpi/scale that is not positive and finite, a negative SVG
    /// padding, a null `latex` with a non-zero `latex_length`, or a
    /// `ztex_last_error` call with no buffer or no room for one.
    invalid_argument = 1,
    /// The LaTeX front end rejected the formula; `ztex_last_error` names the
    /// kind and the position.
    parse_error = 2,
    /// The layout stage rejected the atom tree.
    invalid_ast = 3,
    /// The caller's `alloc` answered null, or a request did not fit the
    /// 32-bit length ABI.
    out_of_memory = 4,
    /// A draw-list coordinate was not finite — the rasterizer's ink extents
    /// included — so no SVG or bitmap can be written.
    non_finite_coordinate = 5,
    /// The caller's buffer cannot hold the whole payload. Nothing was
    /// written into it — not even a NUL — and `out_length` carries the
    /// size needed.
    buffer_too_small = 6,
    /// The output has no 32-bit size: a raster frame whose width, height or
    /// row stride cannot be expressed, or a payload above `max_payload`
    /// bytes. Checked before the pixel block is requested, so the caller's
    /// `alloc` is never asked for it.
    output_too_large = 7,
    /// A font could not be read while rasterizing a glyph outline.
    font_error = 8,
};

/// "No background": a zero alpha in the packed `0xRRGGBBAA` colors below.
/// Zero, so a zeroed `SvgOptions` background asks for the default rendering.
/// (`RasterOptions` has no all-zero default: its `dpi` 0 is not a resolution,
/// and a zeroed raster options struct is refused.)
pub const color_none: u32 = 0;

/// Largest payload the 32-bit length ABI can describe: a caller's buffer
/// needs one byte more than this for the NUL the library appends. The
/// rasterizer sizes its frame against the same ABI and reports
/// `error.OutputTooLarge` for a frame, row stride or payload no 32-bit size
/// describes, so an unrepresentable image is refused before the pixel block
/// is requested instead of being wrapped into a smaller one here.
const max_payload: usize = std.math.maxInt(u32) - 1;

/// Bytes of failure text a context keeps. The error path never allocates,
/// so the text is bounded here and `ztex_last_error` truncates whatever
/// does not fit in the caller's buffer.
const err_text_max = 256;

/// The caller's allocator, copied into the context by
/// `ztex_context_create`, and the only source of memory the library has:
/// every parse, layout, SVG and pixel allocation of every call comes from
/// it too. The struct itself may be a temporary, but `alloc`, `dealloc`
/// and `user` must stay valid and callable until `ztex_context_destroy`.
///
/// `alloc` returns memory aligned for `max_align_t` or null when it cannot;
/// `dealloc` receives the exact `len` its matching `alloc` call was given,
/// never more and never less. Growth inside the library is allocate + copy
/// + free, so an arena works and a size-tracking free list stays exact. A
/// null return, or a length the 32-bit ABI cannot express, is an ordinary
/// allocation failure, so a render reports `.out_of_memory` rather than
/// failing some other way.
///
/// Both run on the thread that called into the library, synchronously,
/// from inside the call that needed the memory and before it returns.
/// Neither may reenter the library on the SAME context: an allocator that
/// renders from inside `alloc` or `dealloc` corrupts the render already in
/// flight. This includes entry from another thread; access must be serialized.
/// Another context is independent if the shared allocator supports its use.
///
/// `user` reaches both callbacks unchanged, which is how a state struct or
/// an arena is carried across. A null `alloc` or `dealloc` is refused by
/// `ztex_context_create` with `.invalid_argument`; both are required.
pub const CAllocator = extern struct {
    alloc: ?*const fn (user: ?*anyopaque, len: u32) callconv(.c) ?*anyopaque,
    dealloc: ?*const fn (user: ?*anyopaque, ptr: ?*anyopaque, len: u32) callconv(.c) void,
    user: ?*anyopaque,
};

/// SVG rendering knobs. An all-zero struct is the default rendering: no
/// padding, no background rectangle, the built-in font stacks.
pub const SvgOptions = extern struct {
    /// Empty margin on every side, in points. Must be 0 or greater: a
    /// negative margin is `.invalid_argument` and a non-finite one
    /// `.non_finite_coordinate`.
    padding: f32 = 0,
    /// Background fill as `0xRRGGBBAA`; `color_none` emits no rectangle.
    background: u32 = color_none,
    /// CSS font stack for math (italic) runs, or null for the built-in one.
    math_font_family: ?[*:0]const u8 = null,
    /// CSS font stack for upright (\text, \mathrm, \mathbf) runs, or null
    /// for the built-in one.
    upright_font_family: ?[*:0]const u8 = null,
};

/// Raster rendering knobs. Every field is the caller's to set: a NULL
/// `ztex_raster_options` means the defaults below, but a ZEROED struct is
/// an error (`dpi` 0 is not a resolution) and says so. The defaults live
/// HERE and in C they do not: a C caller assigns the fields itself, so an
/// omitted `fg` reaches this boundary as a transparent ink and the render
/// paints nothing. Assign every field passed, `fg` above all.
///
/// `dpi`, `scale` and `padding` size a 32-bit frame. A resolution that is
/// finite and positive but frames an image whose width, height or row
/// stride has no 32-bit representation is `.output_too_large`, refused
/// before the pixel block is requested, so a hostile option is never
/// handed to the caller's `alloc`. `rasterOptions` gives the rasterizer
/// the same `max_payload` as the length ABI, so a whole payload it cannot
/// describe is refused on the same path rather than wrapping into a
/// smaller image.
pub const RasterOptions = extern struct {
    /// Output resolution in dots per inch; must be finite and > 0.
    dpi: f32 = 96,
    /// Uniform scale applied on top of `dpi`; must be finite and > 0.
    scale: f32 = 1,
    /// Transparent margin around the content, in pixels, on both axes. A
    /// margin whose framed width or row stride no 32-bit size can describe
    /// is `.output_too_large`.
    padding: u32 = 0,
    /// 0 = 32-bit RGBA (R, G, B, A byte order), 1 = 8-bit alpha mask: one
    /// byte per pixel, coverage times the INK's alpha, on a canvas that is
    /// always transparent (so `bg` is ignored in that format).
    format: u32 = 0,
    /// Ink color as `0xRRGGBBAA` — alpha LAST, so opaque black is
    /// `0x000000ff` and `0xff000000` is a transparent red. The alpha mask
    /// keeps only the alpha byte of it, so red, green and blue never reach
    /// a mask. This default must stay the rasterizer's own
    /// (`ztex.raster.Options{}`), or every render that leaves `fg` unset
    /// paints nothing at all.
    fg: u32 = 0x000000ff,
    /// Background as `0xRRGGBBAA`, or `color_none` for a transparent
    /// buffer.
    bg: u32 = color_none,
};

/// The render context: what `ztex_context_create` hands back. Opaque to C.
const Context = struct {
    /// The pipeline. Owns the embedded Latin Modern faces and the glyph
    /// metric cache; every byte it takes comes from `callbacks`.
    inner: ztex.Context,
    callbacks: Callbacks,
    /// Failure text of the last call on this context, NUL-terminated at
    /// `err_len`. Bounded, so recording a failure never allocates.
    err_text: [err_text_max]u8,
    err_len: usize,

    fn gpa(self: *Context) std.mem.Allocator {
        return self.callbacks.allocator();
    }

    /// Record `msg` as this context's failure text and return `st`. The text
    /// is truncated to the fixed buffer rather than allocated.
    fn fail(self: *Context, st: Status, msg: []const u8) Status {
        const n = @min(msg.len, self.err_text.len - 1);
        @memcpy(self.err_text[0..n], msg[0..n]);
        self.err_text[n] = 0;
        self.err_len = n;
        return st;
    }

    /// `fail` with a formatted message. The exact length is measured first,
    /// so `bufPrint` writes `n` bytes plus its NUL at index `n <= len - 1`
    /// and cannot overflow.
    fn failFmt(self: *Context, st: Status, comptime fmt: []const u8, args: anytype) Status {
        var buf: [err_text_max]u8 = undefined;
        const n = @min(std.fmt.count(fmt, args), buf.len - 1);
        const msg = std.fmt.bufPrint(buf[0..n], fmt, args) catch unreachable;
        return self.fail(st, msg);
    }

    /// Forget the previous failure: every entry point clears it before it
    /// works, so a stale message can never be read back after a success.
    fn clearFailure(self: *Context) void {
        self.err_text[0] = 0;
        self.err_len = 0;
    }

    /// Copy `bytes` and a NUL into the caller's buffer. A buffer that cannot
    /// hold the whole payload is left UNTOUCHED and reports the size it
    /// needs, so a caller can never mistake a partial render for a whole
    /// one. `out_len` is the payload length only: the NUL lands one byte
    /// past it, which is why the caller needs `capacity >= size + 1`. Of the
    /// outcomes here only `output_too_large` leaves `out_len` untouched; a
    /// call that never got this far — a refused argument, a parse, layout
    /// or font failure, an allocation that ran out — leaves it untouched
    /// too, which is the whole of the failure contract a caller sees.
    fn emit(self: *Context, bytes: []const u8, out: ?[*]u8, capacity: u32, out_len: *u32) Status {
        if (bytes.len > max_payload) return self.fail(
            .output_too_large,
            "the rendered output does not fit the 32-bit length ABI",
        );
        const need: u32 = @intCast(bytes.len);
        out_len.* = need;
        const buf = out orelse return self.fail(
            .buffer_too_small,
            "no output buffer; the size needed was reported in out_length",
        );
        if (capacity < need + 1) return self.failFmt(
            .buffer_too_small,
            "the output is {d} bytes; the buffer needs {d}",
            .{ need, need + 1 },
        );
        @memcpy(buf[0..need], bytes);
        buf[need] = 0;
        return .ok;
    }

    /// Record a pipeline failure and map it to a status. The parse errors
    /// are the ones that filled `info`, so they name the kind, the error and
    /// the position; the rest name themselves.
    fn renderFailed(
        self: *Context,
        e: PipelineError,
        info: ztex.parse.Info,
        src: []const u8,
    ) Status {
        return switch (e) {
            error.OutOfMemory => self.fail(.out_of_memory, "out of memory"),
            error.InvalidAst => self.fail(.invalid_ast, "the layout stage rejected the atom tree"),
            error.InvalidArgument => self.fail(
                .invalid_argument,
                "a rendering option is out of range: padding must be >= 0, dpi and scale > 0",
            ),
            error.OutputTooLarge => self.fail(
                .output_too_large,
                "the padded frame has no 32-bit width, height or row stride",
            ),
            error.NonFiniteCoordinate => self.fail(
                .non_finite_coordinate,
                "a draw-list coordinate is not finite; no SVG or bitmap can be written",
            ),
            error.InvalidSfnt,
            error.MissingTable,
            error.InvalidTable,
            error.UnsupportedCmap,
            error.UnsupportedFont,
            => self.failFmt(.font_error, "a font could not be read: {s}", .{@errorName(e)}),
            // Everything the arms above do not name is a front-end error,
            // whose `info` the lexer/parser filled just before returning.
            else => blk: {
                const lc = ztex.parse.err.lineCol(src, info.span.start);
                break :blk self.failFmt(
                    .parse_error,
                    "parse error: {s} ({s}) at line {d}, col {d}",
                    .{ info.message(), @errorName(e), lc.line, lc.col },
                );
            },
        };
    }
};

/// Every failure the pipeline can report across this boundary. The font
/// members come from the rasterizer's glyph-outline path; the C face gives
/// all of them one status, so a font the library cannot read is a
/// reportable outcome instead of a crash. `InvalidArgument` and
/// `OutputTooLarge` are the back ends refusing an option — a margin that is
/// not a margin, a resolution that is not one, a frame no 32-bit size can
/// describe — each reported BEFORE the payload is built or allocated.
const PipelineError = ztex.parse.Error || ztex.font.FontError || error{
    InvalidArgument,
    InvalidAst,
    NonFiniteCoordinate,
    OutOfMemory,
    OutputTooLarge,
};

/// The allocator callbacks as the context stores them — inside the context,
/// so the `std.mem.Allocator` handed to the pipeline keeps a stable `ptr`.
/// Callback types use the C calling convention, not Zig's `.auto` ABI.
const Callbacks = struct {
    alloc_fn: *const fn (user: ?*anyopaque, len: u32) callconv(.c) ?*anyopaque,
    dealloc_fn: *const fn (user: ?*anyopaque, ptr: ?*anyopaque, len: u32) callconv(.c) void,
    user: ?*anyopaque,

    fn allocator(self: *Callbacks) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

const vtable: std.mem.Allocator.VTable = .{
    .alloc = cbAlloc,
    // The C contract has no realloc, and declining both hooks is a
    // supported allocator behaviour: the caller grows by allocating,
    // copying and freeing.
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = cbFree,
};

fn cbAlloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    _ = ra;
    const self: *Callbacks = @ptrCast(@alignCast(ptr));
    const len32 = std.math.cast(u32, len) orelse return null;
    const p = self.alloc_fn(self.user, len32) orelse return null;
    // The contract promises max_align_t, which covers every fundamental
    // alignment std asks for here. Refuse — as an ordinary allocation
    // failure, so a render just reports out-of-memory — rather than hand
    // back under-aligned memory if that ever stops holding.
    if (!alignment.check(@intFromPtr(p))) {
        self.dealloc_fn(self.user, p, len32);
        return null;
    }
    return @ptrCast(p);
}

fn cbFree(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    _ = alignment;
    _ = ra;
    const self: *Callbacks = @ptrCast(@alignCast(ptr));
    const len = std.math.cast(u32, memory.len) orelse return;
    self.dealloc_fn(self.user, memory.ptr, len);
}

comptime {
    // The two C integer widths include/ztex.h fixes, and the two that can
    // actually vary: `int` for a status or a style, `unsigned int`
    // (ztex_u32) for every length. `float` is deliberately absent — f32 is
    // 32 bits on every target, so a check there proves nothing; the header's
    // `float` fields are compared against this module's `f32` by the test
    // sweep that translates the real header.
    if (@sizeOf(c_int) != 4) @compileError("this target's int is not 32 bits");
    if (@sizeOf(c_uint) != 4) @compileError("this target's unsigned int is not 32 bits");
    // The allocator contract above is malloc-class alignment, and 16 bytes
    // covers it on every target this build claims.
    if (@alignOf(Context) > 16) @compileError("a render context must be 16-byte aligned");

    // The header-test root provides this checker. Normal hosts and the C
    // archive compile without translated-header dependencies.
    const header_guard = @import("root");
    if (@hasDecl(header_guard, "ztex_header")) header_guard.checkEntrypoints(.{
        .ztex_status_name = @TypeOf(ztex_status_name),
        .ztex_context_create = @TypeOf(ztex_context_create),
        .ztex_context_destroy = @TypeOf(ztex_context_destroy),
        .ztex_render_svg = @TypeOf(ztex_render_svg),
        .ztex_render_raster = @TypeOf(ztex_render_raster),
        .ztex_last_error = @TypeOf(ztex_last_error),
        .context = Context,
        .allocator = CAllocator,
        .svg_options = SvgOptions,
        .raster_options = RasterOptions,
        .status = Status,
        .style = Style,
        .format = Format,
        .color_none = color_none,
    });
}

/// The arguments both render entry points take, once validated.
const Args = struct {
    /// The caller's counted bytes: a null `latex` is the empty source, and
    /// the byte after `latex_length` is never read.
    src: []const u8,
    style: Style,
    size_pt: f32,
};

/// Validate the arguments every render shares into `args`, answering the
/// status to report: nothing is parsed or laid out from a request the C
/// caller got wrong.
fn readArgs(
    self: *Context,
    args: *Args,
    latex: ?[*]const u8,
    latex_length: u32,
    style: c_int,
    size_pt: f32,
) Status {
    const math = std.enums.fromInt(Style, style) orelse
        return self.fail(.invalid_argument, "unknown math style code");
    if (!std.math.isFinite(size_pt) or size_pt <= 0)
        return self.fail(.invalid_argument, "size_pt must be a positive finite number");
    if (latex == null and latex_length != 0)
        return self.fail(.invalid_argument, "latex is NULL but latex_length is not 0");
    args.* = .{
        .src = if (latex) |p| p[0..latex_length] else "",
        .style = math,
        .size_pt = size_pt,
    };
    return .ok;
}

/// Map the C options struct onto the SVG serializer's, resolving the two
/// font stacks (null keeps the serializer's own default) and packing the
/// background color.
fn svgOptions(options: ?*const SvgOptions) ztex.svg.Options {
    const o = options orelse return .{};
    return .{
        .padding = o.padding,
        .background = if (o.background == color_none) null else unpackColor(o.background),
        .font_family = family(o.math_font_family),
        .text_font_family = family(o.upright_font_family),
    };
}

/// Map the C options struct onto the rasterizer's, or null when the pixel
/// format code is not one this build knows. `max_bytes` is `max_payload` on
/// both arms, so the rasterizer refuses a payload the 32-bit length ABI
/// cannot describe BEFORE it asks the caller's `alloc` for the pixel block,
/// exactly as it refuses a frame no 32-bit size can describe. Without it the
/// frame is measured, allocated for, and only then refused — as an ordinary
/// allocation failure the caller reads as OOM.
fn rasterOptions(options: ?*const RasterOptions) ?ztex.raster.Options {
    const o = options orelse return .{ .max_bytes = max_payload };
    return .{
        .dpi = o.dpi,
        .scale = o.scale,
        .padding = o.padding,
        .format = std.enums.fromInt(Format, o.format) orelse return null,
        .fg = unpackColor(o.fg),
        .bg = if (o.bg == color_none) null else unpackColor(o.bg),
        .max_bytes = max_payload,
    };
}

/// NUL-terminated C string → slice; null keeps the serializer's default
/// font stack.
fn family(text: ?[*:0]const u8) []const u8 {
    const defaults = ztex.svg.Options{};
    const p = text orelse return defaults.font_family;
    return std.mem.span(p);
}

/// `0xRRGGBBAA` → the pipeline's channel struct.
fn unpackColor(bits: u32) Color {
    return .{
        .r = @truncate(bits >> 24),
        .g = @truncate(bits >> 16),
        .b = @truncate(bits >> 8),
        .a = @truncate(bits),
    };
}

// ── the C surface ────────────────────────────────
//
// The names below are published C ABI symbols, not Zig identifiers:
// snake_case is the C convention, include/ztex.h declares exactly these
// spellings, and every C host that links this library already depends on
// them, so renaming them would break the contract for no gain. The rule is
// waived for the exported surface alone; the internal helpers above stay
// under it and keep their camelCase names.
// zwanzig-disable: identifier-style

/// Create a render context and write it to `out_context`, which the caller
/// then owns until `ztex_context_destroy`. The context block comes from
/// `allocator`, and so does every byte the pipeline takes after it;
/// `ztex_context_destroy` gives all of them back through the same
/// `dealloc`.
///
/// Nothing is retained on failure: `out_context` keeps the value the caller
/// passed, and a block already taken goes straight back to `dealloc`. The
/// two failure kinds are `.invalid_argument` — a NULL `allocator`, a NULL
/// `out_context`, a NULL `alloc` or a NULL `dealloc`, none of which is
/// attempted at all — and `.out_of_memory`, which is a NULL from `alloc` or
/// a pipeline that could not build its faces. There is no failure text for
/// either: the status is the whole report, because no context exists to
/// carry text back on.
export fn ztex_context_create(
    allocator: ?*const CAllocator,
    out_context: ?*?*Context,
) c_int {
    const desc = allocator orelse return @backingInt(Status.invalid_argument);
    const out = out_context orelse return @backingInt(Status.invalid_argument);
    const alloc_fn = desc.alloc orelse return @backingInt(Status.invalid_argument);
    const dealloc_fn = desc.dealloc orelse return @backingInt(Status.invalid_argument);
    const block: u32 = @intCast(@sizeOf(Context));
    const raw = alloc_fn(desc.user, block) orelse return @backingInt(Status.out_of_memory);
    const self: *Context = @ptrCast(@alignCast(raw));
    // Written before the first allocation through the context, so the
    // allocator the pipeline receives points into storage that outlives it.
    self.callbacks = .{ .alloc_fn = alloc_fn, .dealloc_fn = dealloc_fn, .user = desc.user };
    self.clearFailure();
    self.inner = ztex.Context.init(self.gpa()) catch {
        dealloc_fn(desc.user, raw, block);
        return @backingInt(Status.out_of_memory);
    };
    out.* = self;
    return @backingInt(Status.ok);
}

/// Destroy a context: the pipeline's embedded Latin Modern faces, its glyph
/// metric cache and the context block itself all go back to the `dealloc`
/// the context was created with. A NULL context is a no-op; passing the
/// same one twice is undefined, exactly as calling free twice is.
export fn ztex_context_destroy(context: ?*Context) void {
    const self = context orelse return;
    const block: u32 = @intCast(@sizeOf(Context));
    self.inner.deinit();
    self.callbacks.dealloc_fn(self.callbacks.user, @ptrCast(self), block);
}

/// The name of a status code, as a NUL-terminated C string owned by the
/// library: it lives as long as the process and must never be freed. A code
/// this build does not know reads "unknown status".
///
/// Returns a non-null C pointer, not a Zig pointer/length slice.
export fn ztex_status_name(status: c_int) [*:0]const u8 {
    const st = std.enums.fromInt(Status, status) orelse return "unknown status";
    return @tagName(st).ptr;
}

/// Render one formula to SVG in the caller's buffer.
///
/// `latex` is COUNTED UTF-8 — exactly `latex_length` bytes are read, so
/// the pointer needs no NUL terminator — and it is read during the call
/// only, with nothing retained: the SVG is copied into `out`, which the
/// caller owns. A render that got as far as building the document gives
/// `out_length` the payload size — on `ok` the bytes copied into `out`, on
/// `buffer_too_small` the size needed — so `out = NULL, out_capacity = 0` is
/// a size query, and a buffer that cannot hold the whole payload comes back
/// UNWRITTEN rather than half filled. The payload needs
/// `out_capacity >= size + 1`: the library always terminates it with a NUL,
/// and that NUL is the one byte `out_length` does not count.
///
/// A FAILED render leaves `out_length` and every byte of `out` untouched,
/// whatever the failure: a refused argument (including a negative
/// `options->padding`, which is checked before the document is built), a
/// parse, layout or font error, an allocation that ran out, or a payload
/// too large for the 32-bit length ABI.
export fn ztex_render_svg(
    context: ?*Context,
    latex: ?[*]const u8,
    latex_length: u32,
    style: c_int,
    size_pt: f32,
    options: ?*const SvgOptions,
    out: ?[*]u8,
    out_capacity: u32,
    out_length: ?*u32,
) c_int {
    const self = context orelse return @backingInt(Status.invalid_argument);
    const len_out = out_length orelse
        return @backingInt(self.fail(.invalid_argument, "out_length must not be NULL"));
    self.clearFailure();
    var args: Args = undefined;
    const invalid = readArgs(self, &args, latex, latex_length, style, size_pt);
    if (invalid != .ok) return @backingInt(invalid);
    var info: ztex.parse.Info = undefined;
    var list = self.inner.render(args.src, args.style, args.size_pt, &info) catch |e|
        return @backingInt(self.renderFailed(e, info, args.src));
    defer list.deinit();
    var opts = svgOptions(options);
    opts.fonts = self.inner.fonts;
    const text = ztex.svg.render(self.gpa(), &list, opts) catch |e|
        return @backingInt(self.renderFailed(e, info, args.src));
    defer self.gpa().free(text);
    return @backingInt(self.emit(text, out, out_capacity, len_out));
}

/// Render one formula to a pixel buffer in the caller's buffer. Ownership,
/// the counted `latex` source and the size-query protocol follow
/// `ztex_render_svg` exactly: the payload is `width * height * 4` bytes for
/// `rgba32` and `width * height` for `alpha8`, and it needs one byte of
/// capacity past that, for the NUL written after the last pixel.
/// `out_width`/`out_height` receive the image size in pixels whenever the
/// render itself succeeded — including on the `buffer_too_small` a size
/// query returns — and are untouched when it failed; both must be
/// non-NULL.
///
/// A frame the 32-bit ABI cannot describe is refused as `output_too_large`
/// before the pixel block is requested, so it leaves every out-parameter
/// untouched and never reaches the caller's `alloc`. "Cannot describe" is
/// the width, the height, the row stride AND the whole payload: the frame
/// is measured against `max_payload`, the same ceiling `emit` applies, so a
/// picture wider than 4 GiB is refused as too large rather than wrapped into
/// a smaller one. `emit` keeps its own check as the last word, for the SVG
/// path and for anything that reaches it another way.
export fn ztex_render_raster(
    context: ?*Context,
    latex: ?[*]const u8,
    latex_length: u32,
    style: c_int,
    size_pt: f32,
    options: ?*const RasterOptions,
    out: ?[*]u8,
    out_capacity: u32,
    out_length: ?*u32,
    out_width: ?*u32,
    out_height: ?*u32,
) c_int {
    const self = context orelse return @backingInt(Status.invalid_argument);
    const len_out = out_length orelse
        return @backingInt(self.fail(.invalid_argument, "out_length must not be NULL"));
    const width_out = out_width orelse
        return @backingInt(self.fail(.invalid_argument, "out_width must not be NULL"));
    const height_out = out_height orelse
        return @backingInt(self.fail(.invalid_argument, "out_height must not be NULL"));
    self.clearFailure();
    var args: Args = undefined;
    const invalid = readArgs(self, &args, latex, latex_length, style, size_pt);
    if (invalid != .ok) return @backingInt(invalid);
    if (options) |o| {
        if (!std.math.isFinite(o.dpi) or o.dpi <= 0) return @backingInt(
            self.fail(.invalid_argument, "dpi must be a positive finite number"),
        );
        if (!std.math.isFinite(o.scale) or o.scale <= 0) return @backingInt(
            self.fail(.invalid_argument, "scale must be a positive finite number"),
        );
    }
    const raster = rasterOptions(options) orelse return @backingInt(
        self.fail(.invalid_argument, "unknown pixel format code"),
    );
    var info: ztex.parse.Info = undefined;
    var pix = self.inner.renderPixels(args.src, args.style, args.size_pt, raster, &info) catch |e|
        return @backingInt(self.renderFailed(e, info, args.src));
    defer pix.deinit();
    const status = self.emit(pix.pixels, out, out_capacity, len_out);
    // Only an outcome that reports a size reports a frame. `.ok` drew it and
    // `.buffer_too_small` is the size query that tells the caller how big the
    // buffer must be; every other status is a failure and leaves the
    // caller's own geometry exactly as it was passed, so a refused call is
    // never mistaken for a query.
    switch (status) {
        .ok, .buffer_too_small => {
            width_out.* = pix.width;
            height_out.* = pix.height;
        },
        else => {},
    }
    return @backingInt(status);
}

/// Copy the text of the last failure on `context` into `buffer`, always
/// NUL-terminating within `capacity`. Truncation is the caller's choice:
/// `out_length` always receives the FULL text length, which never exceeds
/// `err_text_max - 1`, so `out_length >= capacity` means the tail was cut.
/// It is written before the buffer is looked at, so a NULL `buffer`, or a
/// zero `capacity` with text to report, answers ZTEX_INVALID_ARGUMENT with
/// the length still reported and the stored text still readable. With no
/// failure to report the call answers ZTEX_OK, writes `out_length = 0` and
/// touches no byte of `buffer`.
///
/// The text belongs to the context: every render clears it before it works,
/// so a successful render leaves it empty and a failed one replaces it.
/// This function never changes it.
export fn ztex_last_error(
    context: ?*const Context,
    buffer: ?[*]u8,
    capacity: u32,
    out_length: ?*u32,
) c_int {
    const self = context orelse return @backingInt(Status.invalid_argument);
    const len_out = out_length orelse return @backingInt(Status.invalid_argument);
    len_out.* = @intCast(self.err_len);
    if (self.err_len == 0) return @backingInt(Status.ok);
    // Argument misuse here is reported without touching the stored text: a
    // caller that misreads its own error must still be able to read it.
    const buf = buffer orelse return @backingInt(Status.invalid_argument);
    if (capacity == 0) return @backingInt(Status.invalid_argument);
    const n: usize = @min(self.err_len, capacity - 1);
    @memcpy(buf[0..n], self.err_text[0..n]);
    buf[n] = 0;
    return @backingInt(Status.ok);
}

// zwanzig-enable: identifier-style

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// A `ztex_allocator` over `testing.allocator` that counts live bytes, so a
/// test can prove a context gives every byte back, and refuses any request
/// above `fail_above` — the ceiling a C host's own allocator imposes, which
/// a call that sizes a request it should have refused cannot slip past.
const Counted = struct {
    state: State,

    const State = struct {
        gpa: std.mem.Allocator,
        live: usize,
        /// Requests larger than this answer null, exactly as an allocator
        /// that cannot get the memory does. Defaults to no ceiling.
        fail_above: u32 = std.math.maxInt(u32),
        /// The largest block this allocator was asked for, so a test can
        /// tell a refused request apart from a served one: a frame ztex
        /// measured and then declined never reaches `alloc` at all.
        biggest: u32 = 0,

        /// The state the `user` pointer addresses. `desc()` always passes
        /// `&self.state`, so an absent pointer means the fixture was wired
        /// wrong. Name it, answer the C contract (no allocation, no free)
        /// and let the test fail on its own assertion: unwrapping a NULL
        /// here would panic without saying which pointer was missing.
        fn stateOf(user: ?*anyopaque) ?*State {
            const ptr = user orelse {
                std.debug.print("c abi test allocator: NULL user pointer\n", .{});
                return null;
            };
            return @ptrCast(@alignCast(ptr));
        }

        fn alloc(user: ?*anyopaque, len: u32) callconv(.c) ?*anyopaque {
            const self = stateOf(user) orelse return null;
            self.biggest = @max(self.biggest, len);
            if (len > self.fail_above) return null;
            const bytes = self.gpa.alloc(u8, len) catch return null;
            self.live += bytes.len;
            return @ptrCast(bytes.ptr);
        }

        fn dealloc(user: ?*anyopaque, ptr: ?*anyopaque, len: u32) callconv(.c) void {
            const self = stateOf(user) orelse return;
            const block = ptr orelse {
                std.debug.print("c abi test allocator: NULL pointer to free\n", .{});
                return;
            };
            self.gpa.free(@as([*]u8, @ptrCast(block))[0..len]);
            self.live -= len;
        }
    };

    fn init(gpa: std.mem.Allocator) Counted {
        return .{ .state = .{ .gpa = gpa, .live = 0 } };
    }

    fn desc(self: *Counted) CAllocator {
        return .{
            .alloc = State.alloc,
            .dealloc = State.dealloc,
            .user = &self.state,
        };
    }
};

/// A created context over `testing.allocator`. The allocator's `user`
/// pointer addresses the fixture, so a fixture must stay put once created.
const Fixture = struct {
    counted: Counted,
    handle: ?*Context,

    fn create(self: *Fixture) !void {
        self.counted = Counted.init(testing.allocator);
        const desc = self.counted.desc();
        if (ztex_context_create(&desc, &self.handle) != 0) return error.ContextCreationFailed;
    }

    fn destroy(self: *Fixture) void {
        ztex_context_destroy(self.handle);
    }

    fn ctx(self: *Fixture) ?*Context {
        return self.handle;
    }

    /// The failure text of the last call, as a slice of `buf`.
    fn lastError(self: *Fixture, buf: []u8) ![]const u8 {
        var len: u32 = 0;
        try testing.expectEqual(
            @as(c_int, 0),
            ztex_last_error(self.handle, buf.ptr, @intCast(buf.len), &len),
        );
        return buf[0..len];
    }
};

test "c abi: render_svg writes an <svg document into the caller's buffer" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "\\frac{1}{2}+x^2";
    var buf: [16 * 1024]u8 = undefined;
    var len: u32 = 0;
    const live_before = f.counted.state.live;
    const status = ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        &buf,
        @intCast(buf.len),
        &len,
    );
    try testing.expectEqual(@as(c_int, 0), status);
    const out = buf[0..len];
    try testing.expect(std.mem.startsWith(u8, out, "<svg"));
    try testing.expect(std.mem.endsWith(u8, out, "</svg>\n"));
    // C callers get a NUL, not just the length.
    try testing.expectEqual(@as(u8, 0), buf[len]);
    // The call kept nothing: the context's own footprint is unchanged.
    try testing.expectEqual(live_before, f.counted.state.live);
}

test "c abi: render_raster fills the caller's pixel buffer" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "\\sum_{i=1}^{n} i";
    const opts: RasterOptions = .{ .dpi = 96 };
    var len: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    // A size query: no buffer at all, just the size the caller must provide.
    try testing.expectEqual(@as(c_int, @backingInt(Status.buffer_too_small)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &opts,
        null,
        0,
        &len,
        &width,
        &height,
    ));
    try testing.expect(width > 0 and height > 0);
    const bytes = try testing.allocator.alloc(u8, len + 1);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(c_int, 0), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &opts,
        bytes.ptr,
        len + 1,
        &len,
        &width,
        &height,
    ));
    // 4 bytes per pixel for the default RGBA format.
    try testing.expectEqual(len, @as(u32, @intCast(width)) * height * 4);
    // Ink on the page, and it is BLACK: the default `fg` is opaque black, so
    // a pixel the glyph covers is (0, 0, 0, a) with a > 0. A default packed
    // in the wrong byte order unpacks to a zero alpha and paints nothing.
    const n: usize = len;
    var i: usize = 0;
    var inked: usize = 0;
    while (i < n) : (i += 4) {
        if (bytes[i + 3] == 0) continue;
        inked += 1;
        try testing.expectEqual([3]u8{ 0, 0, 0 }, bytes[i..][0..3].*);
    }
    try testing.expect(inked > 0);
}

test "c abi: the ink color crosses as 0xRRGGBBAA, alpha last" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "\\frac{x}{2}";
    // Every byte differs, and the one that decides visibility is the last,
    // so no byte order but the documented one reproduces these pixels.
    const opts: RasterOptions = .{ .dpi = 96, .fg = 0x1a2b3cff };
    var len: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var buf: [64 * 1024]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &opts,
        &buf,
        @intCast(buf.len),
        &len,
        &width,
        &height,
    ));
    try testing.expectEqual(len, @as(u32, @intCast(width)) * height * 4);
    const n: usize = len;
    var i: usize = 0;
    var inked: usize = 0;
    while (i < n) : (i += 4) {
        if (buf[i + 3] == 0) continue;
        inked += 1;
        // Ink over a transparent buffer is that ink: only the coverage in
        // the alpha byte varies, never the color.
        try testing.expectEqual(@as(u8, 0x1a), buf[i]);
        try testing.expectEqual(@as(u8, 0x2b), buf[i + 1]);
        try testing.expectEqual(@as(u8, 0x3c), buf[i + 2]);
    }
    try testing.expect(inked > 0);
}

test "c abi: the alpha mask format is one byte per pixel" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "x";
    const opts: RasterOptions = .{ .dpi = 72, .format = 1 };
    var len: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    const bytes = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(c_int, 0), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &opts,
        bytes.ptr,
        @intCast(bytes.len),
        &len,
        &width,
        &height,
    ));
    try testing.expectEqual(len, width * height);
}

test "c abi: a malformed formula reports the parse failure and names it" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    // The denominator is missing.
    const src: [:0]const u8 = "\\frac{1}";
    var buf: [4096]u8 = undefined;
    var len: u32 = 0;
    const status = ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        &buf,
        @intCast(buf.len),
        &len,
    );
    try testing.expectEqual(@as(c_int, @backingInt(Status.parse_error)), status);
    var msg: [err_text_max]u8 = undefined;
    const text = try f.lastError(&msg);
    try testing.expect(std.mem.startsWith(u8, text, "parse error: Missing argument"));
    try testing.expect(std.mem.indexOf(u8, text, "at line 1, col") != null);
    try testing.expectEqualStrings("parse_error", std.mem.span(ztex_status_name(status)));
}

test "c abi: a too-small buffer is refused, never partially filled" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "x^2+y^2";
    var small: [8]u8 = @splat(0xaa);
    var len: u32 = 0;
    const status = ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        &small,
        @intCast(small.len),
        &len,
    );
    try testing.expectEqual(@as(c_int, @backingInt(Status.buffer_too_small)), status);
    // The caller learns the exact size it must provide...
    try testing.expect(len > small.len);
    // ...and got no bytes at all, not even a NUL.
    for (small) |b| try testing.expectEqual(@as(u8, 0xaa), b);
    const exact = try testing.allocator.alloc(u8, len + 1);
    defer testing.allocator.free(exact);
    try testing.expectEqual(@as(c_int, 0), ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        exact.ptr,
        len + 1,
        &len,
    ));
    try testing.expect(std.mem.startsWith(u8, exact[0..len], "<svg"));
}

test "c abi: bad arguments are refused before any rendering" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "x";
    var buf: [64]u8 = undefined;
    var len: u32 = 0;
    const cap: u32 = @intCast(buf.len);
    // No context, and no room to report the size.
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_render_svg(
        null,
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        &buf,
        cap,
        &len,
    ));
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        &buf,
        cap,
        null,
    ));
    // An unknown style code, and a size that is not a usable point size.
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        99,
        20,
        null,
        &buf,
        cap,
        &len,
    ));
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        0,
        null,
        &buf,
        cap,
        &len,
    ));
    // A NULL source is only an empty formula, never a non-empty one.
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_render_svg(
        f.ctx(),
        null,
        3,
        @backingInt(Style.display),
        20,
        null,
        &buf,
        cap,
        &len,
    ));
    var msg: [err_text_max]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try f.lastError(&msg), "latex_length") != null);
}

test "c abi: raster options are validated, and NULL means the defaults" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "x";
    var len: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    // A C caller who writes `{0}` gets dpi 0, which is not a resolution.
    const zeroed = std.mem.zeroes(RasterOptions);
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &zeroed,
        null,
        0,
        &len,
        &width,
        &height,
    ));
    var msg: [err_text_max]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try f.lastError(&msg), "dpi") != null);
    // An unknown pixel format is refused rather than silently defaulted.
    const bad: RasterOptions = .{ .dpi = 96, .format = 7 };
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &bad,
        null,
        0,
        &len,
        &width,
        &height,
    ));
    // NULL options render at the pipeline's defaults (96 dpi).
    try testing.expectEqual(@as(c_int, @backingInt(Status.buffer_too_small)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        null,
        0,
        &len,
        &width,
        &height,
    ));
    try testing.expect(width > 0 and height > 0);
}

test "c abi: a negative SVG padding is refused before a document is built" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "x";
    const opts: SvgOptions = .{ .padding = -1000 };
    var out: [4096]u8 = @splat(0xaa);
    var len: u32 = 0xdeadbeef;
    // The document this used to report as a success declared a negative
    // frame: `width="-1988pt"` over a viewBox of "0 0 -1988 …".
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &opts,
        &out,
        @intCast(out.len),
        &len,
    ));
    var msg: [err_text_max]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try f.lastError(&msg), "padding") != null);
    // A refused call writes nothing at all: not a document, not a NUL, and
    // no size — it is not a size query.
    for (out) |b| try testing.expectEqual(@as(u8, 0xaa), b);
    try testing.expectEqual(@as(u32, 0xdeadbeef), len);
    // The margin's own contract: 0 or more renders, and the document's
    // declared width is the positive frame the negative case could not be.
    const fine: SvgOptions = .{ .padding = 4 };
    var doc: [16 * 1024]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &fine,
        &doc,
        @intCast(doc.len),
        &len,
    ));
    const text = doc[0..len];
    const at = std.mem.indexOf(u8, text, " width=\"") orelse return error.MissingAttribute;
    try testing.expect(text[at + " width=\"".len] != '-');
}

test "c abi: a raster frame the 32-bit size cannot describe is refused unallocated" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "x";
    // The caller's allocator answers null above a megabyte, as a host's
    // would. A frame this library cannot describe is refused BEFORE the
    // request, so it reports output_too_large rather than the
    // out_of_memory that such a request would earn.
    f.counted.state.fail_above = 1024 * 1024;
    var out: [64]u8 = @splat(0xaa);
    var len: u32 = 123;
    var width: u32 = 123;
    var height: u32 = 123;
    // 2 * 2^31 pixels of margin is one past the largest u32: the frame has no
    // 32-bit width, and computing it used to abort on the overflow.
    const huge_margin: RasterOptions = .{ .dpi = 96, .padding = 2147483648 };
    try testing.expectEqual(@as(c_int, @backingInt(Status.output_too_large)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &huge_margin,
        &out,
        @intCast(out.len),
        &len,
        &width,
        &height,
    ));
    // A resolution that is finite, positive and enormous frames an equally
    // unrepresentable image: 1e30 dpi is 1.4e28 px per point.
    const huge_dpi: RasterOptions = .{ .dpi = 1e30 };
    try testing.expectEqual(@as(c_int, @backingInt(Status.output_too_large)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &huge_dpi,
        &out,
        @intCast(out.len),
        &len,
        &width,
        &height,
    ));
    // Every out-parameter is left as the caller passed it, out included.
    try testing.expectEqual(@as(u32, 123), len);
    try testing.expectEqual(@as(u32, 123), width);
    try testing.expectEqual(@as(u32, 123), height);
    for (out) |b| try testing.expectEqual(@as(u8, 0xaa), b);
    var msg: [err_text_max]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try f.lastError(&msg), "32-bit") != null);
    // The same allocator still renders an ordinary formula, so the statuses
    // above came from the frame and not from a starving allocator.
    try testing.expectEqual(@as(c_int, @backingInt(Status.buffer_too_small)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        null,
        0,
        &len,
        &width,
        &height,
    ));
    try testing.expect(width > 0 and height > 0);
}

test "c abi: an rgba payload past the 32-bit length ABI is refused unallocated" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "x";

    // A margin that frames an image just short of the point where the RGBA
    // row stride stops being a 32-bit size. The framed width is
    // ceil(ink) + 2*padding + 1 and stride is width*4, so this padding leaves
    // room for 1,741,822 px of ink — far more than the query below measures,
    // and checked by it rather than trusted. The frame that follows is about
    // 1.07e9 px square, so its RGBA payload is around 4.6e18 bytes: no
    // `ztex_u32` length can describe it, and no `u32` the caller's allocator
    // is handed can either. This is the case the length ABI has to refuse.
    const pad: u32 = 536_000_000;

    var probe_len: u32 = 0;
    var probe_width: u32 = 0;
    var probe_height: u32 = 0;
    try testing.expectEqual(@as(c_int, @backingInt(Status.buffer_too_small)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        null,
        0,
        &probe_len,
        &probe_width,
        &probe_height,
    ));
    try testing.expect(probe_width < 100_000);
    try testing.expect(probe_height < 100_000);

    const hostile: RasterOptions = .{ .dpi = 96, .padding = pad };
    var out: [64]u8 = @splat(0xaa);
    var len: u32 = 123;
    var width: u32 = 123;
    var height: u32 = 123;
    try testing.expectEqual(@as(c_int, @backingInt(Status.output_too_large)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        &hostile,
        &out,
        @intCast(out.len),
        &len,
        &width,
        &height,
    ));
    // A refused call is not a size query: no payload length, no frame, and
    // not one byte of the caller's buffer.
    try testing.expectEqual(@as(u32, 123), len);
    try testing.expectEqual(@as(u32, 123), width);
    try testing.expectEqual(@as(u32, 123), height);
    for (out) |b| try testing.expectEqual(@as(u8, 0xaa), b);
    // The frame was measured, not requested: the largest block the caller's
    // allocator ever saw is a working-set one. The count is not zero — a
    // render of "x" still parses, lays out and paints a small frame — but it
    // is nothing like the payload above.
    try testing.expect(f.counted.state.biggest < 4 * 1024 * 1024);
    var msg: [err_text_max]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, try f.lastError(&msg), "32-bit") != null);
    // The same context still renders an ordinary formula, so the status above
    // came from the frame and not from an allocator that ran out.
    try testing.expectEqual(@as(c_int, @backingInt(Status.buffer_too_small)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        null,
        0,
        &len,
        &width,
        &height,
    ));
    try testing.expect(width > 0 and height > 0);
}

test "c abi: last_error truncates to the caller's buffer" {
    var f: Fixture = undefined;
    try f.create();
    defer f.destroy();
    const src: [:0]const u8 = "\\nosuchcommand";
    var len: u32 = 0;
    try testing.expectEqual(@as(c_int, @backingInt(Status.parse_error)), ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        null,
        0,
        &len,
    ));
    var short: [12]u8 = @splat(0);
    var full: [err_text_max]u8 = undefined;
    var short_len: u32 = 0;
    try testing.expectEqual(@as(c_int, 0), ztex_last_error(
        f.ctx(),
        &short,
        @intCast(short.len),
        &short_len,
    ));
    // The full length is always reported, so cutting the text is the
    // caller's decision; the copy stays NUL-terminated inside the buffer.
    try testing.expect(short_len > short.len);
    try testing.expectEqual(@as(u8, 0), short[short.len - 1]);
    try testing.expect(std.mem.startsWith(u8, short[0..], "parse error"));
    const text = try f.lastError(&full);
    try testing.expectEqual(short_len, @as(u32, @intCast(text.len)));
    // A successful call clears the text, so nothing stale reads back.
    const ok: [:0]const u8 = "x";
    var buf: [4096]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), ztex_render_svg(
        f.ctx(),
        ok.ptr,
        @intCast(ok.len),
        @backingInt(Style.display),
        20,
        null,
        &buf,
        @intCast(buf.len),
        &len,
    ));
    try testing.expectEqual(@as(usize, 0), (try f.lastError(&full)).len);
}

test "c abi: destroying the context gives every byte back" {
    var f: Fixture = undefined;
    try f.create();
    const src: [:0]const u8 = "\\frac{a}{b}+\\sqrt{x}+\\int_0^1 f(x)\\,dx";
    var len: u32 = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    var buf: [64 * 1024]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), ztex_render_svg(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        &buf,
        @intCast(buf.len),
        &len,
    ));
    try testing.expectEqual(@as(c_int, @backingInt(Status.buffer_too_small)), ztex_render_raster(
        f.ctx(),
        src.ptr,
        @intCast(src.len),
        @backingInt(Style.display),
        20,
        null,
        null,
        0,
        &len,
        &width,
        &height,
    ));
    try testing.expect(f.counted.state.live > 0);
    f.destroy();
    try testing.expectEqual(@as(usize, 0), f.counted.state.live);
    // Both halves of the surface tolerate a NULL handle.
    ztex_context_destroy(null);
    try testing.expectEqual(@as(c_int, @backingInt(Status.invalid_argument)), ztex_last_error(
        null,
        null,
        0,
        null,
    ));
}

test "c abi: every status code has its own name" {
    inline for (@typeInfo(Status).@"enum".field_names) |name| {
        const code: c_int = @intCast(@backingInt(@field(Status, name)));
        try testing.expectEqualStrings(name, std.mem.span(ztex_status_name(code)));
    }
    try testing.expectEqualStrings("unknown status", std.mem.span(ztex_status_name(1234)));
}
