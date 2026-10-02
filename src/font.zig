//! ztex.font — sfnt parsing (OpenType/CFF and TrueType/glyf), OpenType MATH
//! decoding, and a cached layer that hands out faces and glyph metrics.
//!
//! Two layers, each usable on its own:
//!
//! - `FontFace`: one parsed font. It reads the sfnt container and the tables
//!   horizontal metrics need — `head` (unitsPerEm), `hhea` (ascender,
//!   descender, lineGap), `hmtx` (per-glyph advances), `maxp` (glyph count)
//!   and `OS/2` (sTypo*/usWin* extents) — plus `cmap` (codepoint → glyph id,
//!   formats 4 and 12). Metrics always; `glyphOutline` additionally reads
//!   `loca`/`glyf` (quadratic TrueType) or executes the Type 2 charstrings
//!   and Subr INDEXes of the `CFF ` table (cubic, flattened to quadratics).
//!   A `MATH` table is decoded when the font carries one (constants, per-glyph
//!   values, and both the vertical AND the horizontal variants and
//!   assemblies) and costs nothing when it does not: such a face reports no
//!   math data.
//! - `FontContext`: the "init once, render many" layer. One arena holds the
//!   embedded Latin Modern fallbacks (LM Math plus LM Roman regular, italic,
//!   bold and bold italic), the faces loaded from disk, and the metric cache.
//!
//! Import routes: `ztex.font`, which the root module `ztex` re-exports under
//! the same name, and the relative path `font.zig` inside this tree.
//!
//! What this module deliberately does not do: it draws nothing and lays
//! nothing out (`ztex.svg` and `ztex.raster` consume it), it keeps no
//! `std.Io` of its own — the two entry points that touch the file system take
//! one per call — and it holds no process-wide state, so two contexts never
//! share a cache.
//!
//! Units: every value named "em units" is font-relative (the font's own value
//! ÷ its `unitsPerEm`), so a caller multiplies it by the size it draws at.
//! Glyph outline coordinates are the exception — `glyphOutline` returns raw
//! font units, Y-up, and the caller scales by `size_pt ÷ unitsPerEm`.
//!
//! Ownership: the allocator is the caller's and is never released here. A
//! `FontFace` from `fromBytes` owns its copy of the font bytes and releases
//! them in exactly one `deinit`; a `FontFace` a `FontContext` hands out is
//! arena-owned and needs none. A `FontContext` owns one arena and releases
//! every face, path and cache row it created in one `deinit`. `glyphOutline`
//! allocates from the allocator it is given and the caller frees that
//! `Outline`.
//!
//! Shortest sequence:
//!
//! ```zig
//! var face = try font.FontFace.fromBytes(gpa, bytes);
//! defer face.deinit();
//! const gid = face.glyphIndex('x') orelse return error.MissingGlyph;
//! var outline = try face.glyphOutline(gpa, gid);
//! defer outline.deinit();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const atom = @import("ztex.atom");

const lmmath = @import("fonts/lmmath.zig");
const lmroman_regular = @import("fonts/lmroman_regular.zig");
const lmroman_italic = @import("fonts/lmroman_italic.zig");
const lmroman_bold = @import("fonts/lmroman_bold.zig");
const lmroman_bold_italic = @import("fonts/lmroman_bold_italic.zig");

/// Per-glyph metrics at a given size, in points. The MATH measurements are
/// the face's own per-glyph values when it carries a MATH table, and null
/// when it records none (every text face is such a font).
///
/// A plain value: it owns nothing, and its numbers describe one glyph of one
/// face, so it says nothing about that face after the face is released. Ask
/// `FontContext.metrics` again for another size rather than scaling a stored
/// row yourself — the MATH fields are null-or-present, never zero-for-absent.
pub const GlyphMetrics = struct {
    /// Horizontal advance (width).
    width: f32,
    /// Nominal ascent (font hhea ascender) at this size.
    height: f32,
    /// Nominal descent (positive; -hhea descender) at this size.
    depth: f32,
    /// Nominal line gap (hhea lineGap) at this size.
    line_gap: f32,
    /// MATH horizontal italic correction at this size; null when the font
    /// records none for the glyph.
    italic_correction: ?f32 = null,
    /// MATH horizontal accent attachment at this size; null when the font
    /// records none for the glyph.
    top_accent_attachment: ?f32 = null,
};

/// What a font file can be refused for. Every table is bounds-checked, so a
/// truncated or malformed file fails with one of these instead of reading
/// past its bytes. A parse that returns one of them leaves the caller's
/// memory as it found it.
pub const FontError = error{
    /// Not an sfnt container (bad scaler or truncated header).
    InvalidSfnt,
    /// A required table (head/hhea/hmtx/cmap/maxp) is missing.
    MissingTable,
    /// A table exists but its contents are malformed.
    InvalidTable,
    /// No usable cmap subtable (neither format 4 nor format 12).
    UnsupportedCmap,
    /// CFF is CID-keyed (ROS in the Top DICT); FDArray-based charstrings
    /// are not decoded.
    UnsupportedFont,
};

/// What `FontFace.fromBytes` and `FontContext.init` can fail with: one
/// `FontError` for the font data, plus the allocator.
pub const ParseError = FontError || std.mem.Allocator.Error;

/// What `FontContext.loadFromFile` can fail with: the `ParseError` of the
/// face it builds, plus the file read that supplies the bytes.
pub const LoadError = ParseError || std.Io.Dir.ReadFileAllocError;

/// What `FontFace.glyphOutline` can fail with. A `gid` the face does not
/// have, a table the face lacks and a malformed outline are all separate
/// answers, so a caller can tell "this font cannot draw" from "this glyph is
/// not here".
/// Named explicitly rather than inferred, so the mutual recursion between
/// the glyf decoders does not form an inferred-error-set cycle.
pub const OutlineError = error{
    /// The caller allocator failed while the curve list grew.
    OutOfMemory,
    /// The glyph id is past the face's last glyph, or its outline data is
    /// malformed.
    InvalidTable,
    /// The face carries neither `glyf`/`loca` nor a `CFF ` table, so it has
    /// no outline data at all.
    MissingTable,
    /// The CFF is CID-keyed; its charstrings need an FDArray this module
    /// does not decode.
    UnsupportedFont,
};

/// One quadratic Bézier segment of a glyph outline, in raw font units — the
/// font's own design grid, not em fractions — Y-up (y grows up, FreeType
/// convention). TrueType glyphs are quadratic by construction and a CFF
/// glyph's cubics are flattened into quadratics before they arrive here, so
/// every segment in one outline is quadratic; a straight segment is carried
/// as `p1 = midpoint(p0, p2)`.
///
/// A caller draws at a point size by multiplying every coordinate by
/// `size_pt / unitsPerEm`; nothing here is pre-normalized.
pub const QuadCurve = struct {
    /// Segment start, in font units.
    p0: [2]f32,
    /// Control point, in font units.
    p1: [2]f32,
    /// Segment end, in font units.
    p2: [2]f32,
};

/// One glyph's outline: every contour reduced to quadratic segments, in raw
/// font units and Y-up (see `QuadCurve`). A glyph with no contours — a space,
/// or a contour count the format does not define — yields an empty `curves`.
///
/// An `Outline` owns `curves` and nothing else. `glyphOutline` allocates it
/// from the allocator it is given, and one `deinit` releases it through that
/// same allocator; the allocator must stay the one `glyphOutline` was given.
/// A copy made before that call shares the same buffer, so it is not a second
/// owner and must not be deinited.
pub const Outline = struct {
    /// Allocator `curves` is allocated from and `deinit` frees through it.
    gpa: std.mem.Allocator,
    /// The flattened contour segments, in the order the decoders emitted them:
    /// one contour after another, and within a contour a chain the caller
    /// walks by matching `p2` against the next segment's `p0`.
    curves: std.ArrayList(QuadCurve) = .empty,

    /// Releases `curves` through `gpa` and leaves the outline unusable; a
    /// second call frees the same memory again.
    pub fn deinit(self: *Outline) void {
        self.curves.deinit(self.gpa);
        self.* = undefined;
    }
};

/// Bounds-checked big-endian reader over a table slice.
const Reader = struct {
    data: []const u8,

    fn readU8(self: Reader, off: usize) error{InvalidTable}!u8 {
        if (off + 1 > self.data.len) return error.InvalidTable;
        return self.data[off];
    }

    fn readU16(self: Reader, off: usize) error{InvalidTable}!u16 {
        if (off + 2 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(u16, self.data[off..][0..2], .big);
    }

    fn readI16(self: Reader, off: usize) error{InvalidTable}!i16 {
        if (off + 2 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(i16, self.data[off..][0..2], .big);
    }

    fn readI32(self: Reader, off: usize) error{InvalidTable}!i32 {
        if (off + 4 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(i32, self.data[off..][0..4], .big);
    }

    fn readU32(self: Reader, off: usize) error{InvalidTable}!u32 {
        if (off + 4 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(u32, self.data[off..][0..4], .big);
    }
};

/// Compile-time 4-byte sfnt tag (e.g. `tag("head")`).
fn tag(comptime s: []const u8) u32 {
    comptime std.debug.assert(s.len == 4);
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | @as(u32, s[3]);
}

const TableLoc = struct {
    offset: usize,
    length: usize,
};

/// Locate a table record in the sfnt directory.
fn findTable(data: []const u8, want: u32) !TableLoc {
    if (data.len < 12) return error.InvalidSfnt;
    const num_tables = try (Reader{ .data = data }).readU16(4);
    if (12 + 16 * num_tables > data.len) return error.InvalidSfnt;
    var i: u32 = 0;
    while (i < num_tables) : (i += 1) {
        const rec = 12 + 16 * i;
        const have = std.mem.readInt(u32, data[rec..][0..4], .big);
        if (have != want) continue;
        const offset = try (Reader{ .data = data }).readU32(rec + 8);
        const length = try (Reader{ .data = data }).readU32(rec + 12);
        if (offset + length > data.len) return error.InvalidSfnt;
        return .{ .offset = offset, .length = length };
    }
    return error.MissingTable;
}

/// Priority score for a cmap subtable's platform/encoding pair, per the
/// OpenType recommendation (higher wins). We keep the best format-12 and the
/// best format-4 subtable independently; lookup prefers 12 (full repertoire)
/// and falls back to 4 (BMP).
fn cmapScore(platform: u16, encoding: u16) u8 {
    if (platform == 3 and encoding == 10) return 9;
    if (platform == 0 and encoding == 6) return 8;
    if (platform == 0 and encoding == 4) return 7;
    if (platform == 3 and encoding == 1) return 6;
    if (platform == 0 and encoding == 3) return 5;
    if (platform == 0 and encoding == 2) return 4;
    if (platform == 3 and encoding == 0) return 3;
    if (platform == 1 and encoding == 0) return 2;
    return 1;
}

/// Pick the best format-4 and format-12 subtables from a cmap table.
fn selectCmap(face: *FontFace, table: []const u8) FontError!void {
    const r: Reader = .{ .data = table };
    const num_subtables = try r.readU16(2);
    var best4: ?[]const u8 = null;
    var best4_score: u8 = 0;
    var best12: ?[]const u8 = null;
    var best12_score: u8 = 0;
    var i: u32 = 0;
    while (i < num_subtables) : (i += 1) {
        const rec = 4 + 8 * i;
        const platform = try r.readU16(rec);
        const encoding = try r.readU16(rec + 2);
        const offset: usize = try r.readU32(rec + 4);
        const format = try r.readU16(offset);
        const sub: []const u8 = switch (format) {
            4 => blk: {
                const len: usize = try r.readU16(offset + 2);
                if (offset + len > table.len) return error.InvalidTable;
                break :blk table[offset..][0..len];
            },
            12 => blk: {
                const len: usize = try r.readU32(offset + 4);
                if (offset + len > table.len) return error.InvalidTable;
                break :blk table[offset..][0..len];
            },
            else => continue, // formats 0/6/13/14 are not needed for metrics
        };
        const score = cmapScore(platform, encoding);
        if (format == 4 and score > best4_score) {
            best4 = sub;
            best4_score = score;
        } else if (format == 12 and score > best12_score) {
            best12 = sub;
            best12_score = score;
        }
    }
    if (best4 == null and best12 == null) return error.UnsupportedCmap;
    face.cmap4 = best4;
    face.cmap12 = best12;
}

/// Format 12 (segmented coverage) lookup: binary search over groups sorted
/// by startCharCode. Handles the full Unicode range.
fn cmap12Lookup(table: []const u8, cp: u21) ?u32 {
    const r: Reader = .{ .data = table };
    const num_groups = r.readU32(12) catch return null;
    var lo: u32 = 0;
    var hi: u32 = num_groups;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if ((r.readU32(16 + 12 * mid + 4) catch return null) < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo >= num_groups) return null;
    const start = r.readU32(16 + 12 * lo) catch return null;
    if (cp < start) return null;
    const gid_start = r.readU32(16 + 12 * lo + 8) catch return null;
    return gid_start + (cp - start);
}

/// Format 4 (segment mapping to delta values) lookup: binary search over
/// endCode, then apply the segment delta or glyphIdArray indirection. BMP
/// only (callers gate `cp <= 0xFFFF`).
fn cmap4Lookup(table: []const u8, cp: u16) ?u32 {
    const r: Reader = .{ .data = table };
    const seg_count_x2: usize = r.readU16(6) catch return null;
    const seg_count = seg_count_x2 / 2;
    const end_base: usize = 14;
    const start_base = end_base + seg_count_x2 + 2;
    const delta_base = start_base + seg_count_x2;
    const ro_base = delta_base + seg_count_x2;
    var lo: usize = 0;
    var hi: usize = seg_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if ((r.readU16(end_base + 2 * mid) catch return null) < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo >= seg_count) return null;
    const i = lo;
    const start = r.readU16(start_base + 2 * i) catch return null;
    if (cp < start) return null;
    const delta: u16 = @bitCast(r.readI16(delta_base + 2 * i) catch return null);
    const id_range_offset: usize = r.readU16(ro_base + 2 * i) catch return null;
    if (id_range_offset == 0) {
        // gid = (cp + delta) mod 65536
        return cp +% delta;
    }
    // gid sits in the glyphIdArray, addressed from this idRangeOffset entry.
    const gid16 = r.readU16(ro_base + 2 * i + id_range_offset + 2 * (cp - start)) catch return null;
    if (gid16 == 0) return null;
    return gid16 +% delta;
}

/// One glyph's MATH measurements, in em units. A field is null when the
/// font records no value for the glyph — and every field is null on a
/// face whose font has no MATH table. The MATH table carries a single
/// accent attachment point per glyph (the top accent), so there is no
/// axis or bottom attachment value to report.
pub const MathGlyphValues = struct {
    /// Horizontal italic correction.
    italic_correction: ?f32,
    /// Height of the glyph's top accent attachment point.
    top_accent_attachment: ?f32,
};

/// The MATH table's font-wide constants. The type itself belongs to
/// `ztex.atom` — `atom.MathConstants` — so the layout module reads the same
/// decoded values through the FontHook without importing this file, which
/// the module graph forbids. This alias is private to the parser below.
const MathConstants = atom.MathConstants;

/// A glyph's size-variant ladder along one extension axis — vertical for a
/// fence or a radical, horizontal for a wide bar or an extensible arrow —
/// smallest first and excluding the base glyph: `glyph(0)` is the first size
/// variant, the glyph a renderer draws when it needs one step of growth.
///
/// A borrowed view over the face's own font bytes, not a copy and not an
/// allocation: the two fields point into `FontFace.data`, and both are valid
/// until that face is released. Copying the struct copies the view, so a copy
/// dies at the same moment.
pub const MathVariants = struct {
    /// Variant records — glyph id then advance measurement, 4 bytes each —
    /// sliced from the MATH table.
    records: []const u8,
    /// The face's design units per em: the divisor `advanceEm` applies.
    units_per_em: u16,

    /// Number of size variants in `records`.
    pub fn len(self: MathVariants) usize {
        return self.records.len / 4;
    }

    /// The `i`th variant's glyph id, in the face this ladder came from.
    /// `i` must be < `len()`; that bound is a debug assertion, so a release
    /// build reads past the records instead of reporting it.
    pub fn glyph(self: MathVariants, i: usize) u32 {
        std.debug.assert(i < self.len());
        return readBeU16(self.records[4 * i ..]);
    }

    /// The `i`th variant's advance measurement along the extension axis,
    /// in em units. `i` must be < `len()`, on the same assertion as `glyph`.
    pub fn advanceEm(self: MathVariants, i: usize) f32 {
        std.debug.assert(i < self.len());
        return emValue(readBeU16(self.records[4 * i + 2 ..]), self.units_per_em);
    }
};

/// One part of a glyph assembly, in em units: a glyph plus the straight
/// connector material at its ends. A renderer stacks parts along the
/// extension axis, skipping or repeating extenders, until the target size is
/// reached. `glyph` is an id in the face the assembly came from.
pub const MathAssemblyPart = struct {
    /// The part's glyph id.
    glyph: u32,
    /// Connector material at the start of the part.
    start_connector_length: f32,
    /// Connector material at the end of the part.
    end_connector_length: f32,
    /// The part's full advance along the extension axis.
    full_advance: f32,
    /// True when the part may be skipped or repeated, which is how a
    /// size between two exact stacks is reached.
    extender: bool,
};

/// How to build a stretched glyph: the parts to repeat along one extension
/// axis (bottom to top for a fence, left to right for a wide bar), and the
/// assembly's own italic correction.
///
/// A borrowed view over the face's own font bytes: `parts` points into
/// `FontFace.data` and both views are valid until that face is released.
pub const MathAssembly = struct {
    /// Italic correction of the whole assembly, in em units.
    italic_correction: f32,
    /// Part records — glyph id, the two connector lengths, the full
    /// advance, then the part flags, 10 bytes each — sliced from the
    /// MATH table.
    parts: []const u8,
    /// The face's design units per em: the divisor `part` applies.
    units_per_em: u16,

    /// Number of parts in `parts`.
    pub fn partCount(self: MathAssembly) usize {
        return self.parts.len / 10;
    }

    /// The `i`th part, counting from the first end along the axis (the
    /// bottom for a vertical assembly, the left for a horizontal one).
    /// `i` must be < `partCount()`; that bound is a debug assertion, so a
    /// release build reads past the records instead of reporting it.
    pub fn part(self: MathAssembly, i: usize) MathAssemblyPart {
        std.debug.assert(i < self.partCount());
        const rec = self.parts[10 * i ..];
        const upem = self.units_per_em;
        return .{
            .glyph = readBeU16(rec),
            .start_connector_length = emValue(readBeU16(rec[2..]), upem),
            .end_connector_length = emValue(readBeU16(rec[4..]), upem),
            .full_advance = emValue(readBeU16(rec[6..]), upem),
            .extender = (readBeU16(rec[8..]) & extender_flag) != 0,
        };
    }
};

/// GlyphPartRecord PartFlags bit 0: the part may be skipped or repeated.
const extender_flag: u32 = 0x0001;

/// Big-endian u16 at the start of `bytes` (at least 2 long), widened to
/// u32 so a glyph id and a measurement share one accessor.
fn readBeU16(bytes: []const u8) u32 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

/// A MATH design-unit value in em units. Accepts either integer width the
/// table uses; f64 is exact for both, and the result is narrowed to the
/// f32 the layout scales from.
fn emValue(value: anytype, units_per_em: u16) f32 {
    const v: f64 = @floatFromInt(value);
    const u: f64 = @floatFromInt(units_per_em);
    return @floatCast(v / u);
}

/// A MathConstants percentage (stored 0-100) as a ratio.
fn mathRatio(percent: anytype) f32 {
    return @as(f32, @floatFromInt(percent)) / 100.0;
}

/// A MATH coverage table (format 1 glyph array or format 2 range table)
/// held as a validated slice of the face's font bytes. Coverage order is
/// ascending glyph order in both formats.
const MathCoverage = struct {
    /// format u16, count u16, then the glyph array (format 1) or the
    /// range array (format 2).
    table: []const u8,

    /// Number of covered glyphs.
    fn count(self: MathCoverage) usize {
        return readBeU16(self.table[2..]);
    }

    /// `gid`'s position in the coverage order, or null when the glyph is
    /// not covered. Format 1 binary-searches the sorted glyph array;
    /// format 2 binary-searches the sorted ranges and adds the glyph's
    /// distance from its range's start to that range's first index.
    fn indexOf(self: MathCoverage, gid: u32) ?u32 {
        if (gid > 0xFFFF) return null;
        const want: u16 = @intCast(gid);
        const r: Reader = .{ .data = self.table };
        return switch (r.readU16(0) catch return null) {
            1 => format1Index(self.table, want),
            2 => format2Index(self.table, want),
            else => null,
        };
    }
};

/// Coverage format 1: the index of `want` in the sorted glyph array, or
/// null when it is absent.
fn format1Index(table: []const u8, want: u16) ?u32 {
    const r: Reader = .{ .data = table };
    const count = r.readU16(2) catch return null;
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if ((r.readU16(4 + 2 * mid) catch return null) < want) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo >= count) return null;
    const gid = r.readU16(4 + 2 * lo) catch return null;
    return if (gid == want) @intCast(lo) else null;
}

/// Coverage format 2: the index of `want` inside the sorted range table,
/// or null when no range covers it.
fn format2Index(table: []const u8, want: u16) ?u32 {
    const r: Reader = .{ .data = table };
    const count = r.readU16(2) catch return null;
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const rec = 4 + 6 * mid;
        const start = r.readU16(rec) catch return null;
        const end = r.readU16(rec + 2) catch return null;
        if (want < start) {
            hi = mid;
        } else if (want > end) {
            lo = mid + 1;
        } else {
            const first = r.readU16(rec + 4) catch return null;
            return first + (want - start);
        }
    }
    return null;
}

/// A coverage-ordered array of MathValueRecords — the MATH table's
/// per-glyph value plus its (ignored) device-table offset — held as a
/// slice of the face's font bytes.
const MathValueList = struct {
    coverage: MathCoverage,
    /// 4 bytes per covered glyph, in coverage order.
    records: []const u8,

    /// The glyph's design-unit value, or null when the glyph has no
    /// record (or the array is shorter than its coverage claims).
    fn get(self: MathValueList, gid: u32) ?i16 {
        const off = 4 * (self.coverage.indexOf(gid) orelse return null);
        if (off + 2 > self.records.len) return null;
        return std.mem.readInt(i16, self.records[off..][0..2], .big);
    }
};

/// The vertical constructions of the MATH table: which glyphs grow, and
/// where each construction lives. Every offset is relative to the
/// MathVariants table, which `base` locates in the MATH table.
const MathVariantIndex = struct {
    /// Byte offset of the MathVariants table within the MATH table.
    base: usize,
    coverage: MathCoverage,
    /// 2 bytes per covered glyph: that glyph's construction offset.
    offsets: []const u8,

    /// Byte offset of `gid`'s construction within the MATH table, or null
    /// when the glyph has none.
    fn constructionOffset(self: MathVariantIndex, gid: u32) ?usize {
        const at = 2 * (self.coverage.indexOf(gid) orelse return null);
        if (at + 2 > self.offsets.len) return null;
        const off = readBeU16(self.offsets[at..]);
        if (off == 0) return null;
        return self.base + off;
    }
};

/// The two construction indexes of one MathVariants table: the glyphs that
/// grow up/down and the glyphs that grow left/right. Both index the same
/// table, so a construction offset means the same thing in either half.
/// Either half is null when the font grows nothing along that axis: the
/// format leaves the coverage offset NULL whenever its glyph count is zero,
/// and a lookup on an absent axis finds nothing.
const MathVariantHalves = struct {
    vert: ?MathVariantIndex,
    horiz: ?MathVariantIndex,
};

/// The MATH table's structures. The constants are decoded into em units
/// at parse time; everything else is a validated view into the face's own
/// font bytes, so a lookup neither allocates nor re-scans the table.
const MathData = struct {
    /// The MATH table itself, into the face's `data`.
    table: []const u8,
    units_per_em: u16,
    constants: MathConstants,
    /// Minimum overlap a renderer may leave between assembled connector
    /// parts, em units.
    min_connector_overlap: f32,
    italics: ?MathValueList,
    top_accent: ?MathValueList,
    variants: MathVariantHalves,

    /// The glyph's italic correction, em units, or null when the font
    /// records none.
    fn italicsEm(self: *const MathData, gid: u32) ?f32 {
        const raw = (self.italics orelse return null).get(gid) orelse return null;
        return emValue(raw, self.units_per_em);
    }

    /// The glyph's top accent attachment height, em units, or null when
    /// the font records none.
    fn topAccentEm(self: *const MathData, gid: u32) ?f32 {
        const raw = (self.top_accent orelse return null).get(gid) orelse return null;
        return emValue(raw, self.units_per_em);
    }

    /// `gid`'s vertical size variants, excluding the base glyph, or null
    /// when it has no construction or the construction lists no variants.
    fn verticalVariantsOf(self: *const MathData, gid: u32) ?MathVariants {
        const index = self.variants.vert orelse return null;
        return self.ladderOf(index.constructionOffset(gid), gid, false);
    }

    /// `gid`'s horizontal size variants — the same ladder read along x.
    fn horizontalVariantsOf(self: *const MathData, gid: u32) ?MathVariants {
        const index = self.variants.horiz orelse return null;
        return self.ladderOf(index.constructionOffset(gid), gid, true);
    }

    /// Horizontal selection needs the base record's stretch measurement,
    /// which can be positive even when the combining glyph's hmtx advance is zero.
    fn ladderOf(
        self: *const MathData,
        at: ?usize,
        gid: u32,
        comptime include_base: bool,
    ) ?MathVariants {
        const c = at orelse return null;
        const r: Reader = .{ .data = self.table };
        const count = r.readU16(c + 2) catch return null;
        if (count == 0) return null;
        const records_start = c + 4;
        const records_bytes = 4 * @as(usize, count);
        if (records_start + records_bytes > self.table.len) return null;
        const skip: usize = if (!include_base and readBeU16(self.table[records_start..]) == gid)
            1
        else
            0;
        if (skip == count) return null;
        const start = records_start + 4 * skip;
        const bytes = records_bytes - 4 * skip;
        return .{
            .records = self.table[start..][0..bytes],
            .units_per_em = self.units_per_em,
        };
    }

    /// `gid`'s vertical glyph assembly, or null when it has none.
    fn verticalAssemblyOf(self: *const MathData, gid: u32) ?MathAssembly {
        const index = self.variants.vert orelse return null;
        return self.stackedAt(index.constructionOffset(gid));
    }

    /// `gid`'s horizontal glyph assembly, or null when it has none.
    fn horizontalAssemblyOf(self: *const MathData, gid: u32) ?MathAssembly {
        const index = self.variants.horiz orelse return null;
        return self.stackedAt(index.constructionOffset(gid));
    }

    /// The glyph assembly at `at`: the pieces a renderer repeats along one
    /// axis until it has the size it needs, or null when it has none.
    fn stackedAt(self: *const MathData, at: ?usize) ?MathAssembly {
        const c = at orelse return null;
        const r: Reader = .{ .data = self.table };
        const rel = r.readU16(c) catch return null;
        if (rel == 0) return null;
        const a = c + rel;
        const italic = r.readI16(a) catch return null;
        const count = r.readU16(a + 4) catch return null;
        const start = a + 6;
        const bytes = 10 * count;
        if (start + bytes > self.table.len) return null;
        return .{
            .italic_correction = emValue(italic, self.units_per_em),
            .parts = self.table[start..][0..bytes],
            .units_per_em = self.units_per_em,
        };
    }
};

/// One parsed font: its metrics, its codepoint-to-glyph mapping and its MATH
/// data, decoded out of one sfnt file. Every table the face exposes is a view
/// into `data`, so a lookup neither re-parses nor allocates.
///
/// Two ownership regimes, one type. A face from `fromBytes` owns its copy of
/// the file bytes through `gpa` and releases them in exactly one `deinit`. A
/// face a `FontContext` hands out is owned by that context's arena: `gpa` is
/// `null`, its `deinit` releases nothing, and every slice and view it returns
/// dies with the context. Copying a face copies the handle, not the bytes, so
/// a copy is not a second owner and must not be deinited; note that
/// `FontContext.metrics` keys its cache on the face's ADDRESS, so a copied
/// face measures under its own row while reading the same data.
pub const FontFace = struct {
    /// Allocator that owns `data`, or null when a `FontContext`'s arena owns
    /// it — which is exactly when `deinit` has nothing to release.
    gpa: ?std.mem.Allocator,
    /// The whole font file (sfnt container), including every table slice
    /// below. Immutable after parsing; a caller may read it to reach a table
    /// this module does not decode.
    data: []u8,

    /// head.unitsPerEm: design units in one em. The divisor every em-unit
    /// accessor here and every outline coordinate applies.
    units_per_em: u16,
    /// maxp.numGlyphs: how many glyph ids this face has. A larger `gid` is
    /// out of range for `glyphOutline`.
    num_glyphs: u16,

    // hhea
    /// hhea.ascender in design units, negative when the font descends.
    hhea_ascender: i16,
    /// hhea.descender in design units; `descenderEm` negates it, so the
    /// reported descent is positive.
    hhea_descender: i16,
    /// hhea.lineGap in design units.
    hhea_line_gap: i16,
    /// hhea.numberOfHMetrics: how many long (advance, lsb) records `hmtx`
    /// opens with. Glyphs past it share the last advance.
    num_h_metrics: u16,

    // OS/2 (optional table; zero when absent)
    /// OS/2 sTypoAscender in design units, 0 when the table is absent or
    /// truncated before it.
    os2_typo_ascender: i16,
    /// OS/2 sTypoDescender in design units, 0 when absent.
    os2_typo_descender: i16,
    /// OS/2 sTypoLineGap in design units, 0 when absent.
    os2_typo_line_gap: i16,
    /// OS/2 usWinAscent in design units (clipping extent), 0 when absent.
    os2_win_ascent: u16,
    /// OS/2 usWinDescent in design units (clipping extent), 0 when absent.
    os2_win_descent: u16,

    /// True only for the embedded Latin Modern Math file, matched byte for
    /// byte at parse time. That one font keeps four prime alternates off its
    /// cmap for script-size runs, and those ids (`script_prime_gids`) name
    /// glyphs only it has, so `smallPrimeGid` answers for a face that is
    /// exactly this one and for no other: the length test comes first and the
    /// byte comparison runs only on a match. Read-only after parsing.
    has_script_prime_alternates: bool,

    /// hmtx table slice (into `data`); first num_h_metrics entries are
    /// (advanceWidth u16, lsb i16) pairs, later glyphs share the last advance.
    hmtx: []const u8,

    /// Selected cmap subtables (into `data`), null when the font lacks one.
    cmap4: ?[]const u8,
    cmap12: ?[]const u8,

    /// loca table slice (into `data`); null for CFF/OTF fonts (no glyf).
    loca: ?[]const u8,
    /// glyf table slice (into `data`); null for CFF/OTF fonts.
    glyf: ?[]const u8,
    /// head.indexToLocFormat: 0 = short loca (u16 offsets × 2), 1 = long
    /// (u32 offsets).
    index_to_loc_format: i16,

    /// Parsed CFF structure (CharStrings/Subr INDEXes into `data`); null
    /// for TrueType fonts (no `CFF ` table).
    cff: ?CffData,
    /// True when the scaler was 'OTTO' (OpenType/CFF): outlines come from
    /// Type 2 charstrings, not glyf.
    is_cff: bool,
    /// True when the Top DICT declares ROS (CID-keyed). Charstrings then
    /// need FDArray/FDSelect; glyphOutline reports UnsupportedFont.
    cff_cid: bool,

    /// Parsed MATH table (views into `data`); null when the font has none.
    math: ?MathData,

    /// Parse `data` into a face, keeping a private copy of it in `gpa`.
    ///
    /// `data` need not outlive the call — the face owns its bytes — and every
    /// view the face returns points into that copy, not into `data`. On any
    /// error the copy is released and nothing is returned, so the caller owns
    /// nothing afterwards. The result is the caller's to release in one
    /// `deinit`; nothing else releases it.
    pub fn fromBytes(gpa: std.mem.Allocator, data: []const u8) ParseError!FontFace {
        const owned = try gpa.dupe(u8, data);
        errdefer gpa.free(owned);
        return parseOwned(owned, gpa);
    }

    /// Releases the owned byte copy when the face owns one (a face from
    /// `fromBytes`); an arena-owned face keeps its bytes, which its
    /// `FontContext` releases. Either way the face is unusable after this
    /// call, and calling it twice on an owning face frees the same bytes
    /// again.
    pub fn deinit(self: *FontFace) void {
        if (self.gpa) |gpa| gpa.free(self.data);
        self.* = undefined;
    }

    /// Font design size in font units per em (head.unitsPerEm).
    pub fn unitsPerEm(self: *const FontFace) u16 {
        return self.units_per_em;
    }

    /// Nominal ascent, em units (hhea.ascent ÷ upem).
    pub fn ascenderEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.hhea_ascender)) / upem;
    }

    /// Nominal descent, em units, positive (-hhea.descent ÷ upem).
    pub fn descenderEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(-self.hhea_descender)) / upem;
    }

    /// Nominal line gap, em units (hhea.lineGap ÷ upem).
    pub fn lineGapEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.hhea_line_gap)) / upem;
    }

    /// OS/2 sTypoAscender, em units.
    pub fn typoAscenderEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.os2_typo_ascender)) / upem;
    }

    /// OS/2 sTypoDescender, em units, positive.
    pub fn typoDescenderEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(-self.os2_typo_descender)) / upem;
    }

    /// OS/2 sTypoLineGap, em units.
    pub fn typoLineGapEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.os2_typo_line_gap)) / upem;
    }

    /// OS/2 usWinAscent (clipping extent), em units.
    pub fn winAscentEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.os2_win_ascent)) / upem;
    }

    /// OS/2 usWinDescent (clipping extent), em units.
    pub fn winDescentEm(self: *const FontFace) f32 {
        const upem: f32 = @floatFromInt(self.units_per_em);
        return @as(f32, @floatFromInt(self.os2_win_descent)) / upem;
    }

    /// Map a Unicode codepoint to a glyph id via the best cmap subtable
    /// (format 12 first, then format 4). Null when the font has no glyph.
    /// The id names a glyph of THIS face only — the same number in another
    /// face is a different glyph or none at all.
    pub fn glyphIndex(self: *const FontFace, cp: u21) ?u32 {
        if (self.cmap12) |t| {
            if (cmap12Lookup(t, cp)) |gid| return gid;
        }
        if (self.cmap4) |t| {
            if (cp <= 0xFFFF) {
                if (cmap4Lookup(t, @intCast(cp))) |gid| return gid;
            }
        }
        return null;
    }

    /// True when the font's cmap maps `cp` to a glyph (glyphIndex != null).
    /// The cmap-validation primitive for the math-italic mapping: a mapped
    /// Mathematical-Alphanumeric-Symbols codepoint (U+1D4xx/U+1D6xx) is
    /// only emitted when the font actually carries the glyph.
    pub fn hasGlyph(self: *const FontFace, cp: u21) bool {
        return self.glyphIndex(cp) != null;
    }

    /// The unencoded script-size alternate this face carries for a prime
    /// codepoint, or null for every other codepoint.
    ///
    /// Latin Modern Math — and only that font, identified at parse time by
    /// its exact bytes — keeps four alternates off its cmap: the glyphs it
    /// draws for a script-size run of one to four primes, on the same 0.3em
    /// advance grid as the encoded composites but one step wider each time
    /// (0.489/0.789/1.089/1.389em against 0.311/0.511/0.711/0.911em). The
    /// ids are this font's own, so no other face can answer with them: every
    /// face here, including a system font that maps U+2032 in its cmap, keeps
    /// its own glyph at every size.
    ///
    /// `resolvedGlyphId` applies this at `small_prime_max_size` and below;
    /// a caller that measures a glyph asks for the same resolution so the
    /// width and the outline describe one glyph.
    pub fn smallPrimeGid(self: *const FontFace, cp: u21) ?u32 {
        if (!self.has_script_prime_alternates) return null;
        return switch (cp) {
            0x2032 => script_prime_gids[0],
            0x2033 => script_prime_gids[1],
            0x2034 => script_prime_gids[2],
            0x2057 => script_prime_gids[3],
            else => null,
        };
    }

    /// The MATH table's font-wide constants, or null when the font carries
    /// no MATH table. A borrowed, immutable view of the face's own decoded
    /// value: valid until `deinit`, and the same pointer on every call — a
    /// caller may keep it for as long as it keeps the face.
    pub fn mathConstants(self: *const FontFace) ?*const atom.MathConstants {
        if (self.math == null) return null;
        return &self.math.?.constants;
    }

    /// Minimum overlap a renderer may leave between assembled connector
    /// parts, em units. 0 when the font has no MATH table, which allows
    /// no overlap at all.
    pub fn mathMinConnectorOverlapEm(self: *const FontFace) f32 {
        if (self.math == null) return 0;
        return self.math.?.min_connector_overlap;
    }

    /// The glyph's MATH measurements, em units. Both fields are null when
    /// the font records nothing for the glyph, and on a face whose font
    /// has no MATH table.
    pub fn mathValues(self: *const FontFace, gid: u32) MathGlyphValues {
        if (self.math == null) return .{
            .italic_correction = null,
            .top_accent_attachment = null,
        };
        const m = &self.math.?;
        return .{
            .italic_correction = m.italicsEm(gid),
            .top_accent_attachment = m.topAccentEm(gid),
        };
    }

    /// The glyph's vertical size variants, smallest first and excluding
    /// the base glyph: `variants(gid).?.glyph(0)` is the first size
    /// variant, the glyph to draw for one step of growth. Null when the
    /// font has no MATH table, the glyph has no construction, or its
    /// construction lists no variants. The ladder is a view into the
    /// face's own bytes, valid until `deinit`.
    pub fn variants(self: *const FontFace, gid: u32) ?MathVariants {
        if (self.math == null) return null;
        return self.math.?.verticalVariantsOf(gid);
    }

    /// The glyph's horizontal construction records, smallest first,
    /// including the base glyph when the font declares its stretch measurement.
    /// A glyph can grow along this axis without growing vertically.
    /// `advanceEm` is the
    /// advance measurement along that axis. Null when the font has no MATH
    /// table, the glyph does not grow horizontally, or its construction
    /// lists no variants. A view into the face's own bytes, valid until
    /// `deinit`.
    pub fn horizontalVariants(self: *const FontFace, gid: u32) ?MathVariants {
        if (self.math == null) return null;
        return self.math.?.horizontalVariantsOf(gid);
    }

    /// The glyph's horizontal glyph assembly — the left cap, the repeatable
    /// extender and the right cap a renderer repeats to reach a requested
    /// width. Null when the font has no MATH table or the glyph's
    /// horizontal construction carries no assembly. A view into the face's
    /// own bytes, valid until `deinit`.
    pub fn horizontalAssembly(self: *const FontFace, gid: u32) ?MathAssembly {
        if (self.math == null) return null;
        return self.math.?.horizontalAssemblyOf(gid);
    }

    /// The glyph's vertical glyph assembly, or null when the font has no
    /// MATH table or the glyph's construction carries no assembly. A view
    /// into the face's own bytes, valid until `deinit`. A stretchy
    /// delimiter reads both: `variants` for the rungs it has, `assembly`
    /// for the parts it stacks once it outgrows the last one.
    pub fn assembly(self: *const FontFace, gid: u32) ?MathAssembly {
        if (self.math == null) return null;
        return self.math.?.verticalAssemblyOf(gid);
    }

    /// Horizontal advance for a glyph, em units (hmtx ÷ upem). Glyph ids
    /// past the explicit metric list share the last advance (hmtx
    /// convention); out-of-range ids clamp to the last glyph.
    pub fn advanceEm(self: *const FontFace, gid: u32) f32 {
        const n: u32 = self.num_h_metrics;
        const i: usize = @min(gid, n - 1);
        const adv = std.mem.readInt(u16, self.hmtx[4 * i ..][0..2], .big);
        // f64 intermediate: both values are exact there, and the division
        // result is then narrowed explicitly to the f32 metric.
        const adv_f: f64 = @floatFromInt(adv);
        const upem_f: f64 = @floatFromInt(self.units_per_em);
        return @floatCast(adv_f / upem_f);
    }

    /// Decode one glyph's outline into curves allocated from `gpa`.
    ///
    /// TrueType faces read `loca`/`glyf`; OpenType/CFF faces execute the
    /// glyph's Type 2 charstring against the Subr INDEXes and flatten the
    /// cubics it produces to quadratics. A glyph with no contours — a space,
    /// or a contour count the format does not define — returns an `Outline`
    /// with zero curves, and composite glyphs recurse only as far as
    /// `max_composite_depth`, so a malformed font is refused instead of
    /// running away. Coordinates are raw font units, Y-up; the caller scales
    /// by `size_pt ÷ unitsPerEm`.
    ///
    /// `error.MissingTable` for a face with neither `glyf`/`loca` nor a
    /// `CFF ` table, `error.UnsupportedFont` for a CID-keyed CFF,
    /// `error.InvalidTable` for a `gid` past the last glyph or malformed
    /// outline data, and `error.OutOfMemory` from `gpa`. On any error the
    /// partially built outline is released and nothing is returned, so the
    /// caller owns nothing on that path. On success the caller owns the
    /// `Outline` and releases it with `deinit`.
    pub fn glyphOutline(
        self: *const FontFace,
        gpa: std.mem.Allocator,
        gid: u32,
    ) OutlineError!Outline {
        var out: Outline = .{ .gpa = gpa };
        errdefer out.deinit();
        if (self.is_cff) {
            if (self.cff_cid) return error.UnsupportedFont;
            const cff = self.cff orelse return error.MissingTable;
            if (gid >= self.num_glyphs) return error.InvalidTable;
            const char_string = try cffItem(cff.char_strings, self.data, gid);
            var interp = CffInterp.init(gpa, self.data, cff, &out.curves);
            if (!try interp.run(char_string, false)) return error.InvalidTable;
            return out;
        }
        try self.loadGlyph(gpa, gid, 0, &out.curves);
        return out;
    }

    /// Append the glyf data of `gid` (simple or composite) to `curves`.
    /// `depth` bounds composite recursion so malformed cycles error out
    /// instead of running away.
    fn loadGlyph(
        self: *const FontFace,
        gpa: std.mem.Allocator,
        gid: u32,
        depth: u32,
        curves: *std.ArrayList(QuadCurve),
    ) OutlineError!void {
        if (depth > max_composite_depth) return error.InvalidTable;
        const glyf = self.glyf orelse return error.MissingTable;
        const loca = self.loca orelse return error.MissingTable;
        if (gid >= self.num_glyphs) return error.InvalidTable;
        const start = self.locaOffset(loca, gid) orelse return error.InvalidTable;
        const end = self.locaOffset(loca, gid + 1) orelse return error.InvalidTable;
        if (start > end or end > glyf.len) return error.InvalidTable;
        if (end == start) return; // empty glyph (space etc.): no curves
        const data = glyf[start..end];
        const num_contours = try (Reader{ .data = data }).readI16(0);
        if (num_contours >= 0) return loadSimple(gpa, num_contours, data, curves);
        if (num_contours == -1) return loadComposite(self, gpa, data, depth, curves);
        // numberOfContours < -1 (e.g. -2): degenerate, no curves.
    }

    /// Byte offset of glyph `gid` within the glyf table, from its loca
    /// entry. Short loca stores u16 values × 2; long stores u32 directly.
    /// Null for a malformed format or an out-of-range entry.
    fn locaOffset(self: *const FontFace, loca: []const u8, gid: u32) ?usize {
        const r: Reader = .{ .data = loca };
        return switch (self.index_to_loc_format) {
            0 => blk: {
                const v = r.readU16(2 * gid) catch return null;
                break :blk @as(usize, v) * 2;
            },
            1 => blk: {
                const v = r.readU32(4 * gid) catch return null;
                break :blk v;
            },
            else => null,
        };
    }
};

/// Parse an owned byte blob into a face. `gpa` is stored for `deinit`; pass
/// null when a FontContext arena manages the memory (deinit becomes a no-op).
fn parseOwned(data: []u8, gpa: ?std.mem.Allocator) FontError!FontFace {
    if (data.len < 12) return error.InvalidSfnt;
    const scaler = std.mem.readInt(u32, data[0..4], .big);
    // 0x00010000 = TrueType (glyf), 'OTTO' = OpenType/CFF. Metrics come from
    // the same sfnt tables either way; only the TTF scaler implies glyf
    // outline data (CFF glyphs live in charstrings, out of scope).
    if (scaler != 0x00010000 and scaler != 0x4F54544F) return error.InvalidSfnt;

    const head = try findTable(data, tag("head"));
    const hhea = try findTable(data, tag("hhea"));
    const hmtx = try findTable(data, tag("hmtx"));
    const cmap = try findTable(data, tag("cmap"));
    const maxp = try findTable(data, tag("maxp"));
    const os2 = findTable(data, tag("OS/2")) catch null;
    // Outline tables: either glyf/loca (TrueType) or `CFF ` (OpenType/CFF).
    // Metrics parse identically either way; glyphOutline dispatches on the
    // scaler.
    const loca = findTable(data, tag("loca")) catch null;
    const glyf = findTable(data, tag("glyf")) catch null;
    const cff = findTable(data, tag("CFF ")) catch null;
    // Math layout data; a font without it still parses and reports none.
    const math = findTable(data, tag("MATH")) catch null;

    const hr: Reader = .{ .data = data[head.offset..][0..head.length] };
    const units_per_em = try hr.readU16(18);
    if (units_per_em == 0) return error.InvalidTable;

    const hhr: Reader = .{ .data = data[hhea.offset..][0..hhea.length] };
    const num_h_metrics = try hhr.readU16(34);
    if (num_h_metrics == 0) return error.InvalidTable;
    if (hmtx.length < 4 * num_h_metrics) return error.InvalidTable;

    const mr: Reader = .{ .data = data[maxp.offset..][0..maxp.length] };
    const num_glyphs = try mr.readU16(4);

    var face: FontFace = .{
        .gpa = gpa,
        .data = data,
        .units_per_em = units_per_em,
        .num_glyphs = num_glyphs,
        .hhea_ascender = try hhr.readI16(4),
        .hhea_descender = try hhr.readI16(6),
        .hhea_line_gap = try hhr.readI16(8),
        .num_h_metrics = num_h_metrics,
        .os2_typo_ascender = 0,
        .os2_typo_descender = 0,
        .os2_typo_line_gap = 0,
        .os2_win_ascent = 0,
        .os2_win_descent = 0,
        .has_script_prime_alternates = isBundledMathFace(data),
        .hmtx = data[hmtx.offset..][0..hmtx.length],
        .cmap4 = null,
        .cmap12 = null,
        .loca = if (loca) |l| data[l.offset..][0..l.length] else null,
        .glyf = if (glyf) |g| data[g.offset..][0..g.length] else null,
        .index_to_loc_format = hr.readI16(50) catch 0,
        .cff = null,
        .is_cff = scaler == 0x4F54544F,
        .cff_cid = false,
        .math = null,
    };
    if (cff) |c| {
        var cff_data: CffData = .{
            .char_strings = undefined,
            .gsubrs = undefined,
            .lsubrs = null,
            .gsubr_bias = 107,
            .lsubr_bias = 107,
        };
        face.cff_cid = try parseCffData(data, c, &cff_data);
        face.cff = cff_data;
    }
    if (os2) |o| {
        const or_: Reader = .{ .data = data[o.offset..][0..o.length] };
        // Fields exist from OS/2 version 0; read with defaults on any
        // malformed/truncated table.
        face.os2_typo_ascender = or_.readI16(68) catch 0;
        face.os2_typo_descender = or_.readI16(70) catch 0;
        face.os2_typo_line_gap = or_.readI16(72) catch 0;
        face.os2_win_ascent = or_.readU16(74) catch 0;
        face.os2_win_descent = or_.readU16(76) catch 0;
    }
    try selectCmap(&face, data[cmap.offset..][0..cmap.length]);
    if (math) |m| face.math = try parseMath(data[m.offset..][0..m.length], units_per_em);
    return face;
}

/// True when `data` is the embedded Latin Modern Math file itself, which is
/// the only face that carries the unencoded script-size prime alternates
/// `script_prime_gids` names. Any font of another length is answered without
/// touching its bytes, and a same-length font still has to match every byte:
/// an id is only meaningful in the face that defines it, so a font that
/// merely resembles LM Math (or is a re-save of it) keeps its own glyphs for
/// a prime. Run once per parse, never on a lookup.
fn isBundledMathFace(data: []const u8) bool {
    const bundled = lmmath.lmmath_otf[0..];
    return data.len == bundled.len and std.mem.eql(u8, data, bundled);
}

/// MathValueRecords in a MathConstants table, in spec order.
const math_value_record_count = 51;
/// Byte length of a MathConstants table: two percent int16s, two uint16
/// minimums, the MathValueRecords, then the radical degree raise percent.
const math_constants_len = 8 + 4 * math_value_record_count + 2;
/// Byte length of a MathVariants header: the minimum connector overlap,
/// the vertical and horizontal coverage offsets, and both glyph counts.
const math_variants_header_len = 10;
/// Header field offsets. The two coverage offsets come before the two
/// glyph counts in this format (see `parseMathVariants`).
const math_variants_vert_cov_off = 2;
const math_variants_horiz_cov_off = 4;
const math_variants_vert_count_off = 6;
const math_variants_horiz_count_off = 8;

/// The `index`th MathValueRecord of a MathConstants block, in em units.
fn mathConstant(r: Reader, block: usize, index: usize, upem: u16) error{InvalidTable}!f32 {
    return emValue(try r.readI16(block + 4 * index), upem);
}

/// Parse the MATH table into views of its own bytes. Reads the header
/// (version 1.0, then the offsets of MathConstants, MathGlyphInfo, and
/// MathVariants), decodes the constants, and checks every structure a
/// lookup can reach — coverage tables, value lists, constructions, and
/// assemblies — so a lookup can slice the bytes without re-validating
/// them. A truncated, foreign, or later-version table reports
/// error.InvalidTable, the failure every other malformed table gives. A
/// font with no MATH table never reaches here.
fn parseMath(table: []const u8, upem: u16) error{InvalidTable}!MathData {
    const r: Reader = .{ .data = table };
    if (try r.readU16(0) != 1) return error.InvalidTable;
    const c_off = try r.readU16(4);
    const gi_off = try r.readU16(6);
    const v_off = try r.readU16(8);
    if (c_off == 0 or gi_off == 0 or v_off == 0) return error.InvalidTable;
    if (c_off > table.len or gi_off > table.len or v_off > table.len) {
        return error.InvalidTable;
    }
    return .{
        .table = table,
        .units_per_em = upem,
        .constants = try parseMathConstants(table, c_off, upem),
        .min_connector_overlap = emValue(try r.readU16(v_off), upem),
        .italics = try parseMathValueList(table, gi_off, try r.readU16(gi_off)),
        .top_accent = try parseMathValueList(table, gi_off, try r.readU16(gi_off + 2)),
        .variants = try parseMathVariants(table, v_off),
    };
}

/// Decode MathConstants. The block opens with the two script scale-down
/// percents and the two uint16 formula minimums, then one
/// MathValueRecord per field (a design value plus a device-table offset
/// that is ignored), then the radical degree raise percent. The indices
/// below count those records in spec order.
fn parseMathConstants(table: []const u8, off: usize, upem: u16) error{InvalidTable}!MathConstants {
    if (off + math_constants_len > table.len) return error.InvalidTable;
    const r: Reader = .{ .data = table };
    const rec = off + 8;
    return .{
        .script_percent_scale_down = mathRatio(try r.readI16(off)),
        .script_script_percent_scale_down = mathRatio(try r.readI16(off + 2)),
        .delimited_sub_formula_min_height = emValue(try r.readU16(off + 4), upem),
        .display_operator_min_height = emValue(try r.readU16(off + 6), upem),
        .math_leading = try mathConstant(r, rec, 0, upem),
        .axis_height = try mathConstant(r, rec, 1, upem),
        .accent_base_height = try mathConstant(r, rec, 2, upem),
        .flattened_accent_base_height = try mathConstant(r, rec, 3, upem),
        .subscript_shift_down = try mathConstant(r, rec, 4, upem),
        .subscript_top_max = try mathConstant(r, rec, 5, upem),
        .subscript_baseline_drop_min = try mathConstant(r, rec, 6, upem),
        .superscript_shift_up = try mathConstant(r, rec, 7, upem),
        .superscript_shift_up_cramped = try mathConstant(r, rec, 8, upem),
        .superscript_bottom_min = try mathConstant(r, rec, 9, upem),
        .superscript_baseline_drop_max = try mathConstant(r, rec, 10, upem),
        .sub_superscript_gap_min = try mathConstant(r, rec, 11, upem),
        .superscript_bottom_max_with_subscript = try mathConstant(r, rec, 12, upem),
        .space_after_script = try mathConstant(r, rec, 13, upem),
        .upper_limit_gap_min = try mathConstant(r, rec, 14, upem),
        .upper_limit_baseline_rise_min = try mathConstant(r, rec, 15, upem),
        .lower_limit_gap_min = try mathConstant(r, rec, 16, upem),
        .lower_limit_baseline_drop_min = try mathConstant(r, rec, 17, upem),
        .stack_top_shift_up = try mathConstant(r, rec, 18, upem),
        .stack_top_display_style_shift_up = try mathConstant(r, rec, 19, upem),
        .stack_bottom_shift_down = try mathConstant(r, rec, 20, upem),
        .stack_bottom_display_style_shift_down = try mathConstant(r, rec, 21, upem),
        .stack_gap_min = try mathConstant(r, rec, 22, upem),
        .stack_display_style_gap_min = try mathConstant(r, rec, 23, upem),
        .stretch_stack_top_shift_up = try mathConstant(r, rec, 24, upem),
        .stretch_stack_bottom_shift_down = try mathConstant(r, rec, 25, upem),
        .stretch_stack_gap_above_min = try mathConstant(r, rec, 26, upem),
        .stretch_stack_gap_below_min = try mathConstant(r, rec, 27, upem),
        .fraction_numerator_shift_up = try mathConstant(r, rec, 28, upem),
        .fraction_numerator_display_style_shift_up = try mathConstant(r, rec, 29, upem),
        .fraction_denominator_shift_down = try mathConstant(r, rec, 30, upem),
        .fraction_denominator_display_style_shift_down = try mathConstant(r, rec, 31, upem),
        .fraction_numerator_gap_min = try mathConstant(r, rec, 32, upem),
        .fraction_num_display_style_gap_min = try mathConstant(r, rec, 33, upem),
        .fraction_rule_thickness = try mathConstant(r, rec, 34, upem),
        .fraction_denominator_gap_min = try mathConstant(r, rec, 35, upem),
        .fraction_denom_display_style_gap_min = try mathConstant(r, rec, 36, upem),
        .skewed_fraction_horizontal_gap = try mathConstant(r, rec, 37, upem),
        .skewed_fraction_vertical_gap = try mathConstant(r, rec, 38, upem),
        .overbar_vertical_gap = try mathConstant(r, rec, 39, upem),
        .overbar_rule_thickness = try mathConstant(r, rec, 40, upem),
        .overbar_extra_ascender = try mathConstant(r, rec, 41, upem),
        .underbar_vertical_gap = try mathConstant(r, rec, 42, upem),
        .underbar_rule_thickness = try mathConstant(r, rec, 43, upem),
        .underbar_extra_descender = try mathConstant(r, rec, 44, upem),
        .radical_vertical_gap = try mathConstant(r, rec, 45, upem),
        .radical_display_style_vertical_gap = try mathConstant(r, rec, 46, upem),
        .radical_rule_thickness = try mathConstant(r, rec, 47, upem),
        .radical_extra_ascender = try mathConstant(r, rec, 48, upem),
        .radical_kern_before_degree = try mathConstant(r, rec, 49, upem),
        .radical_kern_after_degree = try mathConstant(r, rec, 50, upem),
        .radical_degree_bottom_raise_percent = mathRatio(
            try r.readU16(rec + 4 * math_value_record_count),
        ),
    };
}

/// Parse a MathItalicsCorrectionInfo or MathTopAccentAttachment table: a
/// coverage offset, a record count, then that many MathValueRecords.
/// `base` is the MathGlyphInfo offset the table's own offset is relative
/// to; a zero offset (an absent table) yields null.
fn parseMathValueList(
    table: []const u8,
    base: usize,
    off: u16,
) error{InvalidTable}!?MathValueList {
    if (off == 0) return null;
    const r: Reader = .{ .data = table };
    const start = base + off;
    const cov_off = try r.readU16(start);
    const count = try r.readU16(start + 2);
    if (cov_off == 0) return error.InvalidTable;
    const records = start + 4;
    if (records + 4 * count > table.len) return error.InvalidTable;
    return .{
        .coverage = .{ .table = try coverageTable(table, start + cov_off) },
        .records = table[records..][0 .. 4 * count],
    };
}

/// Parse one construction index of a MathVariants table: the coverage of the
/// glyphs that grow along that axis and the construction offset array, one
/// entry per covered glyph, each construction checked in full. `cov_field`
/// and `count_field` are the header fields holding this half's coverage
/// offset and glyph count; `list_at` is where this half's offset array
/// starts, which for the horizontal half follows the vertical one.
///
/// Either axis is optional: the format leaves the coverage offset NULL when
/// that axis carries no glyphs, so a NULL offset with a zero glyph count is
/// an absent half (null) and only a NULL offset that still claims glyphs,
/// or a coverage whose own count contradicts the header's, is malformed.
fn parseVariantHalf(
    table: []const u8,
    off: usize,
    cov_field: usize,
    count_field: usize,
    list_at: usize,
) error{InvalidTable}!?MathVariantIndex {
    const r: Reader = .{ .data = table };
    const cov_off = try r.readU16(off + cov_field);
    const count = try r.readU16(off + count_field);
    if (cov_off == 0) {
        if (count != 0) return error.InvalidTable;
        return null;
    }
    const coverage: MathCoverage = .{ .table = try coverageTable(table, off + cov_off) };
    // One construction per covered glyph; a mismatch would index the
    // array past the glyphs it describes.
    if (coverage.count() != count) return error.InvalidTable;
    if (list_at + 2 * count > table.len) return error.InvalidTable;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const rel = try r.readU16(list_at + 2 * i);
        if (rel == 0) return error.InvalidTable;
        try checkConstruction(table, off + rel);
    }
    return .{
        .base = off,
        .coverage = coverage,
        .offsets = table[list_at..][0 .. 2 * count],
    };
}

/// Parse both halves of a MathVariants table: the vertical constructions
/// (fences, radicals, big operators) and the horizontal ones (wide bars,
/// extensible arrows and signs), so a renderer grows a glyph along either
/// axis from the font's own designs instead of stretching one shape.
/// The header carries the two coverage offsets first and the two glyph
/// counts after them — measured from the real face, and confirmed by each
/// coverage's own glyph count matching the count read beside it.
/// An axis the face grows nothing along yields a null half, leaving the other
/// axis — and the rest of the MATH table — intact.
fn parseMathVariants(table: []const u8, off: usize) error{InvalidTable}!MathVariantHalves {
    const r: Reader = .{ .data = table };
    if (off + math_variants_header_len > table.len) return error.InvalidTable;
    const vert_count = try r.readU16(off + math_variants_vert_count_off);
    const list = off + math_variants_header_len;
    if (list + 2 * vert_count > table.len) return error.InvalidTable;
    return .{
        .vert = try parseVariantHalf(
            table,
            off,
            math_variants_vert_cov_off,
            math_variants_vert_count_off,
            list,
        ),
        .horiz = try parseVariantHalf(
            table,
            off,
            math_variants_horiz_cov_off,
            math_variants_horiz_count_off,
            list + 2 * vert_count,
        ),
    };
}

/// Bounds-check one MathGlyphConstruction: the glyph-assembly offset, the
/// variant count with its records, then the assembly's italic correction,
/// part count, and parts.
fn checkConstruction(table: []const u8, at: usize) error{InvalidTable}!void {
    const r: Reader = .{ .data = table };
    const assembly = try r.readU16(at);
    const variants = try r.readU16(at + 2);
    if (at + 4 + 4 * variants > table.len) return error.InvalidTable;
    if (assembly == 0) return;
    const a = at + assembly;
    const parts = try r.readU16(a + 4);
    if (a + 6 + 10 * parts > table.len) return error.InvalidTable;
}

/// The coverage table at `off` — format, count, then the glyph array
/// (format 1) or the range array (format 2) — as a bounds-checked slice.
fn coverageTable(table: []const u8, off: usize) error{InvalidTable}![]const u8 {
    const r: Reader = .{ .data = table };
    const format = try r.readU16(off);
    const count = try r.readU16(off + 2);
    const len: usize = switch (format) {
        1 => 4 + 2 * count,
        2 => 4 + 6 * count,
        else => return error.InvalidTable,
    };
    if (off + len > table.len) return error.InvalidTable;
    return table[off..][0..len];
}

/// Composite recursion cap; malformed component cycles error out instead of
/// recursing forever.
const max_composite_depth = 4;

/// A decoded point of a simple glyph (font units, Y-up).
const GlyphPoint = struct {
    x: f32,
    y: f32,
    on_curve: bool,
};

/// A signed F2Dot14 fixed-point value (OpenType composite scales).
fn f2dot14(v: i16) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

fn xy(p: GlyphPoint) [2]f32 {
    return .{ p.x, p.y };
}

fn midPoint(a: [2]f32, b: [2]f32) [2]f32 {
    return .{ 0.5 * (a[0] + b[0]), 0.5 * (a[1] + b[1]) };
}

/// Apply a composite component transform: translate (dx, dy) after the
/// optional scale/shear (identity factors when no scale flags were set).
/// The offset is unscaled, per the spec.
fn transformPoint(p: [2]f32, dx: i32, dy: i32, sx: f32, sy: f32, s01: f32, s10: f32) [2]f32 {
    const dxf: f32 = @floatFromInt(dx);
    const dyf: f32 = @floatFromInt(dy);
    return .{ sx * p[0] + s01 * p[1] + dxf, s10 * p[0] + sy * p[1] + dyf };
}

/// Decode a simple glyph (numberOfContours >= 0): endPtsOfContours,
/// instructions (skipped), flags with optional repeats, x/y deltas; then
/// decompose each contour into quadratic segments appended to `curves`.
/// Every read is bounds-checked; trailing padding is ignored.
fn loadSimple(
    gpa: std.mem.Allocator,
    num_contours: i16,
    data: []const u8,
    curves: *std.ArrayList(QuadCurve),
) error{ OutOfMemory, InvalidTable }!void {
    const r: Reader = .{ .data = data };
    const n_contours: usize = @intCast(num_contours);
    var pos: usize = 10; // numberOfContours + 8-byte bounding box

    // endPtsOfContours: strictly increasing, last entry = point count - 1.
    const ends = try gpa.alloc(u32, n_contours);
    defer gpa.free(ends);
    var prev_end: i32 = -1;
    var i: usize = 0;
    while (i < n_contours) : (i += 1) {
        const e = try r.readU16(pos);
        pos += 2;
        if (@as(i32, e) <= prev_end) return error.InvalidTable;
        ends[i] = e;
        prev_end = @as(i32, e);
    }
    const n_points: usize = @as(usize, @intCast(prev_end)) + 1;

    const inst_len = try r.readU16(pos);
    pos += 2;
    if (pos + inst_len > data.len) return error.InvalidTable;
    pos += inst_len;

    // Flags; a repeat bit (0x08) extends the current flag to `n` more points.
    const flags = try gpa.alloc(u8, n_points);
    defer gpa.free(flags);
    var n: usize = 0;
    while (n < n_points) {
        const f = try r.readU8(pos);
        pos += 1;
        flags[n] = f;
        n += 1;
        if (f & 0x08 != 0) {
            const rep = try r.readU8(pos);
            pos += 1;
            if (rep > n_points - n) return error.InvalidTable;
            var j: usize = 0;
            while (j < rep) : (j += 1) {
                flags[n] = f;
                n += 1;
            }
        }
    }

    // x deltas, then y deltas (accumulated; saturated adds keep absurd
    // deltas from overflowing the i32 accumulator).
    const points = try gpa.alloc(GlyphPoint, n_points);
    defer gpa.free(points);
    var x: i32 = 0;
    n = 0;
    while (n < n_points) : (n += 1) {
        const f = flags[n];
        if (f & 0x02 != 0) { // x-short: 1 byte, positive when 0x10 set
            const v = try r.readU8(pos);
            pos += 1;
            x +|= if (f & 0x10 != 0) @as(i32, v) else -@as(i32, v);
        } else if (f & 0x10 == 0) { // x-same clear: signed 16-bit delta
            x +|= try r.readI16(pos);
            pos += 2;
        }
        points[n].x = @floatFromInt(x);
        points[n].on_curve = f & 0x01 != 0;
    }
    var y: i32 = 0;
    n = 0;
    while (n < n_points) : (n += 1) {
        const f = flags[n];
        if (f & 0x04 != 0) { // y-short: 1 byte, positive when 0x20 set
            const v = try r.readU8(pos);
            pos += 1;
            y +|= if (f & 0x20 != 0) @as(i32, v) else -@as(i32, v);
        } else if (f & 0x20 == 0) { // y-same clear: signed 16-bit delta
            y +|= try r.readI16(pos);
            pos += 2;
        }
        points[n].y = @floatFromInt(y);
    }

    var c_start: usize = 0;
    i = 0;
    while (i < n_contours) : (i += 1) {
        const c_end: usize = ends[i];
        try appendContour(gpa, curves, points[c_start .. c_end + 1]);
        c_start = c_end + 1;
    }
}

/// Decompose one closed contour into quadratic segments (the standard
/// TrueType rule): consecutive on-curve points join by a line (control =
/// midpoint); a lone off-curve point between on-curve positions is the
/// control; consecutive off-curve points imply an on-curve midpoint
/// between them; the contour closes back to its first point. A contour of
/// exactly one point is degenerate (nothing emitted); two points = a line.
fn appendContour(
    gpa: std.mem.Allocator,
    curves: *std.ArrayList(QuadCurve),
    pts: []const GlyphPoint,
) std.mem.Allocator.Error!void {
    const n = pts.len;
    if (n <= 1) return;
    if (n == 2) {
        try curves.append(gpa, .{
            .p0 = xy(pts[0]),
            .p1 = midPoint(xy(pts[0]), xy(pts[1])),
            .p2 = xy(pts[1]),
        });
        return;
    }
    if (n > 0) {
        var start: usize = 0;
        var any_on = false;
        for (pts, 0..) |p, idx| {
            if (p.on_curve) {
                start = idx;
                any_on = true;
                break;
            }
        }
        // Current on-curve position plus the pending off-curve control (at
        // most one: the second of two consecutive off-curves immediately emits
        // their implied midpoint). With no on-curve point at all, the contour
        // starts at the implied midpoint of the last and first points, with the
        // first point pending as the control.
        var cur: [2]f32 = if (any_on) xy(pts[start]) else midPoint(xy(pts[n - 1]), xy(pts[0]));
        var ctrl: ?[2]f32 = if (any_on) null else xy(pts[0]);
        var idx = (start + 1) % n;
        while (true) {
            const p = xy(pts[idx]);
            if (pts[idx].on_curve) {
                if (ctrl) |c| {
                    try curves.append(gpa, .{ .p0 = cur, .p1 = c, .p2 = p });
                } else {
                    try curves.append(gpa, .{ .p0 = cur, .p1 = midPoint(cur, p), .p2 = p });
                }
                cur = p;
                ctrl = null;
            } else {
                if (ctrl) |c| {
                    const mid = midPoint(c, p);
                    try curves.append(gpa, .{ .p0 = cur, .p1 = c, .p2 = mid });
                    cur = mid;
                }
                ctrl = p;
            }
            if (idx == start) break;
            idx = (idx + 1) % n;
        }
    }
}

/// Decode a composite glyph (numberOfContours == -1): component records
/// each naming a glyph plus a transform (word/byte args, optional scale).
/// Component outlines load recursively and append transformed. Point-index
/// args (no ARGS_ARE_XY_VALUES) are used as raw offsets — true point
/// matching needs the parent's accumulated points and is not implemented.
fn loadComposite(
    self: *const FontFace,
    gpa: std.mem.Allocator,
    data: []const u8,
    depth: u32,
    curves: *std.ArrayList(QuadCurve),
) OutlineError!void {
    const r: Reader = .{ .data = data };
    var pos: usize = 10;
    var comp: Outline = .{ .gpa = gpa };
    defer comp.deinit();
    while (true) {
        const flags = try r.readU16(pos);
        pos += 2;
        const comp_gid = try r.readU16(pos);
        pos += 2;

        var dx: i32 = 0;
        var dy: i32 = 0;
        if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS: signed i16
            dx = try r.readI16(pos);
            dy = try r.readI16(pos + 2);
            pos += 4;
        } else { // 1-byte args (unsigned, per the spec)
            dx = try r.readU8(pos);
            dy = try r.readU8(pos + 1);
            pos += 2;
        }

        var sx: f32 = 1;
        var sy: f32 = 1;
        var s01: f32 = 0;
        var s10: f32 = 0;
        if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE: uniform
            sx = f2dot14(try r.readI16(pos));
            sy = sx;
            pos += 2;
        } else if (flags & 0x0040 != 0) { // WE_HAVE_AN_X_AND_Y_SCALE
            sx = f2dot14(try r.readI16(pos));
            sy = f2dot14(try r.readI16(pos + 2));
            pos += 4;
        } else if (flags & 0x0080 != 0) { // WE_HAVE_A_TWO_BY_TWO
            sx = f2dot14(try r.readI16(pos));
            s01 = f2dot14(try r.readI16(pos + 2));
            s10 = f2dot14(try r.readI16(pos + 4));
            sy = f2dot14(try r.readI16(pos + 6));
            pos += 8;
        }

        // Component outline, transformed into the parent.
        try self.loadGlyph(gpa, comp_gid, depth + 1, &comp.curves);
        const src_curves = comp.curves.items;
        for (src_curves) |c| {
            try curves.append(gpa, .{
                .p0 = transformPoint(c.p0, dx, dy, sx, sy, s01, s10),
                .p1 = transformPoint(c.p1, dx, dy, sx, sy, s01, s10),
                .p2 = transformPoint(c.p2, dx, dy, sx, sy, s01, s10),
            });
        }
        comp.curves.clearRetainingCapacity();

        // MORE_COMPONENTS is spec bit 5 (0x0020); 0x0200 is USE_MY_METRICS,
        // a real flag some fonts set that must NOT chain.
        if (flags & 0x0020 == 0) break;
    }
}

// ── CFF (Type 2 charstring) outline decoding ────────────
// The embedded Latin Modern faces are OpenType/CFF: `OTTO` scaler, a `CFF `
// table, no glyf/loca. CFF glyphs are Type 2 charstrings (Adobe TN 5177)
// executed against the local/global Subr INDEXes. Executed segments are
// flattened to quadratics here — cubics split at t = 0.5 into two
// midpoint-exact quads, lines as midpoint quads — matching the glyf
// decoder's output shape. Semantics follow FreeType's cf2 interpreter
// (src/psaux/psintrp.c); the operand counts and curve geometry were
// verified against fontTools on every glyph of the three embedded faces.

/// Type 2 limits (spec Appendix B): operand stack depth and subr nesting.
const cff_stack_limit = 48;
const max_subr_depth = 10;

/// A parsed CFF INDEX (count, offSize, offsets array, data). Positions are
/// absolute into the font's data; items are located via 1-based offsets.
const CffIndex = struct {
    count: u16,
    off_size: u8,
    /// Absolute offset of the offsets array (count + 1 entries).
    offsets_start: usize,
    /// Absolute offset of the data section.
    data_start: usize,
    /// Absolute offset of the first byte after this INDEX.
    next: usize,
};

/// Read an offSize-byte big-endian offset at `pos` (INDEX offsets).
fn readCffOffset(data: []const u8, pos: usize, off_size: u8) error{InvalidTable}!u32 {
    if (pos + off_size > data.len) return error.InvalidTable;
    var v: u32 = 0;
    var i: u8 = 0;
    while (i < off_size) : (i += 1) v = (v << 8) | data[pos + i];
    return v;
}

/// Parse an INDEX at `pos`; positions are absolute into `data`.
fn parseCffIndex(data: []const u8, pos: usize) error{InvalidTable}!CffIndex {
    const r: Reader = .{ .data = data };
    const count = try r.readU16(pos);
    if (count == 0) {
        // Empty INDEX: no offsets, no data.
        return .{
            .count = 0,
            .off_size = 0,
            .offsets_start = pos + 2,
            .data_start = pos + 2,
            .next = pos + 2,
        };
    }
    const off_size = try r.readU8(pos + 2);
    if (off_size < 1 or off_size > 4) return error.InvalidTable;
    const offsets_start = pos + 3;
    const data_start = offsets_start + (@as(usize, count) + 1) * off_size;
    const last = try readCffOffset(data, offsets_start + @as(usize, count) * off_size, off_size);
    if (last < 1 or data_start + last - 1 > data.len) return error.InvalidTable;
    return .{
        .count = count,
        .off_size = off_size,
        .offsets_start = offsets_start,
        .data_start = data_start,
        .next = data_start + last - 1,
    };
}

/// Item `i` of an INDEX as a slice into `data`.
fn cffItem(self: CffIndex, data: []const u8, i: usize) error{InvalidTable}![]const u8 {
    if (i >= self.count) return error.InvalidTable;
    const o0 = try readCffOffset(data, self.offsets_start + i * self.off_size, self.off_size);
    const o1 = try readCffOffset(data, self.offsets_start + (i + 1) * self.off_size, self.off_size);
    if (o0 < 1 or o1 < o0) return error.InvalidTable;
    const start = self.data_start + o0 - 1;
    const end = self.data_start + o1 - 1;
    if (end > data.len) return error.InvalidTable;
    return data[start..end];
}

/// Number operand encodings: DICTs use the longint (29) form, charstrings
/// the 16.16 fixed (255) form instead.
const CffNumberFormat = enum { dict, charstring };

/// Decode one CFF number operand at `pos` (advancing it). Operator byte
/// values are rejected — this decodes numbers only.
fn readCffNumber(data: []const u8, pos: *usize, format: CffNumberFormat) error{InvalidTable}!f32 {
    const r: Reader = .{ .data = data };
    const b0 = try r.readU8(pos.*);
    if (b0 <= 27) return error.InvalidTable;
    if (b0 == 28) {
        const v = try r.readI16(pos.* + 1);
        pos.* += 3;
        return @floatFromInt(v);
    }
    if (b0 == 29) { // longint (DICT only)
        if (format != .dict) return error.InvalidTable;
        const v = try r.readI32(pos.* + 1);
        pos.* += 5;
        return @floatFromInt(v);
    }
    if (b0 == 30) { // real number (DICT only): nibble-encoded, 0xF ends
        if (format != .dict) return error.InvalidTable;
        var value: f64 = 0;
        var frac_scale: f64 = 1;
        var frac = false;
        var neg = false;
        var exp_active = false;
        var exp_neg = false;
        var exp_val: i32 = 0;
        var bpos = pos.* + 1;
        var ended = false;
        while (!ended) {
            const b = try r.readU8(bpos);
            bpos += 1;
            const hi = b >> 4;
            const lo = b & 0x0F;
            var n: u8 = 0;
            while (n < 2) : (n += 1) {
                const nib = if (n == 0) hi else lo;
                switch (nib) {
                    0...9 => {
                        if (exp_active) {
                            exp_val = exp_val * 10 + @as(i32, nib);
                        } else if (frac) {
                            frac_scale *= 0.1;
                            value += @as(f64, nib) * frac_scale;
                        } else {
                            value = value * 10.0 + @as(f64, nib);
                        }
                    },
                    0xA => frac = true,
                    0xB => { // 'E'
                        exp_active = true;
                        exp_neg = false;
                    },
                    0xC => { // 'E-'
                        exp_active = true;
                        exp_neg = true;
                    },
                    0xE => neg = true,
                    0xF => {
                        ended = true;
                        break;
                    },
                    else => return error.InvalidTable, // 'D' is reserved
                }
            }
        }
        pos.* = bpos;
        const mantissa = if (neg) -value else value;
        const exp = if (exp_neg)
            -@as(f64, @floatFromInt(exp_val))
        else
            @as(f64, @floatFromInt(exp_val));
        return @floatCast(mantissa * std.math.pow(f64, 10.0, exp));
    }
    if (b0 == 31) return error.InvalidTable; // reserved
    if (b0 == 255) { // 16.16 fixed (charstrings only)
        if (format != .charstring) return error.InvalidTable;
        const hi = try r.readI16(pos.* + 1);
        const lo = try r.readU16(pos.* + 3);
        pos.* += 5;
        return @floatCast(@as(f64, @floatFromInt((@as(i32, hi) << 16) | @as(i32, lo))) / 65536.0);
    }
    if (b0 <= 246) { // 32..246: v = b - 139
        pos.* += 1;
        return @as(f32, @floatCast(@as(f64, @floatFromInt(b0)) - 139.0));
    }
    const b1 = try r.readU8(pos.* + 1);
    pos.* += 2;
    if (b0 <= 250) { // 247..250: (b - 247) * 256 + b1 + 108
        return @as(f32, @floatCast(
            @as(f64, @floatFromInt(@as(i32, b0) - 247)) * 256.0 +
                @as(f64, @floatFromInt(b1)) + 108.0,
        ));
    }
    // 251..254: -(b - 251) * 256 - b1 - 108
    return @as(f32, @floatCast(
        -@as(f64, @floatFromInt(@as(i32, b0) - 251)) * 256.0 -
            @as(f64, @floatFromInt(b1)) - 108.0,
    ));
}

/// Which DICT an operator belongs to (opcodes overlap: 0x11 is CharStrings
/// in the Top DICT but 0x13 is Subrs in the Private DICT).
const CffDictKind = enum { top, private };

/// Operand values collected from a Top/Private DICT (DICT numbers are
/// integral; the offsets are absolute CFF-table positions).
const CffDict = struct {
    char_strings: ?usize = null, // Top 0x11
    private_size: ?usize = null, // Top 0x12 (first operand)
    private_off: ?usize = null, // Top 0x12 (second operand)
    is_cid: bool = false, // Top 0x15 (ROS)
    subrs_off: ?usize = null, // Private 0x13
};

/// A CFF DICT integer operand (a non-negative offset/count) converted to
/// usize, clamped so @intFromFloat cannot trap on a corrupt operand.
fn cffInt(x: f32) usize {
    return @intFromFloat(@min(@max(x, 0), @as(f64, @floatFromInt(std.math.maxInt(u32)))));
}

/// Walk a DICT: operands accumulate on a fixed stack; each operator
/// consumes them. Only the operators we need are recorded.
fn parseCffDict(dict: []const u8, kind: CffDictKind, out: *CffDict) error{InvalidTable}!void {
    var ops: [cff_stack_limit]f32 = undefined;
    var n_ops: usize = 0;
    var i: usize = 0;
    while (i < dict.len) {
        const b = dict[i];
        if (b == 12) { // escape operator: none carry operands we need
            i += 1;
            if (i >= dict.len) return error.InvalidTable;
            i += 1;
            n_ops = 0;
        } else if (b <= 21) {
            switch (kind) {
                .top => switch (b) {
                    0x11 => {
                        if (n_ops < 1) return error.InvalidTable;
                        out.char_strings = cffInt(ops[n_ops - 1]);
                    },
                    0x12 => {
                        if (n_ops < 2) return error.InvalidTable;
                        out.private_size = cffInt(ops[n_ops - 2]);
                        out.private_off = cffInt(ops[n_ops - 1]);
                    },
                    0x15 => out.is_cid = true,
                    else => {},
                },
                .private => switch (b) {
                    0x13 => {
                        if (n_ops < 1) return error.InvalidTable;
                        out.subrs_off = cffInt(ops[n_ops - 1]);
                    },
                    else => {},
                },
            }
            n_ops = 0;
            i += 1;
        } else {
            if (n_ops >= ops.len) return error.InvalidTable;
            ops[n_ops] = try readCffNumber(dict, &i, .dict);
            n_ops += 1;
        }
    }
}

/// Parsed CFF font structure (non-CID layout), positions into the face's
/// data. `lsubrs` is absent when the Private DICT declares no Subrs.
const CffData = struct {
    char_strings: CffIndex,
    gsubrs: CffIndex,
    lsubrs: ?CffIndex,
    gsubr_bias: i32,
    lsubr_bias: i32,
};

/// Subroutine bias from the subr count (Type 2 spec §4.7).
fn cffSubrBias(count: u16) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

/// Parse the CFF structure: header, Name/Top DICT/String INDEXes, Global
/// Subrs, then the objects the Top DICT points at (CharStrings INDEX,
/// Private DICT with optional local Subrs). Returns whether the Top DICT
/// declares ROS (CID-keyed — outline decoding is then unsupported).
fn parseCffData(data: []const u8, table: TableLoc, out: *CffData) error{InvalidTable}!bool {
    const base = table.offset;
    const r: Reader = .{ .data = data };
    const hdr_size = try r.readU8(base + 2);
    if (hdr_size < 4 or base + hdr_size > data.len) return error.InvalidTable;
    var pos = base + hdr_size;
    const name_idx = try parseCffIndex(data, pos); // Name INDEX: skipped
    pos = name_idx.next;
    const top_idx = try parseCffIndex(data, pos); // Top DICT INDEX
    pos = top_idx.next;
    if (top_idx.count != 1) return error.InvalidTable; // non-CID: one dict
    const top_dict = try cffItem(top_idx, data, 0);
    var dict: CffDict = .{};
    try parseCffDict(top_dict, .top, &dict);
    const cs_off = dict.char_strings orelse return error.InvalidTable;
    if (base + cs_off > data.len) return error.InvalidTable;
    out.char_strings = try parseCffIndex(data, base + cs_off);
    const string_idx = try parseCffIndex(data, pos); // String INDEX: skipped
    out.gsubrs = try parseCffIndex(data, string_idx.next);
    out.gsubr_bias = cffSubrBias(out.gsubrs.count);
    out.lsubrs = null;
    out.lsubr_bias = 107;
    if (dict.private_off) |p_off| {
        const p_size = dict.private_size orelse return error.InvalidTable;
        if (base + p_off + p_size > data.len) return error.InvalidTable;
        const priv_dict = data[base + p_off .. base + p_off + p_size];
        var pd: CffDict = .{};
        try parseCffDict(priv_dict, .private, &pd);
        if (pd.subrs_off) |s_off| {
            out.lsubrs = try parseCffIndex(data, base + p_off + s_off);
            out.lsubr_bias = cffSubrBias(out.lsubrs.?.count);
        }
    }
    return dict.is_cid;
}

/// Type 2 charstring interpreter: executes one glyph's charstring plus its
/// local/global subroutines, appending flattened quadratics to `curves`.
/// State that persists across subr calls (operand stack, stems, width flag,
/// current point) lives here; subr nesting is capped.
const CffInterp = struct {
    gpa: std.mem.Allocator,
    data: []const u8,
    cff: CffData,
    curves: *std.ArrayList(QuadCurve),

    stack: [cff_stack_limit]f32 = undefined,
    n_stack: usize = 0,
    cur: [2]f32 = .{ 0, 0 },
    contour_start: ?[2]f32 = null,
    stem_count: usize = 0,
    width_seen: bool = false,
    depth: usize = 0,

    fn init(
        gpa: std.mem.Allocator,
        data: []const u8,
        cff: CffData,
        curves: *std.ArrayList(QuadCurve),
    ) CffInterp {
        return .{ .gpa = gpa, .data = data, .cff = cff, .curves = curves };
    }

    fn push(self: *CffInterp, v: f32) error{InvalidTable}!void {
        if (self.n_stack >= self.stack.len) return error.InvalidTable;
        self.stack[self.n_stack] = v;
        self.n_stack += 1;
    }

    /// Pop the top operand (a subr index).
    fn pop(self: *CffInterp) f32 {
        self.n_stack -= 1;
        return self.stack[self.n_stack];
    }

    /// Drop the width operand when this is the first stack-clearing
    /// operator and the stack holds one operand more than `required`
    /// (Type 2 spec Note 4). Only the first such operator may carry a
    /// width.
    fn stripWidth(self: *CffInterp, required: usize) void {
        if (!self.width_seen and self.n_stack == required + 1) {
            @memmove(self.stack[0 .. self.n_stack - 1], self.stack[1..self.n_stack]);
            self.n_stack -= 1;
            self.width_seen = true;
        }
    }

    /// hstem/vstem/hstemhm/vstemhm, and the implied stems of
    /// hintmask/cntrmask: 2 operands per stem; an odd count on the first
    /// such operator carries the width (spec Note 4). Stems accumulate
    /// globally so mask sizing stays correct across subr calls.
    fn doStems(self: *CffInterp) error{InvalidTable}!void {
        if (!self.width_seen and self.n_stack % 2 == 1) {
            @memmove(self.stack[0 .. self.n_stack - 1], self.stack[1..self.n_stack]);
            self.n_stack -= 1;
            self.width_seen = true;
        }
        if (self.n_stack % 2 != 0) return error.InvalidTable;
        self.stem_count += self.n_stack / 2;
        self.n_stack = 0;
    }

    /// Close the open contour with a line back to its start (the implicit
    /// closepath); a contour that already returned to its start emits
    /// nothing. The current point is left at the last drawn point — the
    /// next moveto's arguments are relative to it, per the spec.
    fn closeContour(self: *CffInterp) error{ OutOfMemory, InvalidTable }!void {
        if (self.contour_start) |start| {
            if (self.cur[0] != start[0] or self.cur[1] != start[1]) {
                try self.curves.append(self.gpa, .{
                    .p0 = self.cur,
                    .p1 = .{ 0.5 * (self.cur[0] + start[0]), 0.5 * (self.cur[1] + start[1]) },
                    .p2 = start,
                });
            }
            self.contour_start = null;
        }
    }

    /// Start a new contour at the current point plus (dx, dy), closing any
    /// open contour first.
    fn moveto(self: *CffInterp, dx: f32, dy: f32) error{ OutOfMemory, InvalidTable }!void {
        try self.closeContour();
        self.cur = .{ self.cur[0] + dx, self.cur[1] + dy };
        self.contour_start = self.cur;
    }

    /// A line as a degenerate quad (control = midpoint), like the glyf
    /// decoder.
    fn appendLine(self: *CffInterp, p1: [2]f32) error{ OutOfMemory, InvalidTable }!void {
        try self.curves.append(self.gpa, .{
            .p0 = self.cur,
            .p1 = .{ 0.5 * (self.cur[0] + p1[0]), 0.5 * (self.cur[1] + p1[1]) },
            .p2 = p1,
        });
        self.cur = p1;
    }

    /// Append a line relative to the current point.
    fn lineRel(self: *CffInterp, dx: f32, dy: f32) error{ OutOfMemory, InvalidTable }!void {
        try self.appendLine(.{ self.cur[0] + dx, self.cur[1] + dy });
    }

    /// Append a cubic from six relative deltas (each delta relative to the
    /// previous point), flattened to two quadratics.
    fn curveRel(self: *CffInterp, args: *const [6]f32) error{ OutOfMemory, InvalidTable }!void {
        const x = self.cur[0];
        const y = self.cur[1];
        const x1 = x + args[0];
        const y1 = y + args[1];
        try self.appendCubic(
            self.cur,
            .{ x1, y1 },
            .{ x1 + args[2], y1 + args[3] },
            .{ x1 + args[2] + args[4], y1 + args[3] + args[5] },
        );
    }

    /// Split at the cubic's coordinate extrema before fitting quadratics.
    /// Each fit stays monotonic within its endpoints, preserving the original
    /// ink bounds rather than painting an approximation outside the frame.
    fn appendCubic(
        self: *CffInterp,
        a0: [2]f32,
        a1: [2]f32,
        a2: [2]f32,
        a3: [2]f32,
    ) error{ OutOfMemory, InvalidTable }!void {
        var points: [4][2]f64 = undefined;
        for ([_][2]f32{ a0, a1, a2, a3 }, 0..) |p, i| {
            points[i] = .{ p[0], p[1] };
        }
        var cuts: [4]f64 = undefined;
        var count: usize = 0;
        for (0..2) |axis| {
            const p0 = points[0][axis];
            const p1 = points[1][axis];
            const p2 = points[2][axis];
            const p3 = points[3][axis];
            const a = -p0 + 3 * p1 - 3 * p2 + p3;
            const b = 2 * (p0 - 2 * p1 + p2);
            const c = p1 - p0;
            if (a == 0) {
                if (b != 0) addCubicCut(&cuts, &count, -c / b);
            } else {
                const discriminant = b * b - 4 * a * c;
                if (discriminant < 0) continue;
                const root = @sqrt(discriminant);
                const q = -0.5 * (b + if (b >= 0) root else -root);
                if (q == 0) continue;
                addCubicCut(&cuts, &count, q / a);
                addCubicCut(&cuts, &count, c / q);
            }
        }
        var previous: f64 = 0;
        for (cuts[0..count]) |t| {
            var left: [4][2]f64 = undefined;
            splitCubic(&points, (t - previous) / (1 - previous), &left);
            try self.appendCubicPiece(&left);
            previous = t;
        }
        try self.appendCubicPiece(&points);
        self.cur = a3;
    }

    fn addCubicCut(cuts: *[4]f64, count: *usize, t: f64) void {
        if (!(t > 0 and t < 1)) return;
        var at: usize = 0;
        while (at < count.* and cuts[at] < t) : (at += 1) {}
        if (at < count.* and cuts[at] == t) return;
        std.debug.assert(count.* < cuts.len);
        var i = count.*;
        while (i > at) : (i -= 1) cuts[i] = cuts[i - 1];
        cuts[at] = t;
        count.* += 1;
    }

    fn cubicLerp(a: [2]f64, b: [2]f64, t: f64) [2]f64 {
        return .{ (1 - t) * a[0] + t * b[0], (1 - t) * a[1] + t * b[1] };
    }

    fn splitCubic(points: *[4][2]f64, t: f64, left: *[4][2]f64) void {
        const p01 = cubicLerp(points[0], points[1], t);
        const p12 = cubicLerp(points[1], points[2], t);
        const p23 = cubicLerp(points[2], points[3], t);
        const p012 = cubicLerp(p01, p12, t);
        const p123 = cubicLerp(p12, p23, t);
        const mid = cubicLerp(p012, p123, t);
        left.* = .{ points[0], p01, p012, mid };
        points.* = .{ mid, p123, p23, points[3] };
    }

    fn appendCubicPiece(
        self: *CffInterp,
        points: *const [4][2]f64,
    ) std.mem.Allocator.Error!void {
        var right = points.*;
        var left: [4][2]f64 = undefined;
        splitCubic(&right, 0.5, &left);
        try self.appendCubicHalf(&left);
        try self.appendCubicHalf(&right);
    }

    fn appendCubicHalf(
        self: *CffInterp,
        points: *const [4][2]f64,
    ) std.mem.Allocator.Error!void {
        var control: [2]f32 = undefined;
        for (0..2) |axis| {
            const start = points[0][axis];
            const end = points[3][axis];
            const fit = (3 * points[1][axis] - start + 3 * points[2][axis] - end) / 4;
            control[axis] = @floatCast(std.math.clamp(fit, @min(start, end), @max(start, end)));
        }
        try self.curves.append(self.gpa, .{
            .p0 = .{ @floatCast(points[0][0]), @floatCast(points[0][1]) },
            .p1 = control,
            .p2 = .{ @floatCast(points[3][0]), @floatCast(points[3][1]) },
        });
    }

    /// Execute a charstring or subr. True = the glyph is finished (endchar,
    /// possibly inside a subr, or a top-level buffer end).
    fn run(
        self: *CffInterp,
        prog: []const u8,
        is_subr: bool,
    ) error{ OutOfMemory, InvalidTable }!bool {
        var pos: usize = 0;
        while (true) {
            if (pos >= prog.len) {
                // Buffer end without return/endchar: FreeType simulates
                // return (subr) or endchar (top-level charstring).
                if (is_subr) return false;
                try self.closeContour();
                return true;
            }
            const b0 = prog[pos];
            if (b0 == 12) { // escape: next byte is the operator
                if (pos + 1 >= prog.len) return error.InvalidTable;
                const done = try self.opEscape(prog[pos + 1]);
                pos += 2;
                if (done) return true;
                continue;
            }
            if (b0 == 28 or b0 >= 32) { // operand
                try self.push(try readCffNumber(prog, &pos, .charstring));
                continue;
            }
            pos += 1;
            if (b0 == 19 or b0 == 20) { // hintmask/cntrmask: mask follows
                const done = try self.op(b0, is_subr);
                pos += (self.stem_count + 7) / 8;
                if (done) return true;
            } else {
                const done = try self.op(b0, is_subr);
                if (done) return true;
            }
        }
    }

    fn op(self: *CffInterp, opcode: u8, is_subr: bool) error{ OutOfMemory, InvalidTable }!bool {
        const s = &self.stack;
        switch (opcode) {
            1, 3, 18, 23 => try self.doStems(), // hstem, vstem, hstemhm, vstemhm
            4 => { // vmoveto
                self.stripWidth(1);
                if (self.n_stack != 1) return error.InvalidTable;
                self.width_seen = true;
                const dy = s[0];
                self.n_stack = 0;
                try self.moveto(0, dy);
            },
            5 => { // rlineto: 2 operands per segment
                if (self.n_stack % 2 != 0) return error.InvalidTable;
                var i: usize = 0;
                while (i < self.n_stack) : (i += 2) try self.lineRel(s[i], s[i + 1]);
                self.n_stack = 0;
            },
            6, 7 => { // hlineto/vlineto: 1 operand per segment, alternating
                var horizontal = opcode == 6;
                var i: usize = 0;
                while (i < self.n_stack) : (i += 1) {
                    const v = s[i];
                    const p0 = self.cur;
                    const p1 = if (horizontal)
                        [2]f32{ p0[0] + v, p0[1] }
                    else
                        [2]f32{ p0[0], p0[1] + v };
                    try self.curves.append(self.gpa, .{
                        .p0 = p0,
                        .p1 = .{ 0.5 * (p0[0] + p1[0]), 0.5 * (p0[1] + p1[1]) },
                        .p2 = p1,
                    });
                    self.cur = p1;
                    horizontal = !horizontal;
                }
                self.n_stack = 0;
            },
            8 => { // rrcurveto: 6 operands per cubic
                if (self.n_stack % 6 != 0) return error.InvalidTable;
                var i: usize = 0;
                while (i < self.n_stack) : (i += 6) try self.curveRel(s[i..][0..6]);
                self.n_stack = 0;
            },
            10, 29 => { // callsubr / callgsubr
                if (self.n_stack == 0) return error.InvalidTable;
                const done = try self.callSubr(self.pop(), opcode == 10);
                if (done) return true;
            },
            11 => { // return
                if (!is_subr) return error.InvalidTable;
                return false;
            },
            14 => { // endchar
                self.width_seen = true;
                try self.closeContour();
                return true;
            },
            19, 20 => try self.doStems(), // hintmask/cntrmask (mask skipped by run)
            21 => { // rmoveto
                self.stripWidth(2);
                if (self.n_stack != 2) return error.InvalidTable;
                self.width_seen = true;
                const dx = s[0];
                const dy = s[1];
                self.n_stack = 0;
                try self.moveto(dx, dy);
            },
            22 => { // hmoveto
                self.stripWidth(1);
                if (self.n_stack != 1) return error.InvalidTable;
                self.width_seen = true;
                const dx = s[0];
                self.n_stack = 0;
                try self.moveto(dx, 0);
            },
            24 => { // rcurveline: 6-operand cubics, then one 2-operand line
                var i: usize = 0;
                while (self.n_stack - i >= 8) : (i += 6) try self.curveRel(s[i..][0..6]);
                if (self.n_stack - i != 2) return error.InvalidTable;
                try self.lineRel(s[i], s[i + 1]);
                self.n_stack = 0;
            },
            25 => { // rlinecurve: 2-operand lines, then one 6-operand cubic
                var i: usize = 0;
                while (self.n_stack - i > 6) : (i += 2) try self.lineRel(s[i], s[i + 1]);
                if (self.n_stack - i != 6) return error.InvalidTable;
                try self.curveRel(s[i..][0..6]);
                self.n_stack = 0;
            },
            26, 27 => try self.vvHh(opcode == 26), // vvcurveto / hhcurveto
            30, 31 => try self.vhHv(opcode == 30), // vhcurveto / hvcurveto
            else => return error.InvalidTable, // reserved / undefined
        }
        return false;
    }

    fn opEscape(self: *CffInterp, esc: u8) error{ OutOfMemory, InvalidTable }!bool {
        const s = &self.stack;
        switch (esc) {
            34 => { // hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6 → two cubics
                if (self.n_stack != 7) return error.InvalidTable;
                const dx1 = s[0];
                const dx2 = s[1];
                const dy2 = s[2];
                const dx3 = s[3];
                const dx4 = s[4];
                const dx5 = s[5];
                const dx6 = s[6];
                self.n_stack = 0;
                const x = self.cur[0];
                const y = self.cur[1];
                const s1x = x + dx1;
                const s2x = s1x + dx2;
                const s3x = s2x + dx3;
                const s4x = s3x + dx4;
                const s5x = s4x + dx5;
                const s6x = s5x + dx6;
                try self.appendCubic(self.cur, .{ s1x, y }, .{ s2x, y + dy2 }, .{ s3x, y + dy2 });
                try self.appendCubic(
                    .{ s3x, y + dy2 },
                    .{ s4x, y + dy2 },
                    .{ s5x, y },
                    .{ s6x, y },
                );
            },
            35 => { // flex: 12 deltas + flex depth → two cubics
                if (self.n_stack != 13) return error.InvalidTable;
                self.n_stack = 0;
                const x = self.cur[0];
                const y = self.cur[1];
                var px = x;
                var py = y;
                var pts: [6][2]f32 = undefined;
                var i: usize = 0;
                while (i < 6) : (i += 1) {
                    px += s[2 * i];
                    py += s[2 * i + 1];
                    pts[i] = .{ px, py };
                }
                try self.appendCubic(self.cur, pts[0], pts[1], pts[2]);
                try self.appendCubic(pts[2], pts[3], pts[4], pts[5]);
            },
            36 => { // hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
                if (self.n_stack != 9) return error.InvalidTable;
                const dx1 = s[0];
                const dy1 = s[1];
                const dx2 = s[2];
                const dy2 = s[3];
                const dx3 = s[4];
                const dx4 = s[5];
                const dx5 = s[6];
                const dy5 = s[7];
                const dx6 = s[8];
                self.n_stack = 0;
                const x = self.cur[0];
                const y = self.cur[1];
                const s1x = x + dx1;
                const s1y = y + dy1;
                const s2x = s1x + dx2;
                const s2y = s1y + dy2;
                const s3x = s2x + dx3;
                const s4x = s3x + dx4;
                const s5x = s4x + dx5;
                const s5y = s2y + dy5;
                const s6x = s5x + dx6;
                try self.appendCubic(self.cur, .{ s1x, s1y }, .{ s2x, s2y }, .{ s3x, s2y });
                try self.appendCubic(.{ s3x, s2y }, .{ s4x, s2y }, .{ s5x, s5y }, .{ s6x, y });
            },
            37 => { // flex1: 10 deltas + d6 (dx or dy by the total displacement)
                if (self.n_stack != 11) return error.InvalidTable;
                self.n_stack = 0;
                const x = self.cur[0];
                const y = self.cur[1];
                var px = x;
                var py = y;
                var pts: [5][2]f32 = undefined;
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    px += s[2 * i];
                    py += s[2 * i + 1];
                    pts[i] = .{ px, py };
                }
                const dx = pts[4][0] - x;
                const dy = pts[4][1] - y;
                const d6 = s[10];
                const end = if (@abs(dx) > @abs(dy))
                    [2]f32{ x + dx + d6, y }
                else
                    [2]f32{ x, y + dy + d6 };
                try self.appendCubic(self.cur, pts[0], pts[1], pts[2]);
                try self.appendCubic(pts[2], pts[3], pts[4], end);
            },
            else => return error.InvalidTable,
        }
        return false;
    }

    /// vvcurveto (26) / hhcurveto (27): 4 operands per curve plus an
    /// optional leading dx1/dy1 on the first curve (odd count). The count
    /// is normalized like FreeType (`count & ~2`), dropping any leading
    /// junk, so non-canonical stacks never read out of bounds.
    fn vvHh(self: *CffInterp, vertical: bool) error{ OutOfMemory, InvalidTable }!void {
        const s = &self.stack;
        const count1 = self.n_stack;
        const count = count1 & ~@as(usize, 2);
        var idx = count1 - count;
        var x = self.cur[0];
        var y = self.cur[1];
        while (idx < count) : (idx += 4) {
            var lead: f32 = 0;
            if ((count - idx) & 1 != 0) {
                lead = s[idx];
                idx += 1;
            }
            var x1: f32 = undefined;
            var y1: f32 = undefined;
            var x2: f32 = undefined;
            var y2: f32 = undefined;
            var x3: f32 = undefined;
            var y3: f32 = undefined;
            if (vertical) {
                x1 = x + lead; // first control x stays at the start ("v")
                y1 = y + s[idx];
                x2 = x1 + s[idx + 1];
                y2 = y1 + s[idx + 2];
                x3 = x2;
                y3 = y2 + s[idx + 3];
            } else {
                x1 = x + s[idx];
                y1 = y + lead; // first control y stays at the start ("h")
                x2 = x1 + s[idx + 1];
                y2 = y1 + s[idx + 2];
                x3 = x2 + s[idx + 3];
                y3 = y2;
            }
            try self.appendCubic(.{ x, y }, .{ x1, y1 }, .{ x2, y2 }, .{ x3, y3 });
            x = x3;
            y = y3;
        }
        self.cur = .{ x, y };
        self.n_stack = 0;
    }

    /// vhcurveto (30) / hvcurveto (31): 4 operands per curve, alternating
    /// vertical/horizontal first controls; the LAST curve may take a fifth
    /// operand for its final coordinate along the tangent axis. Count is
    /// normalized like FreeType.
    fn vhHv(self: *CffInterp, start_vertical: bool) error{ OutOfMemory, InvalidTable }!void {
        const s = &self.stack;
        const count1 = self.n_stack;
        const count = count1 & ~@as(usize, 2);
        var idx = count1 - count;
        var x = self.cur[0];
        var y = self.cur[1];
        var vertical = start_vertical;
        while (idx < count) {
            const last = count - idx == 5;
            const extra: f32 = if (last) s[idx + 4] else 0;
            var x1: f32 = undefined;
            var y1: f32 = undefined;
            var x2: f32 = undefined;
            var y2: f32 = undefined;
            var x3: f32 = undefined;
            var y3: f32 = undefined;
            if (vertical) {
                x1 = x;
                y1 = y + s[idx];
                x2 = x1 + s[idx + 1];
                y2 = y1 + s[idx + 2];
                x3 = x2 + s[idx + 3];
                y3 = y2 + extra;
            } else {
                x1 = x + s[idx];
                y1 = y;
                x2 = x1 + s[idx + 1];
                y2 = y1 + s[idx + 2];
                x3 = x2 + extra;
                y3 = y2 + s[idx + 3];
            }
            try self.appendCubic(.{ x, y }, .{ x1, y1 }, .{ x2, y2 }, .{ x3, y3 });
            x = x3;
            y = y3;
            idx += if (last) @as(usize, 5) else 4;
            vertical = !vertical;
        }
        self.cur = .{ x, y };
        self.n_stack = 0;
    }

    /// Call a local/global subroutine (biased index); its program runs in
    /// the same interpreter state, so the operand stack, stems, width flag,
    /// and current point persist across the call (FreeType semantics — LM
    /// subrs are macros that may push results for the caller).
    fn callSubr(self: *CffInterp, raw: f32, local: bool) error{ OutOfMemory, InvalidTable }!bool {
        if (self.depth >= max_subr_depth) return error.InvalidTable;
        if (raw != @trunc(raw) or raw < -32768.0 or raw > 32767.0) return error.InvalidTable;
        const index: i32 = @intFromFloat(raw);
        const bias = if (local) self.cff.lsubr_bias else self.cff.gsubr_bias;
        const sub_idx = index + bias;
        if (sub_idx < 0) return error.InvalidTable;
        const subs = if (local)
            (self.cff.lsubrs orelse return error.InvalidTable)
        else
            self.cff.gsubrs;
        const prog = try cffItem(subs, self.data, @intCast(sub_idx));
        self.depth += 1;
        defer self.depth -= 1;
        return self.run(prog, true);
    }
};

/// The drawn size in points at and below which a prime composite in Latin
/// Modern Math resolves to the font's own unencoded alternate: LM Math's
/// cmap composites are laid out for the text-size design, and its
/// script-size alternates are the ones a script of an 8pt base (5.6pt)
/// draws. Above it the encoded composite is the only glyph: an 8.4pt script
/// (a 12pt base) and every larger size keep the glyph they always had. The
/// gate is the drawn size of the prime run alone, in points; a face that
/// carries no alternate (see `FontFace.smallPrimeGid`) ignores it.
pub const small_prime_max_size: f32 = 6.0;

/// The four glyph ids Latin Modern Math keeps OFF its cmap for a script-size
/// prime run, indexed by the codepoint order `FontFace.smallPrimeGid` uses:
/// U+2032, U+2033, U+2034, U+2057. They are the composites LM Math draws for
/// such a run, on the same 0.3em advance grid as the encoded ones and one step
/// wider each time (489/789/1089/1389 of 1000 em against 0.311/0.511/0.711/
/// 0.911em). They belong to that one font: nothing else here, not even a
/// system font whose cmap maps the same codepoints, has a glyph at these ids.
const script_prime_gids = [4]u32{ 2988, 2990, 2992, 2994 };

/// The glyph id a run paints and advances for `cp` at `size_pt`, or null when
/// the face has no glyph for it at all.
///
/// Everything a codepoint draws is the face's own cmap entry, except a prime
/// composite at or below `small_prime_max_size` in a face that carries the
/// unencoded alternate — `FontFace.smallPrimeGid` decides that, so a face
/// other than Latin Modern Math always keeps its own glyph, whatever its cmap
/// maps. This is the one rule both back ends and the metric hook resolve
/// through, so an outline, its advance and the ink box around it always name
/// the same glyph. `size_pt` is the drawn size of the run in points and only
/// selects that tier; a negative or NaN size is at or below the gate.
pub fn resolvedGlyphId(face: *const FontFace, cp: u21, size_pt: f32) ?u32 {
    const gid = face.glyphIndex(cp) orelse return null;
    if (size_pt > small_prime_max_size) return gid;
    return face.smallPrimeGid(cp) orelse gid;
}

/// (face, cp, tier) key for the per-glyph metrics cache. The tier is the
/// prime swap the size that cached this row made, and it exists only for a
/// face that carries the unencoded alternate (`FontFace.smallPrimeGid`): a
/// composite measured at script size is that alternate, one measured above
/// the gate is the cmap's own composite, and the two never share a row. Every
/// other codepoint is one row however many sizes ask for it, so the common
/// lookup stays the hash it always was — no cmap search to learn the glyph on
/// a cache hit. `face` is compared by address, so a copied face measures
/// under its own row.
const CacheKey = struct {
    face: *const FontFace,
    cp: u21,
    alternate: bool,
};

/// Roots probed first by `findFont`, before user dirs and the nix store.
const search_roots = [_][]const u8{
    "/run/current-system/sw/share/fonts",
    "/usr/share/fonts",
    "/usr/local/share/fonts",
    "/nix/var/nix/profiles/default/share/fonts",
};

/// Max recursion depth when walking font directories.
const max_search_depth = 6;

/// Max bytes accepted for a font file read.
const max_font_bytes = 64 * 1024 * 1024;

/// "Init once, render many": the embedded Latin Modern fallback faces, the
/// faces loaded from disk, and the per-glyph metric cache, all in one arena.
///
/// Ownership: every long-lived allocation — the five embedded faces, every
/// disk-loaded face, every discovered path, every cache row — lives in
/// `arena`, so one `deinit` releases all of it. `gpa` is borrowed and never
/// released here. A face this context hands out is arena-owned: its
/// `FontFace.gpa` is `null`, the caller must not `deinit` it, and every slice
/// or view reached through it dies with this context. A standalone face from
/// `FontFace.fromBytes` is untouched by `deinit` — it owns its own memory.
///
/// I/O: none is stored here. `loadFromFile` and `findFont` take the `std.Io`
/// they do their disk work through, so the caller picks the provider, and the
/// in-memory half — `init`, `faceForStyle`, `faceForCodepoint`, `metrics` —
/// never touches the file system.
///
/// Concurrency: a context is not internally synchronized. `metrics`,
/// `loadFromFile` and `findFont` write their tables, so one context serves one
/// thread at a time unless the caller serializes those calls. The embedded
/// faces and every read-only accessor are safe to share.
pub const FontContext = struct {
    /// Caller's allocator, borrowed to back `arena`; `deinit` never releases
    /// it and it must outlive the context.
    gpa: std.mem.Allocator,
    /// The one arena that owns every face, path and cache row below.
    arena: std.heap.ArenaAllocator,

    /// Path (arena-owned copy of the caller's) → arena-owned face; dedupes
    /// `loadFromFile` by the exact path string, so two spellings of one file
    /// are two entries.
    faces: std.StringHashMapUnmanaged(*FontFace),
    /// Font name → arena-owned discovered path; an empty slice records a
    /// miss, and that record is as permanent as a hit (see `findFont`).
    found: std.StringHashMapUnmanaged([]const u8),
    /// (face, cp, prime tier) → em metrics at 1pt, MATH values included; the
    /// caller scales every field by the size it asked for.
    metrics_cache: std.AutoHashMapUnmanaged(CacheKey, GlyphMetrics),

    /// Embedded Latin Modern Math — default face for math glyphs. Arena-owned
    /// like every face here, and valid until `deinit`.
    math: *FontFace,
    /// Embedded Latin Modern Roman regular — for \text/\mathrm.
    roman: *FontFace,
    /// Embedded Latin Modern Roman italic — for `\textit`.
    italic: *FontFace,
    /// Embedded Latin Modern Roman bold — for `\mathbf`.
    bold: *FontFace,
    /// Embedded Latin Modern Roman bold italic — for `\textit{\textbf{}}`.
    bold_italic: *FontFace,

    /// Create a context preloaded with the five embedded fallback faces: LM
    /// Math (math) plus LM Roman regular, italic, bold and bold italic (text).
    ///
    /// Purely in-memory: no `std.Io` and no file system, so this is the only
    /// construction embedded rendering needs. On error the arena is released
    /// and nothing is returned, so the caller owns nothing afterwards. The
    /// result is the caller's to release in exactly one `deinit`; copying the
    /// struct copies that one owner, so a copy must not be deinited.
    ///
    /// The context holds no pointer to itself, so it may live wherever the
    /// caller puts it — but a caller that publishes a pointer to it (the
    /// `ztex.layout` font hook carries one) must keep that address stable for
    /// as long as the pointer is used.
    pub fn init(gpa: std.mem.Allocator) ParseError!FontContext {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const math = try createFace(a, lmmath.lmmath_otf[0..]);
        const roman = try createFace(a, lmroman_regular.lmroman10_regular_otf[0..]);
        const italic = try createFace(a, lmroman_italic.lmroman10_italic_otf[0..]);
        const bold = try createFace(a, lmroman_bold.lmroman10_bold_otf[0..]);
        const bi = try createFace(a, lmroman_bold_italic.lmroman10_bolditalic_otf[0..]);
        return .{
            .gpa = gpa,
            .arena = arena,
            .faces = .empty,
            .found = .empty,
            .metrics_cache = .empty,
            .math = math,
            .roman = roman,
            .italic = italic,
            .bold = bold,
            .bold_italic = bi,
        };
    }

    /// Releases the arena and with it every embedded face, disk-loaded face,
    /// discovered path and cache row this context owns. The allocator given
    /// to `init` is not released. Every `*FontFace` this context handed out,
    /// and every view reached through one, is invalid afterwards; a second
    /// `deinit` releases the same arena twice.
    pub fn deinit(self: *FontContext) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The face a `CharStyle` draws from. The four text styles resolve to
    /// the four embedded LM Roman faces — regular, italic, bold and bold
    /// italic, one real face each, never a slanted or emboldened copy of
    /// another — and every other style resolves to the Latin Modern Math
    /// face, whose math-italic, double-struck, script, fraktur, sans and
    /// mono glyphs are already styled, so mapping those to a Roman face
    /// would draw the wrong letterform. Both the metric hook and the
    /// rasterizer resolve their face here, so a style can never measure
    /// from one face and be drawn from another.
    ///
    /// The face is arena-owned: it stays valid until `deinit` and the caller
    /// must not `deinit` it. The style does not change which face is used —
    /// it only picks among five faces fixed at `init` — so the result is the
    /// same pointer on every call with the same style.
    pub fn faceForStyle(self: *const FontContext, style: atom.CharStyle) *FontFace {
        return switch (style) {
            .roman => self.roman,
            .text_italic => self.italic,
            .bold => self.bold,
            .bold_italic => self.bold_italic,
            else => self.math,
        };
    }

    /// Preserve the requested text face when it maps the codepoint. A missing
    /// text glyph may use the genuine Math glyph, never a system-font
    /// substitute, so a font the caller did not ask for is never substituted.
    /// Arena-owned, like every face from `faceForStyle`.
    pub fn faceForCodepoint(self: *const FontContext, cp: u21, style: atom.CharStyle) *FontFace {
        const requested = self.faceForStyle(style);
        if (requested.glyphIndex(cp) != null) return requested;
        if (requested != self.math and self.math.glyphIndex(cp) != null) return self.math;
        return requested;
    }

    /// Parse the font file at `path` and cache the face under that path.
    ///
    /// `path` is resolved against the process working directory (`.cwd()`),
    /// so a relative path means what it means to the caller's process. The
    /// face holds a copy of the file's bytes inside the arena, so the file
    /// may change or disappear afterwards without affecting it. A second call
    /// with the same path string returns the same face without touching the
    /// file system again.
    ///
    /// `io` performs every disk operation and is not retained: it must stay
    /// valid for the call, and this context keeps no reference to it. `gpa`
    /// backs the transient read buffer only and is not retained either — the
    /// face is allocated from the context's arena. A file at or over 64 MiB
    /// fails with `error.StreamTooLong`; every `LoadError` leaves `faces`
    /// unchanged, so nothing is cached and a later call with a readable file
    /// can still succeed.
    ///
    /// The face is arena-owned: it lives until `deinit`, needs no `deinit` of
    /// its own, and every view reached through it dies with the context.
    pub fn loadFromFile(
        self: *FontContext,
        gpa: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) LoadError!*FontFace {
        if (self.faces.get(path)) |face| return face;
        const bytes = try std.Io.Dir.readFileAlloc(
            .cwd(),
            io,
            path,
            gpa,
            .limited(max_font_bytes),
        );
        defer gpa.free(bytes);
        const face = try createFace(self.arena.allocator(), bytes);
        const key = try self.arena.allocator().dupe(u8, path);
        try self.faces.put(self.arena.allocator(), key, face);
        return face;
    }

    /// Discover a font file on disk by name, or null when this search finds
    /// none. A `name` matches a file whose basename equals it, case
    /// insensitively, or begins with it — `latinmodern-math` matches
    /// `latinmodern-math.otf`.
    ///
    /// Search order, first hit wins: the well-known roots (`search_roots`),
    /// then `$XDG_DATA_HOME/fonts` and `$HOME/.local/share/fonts`, then the
    /// `/nix/store` entries whose name mentions `lm` or `font`, then the
    /// paths `fc-list` prints that also pass an existence check. Every step is
    /// best-effort: a directory that will not open, an environment variable
    /// that is unset, a missing `fc-list` and a process that fails to run all
    /// read as "nothing found here" and the search moves on. Null therefore
    /// means this search found nothing, not that no font of that name exists.
    /// This call blocks. I/O errors, including cancellation, are not
    /// propagated: an interrupted candidate is treated as absent. If the
    /// remaining best-effort search finds no hit, that miss is memoized too.
    ///
    /// Answers are memoized per `name`, misses included and permanently: a
    /// name that missed once is not searched again, so a font installed
    /// afterwards stays invisible to this context until it is destroyed and
    /// recreated. Both the hit and the miss are recorded in the arena, and
    /// the returned path is that arena-owned copy — valid until `deinit`, and
    /// the same slice on every later hit for the same name.
    ///
    /// A path built from `$XDG_DATA_HOME` or `$HOME` is only as absolute as
    /// that variable's value, so hand it straight to `loadFromFile`, which
    /// resolves a relative path against the working directory.
    ///
    /// `io` performs every disk operation, the `/proc/self/environ` read and
    /// the `fc-list` run, and is not retained: it must stay valid for the
    /// call only. This call writes `found`, so one context serves one thread
    /// at a time unless the caller serializes it.
    pub fn findFont(self: *FontContext, io: std.Io, name: []const u8) ?[]const u8 {
        if (self.found.get(name)) |cached| {
            return if (cached.len == 0) null else cached;
        }
        const path = self.findFontUncached(io, name);
        const a = self.arena.allocator();
        const cached_path = a.dupe(u8, path orelse "") catch return path;
        const cached_name = a.dupe(u8, name) catch return path;
        self.found.put(a, cached_name, cached_path) catch return path;
        return path;
    }

    /// Per-glyph metrics for `cp` at `size_pt` points, scaled linearly from
    /// em-unit values cached per (face, cp, prime tier). Infallible: an
    /// allocation failure recomputes the row instead of caching it, and the
    /// caller sees the same numbers either way.
    ///
    /// The glyph measured is the one this size resolves to: at or below
    /// `small_prime_max_size` a prime composite in a face that carries the
    /// unencoded alternate (`FontFace.smallPrimeGid`) is that alternate, and
    /// above the gate it is the cmap's own composite, so the width and the
    /// MATH values always describe the glyph the back end paints at that size
    /// and never the other tier's. `face` need not be one of the context's
    /// own faces — any face the caller holds measures correctly — and is
    /// keyed by address, so a standalone face caches under its own pointer.
    /// An external face must remain alive, unchanged, and at that address
    /// until this context is disposed; its cache rows are not invalidated
    /// when the face is replaced or disposed.
    ///
    /// `height`, `depth` and `line_gap` are the face's OWN nominal extents
    /// (hhea) — real font data, never a hard-coded table — and bound every
    /// glyph. The MATH values are the face's own per-glyph corrections, read
    /// from its MATH table on the cache miss only; every later request scales
    /// the stored em values with the same factor as the width. An unmapped
    /// codepoint gets a 0.5em advance with the same nominal extents and no
    /// MATH value; the caller decides how to draw it. `size_pt` is the drawn
    /// size in points and may be any value, including zero.
    pub fn metrics(self: *FontContext, face: *const FontFace, cp: u21, size_pt: f32) GlyphMetrics {
        const key: CacheKey = .{
            .face = face,
            .cp = cp,
            .alternate = size_pt <= small_prime_max_size and face.smallPrimeGid(cp) != null,
        };
        const em: GlyphMetrics = if (self.metrics_cache.get(key)) |cached|
            cached
        else blk: {
            const computed = computeEmMetrics(face, cp, key.alternate);
            // metrics() is infallible; a failed insert (OOM) just recomputes.
            self.metrics_cache.put(self.arena.allocator(), key, computed) catch |err| switch (err) {
                error.OutOfMemory => {},
            };
            break :blk computed;
        };
        return .{
            .width = em.width * size_pt,
            .height = em.height * size_pt,
            .depth = em.depth * size_pt,
            .line_gap = em.line_gap * size_pt,
            .italic_correction = scaleEm(em.italic_correction, size_pt),
            .top_accent_attachment = scaleEm(em.top_accent_attachment, size_pt),
        };
    }

    /// Copy `bytes` into `a` and parse them into a face owned by `a`. The
    /// caller frees nothing: the face and its bytes belong to the allocator.
    fn createFace(a: std.mem.Allocator, bytes: []const u8) ParseError!*FontFace {
        const owned = try a.dupe(u8, bytes);
        const face = try a.create(FontFace);
        face.* = try parseOwned(owned, null);
        return face;
    }

    /// One uncached pass of the `findFont` search order. Every path it
    /// returns is arena-owned and outlives only the context.
    fn findFontUncached(self: *FontContext, io: std.Io, name: []const u8) ?[]const u8 {
        for (search_roots) |root| {
            if (self.findInTree(io, root, name, 0)) |p| return p;
        }
        if (self.envGet(io, "XDG_DATA_HOME")) |xdg| {
            if (self.joinAlloc(&.{ xdg, "fonts" })) |dir| {
                if (self.findInTree(io, dir, name, 0)) |p| return p;
            }
        }
        if (self.envGet(io, "HOME")) |home| {
            if (self.joinAlloc(&.{ home, ".local", "share", "fonts" })) |dir| {
                if (self.findInTree(io, dir, name, 0)) |p| return p;
            }
        }
        if (self.findInNixStore(io, name)) |p| return p;
        if (self.findViaFcList(io, name)) |p| return p;
        return null;
    }

    /// Recursive, depth-limited directory walk looking for `name`. Null at
    /// any failure to open, read or descend, so an unreadable subtree only
    /// costs the walk.
    fn findInTree(
        self: *FontContext,
        io: std.Io,
        root: []const u8,
        name: []const u8,
        depth: u32,
    ) ?[]const u8 {
        if (depth > max_search_depth) return null;
        var dir = std.Io.Dir.openDir(.cwd(), io, root, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch return null) |entry| {
            switch (entry.kind) {
                .file => {
                    if (basenameMatches(entry.name, name)) {
                        return self.joinAlloc(&.{ root, entry.name });
                    }
                },
                .directory, .sym_link => {
                    const sub = self.joinAlloc(&.{ root, entry.name }) orelse continue;
                    if (self.findInTree(io, sub, name, depth + 1)) |p| return p;
                },
                else => {},
            }
        }
        return null;
    }

    /// Scan /nix/store outputs whose name hints at Latin Modern / fonts and
    /// search their share/fonts trees. Store hashes vary per machine, so a
    /// name-filtered walk beats hard-coding them.
    fn findInNixStore(self: *FontContext, io: std.Io, name: []const u8) ?[]const u8 {
        var store = std.Io.Dir.openDir(.cwd(), io, "/nix/store", .{
            .iterate = true,
        }) catch return null;
        defer store.close(io);
        var it = store.iterate();
        while (it.next(io) catch return null) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            if (!containsIgnoreCase(entry.name, "lm") and !containsIgnoreCase(entry.name, "font")) continue;
            const share = self.joinAlloc(&.{ "/nix/store", entry.name, "share", "fonts" }) orelse continue;
            if (self.findInTree(io, share, name, 0)) |p| return p;
        }
        return null;
    }

    /// Query fontconfig (`fc-list`) for a file path matching `name`. A
    /// process that cannot be run, exits non-zero or prints nothing usable
    /// reads as "no answer here"; every candidate is checked for existence
    /// before it is returned, so a stale fontconfig cache cannot hand back a
    /// path that is not there.
    fn findViaFcList(self: *FontContext, io: std.Io, name: []const u8) ?[]const u8 {
        const result = std.process.run(self.arena.allocator(), io, .{
            .argv = &.{"fc-list"},
            .stdout_limit = .limited(8 << 20),
            .stderr_limit = .limited(1 << 20),
        }) catch return null;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const path = std.mem.trim(u8, line[0..colon], " \t");
            if (path.len == 0) continue;
            if (!basenameMatches(path, name)) continue;
            std.Io.Dir.access(.cwd(), io, path, .{}) catch continue;
            return self.arena.allocator().dupe(u8, path) catch null;
        }
        return null;
    }

    /// Best-effort environment lookup. Linux reads /proc/self/environ
    /// (dependency-free, no libc); other platforms return null. Null also
    /// covers an unreadable `/proc`, an out-of-memory read and a variable
    /// that is not set. The returned slice points into that arena-owned read,
    /// so it lives exactly as long as the context and must be copied before
    /// it is kept anywhere else.
    fn envGet(self: *FontContext, io: std.Io, key: []const u8) ?[]const u8 {
        if (builtin.os.tag != .linux) return null;
        const data = std.Io.Dir.readFileAlloc(
            .cwd(),
            io,
            "/proc/self/environ",
            self.arena.allocator(),
            .limited(1 << 20),
        ) catch return null;
        var it = std.mem.splitScalar(u8, data, 0);
        while (it.next()) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (std.mem.eql(u8, entry[0..eq], key)) return entry[eq + 1 ..];
        }
        return null;
    }

    /// `parts` joined with the platform separator into one arena-owned path,
    /// or null when the join cannot be allocated.
    fn joinAlloc(self: *FontContext, parts: []const []const u8) ?[]const u8 {
        return std.fs.path.join(self.arena.allocator(), parts) catch null;
    }
};

/// Em metrics for a codepoint at one prime tier: the real advance from hmtx
/// for the glyph that tier resolves to — the unencoded alternate when
/// `alternate` and the face carries one, the face's own cmap glyph otherwise
/// — nominal extents (hhea) for height/depth/line_gap always, and 0.5em when
/// the face has no glyph for the codepoint at all. An uncovered MATH glyph has
/// zero italic correction; an absent MATH table leaves it unknown.
fn computeEmMetrics(face: *const FontFace, cp: u21, alternate: bool) GlyphMetrics {
    const nominal: GlyphMetrics = .{
        .width = 0.5,
        .height = face.ascenderEm(),
        .depth = face.descenderEm(),
        .line_gap = face.lineGapEm(),
    };
    const mapped = face.glyphIndex(cp) orelse return nominal;
    const id = if (alternate) (face.smallPrimeGid(cp) orelse mapped) else mapped;
    const math = face.mathValues(id);
    return .{
        .width = face.advanceEm(id),
        .height = nominal.height,
        .depth = nominal.depth,
        .line_gap = nominal.line_gap,
        .italic_correction = if (face.math != null) math.italic_correction orelse 0 else null,
        .top_accent_attachment = math.top_accent_attachment,
    };
}

/// Scale an optional em measurement without inventing a missing value.
fn scaleEm(value: ?f32, size_pt: f32) ?f32 {
    const em = value orelse return null;
    return em * size_pt;
}

/// Case-insensitive basename match; `name` may also prefix the basename
/// (e.g. "latinmodern-math" matches "latinmodern-math.otf").
fn basenameMatches(candidate: []const u8, name: []const u8) bool {
    const base = std.fs.path.basename(candidate);
    if (std.ascii.eqlIgnoreCase(base, name)) return true;
    if (base.len >= name.len and std.ascii.eqlIgnoreCase(base[0..name.len], name)) return true;
    return false;
}

/// ASCII case-insensitive substring test, used to skip store entries whose
/// name does not hint at fonts. An empty `needle` matches nothing.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── tests ────────────────────────────────
// Expected values below were measured from the real OTF files (fontTools +
// the byte-level parser in this module cross-checked byte-for-byte).
// Nothing is guessed.

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "font: parse embedded LM Math — upem and nominal extents" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    try testing.expectEqual(@as(u16, 1000), face.unitsPerEm());
    try testing.expectApproxEqAbs(@as(f32, 0.806), face.ascenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.194), face.descenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.200), face.lineGapEm(), 0.001);
    // OS/2 extents of the same font
    try testing.expectApproxEqAbs(@as(f32, 0.806), face.typoAscenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.194), face.typoDescenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.200), face.typoLineGapEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.560), face.winAscentEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.060), face.winDescentEm(), 0.001);
}

test "font: cmap + hmtx — real LM Math glyph ids and advances" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const x = face.glyphIndex('x') orelse return error.TestUnexpectedResult;
    const n = face.glyphIndex('n') orelse return error.TestUnexpectedResult;
    const sum = face.glyphIndex(0x2211) orelse return error.TestUnexpectedResult;
    const int = face.glyphIndex(0x222B) orelse return error.TestUnexpectedResult;
    // astral-plane coverage comes from the format-12 subtable
    try testing.expect(face.glyphIndex(0x1D400) != null);
    try testing.expectApproxEqAbs(@as(f32, 0.528), face.advanceEm(x), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.556), face.advanceEm(n), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.056), face.advanceEm(sum), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.665), face.advanceEm(int), 0.001);
}

test "font: roman face — format 4 only, no math glyphs" {
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    try testing.expectEqual(@as(u16, 1000), face.unitsPerEm());
    try testing.expectApproxEqAbs(@as(f32, 1.127), face.ascenderEm(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.290), face.descenderEm(), 0.001);
    try testing.expect(face.glyphIndex('x') != null);
    try testing.expect(face.glyphIndex(0x2211) == null);
    try testing.expectApproxEqAbs(
        @as(f32, 0.528),
        face.advanceEm(face.glyphIndex('x').?),
        0.001,
    );
}

test "font: accepts TTF (glyf) scaler as well as OTF (CFF)" {
    const src = lmmath.lmmath_otf[0..];
    const ttf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(ttf);
    ttf[0] = 0x00;
    ttf[1] = 0x01;
    ttf[2] = 0x00;
    ttf[3] = 0x00;
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    try testing.expectApproxEqAbs(
        @as(f32, 0.528),
        face.advanceEm(face.glyphIndex('x').?),
        0.001,
    );
}

test "font: rejects non-sfnt input" {
    try testing.expectError(error.InvalidSfnt, FontFace.fromBytes(testing.allocator, "not a font"));
    try testing.expectError(error.InvalidSfnt, FontFace.fromBytes(testing.allocator, ""));
}

test "font: context loads embedded fallbacks and caches metrics" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const math = ctx.faceForStyle(.italic);
    try testing.expectEqual(@as(u16, 1000), math.unitsPerEm());
    // each style resolves to a distinct embedded face: \mathbf must not
    // measure or draw from the regular Roman face, or it renders unbolded.
    const roman = ctx.faceForStyle(.roman);
    const bold = ctx.faceForStyle(.bold);
    try testing.expect(roman != bold);
    try testing.expect(math != roman);
    try testing.expect(math != bold);
    // every other style is drawn from the math face, whose glyphs for those
    // series are already styled.
    for ([_]atom.CharStyle{ .bb, .cal, .frak, .sans, .mono }) |s| {
        try testing.expectEqual(math, ctx.faceForStyle(s));
    }

    const g = ctx.metrics(math, 'x', 20);
    try testing.expectApproxEqAbs(@as(f32, 10.56), g.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 16.12), g.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.88), g.depth, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4.00), g.line_gap, 0.001);
    // same key hits the cache; a different size scales linearly
    const g2 = ctx.metrics(math, 'x', 20);
    try testing.expectApproxEqAbs(g.width, g2.width, 0.0001);
    const g3 = ctx.metrics(math, 'x', 10);
    try testing.expectApproxEqAbs(@as(f32, 5.28), g3.width, 0.001);
    // regular and bold advances differ (real font data), which is what makes
    // \mathbf measure and draw differently from \text
    const rx = roman.glyphIndex('x') orelse return error.TestUnexpectedResult;
    const bx = bold.glyphIndex('x') orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 0.528), roman.advanceEm(rx), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.607), bold.advanceEm(bx), 0.001);
}

test "font: each text style resolves to its own real Roman face" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    try testing.expectEqual(ctx.roman, ctx.faceForStyle(.roman));
    try testing.expectEqual(ctx.italic, ctx.faceForStyle(.text_italic));
    try testing.expectEqual(ctx.bold, ctx.faceForStyle(.bold));
    try testing.expectEqual(ctx.bold_italic, ctx.faceForStyle(.bold_italic));
    // Four different real advances for 'x' at the 10pt base, each read from
    // its own face's hmtx: no style is a slanted or emboldened copy of
    // another, so measuring and drawing cannot silently agree on a fake.
    const cases = [_]struct { style: atom.CharStyle, width: f32 }{
        .{ .style = .roman, .width = 5.28 },
        .{ .style = .text_italic, .width = 4.64 },
        .{ .style = .bold, .width = 6.07 },
        .{ .style = .bold_italic, .width = 5.61 },
    };
    for (cases) |c| {
        const g = ctx.metrics(ctx.faceForStyle(c.style), 'x', 10.0);
        try testing.expectApproxEqAbs(c.width, g.width, 0.001);
        // These are text faces with no MATH table: the metric reports the
        // genuine absence instead of an invented zero correction.
        try testing.expect(g.italic_correction == null);
        try testing.expect(g.top_accent_attachment == null);
    }
    // Accented and dotless letters are real glyphs in every text face, so a
    // text run never falls through to a 0.5em estimate.
    for ([_]atom.CharStyle{ .roman, .text_italic, .bold, .bold_italic }) |s| {
        const face = ctx.faceForStyle(s);
        try testing.expect(face.glyphIndex(0x00E9) != null); // é
        try testing.expect(face.glyphIndex(0x0131) != null); // ı
    }
}

test "font: glyph metrics carry the face's MATH values, normalized once and scaled" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const face = ctx.math;
    const cp: u21 = 0x1D453; // 𝑓, the math italic LM Math does correct
    const gid = face.glyphIndex(cp) orelse return error.TestUnexpectedResult;
    const ic = face.mathValues(gid).italic_correction orelse
        return error.TestUnexpectedResult;
    try testing.expect(ic > 0);
    // A cache miss stores the em value, and the caller gets it scaled.
    const at20 = ctx.metrics(face, cp, 20.0);
    try testing.expectApproxEqAbs(ic * 20.0, at20.italic_correction.?, 0.0001);
    // Every later request scales that one stored value — the MATH table is
    // searched once per (face, cp), and the answer tracks the requested size
    // exactly like the width does.
    const at10 = ctx.metrics(face, cp, 10.0);
    try testing.expectApproxEqAbs(ic * 10.0, at10.italic_correction.?, 0.0001);
    try testing.expectApproxEqAbs(at20.width / 2.0, at10.width, 0.0001);
    try testing.expectEqual(@as(usize, 1), ctx.metrics_cache.count());
}

test "font: metrics for an unmapped codepoint use nominal extents" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const g = ctx.metrics(ctx.faceForStyle(.italic), 0x10FFFF, 20);
    try testing.expectApproxEqAbs(@as(f32, 10.0), g.width, 0.001); // 0.5em fallback
    try testing.expectApproxEqAbs(@as(f32, 16.12), g.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.88), g.depth, 0.001);
}

test "font: loadFromFile parses a cached face from disk" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const path = ctx.findFont(testing.io, "latinmodern-math.otf") orelse
        return error.TestUnexpectedResult;
    const face = try ctx.loadFromFile(testing.allocator, testing.io, path);
    try testing.expectApproxEqAbs(
        @as(f32, 0.528),
        face.advanceEm(face.glyphIndex('x').?),
        0.001,
    );
    // second load with the same path returns the cached face
    try testing.expect(face == try ctx.loadFromFile(testing.allocator, testing.io, path));
}

test "font: findFont discovers the embedded fonts on disk" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const names = [_][]const u8{
        "latinmodern-math.otf",
        "lmroman10-regular.otf",
        "lmroman10-italic.otf",
    };
    for (names) |name| {
        const path = ctx.findFont(testing.io, name) orelse return error.TestUnexpectedResult;
        try testing.expect(std.mem.endsWith(u8, path, name));
        std.Io.Dir.access(.cwd(), testing.io, path, .{}) catch
            return error.TestUnexpectedResult;
    }
    // memoized miss: unknown names are remembered as not-found, and a
    // repeated call stays null (no rescan).
    try testing.expect(ctx.findFont(testing.io, "no-such-font-xyz.otf") == null);
    try testing.expect(ctx.findFont(testing.io, "no-such-font-xyz.otf") == null);
}

// ── outline tests ─────────────────────────────
// The embedded Latin Modern faces are CFF (OTTO scaler, "CFF " table):
// they carry no glyf/loca tables, so their outlines come from the Type 2
// charstring decoder (tested below on the real faces). The tests in this
// section additionally build a small but complete TrueType font in memory —
// the same tables the glyf decoder reads — exercising every path: flag
// repeats, short/same deltas, off-curve runs with implied midpoints,
// composites with a scale transform, degenerate and empty glyphs.

const TPoint = struct { x: i16, y: i16, on: bool };

const TComponent = struct {
    gid: u16,
    dx: i16,
    dy: i16,
    /// Uniform scale (WE_HAVE_A_SCALE); null = no scale.
    scale: ?f32 = null,
};

const TGlyph = struct {
    points: []const TPoint = &.{},
    end_pts: []const u16 = &.{},
    components: []const TComponent = &.{},
};

fn putU16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.appendSlice(gpa, &[_]u8{ @intCast(v >> 8), @intCast(v & 0xFF) });
}

fn putI16(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: i16) !void {
    try putU16(gpa, out, @bitCast(v));
}

fn putU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(gpa, &[_]u8{
        @intCast(v >> 24),
        @intCast((v >> 16) & 0xFF),
        @intCast((v >> 8) & 0xFF),
        @intCast(v & 0xFF),
    });
}

/// Big-endian u16 at a fixed offset (the MATH table's own fields are
/// 16-bit, so a u32 store would spill into the next field).
fn storeU16(out: []u8, off: usize, v: u32) void {
    out[off] = @intCast(v >> 8);
    out[off + 1] = @truncate(v);
}

/// Big-endian u32 at a fixed offset (sfnt fields are big-endian; @bitCast
/// of an integer would use native order).
fn storeU32(out: []u8, off: usize, v: u32) void {
    out[off] = @intCast(v >> 24);
    out[off + 1] = @intCast((v >> 16) & 0xFF);
    out[off + 2] = @intCast((v >> 8) & 0xFF);
    out[off + 3] = @intCast(v & 0xFF);
}

/// Encode one simple glyph: header, endPts, zero instructions, then
/// per-point flags (repeat-compressed) and x/y deltas. Deltas within
/// [-255, 255] use the short encodings, the rest signed 16-bit.
fn buildSimpleGlyph(gpa: std.mem.Allocator, g: TGlyph) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try putI16(gpa, &out, @intCast(g.end_pts.len)); // numberOfContours
    try putI16(gpa, &out, 0); // xMin
    try putI16(gpa, &out, 0); // yMin
    try putI16(gpa, &out, 1000); // xMax
    try putI16(gpa, &out, 1000); // yMax
    for (g.end_pts) |e| try putU16(gpa, &out, e);
    try putU16(gpa, &out, 0); // instructionLength

    var flags: std.ArrayList(u8) = .empty;
    defer flags.deinit(gpa);
    var xs: std.ArrayList(u8) = .empty;
    defer xs.deinit(gpa);
    var ys: std.ArrayList(u8) = .empty;
    defer ys.deinit(gpa);
    var px: i32 = 0;
    var py: i32 = 0;
    for (g.points) |p| {
        var f: u8 = if (p.on) 0x01 else 0;
        const dx: i32 = @as(i32, p.x) - px;
        const dy: i32 = @as(i32, p.y) - py;
        px = p.x;
        py = p.y;
        if (dx != 0 and dx >= -255 and dx <= 255) {
            f |= 0x02;
            if (dx > 0) f |= 0x10;
            try xs.append(gpa, @intCast(@abs(dx)));
        } else if (dx != 0) {
            try putI16(gpa, &xs, @intCast(dx));
        } else {
            f |= 0x10; // x-same: zero delta, no byte
        }
        if (dy != 0 and dy >= -255 and dy <= 255) {
            f |= 0x04;
            if (dy > 0) f |= 0x20;
            try ys.append(gpa, @intCast(@abs(dy)));
        } else if (dy != 0) {
            try putI16(gpa, &ys, @intCast(dy));
        } else {
            f |= 0x20; // y-same: zero delta, no byte
        }
        try flags.append(gpa, f);
    }
    // Repeat-compress runs of identical flags.
    var i: usize = 0;
    while (i < flags.items.len) {
        const f = flags.items[i];
        var run: usize = 1;
        while (i + run < flags.items.len and flags.items[i + run] == f) run += 1;
        if (run > 1) {
            try out.append(gpa, f | 0x08);
            try out.append(gpa, @intCast(run - 1));
        } else {
            try out.append(gpa, f);
        }
        i += run;
    }
    try out.appendSlice(gpa, xs.items);
    try out.appendSlice(gpa, ys.items);
    const value = try out.toOwnedSlice(gpa);
    return value;
}

/// Encode one composite glyph: numberOfContours == -1 plus component
/// records with word args, xy offsets, and an optional uniform scale.
fn buildCompositeGlyph(gpa: std.mem.Allocator, g: TGlyph) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // Full 10-byte glyf header (numberOfContours + bounding box), same as
    // simple glyphs; component records follow at offset 10.
    try putI16(gpa, &out, -1);
    try putI16(gpa, &out, 0); // xMin
    try putI16(gpa, &out, 0); // yMin
    try putI16(gpa, &out, 1000); // xMax
    try putI16(gpa, &out, 1000); // yMax
    for (g.components, 0..) |c, i| {
        var flags: u16 = 0x0001 | 0x0002; // words + xy offsets
        if (c.scale != null) flags |= 0x0008; // WE_HAVE_A_SCALE
        if (i + 1 < g.components.len) flags |= 0x0020; // MORE_COMPONENTS
        try putU16(gpa, &out, flags);
        try putU16(gpa, &out, c.gid);
        try putI16(gpa, &out, c.dx);
        try putI16(gpa, &out, c.dy);
        if (c.scale) |s| try putI16(gpa, &out, @intFromFloat(s * 16384.0));
    }
    const value = try out.toOwnedSlice(gpa);
    return value;
}

/// n alternating on/off points around (cx, cy) at radius r (n even).
fn circlePoints(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(TPoint),
    cx: i16,
    cy: i16,
    r: i16,
    n: usize,
) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ang: f64 = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) /
            @as(f64, @floatFromInt(n));
        const fx: f32 = @floatCast(
            @as(f64, @floatFromInt(cx)) + @as(f64, @floatFromInt(r)) * @cos(ang),
        );
        const fy: f32 = @floatCast(
            @as(f64, @floatFromInt(cy)) + @as(f64, @floatFromInt(r)) * @sin(ang),
        );
        try out.append(gpa, .{ .x = @intFromFloat(fx), .y = @intFromFloat(fy), .on = i % 2 == 0 });
    }
}

/// Assemble a complete sfnt: head/hhea/hmtx/maxp/cmap (format 4) +
/// long-format loca + glyf. Glyphs: 0 space, 1 'x', 2 'o', 3 'á'
/// (composite), 4 accent, 5 lone point, 6 two-point line. Glyph 1 is also
/// the face's own U+2032 prime, so the face maps a prime codepoint without
/// carrying any unencoded alternate for it; glyph 6 carries a 0.25em
/// advance, distinct from every other glyph's 0.5em, so a glyph id that
/// only exists as the hmtx last-entry clamp shows up in a measured width.
fn buildTestTtf(gpa: std.mem.Allocator) ![]u8 {
    var circle_outer: std.ArrayList(TPoint) = .empty;
    defer circle_outer.deinit(gpa);
    try circlePoints(gpa, &circle_outer, 500, 500, 400, 12);
    var circle_inner: std.ArrayList(TPoint) = .empty;
    defer circle_inner.deinit(gpa);
    try circlePoints(gpa, &circle_inner, 500, 500, 200, 10);
    // Both circle point lists in one array (runtime concat).
    const circle_pts = try gpa.alloc(TPoint, circle_outer.items.len + circle_inner.items.len);
    defer gpa.free(circle_pts);
    @memcpy(circle_pts[0..circle_outer.items.len], circle_outer.items);
    @memcpy(circle_pts[circle_outer.items.len..], circle_inner.items);
    const glyphs = [_]TGlyph{
        .{}, // 0: space (empty loca range)
        .{ // 1: 'x' — two strokes; off-curve runs, repeated flags, mixed deltas
            .points = &.{
                .{ .x = 0, .y = 0, .on = true },
                .{ .x = 150, .y = 175, .on = false },
                .{ .x = 300, .y = 350, .on = false },
                .{ .x = 600, .y = 700, .on = true },
                .{ .x = 100, .y = 800, .on = true },
                .{ .x = 300, .y = 450, .on = false },
                .{ .x = 500, .y = 100, .on = true },
            },
            .end_pts = &.{ 3, 6 },
        },
        .{ // 2: 'o' — outer 12-pt circle + inner 10-pt circle
            .points = circle_pts,
            .end_pts = &.{ 11, 21 },
        },
        .{ // 3: 'á' — composite: 'x' at origin + scaled accent
            .components = &.{
                .{ .gid = 1, .dx = 0, .dy = 0 },
                .{ .gid = 4, .dx = 50, .dy = 300, .scale = 0.5 },
            },
        },
        .{ // 4: accent — one upward curve
            .points = &.{
                .{ .x = 100, .y = 600, .on = true },
                .{ .x = 200, .y = 700, .on = false },
                .{ .x = 300, .y = 600, .on = true },
            },
            .end_pts = &.{2},
        },
        .{ // 5: lone point (degenerate contour)
            .points = &.{.{ .x = 500, .y = 500, .on = true }},
            .end_pts = &.{0},
        },
        .{ // 6: two points = a line
            .points = &.{
                .{ .x = 100, .y = 100, .on = true },
                .{ .x = 200, .y = 300, .on = true },
            },
            .end_pts = &.{1},
        },
    };

    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(gpa);
    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(gpa);
    for (glyphs) |g| {
        try putU32(gpa, &loca, @intCast(glyf.items.len));
        const blob = if (g.components.len > 0)
            try buildCompositeGlyph(gpa, g)
        else if (g.points.len == 0 and g.end_pts.len == 0)
            try gpa.alloc(u8, 0) // truly empty glyph: zero-length loca range
        else
            try buildSimpleGlyph(gpa, g);
        try glyf.appendSlice(gpa, blob);
        gpa.free(blob);
    }
    try putU32(gpa, &loca, @intCast(glyf.items.len));

    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(gpa);
    try putU32(gpa, &head, 0x00010000); // version
    try putU32(gpa, &head, 0x00010000); // fontRevision
    try putU32(gpa, &head, 0); // checkSumAdjustment
    try putU32(gpa, &head, 0x5F0F3CF5); // magic
    try putU16(gpa, &head, 0); // flags
    try putU16(gpa, &head, 1000); // unitsPerEm
    try putU32(gpa, &head, 0); // created (LongDateTime: two u32 halves)
    try putU32(gpa, &head, 0);
    try putU32(gpa, &head, 0); // modified
    try putU32(gpa, &head, 0);
    try putI16(gpa, &head, 0); // xMin
    try putI16(gpa, &head, 0); // yMin
    try putI16(gpa, &head, 1000); // xMax
    try putI16(gpa, &head, 1000); // yMax
    try putU16(gpa, &head, 0); // macStyle
    try putU16(gpa, &head, 8); // lowestRecPPEM
    try putI16(gpa, &head, 2); // fontDirectionHint
    try putI16(gpa, &head, 1); // indexToLocFormat: long
    try putI16(gpa, &head, 0); // glyphDataFormat

    var hhea: std.ArrayList(u8) = .empty;
    defer hhea.deinit(gpa);
    try putU32(gpa, &hhea, 0x00010000); // version
    try putI16(gpa, &hhea, 800); // ascender
    try putI16(gpa, &hhea, -200); // descender
    try putI16(gpa, &hhea, 200); // lineGap
    try putU16(gpa, &hhea, 0); // advanceWidthMax
    try putI16(gpa, &hhea, 0); // minLeftSideBearing
    try putI16(gpa, &hhea, 0); // minRightSideBearing
    try putI16(gpa, &hhea, 0); // xMaxExtent
    try putI16(gpa, &hhea, 1); // caretSlopeRise
    try putI16(gpa, &hhea, 0); // caretSlopeRun
    try putI16(gpa, &hhea, 0); // caretOffset
    try putI16(gpa, &hhea, 0); // reserved x4
    try putI16(gpa, &hhea, 0);
    try putI16(gpa, &hhea, 0);
    try putI16(gpa, &hhea, 0);
    try putI16(gpa, &hhea, 0); // metricDataFormat
    try putU16(gpa, &hhea, 7); // numHMetrics

    var hmtx: std.ArrayList(u8) = .empty;
    defer hmtx.deinit(gpa);
    for (0..7) |i| {
        try putU16(gpa, &hmtx, if (i == 6) 250 else 500);
        try putI16(gpa, &hmtx, 0);
    }

    var maxp: std.ArrayList(u8) = .empty;
    defer maxp.deinit(gpa);
    try putU32(gpa, &maxp, 0x00005000); // version 0.5
    try putU16(gpa, &maxp, 7); // numGlyphs

    var cmap: std.ArrayList(u8) = .empty;
    defer cmap.deinit(gpa);
    try putU16(gpa, &cmap, 0); // version
    try putU16(gpa, &cmap, 1); // numTables
    try putU16(gpa, &cmap, 3); // platform
    try putU16(gpa, &cmap, 1); // encoding
    try putU32(gpa, &cmap, 12); // subtable offset
    try putU16(gpa, &cmap, 4); // format
    try putU16(gpa, &cmap, 0); // length (patched below)
    try putU16(gpa, &cmap, 0); // language
    try putU16(gpa, &cmap, 12); // segCountX2 (6 segments)
    try putU16(gpa, &cmap, 8); // searchRange
    try putU16(gpa, &cmap, 2); // entrySelector
    try putU16(gpa, &cmap, 4); // rangeShift
    const segs = [_][3]u16{
        .{ 0x20, 0x20, 0 }, // space → 0
        .{ 0x6F, 0x6F, 2 }, // 'o' → 2
        .{ 0x78, 0x78, 1 }, // 'x' → 1
        .{ 0xE1, 0xE1, 3 }, // 'á' → 3
        .{ 0x2032, 0x2032, 1 }, // ′ → the same glyph as 'x'
        .{ 0xFFFF, 0xFFFF, 0 }, // sentinel
    };
    for (segs) |s| try putU16(gpa, &cmap, s[1]); // endCode
    try putU16(gpa, &cmap, 0); // reservedPad
    for (segs) |s| try putU16(gpa, &cmap, s[0]); // startCode
    for (segs) |s| try putU16(gpa, &cmap, s[2] -% s[0]); // idDelta = gid - cp
    for (segs) |_| try putU16(gpa, &cmap, 0); // idRangeOffset
    const cmap_len: u16 = @intCast(cmap.items.len - 12);
    cmap.items[14] = @intCast(cmap_len >> 8);
    cmap.items[15] = @intCast(cmap_len & 0xFF);

    // sfnt directory: 12-byte header + 16-byte records, tables sorted by
    // tag, each 4-byte aligned.
    const tables = [_]struct { tag: [4]u8, data: []const u8 }{
        .{ .tag = [4]u8{ 'c', 'm', 'a', 'p' }, .data = cmap.items },
        .{ .tag = [4]u8{ 'g', 'l', 'y', 'f' }, .data = glyf.items },
        .{ .tag = [4]u8{ 'h', 'e', 'a', 'd' }, .data = head.items },
        .{ .tag = [4]u8{ 'h', 'h', 'e', 'a' }, .data = hhea.items },
        .{ .tag = [4]u8{ 'h', 'm', 't', 'x' }, .data = hmtx.items },
        .{ .tag = [4]u8{ 'l', 'o', 'c', 'a' }, .data = loca.items },
        .{ .tag = [4]u8{ 'm', 'a', 'x', 'p' }, .data = maxp.items },
    };
    var total: usize = 12 + 16 * tables.len;
    for (tables) |t| total += (t.data.len + 3) & ~@as(usize, 3);
    const ttf = try gpa.alloc(u8, total);
    errdefer gpa.free(ttf);
    storeU32(ttf, 0, 0x00010000); // TrueType scaler
    // Header fields for 7 tables: numTables, searchRange 64 (16 × 2^2),
    // entrySelector 2, rangeShift 48 (16 × 7 - 64).
    const num_tables: u16 = @intCast(tables.len);
    ttf[4] = @intCast(num_tables >> 8);
    ttf[5] = @intCast(num_tables & 0xFF);
    ttf[6] = 0;
    ttf[7] = 64;
    ttf[8] = 0;
    ttf[9] = 2;
    ttf[10] = 0;
    ttf[11] = 48;
    var pos: usize = 12;
    var data_off: usize = 12 + 16 * tables.len;
    for (tables) |t| {
        data_off = (data_off + 3) & ~@as(usize, 3);
        ttf[pos..][0..4].* = t.tag;
        storeU32(ttf, pos + 4, 0); // checksum (unchecked)
        storeU32(ttf, pos + 8, @intCast(data_off));
        storeU32(ttf, pos + 12, @intCast(t.data.len));
        pos += 16;
        @memcpy(ttf[data_off..][0..t.data.len], t.data);
        data_off += t.data.len;
    }
    return ttf;
}

test "font: glyphOutline — 'x' has curves, sane bounds, an upward stroke" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const gid = face.glyphIndex('x') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    try testing.expect(out.curves.items.len > 0);
    var saw_up = false;
    for (out.curves.items) |c| {
        for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
            try testing.expect(p[0] >= -300 and p[0] <= 3000);
            try testing.expect(p[1] >= -300 and p[1] <= 3000);
        }
        if (c.p2[1] > c.p0[1]) saw_up = true;
    }
    try testing.expect(saw_up);
}

test "font: glyphOutline — 'o' has two contours worth of curves" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const gid = face.glyphIndex('o') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    // 12-pt outer circle (6 curves) + 10-pt inner counter (5 curves).
    try testing.expect(out.curves.items.len > 8);
}

test "font: glyphOutline — space is an empty outline" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const gid = face.glyphIndex(' ') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    try testing.expectEqual(@as(usize, 0), out.curves.items.len);
}

test "font: glyphOutline — composite 'á' appends transformed components" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const gid = face.glyphIndex(0xE1) orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    // 'x' (5 curves) + accent scaled by 0.5 (2 curves).
    try testing.expectEqual(@as(usize, 7), out.curves.items.len);
    // The scaled accent must land at x*0.5+50, y*0.5+300: its control
    // point (200, 700) becomes (150, 650).
    var saw_scaled = false;
    for (out.curves.items) |c| {
        if (c.p1[0] == 150 and c.p1[1] == 650) saw_scaled = true;
    }
    try testing.expect(saw_scaled);
}

test "font: glyphOutline — degenerate glyphs: lone point empty, two points a line" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    var lone = try face.glyphOutline(testing.allocator, 5);
    defer lone.deinit();
    try testing.expectEqual(@as(usize, 0), lone.curves.items.len);
    var line = try face.glyphOutline(testing.allocator, 6);
    defer line.deinit();
    try testing.expectEqual(@as(usize, 1), line.curves.items.len);
    try testing.expectEqual(@as(f32, 150), line.curves.items[0].p1[0]);
    try testing.expectEqual(@as(f32, 200), line.curves.items[0].p1[1]);
}

test "font: glyphOutline — malformed inputs error, never panic" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();

    // Glyph id past the last loca entry.
    try testing.expectError(
        error.InvalidTable,
        face.glyphOutline(testing.allocator, face.num_glyphs),
    );
    // Bad indexToLocFormat.
    face.index_to_loc_format = 2;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 1));
    face.index_to_loc_format = 1;
    const glyf_loc = try findTable(face.data, tag("glyf"));
    const loca_loc = try findTable(face.data, tag("loca"));
    // Truncated glyph data: claim 32767 contours — the endPts reads run
    // past the glyph's bytes immediately.
    const x_start = std.mem.readInt(u32, face.data[loca_loc.offset + 4 ..][0..4], .big);
    const nc = face.data[glyf_loc.offset + x_start ..][0..2];
    nc[0] = 0x7F;
    nc[1] = 0xFF;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 1));
    // loca start past the end (4 GiB) → start > end.
    const entry = face.data[loca_loc.offset + 4 ..][0..4];
    entry[0] = 0xFF;
    entry[1] = 0xFF;
    entry[2] = 0xFF;
    entry[3] = 0xFF;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 1));
    // loca end past the glyf table → end > glyf.len.
    const end_entry = face.data[loca_loc.offset + 8 ..][0..4];
    end_entry[0] = 0xFF;
    end_entry[1] = 0xFF;
    end_entry[2] = 0xFF;
    end_entry[3] = 0xFF;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 1));

    // A composite that references itself: recursion must be depth-bounded.
    const gid3_offset = std.mem.readInt(u32, face.data[loca_loc.offset + 12 ..][0..4], .big);
    // First component record starts at glyph+10 (after the bbox header):
    // flags u16, then the component gid u16.
    const comp_gid = face.data[glyf_loc.offset + gid3_offset + 12 ..][0..2];
    comp_gid[0] = 0x00;
    comp_gid[1] = 0x03;
    try testing.expectError(error.InvalidTable, face.glyphOutline(testing.allocator, 3));
}

test "font: quadratic outlines stay within the original CFF ink" {
    var face = try FontFace.fromBytes(testing.allocator, &lmmath.lmmath_otf);
    defer face.deinit();
    const gid = face.glyphIndex(0x1D453) orelse return error.TestUnexpectedResult;
    var outline = try face.glyphOutline(testing.allocator, gid);
    defer outline.deinit();
    for (outline.curves.items) |c| {
        try testing.expect(c.p0[1] <= 705 and c.p0[1] >= -205);
        try testing.expect(c.p2[1] <= 705 and c.p2[1] >= -205);
        const denominator = c.p0[1] - 2 * c.p1[1] + c.p2[1];
        if (denominator == 0) continue;
        const t = (c.p0[1] - c.p1[1]) / denominator;
        if (t <= 0 or t >= 1) continue;
        const u = 1 - t;
        const y = u * u * c.p0[1] + 2 * u * t * c.p1[1] + t * t * c.p2[1];
        try testing.expect(y <= 705 and y >= -205);
    }
}

test "font: glyphOutline — embedded CFF 'x' has curves, sane bounds, an upward stroke" {
    // The vendored Latin Modern faces are CFF (`OTTO` scaler, "CFF " table,
    // no loca/glyf): outlines come from Type 2 charstrings. LM em = 1000.
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    try testing.expect(face.is_cff);
    try testing.expect(face.glyf == null);
    try testing.expect(face.cff != null);
    const gid = face.glyphIndex('x') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    try testing.expect(out.curves.items.len > 0);
    var saw_up = false;
    for (out.curves.items) |c| {
        for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
            try testing.expect(p[0] >= -2000 and p[0] <= 4000);
            try testing.expect(p[1] >= -2000 and p[1] <= 4000);
        }
        if (c.p2[1] > c.p0[1]) saw_up = true;
    }
    try testing.expect(saw_up);
}

test "font: glyphOutline — embedded CFF 'o' has two contours worth of curves" {
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    const gid = face.glyphIndex('o') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    // Outer bowl plus the inner counter; each cubic flattens to two quads.
    try testing.expect(out.curves.items.len > 8);
}

test "font: glyphOutline — embedded CFF space is an empty outline" {
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    const gid = face.glyphIndex(' ') orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    // The space charstring is only a width plus endchar.
    try testing.expectEqual(@as(usize, 0), out.curves.items.len);
}

test "font: glyphOutline — embedded CFF Math sum glyph decodes" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const gid = face.glyphIndex(0x2211) orelse return error.TestUnexpectedResult;
    var out = try face.glyphOutline(testing.allocator, gid);
    defer out.deinit();
    try testing.expect(out.curves.items.len > 0);
    for (out.curves.items) |c| {
        for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
            try testing.expect(p[0] >= -2000 and p[0] <= 4000);
            try testing.expect(p[1] >= -2000 and p[1] <= 4000);
        }
    }
}

test "font: glyphOutline — CFF glyph id out of range errors, never panics" {
    var face = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer face.deinit();
    try testing.expectError(
        error.InvalidTable,
        face.glyphOutline(testing.allocator, face.num_glyphs),
    );
}

test "font: glyphOutline — regular and bold CFF 'x' shapes differ" {
    var reg = try FontFace.fromBytes(
        testing.allocator,
        lmroman_regular.lmroman10_regular_otf[0..],
    );
    defer reg.deinit();
    var bld = try FontFace.fromBytes(
        testing.allocator,
        lmroman_bold.lmroman10_bold_otf[0..],
    );
    defer bld.deinit();
    const reg_gid = reg.glyphIndex('x') orelse return error.TestUnexpectedResult;
    var a = try reg.glyphOutline(testing.allocator, reg_gid);
    defer a.deinit();
    const bld_gid = bld.glyphIndex('x') orelse return error.TestUnexpectedResult;
    var b = try bld.glyphOutline(testing.allocator, bld_gid);
    defer b.deinit();
    try testing.expect(a.curves.items.len > 0);
    try testing.expect(b.curves.items.len > 0);
    // The two faces are distinct: some control point must differ.
    var differ = a.curves.items.len != b.curves.items.len;
    if (!differ) {
        for (a.curves.items, 0..) |c, i| {
            const d = b.curves.items[i];
            if (c.p0[0] != d.p0[0] or c.p0[1] != d.p0[1] or
                c.p1[0] != d.p1[0] or c.p1[1] != d.p1[1] or
                c.p2[0] != d.p2[0] or c.p2[1] != d.p2[1])
            {
                differ = true;
                break;
            }
        }
    }
    try testing.expect(differ);
}

test "font: MATH constants are the table's design values in em" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const c = face.mathConstants() orelse return error.TestUnexpectedResult;
    // LM Math at 1000 upem: the 0.25em axis the layout bakes as 2.5pt at
    // the 10pt design size, TeX's 70%/50% script steps, and a 0.04em rule.
    try testing.expectApproxEqAbs(@as(f32, 0.25), c.axis_height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), c.script_percent_scale_down, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), c.script_script_percent_scale_down, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.3), c.display_operator_min_height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.04), c.fraction_rule_thickness, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.05), c.radical_vertical_gap, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.247), c.subscript_shift_down, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.363), c.superscript_shift_up, 0.001);
    // Negative design values keep their sign through the em conversion.
    try testing.expectApproxEqAbs(@as(f32, -0.556), c.radical_kern_after_degree, 0.001);
    // The degree raise percent is stored 0-100 and reported as a ratio.
    try testing.expectApproxEqAbs(@as(f32, 0.6), c.radical_degree_bottom_raise_percent, 0.001);
    // Connectors may overlap by 0.02em when an assembly is stacked.
    try testing.expectApproxEqAbs(@as(f32, 0.02), face.mathMinConnectorOverlapEm(), 0.001);
}

test "font: mathConstants is one borrowed view, not a copy per call" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const first = face.mathConstants() orelse return error.TestUnexpectedResult;
    const second = face.mathConstants() orelse return error.TestUnexpectedResult;
    try testing.expect(first == second);
    try testing.expectApproxEqAbs(@as(f32, 0.25), first.axis_height, 0.001);
    // The storage lives inside the face, so the pointer outlives the call:
    // a holder keeps valid constants for as long as it keeps the face.
    const field = @intFromPtr(&first.axis_height);
    const base = @intFromPtr(&face);
    try testing.expect(field > base and field < base + @sizeOf(FontFace));
}

test "font: MATH variants name the sum's .v1 — the id the rasterizer hardcodes" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const sum = face.glyphIndex(0x2211) orelse return error.TestUnexpectedResult;
    const v = face.variants(sum) orelse return error.TestUnexpectedResult;
    // One step of growth: summation.v1, glyph 3074, 1.401em along the
    // extension axis. The base glyph is not part of the ladder.
    try testing.expectEqual(@as(usize, 1), v.len());
    try testing.expectEqual(@as(u32, 3074), v.glyph(0));
    try testing.expectApproxEqAbs(@as(f32, 1.401), v.advanceEm(0), 0.001);
}

test "font: MATH radical has four size variants and a three-part assembly" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const radical = face.glyphIndex(0x221A) orelse return error.TestUnexpectedResult;
    const v = face.variants(radical) orelse return error.TestUnexpectedResult;
    // radical.v1..v4 (gids 3081-3084) grow 1.201 → 3.001em.
    try testing.expectEqual(@as(usize, 4), v.len());
    for (0..v.len()) |i| {
        try testing.expectEqual(@as(u32, 3081) + @as(u32, @intCast(i)), v.glyph(i));
    }
    try testing.expectApproxEqAbs(@as(f32, 1.201), v.advanceEm(0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.001), v.advanceEm(3), 0.001);

    // A radical taller than the last variant is built from the bar, the
    // extender, and the top — in that stacking order.
    const a = face.assembly(radical) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), a.partCount());
    const bar = a.part(0);
    try testing.expectEqual(@as(u32, 3078), bar.glyph);
    try testing.expect(!bar.extender);
    try testing.expectApproxEqAbs(@as(f32, 0.32), bar.end_connector_length, 0.001);
    const extender = a.part(1);
    try testing.expectEqual(@as(u32, 3079), extender.glyph);
    try testing.expect(extender.extender);
    try testing.expectApproxEqAbs(@as(f32, 0.64), extender.full_advance, 0.001);
    const top = a.part(2);
    try testing.expectEqual(@as(u32, 3080), top.glyph);
    try testing.expectApproxEqAbs(@as(f32, 0.32), top.start_connector_length, 0.001);
}

test "font: a zero-advance accent retains its horizontal stretch measurement" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const cases = [_]struct { cp: u21, measurement: f32 }{
        .{ .cp = 0x0302, .measurement = 0.365 },
        .{ .cp = 0x0303, .measurement = 0.371 },
    };
    for (cases) |c| {
        const base = face.glyphIndex(c.cp) orelse return error.TestUnexpectedResult;
        const ladder = face.horizontalVariants(base) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(base, ladder.glyph(0));
        try testing.expectApproxEqAbs(@as(f32, 0), face.advanceEm(ladder.glyph(0)), 0.0001);
        try testing.expectApproxEqAbs(c.measurement, ladder.advanceEm(0), 0.0001);
        for (1..ladder.len()) |i| {
            try testing.expect(ladder.advanceEm(i) > ladder.advanceEm(i - 1));
        }
        try testing.expect(face.variants(base) == null);
        try testing.expect(face.horizontalAssembly(base) == null);
    }
}

test "font: MATH delimiter carries a stretch ladder and an extensible assembly" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const paren = face.glyphIndex('(') orelse return error.TestUnexpectedResult;
    const v = face.variants(paren) orelse return error.TestUnexpectedResult;
    // parenleft grows in seven steps; the last is 2.991em tall.
    try testing.expectEqual(@as(usize, 7), v.len());
    try testing.expectEqual(@as(u32, 2367), v.glyph(0));
    try testing.expectApproxEqAbs(@as(f32, 2.991), v.advanceEm(6), 0.001);

    // Past the last variant the fence is built from a bottom piece, a
    // repeatable connector, and a top piece.
    const a = face.assembly(paren) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), a.partCount());
    try testing.expect(!a.part(0).extender);
    try testing.expect(a.part(1).extender);
    try testing.expect(!a.part(2).extender);
    try testing.expectApproxEqAbs(@as(f32, 0.498), a.part(1).full_advance, 0.001);
}

test "font: MATH per-glyph values read both coverage formats" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    // The integral's italic correction is what layout's op-tail delta
    // wants: 0.332em. It records no accent attachment.
    const integral = face.glyphIndex(0x222B) orelse return error.TestUnexpectedResult;
    const int_values = face.mathValues(integral);
    try testing.expectApproxEqAbs(@as(f32, 0.332), int_values.italic_correction.?, 0.001);
    try testing.expect(int_values.top_accent_attachment == null);
    // '*' is covered by the format-2 range table and has no italic
    // record; '7' is covered by both lists and has both values.
    const star = face.glyphIndex('*') orelse return error.TestUnexpectedResult;
    const star_values = face.mathValues(star);
    try testing.expect(star_values.italic_correction == null);
    try testing.expectApproxEqAbs(@as(f32, 0.398), star_values.top_accent_attachment.?, 0.001);
    const seven = face.glyphIndex('7') orelse return error.TestUnexpectedResult;
    const seven_values = face.mathValues(seven);
    try testing.expectApproxEqAbs(@as(f32, 0.013), seven_values.italic_correction.?, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.103), seven_values.top_accent_attachment.?, 0.001);
    // A glyph outside both coverages reports nothing rather than garbage.
    const none = face.mathValues(0);
    try testing.expect(none.italic_correction == null);
    try testing.expect(none.top_accent_attachment == null);
}

test "font: a glyph with no MATH construction has no variants or assembly" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const x = face.glyphIndex('x') orelse return error.TestUnexpectedResult;
    try testing.expect(face.variants(x) == null);
    try testing.expect(face.assembly(x) == null);
}

test "font: a face whose font has no MATH table reports no math data" {
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    try testing.expect(face.mathConstants() == null);
    try testing.expectApproxEqAbs(@as(f32, 0), face.mathMinConnectorOverlapEm(), 0.001);
    const values = face.mathValues(1);
    try testing.expect(values.italic_correction == null);
    try testing.expect(values.top_accent_attachment == null);
    try testing.expect(face.variants(1) == null);
    try testing.expect(face.assembly(1) == null);
}

/// Byte offset of a table in an sfnt container, or null when the font has
/// none. Locates a table to corrupt without hardcoding a byte offset.
fn tableOffset(data: []const u8, want: u32) ?usize {
    const num_tables = std.mem.readInt(u16, data[4..6], .big);
    var i: u16 = 0;
    while (i < num_tables) : (i += 1) {
        const rec = 12 + 16 * i;
        if (std.mem.readInt(u32, data[rec..][0..4], .big) != want) continue;
        return std.mem.readInt(u32, data[rec + 8 ..][0..4], .big);
    }
    return null;
}

test "font: a malformed MATH table fails through InvalidTable" {
    const bytes = try testing.allocator.dupe(u8, lmmath.lmmath_otf[0..]);
    defer testing.allocator.free(bytes);
    const math = tableOffset(bytes, tag("MATH")) orelse return error.TestUnexpectedResult;
    // A MathConstants offset past the end of the table.
    storeU32(bytes, math + 4, 0xFFF0);
    try testing.expectError(error.InvalidTable, FontFace.fromBytes(testing.allocator, bytes));
    // A version this parser does not know.
    storeU32(bytes, math, 0x00020000);
    try testing.expectError(error.InvalidTable, FontFace.fromBytes(testing.allocator, bytes));
    // A construction count that no longer matches the coverage it
    // indexes: the parser must not read constructions it cannot bound.
    storeU32(bytes, math, 0x00010000);
    const variants = math + std.mem.readInt(u16, bytes[math + 8 ..][0..2], .big);
    bytes[variants + 6] = 0xFF;
    bytes[variants + 7] = 0xFF;
    try testing.expectError(error.InvalidTable, FontFace.fromBytes(testing.allocator, bytes));
}

// A null coverage offset with zero constructions is a legal absent axis.
test "font: a MathVariants half with no constructions loads and stays empty" {
    const bytes = try testing.allocator.dupe(u8, lmmath.lmmath_otf[0..]);
    defer testing.allocator.free(bytes);
    const math = tableOffset(bytes, tag("MATH")) orelse return error.TestUnexpectedResult;
    const variants = math + readBeU16(bytes[math + 8 ..]);
    storeU16(bytes, variants + math_variants_horiz_cov_off, 0);
    storeU16(bytes, variants + math_variants_horiz_count_off, 0);

    var face = try FontFace.fromBytes(testing.allocator, bytes);
    defer face.deinit();
    try testing.expect(face.mathConstants() != null);

    // The surviving axis is untouched: the radical's four rungs and its
    // three-piece assembly, the same glyphs as the unmodified face.
    const radical = face.glyphIndex(0x221A) orelse return error.TestUnexpectedResult;
    const ladder = face.variants(radical) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 4), ladder.len());
    try testing.expectEqual(@as(u32, 3081), ladder.glyph(0));
    const stack = face.assembly(radical) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), stack.partCount());
    try testing.expect(stack.part(1).extender);

    // The absent axis grows nothing — including for the combining
    // circumflex, which carries a seven-rung ladder along x here.
    const hat = face.glyphIndex(0x0302) orelse return error.TestUnexpectedResult;
    try testing.expect(face.horizontalVariants(hat) == null);
    try testing.expect(face.horizontalAssembly(hat) == null);
    try testing.expect(face.horizontalVariants(radical) == null);
    try testing.expect(face.horizontalAssembly(radical) == null);
}

// A populated axis requires coverage with the same construction count.
test "font: a populated MathVariants half without coverage is invalid" {
    const bytes = try testing.allocator.dupe(u8, lmmath.lmmath_otf[0..]);
    defer testing.allocator.free(bytes);
    const math = tableOffset(bytes, tag("MATH")) orelse return error.TestUnexpectedResult;
    const variants = math + readBeU16(bytes[math + 8 ..]);
    const cov_off = readBeU16(bytes[variants + math_variants_horiz_cov_off ..]);
    const count = readBeU16(bytes[variants + math_variants_horiz_count_off ..]);
    try testing.expect(count > 0);
    // This face does grow glyphs horizontally, so a NULL coverage here
    // leaves its constructions belonging to nothing.
    storeU16(bytes, variants + math_variants_horiz_cov_off, 0);
    try testing.expectError(error.InvalidTable, FontFace.fromBytes(testing.allocator, bytes));
    // A coverage claiming more glyphs than the header count indexes
    // constructions past the glyphs they describe.
    storeU16(bytes, variants + math_variants_horiz_cov_off, cov_off);
    storeU16(bytes, variants + math_variants_horiz_count_off, count + 1);
    try testing.expectError(error.InvalidTable, FontFace.fromBytes(testing.allocator, bytes));
}

test "font: a script-size prime composite resolves to the face's own alternate" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    // LM Math's cmap composites are the text-size design — ′ 0.311em, ″
    // 0.511em, ‴ 0.711em, ⁗ 0.911em, read from the face's own hmtx. The four
    // ids below are the alternates it keeps OFF the cmap for a script-size
    // prime run, on the same 0.3em grid one step wider each time.
    // The alternates belong to this exact file: the flag is set by byte
    // identity with the embedded face, never by a name or a glyph count.
    try testing.expect(face.has_script_prime_alternates);

    const cases = [_]struct { cp: u21, gid: u32, em: f32, encoded: f32 }{
        .{ .cp = 0x2032, .gid = 2988, .em = 0.489, .encoded = 0.311 },
        .{ .cp = 0x2033, .gid = 2990, .em = 0.789, .encoded = 0.511 },
        .{ .cp = 0x2034, .gid = 2992, .em = 1.089, .encoded = 0.711 },
        .{ .cp = 0x2057, .gid = 2994, .em = 1.389, .encoded = 0.911 },
    };
    for (cases) |c| {
        try testing.expectEqual(
            c.gid,
            face.smallPrimeGid(c.cp) orelse return error.TestUnexpectedResult,
        );
        // The alternate really carries that advance: a wrong id would measure
        // and draw some other glyph of the face.
        try testing.expectApproxEqAbs(c.em, face.advanceEm(c.gid), 0.0001);
        // The encoded composite is what every size above the gate keeps, and
        // the two are never the same glyph.
        const encoded = face.glyphIndex(c.cp) orelse return error.TestUnexpectedResult;
        try testing.expect(encoded != c.gid);
        try testing.expectApproxEqAbs(c.encoded, face.advanceEm(encoded), 0.0001);
        const small = resolvedGlyphId(&face, c.cp, 5.6) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(c.gid, small);
        const large = resolvedGlyphId(&face, c.cp, 8.4) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(encoded, large);
    }
    // Nothing else moves: the modifier primes LM Math also encodes, and a
    // letter, resolve to the face's own glyph at every size.
    try testing.expect(face.smallPrimeGid(0x2035) == null);
    try testing.expect(face.smallPrimeGid('x') == null);
    const x_gid = face.glyphIndex('x') orelse return error.TestUnexpectedResult;
    const x_small = resolvedGlyphId(&face, 'x', 5.6) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(x_gid, x_small);
    const x_large = resolvedGlyphId(&face, 'x', 60.0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(x_gid, x_large);
}

test "font: a face that maps a prime keeps its own glyph at script size" {
    // This fixture is not Latin Modern Math and it does map U+2032, to its
    // own glyph: nothing in it is an unencoded script-size alternate, so
    // the prime keeps the face's own glyph at every drawn size. Another
    // font's alternate id names a glyph this face does not have — the back
    // end cannot draw it at all — and measures the hmtx last-entry clamp
    // (0.25em) instead of the prime's own advance (0.5em).
    const ttf = try buildTestTtf(testing.allocator);
    defer testing.allocator.free(ttf);
    var face = try FontFace.fromBytes(testing.allocator, ttf);
    defer face.deinit();
    const own = face.glyphIndex(0x2032) orelse return error.TestUnexpectedResult;

    // The gate is the face, not the codepoint: this face carries no
    // unencoded alternate at all, so it has no alternate to swap in.
    try testing.expect(!face.has_script_prime_alternates);
    try testing.expect(face.smallPrimeGid(0x2032) == null);

    const small = resolvedGlyphId(&face, 0x2032, 5.6) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(own, small);
    const large = resolvedGlyphId(&face, 0x2032, 8.4) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(own, large);

    // The glyph a back end paints at script size is one this face carries:
    // 'x', five curves, rather than a failure on an id past the last glyph.
    var outline = try face.glyphOutline(testing.allocator, small);
    defer outline.deinit();
    try testing.expectEqual(@as(usize, 5), outline.curves.items.len);

    // Metrics name that same glyph at both tiers, from one cached row: a
    // face with no alternate has no second tier to keep apart.
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    try testing.expectApproxEqAbs(
        face.advanceEm(own) * 5.6,
        ctx.metrics(&face, 0x2032, 5.6).width,
        0.0001,
    );
    try testing.expectApproxEqAbs(
        face.advanceEm(own) * 8.4,
        ctx.metrics(&face, 0x2032, 8.4).width,
        0.0001,
    );
    try testing.expectEqual(@as(usize, 1), ctx.metrics_cache.count());
}

test "font: the prime grid follows the drawn size, not the codepoint" {
    var f = try FontContext.init(testing.allocator);
    defer f.deinit();
    const face = f.math;
    // An 8pt base sets its script at 5.6pt and every prime in it is the
    // face's unencoded alternate: 0.489/0.789/1.089/1.389em. A 12pt base sets
    // its script at 8.4pt — past the gate — so the same four codepoints are
    // the encoded composites again, at the widths they always had.
    const cases = [_]struct { cp: u21, script_pt: f32, gate_pt: f32 }{
        .{ .cp = 0x2032, .script_pt = 2.7384, .gate_pt = 2.6124 },
        .{ .cp = 0x2033, .script_pt = 4.4184, .gate_pt = 4.2924 },
        .{ .cp = 0x2034, .script_pt = 6.0984, .gate_pt = 5.9724 },
        .{ .cp = 0x2057, .script_pt = 7.7784, .gate_pt = 7.6524 },
    };
    for (cases) |c| {
        try testing.expectApproxEqAbs(c.script_pt, f.metrics(face, c.cp, 5.6).width, 0.0001);
        try testing.expectApproxEqAbs(c.gate_pt, f.metrics(face, c.cp, 8.4).width, 0.0001);
        // The gate is the drawn size alone: the scripts of a 12.06pt, a 20pt
        // and a 60pt base are all past it, so all three keep the encoded
        // measure and land on the SAME cached row.
        const encoded = face.glyphIndex(c.cp) orelse return error.TestUnexpectedResult;
        for ([_]f32{ 8.442, 14.0, 42.0 }) |size| {
            try testing.expectApproxEqAbs(
                face.advanceEm(encoded) * size,
                f.metrics(face, c.cp, size).width,
                0.0001,
            );
        }
    }
    // One row per tier and per glyph, never one row both tiers scale: two
    // rows per prime (the alternate and the composite), and every size above
    // the gate shares the composite's.
    try testing.expectEqual(@as(usize, 2 * cases.len), f.metrics_cache.count());
}

test "font: the triple-prime alternate is one outline of three marks" {
    var face = try FontFace.fromBytes(testing.allocator, lmmath.lmmath_otf[0..]);
    defer face.deinit();
    const gid = face.smallPrimeGid(0x2034) orelse return error.TestUnexpectedResult;
    var outline = try face.glyphOutline(testing.allocator, gid);
    defer outline.deinit();
    // Contours are the maximal runs whose endpoint meets the next curve's
    // start point — the boundary svg.zig's serializer writes an `M` at and
    // the rasterizer sweeps over, so a consumer sees one path carrying three
    // marks. Each box is the CONTROL hull of the mark, which is the box the
    // back ends frame against.
    const curves = outline.curves.items;
    try testing.expect(curves.len > 2);
    var boxes: [4][4]f32 = undefined;
    var marks: usize = 0;
    var left: f32 = std.math.inf(f32);
    var right: f32 = -std.math.inf(f32);
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = -std.math.inf(f32);
    var i: usize = 0;
    while (i < curves.len) : (i += 1) {
        for ([_][2]f32{ curves[i].p0, curves[i].p1, curves[i].p2 }) |p| {
            left = @min(left, p[0]);
            right = @max(right, p[0]);
            lo = @min(lo, p[1]);
            hi = @max(hi, p[1]);
        }
        const last = i + 1 == curves.len;
        if (!last and curves[i].p2[0] == curves[i + 1].p0[0] and
            curves[i].p2[1] == curves[i + 1].p0[1]) continue;
        if (marks == boxes.len) return error.TestUnexpectedResult;
        boxes[marks] = .{ left, right, lo, hi };
        marks += 1;
        left = std.math.inf(f32);
        right = -std.math.inf(f32);
        lo = std.math.inf(f32);
        hi = -std.math.inf(f32);
    }
    try testing.expectEqual(@as(usize, 3), marks);
    // One mark repeated: the same box three times, stepped along x by the
    // hmoveto between the draws. The step is a hair NARROWER than a mark:
    // the slashes overlap by 0.025em — exactly the overlapping slashes the
    // 8pt reference draws (its inter-prime gap is -0.0251em of the script
    // size, and the old "shoulder to shoulder" premise failed as width 325
    // vs pitch 300 in font units).
    const width = boxes[0][1] - boxes[0][0];
    const pitch = boxes[1][0] - boxes[0][0];
    var k: usize = 1;
    while (k < marks) : (k += 1) {
        const step = @as(f32, @floatFromInt(k)) * pitch;
        try testing.expectApproxEqAbs(boxes[0][0] + step, boxes[k][0], 0.0001);
        try testing.expectApproxEqAbs(boxes[0][1] + step, boxes[k][1], 0.0001);
        try testing.expectApproxEqAbs(boxes[0][2], boxes[k][2], 0.0001);
        try testing.expectApproxEqAbs(boxes[0][3], boxes[k][3], 0.0001);
    }
    // Curves are font units; the face is 1000 upem, so this is em below.
    const upem: f32 = @floatFromInt(face.unitsPerEm());
    try testing.expectApproxEqAbs((width - pitch) / upem, 0.025, 0.005);
    // The marks are the big alternates (0.53em tall), not the 0.318em
    // encoded ones — the "smaller" half of the reported regression.
    try testing.expect((boxes[0][3] - boxes[0][2]) / upem > 0.45);
    // The composite is drawn above its own origin and stays inside the em.
    try testing.expect(boxes[0][2] / upem > 0);
    try testing.expect(boxes[0][3] / upem < 1.0);
}
