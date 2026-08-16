//! ztex.font — minimal OTF/TTF font parser + cached FontContext.
//!
//! Two layers:
//! - `FontFace`: a parsed font. Handles the sfnt container and the tables
//!   needed for horizontal metrics: `head` (unitsPerEm), `hhea`
//!   (ascender/descender/lineGap), `hmtx` (per-glyph advance widths),
//!   `maxp` (glyph count), `OS/2` (sTypo*/usWin* extents), and `cmap`
//!   (codepoint → glyph id, formats 4 and 12). Both OTF (`OTTO`/CFF) and
//!   TTF (0x00010000/glyf) containers parse through the same code — only
//!   metric tables are read, never outlines.
//! - `FontContext`: the "init once, render many" core. Owns the embedded
//!   Latin Modern fallback fonts (LM Math + LM Roman regular/italic) and
//!   serves per-(face, cp) metric lookups from a cache.
//!
//! Only the embedded fonts are used; disk font loading was removed (it was
//! a parse-and-discard no-op — loaded fonts were never read by the metric
//! or SVG path). context.zig — the sole importer — feeds the context to
//! layout/metrics through the closed `FontMetrics` union (SIM2).
//!
//! All values returned in "em" units are font-relative (value ÷ unitsPerEm),
//! so callers multiply by the desired size in points. Every number asserted
//! in the tests below was measured from the real fonts (see
//! notes/font-context.md for the measurement method).

const std = @import("std");

const lmmath = @import("fonts/lmmath.zig");
const lmroman_regular = @import("fonts/lmroman_regular.zig");
const lmroman_italic = @import("fonts/lmroman_italic.zig");

/// Per-glyph metrics at a given size, in points.
pub const GlyphMetrics = struct {
    /// Horizontal advance (width).
    width: f32,
    /// Nominal ascent (font hhea ascender) at this size.
    height: f32,
    /// Nominal descent (positive; -hhea descender) at this size.
    depth: f32,
    /// Nominal line gap (hhea lineGap) at this size.
    line_gap: f32,
};

/// Errors from parsing a font. All tables are bounds-checked.
pub const FontError = error{
    /// Not an sfnt container (bad scaler or truncated header).
    InvalidSfnt,
    /// A required table (head/hhea/hmtx/cmap/maxp) is missing.
    MissingTable,
    /// A table exists but its contents are malformed.
    InvalidTable,
    /// No usable cmap subtable (neither format 4 nor format 12).
    UnsupportedCmap,
};

/// Bounds-checked big-endian reader over a table slice.
const Reader = struct {
    data: []const u8,

    fn readU16(self: Reader, off: usize) error{InvalidTable}!u16 {
        if (off + 2 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(u16, self.data[off..][0..2], .big);
    }

    fn readI16(self: Reader, off: usize) error{InvalidTable}!i16 {
        if (off + 2 > self.data.len) return error.InvalidTable;
        return std.mem.readInt(i16, self.data[off..][0..2], .big);
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

/// A parsed font. Owns a private copy of the file bytes (via `fromBytes`)
/// or is arena-managed by a `FontContext` (gpa == null, never deinit'd).
pub const FontFace = struct {
    /// Allocator that owns `data`; null when a FontContext's arena owns it.
    gpa: ?std.mem.Allocator,
    /// Owned copy of the whole font file (sfnt container).
    data: []u8,

    units_per_em: u16,
    num_glyphs: u16,

    // hhea
    hhea_ascender: i16,
    hhea_descender: i16,
    hhea_line_gap: i16,
    num_h_metrics: u16,

    // OS/2 (optional table; zero when absent)
    os2_typo_ascender: i16,
    os2_typo_descender: i16,
    os2_typo_line_gap: i16,
    os2_win_ascent: u16,
    os2_win_descent: u16,

    /// hmtx table slice (into `data`); first num_h_metrics entries are
    /// (advanceWidth u16, lsb i16) pairs, later glyphs share the last advance.
    hmtx: []const u8,

    /// Selected cmap subtables (into `data`), null when the font lacks one.
    cmap4: ?[]const u8,
    cmap12: ?[]const u8,

    /// Parse `data` into a face, duplicating the bytes into `gpa`.
    /// The returned face owns its copy; free it with `deinit`.
    pub fn fromBytes(gpa: std.mem.Allocator, data: []const u8) !FontFace {
        const owned = try gpa.dupe(u8, data);
        errdefer gpa.free(owned);
        return parseOwned(owned, gpa);
    }

    /// Release the owned byte copy. No-op for arena-managed fonts (gpa null).
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
};

/// Parse an owned byte blob into a face. `gpa` is stored for `deinit`; pass
/// null when a FontContext arena manages the memory (deinit becomes a no-op).
fn parseOwned(data: []u8, gpa: ?std.mem.Allocator) FontError!FontFace {
    if (data.len < 12) return error.InvalidSfnt;
    const scaler = std.mem.readInt(u32, data[0..4], .big);
    // 0x00010000 = TrueType (glyf), 'OTTO' = OpenType/CFF. Metrics come from
    // the same sfnt tables either way; outlines are never parsed.
    if (scaler != 0x00010000 and scaler != 0x4F54544F) return error.InvalidSfnt;

    const head = try findTable(data, tag("head"));
    const hhea = try findTable(data, tag("hhea"));
    const hmtx = try findTable(data, tag("hmtx"));
    const cmap = try findTable(data, tag("cmap"));
    const maxp = try findTable(data, tag("maxp"));
    const os2 = findTable(data, tag("OS/2")) catch null;

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
        .hmtx = data[hmtx.offset..][0..hmtx.length],
        .cmap4 = null,
        .cmap12 = null,
    };
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
    return face;
}

/// (face, cp) key for the per-glyph metrics cache.
const CacheKey = struct {
    face: *const FontFace,
    cp: u21,
};

/// "Init once, render many": owns the embedded fallback fonts and the
/// per-glyph metrics cache.
///
/// Every long-lived allocation lives in `arena` (font data, cache entries);
/// `deinit` releases everything at once. `metrics` is infallible: on an
/// allocation failure it recomputes instead of caching.
pub const FontContext = struct {
    /// Caller's allocator; backs the arena.
    gpa: std.mem.Allocator,
    /// Single arena owns every face and cache entry.
    arena: std.heap.ArenaAllocator,
    /// (face, cp) → em metrics at 1pt (scaled by size_pt on return).
    metrics_cache: std.AutoHashMapUnmanaged(CacheKey, GlyphMetrics),

    /// Embedded Latin Modern Math — default face for math glyphs.
    math: *FontFace,
    /// Embedded Latin Modern Roman regular — for \text/\mathrm.
    roman: *FontFace,
    /// Embedded Latin Modern Roman italic.
    italic: *FontFace,

    /// Create a context preloaded with the embedded fallback fonts:
    /// LM Math (math), LM Roman regular and italic (text).
    pub fn init(gpa: std.mem.Allocator) !FontContext {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const math = try createFace(a, lmmath.lmmath_otf[0..]);
        const roman = try createFace(a, lmroman_regular.lmroman10_regular_otf[0..]);
        const italic = try createFace(a, lmroman_italic.lmroman10_italic_otf[0..]);
        return .{
            .gpa = gpa,
            .arena = arena,
            .metrics_cache = .empty,
            .math = math,
            .roman = roman,
            .italic = italic,
        };
    }

    /// Release everything the context owns (arena: embedded fonts, cache
    /// entries). Standalone fonts created via `FontFace.fromBytes` are
    /// unaffected (they own their own memory).
    pub fn deinit(self: *FontContext) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The embedded Latin Modern Math face (math glyphs).
    pub fn mathFace(self: *const FontContext) *FontFace {
        return self.math;
    }

    /// The embedded Latin Modern Roman face; `italic` selects the italic
    /// variant (for \text/\mathrm).
    pub fn romanFace(self: *const FontContext, italic: bool) *FontFace {
        return if (italic) self.italic else self.roman;
    }

    /// Per-glyph metrics at `size_pt` points, cached per (face, cp) in em
    /// units and scaled linearly. Height/depth/line_gap are the face's OWN
    /// nominal extents (hhea) — real font data, never a hard-coded table —
    /// and bound every glyph. Unmapped codepoints get a 0.5em advance with
    /// the same nominal extents (the caller decides how to draw them).
    pub fn metrics(self: *FontContext, face: *const FontFace, cp: u21, size_pt: f32) GlyphMetrics {
        const key: CacheKey = .{ .face = face, .cp = cp };
        const em: GlyphMetrics = if (self.metrics_cache.get(key)) |cached|
            cached
        else blk: {
            const computed = computeEmMetrics(face, cp);
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
        };
    }

    fn createFace(a: std.mem.Allocator, bytes: []const u8) !*FontFace {
        const owned = try a.dupe(u8, bytes);
        const face = try a.create(FontFace);
        face.* = try parseOwned(owned, null);
        return face;
    }
};

/// Em metrics for a codepoint: real advance from hmtx when the glyph exists,
/// nominal extents (hhea) for height/depth/line_gap always; 0.5em advance
/// when the font has no glyph for the codepoint.
fn computeEmMetrics(face: *const FontFace, cp: u21) GlyphMetrics {
    const nominal: GlyphMetrics = .{
        .width = 0.5,
        .height = face.ascenderEm(),
        .depth = face.descenderEm(),
        .line_gap = face.lineGapEm(),
    };
    const gid = face.glyphIndex(cp) orelse return nominal;
    return .{
        .width = face.advanceEm(gid),
        .height = nominal.height,
        .depth = nominal.depth,
        .line_gap = nominal.line_gap,
    };
}

// ── tests ────────────────────────────────
// Expected values below were measured from the real OTF files (fontTools +
// the byte-level parser in this module cross-checked byte-for-byte; see
// notes/font-context.md). Nothing is guessed.

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
    const math = ctx.mathFace();
    try testing.expectEqual(@as(u16, 1000), math.unitsPerEm());
    const roman = ctx.romanFace(false);
    const italic = ctx.romanFace(true);
    try testing.expect(roman != italic);

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
    // roman and italic advances differ (real font data)
    const rx = roman.glyphIndex('x').?;
    const ix = italic.glyphIndex('x').?;
    try testing.expectApproxEqAbs(@as(f32, 0.528), roman.advanceEm(rx), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.464), italic.advanceEm(ix), 0.001);
}

test "font: metrics for an unmapped codepoint use nominal extents" {
    var ctx = try FontContext.init(testing.allocator);
    defer ctx.deinit();
    const g = ctx.metrics(ctx.mathFace(), 0x10FFFF, 20);
    try testing.expectApproxEqAbs(@as(f32, 10.0), g.width, 0.001); // 0.5em fallback
    try testing.expectApproxEqAbs(@as(f32, 16.12), g.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.88), g.depth, 0.001);
}
