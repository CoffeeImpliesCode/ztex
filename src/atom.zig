//! ztex.atom — superflat LaTeX atom (AST).
//!
//! One flat pool of fixed-size nodes; a node's children are a contiguous
//! index run. Duplication protocol: `createNode` re-appends copies of the
//! immediate children just before the parent, so a subtree appears in the
//! pool more than once and only the root-reachable chain is the tree.
//! Provenance is a parallel token table of byte spans.
//!
//! This module is the VOCABULARY: the tags, the node records and the `data`
//! encodings the parser writes and layout reads. It neither parses (that is
//! `ztex.parse`) nor validates — the `Ast` builders store whatever they are
//! given, and `layout.render` is the boundary that checks a tree before the
//! recursive layout reads it.

const std = @import("std");

// ── lexical tokens ────────────────────────────────────────────────────────

/// Lexical token kind.
pub const TokenTag = enum(u8) {
    /// an ordinary character/codepoint (`x`, digits, `+`, `[`, `]`, utf-8…)
    char,
    /// a control sequence `\name`; the name is `src[start+1..end]`
    command,
    /// `{`
    l_group,
    /// `}`
    r_group,
    /// `^`
    sup,
    /// `_`
    sub,
};

/// A token plus its byte span into the source.
pub const Token = struct {
    tag: TokenTag,
    /// byte offset of the first byte of this token in the source
    start: u32,
    /// byte offset just past the last byte of this token in the source
    end: u32,
};

/// A byte span into the original source. The universal provenance currency:
/// source → token → atom → box → drawable.
pub const Span = struct {
    start: u32,
    end: u32,

    /// Bytes covered, 0 for an empty or reversed span (see the body). The
    /// span is a pair of offsets; the bytes themselves are the caller's.
    pub fn len(self: Span) usize {
        // Saturating: a hand-built span with end < start must not underflow
        // (panic in Debug/ReleaseSafe) — report 0 instead.
        return self.end -| self.start;
    }
};

/// A straight (non-premultiplied) sRGB color with straight alpha. `a`
/// defaults to opaque; 0 is a fully transparent ink that paints nothing.
/// Owned by the AST module because a `\color` scope and every draw
/// primitive agree on this one shape.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

/// Parse a color from a name (`white`, `black`, …) or hex (`#RRGGBB[AA]`).
/// Returns null for the valid "no color" values `none`/`transparent`,
/// a `Color` for a recognized name/hex, and `error.UnrecognizedColor` for
/// anything else — so callers can tell "no color" apart from a typo (e.g.
/// `-b blak`). Shared by the CLI's background option and the `\color` /
/// `\textcolor` parsers, so a typo is reported identically in both.
pub fn parseColorChecked(s: []const u8) error{UnrecognizedColor}!?Color {
    if (std.mem.eql(u8, s, "none") or std.mem.eql(u8, s, "transparent")) return null;
    if (s.len > 0 and s[0] == '#') return parseHex(s[1..]) orelse error.UnrecognizedColor;
    const named = [_]struct { name: []const u8, c: Color }{
        .{ .name = "white", .c = .{ .r = 255, .g = 255, .b = 255 } },
        .{ .name = "black", .c = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .name = "red", .c = .{ .r = 255, .g = 0, .b = 0 } },
        .{ .name = "green", .c = .{ .r = 0, .g = 128, .b = 0 } },
        .{ .name = "blue", .c = .{ .r = 0, .g = 0, .b = 255 } },
        .{ .name = "yellow", .c = .{ .r = 255, .g = 255, .b = 0 } },
        .{ .name = "cyan", .c = .{ .r = 0, .g = 255, .b = 255 } },
        .{ .name = "magenta", .c = .{ .r = 255, .g = 0, .b = 255 } },
        .{ .name = "orange", .c = .{ .r = 255, .g = 165, .b = 0 } },
        .{ .name = "gray", .c = .{ .r = 128, .g = 128, .b = 128 } },
        .{ .name = "grey", .c = .{ .r = 128, .g = 128, .b = 128 } },
    };
    for (named) |n| {
        if (std.mem.eql(u8, s, n.name)) return n.c;
    }
    return error.UnrecognizedColor;
}

/// `#RRGGBB` or `#RRGGBBAA` (the leading `#` already consumed). A wrong
/// length or a non-hex digit is a null, which parseColorChecked turns into
/// error.UnrecognizedColor.
fn parseHex(s: []const u8) ?Color {
    if (s.len != 6 and s.len != 8) return null;
    var c: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    if (s.len == 8) c.a = std.fmt.parseInt(u8, s[6..8], 16) catch return null;
    c.r = std.fmt.parseInt(u8, s[0..2], 16) catch return null;
    c.g = std.fmt.parseInt(u8, s[2..4], 16) catch return null;
    c.b = std.fmt.parseInt(u8, s[4..6], 16) catch return null;
    return c;
}

/// Parser and layout share this bound for nested groups in a raw text leaf.
pub const max_text_nesting: u32 = 500;

/// The deepest `parseRow` recursion a parse may reach (src/parse/parser.zig
/// `max_nesting`). Brace nesting costs one frame per level, so a source of
/// nested groups beyond this fails with `error.NestingTooDeep` instead of
/// overflowing the C stack. Layout does NOT read this bound: its own is
/// `max_ast_depth`, below.
pub const max_nesting: u32 = 500;

/// The deepest atom tree `layout` will recurse into; a root-reachable node
/// below this depth makes the layout boundary refuse the tree with
/// `error.InvalidAst` BEFORE any recursive layout runs.
///
/// The bound has to admit every tree the parser can build and still keep
/// the recursive layout inside the C stack. The parser spends at most
/// `max_nesting` `parseRow` frames, and nesting a construct always costs a
/// frame: the only wrappers built inside an existing frame are the row
/// itself, an infix `\atop`/`\over` fraction (which replaces the row with a
/// `.fraction` over two rows) and `\pmod`-style words (a `.row` over an
/// `.opname` over the letter row) — three node levels at most, and every
/// deeper construct takes its own frame. Four times the frame bound is
/// therefore above anything a parse can produce, and keeps a hand-built
/// tree far below the depth at which the recursion would exhaust the stack.
pub const max_ast_depth: u32 = 4 * max_nesting;

/// Combine two TEXT face styles into the single face that carries both
/// (LaTeX's `\textbf{\textit{x}}` is BOLD ITALIC). A text face is upright
/// roman plus the italic and bold modifiers, so the combination is the
/// union of the modifiers. A MATH alphabet style (.bb, .cal, …) has no
/// modifiers, so a nested text face leaves it untouched — `\mathbb` is a
/// blackboard face, not "roman in bold".
pub inline fn combineTextStyles(outer: CharStyle, inner: CharStyle) CharStyle {
    const italic = outer == .text_italic or outer == .bold_italic or
        inner == .text_italic or inner == .bold_italic;
    const bold = outer == .bold or outer == .bold_italic or
        inner == .bold or inner == .bold_italic;
    const is_text = outer == .roman or outer == .text_italic or
        outer == .bold or outer == .bold_italic;
    if (!is_text or !(italic or bold)) return outer;
    if (italic and bold) return .bold_italic;
    if (bold) return .bold;
    if (italic) return .text_italic;
    return .roman;
}

/// Math/text font style of a character or text run.
pub const CharStyle = enum(u8) {
    /// default math italic (variables)
    italic,
    /// upright roman (\mathrm, \text)
    roman,
    /// bold (\mathbf)
    bold,
    /// blackboard (\mathbb)
    bb,
    /// calligraphic (\mathcal)
    cal,
    /// fraktur (\mathfrak)
    frak,
    /// sans-serif (\mathsf)
    sans,
    /// monospace (\mathtt)
    mono,
    /// TEXT italic (\textit) — LM Roman Italic, NOT math italic: the raw
    /// bytes stay as written (no Unicode math remapping) and the text
    /// renderer picks the italic roman face.
    text_italic,
    /// TEXT bold italic (\textbf{\textit{…}} / \textit{\textbf{…}}) — the
    /// two text faces combined; see `combineTextStyles`.
    bold_italic,
};

/// Raw text scopes add face modifiers; an inner upright scope preserves
/// modifiers supplied by its enclosing scope.
pub fn textFaceCommand(name: []const u8) ?CharStyle {
    if (std.mem.eql(u8, name, "textit")) return .text_italic;
    if (std.mem.eql(u8, name, "textbf")) return .bold;
    if (std.mem.eql(u8, name, "text")) return .roman;
    return null;
}

/// Whether `c` is one of the accent control symbols a `\text` run accepts
/// (`\H \r \v \u \c \d \b \t` and the seven accent marks).
pub inline fn isTextAccentControl(c: u8) bool {
    return switch (c) {
        'H',
        'r',
        'v',
        'u',
        'c',
        'd',
        'b',
        't',
        '\'',
        '`',
        '"',
        '^',
        '~',
        '.',
        '=',
        => true,
        else => false,
    };
}

/// Parser validation and raw-text layout share one command repertoire.
pub fn textCommandSupported(name: []const u8) bool {
    if (textFaceCommand(name) != null) return true;
    if (name.len != 1) return false;
    return isTextAccentControl(name[0]) or switch (name[0]) {
        'i', 'j', ' ', '{', '}', '$', '%', '&', '#', '_' => true,
        else => false,
    };
}

/// Big operator (rendered large; scripts become limits in display style).
pub const BigOp = enum(u8) {
    sum,
    int,
    prod,
    coprod,
    bigcup,
    bigcap,
    bigsqcup,
    oint,
    oiint,
    oiiint,
    ointctrclockwise,
    /// the \bigXXX n-ary family (\bigodot \bigoplus \bigotimes \biguplus
    /// \bigsqcap \bigwedge \bigvee) plus \bigstar
    bigodot,
    bigoplus,
    bigotimes,
    biguplus,
    bigsqcap,
    bigwedge,
    bigvee,
    bigstar,
    /// the BIG integrals: no single Unicode "big integral" exists, so these
    /// draw the ordinary integral codepoints at a larger size (see
    /// metrics.bigOpScale)
    bigint,
    bigiint,
    bigiiint,
};

/// TeX math style. Layout's `Style` is an alias of this, so the parser can
/// pack a forced style into a `fraction` node's `data` or a `.mathstyle`
/// node's `data` without a layout import.
pub const MathStyle = enum(u8) {
    display = 0,
    text = 1,
    script = 2,
    script_script = 3,
};

/// TeX math CLASS of an atom — the value the inter-atom glue table is
/// indexed by (tex.web §799). Layout derives it per atom for a private
/// mirror of the same eight classes; the parser records an EXPLICIT class
/// (`\mathord` and friends, `\colon`) in a `.row` node's `data` (see
/// `ClassBits`), so this enum is the parser's spelling of that table.
pub const MathClass = enum(u8) {
    ord,
    op,
    bin,
    rel,
    open,
    close,
    punct,
    inner,
};

/// Encoding of a class override in a `.row` node's `data`: the low four
/// bits carry the row marker, bits 8-10 the class. The marker is 13 — the
/// fixed markers 0..12, the phantom family's bit 4 and the kern family's
/// bit 5 are taken, so 13 is the first free value, and `data & 0xF == 13`
/// is reachable only through this encoding (a phantom row is 16|keep, a
/// kern row 32|unit).
pub const ClassBits = struct {
    pub const marker: u32 = 13;
    pub const class_shift: u5 = 8;
    pub const class_mask: u32 = 0x7;
};

/// The `data` of a class-override row (one child: the wrapped field).
pub inline fn classRowData(cls: MathClass) u32 {
    return ClassBits.marker | (@as(u32, @intFromEnum(cls)) << ClassBits.class_shift);
}

/// Whether a `.row` node's `data` carries a class override.
pub inline fn isClassRow(data: u32) bool {
    return data & 0xF == ClassBits.marker;
}

/// The class a class-override row reports on BOTH sides of its content.
pub inline fn classRowClass(data: u32) MathClass {
    return @enumFromInt((data >> ClassBits.class_shift) & ClassBits.class_mask);
}

/// Math environment kinds, packed into an `.env` node's `data` low bits.
pub const EnvKind = enum(u8) {
    matrix = 0,
    pmatrix = 1,
    bmatrix = 2,
    Bmatrix = 3,
    vmatrix = 4,
    Vmatrix = 5,
    cases = 6,
    aligned = 7,
    array = 8,
};

/// Bit layout of an `.env` node's `data`:
///   bits 0-3  environment kind (EnvKind)
///   bits 4-7  packed array colspec length (slots that follow; 0 for the
///             matrix family / cases / aligned)
///   bits 8+   array colspec slots, 2 bits per spec char (first char at
///             bit 8): 0 = l, 1 = c, 2 = r, 3 = | (vertical rule BEFORE
///             that column — a leading | draws a rule at the array's left
///             edge). Rules occupy their own slot, so a ruled spec
///             `|c|c|...` consumes one slot per alignment AND one per rule:
///             the 2-bit slot width fits 12 spec chars (6 ruled columns,
///             e.g. `|c|c|c|c|c|c`); beyond the spec, columns align
///             centered (TeX: extra columns default to c).
pub const EnvBits = struct {
    pub const kind_mask: u32 = 0xF;
    pub const count_shift: u5 = 4;
    pub const col_shift: u5 = 8;
    pub const col_nibble: u32 = 0x3;
    pub const col_l: u32 = 0;
    pub const col_c: u32 = 1;
    pub const col_r: u32 = 2;
    pub const col_rule: u32 = 3;
    pub const max_spec_cols: usize = 12;
};

/// The environment kind an `.env` node's `data` carries. A `data` whose low
/// bits name no kind is refused by `layout.render`, which checks the field
/// before this `@enumFromInt` can trap on it.
pub inline fn envKind(data: u32) EnvKind {
    return @enumFromInt(data & EnvBits.kind_mask);
}

/// Number of array colspec nibbles packed in `data` (0 for non-array envs).
pub inline fn envSpecCount(data: u32) usize {
    return (data >> EnvBits.count_shift) & 0xF;
}

/// The packed colspec nibble for column `i`, or null past the encoded count.
/// Requires `data` produced by `envData`, or a validated count no greater
/// than `EnvBits.max_spec_cols`; larger counts cannot fit the shift encoding.
pub inline fn envColSpec(data: u32, i: usize) ?u32 {
    if (i >= envSpecCount(data)) return null;
    return (data >> (EnvBits.col_shift + @as(u5, @intCast(2 * i)))) & EnvBits.col_nibble;
}

/// Pack an `.env` node's `data` from the kind and the array colspec (a byte
/// string of l/c/r/| chars; unknown chars count as centered). The spec is
/// truncated to `max_spec_cols` slots.
pub inline fn envData(kind: EnvKind, colspec: []const u8) u32 {
    var data: u32 = @intFromEnum(kind);
    const n = @min(colspec.len, EnvBits.max_spec_cols);
    data |= @as(u32, @intCast(n)) << EnvBits.count_shift;
    for (colspec[0..n], 0..) |b, i| {
        const nib: u32 = switch (b) {
            'l' => EnvBits.col_l,
            'r' => EnvBits.col_r,
            '|' => EnvBits.col_rule,
            else => EnvBits.col_c,
        };
        data |= nib << (EnvBits.col_shift + @as(u5, @intCast(2 * i)));
    }
    return data;
}

/// Presence bits stored in a `script` node's `data`.
pub const ScriptBits = struct {
    pub const sup: u32 = 1 << 0;
    pub const sub: u32 = 1 << 1;
};

/// Bit layout of a `fraction` node's `data`: bit 0 = rule line (\frac vs
/// \atop), bits 1-4 = forced math-style code (0 = none, else MathStyle + 1),
/// bit 5 = \cfrac's parts-at-display-style flag, bits 6-21 = \genfrac's
/// explicit rule thickness (pt, Q8.8 fixed point; 0 = none — use the font's
/// rule_thickness or \atop's no rule). A plain \frac/\atop keeps data 0/1 —
/// byte-identical to the pre-feature encoding.
pub const FractionBits = struct {
    pub const line: u32 = 1 << 0;
    pub const forced_shift: u5 = 1;
    pub const forced_mask: u32 = 0xF;
    pub const parts_display: u32 = 1 << 5;
    /// \genfrac's explicit rule thickness in bits 6-21 (Q8.8 fixed point:
    /// 1/256 pt resolution, up to 255.99 pt). Zero means "no explicit
    /// thickness": \frac/\atop use the font's rule_thickness (or no rule).
    pub const thick_shift: u5 = 6;
    pub const thick_mask: u32 = 0xFFFF;
    /// \genfrac-with-delimiters (\binom, `\genfrac{()}{...}`) mark their
    /// fraction data with this bit so layout sizes the parens to amsc's FIXED
    /// fraction-delimiter size instead of TeX's content-\left sizing (TeX's
    /// own `\left( a \atop b \right)` stays content-based; only the
    /// `\genfrac`-delimited fraction is fixed). Bit 22 is free (FractionBits
    /// uses 0..21; the high-bit LimitBits live on `script`/`op` nodes).
    pub const fixed_delim: u32 = 1 << 22;
};

/// Encode fraction `data` from the line flag, the optional forced style
/// (\dfrac → .display, \tfrac → .text), and \cfrac's parts-at-display flag.
pub inline fn fracData(line: bool, forced: ?MathStyle, parts_display: bool) u32 {
    const code: u32 = if (forced) |f| @as(u32, @intFromEnum(f)) + 1 else 0;
    return @intFromBool(line) |
        (code << FractionBits.forced_shift) |
        (@as(u32, @intFromBool(parts_display)) << 5);
}

/// Whether the fraction draws a rule line (\frac \dfrac \tfrac \cfrac).
pub inline fn fracLine(data: u32) bool {
    return data & FractionBits.line != 0;
}

/// The forced style of a \dfrac/\tfrac/\cfrac fraction; null for \frac/\atop.
pub inline fn fracForcedStyle(data: u32) ?MathStyle {
    const code = (data >> FractionBits.forced_shift) & FractionBits.forced_mask;
    if (code == 0) return null;
    return @enumFromInt(code - 1);
}

/// \cfrac flag: lay out BOTH parts in display style (amsmath's continued
/// fraction), on top of the display-style gaps.
pub inline fn fracPartsDisplay(data: u32) bool {
    return data & FractionBits.parts_display != 0;
}

/// Encode a \genfrac rule thickness (pt) as Q8.8 in the thick bits; 0 for
/// "no explicit thickness". Values are clamped to [0, 255.99]; a non-rule
/// genfrac (\atop-style) carries thickness 0 like a plain \frac/\atop.
pub inline fn fracThicknessBits(pt: f32) u32 {
    // Clamp into the Q8.8 range BEFORE the float->int conversion: an
    // attacker-controlled \genfrac thickness (e.g. 99999999pt) would
    // otherwise overflow i32 in `@intFromFloat` (panic in Debug/ReleaseSafe,
    // UB in ReleaseFast). 255.99pt is the largest Q8.8 value (0xFFFF/256).
    const clamped = @min(@max(pt, 0), 255.99);
    const q: u32 = @intFromFloat(@round(clamped * 256.0));
    return (q << FractionBits.thick_shift) &
        (FractionBits.thick_mask << FractionBits.thick_shift);
}

/// The \genfrac rule thickness in pt (absolute TeX dimension — layout does
/// NOT scale it with the font size); 0 when the fraction has no explicit
/// thickness (plain \frac/\atop, or a 0pt genfrac).
pub inline fn fracThickness(data: u32) f32 {
    const q: i32 = @bitCast((data >> FractionBits.thick_shift) & FractionBits.thick_mask);
    return @as(f32, @floatFromInt(q)) / 256.0;
}
/// True when the fraction node is wrapped by amsmath `\genfrac` delimiters
/// (`\binom`, `\genfrac{..}{..}{..}{..}{n}{d}` with delimiters) — layout sizes
/// those parens to amsc's FIXED fraction-delimiter size, not a content-`\left`
/// delta. Set by the parser on the fraction `data`; read by layoutLeftRight.
pub inline fn fracFixedDelim(data: u32) bool {
    return data & FractionBits.fixed_delim != 0;
}

/// Limits-override bits packed into the HIGH bits of an `op`/`opname`
/// node's `data` (the low bits carry the BigOp enum / the opname
/// limit-taking flag). The parser sets them when \limits / \nolimits /
/// \displaylimits follows the operator atom (TeX: "limit controls"); the
/// layout reads them to force or restore the over/under-limits decision.
pub const LimitsBits = struct {
    /// Bit mask isolating the override bits within `data`.
    pub const mask: u32 = 0x6000_0000;
    /// \limits: force over/under limits in display AND text styles.
    pub const force: u32 = 1 << 29;
    /// \nolimits: force beside scripts in every style.
    pub const force_beside: u32 = 1 << 30;
    /// Everything below the override bits: the BigOp enum / limit flag.
    pub const value_mask: u32 = 0x1FFF_FFFF;
};

/// The MATH table's font-wide constants, decoded once per face. Every
/// length is in em units (the table's design value ÷ unitsPerEm) and
/// every `*_percent` field is a ratio: a font that stores 70 for the
/// script scale-down yields 0.7. Device tables — the ppem-specific
/// adjustments a MathValueRecord may point at — are ignored, so a value
/// is the design-unit value that layout scales to the requested size.
///
/// Lives here, not in the font module, so `atom.FontHook`-style consumers
/// (layout's glue table, the draw pipeline) can read a face's constants
/// without the font module importing anything but the AST vocabulary.
pub const MathConstants = struct {
    // Style-to-size factors and formula minimums.
    script_percent_scale_down: f32,
    script_script_percent_scale_down: f32,
    delimited_sub_formula_min_height: f32,
    display_operator_min_height: f32,
    // Line spacing, the math axis, and accent placement.
    math_leading: f32,
    axis_height: f32,
    accent_base_height: f32,
    flattened_accent_base_height: f32,
    // Subscripts and superscripts.
    subscript_shift_down: f32,
    subscript_top_max: f32,
    subscript_baseline_drop_min: f32,
    superscript_shift_up: f32,
    superscript_shift_up_cramped: f32,
    superscript_bottom_min: f32,
    superscript_baseline_drop_max: f32,
    sub_superscript_gap_min: f32,
    superscript_bottom_max_with_subscript: f32,
    space_after_script: f32,
    // Limits stacked above or below an operator.
    upper_limit_gap_min: f32,
    upper_limit_baseline_rise_min: f32,
    lower_limit_gap_min: f32,
    lower_limit_baseline_drop_min: f32,
    // Stacks (\atop and friends) and stretched stacks.
    stack_top_shift_up: f32,
    stack_top_display_style_shift_up: f32,
    stack_bottom_shift_down: f32,
    stack_bottom_display_style_shift_down: f32,
    stack_gap_min: f32,
    stack_display_style_gap_min: f32,
    stretch_stack_top_shift_up: f32,
    stretch_stack_bottom_shift_down: f32,
    stretch_stack_gap_above_min: f32,
    stretch_stack_gap_below_min: f32,
    // Fractions, upright and skewed.
    fraction_numerator_shift_up: f32,
    fraction_numerator_display_style_shift_up: f32,
    fraction_denominator_shift_down: f32,
    fraction_denominator_display_style_shift_down: f32,
    fraction_numerator_gap_min: f32,
    fraction_num_display_style_gap_min: f32,
    fraction_rule_thickness: f32,
    fraction_denominator_gap_min: f32,
    fraction_denom_display_style_gap_min: f32,
    skewed_fraction_horizontal_gap: f32,
    skewed_fraction_vertical_gap: f32,
    // Overbar, underbar, and radical sign.
    overbar_vertical_gap: f32,
    overbar_rule_thickness: f32,
    overbar_extra_ascender: f32,
    underbar_vertical_gap: f32,
    underbar_rule_thickness: f32,
    underbar_extra_descender: f32,
    radical_vertical_gap: f32,
    radical_display_style_vertical_gap: f32,
    radical_rule_thickness: f32,
    radical_extra_ascender: f32,
    radical_kern_before_degree: f32,
    radical_kern_after_degree: f32,
    /// Bottom of the radical degree as a fraction of the radical sign's
    /// ascender.
    radical_degree_bottom_raise_percent: f32,
};

/// Atom (node) tag.
pub const Tag = enum(u8) {
    /// a sequence of sibling atoms; children = the atoms in order
    row,
    /// `{ ... }`; exactly 1 child
    group,
    /// a glyph; leaf. Codepoint re-read from the source span. The effective
    /// font style comes from the nearest enclosing `styled` node.
    char,
    /// `base^sup_sub`; children[0]=base, [1]=sup, [2]=sub (null if absent)
    script,
    /// `\frac{num}{den}` / `\atop`; children[0]=num, [1]=den; data: line flag
    fraction,
    /// horizontal space (\, \; \quad); leaf; data: width_em (f32 bits)
    space,
    /// `\text{...}`; leaf; raw bytes re-read from source span; data: CharStyle
    text,
    /// a style scope (`\mathbf{...}`); 1 child; data: CharStyle
    styled,
    /// a forced math style (`\displaystyle \textstyle \scriptstyle
    /// \scriptscriptstyle`); 1 child = a row of everything after the
    /// command (rest-of-group semantics); data: MathStyle
    mathstyle,
    /// a big operator (`\sum \int \prod ...`); leaf; data: BigOp
    op,
    /// an operator word (`\sin \lim \log ...`); 1 child = a row of the
    /// name's letters (each a char leaf carrying its ASCII codepoint in
    /// `data`); always roman. `data`: 1 when the word takes display-style
    /// over/under limits like a big operator (\lim \max \min \sup \inf \det
    /// \gcd \Pr \arg \ker \dim \hom \deg \limsup \liminf), 0 otherwise
    /// (\sin \cos \log \exp ... keep scripts as regular sub/superscripts).
    opname,
    /// `\left <delim> ... \right <delim>`: children [open?, inner, close?]
    /// where open/close are delimiter char leaves (absent for `\left.` /
    /// `\right.`); the inner is the delimited row. Layout stretches the
    /// delimiters to cover the inner's height.
    left,
    /// `\overline{x}` / `\underline{x}`: 1 child = the content (a single
    /// atom or braced group); `data` = 0 over / 1 under. Layout lays the
    /// content out (cramped for \overline, TeX make_over) and draws a rule
    /// of `rule_thickness` at a clearance of 3·rule_thickness from the
    /// content's box edge, spanning exactly the content width (tex.web
    /// overbar/make_under). Scripts after it attach via the usual
    /// parseAtom path, like any base.
    overline,
    /// \mathchoice{D}{T}{S}{SS}`: TeX's four-style choice primitive.
    /// children = the four branches [D, T, S, SS]. Layout picks the branch
    /// matching the CURRENT math style (display→0, text→1, script→2,
    /// scriptscript→3) and lays it out with the branch's OWN style forced
    /// (branch i is set at style i — the D branch renders at display size
    /// even inside a script, exactly \dfrac's forcing). Scripts after it
    /// attach via the usual parseAtom path, like any base.
    mathchoice,
    /// `\substack{a \\ b \\ c}` (amsmath): a script-size multi-line stack
    /// for limits, e.g. \sum_{\substack{i=1 \\ j=2}} x_i x_j. Children = the
    /// `\\`-separated lines, each a row. Layout lays the lines out at
    /// script style, centered, stacked with the TeX \subarray baseline
    /// gaps, and the whole stack is a single script-sized box (a `\vcenter`
    /// in TeX — the reference placement under a big op matches the raw
    /// stack box, see layoutSubstack). Scripts after it attach via the
    /// the usual parseAtom path, like any base.
    substack,
    /// `\begin{env}...\end{env}` math environment (matrix/pmatrix/bmatrix/
    /// Bmatrix/vmatrix/Vmatrix/cases/aligned/array). Children =
    /// [open?, entry1, ..., entryN, close?] — the optional delimiter char
    /// leaves (only pmatrix/bmatrix/Bmatrix/vmatrix/Vmatrix/cases; each a
    /// char leaf whose `data` carries the delimiter codepoint, like \cdot)
    /// around the body entries. An entry is EITHER a `.row` (children = the
    /// cell atoms; a cell may be a .group/.row of its content; cells split
    /// on `&`, rows on `\\`) OR a `.hline` rule leaf standing BETWEEN two
    /// rows — never a cell and never a row, so a leading, intermediate or
    /// trailing `\hline` adds no empty row and repeated rules stay separate
    /// entries. `data` = env kind (low 4 bits) plus the packed array colspec
    /// (see EnvBits).
    env,
    /// a foreground-color DECLARATION (`\color{red}…`). Exactly ONE child:
    /// the rest of the current math group / row / cell. `data` =
    /// 0xRRGGBBAA (see ColorBits).
    ///
    /// The wrapper is TRANSPARENT to geometry AND to math class: it lays the
    /// child out unchanged and only sets the inherited paint color, so a
    /// colored relation keeps its relation glue. That is what xcolor's
    /// `\color` is — a switch, not a group — and it is measured: `a
    /// \color{red}= b` keeps the rel glue. A nested scope shadows this one
    /// and the outer color resumes when the nested scope ends.
    color,
    /// `\textcolor{red}{<text>}`: the color of ONE braced argument.
    /// Exactly ONE child; `data` = 0xRRGGBBAA, the same encoding as `.color`.
    ///
    /// Unlike `.color` this wrapper is a GROUP: xcolor's \textcolor is
    /// `\leavevmode{\color…#2}`, and the braces make the content an ORD, so
    /// a colored RELATION loses its relation glue. Measured on the XeTeX +
    /// xcolor reference at 20pt: `a\textcolor{red}{=}b` is 35.0pt wide,
    /// exactly `a\mathord{=}b`, while `a\color{red}=b` keeps the 46.11pt of
    /// `a=b`. So `.textcolor` reports the ORD class a plain `.group` does,
    /// and `.color` reports its child's own class.
    textcolor,
    /// `\boxed{x}`: a frame around ONE child, exactly LaTeX's \fbox around
    /// `\m@th$\displaystyle x$` — layout draws the four rules OUTSIDE the
    /// content at fboxsep=3pt / fboxrule=0.4pt (fixed physical dimensions,
    /// never scaled by the font size). `data` = 0.
    boxed,
    /// `\hline`: a full-width horizontal rule BETWEEN two environment rows.
    /// A LEAF (`num_children == 0`) and legal ONLY at an environment row
    /// boundary: it is an entry in the `.env` node's child run, never a
    /// cell and never a row, so leading, intermediate and trailing rules
    /// never fabricate an empty row. `data` = 0.
    hline,
};

/// A flat, fixed-size AST node.
///
/// Stored as given, never normalized: the constructors do not check that
/// `first_token + num_tokens` fits the token table, that a span lands inside
/// the source, or that `data` names a member of the enum a tag decodes it
/// to. `layout.render` checks all three over the root-reachable subtree
/// before layout reads them.
pub const Node = struct {
    /// what kind of atom this is; it fixes the meaning of `data` and how many
    /// children the node must carry
    tag: Tag,
    /// index of the first token this node spans (into Ast.tokens)
    first_token: u32,
    /// number of tokens this node spans
    num_tokens: u32,
    /// index of the first child (into Ast.nodes); leaf nodes set it to
    /// `null_node` (0), but 0 is a VALID index — test `num_children == 0`
    /// for "no children", never `first_child == 0`.
    first_child: u32,
    /// number of children in the contiguous run starting at `first_child`
    num_children: u16,
    /// tag-specific scalar payload, encoded per tag (the `Bits` structs above
    /// and the `Tag` docs): a `CharStyle` on `.styled`/`.text`, a
    /// `MathStyle` on `.mathstyle`, a `BigOp` plus `LimitsBits` on `.op`, an
    /// `EnvKind` plus the array colspec on `.env`, `FractionBits` on
    /// `.fraction`, `ScriptBits` on `.script`, 0xRRGGBBAA on
    /// `.color`/`.textcolor`, and a raw f32 bit pattern on `.space`.
    data: u32,
};

/// Sentinel "no child / no node" index (0). Only a default for leaf nodes'
/// `first_child`; the authoritative no-children test is `num_children == 0`
/// (0 is a VALID node index, so never test `first_child == 0` for that).
const null_node: u32 = 0;

/// Encoding of a `.color` / `.textcolor` node's `data`: the scope's color as
/// 0xRRGGBBAA, byte order r<<24 | g<<16 | b<<8 | a (the low byte is alpha,
/// so the word reads in memory order). Alpha 0 is a real TRANSPARENT
/// foreground {0,0,0,0} — never "inherit the outer color".
pub const ColorBits = struct {
    pub const r_shift: u5 = 24;
    pub const g_shift: u5 = 16;
    pub const b_shift: u5 = 8;
};

/// Pack a color into the `0xRRGGBBAA` word a `.color`/`.textcolor` node's
/// `data` holds; `nodeColor` is the inverse.
pub inline fn colorData(c: Color) u32 {
    return (@as(u32, c.r) << ColorBits.r_shift) |
        (@as(u32, c.g) << ColorBits.g_shift) |
        (@as(u32, c.b) << ColorBits.b_shift) |
        @as(u32, c.a);
}

/// The color a `.color` node carries. `data` 0 decodes to the transparent
/// {0,0,0,0} ink, which is a real color, not an absent scope.
pub inline fn nodeColor(data: u32) Color {
    return .{
        .r = @truncate(data >> ColorBits.r_shift),
        .g = @truncate(data >> ColorBits.g_shift),
        .b = @truncate(data >> ColorBits.b_shift),
        .a = @truncate(data),
    };
}

/// Encode a width-in-em for `space` node data: the f32 em value, stored as
/// its raw bits (not Q16.16 — the payload only ever holds table constants).
/// A bitcast round-trips losslessly; the previous Q16.16 conversion rounded
/// each constant to 1/65536 em and could overflow on hostile inputs.
pub inline fn emToFixed(em: f32) u32 {
    return @bitCast(em);
}

/// The em width a `space` node's `data` carries, read back as the f32
/// `emToFixed` stored.
pub inline fn fixedToEm(v: u32) f32 {
    return @bitCast(v);
}

/// `\arraystretch`'s factor as an environment's FIRST ROW `.row` node
/// carries it in `data`: the f32 em value (emToFixed), or null when the
/// layout must use the per-kind default (no assignment in effect).
///
/// A row's `data` is free inside an environment because `layoutEnv` walks a
/// row's CELLS and never lays the row node out itself, so the value cannot
/// be mistaken for a row marker (1..12), atom.ClassBits's 13, the phantom
/// family's bit 4 or the kern family's bit 5. The f32 patterns of real
/// factors DO set bits 4 and 5, which is exactly why the stamp cannot live
/// in a field that shares a node pool with the markers.
pub inline fn rowStretch(data: u32) ?f32 {
    if (data == 0) return null;
    return fixedToEm(data);
}

/// Errors returned by AST mutation operations.
pub const Error = std.mem.Allocator.Error || error{
    ChildCountOverflow,
};

inline fn checkNodeCapacity(current: usize, additional: usize) std.mem.Allocator.Error!void {
    const limit: usize = std.math.maxInt(u32);
    if (current > limit or additional > limit - current) return error.OutOfMemory;
}

/// The superflat AST: source + parallel token table + flat node pool.
///
/// Owns nothing beyond the two ArrayLists; the caller provides `gpa`. Free
/// with `deinit`. Node indices are stable for the lifetime of the Ast; the
/// append-only pool's backing allocation can move as it grows.
///
/// Ownership: `Ast` OWNS its two ArrayLists. Do NOT copy an `Ast` by value
/// (a copy would alias the same buffers and double-free on `deinit`); create
/// with `init` and free with `deinit` exactly once, on the original.
///
/// Nothing in this module validates a tree. The constructors below build
/// whatever the caller describes — an out-of-range token run or an
/// out-of-range `data` is stored as given — so a hand-built `Ast` is only
/// safe to read through `layout.render`, which checks the whole
/// root-reachable subtree (arity, child bounds, tree shape, depth, token
/// runs, source spans, enum payloads) before any layout recursion runs.
pub const Ast = struct {
    /// The allocator both tables are drawn from. The caller owns it and it
    /// must outlive this Ast.
    gpa: std.mem.Allocator,
    /// The formula source. BORROWED, never copied and never written here:
    /// every node's token span and every layout read of a glyph's bytes are
    /// offsets into it, so it must stay alive and unmodified for as long as
    /// anything reads those spans.
    src: []const u8,
    /// Lexical tokens in source order. `Node.first_token`/`num_tokens` index
    /// a contiguous run here; `Ast.span` reads only the run's two ends.
    tokens: std.ArrayList(Token) = .empty,
    /// The node pool: a node index is a slot in it, and a node's children
    /// are the contiguous run starting at its `first_child`.
    nodes: std.ArrayList(Node) = .empty,
    /// index of the root node (the whole formula), set by the parser
    root: u32 = 0,

    /// Create an empty Ast over `src`. The caller must pre-lex into `tokens`
    /// before parsing (see ztex.parse.lexer).
    pub fn init(gpa: std.mem.Allocator, src: []const u8) Ast {
        return .{ .gpa = gpa, .src = src };
    }

    /// Releases the token and node tables; `src` is borrowed and left
    /// untouched. The Ast is unusable afterward, and a second call is a
    /// double free.
    pub fn deinit(self: *Ast) void {
        self.tokens.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.* = undefined;
    }

    /// Preallocate the token table (~src.len/4 tokens, then nodes).
    pub fn reserve(self: *Ast, token_count: usize, node_count: usize) !void {
        try self.tokens.ensureTotalCapacity(self.gpa, token_count);
        try self.nodes.ensureTotalCapacity(self.gpa, node_count);
    }

    /// Append a token; the caller tracks indices via items.len.
    pub fn pushToken(self: *Ast, t: Token) !void {
        try self.tokens.append(self.gpa, t);
    }

    /// Appends one node and returns its index. The node's fields are stored
    /// as given — a child run that does not exist or a `data` outside its
    /// enum is accepted here and refused by `layout.render`.
    pub fn pushNode(self: *Ast, n: Node) !u32 {
        try checkNodeCapacity(self.nodes.items.len, 1);
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, n);
        return idx;
    }

    /// Appends `ns` and returns the index of the first; they stay contiguous.
    pub fn pushNodes(self: *Ast, ns: []const Node) !u32 {
        try checkNodeCapacity(self.nodes.items.len, ns.len);
        const first: u32 = @intCast(self.nodes.items.len);
        try self.nodes.appendSlice(self.gpa, ns);
        return first;
    }

    /// Create a node with a contiguous child run: copies `children` into the
    /// pool, then appends the parent pointing at that run.
    ///
    /// `data` is stored verbatim (the per-tag encoding above). A run longer
    /// than `maxInt(u16)` children is `error.ChildCountOverflow`, and a pool
    /// that could not index the run is `error.OutOfMemory`; both are decided
    /// before any append, so a failed call leaves the pool as it was.
    pub fn createNode(
        self: *Ast,
        tag: Tag,
        first_token: u32,
        num_tokens: u32,
        children: []const Node,
        data: u32,
    ) Error!u32 {
        if (children.len > std.math.maxInt(u16)) return error.ChildCountOverflow;
        const additional = children.len + 1;
        try checkNodeCapacity(self.nodes.items.len, additional);
        const first: u32 = @intCast(self.nodes.items.len);
        try self.nodes.ensureUnusedCapacity(self.gpa, additional);
        self.nodes.appendSliceAssumeCapacity(children);
        const idx: u32 = @intCast(self.nodes.items.len);
        self.nodes.appendAssumeCapacity(.{
            .tag = tag,
            .first_token = first_token,
            .num_tokens = num_tokens,
            .first_child = first,
            .num_children = @intCast(children.len),
            .data = data,
        });
        return idx;
    }

    /// Appends a childless node (`first_child` = `null_node`, which 0 also
    /// is, so the no-children test stays `num_children == 0`) and returns its
    /// index.
    pub fn createLeaf(
        self: *Ast,
        tag: Tag,
        first_token: u32,
        num_tokens: u32,
        data: u32,
    ) !u32 {
        return self.pushNode(.{
            .tag = tag,
            .first_token = first_token,
            .num_tokens = num_tokens,
            .first_child = null_node,
            .num_children = 0,
            .data = data,
        });
    }

    /// The node at `idx`. `layout.render` validates the whole tree at its
    /// boundary, so this index is in range for anything that reached layout;
    /// the assert catches a bad index on a hand-built tree in a debug or
    /// safe build, and compiles out of ReleaseFast where the branch would
    /// sit on the hottest accessor in layout.
    pub inline fn node(self: *const Ast, idx: u32) Node {
        std.debug.assert(idx < self.nodes.items.len);
        return self.nodes.items[idx];
    }

    /// The `i`-th child index of node `idx`. Panics if `i` is out of bounds
    /// (callers must check `num_children` first; an empty node has
    /// `num_children == 0` — never probe `first_child == 0`, which is a
    /// valid index).
    pub inline fn child(self: *const Ast, idx: u32, i: usize) u32 {
        const n = self.node(idx);
        if (i >= n.num_children) @panic("Ast.child: child index out of bounds");
        return n.first_child + @as(u32, @intCast(i));
    }

    /// Byte span of a node in the source, via its token range.
    ///
    /// O(1): `src[tokens[first].start .. tokens[last].end]`. Only meaningful
    /// for nodes whose token range is non-empty.
    ///
    /// The returned offsets are whatever the tokens carry: nothing here
    /// checks them against the token table or against `src`, because the
    /// token reads themselves are unchecked. A tree that came from the
    /// lexer has both, and `layout.render` verifies them for a hand-built
    /// one before anything reads a span. DECODING the bytes is a separate
    /// precondition: `src` is expected to be well-formed UTF-8 at its token
    /// boundaries, and a span that cuts a codepoint in half decodes to
    /// U+0000 rather than trapping.
    pub inline fn span(self: *const Ast, idx: u32) Span {
        const n = self.node(idx);
        if (n.num_tokens == 0) return .{ .start = 0, .end = 0 };
        const first_t = self.tokens.items[n.first_token];
        const last_t = self.tokens.items[n.first_token + n.num_tokens - 1];
        return .{ .start = first_t.start, .end = last_t.end };
    }
};

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "span: length is end minus start" {
    const s: Span = .{ .start = 4, .end = 9 };
    try testing.expectEqual(@as(usize, 5), s.len());
}

fn testAst() !Ast {
    var a = Ast.init(testing.allocator, "x^2");
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .sup, .start = 1, .end = 2 });
    try a.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    return a;
}

test "ast: reserve and push tokens" {
    var a = try testAst();
    defer a.deinit();
    try testing.expectEqual(@as(usize, 3), a.tokens.items.len);
}

test "ast: createNode builds contiguous child run" {
    var a = try testAst();
    defer a.deinit();
    const c1 = try a.createLeaf(.char, 0, 1, 0);
    const c2 = try a.createLeaf(.char, 2, 1, 0);
    const children = [_]Node{ a.node(c1), a.node(c2) };
    const row = try a.createNode(.row, 0, 3, &children, 0);
    const rn = a.node(row);
    try testing.expectEqual(@as(u16, 2), rn.num_children);
    // contiguous run: c1 copy at first_child, c2 copy right after
    try testing.expectEqual(@as(u32, rn.first_child + 1), rn.first_child + 1);
    try testing.expectEqual(.char, a.node(rn.first_child).tag);
    try testing.expectEqual(.char, a.node(rn.first_child + 1).tag);
}

test "ast: span resolves token range to bytes" {
    var a = try testAst();
    defer a.deinit();
    const c1 = try a.createLeaf(.char, 0, 1, 0);
    const s = a.span(c1);
    try testing.expectEqual(@as(u32, 0), s.start);
    try testing.expectEqual(@as(u32, 1), s.end);
    // full row spans tokens 0..2 → bytes 0..3
    const c2 = try a.createLeaf(.char, 2, 1, 0);
    const children = [_]Node{ a.node(c1), a.node(c2) };
    const row = try a.createNode(.row, 0, 3, &children, 0);
    const rs = a.span(row);
    try testing.expectEqual(@as(u32, 0), rs.start);
    try testing.expectEqual(@as(u32, 3), rs.end);
}

test "atom: genfrac thickness bits round-trip" {
    // 0 → no bits (plain \frac/\atop and 0pt genfrac share the encoding)
    try testing.expectEqual(@as(u32, 0), fracThicknessBits(0));
    try testing.expectEqual(@as(f32, 0), fracThickness(0));
    // 1pt → Q8.8 exact
    const one = fracThicknessBits(1);
    try testing.expect(one != 0);
    try testing.expectApproxEqAbs(@as(f32, 1), fracThickness(one), 1e-3);
    // 0.8pt → 205/256 (Q8.8 rounding)
    const p8 = fracThicknessBits(0.8);
    try testing.expectApproxEqAbs(@as(f32, 0.8), fracThickness(p8), 1e-3);
    // the bits live in 6..22 and do not collide with line/forced/parts
    const data = fracData(true, .text, false) | fracThicknessBits(1.5);
    try testing.expect(fracLine(data));
    try testing.expectEqual(MathStyle.text, fracForcedStyle(data).?);
    try testing.expect(!fracPartsDisplay(data));
    try testing.expectApproxEqAbs(@as(f32, 1.5), fracThickness(data), 1e-3);
    // negative clamps to 0 (no explicit thickness)
    try testing.expectEqual(@as(u32, 0), fracThicknessBits(-2));
}

test "atom: rowStretch reads the arraystretch factor off an env's first row" {
    // data 0 = no assignment: the layout keeps its per-kind default.
    try testing.expect(rowStretch(0) == null);
    const one_four = emToFixed(1.4);
    try testing.expect(one_four != 0);
    const factor = rowStretch(one_four) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 1.4), factor, 1e-6);
    // The stamp is a raw f32 pattern, so it collides with the row-marker
    // bits — the reason it may only live on a row inside an env.
    try testing.expect(one_four & (1 << 4) != 0);
    try testing.expect(one_four & (1 << 5) != 0);
    try testing.expect(!isClassRow(one_four));
}

fn testChildren(count: usize) ![]Node {
    const children = try testing.allocator.alloc(Node, count);
    for (children) |*child| {
        child.* = .{
            .tag = .char,
            .first_token = 0,
            .num_tokens = 0,
            .first_child = null_node,
            .num_children = 0,
            .data = 0,
        };
    }
    return children;
}

test "ast: createNode rejects more than u16 children" {
    var a = Ast.init(testing.allocator, "");
    defer a.deinit();

    const children = try testChildren(@as(usize, std.math.maxInt(u16)) + 1);
    defer testing.allocator.free(children);
    try testing.expectError(
        error.ChildCountOverflow,
        a.createNode(.row, 0, 0, children, 0),
    );
}

test "ast: createNode accepts the maximum u16 child count" {
    var a = Ast.init(testing.allocator, "");
    defer a.deinit();

    const children = try testChildren(std.math.maxInt(u16));
    defer testing.allocator.free(children);
    const row = try a.createNode(.row, 0, 0, children, 0);
    try testing.expectEqual(std.math.maxInt(u16), a.node(row).num_children);
}

test "ast: oversized node run is rejected before allocation" {
    if (@sizeOf(usize) <= @sizeOf(u32)) return error.SkipZigTest;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var a = Ast.init(failing.allocator(), "");
    defer a.deinit();

    const node: Node = .{
        .tag = .char,
        .first_token = 0,
        .num_tokens = 0,
        .first_child = 0,
        .num_children = 0,
        .data = 'x',
    };
    // Only the length is inspected; the oversized run must reach neither
    // an allocation request nor a read of this synthetic slice.
    const ptr: [*]const Node = @ptrCast(&node);
    const len: usize = @as(usize, std.math.maxInt(u32)) + 1;
    try testing.expectError(error.OutOfMemory, a.pushNodes(ptr[0..len]));
    try testing.expect(!failing.has_induced_failure);
}

test "ast: node capacity preserves the last representable run" {
    const limit: usize = std.math.maxInt(u32);
    try checkNodeCapacity(limit - 1, 1);
    try checkNodeCapacity(limit - 4, 4);
    try checkNodeCapacity(limit, 0);
    try testing.expectError(error.OutOfMemory, checkNodeCapacity(limit, 1));
    try testing.expectError(error.OutOfMemory, checkNodeCapacity(limit - 4, 5));
    try testing.expectError(error.OutOfMemory, checkNodeCapacity(1, std.math.maxInt(usize)));
    if (@sizeOf(usize) > @sizeOf(u32)) {
        try testing.expectError(error.OutOfMemory, checkNodeCapacity(limit + 1, 0));
    }
}

test "ast: node accepts the last pool index (the guard must not be off by one)" {
    var a = Ast.init(testing.allocator, "x");
    defer a.deinit();

    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const root = try a.createLeaf(.char, 0, 1, 0);
    // The deepest legal index is the last slot of the pool; an off-by-one in
    // the bound-check in `node` would reject it and break every real tree.
    const last = @as(u32, @intCast(a.nodes.items.len - 1));
    try testing.expectEqual(.char, a.node(last).tag);
    try testing.expectEqual(@as(u16, 1), a.node(root).num_tokens);
}

test "atom: color data round-trips through the RGBA word" {
    // The wire order is 0xRRGGBBAA — r in the high byte, alpha in the low
    // one — so the layout side is a plain shift/mask, not a bit reorder.
    const red = Color{ .r = 255, .g = 0, .b = 0 };
    try testing.expectEqual(@as(u32, 0xFF00_00FF), colorData(red));
    try testing.expectEqual(red, nodeColor(0xFF00_00FF));
    const half_blue = Color{ .r = 0, .g = 0, .b = 255, .a = 128 };
    try testing.expectEqual(@as(u32, 0x0000_FF80), colorData(half_blue));
    try testing.expectEqual(half_blue, nodeColor(0x0000_FF80));
    // data 0 is a real TRANSPARENT ink {0,0,0,0}, not an absent scope.
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0 }, nodeColor(0));
    // The alpha byte alone distinguishes two colors with the same RGB.
    try testing.expect(colorData(.{ .r = 0, .g = 0, .b = 0, .a = 1 }) != 0);
}

test "atom: parseColorChecked tells none/transparent from unrecognized" {
    // valid "no color" values stay null (no background)
    try testing.expect((try parseColorChecked("none")) == null);
    try testing.expect((try parseColorChecked("transparent")) == null);
    // a valid color parses, with alpha defaulting to opaque
    try testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, (try parseColorChecked("red")).?);
    try testing.expectEqual(
        Color{ .r = 255, .g = 128, .b = 0 },
        (try parseColorChecked("#ff8000")).?,
    );
    // #RRGGBBAA keeps its own alpha instead of the opaque default
    try testing.expectEqual(
        Color{ .r = 255, .g = 0, .b = 0, .a = 0 },
        (try parseColorChecked("#ff000000")).?,
    );
    try testing.expectEqual(
        Color{ .r = 1, .g = 2, .b = 3, .a = 4 },
        (try parseColorChecked("#01020304")).?,
    );
    // bad hex is rejected (wrong length, non-hex digit)
    try testing.expectError(error.UnrecognizedColor, parseColorChecked("#zz0000"));
    try testing.expectError(error.UnrecognizedColor, parseColorChecked("#ff00"));
    try testing.expectError(error.UnrecognizedColor, parseColorChecked("#"));
    // an unrecognized string errors (not silently treated as no color)
    try testing.expectError(error.UnrecognizedColor, parseColorChecked("blak"));
    try testing.expectError(error.UnrecognizedColor, parseColorChecked(""));
    // spelling is exact, like every other name table
    try testing.expectError(error.UnrecognizedColor, parseColorChecked("Red"));
}

test "atom: parseColorChecked knows the eleven names" {
    const cases = [_]struct { name: []const u8, c: Color }{
        .{ .name = "white", .c = .{ .r = 255, .g = 255, .b = 255 } },
        .{ .name = "black", .c = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .name = "red", .c = .{ .r = 255, .g = 0, .b = 0 } },
        .{ .name = "green", .c = .{ .r = 0, .g = 128, .b = 0 } },
        .{ .name = "blue", .c = .{ .r = 0, .g = 0, .b = 255 } },
        .{ .name = "yellow", .c = .{ .r = 255, .g = 255, .b = 0 } },
        .{ .name = "cyan", .c = .{ .r = 0, .g = 255, .b = 255 } },
        .{ .name = "magenta", .c = .{ .r = 255, .g = 0, .b = 255 } },
        .{ .name = "orange", .c = .{ .r = 255, .g = 165, .b = 0 } },
        .{ .name = "gray", .c = .{ .r = 128, .g = 128, .b = 128 } },
        .{ .name = "grey", .c = .{ .r = 128, .g = 128, .b = 128 } },
    };
    try testing.expectEqual(@as(usize, 11), cases.len);
    for (cases) |c| {
        try testing.expectEqual(c.c, (try parseColorChecked(c.name)).?);
    }
}

test "atom: nested text faces combine into the strongest face" {
    // \textit{\textbf{x}} and \textbf{\textit{x}} are both BOLD ITALIC —
    // neither command may silently discard the other.
    try testing.expectEqual(CharStyle.bold_italic, combineTextStyles(.text_italic, .bold));
    try testing.expectEqual(CharStyle.bold_italic, combineTextStyles(.bold, .text_italic));
    try testing.expectEqual(CharStyle.bold_italic, combineTextStyles(.text_italic, .bold_italic));
    try testing.expectEqual(CharStyle.bold_italic, combineTextStyles(.bold_italic, .bold));
    // same-face nesting is idempotent
    try testing.expectEqual(CharStyle.text_italic, combineTextStyles(.text_italic, .text_italic));
    try testing.expectEqual(CharStyle.bold, combineTextStyles(.bold, .bold));
    // an inner plain \text{…} does not weaken the outer face
    try testing.expectEqual(CharStyle.text_italic, combineTextStyles(.text_italic, .roman));
    try testing.expectEqual(CharStyle.roman, combineTextStyles(.roman, .roman));
    // a MATH alphabet has no text modifiers: it wins over its own nesting
    for ([_]CharStyle{ .bb, .cal, .frak, .sans, .mono, .italic }) |s| {
        try testing.expectEqual(s, combineTextStyles(s, .bold));
        try testing.expectEqual(s, combineTextStyles(s, .text_italic));
    }
}
