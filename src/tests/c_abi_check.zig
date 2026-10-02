//! c_abi_check — `include/ztex.h`, translated, against `src/ztex_c.zig`.
//!
//! Those two files are hand-written side by side and nothing in a Zig build
//! stops them drifting: an extra field, a reordered struct, a renamed macro,
//! a `u32` where the header says `int`, a parameter type changed on one side
//! only. This module is the guard. The build translates the REAL header and
//! hands it in as the module `header`; `src/ztex_c.zig` then calls
//! `checkEntrypoints` with its own declarations and this file compares each
//! one against what the header says.
//!
//! It is a TEST module. The shipped library never compiles C: the header is
//! behind an optional marker decl that only this root defines, so a build
//! without it skips the seam entirely.
//!
//! Checks: name-paired C schema. Struct fields pair by name, so a same-size
//! field change is caught; scalars compare by width, signedness and
//! integer-vs-float. Pointers compare size, alignment, pointee constness and
//! the matched pointee type, including opaque context identity. Functions
//! compare arity, calling convention, every parameter and return type.
//! A callback is compared signature-deep, not as an address.
//! A sentinel is not compared: a C spelling carries none, so NUL
//! termination and nullability stay runtime claims the header makes in prose
//! and `c_consumer.c` exercises.
//!
//! What makes it a check rather than a ritual:
//!
//! - The types compared are the ACTUAL ones, taken from `src/ztex_c.zig` by
//!   `@TypeOf` at the declaration. A drift on the source side is caught, not
//!   just a drift in the header.
//! - A type the classifier cannot place is a `@compileError`, never a silent
//!   pass, and a name that matches no swept list fails the build.
//! - Every declaration the header publishes is either one this file compares
//!   or a compile error naming it, so a new header export cannot slip past
//!   unexamined.
//! - Every enum tag is matched to its macro by DERIVING the macro's name, so
//!   a tag added to a status, a style or a format without a matching
//!   `#define` fails here — and every `ZTEX_` macro must be accounted for by
//!   one of those enums, so an orphan macro fails too.
//! - Each function in the source seam must match the header, and every header
//!   function must occur in that seam. New private exports must be added to
//!   the source seam; Zig reflection cannot enumerate private exports.
//!
//! Every check is `comptime`. The seam is called from a `comptime` block in
//! `src/ztex_c.zig`, so a mismatch is a compile error rather than a failing
//! assertion, in every optimize mode. What a pass establishes is that this
//! mirror and this header agree, for this target and this configuration, over
//! the declarations named here. It is not portability across targets or
//! header revisions, and it is not execution — `src/tests/c_consumer.c`
//! compiles against the real header, links the real archive and runs.
//!
//! This module is the header test root's own surface, not a host extension
//! mechanism: nothing imports it but `src/ztex_c.zig`, and only through the
//! `@hasDecl` marker below.

const std = @import("std");

/// The translated `include/ztex.h`. Public because it is the MARKER:
/// `src/ztex_c.zig` looks for this exact decl and calls `checkEntrypoints`
/// only when it finds it, so no other build of the library translates C.
pub const ztex_header = @import("header");
const header = ztex_header;
const environment = @import("environment");

comptime {
    std.testing.refAllDecls(@import("ztex.c"));
}

// ── what the header publishes ─────────────────────────────────

const swept_structs = [_][]const u8{
    "ztex_allocator",
    "ztex_svg_options",
    "ztex_raster_options",
};
const swept_opaque = [_][]const u8{"ztex_context"};
const swept_typedefs = [_][]const u8{ "ztex_u8", "ztex_u32" };
const swept_functions = [_][]const u8{
    "ztex_status_name",
    "ztex_context_create",
    "ztex_context_destroy",
    "ztex_render_svg",
    "ztex_render_raster",
    "ztex_last_error",
};

// ── the classifier ─────────────────────────────────────────

/// Whether the two types occupy the same C ABI. A type this cannot place is
/// a compile error naming it, so an unmapped shape fails the build instead of
/// passing quietly.
///
/// Pointers compare size, alignment, pointee constness and matched pointee
/// identity. Aggregate identities come from the source seam and translated
/// header types. Sentinel and nullability are not encoded by C:
/// `const char *` reaches this file as `[*c]const u8`, which encodes
/// no terminator and no optional. Those two are RUNTIME contracts stated in
/// the header, and `c_consumer.c` is what exercises them.
fn sameAbiType(
    comptime zig_type: type,
    comptime c_type: type,
    comptime entries: anytype,
) bool {
    const a = @typeInfo(zig_type);
    const b = @typeInfo(c_type);
    if (a == .optional) {
        if (@typeInfo(a.optional.child) != .pointer)
            @compileError("C ABI guard supports optional pointers only");
        if (@sizeOf(zig_type) != @sizeOf(a.optional.child)) return false;
        return sameAbiType(
            a.optional.child,
            if (b == .optional) b.optional.child else c_type,
            entries,
        );
    }
    if (b == .optional) {
        if (@typeInfo(b.optional.child) != .pointer)
            @compileError("translated C optional is not a pointer");
        return sameAbiType(zig_type, b.optional.child, entries);
    }
    switch (a) {
        .@"fn" => {
            if (b != .@"fn") return false;
            return sameFnType(zig_type, c_type, entries);
        },
        .pointer => {
            if (b != .pointer) return false;
            if (@sizeOf(zig_type) != @sizeOf(c_type)) return false;
            if (@alignOf(zig_type) != @alignOf(c_type)) return false;
            if (a.pointer.is_const != b.pointer.is_const) return false;
            const child = a.pointer.child;
            if (child == anyopaque) return CTypeChild(c_type) == anyopaque;
            return switch (@typeInfo(child)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => blk: {
                    const c_child = CTypeChild(c_type);
                    if (child == entries.context) break :blk c_child == header.ztex_context;
                    if (child == entries.allocator) break :blk c_child == header.ztex_allocator;
                    if (child == entries.svg_options) break :blk c_child == header.ztex_svg_options;
                    if (child == entries.raster_options)
                        break :blk c_child == header.ztex_raster_options;
                    @compileError("unclassified C ABI pointee " ++ @typeName(child));
                },
                else => sameAbiType(child, CTypeChild(c_type), entries),
            };
        },
        .int => {
            if (b != .int) return false;
            if (a.int.bits != b.int.bits) return false;
            return a.int.signedness == b.int.signedness;
        },
        .float => {
            if (b != .float) return false;
            return a.float.bits == b.float.bits;
        },
        .void => return b == .void,
        else => @compileError(std.fmt.comptimePrint(
            "parity sweep cannot place '{s}'; add it to the classifier",
            .{@typeName(zig_type)},
        )),
    }
}

/// The pointee of a C-side pointer, reached only on the path where the Zig
/// side was already known to be a pointer.
fn CTypeChild(comptime c_type: type) type {
    return @typeInfo(c_type).pointer.child;
}

/// Arity, calling convention, every parameter and the return type. A varargs
/// difference is a difference: C89 has no `...` here, and if it ever did, the
/// caller's stack would not.
fn sameFnType(
    comptime zig_type: type,
    comptime c_type: type,
    comptime entries: anytype,
) bool {
    if (@typeInfo(zig_type) != .@"fn") @compileError("sameFnType was handed a non-function");
    if (@typeInfo(c_type) != .@"fn") return false;
    const a = @typeInfo(zig_type).@"fn";
    const b = @typeInfo(c_type).@"fn";
    if (!std.meta.eql(a.calling_convention, b.calling_convention)) return false;
    if (a.is_var_args != b.is_var_args) return false;
    if (a.params.len != b.params.len) return false;
    for (a.params, b.params) |zig_param, c_param| {
        const zig_param_type = zig_param.type orelse return false;
        const c_param_type = c_param.type orelse return false;
        if (!sameAbiType(zig_param_type, c_param_type, entries)) return false;
    }
    const zig_return = a.return_type orelse return b.return_type == null;
    const c_return = b.return_type orelse return false;
    return sameAbiType(zig_return, c_return, entries);
}

fn inList(comptime list: anytype, comptime name: []const u8) bool {
    inline for (list) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

fn startsWith(comptime name: []const u8, comptime prefix: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix);
}

// ── structs ───────────────────────────────────────────────

/// Compare one header struct against the Zig type that mirrors it: size,
/// alignment, and every field matched BY NAME in both directions, with its
/// offset and its type. A field on either side with no partner is a compile
/// error, so renaming a field fails as loudly as dropping one.
fn sameStruct(
    comptime c_name: []const u8,
    comptime zig_type: type,
    comptime entries: anytype,
) void {
    const c_type = @field(header, c_name);
    if (@sizeOf(c_type) != @sizeOf(zig_type)) @compileError(std.fmt.comptimePrint(
        "{s} is {d} bytes in ztex.h and {d} in {s}",
        .{ c_name, @sizeOf(c_type), @sizeOf(zig_type), @typeName(zig_type) },
    ));
    if (@alignOf(c_type) != @alignOf(zig_type)) @compileError(std.fmt.comptimePrint(
        "{s} is aligned {d} in ztex.h and {d} in {s}",
        .{ c_name, @alignOf(c_type), @alignOf(zig_type), @typeName(zig_type) },
    ));
    const zig_fields = @typeInfo(zig_type).@"struct".fields;
    const c_fields = @typeInfo(c_type).@"struct".fields;
    inline for (zig_fields) |zig_field| {
        const at = fieldIndex(c_fields, zig_field.name) orelse @compileError(
            "ztex.h's " ++ c_name ++ " has no field named " ++ zig_field.name ++
                ", which " ++ @typeName(zig_type) ++ " has",
        );
        const c_field = c_fields[at];
        if (@offsetOf(c_type, c_field.name) != @offsetOf(zig_type, zig_field.name))
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} sits at {d} in ztex.h and {d} in {s}",
                .{
                    c_name,                          zig_field.name,
                    @offsetOf(c_type, c_field.name), @offsetOf(zig_type, zig_field.name),
                    @typeName(zig_type),
                },
            ));
        if (!sameAbiType(zig_field.type, c_field.type, entries)) @compileError(std.fmt.comptimePrint(
            "{s}.{s} is '{s}' in ztex.h and '{s}' in {s}",
            .{
                c_name,                    zig_field.name,      @typeName(c_field.type),
                @typeName(zig_field.type), @typeName(zig_type),
            },
        ));
    }
    inline for (c_fields) |c_field| {
        if (fieldIndex(zig_fields, c_field.name) == null) @compileError(
            "ztex.h's " ++ c_name ++ " declares " ++ c_field.name ++
                ", which " ++ @typeName(zig_type) ++ " does not have",
        );
    }
}

fn fieldIndex(comptime fields: anytype, comptime name: []const u8) ?usize {
    for (fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, name)) return i;
    }
    return null;
}

// ── macros ────────────────────────────────────────────────

/// The macro name an enum tag must have: `prefix` plus the tag in upper case.
/// Derived, never listed, so a tag without a matching `#define` fails this
/// file instead of being skipped by it.
fn macroName(comptime prefix: []const u8, comptime tag: []const u8) [:0]const u8 {
    const uppercase = comptime blk: {
        var buf: [tag.len]u8 = undefined;
        for (tag, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
        break :blk buf;
    };
    return prefix ++ uppercase ++ "";
}

fn lowerName(comptime name: []const u8) [:0]const u8 {
    const lowercase = comptime blk: {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        break :blk buf;
    };
    return lowercase ++ "";
}

/// Compare every tag of an enum with the `#define` that carries its code, and
/// name the macro a tag has none of.
fn sameMacroCodes(comptime enum_type: type, comptime prefix: []const u8) void {
    inline for (@typeInfo(enum_type).@"enum".fields) |field| {
        const name = macroName(prefix, field.name);
        if (!@hasDecl(header, name)) @compileError(
            "ztex.h defines no " ++ name ++ ", which " ++ @typeName(enum_type) ++ " needs",
        );
        if (@field(header, name) != field.value) @compileError(std.fmt.comptimePrint(
            "{s} is {d} in {s} and {d} in ztex.h",
            .{ name, field.value, @typeName(enum_type), @field(header, name) },
        ));
    }
}

/// Whether a `ZTEX_` macro is one of the three enums that must account for
/// it. An orphan — a macro no tag claims — fails, so a retired code left in
/// the header is caught too. The suffix is lower-cased for the lookup,
/// because a macro is upper case and a tag is not: `ZTEX_PIXEL_RGBA32` is the
/// tag `rgba32`.
fn macroAccountedFor(comptime macro: []const u8, comptime entries: anytype) bool {
    if (std.mem.eql(u8, macro, "ZTEX_COLOR_NONE") or
        std.mem.eql(u8, macro, "ZTEX_H")) return true;
    if (startsWith(macro, "ZTEX_STYLE_")) {
        return @hasField(entries.style, lowerName(macro["ZTEX_STYLE_".len..]));
    }
    if (startsWith(macro, "ZTEX_PIXEL_")) {
        return @hasField(entries.format, lowerName(macro["ZTEX_PIXEL_".len..]));
    }
    return @hasField(entries.status, lowerName(macro["ZTEX_".len..]));
}

// ── the seam ──────────────────────────────────────────────

/// Compare the source seam's exported types against the real header.
///
/// `entries` is the source of truth and carries the declarations themselves,
/// taken at the declaration with `@TypeOf`:
/// `entries` (one field per exported function), `allocator`, `svg_options`,
/// `context`, `raster_options`, `status`, `style`, `format` and `color_none`.
pub fn checkEntrypoints(comptime entries: anytype) void {
    @setEvalBranchQuota(10_000);
    // The three structs, field by field.
    sameStruct("ztex_allocator", entries.allocator, entries);
    sameStruct("ztex_svg_options", entries.svg_options, entries);
    sameStruct("ztex_raster_options", entries.raster_options, entries);

    // Every code the library and the header both publish.
    sameMacroCodes(entries.status, "ZTEX_");
    sameMacroCodes(entries.style, "ZTEX_STYLE_");
    sameMacroCodes(entries.format, "ZTEX_PIXEL_");
    if (header.ZTEX_COLOR_NONE != entries.color_none) @compileError(std.fmt.comptimePrint(
        "ZTEX_COLOR_NONE is {d} and the library's color_none is {d}",
        .{ header.ZTEX_COLOR_NONE, entries.color_none },
    ));

    // Entry points, both directions: everything exported must be declared,
    // and everything declared must be exported.
    const exported = @typeInfo(@TypeOf(entries)).@"struct".fields;
    inline for (exported) |field| {
        if (!startsWith(field.name, "ztex_")) continue;
        if (!inList(swept_functions, field.name) or !@hasDecl(header, field.name))
            @compileError("unclassified exported C function " ++ field.name);
        const actual = @field(entries, field.name);
        if (!sameAbiType(actual, @TypeOf(@field(header, field.name)), entries))
            @compileError(std.fmt.comptimePrint(
                "{s} is declared as '{s}' in ztex.h, not as the '{s}' src/ztex_c.zig exports",
                .{ field.name, @typeName(@TypeOf(@field(header, field.name))), @typeName(actual) },
            ));
    }
    inline for (swept_functions) |name| {
        if (!@hasField(@TypeOf(entries), name)) @compileError(
            "ztex.h declares " ++ name ++ ", which src/ztex_c.zig exports no",
        );
    }

    // And no macro is an orphan.
    inline for (@typeInfo(header).@"struct".decls) |decl| {
        if (!startsWith(decl.name, "ZTEX_")) continue;
        if (!macroAccountedFor(decl.name, entries)) @compileError(std.fmt.comptimePrint(
            "ztex.h defines {s}, which no status, style or format code accounts for",
            .{decl.name},
        ));
    }
}

// ── what the header side can check on its own ─────────────

// Subtract the empty-header translation, not a hand-maintained compiler
// macro allowlist. Every remaining declaration must belong to this header.
comptime {
    @setEvalBranchQuota(10_000);
    for (@typeInfo(header).@"struct".decls) |decl| {
        if (@hasDecl(environment, decl.name)) continue;
        if (inList(swept_structs, decl.name) or inList(swept_opaque, decl.name) or
            inList(swept_typedefs, decl.name) or inList(swept_functions, decl.name) or
            startsWith(decl.name, "ZTEX_")) continue;
        if (startsWith(decl.name, "struct_")) {
            const alias = decl.name["struct_".len..];
            if (inList(swept_structs, alias) or inList(swept_opaque, alias)) {
                if (@field(header, decl.name) != @field(header, alias))
                    @compileError("translated C tag differs from its typedef: " ++ decl.name);
                continue;
            }
        }
        @compileError(std.fmt.comptimePrint(
            "ztex.h declares '{s}', which this parity sweep does not classify",
            .{decl.name},
        ));
    }
}

comptime {
    // The two typedefs the header defines so it needs no <stdint.h>.
    if (!sameAbiType(u8, header.ztex_u8, .{})) @compileError("ztex_u8 is not unsigned 8-bit");
    if (!sameAbiType(u32, header.ztex_u32, .{})) @compileError("ztex_u32 is not unsigned 32-bit");
    if (@typeInfo(header.ztex_context) != .@"opaque" or header.ztex_context == anyopaque)
        @compileError("ztex_context is not a distinct opaque type");
}
