//! ztex.atom — superflat LaTeX atom (AST).
//!
//! One flat pool of fixed-size nodes; a node's children are a contiguous
//! index run. Duplication protocol: `createNode` re-appends copies of the
//! immediate children just before the parent, so a subtree appears in the
//! pool more than once and only the root-reachable chain is the tree.
//! Provenance is a parallel token table of byte spans.

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

    pub fn len(self: Span) usize {
        // Saturating: a hand-built span with end < start must not underflow
        // (panic in Debug/ReleaseSafe) — report 0 instead.
        return self.end -| self.start;
    }
};

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
};

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

pub inline fn envKind(data: u32) EnvKind {
    return @enumFromInt(data & EnvBits.kind_mask);
}

/// Number of array colspec nibbles packed in `data` (0 for non-array envs).
pub inline fn envSpecCount(data: u32) usize {
    return (data >> EnvBits.count_shift) & 0xF;
}

/// The packed colspec nibble for column `i`, or null beyond the packed
/// spec (callers default to centered alignment).
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
    /// [open?, row1, ..., rowN, close?] — the optional delimiter char
    /// leaves (only pmatrix/bmatrix/Bmatrix/vmatrix/Vmatrix/cases; each a
    /// char leaf whose `data` carries the delimiter codepoint, like \cdot)
    /// around the row atoms; each row is a `.row` node whose children are
    /// the cell atoms (a cell may be a .group/.row of its content; cells
    /// split on `&`, rows on `\\`). `data` = env kind (low 4 bits) plus the
    /// packed array colspec (see EnvBits).
    env,
};

/// A flat, fixed-size AST node.
pub const Node = struct {
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
    /// tag-specific scalar payload (style, width, line flag)
    data: u32,
};

/// Sentinel "no child / no node" index (0). Only a default for leaf nodes'
/// `first_child`; the authoritative no-children test is `num_children == 0`
/// (0 is a VALID node index, so never test `first_child == 0` for that).
const null_node: u32 = 0;

/// Encode a width-in-em for `space` node data: the f32 em value, stored as
/// its raw bits (not Q16.16 — the payload only ever holds table constants).
/// A bitcast round-trips losslessly; the previous Q16.16 conversion rounded
/// each constant to 1/65536 em and could overflow on hostile inputs.
pub inline fn emToFixed(em: f32) u32 {
    return @bitCast(em);
}

pub inline fn fixedToEm(v: u32) f32 {
    return @bitCast(v);
}

/// Errors returned by AST mutation operations.
pub const Error = std.mem.Allocator.Error || error{
    ChildCountOverflow,
};

/// The superflat AST: source + parallel token table + flat node pool.
///
/// Owns nothing beyond the two ArrayLists; the caller provides `gpa`. Free
/// with `deinit`. Node addresses are stable for the lifetime of the Ast (the
/// pool is append-only).
///
/// Ownership: `Ast` OWNS its two ArrayLists. Do NOT copy an `Ast` by value
/// (a copy would alias the same buffers and double-free on `deinit`); create
/// with `init` and free with `deinit` exactly once, on the original.
pub const Ast = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    tokens: std.ArrayList(Token) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    /// index of the root node (the whole formula), set by the parser
    root: u32 = 0,

    /// Create an empty Ast over `src`. The caller must pre-lex into `tokens`
    /// before parsing (see ztex.parse.lexer).
    pub fn init(gpa: std.mem.Allocator, src: []const u8) Ast {
        return .{ .gpa = gpa, .src = src };
    }

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

    pub fn pushNode(self: *Ast, n: Node) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, n);
        return idx;
    }

    pub fn pushNodes(self: *Ast, ns: []const Node) !u32 {
        const first: u32 = @intCast(self.nodes.items.len);
        try self.nodes.appendSlice(self.gpa, ns);
        return first;
    }

    /// Create a node with a contiguous child run: copies `children` into the
    /// pool, then appends the parent pointing at that run.
    pub fn createNode(
        self: *Ast,
        tag: Tag,
        first_token: u32,
        num_tokens: u32,
        children: []const Node,
        data: u32,
    ) Error!u32 {
        if (children.len > std.math.maxInt(u16)) return error.ChildCountOverflow;
        const first = try self.pushNodes(children);
        return self.pushNode(.{
            .tag = tag,
            .first_token = first_token,
            .num_tokens = num_tokens,
            .first_child = first,
            .num_children = @intCast(children.len),
            .data = data,
        });
    }

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
