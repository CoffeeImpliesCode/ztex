//! ztex.layout.metrics — per-glyph TeX metrics and glue parameters.
//!
//! Bundled static table of LATIN MODERN MATH advance widths at the base font
//! size (10pt), measured with fontTools from latinmodern-math.otf (the font
//! the SVG actually draws; hmtx advance ÷ unitsPerEm × 10, em units × 10).
//! Previously these rows carried Computer-Modern widths transcribed from
//! MicroTeX's font metric tables
//! (src/res/font/{cmr10,cmmi10,cmsy10,cmex10}.def.cpp); the CM advances
//! differ from LM Math (x 0.5715 vs 0.528em, ∑ 1.4444 vs 1.056em, ∫ 0.5556
//! vs 0.665em), so layout advances never matched the rendered glyphs and
//! formulas overflowed the frame. Widths are now the LM Math advance so
//! layout advance == render advance; italic corrections and the TeX glue
//! parameters stay the CM values (spacing facts, not render geometry).
//! The DRAWN INK comes from a second generated table, `ink_metrics.zig`: the
//! real outlines of the same five embedded faces `font.zig` draws from, in
//! every direction (ascent, descent, the ink reaching past the advance box,
//! the ink's lower edge), so a glyph is framed by the face it is actually
//! painted from — an italic `f` leans past its advance, a combining mark's
//! ink sits entirely ABOVE the baseline (which is what places an accent over
//! its argument), and a bold `f` is a different, taller design than the
//! upright one. `ink_table` below is what is left of the older rounded
//! Latin-Modern-Math ink rows, and now answers ONLY for a codepoint the
//! active face's cmap does not carry.
//! The static tables are self-contained (no external font files, fully
//! deterministic lookups); the `.font` arm of the `FontMetrics` union
//! delegates glyph measurement to the embedded Latin Modern fonts via
//! font.zig (see `FontMetrics`).
//!
//! Font selection still follows MicroTeX's "mathnormal" style mapping
//! (tex_param.res.cpp): digits/operators/punctuation → cmr10, Latin letters
//! → cmmi10, roman style (\text, \mathrm) is drawn from the embedded LM
//! Roman face (`roman_style_metrics.roman`), uppercase Greek → cmr10 (base.def.cpp
//! symbols, TeX slots
//! 161-171; Α/Β are \mathrm A/B → cmmi10 slots 65/66), lowercase Greek →
//! cmmi10 (TeX slots 174-195 of cmmi10_unchanged, which MicroTeX's symbol
//! table points \alpha..\omega at), braces/bar → cmsy10, big operators →
//! cmex10. bin/rel/open/close symbols (arrows, relations, binary ops,
//! delimiters) → cmsy10 (slots 33-63 arrows, 91-126 delimiters, 161-196
//! binops/relations), AMS-only symbols → msam10/msbm10 (∠ ∴ ∵ ≦ ≧ ⩽ ⩾
//! ⊨ ∤ ∦), harpoons/∂/star/triangles/⌢⌣ → cmmi10, ⨅ → stmary10. Symbols
//! TeX composes from parts (≠ ∉ ≢ ≐ ≅ ↦ ↩ ↪ ⋈ ⋯ ″ long arrows) carry the
//! composed box width, noted per row. The WIDTH of every row is now the
//! Latin-Modern-Math advance regardless of which CM font the row maps to;
//! codepoints LM Math does not cover (Ϝ ▹ ◃ ⤒ ⧫, AMS-only, drawn by a
//! fallback font) keep their measured CM width, noted per row. Every text
//! style (\text, \mathrm, \textbf, \textit) answers from its OWN generated
//! face row instead — a roman letter is LM Roman's real advance, height and
//! depth, not the math face's row for the same codepoint — and there are no
//! optical roman bands: the four embedded faces are the only roman designs.
//!
//! A THIRD generated table, `math_style_metrics.zig`, carries what those two
//! do not: the metrics of the codepoints the style mapping REMAPS to (the
//! math sans-serif / monospace alphabets `\mathsf` and `\mathtt` ask about
//! the mapped codepoint, and the native triple / quadruple prime composite),
//! and the HORIZONTAL MATH size ladders and glyph assemblies of the four
//! forms a horizontal request names. Both come from the same LM Math bytes
//! the renderer draws, so a remapped glyph is measured by the design it is
//! painted from.

const std = @import("std");
const atom = @import("ztex.atom");
const roman_style_metrics = @import("roman_style_metrics.zig");
const ink_metrics = @import("ink_metrics.zig");
const math_style_metrics = @import("math_style_metrics.zig");

/// Per-glyph metrics, in points at the base font size (10pt).
pub const Glyph = struct {
    width: f32,
    height: f32,
    depth: f32,
    italic_correction: f32,
    /// The drawn glyph's OpenType MATH `TopAccentAttachment`, em of the
    /// glyph's font size, when the active face records one (the `.font`
    /// arm reads it from the real MATH table and rescales it to the 10pt
    /// base). `null` = the face records none, so an accent over this glyph
    /// falls back to `accentAttach`'s measured row. The static arm leaves
    /// it null: there is no face, only the table.
    top_accent_attachment: ?f32 = null,
};

/// Drawn-glyph ink extents, in em of the glyph's font-size: the outline's own
/// bounding box above and below the baseline. layoutChar/layoutText box every
/// normal glyph by these (× the drawn size) so the box — and the
/// frame/viewBox — bounds the ink that is actually drawn; see `glyphInkAt`
/// for the per-face source and `fallbackInk` for a codepoint no face carries.
///
/// `left` is how far the ink REACHES LEFT of the glyph origin, in the same em
/// (`max(0, -xMin)`: a negative left side bearing — math italic `j`, every
/// combining mark). `right_edge` is where the ink ENDS on the right, measured
/// right from that same origin (`max(0, xMax)`) — an ABSOLUTE edge, NOT an
/// overhang: `layout.setCharOverhang` takes
/// `max(0, right_edge × size − this box's advance)`, so the overhang is
/// measured against whatever advance the glyph was really boxed by. A static
/// optical band is narrower than the face whose outline this is (LMRoman17's
/// `f`: 0.276em boxed, ink to 0.357em), and an overhang recorded against the
/// face's wider hmtx advance would stop 0.030em short of the hook it has to
/// enclose. Both are non-negative; 0 — a glyph whose ink ends at the origin,
/// or a fallback face whose ink was never measured — frames the advance box
/// exactly as before.
///
/// `bottom` is the ink's lower edge measured UP from the baseline: positive
/// for a combining mark, whose ink floats entirely above its base (that is
/// what places an accent over its argument), and 0 for a glyph that sits on
/// the baseline or hangs below it — its descent is `desc`.
pub const GlyphInk = struct {
    asc: f32,
    desc: f32,
    left: f32 = 0,
    right_edge: f32 = 0,
    bottom: f32 = 0,
};

/// Horizontal advance and painted ink of a selected MATH form, in em.
/// A vertical construction reserves its parts' maximum hmtx advance; a
/// horizontal construction reserves the selected rung or assembled width.
/// The ink is the real outline union, never an estimate from the base glyph.
pub const StretchGeometry = struct {
    advance_em: f32,
    ink: GlyphInk,
    /// The width past which this form has NO design left: the last
    /// AdvanceMeasurement of a horizontal ladder that declares no glyph
    /// assembly. `req_em > finite_ceiling_em` is the only honest test for "the
    /// request outgrew the font" — a form that merely FITS under the request,
    /// a hat or a brace narrower than its nucleus, is answered from inside the
    /// ladder and is not short of anything. Null with no ladder, and null whenever an
    /// assembly exists: an assembly reaches any width, so it has no ceiling.
    finite_ceiling_em: ?f32 = null,
};

/// What resolving a horizontal stretch can fail with. A wired font decodes
/// outlines to answer, so its failures — an allocation, a table this font
/// does not carry — stay errors instead of decaying into the bundled static
/// geometry: `FontHook.horizontal_glyph` propagates them, `horizontalGlyph`
/// returns them, and a caller that cannot resolve keeps its own fallback.
/// The static branch is generated measurements with no font behind it, so it
/// cannot fail and never raises one of these.
pub const StretchError = error{
    OutOfMemory,
    InvalidSfnt,
    MissingTable,
    InvalidTable,
    UnsupportedCmap,
    UnsupportedFont,
};

/// TeX layout parameters, in points at the base size (10pt). Values are
/// MicroTeX tex_param.res.cpp em values × 10 (plus denom3/sub3/x_height from
/// the standard Computer-Modern parameter set). layout scales by size/10.
pub const GlueParams = struct {
    axis_height: f32,
    rule_thickness: f32,
    num1: f32, // numerator gap, display style
    num2: f32, // numerator gap, text style (with rule)
    num3: f32, // numerator gap, script style / \atop
    denom1: f32, // denominator gap, display style
    denom2: f32, // denominator gap, text style
    denom3: f32, // denominator gap, script style
    sup1: f32, // superscript raise floor, display style
    sup2: f32, // superscript raise floor, text style
    sup3: f32, // superscript raise floor, script style
    sub1: f32, // subscript drop floor, sub-only
    sub2: f32, // subscript drop floor, sup+sub
    sub3: f32, // subscript drop floor, script style
    supdrop: f32, // superscript drop: base height − supdrop floor
    subdrop: f32, // subscript drop: base depth + subdrop floor
    bigop_spacing1: f32, // min gap over an over-limit
    bigop_spacing2: f32, // min gap under an under-limit
    bigop_spacing3: f32, // max gap over an over-limit
    bigop_spacing4: f32, // max gap under an under-limit
    bigop_spacing5: f32, // extra padding above over / below under
    scriptfactor: f32, // script style size fraction
    scriptscriptfactor: f32, // scriptscript style size fraction
    x_height: f32, // cmmi10 x-height, for script clearance floors
    /// The `.font` arm's OpenType MATH constants, borrowed from the owned
    /// math face for the hook's lifetime; null when the active metric
    /// source carries no MATH table. `glueImpl` reads every parameter it
    /// can express from here, and layout reads the rest (radical, overbar,
    /// underbar, accent) through `mathConstants`. The static arm keeps its
    /// own measured rows and leaves this null.
    math_constants: ?*const atom.MathConstants = null,
};

/// The bundled static metric tables (Latin-Modern-Math advances, 10pt base)
/// — the metric source of `ztex.render` and of the standalone layout module.
pub const StaticTables = struct {};

/// The real-font metric backend installed by `ztex.Context` (context.zig).
/// Carries the `*FontContext` — opaque here because the ztex.layout module
/// cannot import font.zig (Zig 0.16 rejects relative imports leaving the
/// module directory, so `font.FontContext` is not nameable in this module;
/// context.zig — the one file that imports font.zig — performs the concrete
/// cast) — together with the lookup, so the arm is atomic: a `.font` arm
/// always has both its context and its lookup, and the per-instance state
/// of `FontMetrics` is just the union tag + this payload. The
/// lookup returns null for codepoints the face does not map, so
/// `glyph`/`glyphAt` fall through to the static tables and finally to
/// glyphEstimate.
///
/// WHAT THE CALLBACKS ARE: every field below is called SYNCHRONOUSLY, on
/// the thread that called `layout.render`, from inside that call and before
/// it returns. `ctx` is handed back unchanged and is valid only for the
/// duration of that call — a callback must not retain it, the codepoint, or
/// anything it returns except by value. `math_constants` is borrowed for as
/// long as the hook is installed and must outlive it.
///
/// THREADS AND REENTRY: `ctx` is mutable because measuring fills a
/// per-(face, codepoint) cache in it, and nothing in that cache is locked —
/// so ONE context must not be driven from two threads at once, while
/// separate contexts are independent and may be driven concurrently. A
/// callback may reenter layout (nothing is held across a lookup: the cache
/// hands back a value, not a borrow), and the `FontMetrics` it was handed is
/// borrowed const for the whole call, so it must not be written through.
///
/// ON AN ERROR: a `StretchError` aborts the layout call that raised it. The
/// caller keeps nothing — the box pool and any partially built draw list are
/// released before `render` returns — so the residue is whatever the
/// callback itself left behind in `ctx`, which is that context's cache.
pub const FontHook = struct {
    /// `*font.FontContext`: the embedded LM fonts + the per-(face,
    /// codepoint) metric cache, handed to every callback below unchanged. It
    /// is mutable because measuring fills that cache, which is why one
    /// context serves one thread at a time. The caller that installed the
    /// hook owns it and it must outlive the hook.
    ctx: *anyopaque,
    /// Font-backed glyph lookup for `ctx` at the 10pt base. `size_pt` is the
    /// size the glyph is DRAWN at: every per-glyph answer is the 10pt base the
    /// caller scales, so the size enters only as the prime tier (see
    /// `small_prime_max_size`). It cannot fail: null means the face maps no
    /// glyph for this codepoint in this style, and the caller falls through
    /// to the bundled tables and then to `glyphEstimate`.
    glyph: *const fn (ctx: *anyopaque, cp: u21, style: atom.CharStyle, size_pt: f32) ?Glyph,
    /// The owned math face's MATH constants, borrowed for the context's
    /// lifetime; null for a hook built without a MATH table, which leaves
    /// every parameter on its static row.
    math_constants: ?*const atom.MathConstants = null,
    /// Horizontal stretch resolver for `ctx`: the SMALLEST MATH horizontal
    /// size variant of `cp` whose AdvanceMeasurement covers `req_em`, else
    /// the balanced horizontal GlyphAssembly of the same glyph, measured
    /// from the real outlines it will draw. Its null is a real answer — the
    /// face has no such glyph or construction — and the caller keeps its own
    /// fallback; the bundled geometry is NOT substituted for it. A hook
    /// built without this field (null) is not a claim about the face and
    /// falls through to the generated static ladders.
    horizontal_glyph: ?*const fn (
        ctx: *anyopaque,
        cp: u21,
        req_em: f32,
    ) StretchError!?StretchGeometry = null,
    /// Geometry of the exact vertical form a draw item requests. `form` is the
    /// MATH variant index the layout already selected (0 = the base glyph),
    /// and `assembly_req`/`fixed_req` are EM: the ink height a balanced
    /// assembly must reach, and the amsmath FIXED-rule requirement (0 for
    /// either when the request does not ask). A missing callback keeps the
    /// static backend; a callback's null is final — the face has no such
    /// construction and the caller keeps the geometry it measured itself.
    vertical_glyph: ?*const fn (
        ctx: *anyopaque,
        cp: u21,
        form: u8,
        assembly_req: f32,
        fixed_req: f32,
    ) StretchError!?StretchGeometry = null,
};

/// Closed metric source for the layout: either the bundled static tables or
/// a real font backend. Replaces the previous four-fn-pointer +
/// opaque `?*anyopaque` struct: the per-instance state is only the union
/// arm; the lookup entry points below are comptime constants that dispatch
/// on it.
pub const FontMetrics = union(enum) {
    /// Bundled static tables only (`ztex.render` / `metrics.default`).
    static: StaticTables,
    /// Real fonts via a `FontHook` (context.zig builds it in `Context.init`).
    font: FontHook,

    /// Exact per-glyph metrics for `cp` in `style` at the 10pt base; null
    /// when neither the real font (`.font` arm) nor the static table has
    /// the codepoint. Font path first, then the bundled tables — the
    /// fallback chain layout relies on: font → static table →
    /// glyphEstimate.
    pub const glyph: *const fn (self: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph = glyphImpl;

    /// Deterministic fallback for any unknown glyph (em-based estimate).
    pub const glyphEstimate: *const fn (
        self: *const FontMetrics,
        cp: u21,
        style: atom.CharStyle,
    ) Glyph = glyphEstimateImpl;

    /// TeX layout parameters at the 10pt base; shared by both arms
    /// (spacing facts, not render geometry).
    pub const glue: *const fn (self: *const FontMetrics) GlueParams = glueImpl;
};

/// File-level aliases of the `FontMetrics` entry points, so callers can
/// write `metrics.glyph(fm, ...)` / `metrics.glue(fm)` (a union's decls are
/// only reachable as `FontMetrics.glyph` otherwise, and layout.zig + the
/// tests use the module names).
pub const glyph = FontMetrics.glyph;
pub const glyphEstimate = FontMetrics.glyphEstimate;
pub const glue = FontMetrics.glue;

/// One row of the static metric table: width, height, depth, italic
/// correction, in points at 10pt (em × 10).
const Entry = struct {
    cp: u21,
    w: f32,
    h: f32,
    d: f32,
    ic: f32,
};

/// Static metric table, sorted by `cp` ascending (binary-search invariant).
/// Widths are the Latin-Modern-Math advance (hmtx ÷ unitsPerEm × 10,
/// fontTools on latinmodern-math.otf), so the layout advance matches the
/// rendered glyph; the CM source font per row (cmr10/cmmi10/cmsy10/cmex10,
/// see the header) is retained for provenance only:
///   digits/ops/punct    → cmr10
///   A-Z, a-z            → cmmi10 (mathnormal)
///   braces, |           → cmsy10 (slots 102/103/106)
///   uppercase Greek     → cmr10 (slots 161-171; Α Β = cmmi10 A B)
///   lowercase Greek     → cmmi10 (TeX slots 174-195, \alpha..\omega)
///   big operators       → cmex10 (slots 70/72/80/81/82/83/84/96)
///   math-italic letters → U+1D434..U+1D44D / U+1D44E..U+1D467 (+ U+210E ℎ
///   for h, whose U+1D455 slot is unassigned) carry the LM Math math-italic
///   ADVANCE (the true x = 0.572em vs the upright 0.528em) with the ASCII
///   letter's height/depth/italic-correction. The ASCII rows (U+0041..5A,
///   U+0061..7A) stay: layout maps `.italic` letters to the math-italic cp
///   and falls back to the ASCII entry's metrics when the mapped cp has no
///   row (e.g. a font without the math-italic glyphs).
const table = [_]Entry{
    .{ .cp = 0x21, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0 }, // !
    .{ .cp = 0x23, .w = 8.33, .h = 6.94445, .d = 1.94443, .ic = 0 }, // # \# (cmr10 35)
    .{ .cp = 0x24, .w = 5, .h = 7.5, .d = 0.55555, .ic = 0 }, // $ \$ (cmr10 36)
    .{ .cp = 0x25, .w = 8.33, .h = 7.5, .d = 0.55555, .ic = 0 }, // % \% (cmr10 37)
    .{ .cp = 0x26, .w = 7.78, .h = 6.94445, .d = 0, .ic = 0 }, // & \& (cmr10 38)
    .{ .cp = 0x28, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // (
    .{ .cp = 0x29, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // )
    .{ .cp = 0x2B, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // +
    .{ .cp = 0x2C, .w = 2.78, .h = 1.05556, .d = 1.94445, .ic = 0 }, // ,
    .{ .cp = 0x2D, .w = 3.33, .h = 5.83334, .d = 0.83334, .ic = 0 }, // - (cmsy10 minus)
    .{ .cp = 0x2E, .w = 2.78, .h = 1.05556, .d = 0, .ic = 0 }, // .
    .{ .cp = 0x2F, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // /
    .{ .cp = 0x30, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 0
    .{ .cp = 0x31, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 1
    .{ .cp = 0x32, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 2
    .{ .cp = 0x33, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 3
    .{ .cp = 0x34, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 4
    .{ .cp = 0x35, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 5
    .{ .cp = 0x36, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 6
    .{ .cp = 0x37, .w = 5, .h = 6.44444, .d = 0, .ic = 0.13 }, // 7
    .{ .cp = 0x38, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 8
    .{ .cp = 0x39, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 9
    .{ .cp = 0x3A, .w = 2.78, .h = 4.30555, .d = 0, .ic = 0 }, // :
    .{ .cp = 0x3B, .w = 2.78, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ;
    .{ .cp = 0x3C, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // < (cmmi10)
    .{ .cp = 0x3D, .w = 7.78, .h = 3.66875, .d = -1.33125, .ic = 0 }, // =
    .{ .cp = 0x3E, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // > (cmmi10)
    .{ .cp = 0x41, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x42, .w = 7.08, .h = 6.83332, .d = 0, .ic = 0.50173 }, // B
    .{ .cp = 0x43, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0.715275 }, // C
    .{ .cp = 0x44, .w = 7.64, .h = 6.83332, .d = 0, .ic = 0.27779 }, // D
    .{ .cp = 0x45, .w = 6.81, .h = 6.83332, .d = 0, .ic = 0.57638 }, // E
    .{ .cp = 0x46, .w = 6.53, .h = 6.83332, .d = 0, .ic = 1.3889 }, // F
    .{ .cp = 0x47, .w = 7.85, .h = 6.83332, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x48, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.81248 }, // H
    .{ .cp = 0x49, .w = 3.61, .h = 6.83332, .d = 0, .ic = 0.78471 }, // I
    .{ .cp = 0x4A, .w = 5.14, .h = 6.83332, .d = 0, .ic = 0.96181 }, // J
    .{ .cp = 0x4B, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0.715275 }, // K
    .{ .cp = 0x4C, .w = 6.25, .h = 6.83332, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x4D, .w = 9.17, .h = 6.83332, .d = 0, .ic = 1.09027 }, // M
    .{ .cp = 0x4E, .w = 7.5, .h = 6.83332, .d = 0, .ic = 1.09027 }, // N
    .{ .cp = 0x4F, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0.27779 }, // O
    .{ .cp = 0x50, .w = 6.81, .h = 6.83332, .d = 0, .ic = 1.3889 }, // P
    .{ .cp = 0x51, .w = 7.78, .h = 6.83332, .d = 1.94445, .ic = 0 }, // Q
    .{ .cp = 0x52, .w = 7.36, .h = 6.83332, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x53, .w = 5.56, .h = 6.83332, .d = 0, .ic = 0.57638 }, // S
    .{ .cp = 0x54, .w = 7.22, .h = 6.83332, .d = 0, .ic = 1.3889 }, // T
    .{ .cp = 0x55, .w = 7.5, .h = 6.83332, .d = 0, .ic = 1.09027 }, // U
    .{ .cp = 0x56, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x57, .w = 10.28, .h = 6.83332, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x58, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x59, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x5A, .w = 6.11, .h = 6.83332, .d = 0, .ic = 0.715275 }, // Z
    .{ .cp = 0x5B, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0.06 }, // [
    .{ .cp = 0x5D, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ]
    .{ .cp = 0x5F, .w = 3.33, .h = 6.67859, .d = 0, .ic = 0.28 }, // _ \_ (cmr10 95)
    .{ .cp = 0x61, .w = 5, .h = 4.30555, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x62, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x63, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x64, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x65, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x66, .w = 3.06, .h = 6.94445, .d = 1.94445, .ic = 0.79 }, // f
    .{ .cp = 0x67, .w = 5, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // g
    .{ .cp = 0x68, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x69, .w = 2.78, .h = 6.59525, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x6A, .w = 3.06, .h = 6.59525, .d = 1.94445, .ic = 0.57243 }, // j
    .{ .cp = 0x6B, .w = 5.28, .h = 6.94445, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x6C, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x6D, .w = 8.33, .h = 4.30555, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x6E, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x6F, .w = 5, .h = 4.30555, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x70, .w = 5.56, .h = 4.30555, .d = 1.94445, .ic = 0 }, // p
    .{ .cp = 0x71, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // q
    .{ .cp = 0x72, .w = 3.92, .h = 4.30555, .d = 0, .ic = 0.27779 }, // r
    .{ .cp = 0x73, .w = 3.94, .h = 4.30555, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x74, .w = 3.89, .h = 6.1508, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x75, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x76, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x77, .w = 7.22, .h = 4.30555, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x78, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x79, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // y
    .{ .cp = 0x7A, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0.43981 }, // z
    .{ .cp = 0x7B, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // { (cmsy10)
    .{ .cp = 0x7C, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // | (cmsy10)
    .{ .cp = 0x7D, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // } (cmsy10)
    .{ .cp = 0x00A3, .w = 7.5, .h = 6.94444, .d = 0, .ic = 0 }, // £ \pounds (cmti10 36 sterling sign)
    .{ .cp = 0x00A5, .w = 7.5, .h = 6.75, .d = 0, .ic = 0.16 }, // ¥ \yen (msam10 85)
    .{ .cp = 0x00A7, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // § \S (cmsy10 120)
    .{ .cp = 0x00A9, .w = 6.83, .h = 7.49817, .d = 2.49939, .ic = 0.28 }, // © \copyright (c + OMS circle composite)
    .{ .cp = 0x00AC, .w = 6.67, .h = 4.30555, .d = 0, .ic = 0 }, // ¬ \neg (cmsy10 58)
    .{ .cp = 0x00B1, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ± \pm (cmsy10 167)
    .{ .cp = 0x00B6, .w = 6.11, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ¶ \P (cmsy10 123)
    .{ .cp = 0x00B7, .w = 2.78, .h = 2.5, .d = 0, .ic = 0 }, // · middle dot (cmsy10, same as U+22C5 ⋅)
    .{ .cp = 0x00D7, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // × \times (cmsy10 163)
    .{ .cp = 0x00F0, .w = 5, .h = 6.88889, .d = 0, .ic = 0 }, // ð \eth (msbm10 103)
    .{ .cp = 0x00F7, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ÷ \div (cmsy10 165)
    .{ .cp = 0x0131, .w = 2.78, .h = 4.30555, .d = 0, .ic = 0 }, // ı \imath (cmmi10 123)
    .{ .cp = 0x0237, .w = 3.06, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ȷ \jmath (cmmi10 124)
    .{ .cp = 0x391, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // Α
    .{ .cp = 0x392, .w = 7.08, .h = 6.83332, .d = 0, .ic = 0.50173 }, // Β
    .{ .cp = 0x393, .w = 6.25, .h = 6.83332, .d = 0, .ic = 0 }, // Γ (cmr10 slot 161)
    .{ .cp = 0x394, .w = 8.33, .h = 6.83332, .d = 0, .ic = 0 }, // Δ (cmr10 slot 162)
    .{ .cp = 0x398, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0 }, // Θ (cmr10 slot 163)
    .{ .cp = 0x39B, .w = 6.94, .h = 6.83332, .d = 0, .ic = 0 }, // Λ (cmr10 slot 164)
    .{ .cp = 0x39E, .w = 6.67, .h = 6.83332, .d = 0, .ic = 0 }, // Ξ (cmr10 slot 165)
    .{ .cp = 0x3A0, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // Π (cmr10 slot 166)
    .{ .cp = 0x3A3, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0 }, // Σ (cmr10 slot 167)
    .{ .cp = 0x3A5, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0 }, // Υ (cmr10 slot 168)
    .{ .cp = 0x3A6, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0 }, // Φ (cmr10 slot 169)
    .{ .cp = 0x3A8, .w = 7.78, .h = 6.83332, .d = 0, .ic = 0 }, // Ψ (cmr10 slot 170)
    .{ .cp = 0x3A9, .w = 7.22, .h = 6.83332, .d = 0, .ic = 0 }, // Ω (cmr10 slot 171)
    .{ .cp = 0x3B1, .w = 6.41, .h = 4.30555, .d = 0, .ic = 0.24 }, // α
    .{ .cp = 0x3B2, .w = 5.58, .h = 6.94445, .d = 1.94445, .ic = 0.52778 }, // β
    .{ .cp = 0x3B3, .w = 5.86, .h = 4.30555, .d = 1.94445, .ic = 0.55555 }, // γ
    .{ .cp = 0x3B4, .w = 4.74, .h = 6.94445, .d = 0, .ic = 0.37847 }, // δ
    .{ .cp = 0x3B5, .w = 5.35, .h = 4.30555, .d = 0, .ic = 0 }, // ε
    .{ .cp = 0x3B6, .w = 5.3, .h = 6.94445, .d = 1.94445, .ic = 0.73784 }, // ζ
    .{ .cp = 0x3B7, .w = 5.3, .h = 4.30555, .d = 1.94445, .ic = 0.35879 }, // η
    .{ .cp = 0x3B8, .w = 4.88, .h = 6.94445, .d = 0, .ic = 0.27779 }, // θ
    .{ .cp = 0x3B9, .w = 3.08, .h = 4.30555, .d = 0, .ic = 0.24 }, // ι
    .{ .cp = 0x3BA, .w = 5.3, .h = 4.30555, .d = 0, .ic = 0.23 }, // κ
    .{ .cp = 0x3BB, .w = 5.37, .h = 6.94445, .d = 0, .ic = 0.54 }, // λ
    .{ .cp = 0x3BC, .w = 5.3, .h = 4.30555, .d = 1.94445, .ic = 0.23 }, // μ
    .{ .cp = 0x3BD, .w = 5.02, .h = 4.30555, .d = 0, .ic = 0.63658 }, // ν
    .{ .cp = 0x3BE, .w = 5.3, .h = 6.94445, .d = 1.94445, .ic = 0.46007 }, // ξ
    .{ .cp = 0x3BF, .w = 5, .h = 4.30555, .d = 0, .ic = 0 }, // ο (cmmi10 111 italic o; CM has no omicron)
    .{ .cp = 0x3C0, .w = 5.86, .h = 4.30555, .d = 0, .ic = 0.35879 }, // π
    .{ .cp = 0x3C1, .w = 4.88, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ρ
    .{ .cp = 0x3C2, .w = 4.74, .h = 4.30555, .d = 0.97223, .ic = 0.7986 }, // ς \varsigma
    .{ .cp = 0x3C3, .w = 5.99, .h = 4.30555, .d = 0, .ic = 0.35879 }, // σ
    .{ .cp = 0x3C4, .w = 5.3, .h = 4.30555, .d = 0, .ic = 1.13195 }, // τ
    .{ .cp = 0x3C5, .w = 5.3, .h = 4.30555, .d = 0, .ic = 0.35879 }, // υ
    .{ .cp = 0x3C6, .w = 6.41, .h = 6.94445, .d = 1.94445, .ic = 0 }, // φ
    .{ .cp = 0x3C7, .w = 6.41, .h = 4.30555, .d = 1.94445, .ic = 0.24 }, // χ
    .{ .cp = 0x3C8, .w = 6.41, .h = 6.94445, .d = 1.94445, .ic = 0.35879 }, // ψ
    .{ .cp = 0x3C9, .w = 6.41, .h = 6.94445, .d = 1.94445, .ic = 0.35879 }, // ω
    .{ .cp = 0x3D1, .w = 5.3, .h = 6.94445, .d = 0, .ic = 0.21 }, // ϑ \vartheta
    .{ .cp = 0x3D5, .w = 6.41, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ϕ \varphi
    .{ .cp = 0x3D6, .w = 8.36, .h = 4.30555, .d = 0, .ic = 0.27779 }, // ϖ \varpi
    .{ .cp = 0x3D8, .w = 7.77781, .h = 5.81665, .d = 0.81665, .ic = 0 }, // Ϝ \digamma (msbm10 122)
    .{ .cp = 0x3F1, .w = 4.88, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ϱ \varrho
    .{ .cp = 0x3F5, .w = 4.14, .h = 4.30555, .d = 0, .ic = 0.35 }, // ϵ \varepsilon
    .{ .cp = 0x2020, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // † \dagger (cmsy10 121)
    .{ .cp = 0x2021, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ‡ \ddagger (cmsy10 122)
    .{ .cp = 0x2026, .w = 8.37, .h = 1.05556, .d = 0, .ic = 0 }, // … \ldots (composite: 3 × \ldotp, cmmi10 58)
    .{ .cp = 0x2032, .w = 3.11, .h = 5.55557, .d = 0, .ic = 0 }, // ′ \prime (cmsy10 48)
    .{ .cp = 0x2033, .w = 5.11, .h = 5.55557, .d = 0, .ic = 0 }, // ″ composite: 2 × \prime
    .{ .cp = 0x2035, .w = 3.11, .h = 5.4986, .d = 0, .ic = 0 }, // ‵ \backprime (msam10 56)
    .{ .cp = 0x210E, .w = 5.76, .h = 6.94445, .d = 0, .ic = 0.07 }, // ℎ
    .{ .cp = 0x210F, .w = 5.76, .h = 6.88889, .d = 0, .ic = 0 }, // ℏ \hbar (msbm10 126)
    .{ .cp = 0x2111, .w = 5.54, .h = 6.94445, .d = 0, .ic = 0.07 }, // ℑ \Im (cmsy10 61)
    .{ .cp = 0x2113, .w = 4.17, .h = 6.94445, .d = 0, .ic = 0.09 }, // ℓ \ell (cmmi10 96)
    .{ .cp = 0x2118, .w = 6.36, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ℘ \wp (cmmi10 125)
    .{ .cp = 0x211C, .w = 8.28, .h = 6.94445, .d = 0, .ic = 0.26 }, // ℜ \Re (cmsy10 60)
    .{ .cp = 0x2127, .w = 7.22, .h = 6.88889, .d = 0, .ic = 0 }, // ℧ \mho (msbm10 102)
    .{ .cp = 0x2135, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ℵ \aleph (cmsy10 64)
    .{ .cp = 0x2190, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ← \leftarrow (cmsy10 195)
    .{ .cp = 0x2191, .w = 5, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↑ \uparrow (cmsy10 34)
    .{ .cp = 0x2192, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // → \rightarrow (cmsy10 33)
    .{ .cp = 0x2193, .w = 5, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↓ \downarrow (cmsy10 35)
    .{ .cp = 0x2194, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ↔ \leftrightarrow (cmsy10 36)
    .{ .cp = 0x2195, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ↕ \updownarrow (cmsy10 108)
    .{ .cp = 0x2196, .w = 10, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↖ \nwarrow (cmsy10 45)
    .{ .cp = 0x2197, .w = 10, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↗ \nearrow (cmsy10 37)
    .{ .cp = 0x2198, .w = 10, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↘ \searrow (cmsy10 38)
    .{ .cp = 0x2199, .w = 10, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ↙ \swarrow (cmsy10 46)
    .{ .cp = 0x21A3, .w = 11.92, .h = 5.22394, .d = 0.13539, .ic = 0 }, // ↣ \rightarrowtail (msam10 26)
    .{ .cp = 0x21A6, .w = 9.77, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ↦ \mapsto (composite: \mapstochar →)
    .{ .cp = 0x21A9, .w = 9.97, .h = 4.63748, .d = -1.33125, .ic = 0 }, // ↩ \hookleftarrow (← 3\joinrel \rhook)
    .{ .cp = 0x21AA, .w = 9.97, .h = 4.63748, .d = -1.33125, .ic = 0 }, // ↪ \hookrightarrow (\lhook 3\joinrel →)
    .{ .cp = 0x21BC, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ↼ \leftharpoonup (cmmi10 40)
    .{ .cp = 0x21BD, .w = 10.12, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ↽ \leftharpoondown (cmmi10 41)
    .{ .cp = 0x21C0, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇀ \rightharpoonup (cmmi10 42)
    .{ .cp = 0x21C1, .w = 10.12, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇁ \rightharpoondown (cmmi10 43)
    .{ .cp = 0x21C4, .w = 10.18, .h = 6.75, .d = 1.80801, .ic = 0 }, // ⇄ \rightleftarrows (msam10 29)
    .{ .cp = 0x21D0, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇐ \Leftarrow (cmsy10 40)
    .{ .cp = 0x21D1, .w = 6.11, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ⇑ \Uparrow (cmsy10 42)
    .{ .cp = 0x21D2, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇒ \Rightarrow (cmsy10 41)
    .{ .cp = 0x21D3, .w = 6.11, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ⇓ \Downarrow (cmsy10 43)
    .{ .cp = 0x21D4, .w = 10, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⇔ \Leftrightarrow (cmsy10 44)
    .{ .cp = 0x21D5, .w = 6.11, .h = 7.5, .d = 2.5, .ic = 0 }, // ⇕ \Updownarrow (cmsy10 109)
    .{ .cp = 0x2200, .w = 6.66, .h = 6.94445, .d = 0, .ic = 0 }, // ∀ \forall (cmsy10 56)
    .{ .cp = 0x2202, .w = 5.86, .h = 6.94445, .d = 0, .ic = 0.55555 }, // ∂ \partial (cmmi10 64)
    .{ .cp = 0x2203, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // ∃ \exists (cmsy10 57)
    .{ .cp = 0x2204, .w = 5.56, .h = 6.88889, .d = 0, .ic = 0 }, // ∄ \nexists (msbm10 64)
    .{ .cp = 0x2205, .w = 5, .h = 7.5, .d = 0.55555, .ic = 0 }, // ∅ \emptyset (cmsy10 59)
    .{ .cp = 0x2207, .w = 8.33, .h = 6.83332, .d = 0, .ic = 0 }, // ∇ \nabla (cmsy10 114)
    .{ .cp = 0x2208, .w = 6.67, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ∈ \in (cmsy10 50)
    .{ .cp = 0x2209, .w = 6.67, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ∉ \notin (composite: \not \in)
    .{ .cp = 0x220B, .w = 6.67, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ∋ \ni (cmsy10 51)
    .{ .cp = 0x220C, .w = 6.67, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ∌ \notni (composite: \not \ni)
    .{ .cp = 0x220F, .w = 9.44, .h = 0, .d = 10.00013, .ic = 0 }, // ∏ \prod
    .{ .cp = 0x2210, .w = 9.44, .h = 0, .d = 10.00013, .ic = 0 }, // ∐ \coprod
    .{ .cp = 0x2211, .w = 10.56, .h = 0, .d = 10.00013, .ic = 0 }, // ∑ \sum
    .{ .cp = 0x2212, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // − minus (cmsy10 161)
    .{ .cp = 0x2213, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ∓ \mp (cmsy10 168)
    .{ .cp = 0x2215, .w = 5.68, .h = 6.88889, .d = 1.94443, .ic = 0 }, // ╱ \diagup (msbm10 30)
    .{ .cp = 0x2216, .w = 5.68, .h = 7.5, .d = 2.5, .ic = 0 }, // ∖ \setminus (cmsy10 110)
    .{ .cp = 0x2217, .w = 5, .h = 4.65279, .d = -0.34721, .ic = 0 }, // ∗ \ast (cmsy10 164)
    .{ .cp = 0x2218, .w = 4.12, .h = 4.44446, .d = -0.55554, .ic = 0 }, // ∘ \circ (cmsy10 177)
    .{ .cp = 0x2219, .w = 5, .h = 4.44446, .d = -0.55554, .ic = 0 }, // ∙ \bullet (cmsy10 178)
    .{ .cp = 0x221A, .w = 8.33, .h = 0.39999, .d = 9.60001, .ic = 0 }, // √ \surd (cmsy10 112)
    .{ .cp = 0x221D, .w = 7.78, .h = 4.30555, .d = 0, .ic = 0 }, // ∝ \propto (cmsy10 47)
    .{ .cp = 0x221E, .w = 10, .h = 4.30555, .d = 0, .ic = 0 }, // ∞ \infty (cmsy10 49)
    .{ .cp = 0x2220, .w = 7.78, .h = 6.92241, .d = 0, .ic = 0 }, // ∠ \angle (msam10 92)
    .{ .cp = 0x2221, .w = 7.78, .h = 6.92241, .d = 0, .ic = 0 }, // ∡ \measuredangle (msam10 93)
    .{ .cp = 0x2222, .w = 7.78, .h = 5.22394, .d = 0.35173, .ic = 0 }, // ∢ \sphericalangle (msam10 94)
    .{ .cp = 0x2223, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ∣ \mid (cmsy10 106 \vert)
    .{ .cp = 0x2224, .w = 3.88, .h = 7.41110, .d = 2.51422, .ic = 0 }, // ∤ \nmid (msbm10 45)
    .{ .cp = 0x2225, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ∥ \parallel (cmsy10 107 \Vert)
    .{ .cp = 0x2226, .w = 5.56, .h = 7.41110, .d = 2.51422, .ic = 0 }, // ∦ \nparallel (msbm10 44)
    .{ .cp = 0x2227, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∧ \wedge (cmsy10 94)
    .{ .cp = 0x2228, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∨ \vee (cmsy10 95)
    .{ .cp = 0x2229, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∩ \cap (cmsy10 92)
    .{ .cp = 0x222A, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∪ \cup (cmsy10 91)
    .{ .cp = 0x222B, .w = 6.65, .h = 0, .d = 11.11122, .ic = 3.32 }, // ∫ \int
    .{ .cp = 0x222E, .w = 6.65, .h = 0, .d = 11.11122, .ic = 3.32 }, // ∮ \oint
    .{ .cp = 0x2234, .w = 5.16, .h = 6.92241, .d = 0, .ic = 0 }, // ∴ \therefore (msam10 41)
    .{ .cp = 0x2235, .w = 5.16, .h = 6.92241, .d = 0, .ic = 0 }, // ∵ \because (msam10 42)
    // The colon family: unicode-math-only glyphs (no CM slot), so the widths
    // and the ink-derived h/d are Latin Modern Math's (fontTools hmtx + CFF
    // bounds); all four sit with their ink between 0.078 and 0.422em above
    // the baseline, so d = 0.
    .{ .cp = 0x2236, .w = 2.78, .h = 4.22, .d = 0, .ic = 0 }, // ∶ \ratio (LM 0.278em)
    .{ .cp = 0x2237, .w = 5.16, .h = 4.22, .d = 0, .ic = 0 }, // ∷ \Colon (LM 0.516em)
    .{ .cp = 0x223C, .w = 7.73, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ∼ \sim (cmsy10 187)
    .{ .cp = 0x2240, .w = 2.8, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ≀ \wr (cmsy10 111)
    .{ .cp = 0x2241, .w = 7.73, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ≁ \nsim (msbm10 28)
    .{ .cp = 0x2243, .w = 7.78, .h = 4.63748, .d = -0.36252, .ic = 0 }, // ≃ \simeq (cmsy10 39)
    .{ .cp = 0x2244, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ≄ \nsimeq (composite: \not \simeq)
    .{ .cp = 0x2245, .w = 7.78, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ≅ \cong (sim+rule composite)
    .{ .cp = 0x2246, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ≆ \simneqq (composite: \not over ≃)
    .{ .cp = 0x2247, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ≇ \ncong (msbm10 29)
    .{ .cp = 0x2248, .w = 7.73, .h = 4.83122, .d = -0.16878, .ic = 0 }, // ≈ \approx (cmsy10 188)
    .{ .cp = 0x2249, .w = 7.73, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ≉ \napprox (composite: \not over ≈)
    .{ .cp = 0x224D, .w = 7.78, .h = 4.63748, .d = -0.36252, .ic = 0 }, // ≍ \asymp (cmsy10 179)
    .{ .cp = 0x2250, .w = 7.78, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ≐ \doteq (dot-over-= composite)
    .{ .cp = 0x2254, .w = 9.06, .h = 4.22, .d = 0, .ic = 0 }, // ⋔ \coloneqq (LM 0.906em)
    .{ .cp = 0x2255, .w = 9.06, .h = 4.22, .d = 0, .ic = 0 }, // ⋕ \coloneq (LM 0.906em)
    .{ .cp = 0x2260, .w = 7.78, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ≠ \ne (composite: \not over =)
    .{ .cp = 0x2261, .w = 7.78, .h = 4.63748, .d = -0.36252, .ic = 0 }, // ≡ \equiv (cmsy10 180)
    .{ .cp = 0x2262, .w = 7.78, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ≢ \not\equiv (composite: \not over ≡)
    .{ .cp = 0x2264, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ≤ \leq (cmsy10 183)
    .{ .cp = 0x2265, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ≥ \geq (cmsy10 184)
    .{ .cp = 0x2266, .w = 7.78, .h = 7.55834, .d = 2.55834, .ic = 0 }, // ≦ \leqq (msam10 53)
    .{ .cp = 0x2267, .w = 7.78, .h = 7.55834, .d = 2.55834, .ic = 0 }, // ≧ \geqq (msam10 61)
    .{ .cp = 0x226A, .w = 10, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ≪ \ll (cmsy10 191)
    .{ .cp = 0x226B, .w = 10, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ≫ \gg (cmsy10 192)
    .{ .cp = 0x226D, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ≭ \nasymp (composite: \not \asymp)
    .{ .cp = 0x226E, .w = 7.78, .h = 7.05765, .d = 2.05765, .ic = 0 }, // ≮ \nless (msbm10 165)
    .{ .cp = 0x226F, .w = 7.78, .h = 7.05765, .d = 2.05765, .ic = 0 }, // ≯ \ngtr (msbm10 166)
    .{ .cp = 0x2270, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ≰ \nleq (msbm10 2)
    .{ .cp = 0x2271, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ≱ \ngeq (msbm10 3)
    .{ .cp = 0x227A, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ≺ \prec (cmsy10 193)
    .{ .cp = 0x227B, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ≻ \succ (cmsy10 194)
    .{ .cp = 0x2280, .w = 7.78, .h = 7.05765, .d = 2.05765, .ic = 0 }, // ⊀ \nprec (msbm10 167)
    .{ .cp = 0x2281, .w = 7.78, .h = 7.05765, .d = 2.05765, .ic = 0 }, // ⊁ \nsucc (msbm10 168)
    .{ .cp = 0x2282, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ⊂ \subset (cmsy10 189)
    .{ .cp = 0x2283, .w = 7.78, .h = 5.39098, .d = 0.39098, .ic = 0 }, // ⊃ \supset (cmsy10 190)
    .{ .cp = 0x2284, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ⊄ \nsubset (composite: \not \subset)
    .{ .cp = 0x2285, .w = 7.78, .h = 6.94444, .d = 1.94443, .ic = 0 }, // ⊅ \nsupset (composite: \not \supset)
    .{ .cp = 0x2286, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⊆ \subseteq (cmsy10 181)
    .{ .cp = 0x2287, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⊇ \supseteq (cmsy10 182)
    .{ .cp = 0x2288, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ⊈ \nsubseteq (msbm10 42)
    .{ .cp = 0x2289, .w = 7.78, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ⊉ \nsupseteq (msbm10 43)
    .{ .cp = 0x228E, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊎ \uplus (cmsy10 93)
    .{ .cp = 0x2291, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⊑ \sqsubseteq (cmsy10 118)
    .{ .cp = 0x2292, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⊒ \sqsupseteq (cmsy10 119)
    .{ .cp = 0x2293, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊓ \sqcap (cmsy10 117)
    .{ .cp = 0x2294, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊔ \sqcup (cmsy10 116)
    .{ .cp = 0x2295, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊕ \oplus (cmsy10 169)
    .{ .cp = 0x2296, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊖ \ominus (cmsy10 170)
    .{ .cp = 0x2297, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊗ \otimes (cmsy10 171)
    .{ .cp = 0x2298, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊘ \oslash (cmsy10 174)
    .{ .cp = 0x2299, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⊙ \odot (cmsy10 175)
    .{ .cp = 0x22A2, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ⊢ \vdash (cmsy10 96)
    .{ .cp = 0x22A3, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ⊣ \dashv (cmsy10 97)
    .{ .cp = 0x22A4, .w = 7.78, .h = 6.94445, .d = 0, .ic = 0 }, // ⊤ \top (cmsy10 62)
    .{ .cp = 0x22A5, .w = 7.78, .h = 6.94445, .d = 0, .ic = 0 }, // ⊥ \perp (cmsy10 63)
    .{ .cp = 0x22A8, .w = 6.12, .h = 6.92241, .d = 0, .ic = 0 }, // ⊨ \vDash (msam10 178)
    .{ .cp = 0x22AC, .w = 5.65, .h = 6.88889, .d = 0, .ic = 0 }, // ⊬ \nvdash (msbm10 48)
    .{ .cp = 0x22C0, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⋀ \bigwedge (cmex10 86)
    .{ .cp = 0x22C1, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⋁ \bigvee (cmex10 87)
    .{ .cp = 0x22C2, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⋂ \bigcap
    .{ .cp = 0x22C3, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⋃ \bigcup
    .{ .cp = 0x22C4, .w = 5, .h = 4.44446, .d = -0.55554, .ic = 0.08 }, // ⋄ \diamond (cmsy10 166)
    .{ .cp = 0x22C5, .w = 2.78, .h = 2.5, .d = 0, .ic = 0 }, // ⋅ \cdot (cmsy10 middle dot)
    .{ .cp = 0x22C6, .w = 5, .h = 4.65279, .d = -0.34721, .ic = 0.25 }, // ⋆ \star (cmmi10 63)
    .{ .cp = 0x22C8, .w = 6.23, .h = 4.65279, .d = -0.34721, .ic = 0 }, // ⋈ \bowtie (composite: ▹ \joinrel ◃)
    .{ .cp = 0x22D8, .w = 12.85, .h = 5.4986, .d = 0.35173, .ic = 0 }, // ⋘ \lll (msam10 110)
    .{ .cp = 0x22D9, .w = 12.85, .h = 5.4986, .d = 0.35173, .ic = 0 }, // ⋙ \ggg (msam10 111)
    .{ .cp = 0x22E0, .w = 7.38, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ⋠ \npreceq (msbm10 177)
    .{ .cp = 0x22E1, .w = 7.38, .h = 7.93829, .d = 3.02742, .ic = 0 }, // ⋡ \nsucceq (msbm10 178)
    .{ .cp = 0x22EF, .w = 7.76, .h = 4.44446, .d = -0.55554, .ic = 0 }, // ⋯ \cdots (composite: 3 × cdot)
    .{ .cp = 0x2308, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌈ \lceil (cmsy10 100)
    .{ .cp = 0x2309, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌉ \rceil (cmsy10 101)
    .{ .cp = 0x230A, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌊ \lfloor (cmsy10 98)
    .{ .cp = 0x230B, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌋ \rfloor (cmsy10 99)
    .{ .cp = 0x2322, .w = 10, .h = 3.57640, .d = -1.42360, .ic = 0 }, // ⌢ \frown (cmmi10 95)
    .{ .cp = 0x2323, .w = 10, .h = 3.57640, .d = -1.42360, .ic = 0 }, // ⌣ \smile (cmmi10 94)
    .{ .cp = 0x25A0, .w = 7.78, .h = 6.75, .d = 0, .ic = 0 }, // ■ \blacksquare (msam10 4)
    .{ .cp = 0x25A1, .w = 7.78, .h = 6.75, .d = 0, .ic = 0 }, // □ \square (msam10 3)
    .{ .cp = 0x25B3, .w = 9.68, .h = 6.94445, .d = 1.94445, .ic = 0 }, // △ \triangle (cmsy10 52)
    .{ .cp = 0x25B9, .w = 5.00002, .h = 4.65279, .d = -0.34721, .ic = 0 }, // ▹ \triangleright (cmmi10 46)
    .{ .cp = 0x25BD, .w = 9.68, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ▽ \bigtriangledown (cmsy10 53)
    .{ .cp = 0x25C3, .w = 5.00002, .h = 4.65279, .d = -0.34721, .ic = 0 }, // ◃ \triangleleft (cmmi10 47)
    .{ .cp = 0x25CA, .w = 5.72, .h = 6.92241, .d = 1.11112, .ic = 0 }, // ◊ \lozenge (msam10 6)
    .{ .cp = 0x25CB, .w = 7.96, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ○ \bigcirc (cmsy10 176)
    .{ .cp = 0x2660, .w = 7.78, .h = 6.94445, .d = 1.29629, .ic = 0 }, // ♠ \spadesuit (cmsy10 127)
    .{ .cp = 0x2661, .w = 7.78, .h = 6.94445, .d = 1.29629, .ic = 0 }, // ♡ \heartsuit (cmsy10 126)
    .{ .cp = 0x2662, .w = 7.78, .h = 6.94445, .d = 1.29629, .ic = 0 }, // ♢ \diamondsuit (cmsy10 125)
    .{ .cp = 0x2663, .w = 7.78, .h = 6.94445, .d = 1.29629, .ic = 0 }, // ♣ \clubsuit (cmsy10 124)
    .{ .cp = 0x266D, .w = 3.88, .h = 7.5, .d = 0, .ic = 0 }, // ♭ \flat (cmmi10 91)
    .{ .cp = 0x266E, .w = 3.88, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ♮ \natural (cmmi10 92)
    .{ .cp = 0x266F, .w = 3.88, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ♯ \sharp (cmmi10 93)
    .{ .cp = 0x2713, .w = 8.33, .h = 6.92241, .d = 0, .ic = 0 }, // ✓ \checkmark (msam10 88)
    .{ .cp = 0x27E8, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟨ \langle (cmsy10 104)
    .{ .cp = 0x27E9, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟩ \rangle (cmsy10 105)
    .{ .cp = 0x27F5, .w = 14.63, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟵ \longleftarrow (← \joinrel \relbar)
    .{ .cp = 0x27F6, .w = 14.63, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟶ \longrightarrow (relbar joinrel)
    .{ .cp = 0x27F7, .w = 14.42, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟷ longleftrightarrow (joinrel)
    .{ .cp = 0x27F8, .w = 14.57, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟸ \Longleftarrow (⇐ \joinrel \Relbar)
    .{ .cp = 0x27F9, .w = 14.57, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟹ \Longrightarrow (Relbar joinrel)
    .{ .cp = 0x27FA, .w = 15.34, .h = 3.66875, .d = -1.33125, .ic = 0 }, // ⟺ \Longleftrightarrow (joinrel)
    .{ .cp = 0x2912, .w = 5.00002, .h = 6.94445, .d = 1.94443, .ic = 0 }, // ⤒ \baruparrow (bar over ↑, cmsy10 34)
    .{ .cp = 0x29EB, .w = 6.66669, .h = 6.92241, .d = 1.11112, .ic = 0 }, // ⧫ \blacklozenge (msam10 7)
    .{ .cp = 0x2A00, .w = 11.11, .h = 0, .d = 10.00013, .ic = 0 }, // ⨀ \bigodot (cmex10 74)
    .{ .cp = 0x2A01, .w = 11.11, .h = 0, .d = 10.00013, .ic = 0 }, // ⨁ \bigoplus (cmex10 76)
    .{ .cp = 0x2A02, .w = 11.11, .h = 0, .d = 10.00013, .ic = 0 }, // ⨂ \bigotimes (cmex10 78)
    .{ .cp = 0x2A04, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⨄ \biguplus (cmex10 85)
    .{ .cp = 0x2A05, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⨅ \bigsqcap (stmary10 132)
    .{ .cp = 0x2A06, .w = 8.33, .h = 0, .d = 10.00013, .ic = 0 }, // ⨆ \bigsqcup
    .{ .cp = 0x2A2F, .w = 7.78, .h = 5.83334, .d = 0.83334, .ic = 0 }, // ⨯ \times (cmsy10 2)
    .{ .cp = 0x2A3F, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // ⨿ \amalg (cmsy10 113)
    .{ .cp = 0x2A7D, .w = 7.78, .h = 6.36665, .d = 1.36665, .ic = 0 }, // ⩽ \leqslant (msam10 54)
    .{ .cp = 0x2A7E, .w = 7.78, .h = 6.36665, .d = 1.36665, .ic = 0 }, // ⩾ \geqslant (msam10 62)
    .{ .cp = 0x2AAF, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⪯ \preceq (cmsy10 185)
    .{ .cp = 0x2AB0, .w = 7.78, .h = 6.35971, .d = 1.35971, .ic = 0 }, // ⪰ \succeq (cmsy10 186)
    .{ .cp = 0x1D434, .w = 7.5, .h = 6.83332, .d = 0, .ic = 0 }, // 𝐴
    .{ .cp = 0x1D435, .w = 7.59, .h = 6.83332, .d = 0, .ic = 0.50173 }, // 𝐵
    .{ .cp = 0x1D436, .w = 7.15, .h = 6.83332, .d = 0, .ic = 0.715275 }, // 𝐶
    .{ .cp = 0x1D437, .w = 8.28, .h = 6.83332, .d = 0, .ic = 0.27779 }, // 𝐷
    .{ .cp = 0x1D438, .w = 7.38, .h = 6.83332, .d = 0, .ic = 0.57638 }, // 𝐸
    .{ .cp = 0x1D439, .w = 6.43, .h = 6.83332, .d = 0, .ic = 1.3889 }, // 𝐹
    .{ .cp = 0x1D43A, .w = 7.86, .h = 6.83332, .d = 0, .ic = 0 }, // 𝐺
    .{ .cp = 0x1D43B, .w = 8.31, .h = 6.83332, .d = 0, .ic = 0.81248 }, // 𝐻
    .{ .cp = 0x1D43C, .w = 4.4, .h = 6.83332, .d = 0, .ic = 0.78471 }, // 𝐼
    .{ .cp = 0x1D43D, .w = 5.55, .h = 6.83332, .d = 0, .ic = 0.96181 }, // 𝐽
    .{ .cp = 0x1D43E, .w = 8.49, .h = 6.83332, .d = 0, .ic = 0.715275 }, // 𝐾
    .{ .cp = 0x1D43F, .w = 6.81, .h = 6.83332, .d = 0, .ic = 0 }, // 𝐿
    .{ .cp = 0x1D440, .w = 9.7, .h = 6.83332, .d = 0, .ic = 1.09027 }, // 𝑀
    .{ .cp = 0x1D441, .w = 8.03, .h = 6.83332, .d = 0, .ic = 1.09027 }, // 𝑁
    .{ .cp = 0x1D442, .w = 7.63, .h = 6.83332, .d = 0, .ic = 0.27779 }, // 𝑂
    .{ .cp = 0x1D443, .w = 6.42, .h = 6.83332, .d = 0, .ic = 1.3889 }, // 𝑃
    .{ .cp = 0x1D444, .w = 7.91, .h = 6.83332, .d = 1.94445, .ic = 0 }, // 𝑄
    .{ .cp = 0x1D445, .w = 7.59, .h = 6.83332, .d = 0, .ic = 0.24 }, // 𝑅
    .{ .cp = 0x1D446, .w = 6.13, .h = 6.83332, .d = 0, .ic = 0.57638 }, // 𝑆
    .{ .cp = 0x1D447, .w = 5.84, .h = 6.83332, .d = 0, .ic = 1.3889 }, // 𝑇
    .{ .cp = 0x1D448, .w = 6.83, .h = 6.83332, .d = 0, .ic = 1.09027 }, // 𝑈
    .{ .cp = 0x1D449, .w = 5.83, .h = 6.83332, .d = 0, .ic = 0.08 }, // 𝑉
    .{ .cp = 0x1D44A, .w = 9.44, .h = 6.83332, .d = 0, .ic = 0.09 }, // 𝑊
    .{ .cp = 0x1D44B, .w = 8.28, .h = 6.83332, .d = 0, .ic = 0.04 }, // 𝑋
    .{ .cp = 0x1D44C, .w = 5.81, .h = 6.83332, .d = 0, .ic = 0.16 }, // 𝑌
    .{ .cp = 0x1D44D, .w = 6.83, .h = 6.83332, .d = 0, .ic = 0.715275 }, // 𝑍
    .{ .cp = 0x1D44E, .w = 5.29, .h = 4.30555, .d = 0, .ic = 0.11 }, // 𝑎
    .{ .cp = 0x1D44F, .w = 4.29, .h = 6.94445, .d = 0, .ic = 0 }, // 𝑏
    .{ .cp = 0x1D450, .w = 4.33, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑐
    .{ .cp = 0x1D451, .w = 5.2, .h = 6.94445, .d = 0, .ic = 0 }, // 𝑑
    .{ .cp = 0x1D452, .w = 4.66, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑒
    .{ .cp = 0x1D453, .w = 4.9, .h = 6.94445, .d = 1.94445, .ic = 0.79 }, // 𝑓
    .{ .cp = 0x1D454, .w = 4.77, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // 𝑔
    .{ .cp = 0x1D456, .w = 3.45, .h = 6.59525, .d = 0, .ic = 0 }, // 𝑖
    .{ .cp = 0x1D457, .w = 4.12, .h = 6.59525, .d = 1.94445, .ic = 0.57243 }, // 𝑗
    .{ .cp = 0x1D458, .w = 5.21, .h = 6.94445, .d = 0, .ic = 0.11 }, // 𝑘
    .{ .cp = 0x1D459, .w = 2.98, .h = 6.94445, .d = 0, .ic = 0.05 }, // 𝑙
    .{ .cp = 0x1D45A, .w = 8.78, .h = 4.30555, .d = 0, .ic = 0.08 }, // 𝑚
    .{ .cp = 0x1D45B, .w = 6, .h = 4.30555, .d = 0, .ic = 0.07 }, // 𝑛
    .{ .cp = 0x1D45C, .w = 4.85, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑜
    .{ .cp = 0x1D45D, .w = 5.03, .h = 4.30555, .d = 1.94445, .ic = 0 }, // 𝑝
    .{ .cp = 0x1D45E, .w = 4.46, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // 𝑞
    .{ .cp = 0x1D45F, .w = 4.51, .h = 4.30555, .d = 0, .ic = 0.27779 }, // 𝑟
    .{ .cp = 0x1D460, .w = 4.69, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑠
    .{ .cp = 0x1D461, .w = 3.61, .h = 6.1508, .d = 0, .ic = 0 }, // 𝑡
    .{ .cp = 0x1D462, .w = 5.72, .h = 4.30555, .d = 0, .ic = 0.07 }, // 𝑢
    .{ .cp = 0x1D463, .w = 4.85, .h = 4.30555, .d = 0, .ic = 0.08 }, // 𝑣
    .{ .cp = 0x1D464, .w = 7.16, .h = 4.30555, .d = 0, .ic = 0.09 }, // 𝑤
    .{ .cp = 0x1D465, .w = 5.72, .h = 4.30555, .d = 0, .ic = 0.16 }, // 𝑥
    .{ .cp = 0x1D466, .w = 4.9, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // 𝑦
    .{ .cp = 0x1D467, .w = 4.65, .h = 4.30555, .d = 0, .ic = 0.43981 }, // 𝑧
    // Math-italic partial U+1D715 (the math-style form of \partial, mapped
    // by layout.mathItalic like the letters): LM Math advance 0.531em (the
    // upright U+2202 is 0.586em — the DIFFERENT glyph the reference emits),
    // h/d/ic from the U+2202 rows (same cmmi10 design slot).
    .{ .cp = 0x1D715, .w = 5.31, .h = 6.94445, .d = 0, .ic = 0.55555 }, // 𝜕
};

/// Blackboard (`\mathbb`) double-struck metrics: LM Math advances/ink for
/// the U+1D538..U+1D56B (double-struck capitals/smalls) and U+1D7D8..U+1D7E1
/// (double-struck digits) series plus the Letterlike ℂ/ℍ/ℕ/ℙ/ℚ/ℝ/ℤ. layout
/// maps `.bb` style chars to these codepoints (layout.mathBb); this table
/// lets the no-font static path validate the mapped cp (hasGlyph) and box
/// it by the real LM Math advance. Values em × 10 (10pt-base convention),
/// sorted by `cp` (binary-search invariant); measured on latinmodern-math.otf
/// 2.005 with fontTools (hmtx advance, BoundsPen ink h/d).
const table_bb = [_]Entry{
    .{ .cp = 0x2102, .w = 6.70, .h = 7.00, .d = 0.20, .ic = 0 }, // bb C
    .{ .cp = 0x210D, .w = 7.20, .h = 6.80, .d = 0.00, .ic = 0 }, // bb H
    .{ .cp = 0x2115, .w = 7.20, .h = 6.80, .d = 0.00, .ic = 0 }, // bb N
    .{ .cp = 0x2119, .w = 6.40, .h = 6.80, .d = 0.00, .ic = 0 }, // bb P
    .{ .cp = 0x211A, .w = 6.70, .h = 7.00, .d = 1.90, .ic = 0 }, // bb Q
    .{ .cp = 0x211D, .w = 6.40, .h = 6.80, .d = 0.00, .ic = 0 }, // bb R
    .{ .cp = 0x2124, .w = 6.70, .h = 6.80, .d = 0.00, .ic = 0 }, // bb Z
    .{ .cp = 0x1D538, .w = 6.10, .h = 6.80, .d = 0.00, .ic = 0 }, // bb A
    .{ .cp = 0x1D539, .w = 6.40, .h = 6.80, .d = 0.00, .ic = 0 }, // bb B
    .{ .cp = 0x1D53B, .w = 6.90, .h = 6.80, .d = 0.00, .ic = 0 }, // bb D
    .{ .cp = 0x1D53C, .w = 6.10, .h = 6.80, .d = 0.00, .ic = 0 }, // bb E
    .{ .cp = 0x1D53D, .w = 6.10, .h = 6.80, .d = 0.00, .ic = 0 }, // bb F
    .{ .cp = 0x1D53E, .w = 6.70, .h = 7.00, .d = 0.20, .ic = 0 }, // bb G
    .{ .cp = 0x1D540, .w = 3.30, .h = 6.80, .d = 0.00, .ic = 0 }, // bb I
    .{ .cp = 0x1D541, .w = 6.40, .h = 6.80, .d = 0.20, .ic = 0 }, // bb J
    .{ .cp = 0x1D542, .w = 6.40, .h = 6.80, .d = 0.00, .ic = 0 }, // bb K
    .{ .cp = 0x1D543, .w = 6.10, .h = 6.80, .d = 0.00, .ic = 0 }, // bb L
    .{ .cp = 0x1D544, .w = 7.20, .h = 6.80, .d = 0.00, .ic = 0 }, // bb M
    .{ .cp = 0x1D546, .w = 6.70, .h = 7.00, .d = 0.20, .ic = 0 }, // bb O
    .{ .cp = 0x1D54A, .w = 6.10, .h = 7.00, .d = 0.20, .ic = 0 }, // bb S
    .{ .cp = 0x1D54B, .w = 6.10, .h = 6.80, .d = 0.00, .ic = 0 }, // bb T
    .{ .cp = 0x1D54C, .w = 7.20, .h = 6.80, .d = 0.20, .ic = 0 }, // bb U
    .{ .cp = 0x1D54D, .w = 6.10, .h = 6.80, .d = 0.00, .ic = 0 }, // bb V
    .{ .cp = 0x1D54E, .w = 8.30, .h = 6.80, .d = 0.00, .ic = 0 }, // bb W
    .{ .cp = 0x1D54F, .w = 6.70, .h = 6.80, .d = 0.00, .ic = 0 }, // bb X
    .{ .cp = 0x1D550, .w = 6.10, .h = 6.80, .d = 0.00, .ic = 0 }, // bb Y
    .{ .cp = 0x1D552, .w = 5.00, .h = 4.50, .d = 0.20, .ic = 0 }, // bb a
    .{ .cp = 0x1D553, .w = 6.30, .h = 6.90, .d = 0.20, .ic = 0 }, // bb b
    .{ .cp = 0x1D554, .w = 4.70, .h = 4.50, .d = 0.20, .ic = 0 }, // bb c
    .{ .cp = 0x1D555, .w = 5.00, .h = 6.90, .d = 0.20, .ic = 0 }, // bb d
    .{ .cp = 0x1D556, .w = 4.70, .h = 4.50, .d = 0.20, .ic = 0 }, // bb e
    .{ .cp = 0x1D557, .w = 3.90, .h = 7.20, .d = 0.00, .ic = 0 }, // bb f
    .{ .cp = 0x1D558, .w = 5.00, .h = 4.50, .d = 2.20, .ic = 0 }, // bb g
    .{ .cp = 0x1D559, .w = 5.70, .h = 6.90, .d = 0.00, .ic = 0 }, // bb h
    .{ .cp = 0x1D55A, .w = 2.80, .h = 6.90, .d = 0.00, .ic = 0 }, // bb i
    .{ .cp = 0x1D55B, .w = 3.90, .h = 6.90, .d = 2.20, .ic = 0 }, // bb j
    .{ .cp = 0x1D55C, .w = 5.40, .h = 6.90, .d = 0.00, .ic = 0 }, // bb k
    .{ .cp = 0x1D55D, .w = 2.80, .h = 6.90, .d = 0.00, .ic = 0 }, // bb l
    .{ .cp = 0x1D55E, .w = 7.20, .h = 4.50, .d = 0.00, .ic = 0 }, // bb m
    .{ .cp = 0x1D55F, .w = 5.70, .h = 4.50, .d = 0.00, .ic = 0 }, // bb n
    .{ .cp = 0x1D560, .w = 4.70, .h = 4.50, .d = 0.20, .ic = 0 }, // bb o
    .{ .cp = 0x1D561, .w = 6.30, .h = 4.50, .d = 1.90, .ic = 0 }, // bb p
    .{ .cp = 0x1D562, .w = 5.00, .h = 4.50, .d = 1.90, .ic = 0 }, // bb q
    .{ .cp = 0x1D563, .w = 5.40, .h = 4.50, .d = 0.00, .ic = 0 }, // bb r
    .{ .cp = 0x1D564, .w = 3.90, .h = 4.50, .d = 0.20, .ic = 0 }, // bb s
    .{ .cp = 0x1D565, .w = 4.20, .h = 6.90, .d = 0.20, .ic = 0 }, // bb t
    .{ .cp = 0x1D566, .w = 5.30, .h = 4.30, .d = 0.20, .ic = 0 }, // bb u
    .{ .cp = 0x1D567, .w = 4.70, .h = 4.30, .d = 0.00, .ic = 0 }, // bb v
    .{ .cp = 0x1D568, .w = 6.70, .h = 4.30, .d = 0.00, .ic = 0 }, // bb w
    .{ .cp = 0x1D569, .w = 4.70, .h = 4.30, .d = 0.00, .ic = 0 }, // bb x
    .{ .cp = 0x1D56A, .w = 4.70, .h = 4.30, .d = 2.20, .ic = 0 }, // bb y
    .{ .cp = 0x1D56B, .w = 4.70, .h = 4.30, .d = 0.00, .ic = 0 }, // bb z
    .{ .cp = 0x1D7D8, .w = 5.60, .h = 6.70, .d = 0.20, .ic = 0 }, // bb 0
    .{ .cp = 0x1D7D9, .w = 5.60, .h = 6.40, .d = 0.00, .ic = 0 }, // bb 1
    .{ .cp = 0x1D7DA, .w = 5.60, .h = 6.70, .d = 0.00, .ic = 0 }, // bb 2
    .{ .cp = 0x1D7DB, .w = 5.60, .h = 6.70, .d = 0.20, .ic = 0 }, // bb 3
    .{ .cp = 0x1D7DC, .w = 5.60, .h = 6.40, .d = 0.00, .ic = 0 }, // bb 4
    .{ .cp = 0x1D7DD, .w = 5.60, .h = 6.40, .d = 0.20, .ic = 0 }, // bb 5
    .{ .cp = 0x1D7DE, .w = 5.60, .h = 6.70, .d = 0.20, .ic = 0 }, // bb 6
    .{ .cp = 0x1D7DF, .w = 5.60, .h = 6.40, .d = 0.00, .ic = 0 }, // bb 7
    .{ .cp = 0x1D7E0, .w = 5.60, .h = 6.70, .d = 0.20, .ic = 0 }, // bb 8
    .{ .cp = 0x1D7E1, .w = 5.60, .h = 6.70, .d = 0.20, .ic = 0 }, // bb 9
};

/// Script-size metric table (design size 7pt), same convention as `table`:
/// TFM em-relative values x 10, so the layout's `size_pt/10` scaling yields
/// the real 7pt points. LM Math is a single 10pt-design OTF with no optical
/// 7pt variant, so every row carries the same LM Math advance as `table`
/// (em × 10) and the layout's size_pt/10 factor produces exactly LM advance
/// × 0.7 at 7pt — linear scaling replaces the old optical cmr7/cmmi7/cmsy7
/// values, which are kept in history. Sorted by `cp`.
const table7 = [_]Entry{
    .{ .cp = 0x21, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0 }, // !
    .{ .cp = 0x28, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // (
    .{ .cp = 0x29, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // )
    .{ .cp = 0x2B, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // +
    .{ .cp = 0x2C, .w = 2.78, .h = 1.1508, .d = 1.94445, .ic = 0 }, // ,
    .{ .cp = 0x2D, .w = 3.33, .h = 6.19049, .d = 1.19049, .ic = 0 }, // - (cmsy10 minus)
    .{ .cp = 0x2E, .w = 2.78, .h = 1.1508, .d = 0, .ic = 0 }, // .
    .{ .cp = 0x2F, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // /
    .{ .cp = 0x30, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 0
    .{ .cp = 0x31, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 1
    .{ .cp = 0x32, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 2
    .{ .cp = 0x33, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 3
    .{ .cp = 0x34, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 4
    .{ .cp = 0x35, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 5
    .{ .cp = 0x36, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 6
    .{ .cp = 0x37, .w = 5, .h = 6.44444, .d = 0, .ic = 0.13 }, // 7
    .{ .cp = 0x38, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 8
    .{ .cp = 0x39, .w = 5, .h = 6.44444, .d = 0, .ic = 0 }, // 9
    .{ .cp = 0x3A, .w = 2.78, .h = 4.30555, .d = 0, .ic = 0 }, // :
    .{ .cp = 0x3B, .w = 2.78, .h = 4.30555, .d = 1.94445, .ic = 0 }, // ;
    .{ .cp = 0x3C, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // < (cmmi10)
    .{ .cp = 0x3D, .w = 7.78, .h = 3.84079, .d = -1.15921, .ic = 0 }, // =
    .{ .cp = 0x3E, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // > (cmmi10)
    .{ .cp = 0x41, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x42, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0.48684 }, // B
    .{ .cp = 0x43, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0.70038 }, // C
    .{ .cp = 0x44, .w = 7.64, .h = 6.83334, .d = 0, .ic = 0.30755 }, // D
    .{ .cp = 0x45, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0.5496 }, // E
    .{ .cp = 0x46, .w = 6.53, .h = 6.83334, .d = 0, .ic = 1.53771 }, // F
    .{ .cp = 0x47, .w = 7.85, .h = 6.83334, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x48, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.76486 }, // H
    .{ .cp = 0x49, .w = 3.61, .h = 6.83334, .d = 0, .ic = 0.77728 }, // I
    .{ .cp = 0x4A, .w = 5.14, .h = 6.83334, .d = 0, .ic = 0.94345 }, // J
    .{ .cp = 0x4B, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0.70038 }, // K
    .{ .cp = 0x4C, .w = 6.25, .h = 6.83334, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x4D, .w = 9.17, .h = 6.83334, .d = 0, .ic = 1.07241 }, // M
    .{ .cp = 0x4E, .w = 7.5, .h = 6.83334, .d = 0, .ic = 1.07241 }, // N
    .{ .cp = 0x4F, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0.30755 }, // O
    .{ .cp = 0x50, .w = 6.81, .h = 6.83334, .d = 0, .ic = 1.53771 }, // P
    .{ .cp = 0x51, .w = 7.78, .h = 6.83334, .d = 1.94445, .ic = 0 }, // Q
    .{ .cp = 0x52, .w = 7.36, .h = 6.83334, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x53, .w = 5.56, .h = 6.83334, .d = 0, .ic = 0.54662 }, // S
    .{ .cp = 0x54, .w = 7.22, .h = 6.83334, .d = 0, .ic = 1.53771 }, // T
    .{ .cp = 0x55, .w = 7.5, .h = 6.83334, .d = 0, .ic = 1.07241 }, // U
    .{ .cp = 0x56, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x57, .w = 10.28, .h = 6.83334, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x58, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x59, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x5A, .w = 6.11, .h = 6.83334, .d = 0, .ic = 0.70038 }, // Z
    .{ .cp = 0x5B, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0.06 }, // [
    .{ .cp = 0x5D, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ]
    .{ .cp = 0x61, .w = 5, .h = 4.30555, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x62, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x63, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x64, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x65, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x66, .w = 3.06, .h = 6.94445, .d = 1.94445, .ic = 0.79 }, // f
    .{ .cp = 0x67, .w = 5, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // g
    .{ .cp = 0x68, .w = 5.56, .h = 6.94445, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x69, .w = 2.78, .h = 6.61706, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x6A, .w = 3.06, .h = 6.61706, .d = 1.94445, .ic = 0.57787 }, // j
    .{ .cp = 0x6B, .w = 5.28, .h = 6.94445, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x6C, .w = 2.78, .h = 6.94445, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x6D, .w = 8.33, .h = 4.30555, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x6E, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x6F, .w = 5, .h = 4.30555, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x70, .w = 5.56, .h = 4.30555, .d = 1.94445, .ic = 0 }, // p
    .{ .cp = 0x71, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // q
    .{ .cp = 0x72, .w = 3.92, .h = 4.30555, .d = 0, .ic = 0.30755 }, // r
    .{ .cp = 0x73, .w = 3.94, .h = 4.30555, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x74, .w = 3.89, .h = 6.1508, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x75, .w = 5.56, .h = 4.30555, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x76, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x77, .w = 7.22, .h = 4.30555, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x78, .w = 5.28, .h = 4.30555, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x79, .w = 5.28, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // y
    .{ .cp = 0x7A, .w = 4.44, .h = 4.30555, .d = 0, .ic = 0.41005 }, // z
    .{ .cp = 0x7B, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // { (cmsy10)
    .{ .cp = 0x7C, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // | (cmsy10)
    .{ .cp = 0x7D, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // } (cmsy10)
    .{ .cp = 0x00B1, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ± \pm (cmsy10 167)
    .{ .cp = 0x00B7, .w = 2.78, .h = 4.6528, .d = -0.3472, .ic = 0 }, // · middle dot (cmsy10, same as U+22C5 ⋅)
    .{ .cp = 0x00D7, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // × \times (cmsy10 163)
    .{ .cp = 0x00F7, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ÷ \div (cmsy10 165)
    .{ .cp = 0x391, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // Α
    .{ .cp = 0x392, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0.48684 }, // Β
    .{ .cp = 0x393, .w = 6.25, .h = 6.83334, .d = 0, .ic = 0 }, // Γ (cmr10 slot 161)
    .{ .cp = 0x394, .w = 8.33, .h = 6.83334, .d = 0, .ic = 0 }, // Δ (cmr10 slot 162)
    .{ .cp = 0x398, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0 }, // Θ (cmr10 slot 163)
    .{ .cp = 0x39B, .w = 6.94, .h = 6.83334, .d = 0, .ic = 0 }, // Λ (cmr10 slot 164)
    .{ .cp = 0x3A0, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // Π (cmr10 slot 166)
    .{ .cp = 0x3A3, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0 }, // Σ (cmr10 slot 167)
    .{ .cp = 0x3A6, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0 }, // Φ (cmr10 slot 169)
    .{ .cp = 0x3A9, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0 }, // Ω (cmr10 slot 171)
    .{ .cp = 0x3B1, .w = 6.41, .h = 4.30555, .d = 0, .ic = 0.24 }, // α
    .{ .cp = 0x3B2, .w = 5.58, .h = 6.94445, .d = 1.94445, .ic = 0.5139 }, // β
    .{ .cp = 0x3B3, .w = 5.86, .h = 4.30555, .d = 1.94445, .ic = 0.61508 }, // γ
    .{ .cp = 0x3B4, .w = 4.74, .h = 6.94445, .d = 0, .ic = 0.3626 }, // δ
    .{ .cp = 0x3B5, .w = 5.35, .h = 4.30555, .d = 0, .ic = 0 }, // ε
    .{ .cp = 0x3B8, .w = 4.88, .h = 6.94445, .d = 0, .ic = 0.30755 }, // θ
    .{ .cp = 0x3BB, .w = 5.37, .h = 6.94445, .d = 0, .ic = 0.54 }, // λ
    .{ .cp = 0x3BC, .w = 5.3, .h = 4.30555, .d = 1.94445, .ic = 0.23 }, // μ
    .{ .cp = 0x3C0, .w = 5.86, .h = 4.30555, .d = 0, .ic = 0.3588 }, // π
    .{ .cp = 0x3C3, .w = 5.99, .h = 4.30555, .d = 0, .ic = 0.3588 }, // σ
    .{ .cp = 0x3C6, .w = 6.41, .h = 6.94445, .d = 1.94445, .ic = 0 }, // φ
    .{ .cp = 0x3C9, .w = 6.41, .h = 4.30555, .d = 0, .ic = 0.3588 }, // ω
    .{ .cp = 0x2020, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // † \dagger (cmsy10 121)
    .{ .cp = 0x2021, .w = 4.44, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ‡ \ddagger (cmsy10 122)
    .{ .cp = 0x2032, .w = 3.11, .h = 5.55557, .d = 0, .ic = 0 }, // ′ \prime (cmsy10 48)
    .{ .cp = 0x2033, .w = 5.11, .h = 5.55557, .d = 0, .ic = 0 }, // ″ composite: 2 × \prime
    .{ .cp = 0x210E, .w = 5.76, .h = 6.94445, .d = 0, .ic = 0.07 }, // ℎ
    .{ .cp = 0x2190, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ← \leftarrow (cmsy10 195)
    .{ .cp = 0x2191, .w = 5, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↑ \uparrow (cmsy10 34)
    .{ .cp = 0x2192, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // → \rightarrow (cmsy10 33)
    .{ .cp = 0x2193, .w = 5, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↓ \downarrow (cmsy10 35)
    .{ .cp = 0x2194, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ↔ \leftrightarrow (cmsy10 36)
    .{ .cp = 0x2195, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ↕ \updownarrow (cmsy10 108)
    .{ .cp = 0x2196, .w = 10, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↖ \nwarrow (cmsy10 45)
    .{ .cp = 0x2197, .w = 10, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↗ \nearrow (cmsy10 37)
    .{ .cp = 0x2198, .w = 10, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↘ \searrow (cmsy10 38)
    .{ .cp = 0x2199, .w = 10, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ↙ \swarrow (cmsy10 46)
    .{ .cp = 0x21A6, .w = 9.77, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ↦ \mapsto (composite: \mapstochar →)
    .{ .cp = 0x21BC, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ↼ \leftharpoonup (cmmi10 40)
    .{ .cp = 0x21BD, .w = 10.12, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ↽ \leftharpoondown (cmmi10 41)
    .{ .cp = 0x21C0, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇀ \rightharpoonup (cmmi10 42)
    .{ .cp = 0x21C1, .w = 10.12, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇁ \rightharpoondown (cmmi10 43)
    .{ .cp = 0x21D0, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇐ \Leftarrow (cmsy10 40)
    .{ .cp = 0x21D1, .w = 6.11, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ⇑ \Uparrow (cmsy10 42)
    .{ .cp = 0x21D2, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇒ \Rightarrow (cmsy10 41)
    .{ .cp = 0x21D3, .w = 6.11, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ⇓ \Downarrow (cmsy10 43)
    .{ .cp = 0x21D4, .w = 10, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ⇔ \Leftrightarrow (cmsy10 44)
    .{ .cp = 0x21D5, .w = 6.11, .h = 7.5, .d = 2.5, .ic = 0 }, // ⇕ \Updownarrow (cmsy10 109)
    .{ .cp = 0x2202, .w = 5.86, .h = 6.94445, .d = 0, .ic = 0.61508 }, // ∂ \partial (cmmi10 64)
    .{ .cp = 0x2205, .w = 5, .h = 7.5, .d = 0.55555, .ic = 0 }, // ∅ \emptyset (cmsy10 59)
    .{ .cp = 0x2207, .w = 8.33, .h = 6.83334, .d = 0, .ic = 0 }, // ∇ \nabla (cmsy10 114)
    .{ .cp = 0x2208, .w = 6.67, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ∈ \in (cmsy10 50)
    .{ .cp = 0x2209, .w = 6.67, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ∉ \notin (composite: \not \in)
    .{ .cp = 0x220B, .w = 6.67, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ∋ \ni (cmsy10 51)
    .{ .cp = 0x2212, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // − minus (cmsy10 161)
    .{ .cp = 0x2213, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ∓ \mp (cmsy10 168)
    .{ .cp = 0x2216, .w = 5.68, .h = 7.5, .d = 2.5, .ic = 0 }, // ∖ \setminus (cmsy10 110)
    .{ .cp = 0x2217, .w = 5, .h = 4.65278, .d = -0.34722, .ic = 0 }, // ∗ \ast (cmsy10 164)
    .{ .cp = 0x2218, .w = 4.12, .h = 4.6528, .d = -0.3472, .ic = 0 }, // ∘ \circ (cmsy10 177)
    .{ .cp = 0x2219, .w = 5, .h = 4.6528, .d = -0.3472, .ic = 0 }, // ∙ \bullet (cmsy10 178)
    .{ .cp = 0x221A, .w = 8.33, .h = 0.48571, .d = 9.51429, .ic = 0 }, // √ \surd (cmsy10 112)
    .{ .cp = 0x221D, .w = 7.78, .h = 4.30555, .d = 0, .ic = 0 }, // ∝ \propto (cmsy10 47)
    .{ .cp = 0x221E, .w = 10, .h = 4.30555, .d = 0, .ic = 0 }, // ∞ \infty (cmsy10 49)
    .{ .cp = 0x2223, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ∣ \mid (cmsy10 106 \vert)
    .{ .cp = 0x2225, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ∥ \parallel (cmsy10 107 \Vert)
    .{ .cp = 0x2227, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∧ \wedge (cmsy10 94)
    .{ .cp = 0x2228, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∨ \vee (cmsy10 95)
    .{ .cp = 0x2229, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∩ \cap (cmsy10 92)
    .{ .cp = 0x222A, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∪ \cup (cmsy10 91)
    .{ .cp = 0x223C, .w = 7.73, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ∼ \sim (cmsy10 187)
    .{ .cp = 0x2240, .w = 2.8, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ≀ \wr (cmsy10 111)
    .{ .cp = 0x2243, .w = 7.78, .h = 4.93871, .d = -0.06129, .ic = 0 }, // ≃ \simeq (cmsy10 39)
    .{ .cp = 0x2248, .w = 7.73, .h = 5.15828, .d = 0.15828, .ic = 0 }, // ≈ \approx (cmsy10 188)
    .{ .cp = 0x224D, .w = 7.78, .h = 4.93871, .d = -0.06129, .ic = 0 }, // ≍ \asymp (cmsy10 179)
    .{ .cp = 0x2260, .w = 7.78, .h = 3.84079, .d = -1.15921, .ic = 0 }, // ≠ \ne (composite: \not over =)
    .{ .cp = 0x2261, .w = 7.78, .h = 4.93871, .d = -0.06129, .ic = 0 }, // ≡ \equiv (cmsy10 180)
    .{ .cp = 0x2262, .w = 7.78, .h = 4.93871, .d = -0.06129, .ic = 0 }, // ≢ \not\equiv (composite: \not over ≡)
    .{ .cp = 0x2264, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ≤ \leq (cmsy10 183)
    .{ .cp = 0x2265, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ≥ \geq (cmsy10 184)
    .{ .cp = 0x226A, .w = 10, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ≪ \ll (cmsy10 191)
    .{ .cp = 0x226B, .w = 10, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ≫ \gg (cmsy10 192)
    .{ .cp = 0x227A, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ≺ \prec (cmsy10 193)
    .{ .cp = 0x227B, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ≻ \succ (cmsy10 194)
    .{ .cp = 0x2282, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ⊂ \subset (cmsy10 189)
    .{ .cp = 0x2283, .w = 7.78, .h = 5.75675, .d = 0.75675, .ic = 0 }, // ⊃ \supset (cmsy10 190)
    .{ .cp = 0x2286, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⊆ \subseteq (cmsy10 181)
    .{ .cp = 0x2287, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⊇ \supseteq (cmsy10 182)
    .{ .cp = 0x228E, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊎ \uplus (cmsy10 93)
    .{ .cp = 0x2291, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⊑ \sqsubseteq (cmsy10 118)
    .{ .cp = 0x2292, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⊒ \sqsupseteq (cmsy10 119)
    .{ .cp = 0x2293, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊓ \sqcap (cmsy10 117)
    .{ .cp = 0x2294, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊔ \sqcup (cmsy10 116)
    .{ .cp = 0x2295, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊕ \oplus (cmsy10 169)
    .{ .cp = 0x2296, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊖ \ominus (cmsy10 170)
    .{ .cp = 0x2297, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊗ \otimes (cmsy10 171)
    .{ .cp = 0x2298, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊘ \oslash (cmsy10 174)
    .{ .cp = 0x2299, .w = 7.78, .h = 6.19049, .d = 1.19049, .ic = 0 }, // ⊙ \odot (cmsy10 175)
    .{ .cp = 0x22A2, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ⊢ \vdash (cmsy10 96)
    .{ .cp = 0x22A3, .w = 6.11, .h = 6.94445, .d = 0, .ic = 0 }, // ⊣ \dashv (cmsy10 97)
    .{ .cp = 0x22A5, .w = 7.78, .h = 6.94445, .d = 0, .ic = 0 }, // ⊥ \perp (cmsy10 63)
    .{ .cp = 0x22C4, .w = 5, .h = 4.6528, .d = -0.3472, .ic = 0.08 }, // ⋄ \diamond (cmsy10 166)
    .{ .cp = 0x22C5, .w = 2.78, .h = 4.6528, .d = -0.3472, .ic = 0 }, // ⋅ \cdot (cmsy10 middle dot)
    .{ .cp = 0x22C6, .w = 5, .h = 4.65278, .d = -0.34722, .ic = 0.25 }, // ⋆ \star (cmmi10 63)
    .{ .cp = 0x22EF, .w = 7.76, .h = 4.6528, .d = -0.3472, .ic = 0 }, // ⋯ \cdots (composite: 3 × cdot)
    .{ .cp = 0x2308, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌈ \lceil (cmsy10 100)
    .{ .cp = 0x2309, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌉ \rceil (cmsy10 101)
    .{ .cp = 0x230A, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌊ \lfloor (cmsy10 98)
    .{ .cp = 0x230B, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌋ \rfloor (cmsy10 99)
    .{ .cp = 0x2322, .w = 10, .h = 3.5764, .d = -1.4236, .ic = 0 }, // ⌢ \frown (cmmi10 95)
    .{ .cp = 0x2323, .w = 10, .h = 3.5764, .d = -1.4236, .ic = 0 }, // ⌣ \smile (cmmi10 94)
    .{ .cp = 0x25B9, .w = 5.8532, .h = 4.65278, .d = -0.34722, .ic = 0 }, // ▹ \triangleright (cmmi10 46)
    .{ .cp = 0x25C3, .w = 5.8532, .h = 4.65278, .d = -0.34722, .ic = 0 }, // ◃ \triangleleft (cmmi10 47)
    .{ .cp = 0x25CB, .w = 7.96, .h = 6.94445, .d = 1.94445, .ic = 0 }, // ○ \bigcirc (cmsy10 176)
    .{ .cp = 0x27E8, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟨ \langle (cmsy10 104)
    .{ .cp = 0x27E9, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟩ \rangle (cmsy10 105)
    .{ .cp = 0x2A3F, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // ⨿ \amalg (cmsy10 113)
    .{ .cp = 0x2AAF, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⪯ \preceq (cmsy10 185)
    .{ .cp = 0x2AB0, .w = 7.78, .h = 6.85469, .d = 1.85469, .ic = 0 }, // ⪰ \succeq (cmsy10 186)
    .{ .cp = 0x1D434, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐴
    .{ .cp = 0x1D435, .w = 7.59, .h = 6.83334, .d = 0, .ic = 0.48684 }, // 𝐵
    .{ .cp = 0x1D436, .w = 7.15, .h = 6.83334, .d = 0, .ic = 0.70038 }, // 𝐶
    .{ .cp = 0x1D437, .w = 8.28, .h = 6.83334, .d = 0, .ic = 0.30755 }, // 𝐷
    .{ .cp = 0x1D438, .w = 7.38, .h = 6.83334, .d = 0, .ic = 0.5496 }, // 𝐸
    .{ .cp = 0x1D439, .w = 6.43, .h = 6.83334, .d = 0, .ic = 1.53771 }, // 𝐹
    .{ .cp = 0x1D43A, .w = 7.86, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐺
    .{ .cp = 0x1D43B, .w = 8.31, .h = 6.83334, .d = 0, .ic = 0.76486 }, // 𝐻
    .{ .cp = 0x1D43C, .w = 4.4, .h = 6.83334, .d = 0, .ic = 0.77728 }, // 𝐼
    .{ .cp = 0x1D43D, .w = 5.55, .h = 6.83334, .d = 0, .ic = 0.94345 }, // 𝐽
    .{ .cp = 0x1D43E, .w = 8.49, .h = 6.83334, .d = 0, .ic = 0.70038 }, // 𝐾
    .{ .cp = 0x1D43F, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐿
    .{ .cp = 0x1D440, .w = 9.7, .h = 6.83334, .d = 0, .ic = 1.07241 }, // 𝑀
    .{ .cp = 0x1D441, .w = 8.03, .h = 6.83334, .d = 0, .ic = 1.07241 }, // 𝑁
    .{ .cp = 0x1D442, .w = 7.63, .h = 6.83334, .d = 0, .ic = 0.30755 }, // 𝑂
    .{ .cp = 0x1D443, .w = 6.42, .h = 6.83334, .d = 0, .ic = 1.53771 }, // 𝑃
    .{ .cp = 0x1D444, .w = 7.91, .h = 6.83334, .d = 1.94445, .ic = 0 }, // 𝑄
    .{ .cp = 0x1D445, .w = 7.59, .h = 6.83334, .d = 0, .ic = 0.24 }, // 𝑅
    .{ .cp = 0x1D446, .w = 6.13, .h = 6.83334, .d = 0, .ic = 0.54662 }, // 𝑆
    .{ .cp = 0x1D447, .w = 5.84, .h = 6.83334, .d = 0, .ic = 1.53771 }, // 𝑇
    .{ .cp = 0x1D448, .w = 6.83, .h = 6.83334, .d = 0, .ic = 1.07241 }, // 𝑈
    .{ .cp = 0x1D449, .w = 5.83, .h = 6.83334, .d = 0, .ic = 0.08 }, // 𝑉
    .{ .cp = 0x1D44A, .w = 9.44, .h = 6.83334, .d = 0, .ic = 0.09 }, // 𝑊
    .{ .cp = 0x1D44B, .w = 8.28, .h = 6.83334, .d = 0, .ic = 0.04 }, // 𝑋
    .{ .cp = 0x1D44C, .w = 5.81, .h = 6.83334, .d = 0, .ic = 0.16 }, // 𝑌
    .{ .cp = 0x1D44D, .w = 6.83, .h = 6.83334, .d = 0, .ic = 0.70038 }, // 𝑍
    .{ .cp = 0x1D44E, .w = 5.29, .h = 4.30555, .d = 0, .ic = 0.11 }, // 𝑎
    .{ .cp = 0x1D44F, .w = 4.29, .h = 6.94445, .d = 0, .ic = 0 }, // 𝑏
    .{ .cp = 0x1D450, .w = 4.33, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑐
    .{ .cp = 0x1D451, .w = 5.2, .h = 6.94445, .d = 0, .ic = 0 }, // 𝑑
    .{ .cp = 0x1D452, .w = 4.66, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑒
    .{ .cp = 0x1D453, .w = 4.9, .h = 6.94445, .d = 1.94445, .ic = 0.79 }, // 𝑓
    .{ .cp = 0x1D454, .w = 4.77, .h = 4.30555, .d = 1.94445, .ic = 0.13 }, // 𝑔
    .{ .cp = 0x1D456, .w = 3.45, .h = 6.61706, .d = 0, .ic = 0 }, // 𝑖
    .{ .cp = 0x1D457, .w = 4.12, .h = 6.61706, .d = 1.94445, .ic = 0.57787 }, // 𝑗
    .{ .cp = 0x1D458, .w = 5.21, .h = 6.94445, .d = 0, .ic = 0.11 }, // 𝑘
    .{ .cp = 0x1D459, .w = 2.98, .h = 6.94445, .d = 0, .ic = 0.05 }, // 𝑙
    .{ .cp = 0x1D45A, .w = 8.78, .h = 4.30555, .d = 0, .ic = 0.08 }, // 𝑚
    .{ .cp = 0x1D45B, .w = 6, .h = 4.30555, .d = 0, .ic = 0.07 }, // 𝑛
    .{ .cp = 0x1D45C, .w = 4.85, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑜
    .{ .cp = 0x1D45D, .w = 5.03, .h = 4.30555, .d = 1.94445, .ic = 0 }, // 𝑝
    .{ .cp = 0x1D45E, .w = 4.46, .h = 4.30555, .d = 1.94445, .ic = 0.27 }, // 𝑞
    .{ .cp = 0x1D45F, .w = 4.51, .h = 4.30555, .d = 0, .ic = 0.30755 }, // 𝑟
    .{ .cp = 0x1D460, .w = 4.69, .h = 4.30555, .d = 0, .ic = 0 }, // 𝑠
    .{ .cp = 0x1D461, .w = 3.61, .h = 6.1508, .d = 0, .ic = 0 }, // 𝑡
    .{ .cp = 0x1D462, .w = 5.72, .h = 4.30555, .d = 0, .ic = 0.07 }, // 𝑢
    .{ .cp = 0x1D463, .w = 4.85, .h = 4.30555, .d = 0, .ic = 0.08 }, // 𝑣
    .{ .cp = 0x1D464, .w = 7.16, .h = 4.30555, .d = 0, .ic = 0.09 }, // 𝑤
    .{ .cp = 0x1D465, .w = 5.72, .h = 4.30555, .d = 0, .ic = 0.16 }, // 𝑥
    .{ .cp = 0x1D466, .w = 4.9, .h = 4.30555, .d = 1.94445, .ic = 0.08 }, // 𝑦
    .{ .cp = 0x1D467, .w = 4.65, .h = 4.30555, .d = 0, .ic = 0.41005 }, // 𝑧
    .{ .cp = 0x1D715, .w = 5.31, .h = 6.94445, .d = 0, .ic = 0.61508 }, // 𝜕
};

/// Scriptscript-size metric table (design size 5pt), same convention as
/// `table` (em × 10): LM Math has no optical 5pt variant either, so these
/// rows carry the LM Math advance and the size_pt/10 factor yields LM
/// advance × 0.5 at 5pt (replacing the old optical cmr5/cmmi5/cmsy5).
const table5 = [_]Entry{
    .{ .cp = 0x21, .w = 2.78, .h = 6.94446, .d = 0, .ic = 0 }, // !
    .{ .cp = 0x28, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // (
    .{ .cp = 0x29, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // )
    .{ .cp = 0x2B, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // +
    .{ .cp = 0x2C, .w = 2.78, .h = 1.22223, .d = 1.94446, .ic = 0 }, // ,
    .{ .cp = 0x2D, .w = 3.33, .h = 6.66675, .d = 1.66675, .ic = 0 }, // - (cmsy10 minus)
    .{ .cp = 0x2E, .w = 2.78, .h = 1.22223, .d = 0, .ic = 0 }, // .
    .{ .cp = 0x2F, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // /
    .{ .cp = 0x30, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 0
    .{ .cp = 0x31, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 1
    .{ .cp = 0x32, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 2
    .{ .cp = 0x33, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 3
    .{ .cp = 0x34, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 4
    .{ .cp = 0x35, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 5
    .{ .cp = 0x36, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 6
    .{ .cp = 0x37, .w = 5, .h = 6.44445, .d = 0, .ic = 0.13 }, // 7
    .{ .cp = 0x38, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 8
    .{ .cp = 0x39, .w = 5, .h = 6.44445, .d = 0, .ic = 0 }, // 9
    .{ .cp = 0x3A, .w = 2.78, .h = 4.30554, .d = 0, .ic = 0 }, // :
    .{ .cp = 0x3B, .w = 2.78, .h = 4.30554, .d = 1.94446, .ic = 0 }, // ;
    .{ .cp = 0x3C, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // < (cmmi10)
    .{ .cp = 0x3D, .w = 7.78, .h = 3.96405, .d = -1.03595, .ic = 0 }, // =
    .{ .cp = 0x3E, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // > (cmmi10)
    .{ .cp = 0x41, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // A
    .{ .cp = 0x42, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0.46701 }, // B
    .{ .cp = 0x43, .w = 7.22, .h = 6.83334, .d = 0, .ic = 0.68054 }, // C
    .{ .cp = 0x44, .w = 7.64, .h = 6.83334, .d = 0, .ic = 0.34723 }, // D
    .{ .cp = 0x45, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0.51389 }, // E
    .{ .cp = 0x46, .w = 6.53, .h = 6.83334, .d = 0, .ic = 1.73615 }, // F
    .{ .cp = 0x47, .w = 7.85, .h = 6.83334, .d = 0, .ic = 0 }, // G
    .{ .cp = 0x48, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.74305 }, // H
    .{ .cp = 0x49, .w = 3.61, .h = 6.83334, .d = 0, .ic = 0.76736 }, // I
    .{ .cp = 0x4A, .w = 5.14, .h = 6.83334, .d = 0, .ic = 0.95139 }, // J
    .{ .cp = 0x4B, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0.68054 }, // K
    .{ .cp = 0x4C, .w = 6.25, .h = 6.83334, .d = 0, .ic = 0 }, // L
    .{ .cp = 0x4D, .w = 9.17, .h = 6.83334, .d = 0, .ic = 1.09027 }, // M
    .{ .cp = 0x4E, .w = 7.5, .h = 6.83334, .d = 0, .ic = 1.09027 }, // N
    .{ .cp = 0x4F, .w = 7.78, .h = 6.83334, .d = 0, .ic = 0.34723 }, // O
    .{ .cp = 0x50, .w = 6.81, .h = 6.83334, .d = 0, .ic = 1.73615 }, // P
    .{ .cp = 0x51, .w = 7.78, .h = 6.83334, .d = 1.94446, .ic = 0 }, // Q
    .{ .cp = 0x52, .w = 7.36, .h = 6.83334, .d = 0, .ic = 0.24 }, // R
    .{ .cp = 0x53, .w = 5.56, .h = 6.83334, .d = 0, .ic = 0.50693 }, // S
    .{ .cp = 0x54, .w = 7.22, .h = 6.83334, .d = 0, .ic = 1.73615 }, // T
    .{ .cp = 0x55, .w = 7.5, .h = 6.83334, .d = 0, .ic = 1.09027 }, // U
    .{ .cp = 0x56, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.08 }, // V
    .{ .cp = 0x57, .w = 10.28, .h = 6.83334, .d = 0, .ic = 0.09 }, // W
    .{ .cp = 0x58, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.04 }, // X
    .{ .cp = 0x59, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0.16 }, // Y
    .{ .cp = 0x5A, .w = 6.11, .h = 6.83334, .d = 0, .ic = 0.68054 }, // Z
    .{ .cp = 0x5B, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0.06 }, // [
    .{ .cp = 0x5D, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ]
    .{ .cp = 0x61, .w = 5, .h = 4.30554, .d = 0, .ic = 0.11 }, // a
    .{ .cp = 0x62, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0 }, // b
    .{ .cp = 0x63, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0 }, // c
    .{ .cp = 0x64, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0 }, // d
    .{ .cp = 0x65, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0 }, // e
    .{ .cp = 0x66, .w = 3.06, .h = 6.94446, .d = 1.94446, .ic = 0.79 }, // f
    .{ .cp = 0x67, .w = 5, .h = 4.30554, .d = 1.94446, .ic = 0.13 }, // g
    .{ .cp = 0x68, .w = 5.56, .h = 6.94446, .d = 0, .ic = 0.07 }, // h
    .{ .cp = 0x69, .w = 2.78, .h = 6.66468, .d = 0, .ic = 0 }, // i
    .{ .cp = 0x6A, .w = 3.06, .h = 6.66468, .d = 1.94446, .ic = 0.58978 }, // j
    .{ .cp = 0x6B, .w = 5.28, .h = 6.94446, .d = 0, .ic = 0.11 }, // k
    .{ .cp = 0x6C, .w = 2.78, .h = 6.94446, .d = 0, .ic = 0.05 }, // l
    .{ .cp = 0x6D, .w = 8.33, .h = 4.30554, .d = 0, .ic = 0.08 }, // m
    .{ .cp = 0x6E, .w = 5.56, .h = 4.30554, .d = 0, .ic = 0.07 }, // n
    .{ .cp = 0x6F, .w = 5, .h = 4.30554, .d = 0, .ic = 0 }, // o
    .{ .cp = 0x70, .w = 5.56, .h = 4.30554, .d = 1.94446, .ic = 0 }, // p
    .{ .cp = 0x71, .w = 5.28, .h = 4.30554, .d = 1.94446, .ic = 0.27 }, // q
    .{ .cp = 0x72, .w = 3.92, .h = 4.30554, .d = 0, .ic = 0.34723 }, // r
    .{ .cp = 0x73, .w = 3.94, .h = 4.30554, .d = 0, .ic = 0 }, // s
    .{ .cp = 0x74, .w = 3.89, .h = 6.15079, .d = 0, .ic = 0 }, // t
    .{ .cp = 0x75, .w = 5.56, .h = 4.30554, .d = 0, .ic = 0.07 }, // u
    .{ .cp = 0x76, .w = 5.28, .h = 4.30554, .d = 0, .ic = 0.08 }, // v
    .{ .cp = 0x77, .w = 7.22, .h = 4.30554, .d = 0, .ic = 0.09 }, // w
    .{ .cp = 0x78, .w = 5.28, .h = 4.30554, .d = 0, .ic = 0.16 }, // x
    .{ .cp = 0x79, .w = 5.28, .h = 4.30554, .d = 1.94446, .ic = 0.08 }, // y
    .{ .cp = 0x7A, .w = 4.44, .h = 4.30554, .d = 0, .ic = 0.37036 }, // z
    .{ .cp = 0x7B, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // { (cmsy10)
    .{ .cp = 0x7C, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // | (cmsy10)
    .{ .cp = 0x7D, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // } (cmsy10)
    .{ .cp = 0x00B1, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ± \pm (cmsy10 167)
    .{ .cp = 0x00B7, .w = 2.78, .h = 4.9306, .d = -0.0694, .ic = 0 }, // · middle dot (cmsy10, same as U+22C5 ⋅)
    .{ .cp = 0x00D7, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // × \times (cmsy10 163)
    .{ .cp = 0x00F7, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ÷ \div (cmsy10 165)
    .{ .cp = 0x391, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // Α
    .{ .cp = 0x392, .w = 7.08, .h = 6.83334, .d = 0, .ic = 0.46701 }, // Β
    .{ .cp = 0x393, .w = 6.25, .h = 6.79761, .d = 0, .ic = 0 }, // Γ (cmr10 slot 161)
    .{ .cp = 0x394, .w = 8.33, .h = 6.79761, .d = 0, .ic = 0 }, // Δ (cmr10 slot 162)
    .{ .cp = 0x398, .w = 7.78, .h = 6.79761, .d = 0, .ic = 0 }, // Θ (cmr10 slot 163)
    .{ .cp = 0x39B, .w = 6.94, .h = 6.79761, .d = 0, .ic = 0 }, // Λ (cmr10 slot 164)
    .{ .cp = 0x3A0, .w = 7.5, .h = 6.79761, .d = 0, .ic = 0 }, // Π (cmr10 slot 166)
    .{ .cp = 0x3A3, .w = 7.22, .h = 6.79761, .d = 0, .ic = 0 }, // Σ (cmr10 slot 167)
    .{ .cp = 0x3A6, .w = 7.22, .h = 6.79761, .d = 0, .ic = 0 }, // Φ (cmr10 slot 169)
    .{ .cp = 0x3A9, .w = 7.22, .h = 6.79761, .d = 0, .ic = 0 }, // Ω (cmr10 slot 171)
    .{ .cp = 0x3B1, .w = 6.41, .h = 4.30554, .d = 0, .ic = 0.24 }, // α
    .{ .cp = 0x3B2, .w = 5.58, .h = 6.94446, .d = 1.94446, .ic = 0.51389 }, // β
    .{ .cp = 0x3B3, .w = 5.86, .h = 4.30554, .d = 1.94446, .ic = 0.69446 }, // γ
    .{ .cp = 0x3B4, .w = 4.74, .h = 6.94446, .d = 0, .ic = 0.3229 }, // δ
    .{ .cp = 0x3B5, .w = 5.35, .h = 4.30554, .d = 0, .ic = 0 }, // ε
    .{ .cp = 0x3B8, .w = 4.88, .h = 6.94446, .d = 0, .ic = 0.34723 }, // θ
    .{ .cp = 0x3BB, .w = 5.37, .h = 6.94446, .d = 0, .ic = 0.54 }, // λ
    .{ .cp = 0x3BC, .w = 5.3, .h = 4.30554, .d = 1.94446, .ic = 0.23 }, // μ
    .{ .cp = 0x3C0, .w = 5.86, .h = 4.30554, .d = 0, .ic = 0.35879 }, // π
    .{ .cp = 0x3C3, .w = 5.99, .h = 4.30554, .d = 0, .ic = 0.35879 }, // σ
    .{ .cp = 0x3C6, .w = 6.41, .h = 6.94446, .d = 1.94446, .ic = 0 }, // φ
    .{ .cp = 0x3C9, .w = 6.41, .h = 4.30554, .d = 0, .ic = 0.35879 }, // ω
    .{ .cp = 0x2020, .w = 4.44, .h = 6.94446, .d = 1.94446, .ic = 0 }, // † \dagger (cmsy10 121)
    .{ .cp = 0x2021, .w = 4.44, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ‡ \ddagger (cmsy10 122)
    .{ .cp = 0x2032, .w = 3.11, .h = 5.55557, .d = 0, .ic = 0 }, // ′ \prime (cmsy10 48)
    .{ .cp = 0x2033, .w = 5.11, .h = 5.55557, .d = 0, .ic = 0 }, // ″ composite: 2 × \prime
    .{ .cp = 0x210E, .w = 5.76, .h = 6.94446, .d = 0, .ic = 0.07 }, // ℎ
    .{ .cp = 0x2190, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ← \leftarrow (cmsy10 195)
    .{ .cp = 0x2191, .w = 5, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↑ \uparrow (cmsy10 34)
    .{ .cp = 0x2192, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // → \rightarrow (cmsy10 33)
    .{ .cp = 0x2193, .w = 5, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↓ \downarrow (cmsy10 35)
    .{ .cp = 0x2194, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ↔ \leftrightarrow (cmsy10 36)
    .{ .cp = 0x2195, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ↕ \updownarrow (cmsy10 108)
    .{ .cp = 0x2196, .w = 10, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↖ \nwarrow (cmsy10 45)
    .{ .cp = 0x2197, .w = 10, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↗ \nearrow (cmsy10 37)
    .{ .cp = 0x2198, .w = 10, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↘ \searrow (cmsy10 38)
    .{ .cp = 0x2199, .w = 10, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ↙ \swarrow (cmsy10 46)
    .{ .cp = 0x21A6, .w = 9.77, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ↦ \mapsto (composite: \mapstochar →)
    .{ .cp = 0x21BC, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ↼ \leftharpoonup (cmmi10 40)
    .{ .cp = 0x21BD, .w = 10.12, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ↽ \leftharpoondown (cmmi10 41)
    .{ .cp = 0x21C0, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇀ \rightharpoonup (cmmi10 42)
    .{ .cp = 0x21C1, .w = 10.12, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇁ \rightharpoondown (cmmi10 43)
    .{ .cp = 0x21D0, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇐ \Leftarrow (cmsy10 40)
    .{ .cp = 0x21D1, .w = 6.11, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ⇑ \Uparrow (cmsy10 42)
    .{ .cp = 0x21D2, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇒ \Rightarrow (cmsy10 41)
    .{ .cp = 0x21D3, .w = 6.11, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ⇓ \Downarrow (cmsy10 43)
    .{ .cp = 0x21D4, .w = 10, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ⇔ \Leftrightarrow (cmsy10 44)
    .{ .cp = 0x21D5, .w = 6.11, .h = 7.5, .d = 2.5, .ic = 0 }, // ⇕ \Updownarrow (cmsy10 109)
    .{ .cp = 0x2202, .w = 5.86, .h = 6.94446, .d = 0, .ic = 0.69446 }, // ∂ \partial (cmmi10 64)
    .{ .cp = 0x2205, .w = 5, .h = 7.5, .d = 0.55554, .ic = 0 }, // ∅ \emptyset (cmsy10 59)
    .{ .cp = 0x2207, .w = 8.33, .h = 6.83334, .d = 0, .ic = 0 }, // ∇ \nabla (cmsy10 114)
    .{ .cp = 0x2208, .w = 6.67, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ∈ \in (cmsy10 50)
    .{ .cp = 0x2209, .w = 6.67, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ∉ \notin (composite: \not \in)
    .{ .cp = 0x220B, .w = 6.67, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ∋ \ni (cmsy10 51)
    .{ .cp = 0x2212, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // − minus (cmsy10 161)
    .{ .cp = 0x2213, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ∓ \mp (cmsy10 168)
    .{ .cp = 0x2216, .w = 5.68, .h = 7.5, .d = 2.5, .ic = 0 }, // ∖ \setminus (cmsy10 110)
    .{ .cp = 0x2217, .w = 5, .h = 4.65277, .d = -0.34723, .ic = 0 }, // ∗ \ast (cmsy10 164)
    .{ .cp = 0x2218, .w = 4.12, .h = 4.9306, .d = -0.0694, .ic = 0 }, // ∘ \circ (cmsy10 177)
    .{ .cp = 0x2219, .w = 5, .h = 4.9306, .d = -0.0694, .ic = 0 }, // ∙ \bullet (cmsy10 178)
    .{ .cp = 0x221A, .w = 8.33, .h = 0.56, .d = 9.44, .ic = 0 }, // √ \surd (cmsy10 112)
    .{ .cp = 0x221D, .w = 7.78, .h = 4.30554, .d = 0, .ic = 0 }, // ∝ \propto (cmsy10 47)
    .{ .cp = 0x221E, .w = 10, .h = 4.30554, .d = 0, .ic = 0 }, // ∞ \infty (cmsy10 49)
    .{ .cp = 0x2223, .w = 2.78, .h = 7.5, .d = 2.5, .ic = 0 }, // ∣ \mid (cmsy10 106 \vert)
    .{ .cp = 0x2225, .w = 5, .h = 7.5, .d = 2.5, .ic = 0 }, // ∥ \parallel (cmsy10 107 \Vert)
    .{ .cp = 0x2227, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∧ \wedge (cmsy10 94)
    .{ .cp = 0x2228, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∨ \vee (cmsy10 95)
    .{ .cp = 0x2229, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∩ \cap (cmsy10 92)
    .{ .cp = 0x222A, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ∪ \cup (cmsy10 91)
    .{ .cp = 0x223C, .w = 7.73, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ∼ \sim (cmsy10 187)
    .{ .cp = 0x2240, .w = 2.8, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ≀ \wr (cmsy10 111)
    .{ .cp = 0x2243, .w = 7.78, .h = 5.14807, .d = 0.14807, .ic = 0 }, // ≃ \simeq (cmsy10 39)
    .{ .cp = 0x2248, .w = 7.73, .h = 5.38488, .d = 0.38488, .ic = 0 }, // ≈ \approx (cmsy10 188)
    .{ .cp = 0x224D, .w = 7.78, .h = 5.14807, .d = 0.14807, .ic = 0 }, // ≍ \asymp (cmsy10 179)
    .{ .cp = 0x2260, .w = 7.78, .h = 3.96405, .d = -1.03595, .ic = 0 }, // ≠ \ne (composite: \not over =)
    .{ .cp = 0x2261, .w = 7.78, .h = 5.14807, .d = 0.14807, .ic = 0 }, // ≡ \equiv (cmsy10 180)
    .{ .cp = 0x2262, .w = 7.78, .h = 5.14807, .d = 0.14807, .ic = 0 }, // ≢ \not\equiv (composite: \not over ≡)
    .{ .cp = 0x2264, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ≤ \leq (cmsy10 183)
    .{ .cp = 0x2265, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ≥ \geq (cmsy10 184)
    .{ .cp = 0x226A, .w = 10, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ≪ \ll (cmsy10 191)
    .{ .cp = 0x226B, .w = 10, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ≫ \gg (cmsy10 192)
    .{ .cp = 0x227A, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ≺ \prec (cmsy10 193)
    .{ .cp = 0x227B, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ≻ \succ (cmsy10 194)
    .{ .cp = 0x2282, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ⊂ \subset (cmsy10 189)
    .{ .cp = 0x2283, .w = 7.78, .h = 6.00916, .d = 1.00916, .ic = 0 }, // ⊃ \supset (cmsy10 190)
    .{ .cp = 0x2286, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⊆ \subseteq (cmsy10 181)
    .{ .cp = 0x2287, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⊇ \supseteq (cmsy10 182)
    .{ .cp = 0x228E, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊎ \uplus (cmsy10 93)
    .{ .cp = 0x2291, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⊑ \sqsubseteq (cmsy10 118)
    .{ .cp = 0x2292, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⊒ \sqsupseteq (cmsy10 119)
    .{ .cp = 0x2293, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊓ \sqcap (cmsy10 117)
    .{ .cp = 0x2294, .w = 6.67, .h = 5.55557, .d = 0, .ic = 0 }, // ⊔ \sqcup (cmsy10 116)
    .{ .cp = 0x2295, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊕ \oplus (cmsy10 169)
    .{ .cp = 0x2296, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊖ \ominus (cmsy10 170)
    .{ .cp = 0x2297, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊗ \otimes (cmsy10 171)
    .{ .cp = 0x2298, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊘ \oslash (cmsy10 174)
    .{ .cp = 0x2299, .w = 7.78, .h = 6.66675, .d = 1.66675, .ic = 0 }, // ⊙ \odot (cmsy10 175)
    .{ .cp = 0x22A2, .w = 6.11, .h = 6.94446, .d = 0, .ic = 0 }, // ⊢ \vdash (cmsy10 96)
    .{ .cp = 0x22A3, .w = 6.11, .h = 6.94446, .d = 0, .ic = 0 }, // ⊣ \dashv (cmsy10 97)
    .{ .cp = 0x22A5, .w = 7.78, .h = 6.94446, .d = 0, .ic = 0 }, // ⊥ \perp (cmsy10 63)
    .{ .cp = 0x22C4, .w = 5, .h = 4.9306, .d = -0.0694, .ic = 0.08 }, // ⋄ \diamond (cmsy10 166)
    .{ .cp = 0x22C5, .w = 2.78, .h = 4.9306, .d = -0.0694, .ic = 0 }, // ⋅ \cdot (cmsy10 middle dot)
    .{ .cp = 0x22C6, .w = 5, .h = 4.65277, .d = -0.34723, .ic = 0.25 }, // ⋆ \star (cmmi10 63)
    .{ .cp = 0x22EF, .w = 7.76, .h = 4.9306, .d = -0.0694, .ic = 0 }, // ⋯ \cdots (composite: 3 × cdot)
    .{ .cp = 0x2308, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌈ \lceil (cmsy10 100)
    .{ .cp = 0x2309, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌉ \rceil (cmsy10 101)
    .{ .cp = 0x230A, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌊ \lfloor (cmsy10 98)
    .{ .cp = 0x230B, .w = 4.44, .h = 7.5, .d = 2.5, .ic = 0 }, // ⌋ \rfloor (cmsy10 99)
    .{ .cp = 0x2322, .w = 10, .h = 3.57638, .d = -1.42362, .ic = 0 }, // ⌢ \frown (cmmi10 95)
    .{ .cp = 0x2323, .w = 10, .h = 3.57638, .d = -1.42362, .ic = 0 }, // ⌣ \smile (cmmi10 94)
    .{ .cp = 0x25B9, .w = 7.3612, .h = 4.65277, .d = -0.34723, .ic = 0 }, // ▹ \triangleright (cmmi10 46)
    .{ .cp = 0x25C3, .w = 7.3612, .h = 4.65277, .d = -0.34723, .ic = 0 }, // ◃ \triangleleft (cmmi10 47)
    .{ .cp = 0x25CB, .w = 7.96, .h = 6.94446, .d = 1.94446, .ic = 0 }, // ○ \bigcirc (cmsy10 176)
    .{ .cp = 0x27E8, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟨ \langle (cmsy10 104)
    .{ .cp = 0x27E9, .w = 3.89, .h = 7.5, .d = 2.5, .ic = 0 }, // ⟩ \rangle (cmsy10 105)
    .{ .cp = 0x2A3F, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // ⨿ \amalg (cmsy10 113)
    .{ .cp = 0x2AAF, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⪯ \preceq (cmsy10 185)
    .{ .cp = 0x2AB0, .w = 7.78, .h = 7.1932, .d = 2.1932, .ic = 0 }, // ⪰ \succeq (cmsy10 186)
    .{ .cp = 0x1D434, .w = 7.5, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐴
    .{ .cp = 0x1D435, .w = 7.59, .h = 6.83334, .d = 0, .ic = 0.46701 }, // 𝐵
    .{ .cp = 0x1D436, .w = 7.15, .h = 6.83334, .d = 0, .ic = 0.68054 }, // 𝐶
    .{ .cp = 0x1D437, .w = 8.28, .h = 6.83334, .d = 0, .ic = 0.34723 }, // 𝐷
    .{ .cp = 0x1D438, .w = 7.38, .h = 6.83334, .d = 0, .ic = 0.51389 }, // 𝐸
    .{ .cp = 0x1D439, .w = 6.43, .h = 6.83334, .d = 0, .ic = 1.73615 }, // 𝐹
    .{ .cp = 0x1D43A, .w = 7.86, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐺
    .{ .cp = 0x1D43B, .w = 8.31, .h = 6.83334, .d = 0, .ic = 0.74305 }, // 𝐻
    .{ .cp = 0x1D43C, .w = 4.4, .h = 6.83334, .d = 0, .ic = 0.76736 }, // 𝐼
    .{ .cp = 0x1D43D, .w = 5.55, .h = 6.83334, .d = 0, .ic = 0.95139 }, // 𝐽
    .{ .cp = 0x1D43E, .w = 8.49, .h = 6.83334, .d = 0, .ic = 0.68054 }, // 𝐾
    .{ .cp = 0x1D43F, .w = 6.81, .h = 6.83334, .d = 0, .ic = 0 }, // 𝐿
    .{ .cp = 0x1D440, .w = 9.7, .h = 6.83334, .d = 0, .ic = 1.09027 }, // 𝑀
    .{ .cp = 0x1D441, .w = 8.03, .h = 6.83334, .d = 0, .ic = 1.09027 }, // 𝑁
    .{ .cp = 0x1D442, .w = 7.63, .h = 6.83334, .d = 0, .ic = 0.34723 }, // 𝑂
    .{ .cp = 0x1D443, .w = 6.42, .h = 6.83334, .d = 0, .ic = 1.73615 }, // 𝑃
    .{ .cp = 0x1D444, .w = 7.91, .h = 6.83334, .d = 1.94446, .ic = 0 }, // 𝑄
    .{ .cp = 0x1D445, .w = 7.59, .h = 6.83334, .d = 0, .ic = 0.24 }, // 𝑅
    .{ .cp = 0x1D446, .w = 6.13, .h = 6.83334, .d = 0, .ic = 0.50693 }, // 𝑆
    .{ .cp = 0x1D447, .w = 5.84, .h = 6.83334, .d = 0, .ic = 1.73615 }, // 𝑇
    .{ .cp = 0x1D448, .w = 6.83, .h = 6.83334, .d = 0, .ic = 1.09027 }, // 𝑈
    .{ .cp = 0x1D449, .w = 5.83, .h = 6.83334, .d = 0, .ic = 0.08 }, // 𝑉
    .{ .cp = 0x1D44A, .w = 9.44, .h = 6.83334, .d = 0, .ic = 0.09 }, // 𝑊
    .{ .cp = 0x1D44B, .w = 8.28, .h = 6.83334, .d = 0, .ic = 0.04 }, // 𝑋
    .{ .cp = 0x1D44C, .w = 5.81, .h = 6.83334, .d = 0, .ic = 0.16 }, // 𝑌
    .{ .cp = 0x1D44D, .w = 6.83, .h = 6.83334, .d = 0, .ic = 0.68054 }, // 𝑍
    .{ .cp = 0x1D44E, .w = 5.29, .h = 4.30554, .d = 0, .ic = 0.11 }, // 𝑎
    .{ .cp = 0x1D44F, .w = 4.29, .h = 6.94446, .d = 0, .ic = 0 }, // 𝑏
    .{ .cp = 0x1D450, .w = 4.33, .h = 4.30554, .d = 0, .ic = 0 }, // 𝑐
    .{ .cp = 0x1D451, .w = 5.2, .h = 6.94446, .d = 0, .ic = 0 }, // 𝑑
    .{ .cp = 0x1D452, .w = 4.66, .h = 4.30554, .d = 0, .ic = 0 }, // 𝑒
    .{ .cp = 0x1D453, .w = 4.9, .h = 6.94446, .d = 1.94446, .ic = 0.79 }, // 𝑓
    .{ .cp = 0x1D454, .w = 4.77, .h = 4.30554, .d = 1.94446, .ic = 0.13 }, // 𝑔
    .{ .cp = 0x1D456, .w = 3.45, .h = 6.66468, .d = 0, .ic = 0 }, // 𝑖
    .{ .cp = 0x1D457, .w = 4.12, .h = 6.66468, .d = 1.94446, .ic = 0.58978 }, // 𝑗
    .{ .cp = 0x1D458, .w = 5.21, .h = 6.94446, .d = 0, .ic = 0.11 }, // 𝑘
    .{ .cp = 0x1D459, .w = 2.98, .h = 6.94446, .d = 0, .ic = 0.05 }, // 𝑙
    .{ .cp = 0x1D45A, .w = 8.78, .h = 4.30554, .d = 0, .ic = 0.08 }, // 𝑚
    .{ .cp = 0x1D45B, .w = 6, .h = 4.30554, .d = 0, .ic = 0.07 }, // 𝑛
    .{ .cp = 0x1D45C, .w = 4.85, .h = 4.30554, .d = 0, .ic = 0 }, // 𝑜
    .{ .cp = 0x1D45D, .w = 5.03, .h = 4.30554, .d = 1.94446, .ic = 0 }, // 𝑝
    .{ .cp = 0x1D45E, .w = 4.46, .h = 4.30554, .d = 1.94446, .ic = 0.27 }, // 𝑞
    .{ .cp = 0x1D45F, .w = 4.51, .h = 4.30554, .d = 0, .ic = 0.34723 }, // 𝑟
    .{ .cp = 0x1D460, .w = 4.69, .h = 4.30554, .d = 0, .ic = 0 }, // 𝑠
    .{ .cp = 0x1D461, .w = 3.61, .h = 6.15079, .d = 0, .ic = 0 }, // 𝑡
    .{ .cp = 0x1D462, .w = 5.72, .h = 4.30554, .d = 0, .ic = 0.07 }, // 𝑢
    .{ .cp = 0x1D463, .w = 4.85, .h = 4.30554, .d = 0, .ic = 0.08 }, // 𝑣
    .{ .cp = 0x1D464, .w = 7.16, .h = 4.30554, .d = 0, .ic = 0.09 }, // 𝑤
    .{ .cp = 0x1D465, .w = 5.72, .h = 4.30554, .d = 0, .ic = 0.16 }, // 𝑥
    .{ .cp = 0x1D466, .w = 4.9, .h = 4.30554, .d = 1.94446, .ic = 0.08 }, // 𝑦
    .{ .cp = 0x1D467, .w = 4.65, .h = 4.30554, .d = 0, .ic = 0.37036 }, // 𝑧
    .{ .cp = 0x1D715, .w = 5.31, .h = 6.94446, .d = 0, .ic = 0.69446 }, // 𝜕
};

/// One row of the drawn-ink table: ascent / descent in em of the glyph
/// font-size (the nominal size layout passes to both draw backends).
const InkEntry = struct {
    cp: u21,
    a: f32,
    d: f32,
};

/// Drawn-glyph ink extents in em of the glyph's font-size, measured with
/// fontTools BoundsPen on latinmodern-math.otf 2.005 (CFF outline bounds,
/// per-mille → em; the big-op rows reproduce the `bigOpInk` table below
/// exactly). Sorted by `cp` (binary-search invariant).
///
/// This is now the FALLBACK table, read only by `mathInk` for a codepoint the
/// active face's cmap does not carry. The primary source is `ink_metrics.zig`
/// — the same outlines regenerated from the embedded bytes, in all five
/// drawing faces and to six decimals instead of three. Three decimals is not
/// enclosure: rounding a 0.684113em top down to 0.684 under-frames the ink by
/// 0.07px at 60pt/720dpi, and one row was outright wrong (U+0391 Α 0.683
/// against a real 0.716, 20px of clipped apex). Nothing here is measured per
/// glyph at runtime, and a codepoint absent from LMMath (ams-only symbols,
/// CJK, …) still gets the font's design bound 0.750/0.250 — safe for the
/// browser's fallback fonts.
const ink_table = [_]InkEntry{
    .{ .cp = 0x0021, .a = 0.716, .d = 0.000 }, // !
    .{ .cp = 0x0023, .a = 0.694, .d = 0.194 }, // #
    .{ .cp = 0x0024, .a = 0.750, .d = 0.056 }, // $
    .{ .cp = 0x0025, .a = 0.750, .d = 0.056 }, // %
    .{ .cp = 0x0026, .a = 0.716, .d = 0.022 }, // &
    .{ .cp = 0x0028, .a = 0.748, .d = 0.248 }, // (
    .{ .cp = 0x0029, .a = 0.748, .d = 0.248 }, // )
    .{ .cp = 0x002B, .a = 0.583, .d = 0.083 }, // +
    .{ .cp = 0x002C, .a = 0.106, .d = 0.193 }, // ,
    .{ .cp = 0x002D, .a = 0.245, .d = 0.000 }, // -
    .{ .cp = 0x002E, .a = 0.106, .d = 0.000 }, // .
    .{ .cp = 0x002F, .a = 0.750, .d = 0.250 }, // /
    .{ .cp = 0x0030, .a = 0.666, .d = 0.022 }, // 0
    .{ .cp = 0x0031, .a = 0.666, .d = 0.000 }, // 1
    .{ .cp = 0x0032, .a = 0.666, .d = 0.000 }, // 2
    .{ .cp = 0x0033, .a = 0.666, .d = 0.022 }, // 3
    .{ .cp = 0x0034, .a = 0.677, .d = 0.000 }, // 4
    .{ .cp = 0x0035, .a = 0.666, .d = 0.022 }, // 5
    .{ .cp = 0x0036, .a = 0.666, .d = 0.022 }, // 6
    .{ .cp = 0x0037, .a = 0.676, .d = 0.022 }, // 7
    .{ .cp = 0x0038, .a = 0.666, .d = 0.022 }, // 8
    .{ .cp = 0x0039, .a = 0.666, .d = 0.022 }, // 9
    .{ .cp = 0x003A, .a = 0.431, .d = 0.000 }, // :
    .{ .cp = 0x003B, .a = 0.431, .d = 0.193 }, // ;
    .{ .cp = 0x003C, .a = 0.547, .d = 0.047 }, // <
    .{ .cp = 0x003D, .a = 0.367, .d = 0.000 }, // =
    .{ .cp = 0x003E, .a = 0.547, .d = 0.047 }, // >
    .{ .cp = 0x0041, .a = 0.716, .d = 0.000 }, // A
    .{ .cp = 0x0042, .a = 0.683, .d = 0.000 }, // B
    .{ .cp = 0x0043, .a = 0.705, .d = 0.022 }, // C
    .{ .cp = 0x0044, .a = 0.683, .d = 0.000 }, // D
    .{ .cp = 0x0045, .a = 0.680, .d = 0.000 }, // E
    .{ .cp = 0x0046, .a = 0.680, .d = 0.000 }, // F
    .{ .cp = 0x0047, .a = 0.705, .d = 0.022 }, // G
    .{ .cp = 0x0048, .a = 0.683, .d = 0.000 }, // H
    .{ .cp = 0x0049, .a = 0.683, .d = 0.000 }, // I
    .{ .cp = 0x004A, .a = 0.683, .d = 0.022 }, // J
    .{ .cp = 0x004B, .a = 0.683, .d = 0.000 }, // K
    .{ .cp = 0x004C, .a = 0.683, .d = 0.000 }, // L
    .{ .cp = 0x004D, .a = 0.683, .d = 0.000 }, // M
    .{ .cp = 0x004E, .a = 0.683, .d = 0.000 }, // N
    .{ .cp = 0x004F, .a = 0.705, .d = 0.022 }, // O
    .{ .cp = 0x0050, .a = 0.683, .d = 0.000 }, // P
    .{ .cp = 0x0051, .a = 0.705, .d = 0.194 }, // Q
    .{ .cp = 0x0052, .a = 0.683, .d = 0.022 }, // R
    .{ .cp = 0x0053, .a = 0.705, .d = 0.022 }, // S
    .{ .cp = 0x0054, .a = 0.677, .d = 0.000 }, // T
    .{ .cp = 0x0055, .a = 0.683, .d = 0.022 }, // U
    .{ .cp = 0x0056, .a = 0.683, .d = 0.022 }, // V
    .{ .cp = 0x0057, .a = 0.683, .d = 0.022 }, // W
    .{ .cp = 0x0058, .a = 0.683, .d = 0.000 }, // X
    .{ .cp = 0x0059, .a = 0.683, .d = 0.000 }, // Y
    .{ .cp = 0x005A, .a = 0.683, .d = 0.000 }, // Z
    .{ .cp = 0x005B, .a = 0.750, .d = 0.250 }, // [
    .{ .cp = 0x005D, .a = 0.750, .d = 0.250 }, // ]
    .{ .cp = 0x005F, .a = 0.000, .d = 0.140 }, // _
    .{ .cp = 0x0061, .a = 0.448, .d = 0.011 }, // a
    .{ .cp = 0x0062, .a = 0.694, .d = 0.011 }, // b
    .{ .cp = 0x0063, .a = 0.448, .d = 0.011 }, // c
    .{ .cp = 0x0064, .a = 0.694, .d = 0.011 }, // d
    .{ .cp = 0x0065, .a = 0.448, .d = 0.011 }, // e
    .{ .cp = 0x0066, .a = 0.705, .d = 0.000 }, // f
    .{ .cp = 0x0067, .a = 0.453, .d = 0.206 }, // g
    .{ .cp = 0x0068, .a = 0.694, .d = 0.000 }, // h
    .{ .cp = 0x0069, .a = 0.657, .d = 0.000 }, // i
    .{ .cp = 0x006A, .a = 0.657, .d = 0.205 }, // j
    .{ .cp = 0x006B, .a = 0.694, .d = 0.000 }, // k
    .{ .cp = 0x006C, .a = 0.694, .d = 0.000 }, // l
    .{ .cp = 0x006D, .a = 0.442, .d = 0.000 }, // m
    .{ .cp = 0x006E, .a = 0.442, .d = 0.000 }, // n
    .{ .cp = 0x006F, .a = 0.448, .d = 0.011 }, // o
    .{ .cp = 0x0070, .a = 0.442, .d = 0.194 }, // p
    .{ .cp = 0x0071, .a = 0.442, .d = 0.194 }, // q
    .{ .cp = 0x0072, .a = 0.442, .d = 0.000 }, // r
    .{ .cp = 0x0073, .a = 0.448, .d = 0.011 }, // s
    .{ .cp = 0x0074, .a = 0.615, .d = 0.011 }, // t
    .{ .cp = 0x0075, .a = 0.442, .d = 0.011 }, // u
    .{ .cp = 0x0076, .a = 0.431, .d = 0.011 }, // v
    .{ .cp = 0x0077, .a = 0.431, .d = 0.011 }, // w
    .{ .cp = 0x0078, .a = 0.431, .d = 0.000 }, // x
    .{ .cp = 0x0079, .a = 0.431, .d = 0.205 }, // y
    .{ .cp = 0x007A, .a = 0.431, .d = 0.000 }, // z
    .{ .cp = 0x007B, .a = 0.750, .d = 0.250 }, // {
    .{ .cp = 0x007C, .a = 0.750, .d = 0.250 }, // |
    .{ .cp = 0x007D, .a = 0.750, .d = 0.250 }, // }
    .{ .cp = 0x00A3, .a = 0.683, .d = 0.035 }, // £
    .{ .cp = 0x00A5, .a = 0.683, .d = 0.000 }, // ¥
    .{ .cp = 0x00A7, .a = 0.705, .d = 0.205 }, // §
    .{ .cp = 0x00A9, .a = 0.683, .d = 0.000 }, // ©
    .{ .cp = 0x00AC, .a = 0.367, .d = 0.000 }, // ¬
    .{ .cp = 0x00B1, .a = 0.583, .d = 0.084 }, // ±
    .{ .cp = 0x00B6, .a = 0.694, .d = 0.194 }, // ¶
    .{ .cp = 0x00B7, .a = 0.303, .d = 0.000 }, // ·
    .{ .cp = 0x00D7, .a = 0.491, .d = 0.000 }, // ×
    .{ .cp = 0x00F0, .a = 0.695, .d = 0.011 }, // ð
    .{ .cp = 0x00F7, .a = 0.504, .d = 0.004 }, // ÷
    .{ .cp = 0x0131, .a = 0.442, .d = 0.000 }, // ı
    .{ .cp = 0x0237, .a = 0.442, .d = 0.205 }, // ȷ
    .{ .cp = 0x0302, .a = 0.734, .d = 0.000 }, // ̂ \hat (combining circumflex; ink above baseline)
    .{ .cp = 0x0303, .a = 0.746, .d = 0.000 }, // ̃ \tilde (combining tilde)
    .{ .cp = 0x0304, .a = 0.640, .d = 0.000 }, // ̄ \bar (combining macron)
    .{ .cp = 0x0307, .a = 0.677, .d = 0.000 }, // ̇ \dot (combining dot above)
    .{ .cp = 0x0308, .a = 0.672, .d = 0.000 }, // ̈ \ddot (combining diaeresis)
    .{ .cp = 0x0338, .a = 0.750, .d = 0.250 }, // ͸ \not slash (overlay)
    .{ .cp = 0x0391, .a = 0.683, .d = 0.000 }, // Α
    .{ .cp = 0x0392, .a = 0.683, .d = 0.000 }, // Β
    .{ .cp = 0x0393, .a = 0.680, .d = 0.000 }, // Γ
    .{ .cp = 0x0394, .a = 0.716, .d = 0.000 }, // Δ
    .{ .cp = 0x0398, .a = 0.705, .d = 0.022 }, // Θ
    .{ .cp = 0x039B, .a = 0.716, .d = 0.000 }, // Λ
    .{ .cp = 0x039E, .a = 0.677, .d = 0.000 }, // Ξ
    .{ .cp = 0x03A0, .a = 0.680, .d = 0.000 }, // Π
    .{ .cp = 0x03A3, .a = 0.683, .d = 0.000 }, // Σ
    .{ .cp = 0x03A5, .a = 0.705, .d = 0.000 }, // Υ
    .{ .cp = 0x03A6, .a = 0.683, .d = 0.000 }, // Φ
    .{ .cp = 0x03A8, .a = 0.683, .d = 0.000 }, // Ψ
    .{ .cp = 0x03A9, .a = 0.705, .d = 0.000 }, // Ω
    .{ .cp = 0x03B1, .a = 0.442, .d = 0.011 }, // α
    .{ .cp = 0x03B2, .a = 0.706, .d = 0.194 }, // β
    .{ .cp = 0x03B3, .a = 0.442, .d = 0.215 }, // γ
    .{ .cp = 0x03B4, .a = 0.712, .d = 0.011 }, // δ
    .{ .cp = 0x03B5, .a = 0.453, .d = 0.022 }, // ε
    .{ .cp = 0x03B6, .a = 0.697, .d = 0.205 }, // ζ
    .{ .cp = 0x03B7, .a = 0.442, .d = 0.216 }, // η
    .{ .cp = 0x03B8, .a = 0.705, .d = 0.011 }, // θ
    .{ .cp = 0x03B9, .a = 0.442, .d = 0.011 }, // ι
    .{ .cp = 0x03BA, .a = 0.442, .d = 0.011 }, // κ
    .{ .cp = 0x03BB, .a = 0.694, .d = 0.013 }, // λ
    .{ .cp = 0x03BC, .a = 0.442, .d = 0.216 }, // μ
    .{ .cp = 0x03BD, .a = 0.442, .d = 0.000 }, // ν
    .{ .cp = 0x03BE, .a = 0.697, .d = 0.205 }, // ξ
    .{ .cp = 0x03BF, .a = 0.448, .d = 0.011 }, // ο
    .{ .cp = 0x03C0, .a = 0.431, .d = 0.011 }, // π
    .{ .cp = 0x03C1, .a = 0.442, .d = 0.216 }, // ρ
    .{ .cp = 0x03C2, .a = 0.442, .d = 0.108 }, // ς
    .{ .cp = 0x03C3, .a = 0.431, .d = 0.011 }, // σ
    .{ .cp = 0x03C4, .a = 0.431, .d = 0.012 }, // τ
    .{ .cp = 0x03C5, .a = 0.442, .d = 0.011 }, // υ
    .{ .cp = 0x03C6, .a = 0.442, .d = 0.218 }, // φ
    .{ .cp = 0x03C7, .a = 0.442, .d = 0.205 }, // χ
    .{ .cp = 0x03C8, .a = 0.694, .d = 0.205 }, // ψ
    .{ .cp = 0x03C9, .a = 0.442, .d = 0.011 }, // ω
    .{ .cp = 0x03D1, .a = 0.705, .d = 0.011 }, // ϑ
    .{ .cp = 0x03D5, .a = 0.694, .d = 0.205 }, // ϕ
    .{ .cp = 0x03D6, .a = 0.431, .d = 0.011 }, // ϖ
    .{ .cp = 0x03D8, .a = 0.750, .d = 0.250 }, // Ϙ
    .{ .cp = 0x03F1, .a = 0.442, .d = 0.194 }, // ϱ
    .{ .cp = 0x03F5, .a = 0.431, .d = 0.011 }, // ϵ
    .{ .cp = 0x2020, .a = 0.705, .d = 0.216 }, // †
    .{ .cp = 0x2021, .a = 0.705, .d = 0.205 }, // ‡
    .{ .cp = 0x2026, .a = 0.106, .d = 0.000 }, // …
    .{ .cp = 0x2032, .a = 0.748, .d = 0.000 }, // ′
    .{ .cp = 0x2033, .a = 0.748, .d = 0.000 }, // ″
    .{ .cp = 0x2035, .a = 0.748, .d = 0.000 }, // ‵
    .{ .cp = 0x20D7, .a = 0.711, .d = 0.000 }, // ⃗ \vec (combining right arrow above)
    .{ .cp = 0x210E, .a = 0.694, .d = 0.011 }, // ℎ
    .{ .cp = 0x210F, .a = 0.694, .d = 0.011 }, // ℏ
    .{ .cp = 0x2111, .a = 0.686, .d = 0.027 }, // ℑ
    .{ .cp = 0x2113, .a = 0.705, .d = 0.012 }, // ℓ
    .{ .cp = 0x2118, .a = 0.453, .d = 0.216 }, // ℘
    .{ .cp = 0x211C, .a = 0.686, .d = 0.027 }, // ℜ
    .{ .cp = 0x2127, .a = 0.684, .d = 0.021 }, // ℧
    .{ .cp = 0x2135, .a = 0.693, .d = 0.000 }, // ℵ
    .{ .cp = 0x2190, .a = 0.510, .d = 0.010 }, // ←
    .{ .cp = 0x2191, .a = 0.679, .d = 0.203 }, // ↑
    .{ .cp = 0x2192, .a = 0.510, .d = 0.010 }, // →
    .{ .cp = 0x2193, .a = 0.703, .d = 0.179 }, // ↓
    .{ .cp = 0x2194, .a = 0.510, .d = 0.010 }, // ↔
    .{ .cp = 0x2195, .a = 0.757, .d = 0.257 }, // ↕
    .{ .cp = 0x2196, .a = 0.714, .d = 0.203 }, // ↖
    .{ .cp = 0x2197, .a = 0.714, .d = 0.203 }, // ↗
    .{ .cp = 0x2198, .a = 0.703, .d = 0.214 }, // ↘
    .{ .cp = 0x2199, .a = 0.703, .d = 0.214 }, // ↙
    .{ .cp = 0x21A3, .a = 0.510, .d = 0.010 }, // ↣
    .{ .cp = 0x21A6, .a = 0.510, .d = 0.010 }, // ↦
    .{ .cp = 0x21A9, .a = 0.550, .d = 0.010 }, // ↩
    .{ .cp = 0x21AA, .a = 0.550, .d = 0.010 }, // ↪
    .{ .cp = 0x21BC, .a = 0.503, .d = 0.000 }, // ↼
    .{ .cp = 0x21BD, .a = 0.270, .d = 0.003 }, // ↽
    .{ .cp = 0x21C0, .a = 0.503, .d = 0.000 }, // ⇀
    .{ .cp = 0x21C1, .a = 0.270, .d = 0.003 }, // ⇁
    .{ .cp = 0x21C4, .a = 0.672, .d = 0.172 }, // ⇄
    .{ .cp = 0x21D0, .a = 0.520, .d = 0.020 }, // ⇐
    .{ .cp = 0x21D1, .a = 0.676, .d = 0.203 }, // ⇑
    .{ .cp = 0x21D2, .a = 0.520, .d = 0.020 }, // ⇒
    .{ .cp = 0x21D3, .a = 0.703, .d = 0.176 }, // ⇓
    .{ .cp = 0x21D4, .a = 0.520, .d = 0.020 }, // ⇔
    .{ .cp = 0x21D5, .a = 0.728, .d = 0.228 }, // ⇕
    .{ .cp = 0x2200, .a = 0.684, .d = 0.000 }, // ∀
    .{ .cp = 0x2202, .a = 0.716, .d = 0.022 }, // ∂
    .{ .cp = 0x2203, .a = 0.684, .d = 0.000 }, // ∃
    .{ .cp = 0x2204, .a = 0.789, .d = 0.105 }, // ∄
    .{ .cp = 0x2205, .a = 0.772, .d = 0.078 }, // ∅
    .{ .cp = 0x2207, .a = 0.683, .d = 0.033 }, // ∇
    .{ .cp = 0x2208, .a = 0.543, .d = 0.043 }, // ∈
    .{ .cp = 0x2209, .a = 0.730, .d = 0.230 }, // ∉
    .{ .cp = 0x220B, .a = 0.543, .d = 0.043 }, // ∋
    .{ .cp = 0x220C, .a = 0.730, .d = 0.230 }, // ∌
    .{ .cp = 0x220F, .a = 0.750, .d = 0.250 }, // ∏
    .{ .cp = 0x2210, .a = 0.750, .d = 0.250 }, // ∐
    .{ .cp = 0x2211, .a = 0.750, .d = 0.250 }, // ∑
    .{ .cp = 0x2212, .a = 0.270, .d = 0.000 }, // −
    .{ .cp = 0x2213, .a = 0.584, .d = 0.083 }, // ∓
    .{ .cp = 0x2215, .a = 0.603, .d = 0.103 }, // ∕
    .{ .cp = 0x2216, .a = 0.603, .d = 0.103 }, // ∖
    .{ .cp = 0x2217, .a = 0.462, .d = 0.000 }, // ∗
    .{ .cp = 0x2218, .a = 0.400, .d = 0.000 }, // ∘
    .{ .cp = 0x2219, .a = 0.445, .d = 0.000 }, // ∙
    .{ .cp = 0x221A, .a = 0.040, .d = 0.960 }, // √
    .{ .cp = 0x221D, .a = 0.442, .d = 0.011 }, // ∝
    .{ .cp = 0x221E, .a = 0.442, .d = 0.011 }, // ∞
    .{ .cp = 0x2220, .a = 0.724, .d = 0.000 }, // ∠
    .{ .cp = 0x2221, .a = 0.724, .d = 0.109 }, // ∡
    .{ .cp = 0x2222, .a = 0.562, .d = 0.062 }, // ∢
    .{ .cp = 0x2223, .a = 0.750, .d = 0.250 }, // ∣
    .{ .cp = 0x2224, .a = 0.750, .d = 0.250 }, // ∤
    .{ .cp = 0x2225, .a = 0.750, .d = 0.250 }, // ∥
    .{ .cp = 0x2226, .a = 0.750, .d = 0.250 }, // ∦
    .{ .cp = 0x2227, .a = 0.602, .d = 0.020 }, // ∧
    .{ .cp = 0x2228, .a = 0.601, .d = 0.021 }, // ∨
    .{ .cp = 0x2229, .a = 0.604, .d = 0.020 }, // ∩
    .{ .cp = 0x222A, .a = 0.604, .d = 0.020 }, // ∪
    .{ .cp = 0x222B, .a = 0.805, .d = 0.306 }, // ∫
    .{ .cp = 0x222E, .a = 0.805, .d = 0.306 }, // ∮
    .{ .cp = 0x2234, .a = 0.416, .d = 0.000 }, // ∴
    .{ .cp = 0x2235, .a = 0.416, .d = 0.000 }, // ∵
    .{ .cp = 0x2236, .a = 0.422, .d = 0.000 }, // ∶
    .{ .cp = 0x2237, .a = 0.422, .d = 0.000 }, // ∷
    .{ .cp = 0x223C, .a = 0.366, .d = 0.000 }, // ∼
    .{ .cp = 0x2240, .a = 0.583, .d = 0.083 }, // ≀
    .{ .cp = 0x2241, .a = 0.482, .d = 0.000 }, // ≁
    .{ .cp = 0x2243, .a = 0.468, .d = 0.000 }, // ≃
    .{ .cp = 0x2244, .a = 0.603, .d = 0.103 }, // ≄
    .{ .cp = 0x2245, .a = 0.552, .d = 0.000 }, // ≅
    .{ .cp = 0x2246, .a = 0.614, .d = 0.048 }, // ≆
    .{ .cp = 0x2247, .a = 0.603, .d = 0.103 }, // ≇
    .{ .cp = 0x2248, .a = 0.457, .d = 0.000 }, // ≈
    .{ .cp = 0x2249, .a = 0.603, .d = 0.103 }, // ≉
    .{ .cp = 0x224D, .a = 0.498, .d = 0.000 }, // ≍
    .{ .cp = 0x2250, .a = 0.601, .d = 0.000 }, // ≐
    .{ .cp = 0x2254, .a = 0.422, .d = 0.000 }, // ⋔
    .{ .cp = 0x2255, .a = 0.422, .d = 0.000 }, // ⋕
    .{ .cp = 0x2260, .a = 0.730, .d = 0.230 }, // ≠
    .{ .cp = 0x2261, .a = 0.464, .d = 0.000 }, // ≡
    .{ .cp = 0x2262, .a = 0.730, .d = 0.230 }, // ≢
    .{ .cp = 0x2264, .a = 0.631, .d = 0.119 }, // ≤
    .{ .cp = 0x2265, .a = 0.631, .d = 0.119 }, // ≥
    .{ .cp = 0x2266, .a = 0.715, .d = 0.203 }, // ≦
    .{ .cp = 0x2267, .a = 0.715, .d = 0.203 }, // ≧
    .{ .cp = 0x226A, .a = 0.547, .d = 0.047 }, // ≪
    .{ .cp = 0x226B, .a = 0.547, .d = 0.047 }, // ≫
    .{ .cp = 0x226D, .a = 0.730, .d = 0.230 }, // ≭
    .{ .cp = 0x226E, .a = 0.730, .d = 0.230 }, // ≮
    .{ .cp = 0x226F, .a = 0.730, .d = 0.230 }, // ≯
    .{ .cp = 0x2270, .a = 0.730, .d = 0.230 }, // ≰
    .{ .cp = 0x2271, .a = 0.730, .d = 0.230 }, // ≱
    .{ .cp = 0x227A, .a = 0.547, .d = 0.047 }, // ≺
    .{ .cp = 0x227B, .a = 0.547, .d = 0.047 }, // ≻
    .{ .cp = 0x2280, .a = 0.730, .d = 0.230 }, // ⊀
    .{ .cp = 0x2281, .a = 0.730, .d = 0.230 }, // ⊁
    .{ .cp = 0x2282, .a = 0.543, .d = 0.043 }, // ⊂
    .{ .cp = 0x2283, .a = 0.543, .d = 0.043 }, // ⊃
    .{ .cp = 0x2284, .a = 0.730, .d = 0.230 }, // ⊄
    .{ .cp = 0x2285, .a = 0.730, .d = 0.230 }, // ⊅
    .{ .cp = 0x2286, .a = 0.627, .d = 0.127 }, // ⊆
    .{ .cp = 0x2287, .a = 0.627, .d = 0.127 }, // ⊇
    .{ .cp = 0x2288, .a = 0.730, .d = 0.230 }, // ⊈
    .{ .cp = 0x2289, .a = 0.730, .d = 0.230 }, // ⊉
    .{ .cp = 0x228E, .a = 0.604, .d = 0.020 }, // ⊎
    .{ .cp = 0x2291, .a = 0.627, .d = 0.127 }, // ⊑
    .{ .cp = 0x2292, .a = 0.627, .d = 0.127 }, // ⊒
    .{ .cp = 0x2293, .a = 0.604, .d = 0.020 }, // ⊓
    .{ .cp = 0x2294, .a = 0.604, .d = 0.020 }, // ⊔
    .{ .cp = 0x2295, .a = 0.592, .d = 0.092 }, // ⊕
    .{ .cp = 0x2296, .a = 0.592, .d = 0.092 }, // ⊖
    .{ .cp = 0x2297, .a = 0.592, .d = 0.092 }, // ⊗
    .{ .cp = 0x2298, .a = 0.592, .d = 0.092 }, // ⊘
    .{ .cp = 0x2299, .a = 0.592, .d = 0.092 }, // ⊙
    .{ .cp = 0x22A2, .a = 0.684, .d = 0.000 }, // ⊢
    .{ .cp = 0x22A3, .a = 0.684, .d = 0.000 }, // ⊣
    .{ .cp = 0x22A4, .a = 0.664, .d = 0.020 }, // ⊤
    .{ .cp = 0x22A5, .a = 0.684, .d = 0.000 }, // ⊥
    .{ .cp = 0x22A8, .a = 0.684, .d = 0.000 }, // ⊨
    .{ .cp = 0x22AC, .a = 0.684, .d = 0.000 }, // ⊬
    .{ .cp = 0x22C0, .a = 0.750, .d = 0.250 }, // ⋀
    .{ .cp = 0x22C1, .a = 0.764, .d = 0.280 }, // ⋁
    .{ .cp = 0x22C2, .a = 0.772, .d = 0.250 }, // ⋂
    .{ .cp = 0x22C3, .a = 0.750, .d = 0.272 }, // ⋃
    .{ .cp = 0x22C4, .a = 0.480, .d = 0.000 }, // ⋄
    .{ .cp = 0x22C5, .a = 0.303, .d = 0.000 }, // ⋅
    .{ .cp = 0x22C6, .a = 0.486, .d = 0.000 }, // ⋆
    .{ .cp = 0x22C8, .a = 0.505, .d = 0.005 }, // ⋈
    .{ .cp = 0x22D8, .a = 0.547, .d = 0.047 }, // ⋘
    .{ .cp = 0x22D9, .a = 0.547, .d = 0.047 }, // ⋙
    .{ .cp = 0x22E0, .a = 0.730, .d = 0.230 }, // ⋠
    .{ .cp = 0x22E1, .a = 0.730, .d = 0.230 }, // ⋡
    .{ .cp = 0x22EF, .a = 0.445, .d = 0.000 }, // ⋯
    .{ .cp = 0x2308, .a = 0.750, .d = 0.250 }, // ⌈
    .{ .cp = 0x2309, .a = 0.750, .d = 0.250 }, // ⌉
    .{ .cp = 0x230A, .a = 0.750, .d = 0.250 }, // ⌊
    .{ .cp = 0x230B, .a = 0.750, .d = 0.250 }, // ⌋
    .{ .cp = 0x2322, .a = 0.381, .d = 0.000 }, // ⌢
    .{ .cp = 0x2323, .a = 0.371, .d = 0.000 }, // ⌣
    .{ .cp = 0x25A0, .a = 0.583, .d = 0.083 }, // ■
    .{ .cp = 0x25A1, .a = 0.583, .d = 0.083 }, // □
    .{ .cp = 0x25B3, .a = 0.741, .d = 0.005 }, // △
    .{ .cp = 0x25B9, .a = 0.750, .d = 0.250 }, // ▹
    .{ .cp = 0x25BD, .a = 0.505, .d = 0.241 }, // ▽
    .{ .cp = 0x25C3, .a = 0.750, .d = 0.250 }, // ◃
    .{ .cp = 0x25CA, .a = 0.610, .d = 0.110 }, // ◊
    .{ .cp = 0x25CB, .a = 0.592, .d = 0.092 }, // ○
    .{ .cp = 0x2660, .a = 0.727, .d = 0.130 }, // ♠
    .{ .cp = 0x2661, .a = 0.716, .d = 0.033 }, // ♡
    .{ .cp = 0x2662, .a = 0.727, .d = 0.163 }, // ♢
    .{ .cp = 0x2663, .a = 0.727, .d = 0.130 }, // ♣
    .{ .cp = 0x266D, .a = 0.750, .d = 0.022 }, // ♭
    .{ .cp = 0x266E, .a = 0.728, .d = 0.217 }, // ♮
    .{ .cp = 0x266F, .a = 0.716, .d = 0.216 }, // ♯
    .{ .cp = 0x2713, .a = 0.699, .d = 0.027 }, // ✓
    .{ .cp = 0x27E8, .a = 0.750, .d = 0.250 }, // ⟨
    .{ .cp = 0x27E9, .a = 0.750, .d = 0.250 }, // ⟩
    .{ .cp = 0x27F5, .a = 0.510, .d = 0.010 }, // ⟵
    .{ .cp = 0x27F6, .a = 0.510, .d = 0.010 }, // ⟶
    .{ .cp = 0x27F7, .a = 0.510, .d = 0.010 }, // ⟷
    .{ .cp = 0x27F8, .a = 0.520, .d = 0.020 }, // ⟸
    .{ .cp = 0x27F9, .a = 0.520, .d = 0.020 }, // ⟹
    .{ .cp = 0x27FA, .a = 0.520, .d = 0.020 }, // ⟺
    .{ .cp = 0x2912, .a = 0.750, .d = 0.250 }, // ⤒
    .{ .cp = 0x29EB, .a = 0.750, .d = 0.250 }, // ⧫
    .{ .cp = 0x2A00, .a = 0.743, .d = 0.243 }, // ⨀
    .{ .cp = 0x2A01, .a = 0.743, .d = 0.243 }, // ⨁
    .{ .cp = 0x2A02, .a = 0.743, .d = 0.243 }, // ⨂
    .{ .cp = 0x2A04, .a = 0.750, .d = 0.272 }, // ⨄
    .{ .cp = 0x2A05, .a = 0.764, .d = 0.264 }, // ⨅
    .{ .cp = 0x2A06, .a = 0.764, .d = 0.264 }, // ⨆
    .{ .cp = 0x2A2F, .a = 0.496, .d = 0.000 }, // ⨯
    .{ .cp = 0x2A3F, .a = 0.683, .d = 0.000 }, // ⨿
    .{ .cp = 0x2A7D, .a = 0.634, .d = 0.134 }, // ⩽
    .{ .cp = 0x2A7E, .a = 0.634, .d = 0.134 }, // ⩾
    .{ .cp = 0x2AAF, .a = 0.631, .d = 0.119 }, // ⪯
    .{ .cp = 0x2AB0, .a = 0.631, .d = 0.119 }, // ⪰
    .{ .cp = 0x1D434, .a = 0.716, .d = 0.000 }, // 𝐴
    .{ .cp = 0x1D435, .a = 0.683, .d = 0.000 }, // 𝐵
    .{ .cp = 0x1D436, .a = 0.705, .d = 0.022 }, // 𝐶
    .{ .cp = 0x1D437, .a = 0.683, .d = 0.000 }, // 𝐷
    .{ .cp = 0x1D438, .a = 0.680, .d = 0.000 }, // 𝐸
    .{ .cp = 0x1D439, .a = 0.680, .d = 0.000 }, // 𝐹
    .{ .cp = 0x1D43A, .a = 0.705, .d = 0.022 }, // 𝐺
    .{ .cp = 0x1D43B, .a = 0.683, .d = 0.000 }, // 𝐻
    .{ .cp = 0x1D43C, .a = 0.683, .d = 0.000 }, // 𝐼
    .{ .cp = 0x1D43D, .a = 0.683, .d = 0.022 }, // 𝐽
    .{ .cp = 0x1D43E, .a = 0.683, .d = 0.000 }, // 𝐾
    .{ .cp = 0x1D43F, .a = 0.683, .d = 0.000 }, // 𝐿
    .{ .cp = 0x1D440, .a = 0.683, .d = 0.000 }, // 𝑀
    .{ .cp = 0x1D441, .a = 0.683, .d = 0.000 }, // 𝑁
    .{ .cp = 0x1D442, .a = 0.705, .d = 0.022 }, // 𝑂
    .{ .cp = 0x1D443, .a = 0.683, .d = 0.000 }, // 𝑃
    .{ .cp = 0x1D444, .a = 0.705, .d = 0.194 }, // 𝑄
    .{ .cp = 0x1D445, .a = 0.683, .d = 0.022 }, // 𝑅
    .{ .cp = 0x1D446, .a = 0.705, .d = 0.022 }, // 𝑆
    .{ .cp = 0x1D447, .a = 0.677, .d = 0.000 }, // 𝑇
    .{ .cp = 0x1D448, .a = 0.683, .d = 0.022 }, // 𝑈
    .{ .cp = 0x1D449, .a = 0.683, .d = 0.022 }, // 𝑉
    .{ .cp = 0x1D44A, .a = 0.683, .d = 0.022 }, // 𝑊
    .{ .cp = 0x1D44B, .a = 0.683, .d = 0.000 }, // 𝑋
    .{ .cp = 0x1D44C, .a = 0.683, .d = 0.000 }, // 𝑌
    .{ .cp = 0x1D44D, .a = 0.683, .d = 0.000 }, // 𝑍
    .{ .cp = 0x1D44E, .a = 0.442, .d = 0.011 }, // 𝑎
    .{ .cp = 0x1D44F, .a = 0.694, .d = 0.011 }, // 𝑏
    .{ .cp = 0x1D450, .a = 0.442, .d = 0.011 }, // 𝑐
    .{ .cp = 0x1D451, .a = 0.694, .d = 0.011 }, // 𝑑
    .{ .cp = 0x1D452, .a = 0.442, .d = 0.011 }, // 𝑒
    .{ .cp = 0x1D453, .a = 0.705, .d = 0.205 }, // 𝑓
    .{ .cp = 0x1D454, .a = 0.442, .d = 0.205 }, // 𝑔
    .{ .cp = 0x1D456, .a = 0.661, .d = 0.011 }, // 𝑖
    .{ .cp = 0x1D457, .a = 0.661, .d = 0.205 }, // 𝑗
    .{ .cp = 0x1D458, .a = 0.694, .d = 0.011 }, // 𝑘
    .{ .cp = 0x1D459, .a = 0.694, .d = 0.011 }, // 𝑙
    .{ .cp = 0x1D45A, .a = 0.442, .d = 0.011 }, // 𝑚
    .{ .cp = 0x1D45B, .a = 0.442, .d = 0.011 }, // 𝑛
    .{ .cp = 0x1D45C, .a = 0.442, .d = 0.011 }, // 𝑜
    .{ .cp = 0x1D45D, .a = 0.442, .d = 0.194 }, // 𝑝
    .{ .cp = 0x1D45E, .a = 0.442, .d = 0.194 }, // 𝑞
    .{ .cp = 0x1D45F, .a = 0.442, .d = 0.011 }, // 𝑟
    .{ .cp = 0x1D460, .a = 0.442, .d = 0.011 }, // 𝑠
    .{ .cp = 0x1D461, .a = 0.626, .d = 0.011 }, // 𝑡
    .{ .cp = 0x1D462, .a = 0.442, .d = 0.011 }, // 𝑢
    .{ .cp = 0x1D463, .a = 0.442, .d = 0.011 }, // 𝑣
    .{ .cp = 0x1D464, .a = 0.442, .d = 0.011 }, // 𝑤
    .{ .cp = 0x1D465, .a = 0.442, .d = 0.011 }, // 𝑥
    .{ .cp = 0x1D466, .a = 0.442, .d = 0.205 }, // 𝑦
    .{ .cp = 0x1D467, .a = 0.442, .d = 0.011 }, // 𝑧
    // Math-italic Greek (U+1D6FC..U+1D714 α–ω run + variant slots
    // U+1D716/1D717/1D719/1D71A/1D71B), the mapped forms of the parser's
    // \alpha..\omega and \varepsilon \vartheta \varphi \varpi \varrho —
    // measured with fontTools BoundsPen on latinmodern-math.otf (nearly
    // identical extents to the upright Greek rows; LM Math draws the italic
    // forms with slightly slanted, distinct outlines).
    .{ .cp = 0x1D6FC, .a = 0.442, .d = 0.011 }, // 𝛼
    .{ .cp = 0x1D6FD, .a = 0.706, .d = 0.194 }, // 𝛽
    .{ .cp = 0x1D6FE, .a = 0.442, .d = 0.215 }, // 𝛾
    .{ .cp = 0x1D6FF, .a = 0.712, .d = 0.011 }, // 𝛿
    .{ .cp = 0x1D700, .a = 0.453, .d = 0.022 }, // 𝜀
    .{ .cp = 0x1D701, .a = 0.697, .d = 0.205 }, // 𝜁
    .{ .cp = 0x1D702, .a = 0.442, .d = 0.216 }, // 𝜂
    .{ .cp = 0x1D703, .a = 0.705, .d = 0.011 }, // 𝜃
    .{ .cp = 0x1D704, .a = 0.442, .d = 0.011 }, // 𝜄
    .{ .cp = 0x1D705, .a = 0.442, .d = 0.011 }, // 𝜅
    .{ .cp = 0x1D706, .a = 0.694, .d = 0.013 }, // 𝜆
    .{ .cp = 0x1D707, .a = 0.442, .d = 0.216 }, // 𝜇
    .{ .cp = 0x1D708, .a = 0.442, .d = 0.000 }, // 𝜈
    .{ .cp = 0x1D709, .a = 0.697, .d = 0.205 }, // 𝜉
    .{ .cp = 0x1D70A, .a = 0.442, .d = 0.011 }, // 𝜊
    .{ .cp = 0x1D70B, .a = 0.431, .d = 0.011 }, // 𝜋
    .{ .cp = 0x1D70C, .a = 0.442, .d = 0.216 }, // 𝜌
    .{ .cp = 0x1D70D, .a = 0.442, .d = 0.108 }, // 𝜍
    .{ .cp = 0x1D70E, .a = 0.431, .d = 0.011 }, // 𝜎
    .{ .cp = 0x1D70F, .a = 0.431, .d = 0.012 }, // 𝜏
    .{ .cp = 0x1D710, .a = 0.442, .d = 0.011 }, // 𝜐
    .{ .cp = 0x1D711, .a = 0.442, .d = 0.218 }, // 𝜑
    .{ .cp = 0x1D712, .a = 0.442, .d = 0.205 }, // 𝜒
    .{ .cp = 0x1D713, .a = 0.694, .d = 0.205 }, // 𝜓
    .{ .cp = 0x1D714, .a = 0.442, .d = 0.011 }, // 𝜔
    // Math-italic ∂ U+1D715 — the SAME ink extents as the upright U+2202
    // (0.716 asc / 0.022 desc, measured with fontTools: LM Math draws the
    // two forms with identical vertical extents).
    .{ .cp = 0x1D715, .a = 0.716, .d = 0.022 }, // 𝜕
    .{ .cp = 0x1D716, .a = 0.431, .d = 0.011 }, // 𝜖
    .{ .cp = 0x1D717, .a = 0.705, .d = 0.011 }, // 𝜗
    .{ .cp = 0x1D719, .a = 0.694, .d = 0.205 }, // 𝜙
    .{ .cp = 0x1D71A, .a = 0.442, .d = 0.194 }, // 𝜚
    .{ .cp = 0x1D71B, .a = 0.431, .d = 0.011 }, // 𝜛
};

/// The drawn glyph's ink extents of a big operator, in em of the glyph's
/// font-size (measured with fontTools on latinmodern-math.otf 2.005).
/// Latin Modern Math draws every big op AXIS-CENTERED — ∑/∏/∐ ink
/// +0.750/−0.250em, ∫/∮ +0.805/−0.306em, ⋂ +0.772/−0.250, ⋃ +0.750/−0.272,
/// ⨆ +0.764/−0.264 (the font MATH axis is 0.250em) — unlike cmex10 whose
/// glyphs hang almost entirely below the baseline. The big-op BOX takes
/// its WIDTH from the hmtx ADVANCE (below) and its height/depth from this
/// ink, at the drawn glyph size,
/// so the viewBox bounds the real ink, the (h−d)/2 − axis shift every parent
/// applies centers the ink on the math axis (the ink center is
/// (asc−desc)/2 = 0.25em above the glyph baseline, the axis is 0.25em of
/// size_pt, so display ∑/∫ land within ±0.5·gs of the axis with NOTHING
/// clipped; XeTeX-LMMath \showbox confirms: text-style ∫ shift ≈ 0), and
/// the advance/limits/side-script geometry all measure from the true ink
/// width (the old cmex10 width under-sized the box ~1.8×: limits centered
/// on a stub, the next atom overlapped the ink, the frame clipped).
/// Widths are the LATIN-MODERN-MATH hmtx ADVANCE in em of the drawn glyph
/// (measured with fontTools: ∑ 1.056, ∏/∐ 0.944, ⋃/⋂/⨆ 0.833, ∫/∮ 0.665),
/// not the ink-bbox width (∑ 0.943, ∫ 0.553) — the advance is what the
/// rendered glyph occupies, so the box advance matches the drawn ∑/∫
/// exactly.
///
/// DISPLAY style uses the font's display variants (the MATH-table
/// MathGlyphVariantRecords XeTeX selects for display operators — measured
/// from the embedded XeTeX render: display ∑ ink +0.95/−0.45em, advance
/// 1.444em; display ∫ ink +1.361/−0.861em). The limits ops (∑ ∏ ∐ ⋃ ⋂ ⨆)
/// take the variant's FULL box (advance 1.444/1.278/1.111em — verified:
/// the following term in \sum_{i=1}^{n} x_i sits at 1.444em + thin, and the
/// over/under limits center on that box). The nolimits ops (∫ ∮) keep the
/// BASE advance for the horizontal script placement and the row advance
/// (measured: \int_0^1 sup at 0.665em + ic, row advance 0.665 + ic + scripts
/// + thin), but the box HEIGHT/DEPTH come from the display variant (so the
/// beside-script drops measure from the drawn glyph: \int_0^1 sup raise
/// 11.860 = 1.361×10 − 1.75, sub drop 10.008 = 0.861×10 + 1.40).
pub const BigOpInk = struct {
    advance: f32,
    /// Display-variant hmtx advance (em). For limits ops it equals
    /// `advance` (the box takes the variant advance); for the nolimits ∫/∮
    /// the ROW box keeps the base advance while the beside scripts attach
    /// at the variant advance (measured \int_0^1 sup at 0.999em).
    disp_advance: f32,
    asc: f32,
    desc: f32,
    /// MathItalicsCorrection (pt at 10pt): base glyph ic (∫ 3.32) in text
    /// style, display-variant ic (∫ .v1 5.91) in display style.
    ic: f32,
};

/// The big operator's drawn ink/advance/italic correction — the single
/// source for every big-op value: the base glyph in the non-display
/// styles, the font's display variant when `display`.
pub fn bigOpInk(op: atom.BigOp, display: bool) BigOpInk {
    const base = switch (op) {
        .sum => BigOpInk{
            .advance = 1.056,
            .disp_advance = 1.056,
            .asc = 0.750,
            .desc = 0.250,
            .ic = 0,
        }, // U+2211 ∑
        .prod => BigOpInk{
            .advance = 0.944,
            .disp_advance = 0.944,
            .asc = 0.750,
            .desc = 0.250,
            .ic = 0,
        }, // U+220F ∏
        .coprod => BigOpInk{
            .advance = 0.944,
            .disp_advance = 0.944,
            .asc = 0.750,
            .desc = 0.250,
            .ic = 0,
        }, // U+2210 ∐
        .bigcup => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.750,
            .desc = 0.272,
            .ic = 0,
        }, // U+22C3 ⋃
        .bigcap => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.772,
            .desc = 0.250,
            .ic = 0,
        }, // U+22C2 ⋂
        .bigsqcup => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.764,
            .desc = 0.264,
            .ic = 0,
        }, // U+2A06 ⨆
        .int, .oint, .oiint, .oiiint, .ointctrclockwise => BigOpInk{
            .advance = 0.665,
            .disp_advance = 0.665,
            .asc = 0.805,
            .desc = 0.306,
            .ic = 3.32,
        },
        // The \bigXXX family and \bigstar: the BASE glyphs (fontTools
        // hmtx + CFF bounds on latinmodern-math.otf 2.005 — ⨀/⨁/⨂ share
        // one design, so do their numbers).
        .bigodot, .bigoplus, .bigotimes => BigOpInk{
            .advance = 1.111,
            .disp_advance = 1.111,
            .asc = 0.743,
            .desc = 0.243,
            .ic = 0,
        }, // U+2A00/2A01/2A02 ⨀ ⨁ ⨂
        .biguplus => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.750,
            .desc = 0.272,
            .ic = 0,
        }, // U+2A04 ⨄
        .bigsqcap => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.764,
            .desc = 0.264,
            .ic = 0,
        }, // U+2A05 ⨅
        .bigwedge => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.780,
            .desc = 0.264,
            .ic = 0,
        }, // U+22C0 ⋀
        .bigvee => BigOpInk{
            .advance = 0.833,
            .disp_advance = 0.833,
            .asc = 0.764,
            .desc = 0.280,
            .ic = 0,
        }, // U+22C1 ⋁
        // U+22C6 ⋆ has no vertical size variant in Latin Modern Math, so
        // the base glyph IS the display form (ic 0.025em = 0.25pt at 10pt).
        .bigstar => BigOpInk{
            .advance = 0.500,
            .disp_advance = 0.500,
            .asc = 0.486,
            .desc = 0.000,
            .ic = 0.25,
        },
        // The BIG integrals: the plain integral glyphs scaled by
        // layout.bigOpScale (2.488 — the `bigints` package's \Huge), since
        // Unicode has no big-integral codepoint. Every field is the plain
        // integral's × 2.488: ∫ 0.665/0.805/0.306 and ic 0.332em (3.32pt at
        // 10pt) → 1.655/2.003/0.761 and 8.26; ∬ and ∭ keep their own
        // hmtx advances (fontTools: 1.035 / 1.405em) and U+222C/U+222D are
        // drawn with the same contours and bbox as U+222F/U+2230, so those
        // advances hold for them too.
        .bigint => BigOpInk{
            .advance = 1.655,
            .disp_advance = 1.655,
            .asc = 2.003,
            .desc = 0.761,
            .ic = 8.26,
        }, // U+222B ∫ × 2.488
        .bigiint => BigOpInk{
            .advance = 2.575,
            .disp_advance = 2.575,
            .asc = 2.003,
            .desc = 0.761,
            .ic = 8.26,
        }, // U+222C ∬ × 2.488
        .bigiiint => BigOpInk{
            .advance = 3.496,
            .disp_advance = 3.496,
            .asc = 2.003,
            .desc = 0.761,
            .ic = 8.26,
        }, // U+222D ∭ × 2.488
    };
    if (!display) return base;
    // Display variants (summation.v1, integral.v1, ... — hmtx advances and
    // ink measured with fontTools; the ink matches the embedded XeTeX
    // render within 0.001em; the .v1 MathItalicsCorrection values are
    // 0 for the limits ops and 0.591em for ∫/∮).
    return switch (op) {
        .sum => BigOpInk{
            .advance = 1.444,
            .disp_advance = 1.444,
            .asc = 0.950,
            .desc = 0.450,
            .ic = 0,
        },
        .prod => BigOpInk{
            .advance = 1.278,
            .disp_advance = 1.278,
            .asc = 0.950,
            .desc = 0.450,
            .ic = 0,
        },
        .coprod => BigOpInk{
            .advance = 1.278,
            .disp_advance = 1.278,
            .asc = 0.950,
            .desc = 0.450,
            .ic = 0,
        },
        .bigcup => BigOpInk{
            .advance = 1.111,
            .disp_advance = 1.111,
            .asc = 0.917,
            .desc = 0.439,
            .ic = 0,
        },
        .bigcap => BigOpInk{
            .advance = 1.111,
            .disp_advance = 1.111,
            .asc = 0.939,
            .desc = 0.417,
            .ic = 0,
        },
        .bigsqcup => BigOpInk{
            .advance = 1.111,
            .disp_advance = 1.111,
            .asc = 0.936,
            .desc = 0.436,
            .ic = 0,
        },
        .int, .oint, .oiint, .oiiint, .ointctrclockwise => BigOpInk{
            .advance = 0.665,
            .disp_advance = 0.999,
            .asc = 1.361,
            .desc = 0.861,
            .ic = 5.91,
        },
        // The \bigXXX family in display: the .v1 of each ladder
        // (uni2A00.v1 / uni2A01.v1 / uni2A02.v1 / uni2A04.v1 / uni2A05.v1 /
        // uni22C0.v1 / uni22C1.v1 — hmtx advance and CFF ink, fontTools).
        .bigodot, .bigoplus, .bigotimes => BigOpInk{
            .advance = 1.511,
            .disp_advance = 1.511,
            .asc = 0.902,
            .desc = 0.402,
            .ic = 0,
        }, // U+2A00/2A01/2A02 .v1
        .biguplus => BigOpInk{
            .advance = 1.111,
            .disp_advance = 1.111,
            .asc = 0.917,
            .desc = 0.439,
            .ic = 0,
        }, // U+2A04 .v1
        .bigsqcap => BigOpInk{
            .advance = 1.111,
            .disp_advance = 1.111,
            .asc = 0.936,
            .desc = 0.436,
            .ic = 0,
        }, // U+2A05 .v1
        .bigwedge => BigOpInk{
            .advance = 1.111,
            .disp_advance = 1.111,
            .asc = 0.958,
            .desc = 0.436,
            .ic = 0,
        }, // U+22C0 .v1
        .bigvee => BigOpInk{
            .advance = 1.111,
            .disp_advance = 1.111,
            .asc = 0.936,
            .desc = 0.458,
            .ic = 0,
        }, // U+22C1 .v1
        // U+22C6 ⋆: no .v1, so the base glyph stands in for the display form
        // (the rasterizer degrades a missing rung to the base glyph).
        .bigstar => BigOpInk{
            .advance = 0.500,
            .disp_advance = 0.500,
            .asc = 0.486,
            .desc = 0.000,
            .ic = 0.25,
        },
        // The BIG integrals have no .v1 either — the integral ladder is base
        // + integral.v1 — so display keeps the scaled base row.
        .bigint => BigOpInk{
            .advance = 1.655,
            .disp_advance = 1.655,
            .asc = 2.003,
            .desc = 0.761,
            .ic = 8.26,
        }, // U+222B ∫ × 2.488
        .bigiint => BigOpInk{
            .advance = 2.575,
            .disp_advance = 2.575,
            .asc = 2.003,
            .desc = 0.761,
            .ic = 8.26,
        }, // U+222C ∬ × 2.488
        .bigiiint => BigOpInk{
            .advance = 3.496,
            .disp_advance = 3.496,
            .asc = 2.003,
            .desc = 0.761,
            .ic = 8.26,
        }, // U+222D ∭ × 2.488
    };
}

/// Binary search over `tbl` for `cp`.
fn search(tbl: []const Entry, cp: u21) ?Entry {
    var lo: usize = 0;
    var hi: usize = tbl.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (tbl[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < tbl.len and tbl[lo].cp == cp) return tbl[lo];
    return null;
}

/// True for a style drawn from one of the four embedded LM Roman faces.
pub fn isTextFace(style: atom.CharStyle) bool {
    return style == .roman or style == .bold or style == .text_italic or
        style == .bold_italic;
}

/// Exact advance and ink of the embedded text face, in the 10pt-base convention.
/// Text faces have no MATH table, so their italic correction is zero.
pub fn textFaceGlyph(style: atom.CharStyle, cp: u21) ?Glyph {
    const tbl: []const roman_style_metrics.Entry = switch (style) {
        .roman => roman_style_metrics.roman,
        .text_italic => roman_style_metrics.italic,
        .bold => roman_style_metrics.bold,
        .bold_italic => roman_style_metrics.bold_italic,
        else => return null,
    };
    const e = roman_style_metrics.lookup(tbl, cp) orelse return null;
    return .{
        .width = e.w,
        .height = e.h,
        .depth = e.d,
        .italic_correction = e.ic,
    };
}

/// Exact LM Math rows for a codepoint remapped into a mathematical alphabet.
fn mappedRow(style: atom.CharStyle, cp: u21) ?math_style_metrics.Row {
    const tbl: []const math_style_metrics.Row = switch (style) {
        .sans => math_style_metrics.sans,
        .mono => math_style_metrics.mono,
        .bb, .cal, .frak => &math_style_metrics.alphabets,
        else => return null,
    };
    return math_style_metrics.lookup(tbl, cp);
}

/// Metrics for a codepoint the layout REMAPPED, measured by the glyph that is
/// actually drawn: the generated hmtx advance and MATH italic correction, and
/// the height and depth from the ink row of the face those glyphs come from
/// (`ink_metrics.math`, measured from the same bytes). Consulted before the
/// ASCII fast path and before every optical band, which describe the upright
/// ASCII design and never the math sans-serif / monospace one — without it a
/// `\mathsf` or `\mathtt` run advances by the 0.5em estimate while the
/// sans-serif or monospace glyph is what gets painted.
///
/// A prime composite is size-aware for the same reason: at script size the
/// face draws its unencoded alternates — the hook measures them from the
/// real face — and this table carries the same advances for a run measured
/// without one.
fn generatedGlyph(cp: u21, style: atom.CharStyle, size_pt: f32) ?Glyph {
    if (smallPrimeGlyph(cp, style, size_pt)) |g| return g;
    const row = mappedRow(style, cp) orelse
        math_style_metrics.lookup(math_style_metrics.primes, cp) orelse return null;
    // `.italic` names the math face — the face every generated row is drawn
    // from, so the ink is that face's own outline for the same codepoint.
    const ink = faceGlyphInk(cp, .italic) orelse fallbackInk(cp, style);
    return .{
        .width = row.adv * em,
        .height = ink.asc * em,
        .depth = ink.desc * em,
        .italic_correction = (row.ic orelse 0) * em,
    };
}

/// Drawn size in points at and below which the prime composites are the face's
/// unencoded alternates instead of the cmap's own. Mirrors
/// `font.small_prime_max_size`: the ztex.layout module cannot import
/// ztex.font, so the one number both sides gate on is stated on both sides and
/// pinned by a test on each.
const small_prime_max_size: f32 = 6.0;

/// The script-size prime composites in em: LM Math's unencoded alternates for a
/// run of one to four primes, on its own 0.3em advance grid — the same hmtx
/// advances the font hook reads from the face for a run measured with one.
fn smallPrimeEm(cp: u21) ?f32 {
    return switch (cp) {
        0x2032 => 0.489,
        0x2033 => 0.789,
        0x2034 => 1.089,
        0x2057 => 1.389,
        else => null,
    };
}

/// A prime composite drawn at script size: the alternate's advance, with the
/// face's own ink row for its height and depth. Every other codepoint, and
/// every size above the gate, keeps the row it always had.
fn smallPrimeGlyph(cp: u21, style: atom.CharStyle, size_pt: f32) ?Glyph {
    if (size_pt > small_prime_max_size) return null;
    const adv = smallPrimeEm(cp) orelse return null;
    const ink = faceGlyphInk(cp, .italic) orelse fallbackInk(cp, style);
    return .{
        .width = adv * em,
        .height = ink.asc * em,
        .depth = ink.desc * em,
        .italic_correction = 0,
    };
}

/// The MATH top-accent attachment of a remapped alphabet glyph, in em: the
/// face records one for every math sans-serif and monospace letter and digit,
/// so a hat over `\mathsf{A}` lands where the font says instead of centred on
/// the box. The two series occupy disjoint codepoint ranges, so the style that
/// produced the codepoint is implied by the codepoint itself.
fn generatedTopAccent(cp: u21) ?f32 {
    const row = math_style_metrics.lookup(math_style_metrics.sans, cp) orelse
        math_style_metrics.lookup(math_style_metrics.mono, cp) orelse
        math_style_metrics.lookup(&math_style_metrics.alphabets, cp) orelse return null;
    return row.top;
}

/// Legacy fallback rows for glyphs absent from the generated face tables.
/// Values use the same 10pt-base convention (em × 10). No text style reaches
/// here: `textFaceGlyph` answers every codepoint its own face carries first.
fn tableFor(style: atom.CharStyle, size_pt: f32) []const Entry {
    const band7 = size_pt > 6.4 and size_pt < 7.6;
    const band5 = size_pt > 4.5 and size_pt < 5.5;
    if (style == .bb) {
        return &table_bb;
    }
    return if (band7) &table7 else if (band5) &table5 else &table;
}

/// Size-aware lookup in the 10pt-base convention (em × 10).
/// A borrowed font or generated face row answers before legacy optical bands.
pub fn glyphAt(fm: *const FontMetrics, cp: u21, style: atom.CharStyle, size_pt: f32) ?Glyph {
    if (fontGlyph(fm, cp, style, size_pt)) |g| return g;
    // A generated text face is measured by its OWN face, and it answers
    // before every optical band and the ASCII fast path below: none of
    // those tables describe LM Roman Regular / Italic / Bold / Bold Italic.
    if (textFaceGlyph(style, cp)) |g| return g;
    // A codepoint the layout REMAPPED (the math sans-serif / monospace
    // alphabets, the native triple / quadruple prime) answers before every
    // optical band and the ASCII fast path below: none of those tables
    // describe the glyph that gets drawn for it.
    if (generatedGlyph(cp, style, size_pt)) |g| return g;
    // O(1) ASCII fast path (lookupAscii, wired here so layoutChar actually
    // takes it): the LUTs derive from the 10pt `table` and from the generated
    // LM Roman rows, so they are bit-identical to the slow path ONLY outside
    // the 7pt/5pt optical bands — the script-size tables carry their own
    // h/d/ic. Inside the bands — and for the `.font` arm / any
    // fm != `&default` — it returns null and the slow path below runs.
    const band7 = size_pt > 6.4 and size_pt < 7.6;
    const band5 = size_pt > 4.5 and size_pt < 5.5;
    if (!band7 and !band5) {
        if (lookupAscii(fm, cp, style)) |g| return g;
    }
    if (search(tableFor(style, size_pt), cp)) |e| {
        return .{ .width = e.w, .height = e.h, .depth = e.d, .italic_correction = e.ic };
    }
    if (style == .bb) {
        // Fallback to standard table if not found in table_bb
        const tbl = if (band7) &table7 else if (band5) &table5 else &table;
        if (search(tbl, cp)) |e| {
            return .{ .width = e.w, .height = e.h, .depth = e.d, .italic_correction = e.ic };
        }
    }
    return null;
}

/// Fallback vertical ink for a codepoint NO drawing face carries (see
/// `fallbackInk`), in em of the glyph's font-size: `ink_table` by binary
/// search, else the LM Math design bound 0.750/0.250 — the LMMath
/// ascender/descender, safe for the browser's fallback fonts too. Boxing a
/// glyph by the drawn ink rather than the cmr10/cmmi10 h/d is what keeps the
/// frame from clipping (digits 0.666em vs cmr10 0.644em, ∫ sup '1' 9.32pt of
/// ink in a 9.02pt box at 14pt), and `ink_metrics.zig` now carries the exact
/// per-face outlines for every glyph a face does have.
const ascii_ink_lut = blk: {
    var lut: [128]?GlyphInk = undefined;
    for (&lut) |*slot| slot.* = null;
    for (ink_table) |e| {
        if (e.cp < 128) {
            lut[e.cp] = .{ .asc = e.a, .desc = e.d };
        }
    }
    break :blk lut;
};

fn mathInk(cp: u21) GlyphInk {
    if (cp < 128) {
        return ascii_ink_lut[cp] orelse .{ .asc = 0.750, .desc = 0.250 };
    }
    var lo: usize = 0;
    var hi: usize = ink_table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ink_table[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < ink_table.len and ink_table[lo].cp == cp) {
        return .{ .asc = ink_table[lo].a, .desc = ink_table[lo].d };
    }
    return .{ .asc = 0.750, .desc = 0.250 };
}

/// The generated ink of the glyph `cp` in the face `edges`, or null when that
/// face's cmap carries no painted glyph for it. The row is the outline's own
/// box (`ink_metrics.Edge`), measured from the very bytes `font.zig` draws, so
/// the frame encloses the real ink instead of a rounded estimate of it.
fn faceInk(edges: []const ink_metrics.Edge, cp: u21) ?GlyphInk {
    const e = ink_metrics.lookup(edges, cp) orelse return null;
    return .{
        .asc = e.asc,
        .desc = e.desc,
        .left = e.left,
        .right_edge = e.right_edge,
        .bottom = e.bottom,
    };
}

/// The ink rows of the face `style` is DRAWN from — the same face
/// `font.FontContext.faceForStyle` resolves for the metric hook and the
/// rasterizer, so a glyph can never be framed by one face's outline while a
/// different face draws it. Every style that is not one of the four text
/// faces draws from LM Math.
fn inkEdges(style: atom.CharStyle) []const ink_metrics.Edge {
    return switch (style) {
        .roman => ink_metrics.roman,
        .text_italic => ink_metrics.italic,
        .bold => ink_metrics.bold,
        .bold_italic => ink_metrics.bold_italic,
        else => ink_metrics.math,
    };
}

/// The real ink `cp` has in the face `style` is DRAWN from, or null when
/// that face's cmap carries no painted glyph for it — the query a caller
/// asks before it commits to a face for that codepoint: one face's row
/// means the face HAS the glyph, null means it does not.
pub fn faceGlyphInk(cp: u21, style: atom.CharStyle) ?GlyphInk {
    return faceInk(inkEdges(style), cp);
}

/// Ink extents for a codepoint the drawing face has NO row for: an AMS-only
/// symbol, a CJK glyph, anything its cmap does not carry. Nothing is known
/// about the painted outline then, so this is the pre-table behaviour — the
/// text face's own generated h/d where it has one, else `mathInk`'s
/// Latin-Modern-Math rows. Both horizontal extents stay 0: no row means the
/// face's ink was not measured, and unmeasured ink is not invented. A 0
/// `right_edge` is a left-of-origin end, and the consumer's
/// `max(0, right_edge × size − advance)` clamps it to 0 anyway — the frame
/// stays the advance box, the same bounds this fallback always gave.
fn fallbackInk(cp: u21, style: atom.CharStyle) GlyphInk {
    if (textFaceGlyph(style, cp)) |g| {
        return .{ .asc = g.height / em, .desc = g.depth / em };
    }
    return mathInk(cp);
}

/// Ink extents of the DRAWN Latin-Modern-Math glyph for `cp`: the face's own
/// exact outline where it has one, else `fallbackInk`.
pub fn glyphInk(cp: u21) GlyphInk {
    // `.italic` names the math face, so a codepoint it cannot answer falls to
    // the Latin-Modern-Math rows exactly as the pre-table path did.
    return faceInk(ink_metrics.math, cp) orelse fallbackInk(cp, .italic);
}

/// Ink extents of the DRAWN glyph in `style`: its face's OWN real ink, in
/// every direction. A bold or italic letter is a different design — taller,
/// wider — and boxing it by the upright LM Math ink clips it, so `inkEdges`
/// picks the face `font.FontContext.faceForStyle` draws it from: a `\text{f}`
/// is framed by the upright face it is drawn from, not by the math-italic `f`
/// beside it.
///
/// A TEXT face carries no Greek, no AMS symbol, no CJK glyph — for those the
/// Math face's own outline is what gets painted next, so that is the frame:
/// `\mathrm{α}` is boxed by LM Math's α, not by a roman estimate that clips
/// its ink. Only a codepoint no bundled face carries falls back
/// (`fallbackInk`).
pub fn glyphInkAt(cp: u21, style: atom.CharStyle) GlyphInk {
    if (faceGlyphInk(cp, style)) |ink| return ink;
    if (isTextFace(style)) {
        if (faceGlyphInk(cp, .italic)) |ink| return ink;
    }
    return fallbackInk(cp, style);
}

/// One MATH-table vertical size variant of a delimiter (and the base entry):
/// the hmtx ADVANCE and the ink extents, in em of the glyph's font-size.
/// Measured with fontTools on latinmodern-math.otf 2.005 (MathVariants
/// VertGlyphConstruction records + BoundsPen + hmtx). Every LM Math variant
/// keeps its ink CENTER at 0.25em above the baseline (asc − desc = 0.5em),
/// so a variant box placed with shift (asc−desc)/2 − axis sits centered on
/// the math axis exactly like the XeTeX reference.
pub const DelimVariant = struct {
    adv: f32,
    asc: f32,
    desc: f32,
};

/// Per-delimiter variant ladder: entry [0] is the BASE glyph (the
/// non-stretched size), [1..7] the MATH size variants parenleft.v1..v7 etc.
/// The \left..\right layout picks the SMALLEST entry whose ink height
/// (asc + desc) covers the content and boxes the delimiter by that entry's
/// advance/ink at the BASE font size — the same variant ladder XeTeX draws
/// (XeTeX renders the parens of `\left( \frac{\partial L}{\partial \dot{q}}
/// \right)` at the base size from the variant glyphs; the ref measured the
/// paren ink span 2.392em = parenleft.v6's ink).
const delim_ladder = [_]struct { cp: u21, variants: [8]DelimVariant }{
    .{
        .cp = 0x0028,
        .variants = .{
            .{ .adv = 0.389, .asc = 0.748, .desc = 0.248 }, // ( base
            .{ .adv = 0.422, .asc = 0.797, .desc = 0.297 }, // .v1
            .{ .adv = 0.458, .asc = 0.847, .desc = 0.347 }, // .v2
            .{ .adv = 0.523, .asc = 0.972, .desc = 0.472 }, // .v3
            .{ .adv = 0.597, .asc = 1.146, .desc = 0.646 }, // .v4
            .{ .adv = 0.663, .asc = 1.296, .desc = 0.796 }, // .v5
            .{ .adv = 0.736, .asc = 1.446, .desc = 0.946 }, // .v6
            .{ .adv = 0.875, .asc = 1.745, .desc = 1.245 }, // .v7
        },
    },
    .{
        .cp = 0x0029,
        .variants = .{
            .{ .adv = 0.389, .asc = 0.748, .desc = 0.248 }, // ) base
            .{ .adv = 0.422, .asc = 0.797, .desc = 0.297 }, // .v1
            .{ .adv = 0.458, .asc = 0.847, .desc = 0.347 }, // .v2
            .{ .adv = 0.523, .asc = 0.972, .desc = 0.472 }, // .v3
            .{ .adv = 0.597, .asc = 1.146, .desc = 0.646 }, // .v4
            .{ .adv = 0.663, .asc = 1.296, .desc = 0.796 }, // .v5
            .{ .adv = 0.736, .asc = 1.446, .desc = 0.946 }, // .v6
            .{ .adv = 0.875, .asc = 1.745, .desc = 1.245 }, // .v7
        },
    },
    .{
        .cp = 0x005B,
        .variants = .{
            .{ .adv = 0.278, .asc = 0.750, .desc = 0.250 }, // [ base
            .{ .adv = 0.340, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.417, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.444, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.472, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.499, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.528, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.667, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x005D,
        .variants = .{
            .{ .adv = 0.278, .asc = 0.750, .desc = 0.250 }, // ] base
            .{ .adv = 0.340, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.417, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.444, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.472, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.499, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.528, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.667, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x007B,
        .variants = .{
            .{ .adv = 0.500, .asc = 0.750, .desc = 0.250 }, // { base
            .{ .adv = 0.540, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.583, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.624, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.667, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.707, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.750, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.902, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x007D,
        .variants = .{
            .{ .adv = 0.500, .asc = 0.750, .desc = 0.250 }, // } base
            .{ .adv = 0.540, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.583, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.624, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.667, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.707, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.750, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.902, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x27E8,
        .variants = .{
            .{ .adv = 0.389, .asc = 0.750, .desc = 0.250 }, // ⟨ base
            .{ .adv = 0.428, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.537, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.611, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.677, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.750, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.908, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x27E9,
        .variants = .{
            .{ .adv = 0.389, .asc = 0.750, .desc = 0.250 }, // ⟩ base
            .{ .adv = 0.428, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.537, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.611, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.677, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.750, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.908, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x2308,
        .variants = .{
            .{ .adv = 0.444, .asc = 0.750, .desc = 0.250 }, // ⌈ base
            .{ .adv = 0.458, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.499, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.528, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.555, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.583, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.623, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x2309,
        .variants = .{
            .{ .adv = 0.444, .asc = 0.750, .desc = 0.250 }, // ⌉ base
            .{ .adv = 0.458, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.499, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.528, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.555, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.583, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.623, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x230A,
        .variants = .{
            .{ .adv = 0.444, .asc = 0.750, .desc = 0.250 }, // ⌊ base
            .{ .adv = 0.458, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.499, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.528, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.555, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.583, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.623, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x230B,
        .variants = .{
            .{ .adv = 0.444, .asc = 0.750, .desc = 0.250 }, // ⌋ base
            .{ .adv = 0.458, .asc = 0.800, .desc = 0.300 }, // .v1
            .{ .adv = 0.472, .asc = 0.850, .desc = 0.350 }, // .v2
            .{ .adv = 0.499, .asc = 0.975, .desc = 0.475 }, // .v3
            .{ .adv = 0.528, .asc = 1.150, .desc = 0.650 }, // .v4
            .{ .adv = 0.555, .asc = 1.300, .desc = 0.800 }, // .v5
            .{ .adv = 0.583, .asc = 1.450, .desc = 0.950 }, // .v6
            .{ .adv = 0.623, .asc = 1.750, .desc = 1.250 }, // .v7
        },
    },
    .{
        .cp = 0x2223, // ∣ \mid / \middle| — the divides construction
        .variants = .{
            .{ .adv = 0.278, .asc = 0.750, .desc = 0.250 }, // ∣ base
            .{ .adv = 0.278, .asc = 0.851, .desc = 0.351 }, // .v1
            .{ .adv = 0.278, .asc = 0.972, .desc = 0.472 }, // .v2
            .{ .adv = 0.278, .asc = 1.117, .desc = 0.617 }, // .v3
            .{ .adv = 0.278, .asc = 1.292, .desc = 0.792 }, // .v4
            .{ .adv = 0.278, .asc = 1.501, .desc = 1.001 }, // .v5
            .{ .adv = 0.278, .asc = 1.752, .desc = 1.252 }, // .v6
            .{ .adv = 0.278, .asc = 2.053, .desc = 1.553 }, // .v7
        },
    },
    .{
        .cp = 0x007C, // | — \left|, \vert: the bar glyph + divides variants
        .variants = .{
            .{ .adv = 0.278, .asc = 0.750, .desc = 0.250 }, // | base
            .{ .adv = 0.278, .asc = 0.851, .desc = 0.351 }, // .v1
            .{ .adv = 0.278, .asc = 0.972, .desc = 0.472 }, // .v2
            .{ .adv = 0.278, .asc = 1.117, .desc = 0.617 }, // .v3
            .{ .adv = 0.278, .asc = 1.292, .desc = 0.792 }, // .v4
            .{ .adv = 0.278, .asc = 1.501, .desc = 1.001 }, // .v5
            .{ .adv = 0.278, .asc = 1.752, .desc = 1.252 }, // .v6
            .{ .adv = 0.278, .asc = 2.053, .desc = 1.553 }, // .v7
        },
    },
    .{
        .cp = 0x2016, // ‖ — \Vert, \|: the double-vertical-bar construction
        .variants = .{
            .{ .adv = 0.398, .asc = 0.750, .desc = 0.250 }, // ‖ base
            .{ .adv = 0.354, .asc = 0.851, .desc = 0.351 }, // .v1
            .{ .adv = 0.364, .asc = 0.972, .desc = 0.472 }, // .v2
            .{ .adv = 0.372, .asc = 1.117, .desc = 0.617 }, // .v3
            .{ .adv = 0.386, .asc = 1.292, .desc = 0.792 }, // .v4
            .{ .adv = 0.396, .asc = 1.501, .desc = 1.001 }, // .v5
            .{ .adv = 0.410, .asc = 1.752, .desc = 1.252 }, // .v6
            .{ .adv = 0.424, .asc = 2.053, .desc = 1.553 }, // .v7
        },
    },
    .{
        .cp = 0x002F, // / — \left/ (the slash construction)
        .variants = .{
            .{ .adv = 0.500, .asc = 0.750, .desc = 0.250 }, // / base
            .{ .adv = 0.617, .asc = 0.905, .desc = 0.405 }, // .v1
            .{ .adv = 0.768, .asc = 1.108, .desc = 0.608 }, // .v2
            .{ .adv = 0.964, .asc = 1.374, .desc = 0.874 }, // .v3
            .{ .adv = 1.222, .asc = 1.722, .desc = 1.222 }, // .v4
            .{ .adv = 1.557, .asc = 2.179, .desc = 1.679 }, // .v5
            .{ .adv = 1.997, .asc = 2.777, .desc = 2.277 }, // .v6
            .{ .adv = 2.572, .asc = 3.560, .desc = 3.060 }, // .v7
        },
    },
};

/// The MATH size-variant ladder of a delimiter codepoint (( ) [ ] { } ⟨ ⟩
/// ⌈ ⌉ ⌊ ⌋ ∣ | ‖ /), or null when the codepoint is not a table delimiter —
/// the caller then falls back to the continuous scaled-base path (e.g.
/// \left\backslash). The | / ‖ entries let \left| and \middle| pick the
/// REAL divides/parallel/slash variants (measured \middle| at 36pt =
/// divides.v3, ink 1.734em — the |'s smallest variant covering the fence's
/// required ink).
pub fn delimVariants(cp: u21) ?[]const DelimVariant {
    for (&delim_ladder) |*entry| {
        if (entry.cp == cp) return &entry.variants;
    }
    return null;
}
/// MATH-table radical vertical variants of the √ glyph (U+221A), in em of
/// the glyph font-size. Measured with fontTools on latinmodern-math.otf 2.005
/// (MathVariants VertGlyphConstruction records + BoundsPen + hmtx). XeTeX's
/// make_radical reads these to pick the smallest variant whose
/// AdvanceMeasurement covers the required radical height — the variant is
/// then drawn at the CURRENT font size (NOT scaled up), so its width stays
/// slim while its height covers the radicand. Variant 0 is the BASE radical
/// glyph (cmsy10 slot 112): the layout uses it when req_em ≤ 1.001.
pub const radical_variants = [_]DelimVariant{
    .{ .adv = 0.833, .asc = 0.040, .desc = 0.960 }, // radical (base, 1.001em)
    .{ .adv = 1.000, .asc = 0.850, .desc = 0.350 }, // radical.v1 (1.201em)
    .{ .adv = 1.000, .asc = 1.150, .desc = 0.650 }, // radical.v2 (1.801em)
    .{ .adv = 1.000, .asc = 1.450, .desc = 0.950 }, // radical.v3 (2.401em)
    .{ .adv = 1.000, .asc = 1.750, .desc = 1.250 }, // radical.v4 (3.001em)
};
/// MATH AdvanceMeasurements (em) for the radical variants above — the
/// vertical advance XeTeX compares against the required radical height.
const radical_advance_measurements = [_]f32{ 1.001, 1.201, 1.801, 2.401, 3.001 };
/// Select the smallest radical variant whose MATH AdvanceMeasurement covers
/// `req_em` (the required radical height in em = ceil(H + D + clr + θ) / size).
/// Returns the variant index (0 = base, 1 = .v1, …, 4 = .v4).
pub fn radicalVariant(req_em: f32) usize {
    for (radical_advance_measurements, 0..) |adv, i| {
        if (adv >= req_em) return i;
    }
    return radical_variants.len - 1; // .v4 (tallest) if none covers
}

/// Advance (width) of every radical piece in em — all three share the same
/// hmtx 1056/1000em on LM Math (the vertical bar at x=702..742 is constant
/// across the assembly; only the hook (right) and foot (left) extend
/// beyond it, but the advance stays 1.056em).
pub const radical_piece_adv: f32 = 1.056;

/// The ink of one horizontal size variant, in em.
fn rungInk(rung: math_style_metrics.Rung) GlyphInk {
    return .{
        .asc = rung.asc,
        .desc = rung.desc,
        .left = rung.left,
        .right_edge = rung.right_edge,
        .bottom = rung.bottom,
    };
}
/// The overlap ONE connection takes: the floor the font permits, opened by the
/// uniform `open` every join takes and never past the ceiling — the connector
/// ink both neighbouring parts offer at the join. OpenType defines the overlap
/// as an INTERVAL, not a fixed value: "the overlap should not be less than the
/// minConnectorOverlap value … and it should not exceed the specified
/// connector length for that end of the glyph". `open` 0 is therefore the
/// floor itself: the WIDEST legal stack, and the one a repeat count has to be
/// judged against.
fn joinOverlap(
    before: math_style_metrics.Part,
    part: math_style_metrics.Part,
    min_overlap: f32,
    open: f32,
) f32 {
    const ceiling = @min(before.end_connector, part.start_connector);
    return @min(min_overlap + open, ceiling);
}

/// How far ONE connection may open: from the floor up to the ceiling its two
/// parts' connector material allows. Never negative — a font that asks for
/// more overlap than it drew leaves the join where it is.
fn joinRoom(
    before: math_style_metrics.Part,
    part: math_style_metrics.Part,
    min_overlap: f32,
) f32 {
    const ceiling = @min(before.end_connector, part.start_connector);
    return @max(0, ceiling - min_overlap);
}

/// One walk of an assembly's parts: the frame it paints at this repeat count
/// and this opening, and the room its connections still have.
const Walk = struct {
    geometry: StretchGeometry,
    /// the largest opening any single connection still allows
    max_open: f32,
};

/// Walk `ladder` at `repeats` and `open`: the parts in MATH order, each
/// advancing the next by its FullAdvance less the overlap the two share. Every
/// part paints once, except a repeat-flagged one, which contributes `repeats`
/// copies — zero drops it entirely, and the join between the parts that DO
/// paint is then measured straight across it. This is the walk the reference
/// engines paint, so the frame is the ink they draw and not a sum of nominal
/// advances.
fn walkAssembly(
    ladder: math_style_metrics.Ladder,
    repeats: usize,
    open: f32,
) Walk {
    var out: Walk = .{
        .geometry = .{ .advance_em = 0, .ink = .{ .asc = 0, .desc = 0 } },
        .max_open = 0,
    };
    var previous: ?math_style_metrics.Part = null;
    var x: f32 = 0;
    for (ladder.parts) |part| {
        const copies: usize = if (part.repeat) repeats else 1;
        var copy: usize = 0;
        while (copy < copies) : (copy += 1) {
            if (previous) |before| {
                // Every connection counts once: the repeated copies of one
                // extender share their own connectors, and a dropped one
                // leaves no join of its own to measure.
                out.max_open = @max(
                    out.max_open,
                    joinRoom(before, part, ladder.min_connector_overlap),
                );
                x -= joinOverlap(before, part, ladder.min_connector_overlap, open);
            }
            // A part's `left` is ink reaching left of the part's OWN origin,
            // so the placed span runs from x − left to x + right_edge.
            const lo = x - part.left;
            const hi = x + part.right_edge;
            if (previous == null) {
                out.geometry.ink = .{
                    .asc = part.asc,
                    .desc = part.desc,
                    .left = @max(0, -lo),
                    .right_edge = @max(0, hi),
                    .bottom = part.bottom,
                };
            } else {
                const ink = &out.geometry.ink;
                ink.asc = @max(ink.asc, part.asc);
                ink.desc = @max(ink.desc, part.desc);
                ink.bottom = @min(ink.bottom, part.bottom);
                ink.left = @min(ink.left, @max(0, lo));
                ink.right_edge = @max(ink.right_edge, @max(0, hi));
            }
            x += part.adv;
            previous = part;
        }
    }
    out.geometry.advance_em = x;
    return out;
}

/// The largest uniform opening this stack's connections allow: the one that
/// puts every join at its own ceiling, the NARROWEST legal stack. It does not
/// depend on `open` itself, so the walk settles at the floor.
fn maxOpen(ladder: math_style_metrics.Ladder, repeats: usize) f32 {
    return walkAssembly(ladder, repeats, 0).max_open;
}

/// The framed geometry of `ladder` at `repeats` and `open`.
fn assembledStretch(
    ladder: math_style_metrics.Ladder,
    repeats: usize,
    open: f32,
) StretchGeometry {
    return walkAssembly(ladder, repeats, open).geometry;
}

/// The last AdvanceMeasurement of a horizontal ladder that declares NO glyph
/// assembly — the width past which the face has no design left. Null with an
/// assembly: it reaches any width, so there is no ceiling to report, and null
/// with an empty ladder, which names no width at all.
fn finiteCeiling(ladder: math_style_metrics.Ladder) ?f32 {
    if (ladder.parts.len != 0) return null;
    if (ladder.rungs.len == 0) return null;
    return ladder.rungs[ladder.rungs.len - 1].req;
}

/// The generated horizontal geometry for `req_em` (em): the LARGEST MATH size
/// variant whose AdvanceMeasurement still FITS the request, else the assembly
/// of the glyph's own parts, else — when the form declares no assembly — that
/// same last rung, kept at its own advance. Every horizontal form reads this
/// one rule: a ladder is a finite set of real drawings and the item takes the
/// widest one the thing it is set on holds. Measured on this exact Latin
/// Modern Math, XeTeX + unicode-math sizes `\widehat` over `M` (0.970em) with
/// the 0.920em hat (ink 18.24pt at 20pt) and over `abc` (1.391em) with the
/// 1.321em one, and draws the brace half of `\underbrace{x}` — `x` is
/// 0.574em — as the 0.492em rung, under `xx` (1.148em) as the 0.993em one,
/// under `xxx` (1.722em) as the 1.494em one and under `xxxxxx` (3.445em) as
/// the 3.000em one: the largest each nucleus still holds, never the smallest
/// that spans it. A nucleus narrower than every rung keeps the base drawing,
/// and a nucleus wider than every one of them is past the ladder, where the
/// MATH spec builds the item itself: the SMALLEST repeat count whose WIDEST
/// legal stack — the extenders dropped first, every connection at the
/// MinConnectorOverlap floor — reaches the request, then every connection
/// opened by the SAME amount, as little as that request allows. A request no
/// legal stack reaches keeps the narrowest one instead: the joins are never
/// torn to cover it. Only a codepoint with no size construction at all is null
/// — there is no native form to fall back to.
fn staticStretch(cp: u21, req_em: f32) ?StretchGeometry {
    const ladder = math_style_metrics.ladder(cp) orelse return null;
    if (ladder.rungs.len == 0) return null;
    // The widest rung the request still holds: the one an item draws.
    var chosen = ladder.rungs[0];
    for (ladder.rungs) |rung| {
        if (rung.req > req_em) break;
        chosen = rung;
    }
    // The ladder answers the request itself when some rung is at least as wide
    // as it; only a request WIDER than every rung is a width the face drew no
    // variant for, and the only one that reaches the assembly. A form with no
    // assembly at all answers from the ladder whatever it asks for.
    if (req_em <= ladder.rungs[ladder.rungs.len - 1].req or ladder.parts.len == 0) {
        return .{
            .advance_em = chosen.adv,
            .ink = rungInk(chosen),
            .finite_ceiling_em = finiteCeiling(ladder),
        };
    }
    var repeats: usize = 0;
    var widest = assembledStretch(ladder, repeats, 0).advance_em;
    while (widest < req_em) {
        const grown = assembledStretch(ladder, repeats + 1, 0).advance_em;
        // An extender that does not advance can never reach the request.
        if (grown <= widest) break;
        repeats += 1;
        widest = grown;
    }
    return assembledStretch(
        ladder,
        repeats,
        openFor(ladder, repeats, req_em) orelse maxOpen(ladder, repeats),
    );
}

/// The largest uniform opening that makes the `repeats`-copy stack cover
/// `req_em`, or null when no opening of it does — a request past the widest
/// frame these parts can build. Opening a connection hands width back, so the
/// stack's advance falls monotonically with the opening and the boundary is
/// bisected; f32 carries a 24-bit significand, so 32 halvings of an em-scaled
/// interval land below the resolution of the measurement.
fn openFor(ladder: math_style_metrics.Ladder, repeats: usize, req_em: f32) ?f32 {
    const most = maxOpen(ladder, repeats);
    // Nothing opened is the floor: the widest this count of parts can be, and
    // a request past it has no answer at this count.
    if (assembledStretch(ladder, repeats, 0).advance_em < req_em) return null;
    // A request even the narrowest frame covers takes the whole opening rather
    // than tearing the joins past the material they were drawn with.
    if (assembledStretch(ladder, repeats, most).advance_em >= req_em) return most;
    var lo: f32 = 0;
    var hi: f32 = most;
    for (0..32) |_| {
        const mid = (lo + hi) / 2;
        if (assembledStretch(ladder, repeats, mid).advance_em >= req_em) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// The horizontal form of `cp` for a nucleus `req_em` wide (em) — a wide
/// `\widehat`, a `\widetilde`, the half of an over/under brace — as the advance
/// it reserves and the ink it paints. Every form is FITTED to the nucleus: the
/// widest rung of its own horizontal ladder that the nucleus still holds, and
/// only a request past that whole ladder assembles.
/// A wired font answers through `FontHook.horizontal_glyph` first, so both
/// branches frame the outline the renderer draws; that callback's null and its
/// errors are final. With no callback, and on the static arm, the answer is the
/// generated ladder and assembly of `math_style_metrics.zig`: measured tables,
/// no font, no allocation, no failure.
pub fn horizontalGlyph(
    fm: *const FontMetrics,
    cp: u21,
    req_em: f32,
) StretchError!?StretchGeometry {
    switch (fm.*) {
        .font => |hook| {
            if (hook.horizontal_glyph) |resolve| {
                return try resolve(hook.ctx, cp, req_em);
            }
        },
        .static => {},
    }
    return staticStretch(cp, req_em);
}

const VerticalWalk = struct {
    extent_em: f32 = 0,
    opened: f32 = 0,
    max_open: f32 = 0,
    geometry: StretchGeometry = .{
        .advance_em = 0,
        .ink = .{ .asc = 0, .desc = 0 },
    },
};

fn walkVertical(
    ladder: math_style_metrics.VerticalLadder,
    repeats: usize,
    open: f32,
) VerticalWalk {
    var out: VerticalWalk = .{};
    var previous: ?math_style_metrics.VerticalPart = null;
    var rise: f32 = 0;
    var low = std.math.inf(f32);
    var high = -std.math.inf(f32);
    var first_bottom: ?f32 = null;
    var last_top: f32 = 0;
    var last_advance: f32 = 0;
    for (ladder.parts) |part| {
        const copies = if (part.repeat) repeats else 1;
        for (0..copies) |_| {
            if (previous) |before| {
                const ceiling = @min(before.end, part.start);
                const room = @max(0, ceiling - math_style_metrics.min_connector_overlap);
                const overlap = @min(math_style_metrics.min_connector_overlap + open, ceiling);
                out.extent_em -= overlap;
                out.opened += @min(open, room);
                out.max_open = @max(out.max_open, room);
                rise -= overlap;
            }
            const bottom = if (part.desc > 0) -part.desc else part.bottom;
            if (first_bottom == null) first_bottom = bottom;
            low = @min(low, rise + bottom);
            high = @max(high, rise + part.asc);
            out.geometry.advance_em = @max(out.geometry.advance_em, part.width);
            out.geometry.ink.left = @max(out.geometry.ink.left, part.left);
            out.geometry.ink.right_edge = @max(out.geometry.ink.right_edge, part.right_edge);
            last_top = part.asc;
            last_advance = part.adv;
            rise += part.adv;
            previous = part;
        }
        out.extent_em += @as(f32, @floatFromInt(copies)) * part.adv;
    }
    if (first_bottom) |bottom| {
        const last_rise = out.extent_em - last_advance;
        const shift = math_style_metrics.axis_height - (bottom + last_rise + last_top) / 2;
        out.geometry.ink.asc = @max(0, high + shift);
        out.geometry.ink.desc = @max(0, -low - shift);
        out.geometry.ink.bottom = @max(0, low + shift);
    }
    return out;
}

fn verticalOpening(
    ladder: math_style_metrics.VerticalLadder,
    repeats: usize,
    excess: f32,
) f32 {
    const widest = walkVertical(ladder, repeats, 0);
    if (excess <= 0 or widest.max_open <= 0) return 0;
    if (walkVertical(ladder, repeats, widest.max_open).opened < excess) {
        return widest.max_open;
    }
    var lo: f32 = 0;
    var hi = widest.max_open;
    for (0..32) |_| {
        const mid = (lo + hi) / 2;
        if (walkVertical(ladder, repeats, mid).opened < excess) lo = mid else hi = mid;
    }
    return hi;
}

fn staticVertical(
    cp: u21,
    form: u8,
    assembly_req: f32,
    fixed_req: f32,
) ?StretchGeometry {
    for (math_style_metrics.verticals) |ladder| {
        if (ladder.cp != cp) continue;
        if (assembly_req > 0 and ladder.parts.len > 0) {
            var repeats: usize = 0;
            var widest = walkVertical(ladder, repeats, 0);
            while (widest.extent_em < assembly_req) {
                const grown = walkVertical(ladder, repeats + 1, 0);
                if (grown.extent_em <= widest.extent_em) break;
                repeats += 1;
                widest = grown;
            }
            return walkVertical(
                ladder,
                repeats,
                verticalOpening(ladder, repeats, widest.extent_em - assembly_req),
            ).geometry;
        }
        var rung = ladder.base;
        if (form > 0 and form <= ladder.rungs.len) {
            rung = ladder.rungs[form - 1];
        } else if (form == 0 and fixed_req > 0) {
            for (ladder.rungs) |candidate| {
                rung = candidate;
                if (rung.req >= fixed_req) break;
            }
        }
        return .{ .advance_em = rung.adv, .ink = rungInk(rung) };
    }
    return null;
}

/// The bounds of the same vertical request the SVG and CPU backends resolve.
pub fn verticalGlyph(
    fm: *const FontMetrics,
    cp: u21,
    form: u8,
    assembly_req: f32,
    fixed_req: f32,
) StretchError!?StretchGeometry {
    switch (fm.*) {
        .font => |hook| {
            if (hook.vertical_glyph) |resolve| {
                return try resolve(hook.ctx, cp, form, assembly_req, fixed_req);
            }
        },
        .static => {},
    }
    return staticVertical(cp, form, assembly_req, fixed_req);
}

/// Horizontal position of a glyph's TOP-ACCENT ATTACHMENT point, in em
/// right of the glyph origin — the MATH-table MathTopAccentAttachment
/// (fontTools on latinmodern-math.otf 2.005). XeTeX+unicode-math places an
/// accent so the ACCENT's attachment point (for the combining marks, their
/// ink center at −0.264em) sits on the BASE's attachment point: measured
/// `\dot{q}` ref, dot ink at q_origin + 0.349em = u1D45E's attachment
/// (0.349), NOT the base ink center (0.246) and NOT box center + italic
/// correction (plain TeX's rule — XeTeX uses the MATH table with
/// unicode-math). Rows cover every letter/Greek/symbol form the parser can
/// produce as an accent base (both the base and the math-italic mapped
/// codepoints). Null = no row (composite base, digit absent from the rows
/// below): the layout falls back to centering the accent on the base box.
const accent_attach = [_]struct { cp: u21, a: f32 }{
    .{ .cp = 0x0030, .a = 0.254 }, // 0
    .{ .cp = 0x0031, .a = 0.257 }, // 1
    .{ .cp = 0x0041, .a = 0.375 }, // A
    .{ .cp = 0x0042, .a = 0.256 }, // B
    .{ .cp = 0x0043, .a = 0.507 }, // C
    .{ .cp = 0x0044, .a = 0.243 }, // D
    .{ .cp = 0x0045, .a = 0.315 }, // E
    .{ .cp = 0x0046, .a = 0.308 }, // F
    .{ .cp = 0x0047, .a = 0.507 }, // G
    .{ .cp = 0x0048, .a = 0.375 }, // H
    .{ .cp = 0x0049, .a = 0.181 }, // I
    .{ .cp = 0x004A, .a = 0.317 }, // J
    .{ .cp = 0x004B, .a = 0.378 }, // K
    .{ .cp = 0x004C, .a = 0.193 }, // L
    .{ .cp = 0x004D, .a = 0.458 }, // M
    .{ .cp = 0x004E, .a = 0.375 }, // N
    .{ .cp = 0x004F, .a = 0.388 }, // O
    .{ .cp = 0x0050, .a = 0.250 }, // P
    .{ .cp = 0x0051, .a = 0.388 }, // Q
    .{ .cp = 0x0052, .a = 0.234 }, // R
    .{ .cp = 0x0053, .a = 0.330 }, // S
    .{ .cp = 0x0054, .a = 0.361 }, // T
    .{ .cp = 0x0055, .a = 0.375 }, // U
    .{ .cp = 0x0056, .a = 0.375 }, // V
    .{ .cp = 0x0057, .a = 0.514 }, // W
    .{ .cp = 0x0058, .a = 0.361 }, // X
    .{ .cp = 0x0059, .a = 0.375 }, // Y
    .{ .cp = 0x005A, .a = 0.317 }, // Z
    .{ .cp = 0x0061, .a = 0.214 }, // a
    .{ .cp = 0x0062, .a = 0.100 }, // b
    .{ .cp = 0x0063, .a = 0.249 }, // c
    .{ .cp = 0x0064, .a = 0.377 }, // d
    .{ .cp = 0x0065, .a = 0.236 }, // e
    .{ .cp = 0x0066, .a = 0.262 }, // f
    .{ .cp = 0x0067, .a = 0.332 }, // g
    .{ .cp = 0x0068, .a = 0.104 }, // h
    .{ .cp = 0x0069, .a = 0.138 }, // i
    .{ .cp = 0x006A, .a = 0.156 }, // j
    .{ .cp = 0x006B, .a = 0.100 }, // k
    .{ .cp = 0x006C, .a = 0.105 }, // l
    .{ .cp = 0x006D, .a = 0.350 }, // m
    .{ .cp = 0x006E, .a = 0.211 }, // n
    .{ .cp = 0x006F, .a = 0.249 }, // o
    .{ .cp = 0x0070, .a = 0.202 }, // p
    .{ .cp = 0x0071, .a = 0.318 }, // q
    .{ .cp = 0x0072, .a = 0.181 }, // r
    .{ .cp = 0x0073, .a = 0.232 }, // s
    .{ .cp = 0x0074, .a = 0.161 }, // t
    .{ .cp = 0x0075, .a = 0.245 }, // u
    .{ .cp = 0x0076, .a = 0.264 }, // v
    .{ .cp = 0x0077, .a = 0.361 }, // w
    .{ .cp = 0x0078, .a = 0.258 }, // x
    .{ .cp = 0x0079, .a = 0.264 }, // y
    .{ .cp = 0x007A, .a = 0.226 }, // z
    // The COMBINING MARKS' own TopAccentAttachment, from the same LM Math MATH
    // table. A mark's attachment is where it wants the base's attachment to
    // land, and it is NOT the ink centre: every mark has a zero advance with
    // its whole ink left of the origin, so `right_edge` clamps to 0 and the
    // ink centre (left/2) lands 0.041em off for U+0302. The font arm reads the
    // real value; this is the face-less fallback the placement site shares.
    .{ .cp = 0x0300, .a = -0.295 }, // combining grave
    .{ .cp = 0x0301, .a = -0.233 }, // combining acute
    .{ .cp = 0x0302, .a = -0.264 }, // combining circumflex (\hat)
    .{ .cp = 0x0303, .a = -0.264 }, // combining tilde (\tilde, \widetilde)
    .{ .cp = 0x0304, .a = -0.263 }, // combining macron (\bar)
    .{ .cp = 0x0307, .a = -0.265 }, // combining dot above (\dot)
    .{ .cp = 0x0308, .a = -0.261 }, // combining diaeresis (\ddot)
    .{ .cp = 0x030C, .a = -0.264 }, // combining caron
    .{ .cp = 0x0131, .a = 0.139 }, // ı
    .{ .cp = 0x0237, .a = 0.153 }, // ȷ
    .{ .cp = 0x03B1, .a = 0.356 }, // α
    .{ .cp = 0x03B2, .a = 0.280 }, // β
    .{ .cp = 0x03B3, .a = 0.293 }, // γ
    .{ .cp = 0x03B4, .a = 0.232 }, // δ
    .{ .cp = 0x03B5, .a = 0.244 }, // ε
    .{ .cp = 0x03B6, .a = 0.224 }, // ζ
    .{ .cp = 0x03B7, .a = 0.218 }, // η
    .{ .cp = 0x03B8, .a = 0.247 }, // θ
    .{ .cp = 0x03B9, .a = 0.098 }, // ι
    .{ .cp = 0x03BA, .a = 0.247 }, // κ
    .{ .cp = 0x03BB, .a = 0.086 }, // λ
    .{ .cp = 0x03BC, .a = 0.237 }, // μ
    .{ .cp = 0x03BD, .a = 0.209 }, // ν
    .{ .cp = 0x03BE, .a = 0.196 }, // ξ
    .{ .cp = 0x03BF, .a = 0.250 }, // ο
    .{ .cp = 0x03C1, .a = 0.243 }, // ρ
    .{ .cp = 0x03C2, .a = 0.237 }, // ς
    .{ .cp = 0x03C3, .a = 0.300 }, // σ
    .{ .cp = 0x03C4, .a = 0.232 }, // τ
    .{ .cp = 0x03C5, .a = 0.251 }, // υ
    .{ .cp = 0x03C6, .a = 0.302 }, // φ
    .{ .cp = 0x03C7, .a = 0.267 }, // χ
    .{ .cp = 0x03C8, .a = 0.348 }, // ψ
    .{ .cp = 0x03C9, .a = 0.322 }, // ω
    .{ .cp = 0x03D1, .a = 0.291 }, // ϑ
    .{ .cp = 0x03D5, .a = 0.320 }, // ϕ
    .{ .cp = 0x03D6, .a = 0.404 }, // ϖ
    .{ .cp = 0x03F1, .a = 0.249 }, // ϱ
    .{ .cp = 0x03F5, .a = 0.242 }, // ϵ
    .{ .cp = 0x210E, .a = 0.213 }, // ℎ
    .{ .cp = 0x2202, .a = 0.291 }, // ∂ (upright form)
    .{ .cp = 0x1D434, .a = 0.550 }, // 𝐴
    .{ .cp = 0x1D435, .a = 0.420 }, // 𝐵
    .{ .cp = 0x1D436, .a = 0.596 }, // 𝐶
    .{ .cp = 0x1D437, .a = 0.427 }, // 𝐷
    .{ .cp = 0x1D438, .a = 0.483 }, // 𝐸
    .{ .cp = 0x1D439, .a = 0.475 }, // 𝐹
    .{ .cp = 0x1D43A, .a = 0.596 }, // 𝐺
    .{ .cp = 0x1D43B, .a = 0.542 }, // 𝐻
    .{ .cp = 0x1D43C, .a = 0.347 }, // 𝐼
    .{ .cp = 0x1D43D, .a = 0.487 }, // 𝐽
    .{ .cp = 0x1D43E, .a = 0.545 }, // 𝐾
    .{ .cp = 0x1D43F, .a = 0.360 }, // 𝐿
    .{ .cp = 0x1D440, .a = 0.625 }, // 𝑀
    .{ .cp = 0x1D441, .a = 0.542 }, // 𝑁
    .{ .cp = 0x1D442, .a = 0.495 }, // 𝑂
    .{ .cp = 0x1D443, .a = 0.416 }, // 𝑃
    .{ .cp = 0x1D444, .a = 0.495 }, // 𝑄
    .{ .cp = 0x1D445, .a = 0.398 }, // 𝑅
    .{ .cp = 0x1D446, .a = 0.498 }, // 𝑆
    .{ .cp = 0x1D447, .a = 0.398 }, // 𝑇
    .{ .cp = 0x1D448, .a = 0.421 }, // 𝑈
    .{ .cp = 0x1D449, .a = 0.413 }, // 𝑉
    .{ .cp = 0x1D44A, .a = 0.552 }, // 𝑊
    .{ .cp = 0x1D44B, .a = 0.528 }, // 𝑋
    .{ .cp = 0x1D44C, .a = 0.399 }, // 𝑌
    .{ .cp = 0x1D44D, .a = 0.485 }, // 𝑍
    .{ .cp = 0x1D44E, .a = 0.287 }, // 𝑎
    .{ .cp = 0x1D44F, .a = 0.165 }, // 𝑏
    .{ .cp = 0x1D450, .a = 0.317 }, // 𝑐
    .{ .cp = 0x1D451, .a = 0.442 }, // 𝑑
    .{ .cp = 0x1D452, .a = 0.300 }, // 𝑒
    .{ .cp = 0x1D453, .a = 0.464 }, // 𝑓
    .{ .cp = 0x1D454, .a = 0.316 }, // 𝑔
    .{ .cp = 0x1D456, .a = 0.247 }, // 𝑖
    .{ .cp = 0x1D457, .a = 0.359 }, // 𝑗
    .{ .cp = 0x1D458, .a = 0.213 }, // 𝑘
    .{ .cp = 0x1D459, .a = 0.184 }, // 𝑙
    .{ .cp = 0x1D45A, .a = 0.404 }, // 𝑚
    .{ .cp = 0x1D45B, .a = 0.265 }, // 𝑛
    .{ .cp = 0x1D45C, .a = 0.315 }, // 𝑜
    .{ .cp = 0x1D45D, .a = 0.246 }, // 𝑝
    .{ .cp = 0x1D45E, .a = 0.349 }, // 𝑞
    .{ .cp = 0x1D45F, .a = 0.247 }, // 𝑟
    .{ .cp = 0x1D460, .a = 0.296 }, // 𝑠
    .{ .cp = 0x1D461, .a = 0.225 }, // 𝑡
    .{ .cp = 0x1D462, .a = 0.305 }, // 𝑢
    .{ .cp = 0x1D463, .a = 0.294 }, // 𝑣
    .{ .cp = 0x1D464, .a = 0.405 }, // 𝑤
    .{ .cp = 0x1D465, .a = 0.329 }, // 𝑥
    .{ .cp = 0x1D466, .a = 0.304 }, // 𝑦
    .{ .cp = 0x1D467, .a = 0.336 }, // 𝑧
    .{ .cp = 0x1D6FC, .a = 0.392 }, // 𝛼
    .{ .cp = 0x1D6FD, .a = 0.437 }, // 𝛽
    .{ .cp = 0x1D6FE, .a = 0.259 }, // 𝛾
    .{ .cp = 0x1D6FF, .a = 0.335 }, // 𝛿
    .{ .cp = 0x1D700, .a = 0.284 }, // 𝜀
    .{ .cp = 0x1D701, .a = 0.313 }, // 𝜁
    .{ .cp = 0x1D702, .a = 0.272 }, // 𝜂
    .{ .cp = 0x1D703, .a = 0.310 }, // 𝜃
    .{ .cp = 0x1D704, .a = 0.184 }, // 𝜄
    .{ .cp = 0x1D705, .a = 0.331 }, // 𝜅
    .{ .cp = 0x1D706, .a = 0.238 }, // 𝜆
    .{ .cp = 0x1D707, .a = 0.349 }, // 𝜇
    .{ .cp = 0x1D708, .a = 0.297 }, // 𝜈
    .{ .cp = 0x1D709, .a = 0.285 }, // 𝜉
    .{ .cp = 0x1D70A, .a = 0.243 }, // 𝜊
    .{ .cp = 0x1D70B, .a = 0.328 }, // 𝜋
    .{ .cp = 0x1D70C, .a = 0.354 }, // 𝜌
    .{ .cp = 0x1D70D, .a = 0.182 }, // 𝜍
    .{ .cp = 0x1D70E, .a = 0.286 }, // 𝜎
    .{ .cp = 0x1D70F, .a = 0.269 }, // 𝜏
    .{ .cp = 0x1D710, .a = 0.306 }, // 𝜐
    .{ .cp = 0x1D711, .a = 0.355 }, // 𝜑
    .{ .cp = 0x1D712, .a = 0.331 }, // 𝜒
    .{ .cp = 0x1D713, .a = 0.469 }, // 𝜓
    .{ .cp = 0x1D714, .a = 0.345 }, // 𝜔
    .{ .cp = 0x1D715, .a = 0.361 }, // 𝜕 (math-italic ∂)
    .{ .cp = 0x1D716, .a = 0.269 }, // 𝜖
    .{ .cp = 0x1D717, .a = 0.411 }, // 𝜗
    .{ .cp = 0x1D719, .a = 0.423 }, // 𝜙
    .{ .cp = 0x1D71A, .a = 0.361 }, // 𝜚
    .{ .cp = 0x1D71B, .a = 0.453 }, // 𝜛
};

/// The top-accent attachment of an accent base codepoint, in em (null when
/// the codepoint has no row — the layout then centers the accent on the box).
/// The hand-measured rows cover the upright and math-italic designs; the
/// math sans-serif and monospace glyphs are drawn from the same face and
/// carry their own recorded attachment, which the generated rows answer.
pub fn accentAttach(cp: u21) ?f32 {
    var lo: usize = 0;
    var hi: usize = accent_attach.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (accent_attach[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < accent_attach.len and accent_attach[lo].cp == cp) return accent_attach[lo].a;
    return generatedTopAccent(cp);
}

/// Em size at the base font size (10pt), used by `glyphEstimate`.
const em: f32 = 10.0;

/// Font-arm dispatch for the `glyph`/`glyphAt` fallback chain: the `.font`
/// arm answers from the real font via its hook, `.static` has no font path
/// (the static tables answer there). `size_pt` is the drawn size the hook
/// resolves its glyph against.
fn fontGlyph(fm: *const FontMetrics, cp: u21, style: atom.CharStyle, size_pt: f32) ?Glyph {
    return switch (fm.*) {
        .static => null,
        .font => |hook| hook.glyph(hook.ctx, cp, style, size_pt),
    };
}

/// Implementation of `FontMetrics.glyph`: exact per-glyph metrics for `cp`
/// in `style` at the 10pt base; null when neither the real font (`.font`
/// arm) nor the static table has the codepoint. Font path first, then the
/// bundled tables — the fallback chain layout relies on: font → static
/// table → glyphEstimate.
fn glyphImpl(fm: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph {
    if (fontGlyph(fm, cp, style, em)) |g| return g;
    return staticGlyph(cp, style);
}

/// Static-table lookup at the 10pt base. A text face answers from its OWN
/// generated row first, then a remapped alphabet glyph, then the O(1) ASCII
/// LUT, and only then the binary search over `tableFor`. Italic correction
/// falls back to these rows only when the active face supplies no MATH value.
pub fn staticGlyph(cp: u21, style: atom.CharStyle) ?Glyph {
    if (textFaceGlyph(style, cp)) |g| return g;
    // A codepoint the layout REMAPPED (the math sans-serif / monospace
    // alphabets, the native triple / quadruple prime) answers before the
    // ASCII fast path and every optical band below: those describe the
    // upright ASCII design, which is not the glyph this run draws.
    if (generatedGlyph(cp, style, em)) |g| return g;
    if (cp < 128) {
        if (ascii_lut[cp]) |g| return g;
    }
    const tbl = tableFor(style, 0);
    var lo: usize = 0;
    var hi: usize = tbl.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (tbl[mid].cp < cp) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < tbl.len and tbl[lo].cp == cp) {
        const e = tbl[lo];
        return .{
            .width = e.w,
            .height = e.h,
            .depth = e.d,
            .italic_correction = e.ic,
        };
    }
    return null;
}

/// True when the ACTIVE metric source carries a glyph for `cp` in `style`:
/// the `.font` arm's cmap (the font returns null for codepoints the face
/// does not map), else the bundled static tables. Layout uses this to
/// validate a mapped math-italic codepoint (U+1D4xx/U+1D6xx) before
/// emitting it: when the source lacks the mapped form, the base codepoint
/// is kept, so the SVG never names a glyph the renderer cannot draw (the
/// static tables cover the U+1D4xx Latin series but not the U+1D6xx Greek
/// series; a loaded font may lack either).
pub fn hasGlyph(fm: *const FontMetrics, cp: u21, style: atom.CharStyle) bool {
    return switch (fm.*) {
        .static => staticGlyph(cp, style) != null,
        .font => |hook| hook.glyph(hook.ctx, cp, style, em) != null,
    };
}

/// ASCII fast-path lookup table (cp < 128), derived at comptime from the same
/// `table` array as `glyph`, so every entry is bit-identical to what the
/// binary search would return (same width/height/depth/italic values). Slots
/// with no table row stay null.
const ascii_lut = blk: {
    var lut: [128]?Glyph = undefined;
    for (&lut) |*slot| slot.* = null;
    for (table) |e| {
        if (e.cp < 128) {
            lut[e.cp] = .{ .width = e.w, .height = e.h, .depth = e.d, .italic_correction = e.ic };
        }
    }
    break :blk lut;
};

/// Roman-style counterpart of `ascii_lut`, derived from the generated LM
/// Roman regular rows (`roman_style_metrics.roman`) — the face `.roman` is
/// actually drawn from, so every entry is exactly what `textFaceGlyph` and
/// `staticGlyph` return for that style. Slots the face does not carry stay
/// null and the caller falls through to the legacy tables.
const roman_ascii_lut = blk: {
    var lut: [128]?Glyph = undefined;
    for (&lut) |*slot| slot.* = null;
    for (roman_style_metrics.roman) |e| {
        if (e.cp < 128) {
            lut[e.cp] = .{ .width = e.w, .height = e.h, .depth = e.d, .italic_correction = e.ic };
        }
    }
    break :blk lut;
};

/// O(1) ASCII glyph lookup for the bundled default metrics: direct table
/// read, no binary search, no indirect call — `glyphAt` takes this fast
/// path outside the 7pt/5pt optical bands (where the script-size tables
/// would answer). Returns null unless `fm` is exactly the bundled `default`
/// and `cp < 128` (including ASCII codepoints absent from the table), so
/// callers fall through to `glyph` otherwise. The `.roman` style resolves
/// from the generated LM Roman face row, everything else from `table`,
/// matching `glyph`/`glyphAt`/`staticGlyph`.
pub fn lookupAscii(fm: *const FontMetrics, cp: u21, style: atom.CharStyle) ?Glyph {
    if (fm != &default) return null;
    if (cp >= 128) return null;
    if (style == .roman) return roman_ascii_lut[cp];
    return ascii_lut[cp];
}

/// Deterministic fallback for any unknown glyph: width 0.5em, height 0.7em,
/// depth 0.2em. Math-italic style adds a small italic correction.
fn glyphEstimateImpl(self: *const FontMetrics, cp: u21, style: atom.CharStyle) Glyph {
    _ = self;
    _ = cp;
    var ic: f32 = 0.0;
    if (style == .italic) ic = 0.2;
    return .{
        .width = 0.5 * em,
        .height = 0.7 * em,
        .depth = 0.2 * em,
        .italic_correction = ic,
    };
}

/// TeX layout parameters at 10pt (MicroTeX tex_param.res.cpp × 10, plus
/// denom3/sub3/x_height from the standard CM set). Layout scales by size/10.
///
/// The `.font` arm overrides every row the face's own OpenType MATH table
/// can express, so the geometry follows the ACTIVE font instead of a
/// hard-wired table: for the bundled Latin Modern Math face the result is
/// the same numbers the static rows already hold (they were measured from
/// that same table), and a face with different constants moves the axis,
/// the script ratios, the fraction shifts and rule, and the limit gaps with
/// it. Nothing is invented: a parameter with no MATH counterpart
/// (`x_height`, and `bigop_spacing5`, which fontspec's fd13 sets to 0pt on
/// an OpenType math font) keeps its static row.
fn glueImpl(self: *const FontMetrics) GlueParams {
    var p: GlueParams = .{
        .axis_height = 2.5,
        .rule_thickness = 0.4,
        .num1 = 6.76508,
        .num2 = 3.93732,
        .num3 = 4.43731,
        .denom1 = 6.85951,
        .denom2 = 3.44841,
        .denom3 = 1.63,
        // Latin-Modern-Math MATH-table constants (measured from
        // latinmodern-math.otf with fontTools, em × 10), matching
        // XeTeX+unicode-math. Verified against the XeTeX render at 10pt:
        // x^2 sup raise 3.630 (= sup1, probe), x_i sub drop 2.470
        // (= sub1), x_i^2 sub drop 2.611 (= sub2 + 4·rt clearance).
        // SuperscriptShiftUp = 0.363em, SuperscriptShiftUpCramped =
        // 0.289em, SubscriptShiftDown = 0.247em; bigop1..5 =
        // UpperLimitGapMin 0.20, LowerLimitGapMin 0.167,
        // UpperLimitBaselineRiseMin 0.111, LowerLimitBaselineDropMin 0.60,
        // bigop5 0 (fontspec fd13 = 0pt on the OT math font).
        .sup1 = 3.63,
        .sup2 = 3.63,
        .sup3 = 2.89,
        .sub1 = 2.47,
        .sub2 = 2.47,
        .sub3 = 2.47,
        .supdrop = 1.75, // SuperscriptBaselineDropMax 0.25em × scriptfactor 0.7
        .subdrop = 1.4, // SubscriptBaselineDropMin 0.20em × scriptfactor 0.7
        .bigop_spacing1 = 2.0,
        .bigop_spacing2 = 1.67,
        .bigop_spacing3 = 1.11,
        .bigop_spacing4 = 6.0,
        .bigop_spacing5 = 0.0,
        .scriptfactor = 0.7,
        .scriptscriptfactor = 0.5,
        .x_height = 4.30555,
    };
    const mc = mathConstants(self) orelse return p;
    p.math_constants = mc;
    // MATH values are em; GlueParams is points at the 10pt base.
    p.axis_height = mc.axis_height * em;
    p.rule_thickness = mc.fraction_rule_thickness * em;
    p.sup1 = mc.superscript_shift_up * em;
    p.sup2 = mc.superscript_shift_up * em;
    p.sup3 = mc.superscript_shift_up_cramped * em;
    p.sub1 = mc.subscript_shift_down * em;
    p.sub2 = mc.subscript_shift_down * em;
    p.sub3 = mc.subscript_shift_down * em;
    // The baseline drops are read at the SCRIPT size (tex.web reads
    // \fontdimen20/21 of the script symbol font), so they carry the script
    // ratio — the same 0.25em × 0.7 the static row encodes.
    p.supdrop = mc.superscript_baseline_drop_max * mc.script_percent_scale_down * em;
    p.subdrop = mc.subscript_baseline_drop_min * mc.script_percent_scale_down * em;
    // Fraction shifts: the display branch uses the display-style shift,
    // every other style the plain one. MATH has no \atop-specific value, so
    // the ruleless branches (num3/denom3) take the same non-display shift.
    p.num1 = mc.fraction_numerator_display_style_shift_up * em;
    p.num2 = mc.fraction_numerator_shift_up * em;
    p.num3 = mc.fraction_numerator_shift_up * em;
    p.denom1 = mc.fraction_denominator_display_style_shift_down * em;
    p.denom2 = mc.fraction_denominator_shift_down * em;
    p.denom3 = mc.fraction_denominator_shift_down * em;
    p.bigop_spacing1 = mc.upper_limit_gap_min * em;
    p.bigop_spacing2 = mc.lower_limit_gap_min * em;
    p.bigop_spacing3 = mc.upper_limit_baseline_rise_min * em;
    p.bigop_spacing4 = mc.lower_limit_baseline_drop_min * em;
    p.scriptfactor = mc.script_percent_scale_down;
    p.scriptscriptfactor = mc.script_script_percent_scale_down;
    return p;
}

/// The OpenType MATH constants of the ACTIVE metric source: the `.font`
/// arm's borrowed face constants, or null for the bundled static tables
/// (which carry their own measured rows). Layout reads the parameters
/// `GlueParams` has no room for — the radical, overbar and underbar gaps,
/// the accent base height — through this.
pub fn mathConstants(fm: *const FontMetrics) ?*const atom.MathConstants {
    return switch (fm.*) {
        .static => null,
        .font => |hook| hook.math_constants,
    };
}

/// The drawn glyph's OpenType MATH italic correction, in points at the 10pt
/// base (the same unit as `Glyph.italic_correction`, so a caller scales it
/// with `s()` like every other base-unit value), read from the ACTIVE FACE
/// only. Null when there is no face, when the face records none, or when it
/// does not map the codepoint — so a caller keeps its own static row instead
/// of silently using a fallback dressed up as the font's answer. (The bare
/// `glyph` lookup cannot say this: it falls through to the static table
/// itself.) This is the correction XeTeX+unicode-math adds after a math_char
/// noad, so a superscript really lands at advance + this × size.
pub fn fontItalicCorrection(fm: *const FontMetrics, cp: u21, style: atom.CharStyle) ?f32 {
    const hook = switch (fm.*) {
        .static => return null,
        .font => |h| h,
    };
    const g = hook.glyph(hook.ctx, cp, style, em) orelse return null;
    return g.italic_correction;
}

/// The drawn glyph's OpenType MATH `TopAccentAttachment`, em of the glyph's
/// font size, from the ACTIVE FACE (see `fontItalicCorrection` for the null
/// contract). The stored value is in base points, so it is divided down to
/// em here to match `accentAttach`'s unit — the two are then interchangeable
/// at the placement site. null = the face records none, and the caller falls
/// back to the measured `accentAttach` row.
pub fn fontTopAccentAttachment(fm: *const FontMetrics, cp: u21, style: atom.CharStyle) ?f32 {
    const hook = switch (fm.*) {
        .static => return null,
        .font => |h| h,
    };
    const g = hook.glyph(hook.ctx, cp, style, em) orelse return null;
    const attachment = g.top_accent_attachment orelse return null;
    return attachment / em;
}

/// The accent clearance height, em: the face's MATH `AccentBaseHeight` on
/// the font path, and Latin Modern Math's measured 0.45em otherwise (the
/// static fallback, so a fontless render is unchanged).
pub fn accentBaseHeightEm(fm: *const FontMetrics) f32 {
    const mc = mathConstants(fm) orelse return 0.45;
    return mc.accent_base_height;
}

/// Bundled default metrics (Latin-Modern-Math advance widths, 10pt base):
/// the `.static` arm of the FontMetrics union.
pub const default: FontMetrics = .{ .static = .{} };

// ── tests ────────────────────────────────

const testing = std.testing;

test "metrics: table is sorted by codepoint" {
    for (table[1..], 0..) |entry, i| {
        try testing.expect(table[i].cp < entry.cp);
    }
}

test "metrics: every bundled glyph resolves with positive extent" {
    for (table) |entry| {
        const g = glyph(&default, entry.cp, .italic);
        try testing.expect(g != null);
        if (g) |gg| {
            try testing.expect(gg.width > 0.0);
            // total extent: some glyphs (e.g. '=', big ops) sit above or
            // hang below the baseline, so height alone may be zero
            try testing.expect(gg.height + gg.depth > 0.0);
        }
    }
}

test "metrics: digits letters operators greek are covered" {
    const cps = [_]u21{
        0x30, 0x39, // digits 0 9
        0x61, 0x7A, 0x41, 0x5A, // letters a z A Z
        0x2B, 0x2D, 0x3D, 0x3C,
        0x3E, 0x28, 0x29, 0x5B,
        0x5D, 0x7B, 0x7D,
        0x2F, 0x7C, 0x2C, 0x2E, 0x3B, 0x21, // + - = < > ( ) [ ] { } / | , . ; !
        0x03B1, 0x03C9, 0x0391, 0x03A9, // α ω Α Ω
        0x03B6, 0x03C8, 0x03C2, 0x03D1, 0x039E, 0x03A5, 0x03A8, // ζ ψ ς ϑ Ξ Υ Ψ
        0x0131, 0x0237, 0x210F, 0x2127, 0x00F0, // ı ȷ ℏ ℧ ð
        0x25B3, 0x25BD, 0x25A1, 0x25A0, 0x25CA, 0x29EB, 0x2713, // △ ▽ □ ■ ◊ ⧫ ✓
        0x2660, 0x2661, 0x2662, 0x2663, 0x266D, 0x266E, 0x266F, // suits + music
        0x00A3, 0x00A5, 0x00A7, 0x00A9, 0x00B6, // £ ¥ § © ¶
        0x2221, 0x2222, 0x2035, 0x2204, 0x2241, 0x2246, 0x2247, 0x2249, // ∡ ∢ ‵ ∄ ≁ ≆ ≇ ≉
        0x2270, 0x2271, 0x2288, 0x2289, 0x22D8, 0x22D9, // ≰ ≱ ⊈ ⊉ ⋘ ⋙
        0x21A3, 0x21C4, 0x2215, 0x2A2F, 0x2912, 0x03D8, // ↣ ⇄ ╱ ⨯ ⤒ Ϝ
        0x2211, 0x220F, 0x222B, // ∑ ∏ ∫
    };
    for (cps) |cp| {
        const g = glyph(&default, cp, .roman);
        try testing.expect(g != null);
        if (g) |gg| {
            try testing.expect(gg.width > 0.0);
            try testing.expect(gg.height + gg.depth > 0.0);
        }
    }
}

test "metrics: unknown codepoint falls back to estimate" {
    const cp: u21 = 0x1F600;
    try testing.expect(glyph(&default, cp, .italic) == null);
    const est = glyphEstimate(&default, cp, .italic);
    try testing.expect(est.width > 0.0);
    try testing.expect(est.height > 0.0);
}

test "metrics: greek alpha present; operators upright, variables slanted" {
    const alpha = glyph(&default, 0x03B1, .italic);
    try testing.expect(alpha != null);
    const plus = glyph(&default, 0x2B, .italic) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 0.0), plus.italic_correction);
    const f = glyph(&default, 0x66, .italic) orelse
        return error.TestUnexpectedResult;
    try testing.expect(f.italic_correction > 0.0);
    const est_i = glyphEstimate(&default, 0x1F600, .italic);
    const est_r = glyphEstimate(&default, 0x1F600, .roman);
    try testing.expect(est_i.italic_correction > 0.0);
    try testing.expectEqual(@as(f32, 0.0), est_r.italic_correction);
}

test "metrics: every roleOfCp math symbol resolves with real CM metrics" {
    // Every codepoint layout.roleOfCp classifies as bin/rel/open/close/
    // punct/op (mirrored here to avoid a metrics → layout import cycle),
    // plus the corpus's common math symbols, must resolve from the table
    // with positive extent — none may fall back to glyphEstimate.
    const bin = [_]u21{
        0x2B,   0x2D,   0x2212, 0x2213, 0x00B1, 0x00D7, 0x00F7, 0x22C5, 0x2217,
        0x2218, 0x2219, 0x2229, 0x222A, 0x2227, 0x2228, 0x2295, 0x2296, 0x2297,
        0x2298, 0x2299, 0x22C2, 0x22C3, 0x2020, 0x2021, 0x2216, 0x2240, 0x228E,
        0x2293, 0x2294, 0x22C4, 0x22C6, 0x25B9, 0x25C3, 0x25CB, 0x2A3F,
    };
    const rel = [_]u21{
        0x3D,   0x3C,   0x3E,   0x3A,   0x2260, 0x2261, 0x2262, 0x2264, 0x2265,
        0x2266, 0x2267, 0x2243, 0x2244, 0x2245, 0x2246, 0x2247, 0x2248, 0x2249,
        0x223C, 0x2241, 0x2282, 0x2283, 0x2284, 0x2285, 0x2286, 0x2287, 0x2288,
        0x2289, 0x2208, 0x2209, 0x220B, 0x220C, 0x227A, 0x227B, 0x2280, 0x2281,
        0x226D, 0x226E, 0x226F, 0x2270, 0x2271, 0x22E0, 0x22E1, 0x22AC, 0x2190,
        0x2192, 0x2194, 0x21D0, 0x21D2, 0x21D4, 0x2A7D, 0x2A7E, 0x2191, 0x2193,
        0x2195, 0x2196, 0x2197, 0x2198, 0x2199, 0x21A6, 0x21A9, 0x21AA, 0x21BC,
        0x21BD, 0x21C0, 0x21C1, 0x21D1, 0x21D3, 0x21D5, 0x221D, 0x2223, 0x2224,
        0x2225, 0x2226, 0x2234, 0x2235, 0x224D, 0x2250, 0x226A, 0x226B, 0x2291,
        0x2292, 0x22A2, 0x22A3, 0x22A5, 0x22A8, 0x22C8, 0x2322, 0x2323, 0x27F5,
        0x27F6, 0x27F7, 0x27F8, 0x27F9, 0x27FA, 0x2AAF, 0x2AB0,
        0x2236, 0x2237, 0x2254, 0x2255, // ∶ ∷ ⋔ ⋕ (the colon family)
    };
    const open = [_]u21{ 0x28, 0x5B, 0x7B, 0x27E8, 0x2308, 0x230A };
    const close = [_]u21{ 0x29, 0x5D, 0x7D, 0x27E9, 0x2309, 0x230B };
    const punct = [_]u21{ 0x2C, 0x3B };
    const ops = [_]u21{
        0x2211, 0x220F, 0x222B, 0x2210, 0x222E, 0x2A06, 0x22C0, 0x22C1,
        0x2A00, 0x2A01, 0x2A02, 0x2A04, 0x2A05,
    };
    // corpus-common math symbols beyond roleOfCp: ∞ ∠ ∇ ∂ √ ′ ″ ∅ ⋯ ·
    const extras = [_]u21{
        0x221E, 0x2220, 0x2207, 0x2202, 0x221A, 0x2032, 0x2033, 0x2205,
        0x22EF, 0x00B7,
    };
    for (bin ++ rel ++ open ++ close ++ punct ++ ops ++ extras) |cp| {
        const g = glyph(&default, cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expect(g.width > 0.0);
        try testing.expect(g.height + g.depth > 0.0);
    }
}

test "metrics: relation/bin symbols beat the glyphEstimate width" {
    // The glyphEstimate fallback width is 0.5em = 5.0pt at 10pt. The real
    // LM Math advances of the corpus's widest symbols are materially
    // different, which is the whole point of the table coverage.
    const cases = [_]u21{
        0x2192, // -> real 10.0 vs 5.0
        0x221E, // infty real 10.0 vs 5.0
        0x2264, // <= real 7.78 vs 5.0
        0x2260, // != real 7.78 vs 5.0
        0x2208, // in real 6.67 vs 5.0
        0x00B1, // +- real 7.78 vs 5.0
        0x2297, // otimes real 7.78 vs 5.0
        0x2282, // subset real 7.78 vs 5.0
    };
    for (cases) |cp| {
        const g = glyph(&default, cp, .roman) orelse
            return error.TestUnexpectedResult;
        try testing.expect(g.width > 5.0);
    }
}

test "metrics: a text face is measured by its own LM Roman row" {
    // Every generated face is a DIFFERENT design, so no upright row can
    // stand in for one: the four real advances for 'x' are all distinct.
    const upright = staticGlyph('x', .roman) orelse return error.TestUnexpectedResult;
    const italic = staticGlyph('x', .text_italic) orelse return error.TestUnexpectedResult;
    const bold = staticGlyph('x', .bold) orelse return error.TestUnexpectedResult;
    const both = staticGlyph('x', .bold_italic) orelse return error.TestUnexpectedResult;
    const widths = [_]f32{ upright.width, italic.width, bold.width, both.width };
    for (widths[0 .. widths.len - 1], widths[1..]) |lo, hi| try testing.expect(lo != hi);
    // The DRAWN bold `p` is boxed by its OWN face's ink, descender included:
    // the layout adds `ink.desc` below the baseline, so ink the box does not
    // carry is ink the frame cuts off.
    const bold_p = glyphInkAt('p', .bold);
    try testing.expect(bold_p.desc > 0);
    try testing.expect(bold_p.asc > bold_p.desc);
}

test "metrics: the extensible accent band is the mark's own ink" {
    // The long \widehat / \widetilde is stroked INSIDE the narrow mark's ink
    // band, so that band is the vertical extent the two forms share. The
    // band runs from the mark's own lower edge (`bottom`, POSITIVE for a
    // mark: its ink floats above the baseline) up to `asc` — it is the
    // distance between the two, not the ascent alone, and it has to be a
    // real positive height or the stroke collapses onto the argument.
    for ([_]u21{ 0x0302, 0x0303 }) |cp| {
        const ink = glyphInk(cp);
        try testing.expect(ink.asc > 0.7);
        try testing.expectApproxEqAbs(@as(f32, 0), ink.desc, 0.001);
        try testing.expect(ink.bottom > 0);
        try testing.expect(ink.asc > ink.bottom);
    }
}

test "metrics: every generated ink row is real, non-negative, cp-ascending" {
    // Every extent is a non-negative measurement the generator clamps at the
    // origin: `asc`/`desc`/`left`/`bottom` are how far the outline REACHES
    // past the baseline or the origin, `right_edge` is where it ENDS. A
    // negative one would shrink the frame and clip the very ink it exists to
    // contain. A row exists only because the glyph really has ink to frame
    // there, so all five zero is not a row; and `cp`-ascending is the
    // precondition of the binary search that finds one.
    const tables = [_][]const ink_metrics.Edge{
        ink_metrics.math,
        ink_metrics.roman,
        ink_metrics.italic,
        ink_metrics.bold,
        ink_metrics.bold_italic,
    };
    for (tables) |rows| {
        try testing.expect(rows.len > 0);
        var previous: u21 = 0;
        for (rows, 0..) |row, i| {
            try testing.expect(row.asc >= 0 and row.desc >= 0);
            try testing.expect(row.left >= 0 and row.right_edge >= 0 and row.bottom >= 0);
            try testing.expect(row.asc > 0 or row.desc > 0 or row.left > 0 or
                row.right_edge > 0 or row.bottom > 0);
            if (i > 0) try testing.expect(previous < row.cp);
            previous = row.cp;
        }
    }
}

test "metrics: a glyph is framed by the face its style is drawn from" {
    // LM Roman Italic's `x` leans further right and sits lower than the
    // upright face's — two different designs. Framing both by one face's
    // outline either clips the italic or pads the upright one, so each style
    // has to answer from the face `FontContext.faceForStyle` hands the
    // rasterizer.
    const upright = glyphInkAt('x', .roman);
    const italic = glyphInkAt('x', .text_italic);
    try testing.expectApproxEqAbs(@as(f32, 0.516), upright.right_edge, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.518), italic.right_edge, 0.0001);
    try testing.expect(italic.right_edge > upright.right_edge);
    try testing.expect(italic.desc > upright.desc);
    // The upright `x` keeps the plain advance box: its ink starts at the
    // origin and sits on the baseline, so both `left` and `bottom` are 0.
    try testing.expectApproxEqAbs(@as(f32, 0), upright.left, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), upright.bottom, 0.0001);
    // Math keeps the LM Math face — and its italic `j` really does start
    // left of its origin, which is the negative side bearing the frame has
    // to absorb.
    try testing.expect(glyphInkAt('j', .italic).left > 0);
}

test "metrics: the right edge is measured from the origin, not past the advance" {
    // The `f` hook is the frame's hard case in every face: its ink ends
    // 0.357 / 0.452 / 0.437 / 0.538em from the ORIGIN, past the advance each
    // style boxes it at. An overhang recorded past the face's own hmtx
    // advance assumes the box IS that advance wide, which for the hook it
    // is not. Measured from the origin, one number frames every one of them.
    const hooks = [_]struct { style: atom.CharStyle, right_edge: f32 }{
        .{ .style = .roman, .right_edge = 0.357 },
        .{ .style = .text_italic, .right_edge = 0.452 },
        .{ .style = .bold, .right_edge = 0.437 },
        .{ .style = .bold_italic, .right_edge = 0.538 },
    };
    for (hooks) |h| {
        const ink = glyphInkAt('f', h.style);
        try testing.expectApproxEqAbs(h.right_edge, ink.right_edge, 0.0001);
        // Every face's hook really does reach past the advance it is boxed
        // at, so the union the consumer takes is nonzero on that axis.
        try testing.expect(ink.right_edge > glyphAt(&default, 'f', h.style, 10.0).?.width / em);
    }
    // A glyph whose ink ENDS inside the advance it is boxed at keeps the
    // plain advance box: the upright `x` ends at 0.516em and its LM Roman
    // face row boxes it at 0.528em, so the union adds nothing on that axis.
    const x = glyphInkAt('x', .roman);
    try testing.expectApproxEqAbs(@as(f32, 0.516), x.right_edge, 0.0001);
    try testing.expect(x.right_edge < glyphAt(&default, 'x', .roman, 10.0).?.width / em);
}

test "metrics: the drawn ink encloses the outline, not a rounded estimate" {
    // Three decimals is not enclosure. The older rounded Latin-Modern-Math
    // rows carried U+0391 Α at 0.683em against a real 0.716em outline and
    // U+22C0 ⋀ at 0.750 against 0.78025, so both lost the top of their ink
    // at every size — 0.033em is 20px of clipped apex at 60pt/720dpi. The
    // rows regenerated from the embedded bytes are the outline's own box.
    try testing.expectApproxEqAbs(@as(f32, 0.716), glyphInk(0x0391).asc, 0.0001);
    const nary_and = glyphInk(0x22C0);
    try testing.expectApproxEqAbs(@as(f32, 0.78025), nary_and.asc, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.264301), nary_and.desc, 0.0001);
    // The math-italic `f` a bare `f` actually DRAWS is U+1D453, whose tail
    // hangs below the baseline; the U+0066 row has no descent, so framing by
    // the base letter cut the tail off.
    const drawn_f = glyphInkAt(0x1D453, .italic);
    try testing.expectApproxEqAbs(@as(f32, 0.705), drawn_f.asc, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.205), drawn_f.desc, 0.0001);
    // Each text face answers with its OWN design: the bold `f` hook tops out
    // lower than the italic one.
    try testing.expectApproxEqAbs(@as(f32, 0.7), glyphInkAt('f', .bold).asc, 0.0001);
    try testing.expectApproxEqAbs(
        @as(f32, 0.705),
        glyphInkAt('f', .text_italic).asc,
        0.0001,
    );
    // A codepoint no embedded face carries has no measured ink at all, so
    // the static design bound still frames it: a CJK glyph in a fallback
    // font must not be boxed at zero height.
    const cjk = glyphInk(0x4E2D);
    try testing.expectApproxEqAbs(@as(f32, 0.75), cjk.asc, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), cjk.desc, 0.0001);
}

test "metrics: the big-integral rows are the plain integral scaled by 2.488" {
    // The box of a scaled big integral is what keeps the painted glyph
    // inside the frame, so every field must be the plain integral's own
    // value times the drawn scale — a row that drifted would clip.
    const scale: f32 = 2.488;
    const plain = bigOpInk(.int, false);
    const cases = [_]struct { op: atom.BigOp, advance_em: f32 }{
        .{ .op = .bigint, .advance_em = 0.665 },
        // ∬ and ∭ keep their OWN hmtx advance (fontTools: 1.035 / 1.405em);
        // only the vertical extents scale.
        .{ .op = .bigiint, .advance_em = 1.035 },
        .{ .op = .bigiiint, .advance_em = 1.405 },
    };
    for (cases) |c| {
        for ([_]bool{ false, true }) |display| {
            const ink = bigOpInk(c.op, display);
            try testing.expectApproxEqAbs(c.advance_em * scale, ink.advance, 0.001);
            try testing.expectApproxEqAbs(c.advance_em * scale, ink.disp_advance, 0.001);
            try testing.expectApproxEqAbs(plain.asc * scale, ink.asc, 0.001);
            try testing.expectApproxEqAbs(plain.desc * scale, ink.desc, 0.001);
            try testing.expectApproxEqAbs(plain.ic * scale, ink.ic, 0.01);
        }
    }
    // The font's display VARIANT for those codepoints is a different, larger
    // design, which is why layoutOp must not mark a scaled big integral as
    // one (measured: integral.v1 ink 1.361/0.861em at advance 0.999em).
    const variant = bigOpInk(.int, true);
    try testing.expect(variant.asc > plain.asc);
    try testing.expect(variant.desc > plain.desc);
}

test "metrics: the monospace alphabet advances at its own fixed pitch" {
    // `\mathtt` remaps every letter and digit to the math monospace series,
    // whose glyphs all advance 0.525em — the fixed pitch the style promises.
    // Each box carries that pitch exactly; the 0.5em estimate is close but is
    // not the drawn advance, so a run of them drifts off its own grid.
    const runs = [_]struct { first: u21, count: u21 }{
        .{ .first = 0x1D670, .count = 26 },
        .{ .first = 0x1D68A, .count = 26 },
        .{ .first = 0x1D7F6, .count = 10 },
    };
    for (runs) |run| {
        for (0..run.count) |i| {
            const cp = run.first + @as(u21, @intCast(i));
            const g = staticGlyph(cp, .mono) orelse return error.TestUnexpectedResult;
            try testing.expectApproxEqAbs(5.25, g.width, 0.001);
            try testing.expect(g.width != glyphEstimate(&default, cp, .mono).width);
            // The mapped codepoint is one the metric source recognises, so
            // layout emits it instead of the ASCII letter.
            try testing.expect(hasGlyph(&default, cp, .mono));
        }
    }
    // The rows belong to the style that remaps them: the sans-serif series is
    // not a monospace row.
    try testing.expect(!hasGlyph(&default, 0x1D5A0, .mono));
}

test "metrics: a remapped alphabet glyph is boxed by the outline it draws" {
    // The math sans-serif A: its own hmtx advance and its own ink, not the
    // upright ASCII design the remapping replaced.
    const a = staticGlyph(0x1D5A0, .sans) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(6.67, a.width, 0.001);
    try testing.expectApproxEqAbs(6.94, a.height, 0.001);
    const ink = glyphInkAt(0x1D5A0, .sans);
    try testing.expectApproxEqAbs(0.694, ink.asc, 0.001);
    // Sans is proportional: two of its capitals advance differently, so a
    // sans run does not sit on the one pitch the `\mathtt` run does.
    const sans_r = staticGlyph(0x1D5B1, .sans) orelse return error.TestUnexpectedResult;
    try testing.expect(sans_r.width != a.width);
    // The sans-serif j leans left of its own origin and descends below the
    // baseline; both overhangs must reach the frame or the glyph is cut.
    const j = glyphInkAt(0x1D5C3, .sans);
    try testing.expectApproxEqAbs(0.061, j.left, 0.001);
    try testing.expectApproxEqAbs(0.205, j.desc, 0.001);
    try testing.expect(j.left > 0 and j.desc > 0);
    // The face records the accent attachment for these glyphs, so a hat over
    // `\mathsf{…}` lands where the font says rather than centred on the box.
    const attach = accentAttach(0x1D5A0) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(0.333, attach, 0.001);
}

test "metrics: the native quadruple prime is measured, not composed" {
    const one = staticGlyph(0x2032, .italic) orelse return error.TestUnexpectedResult;
    const three = staticGlyph(0x2034, .italic) orelse return error.TestUnexpectedResult;
    const four = staticGlyph(0x2057, .italic) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(3.11, one.width, 0.001);
    try testing.expectApproxEqAbs(7.11, three.width, 0.001);
    try testing.expectApproxEqAbs(9.11, four.width, 0.001);
    // The face draws a quadruple prime as ONE composite, so it is narrower
    // than four drawn single primes (12.44pt) — the advance has to come from
    // the glyph, not from composing the prime.
    try testing.expect(four.width < 4 * one.width - 2.0);
    // … and its frame is that composite's own ink.
    const ink = glyphInkAt(0x2057, .italic);
    try testing.expectApproxEqAbs(0.748, ink.asc, 0.001);
    try testing.expectApproxEqAbs(0.851, ink.right_edge, 0.001);
    try testing.expect(ink.right_edge <= four.width / em);
    try testing.expect(ink.asc <= four.height / em);
}

test "metrics: the static prime grid switches at the script threshold too" {
    // Without a face behind it the same four codepoints are measured from this
    // module's own rows, and they switch where the font hook switches: an 8pt
    // base sets its script at 5.6pt and every prime in it is the face's
    // unencoded alternate, a 12pt base at 8.4pt and the encoded composite
    // answers again, at the width it always had. The gate is the single number
    // `font.small_prime_max_size` states, pinned on both sides of the module
    // graph that keeps them apart.
    const grid = [_]struct { cp: u21, script_pt: f32, gate_pt: f32 }{
        .{ .cp = 0x2032, .script_pt = 2.7384, .gate_pt = 2.6124 },
        .{ .cp = 0x2033, .script_pt = 4.4184, .gate_pt = 4.2924 },
        .{ .cp = 0x2034, .script_pt = 6.0984, .gate_pt = 5.9724 },
        .{ .cp = 0x2057, .script_pt = 7.7784, .gate_pt = 7.6524 },
    };
    for (grid) |row| {
        const script = glyphAt(&default, row.cp, .italic, 5.6) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(row.script_pt, script.width * 5.6 / em, 0.0001);
        const gate = glyphAt(&default, row.cp, .italic, 8.4) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(row.gate_pt, gate.width * 8.4 / em, 0.0001);
    }
    // The 10pt base is the encoded row it has always been, and nothing but a
    // prime moves across the gate.
    const base = staticGlyph(0x2034, .italic) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(7.11, base.width, 0.001);
    const x = glyphAt(&default, 'x', .italic, 5.6) orelse return error.TestUnexpectedResult;
    const x_base = staticGlyph('x', .italic) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(x_base.width, x.width, 0.0001);
    try testing.expect(smallPrimeEm(0x2035) == null);
}

test "metrics: a mark drawn OVER a nucleus takes the widest size variant it FITS" {
    // A mark set ON a nucleus is not stretched across it: XeTeX + unicode-math
    // draws the LARGEST variant the nucleus still holds, so over `M` (0.970em)
    // it uses the 0.920em hat and over `abc` (1.391em) the 1.321em one. Every
    // horizontal form reads that one rule, the brace half included. Both
    // rungs of the bundled ladder are reachable and each AdvanceMeasurement is
    // the exact boundary: a request for one rung's own size takes THAT rung,
    // and a request a thousandth of an em under it takes the rung below.
    const ladder = math_style_metrics.ladder(0x0302) orelse
        return error.TestUnexpectedResult;
    for (ladder.rungs, 0..) |rung, i| {
        const chosen = (try horizontalGlyph(&default, 0x0302, rung.req)) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(rung.adv, chosen.advance_em, 0.001);
        try testing.expectApproxEqAbs(rungInk(rung).asc, chosen.ink.asc, 0.001);
        if (i == 0) continue;
        const under = (try horizontalGlyph(&default, 0x0302, rung.req - 0.001)) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(
            ladder.rungs[i - 1].adv,
            under.advance_em,
            0.001,
        );
    }
    // The two nuclei XeTeX was measured on. The rung a covering walk would
    // have taken really does span each nucleus, so the rules cannot pass for
    // one another.
    for ([_]struct { nucleus: f32, fit: usize, spanning: usize }{
        .{ .nucleus = 0.970, .fit = 3, .spanning = 4 },
        .{ .nucleus = 1.391, .fit = 5, .spanning = 6 },
    }) |case| {
        const chosen = (try horizontalGlyph(&default, 0x0302, case.nucleus)) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(ladder.rungs[case.fit].adv, chosen.advance_em, 0.001);
        try testing.expect(ladder.rungs[case.spanning].req > case.nucleus);
        try testing.expect(ladder.rungs[case.fit].req <= case.nucleus);
    }
    // A fitted variant is a real glyph drawn at its own origin: its ink starts
    // there, ends at its advance, and floats above the baseline.
    const hat = (try horizontalGlyph(&default, 0x0302, 0.7)) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(ladder.rungs[1].adv, hat.advance_em, 0.001);
    try testing.expectApproxEqAbs(0, hat.ink.left, 0.001);
    try testing.expectApproxEqAbs(hat.advance_em, hat.ink.right_edge, 0.001);
    try testing.expectApproxEqAbs(0, hat.ink.desc, 0.001);
    try testing.expect(hat.ink.bottom > 0);
    // A narrow request takes the base mark, which LM Math draws with zero
    // advance and its ink left of the origin.
    const narrow = (try horizontalGlyph(&default, 0x0302, 0.2)) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(0, narrow.advance_em, 0.001);
    // Past the last rung an accent has no assembly, so it degrades to the
    // LARGEST variant the face draws, at that variant's OWN advance: the hat
    // keeps one kink and its real width instead of being stretched to a size
    // the font has no design for.
    const last = ladder.rungs[ladder.rungs.len - 1];
    const past = (try horizontalGlyph(&default, 0x0302, 2.0)) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(last.adv, past.advance_em, 0.001);
    try testing.expect(past.advance_em < 2.0);
    try testing.expectApproxEqAbs(last.right_edge, past.ink.right_edge, 0.001);
    try testing.expectApproxEqAbs(last.asc, past.ink.asc, 0.001);
    // Every answer names the form's finite capacity, so a caller can tell
    // "outgrew the face" from "fits inside it": the widest drawing LM Math
    // has for this mark, reached here and not before.
    try testing.expectApproxEqAbs(last.req, past.finite_ceiling_em orelse
        return error.TestUnexpectedResult, 0.001);
    try testing.expectApproxEqAbs(last.req, hat.finite_ceiling_em orelse
        return error.TestUnexpectedResult, 0.001);
    // A codepoint with no horizontal construction at all.
    const plain = try horizontalGlyph(&default, 0x0058, 0.6);
    try testing.expect(plain == null);
}

test "metrics: a brace half FITS its nucleus, it does not cover it" {
    // A brace is SET ON the width under it like every other horizontal form,
    // so it takes the widest rung of its own ladder that width still holds.
    // The exact-font reference says so plainly: at 20pt XeTeX + unicode-math
    // paints the brace half of `\underbrace{x}` 9.84pt wide where `x` is
    // 11.48pt (0.574em) and the smallest rung covering it is 19.88pt; under
    // `xx` (1.148em) 19.80pt, under `xxx` (1.722em) 29.88pt and under six of
    // them (3.445em) 60.00pt — the 0.492, 0.993, 1.494 and 3.000em rungs, each
    // a drawing the face made, never one rung wider.
    for ([_]u21{ 0x23DE, 0x23DF }) |cp| {
        const ladder = math_style_metrics.ladder(cp) orelse
            return error.TestUnexpectedResult;
        // A rung's own designed size takes THAT rung, and a thousandth of an
        // em under it takes the rung below: the AdvanceMeasurement is the
        // boundary, not the glyph.
        for (ladder.rungs, 0..) |rung, i| {
            const chosen = (try horizontalGlyph(&default, cp, rung.req)) orelse
                return error.TestUnexpectedResult;
            try testing.expectApproxEqAbs(rung.adv, chosen.advance_em, 0.001);
            try testing.expectApproxEqAbs(rungInk(rung).asc, chosen.ink.asc, 0.001);
            if (i == 0) continue;
            const under = (try horizontalGlyph(&default, cp, rung.req - 0.001)) orelse
                return error.TestUnexpectedResult;
            try testing.expectApproxEqAbs(
                ladder.rungs[i - 1].adv,
                under.advance_em,
                0.001,
            );
        }
        // The five measured nuclei, each against the rung the face's own
        // measurements put under it, and each still inside the ladder: the
        // next rung up really does span the nucleus, so a covering walk and
        // this one cannot pass for each other.
        for ([_]f32{ 0.574, 0.651, 1.148, 1.722, 3.445 }) |nucleus| {
            const chosen = (try horizontalGlyph(&default, cp, nucleus)) orelse
                return error.TestUnexpectedResult;
            var fit: usize = 0;
            while (fit + 1 < ladder.rungs.len and ladder.rungs[fit + 1].req <= nucleus) fit += 1;
            try testing.expectApproxEqAbs(ladder.rungs[fit].adv, chosen.advance_em, 0.001);
            try testing.expectApproxEqAbs(rungInk(ladder.rungs[fit]).asc, chosen.ink.asc, 0.001);
            try testing.expect(ladder.rungs[fit + 1].req > nucleus);
            // A real drawing at its own advance: the ink ends where the rung
            // ends and never starts left of the origin.
            try testing.expectApproxEqAbs(0, chosen.ink.left, 0.001);
            try testing.expectApproxEqAbs(
                ladder.rungs[fit].right_edge,
                chosen.ink.right_edge,
                0.001,
            );
            // A brace ASSEMBLES, so it reaches any width and names no ceiling.
            try testing.expect(chosen.finite_ceiling_em == null);
        }
        // A nucleus narrower than every rung keeps the base drawing.
        const narrow = (try horizontalGlyph(&default, cp, ladder.rungs[0].req - 0.001)) orelse
            return error.TestUnexpectedResult;
        try testing.expectApproxEqAbs(ladder.rungs[0].adv, narrow.advance_em, 0.001);
    }
}

test "metrics: a brace past its ladder is framed by the real assembly" {
    const req: f32 = 5.0; // past the widest top-brace rung (4.007em)
    const ladder = math_style_metrics.ladder(0x23DE) orelse
        return error.TestUnexpectedResult;
    const base = ladder.rungs[0];
    const top_rung = ladder.rungs[ladder.rungs.len - 1];
    try testing.expect(req > top_rung.req);
    try testing.expect(ladder.parts.len > 0);
    const brace = (try horizontalGlyph(&default, 0x23DE, req)) orelse
        return error.TestUnexpectedResult;
    try testing.expect(brace.advance_em >= req);
    // A brace ASSEMBLES, so it reaches any width and names no ceiling: a
    // request past its last rung is still a drawing the face can make.
    try testing.expect(brace.finite_ceiling_em == null);
    // The SMALLEST legal frame that covers the request. The extenders are
    // dropped before they are added, so the two hooks alone — the widest they
    // can legally be, every connection down to MinConnectorOverlap — stop short
    // of it, and one count below the one that reaches it is short however far
    // its connections open.
    try testing.expect(assembledStretch(ladder, 0, 0).advance_em < req);
    var repeats: usize = 0;
    while (assembledStretch(ladder, repeats, 0).advance_em < req) repeats += 1;
    try testing.expect(repeats > 0);
    try testing.expect(
        assembledStretch(ladder, repeats - 1, maxOpen(ladder, repeats - 1)).advance_em < req,
    );
    // Each repeat-flagged part is one copy wider than the one before, and the
    // copies JOIN rather than abut — so a repeat adds less than the whole
    // FullAdvance it carries, and the count above really is a stack.
    var nominal: f32 = 0;
    for (ladder.parts) |part| {
        if (part.repeat) nominal += part.adv;
    }
    const grown = assembledStretch(ladder, repeats + 1, 0).advance_em -
        assembledStretch(ladder, repeats, 0).advance_em;
    try testing.expect(grown > 0);
    try testing.expect(grown < nominal);
    // Within that count the connections are opened as LITTLE as the request
    // allows: opening one step further drops the frame back under it.
    const open = openFor(ladder, repeats, req) orelse return error.TestUnexpectedResult;
    try testing.expect(assembledStretch(ladder, repeats, open).advance_em >= req);
    try testing.expect(assembledStretch(ladder, repeats, open + 0.01).advance_em < req);
    try testing.expectApproxEqAbs(
        assembledStretch(ladder, repeats, open).advance_em,
        brace.advance_em,
        0.001,
    );
    // The ink is the parts' own: the top half floats above the baseline, its
    // cusp rises past the plain glyph, and the frame spans the whole
    // assembled width with nothing hanging off either end.
    try testing.expectApproxEqAbs(0, brace.ink.desc, 0.001);
    try testing.expect(brace.ink.bottom > 0);
    try testing.expect(brace.ink.asc > base.asc);
    try testing.expectApproxEqAbs(0, brace.ink.left, 0.001);
    try testing.expectApproxEqAbs(brace.advance_em, brace.ink.right_edge, 0.001);
    // The bottom half hangs below the baseline instead: no floating edge.
    const under = (try horizontalGlyph(&default, 0x23DF, req)) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(0, under.ink.asc, 0.001);
    try testing.expect(under.ink.desc > 0);
    try testing.expectApproxEqAbs(0, under.ink.bottom, 0.001);
}

test "metrics: an assembly opens its connections, it does not trim them" {
    // The OpenType rule is an INTERVAL per connection: the overlap is at
    // least MinConnectorOverlap and at most the connector ink both neighbours
    // offer. A stack therefore has a wide end (every connection at the floor)
    // and a tight end (every one at its ceiling), and the item grows between
    // them by opening the connections — not by shaving the overlap.
    const ladder = math_style_metrics.ladder(0x23DE) orelse
        return error.TestUnexpectedResult;
    const floor = ladder.min_connector_overlap;
    const most_open = maxOpen(ladder, 1);
    try testing.expect(most_open > 0);
    // Every connection the stack can make stays inside the legal interval, at
    // both ends of the opening and everywhere between — an extender joined to
    // its own next copy included.
    const joins = [_][2]math_style_metrics.Part{
        .{ ladder.parts[0], ladder.parts[1] },
        .{ ladder.parts[1], ladder.parts[1] },
        .{ ladder.parts[1], ladder.parts[2] },
        .{ ladder.parts[2], ladder.parts[3] },
        .{ ladder.parts[3], ladder.parts[3] },
        .{ ladder.parts[3], ladder.parts[4] },
    };
    for (joins) |pair| {
        const ceiling = @min(pair[0].end_connector, pair[1].start_connector);
        try testing.expect(ceiling >= floor);
        for ([_]f32{ 0, most_open / 2, most_open, most_open * 2 }) |open| {
            const overlap = joinOverlap(pair[0], pair[1], floor, open);
            try testing.expect(overlap >= floor - 0.0001);
            try testing.expect(overlap <= ceiling + 0.0001);
        }
        // Nothing opened is the floor itself, and opening past the interval
        // stops at the ceiling: a connection keeps every bit of connector
        // material the font drew, and not one bit more.
        try testing.expectApproxEqAbs(floor, joinOverlap(pair[0], pair[1], floor, 0), 0.0001);
        try testing.expectApproxEqAbs(
            ceiling,
            joinOverlap(pair[0], pair[1], floor, most_open * 4),
            0.0001,
        );
    }
    // The ends of the opening name the ends of the stack: nothing opened is
    // the widest it can legally be, everything opened the narrowest.
    const wide = assembledStretch(ladder, 1, 0).advance_em;
    const tight = assembledStretch(ladder, 1, most_open).advance_em;
    try testing.expect(wide > tight);
    const none = openFor(ladder, 1, wide) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(0, none, 0.001);
    const all = openFor(ladder, 1, tight) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(most_open, all, 0.001);
    // A request between them is reached, not overshot by a whole connection.
    const between = openFor(ladder, 1, (wide + tight) / 2) orelse
        return error.TestUnexpectedResult;
    try testing.expect(between > 0 and between < most_open);
    try testing.expectApproxEqAbs(
        (wide + tight) / 2,
        assembledStretch(ladder, 1, between).advance_em,
        0.001,
    );
    // Past the widest frame this count can reach there is no answer: the
    // stack may not tear its joins to cover a request it cannot reach.
    try testing.expect(openFor(ladder, 1, wide + 0.01) == null);
    // With no extenders left the join is measured straight across them: the
    // two hooks alone, sharing one floor apiece.
    try testing.expectApproxEqAbs(
        ladder.parts[0].adv + ladder.parts[2].adv + ladder.parts[4].adv - 2 * floor,
        assembledStretch(ladder, 0, 0).advance_em,
        0.001,
    );
    // Only two copies of one extender open a join wider than the hooks share
    // with it: the extenders' own connector material, and nothing else.
    try testing.expect(maxOpen(ladder, 0) == maxOpen(ladder, 1));
    try testing.expect(maxOpen(ladder, 2) > most_open);
}

test "metrics: an explicit stretch hook answers instead of the bundled geometry" {
    // The font branch owns the choice, and what its resolver returns is
    // final — including a null, which is the face saying it has no such form,
    // and its errors, which must not decay into the bundled geometry.
    const glyph_hook = struct {
        fn get(_: *anyopaque, _: u21, _: atom.CharStyle, _: f32) ?Glyph {
            return null;
        }
    }.get;
    const stretch_hook = struct {
        fn get(_: *anyopaque, cp: u21, _: f32) StretchError!?StretchGeometry {
            return switch (cp) {
                0x0302 => null, // the face has no such construction
                0x0303 => error.OutOfMemory, // decoding the outline failed
                else => .{ .advance_em = 3.5, .ink = .{ .asc = 0.9, .desc = 0 } },
            };
        }
    }.get;
    var anchor: u8 = 0;
    const fm: FontMetrics = .{ .font = .{
        .ctx = &anchor,
        .glyph = glyph_hook,
        .horizontal_glyph = stretch_hook,
    } };
    // A 1.25em request would take the brace's own 1.495em rung; the hook's
    // frame is the answer instead.
    const chosen = (try horizontalGlyph(&fm, 0x23DE, 1.25)) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(3.5, chosen.advance_em, 0.001);
    try testing.expectApproxEqAbs(0.9, chosen.ink.asc, 0.001);
    // A null stays null even though the bundled ladder has an answer.
    const absent = try horizontalGlyph(&fm, 0x0302, 0.6);
    try testing.expect(absent == null);
    try testing.expectError(error.OutOfMemory, horizontalGlyph(&fm, 0x0303, 0.6));
    // A hook with no resolver makes no claim about the face, so the generated
    // ladders answer for it.
    const bare: FontMetrics = .{ .font = .{
        .ctx = &anchor,
        .glyph = glyph_hook,
    } };
    const fallback_frame = try horizontalGlyph(&bare, 0x0302, 0.6);
    try testing.expect(fallback_frame != null);
}

test "metrics: a text face without the glyph is framed by the math outline" {
    // LM Roman carries no Greek: `\mathrm{α}` is drawn from the Math face
    // beside it, so the frame is that face's own outline for the same
    // codepoint — not a roman estimate of one.
    try testing.expect(faceGlyphInk(0x03B1, .roman) == null);
    const math_ink = faceGlyphInk(0x03B1, .italic) orelse
        return error.TestUnexpectedResult;
    const ink = glyphInkAt(0x03B1, .roman);
    try testing.expectApproxEqAbs(math_ink.asc, ink.asc, 0.0001);
    try testing.expectApproxEqAbs(math_ink.right_edge, ink.right_edge, 0.0001);
    try testing.expect(ink.right_edge > 0);
    // The face the style draws from answers for the glyphs it HAS: a bold
    // letter keeps its own design's ink, descender and all.
    const bold_p = faceGlyphInk('p', .bold) orelse return error.TestUnexpectedResult;
    try testing.expect(bold_p.desc > 0);
    // A codepoint no bundled face carries keeps the missing-glyph contract.
    const missing = glyphInkAt(0x4E2D, .roman);
    try testing.expectApproxEqAbs(0.750, missing.asc, 0.0001);
    try testing.expectApproxEqAbs(0, missing.left, 0.0001);
}
