//! ztex.layout — atom tree → superflat box tree (TeX layout).
//!
//! A pure function: (atom tree + FontMetrics + style) → box pool. Each box
//! carries its dimensions and the source byte span of the atom it came from,
//! preserving provenance end to end.
//!
//! This file is the recursive engine; its PUBLIC boundary is `render` in
//! ztex/layout/root.zig, which checks the whole atom tree once and then calls
//! `layout` below. Callers reach this file through that boundary, so the
//! preconditions documented on `layout` are established for them.

const std = @import("std");
const zg = @import("zg");
const atom = @import("ztex.atom");
const metrics = @import("metrics.zig");
const box = @import("box.zig");
const draw = @import("draw.zig");
const DisplayWidth = @import("DisplayWidth");
const Graphemes = @import("Graphemes");

/// TeX math style; drives script size, fraction gaps, and spacing.
/// Aliased to the atom's MathStyle so the parser can pack a forced style
/// into a `fraction` node's `data` or a `.mathstyle` node's `data`.
pub const Style = atom.MathStyle;

/// Layout failures: a call argument outside its documented domain
/// (`error.InvalidArgument` — the public boundary's size check), an
/// allocation, a malformed hand-built atom tree, and — since the stretchy
/// MATH forms resolve their horizontal geometry through a wired font —
/// whatever that resolution itself can fail with (`metrics.StretchError`: an
/// outline that will not decode, a table the face does not carry). Those
/// stay errors instead of decaying into the bundled static geometry;
/// `metrics.horizontalGlyph`'s errors propagate here.
pub const Error = error{ InvalidArgument, OutOfMemory, InvalidAst } || metrics.StretchError;

/// The `data` a \sqrt row node carries (set by the parser): children
/// [surd char (optionally wrapped in a script node holding the root index),
/// radicand]. layoutInner routes such rows through layoutSqrt — the
/// stretchy-radical construction — instead of the ordinary row path.
const sqrt_row_data: u32 = 1;

/// The `data` an accent row node carries (set by the parser): children
/// [base, accent-mark char]. layoutInner routes such rows through
/// layoutAccent — base + combining mark above — instead of the ordinary
/// row path.
const accent_row_data: u32 = 2;

/// \big-family ladder indexes. A `.left` node whose `data` is a level 1..4
/// (\big \Big \bigg \Bigg) carries a SINGLE delimiter child and no inner;
/// layoutLeftRight boxes the delimiter by this ladder entry at the base
/// font size. Measured XeTeX+unicode-math at 10/14/24/36pt: \big →
/// parenleft.v1 (ink 1.094em), \Big → .v4 (1.792em), \bigg → .v6 (2.392em),
/// \Bigg → .v7 (2.990em) — amsmath's \bBigg@ \vcenter height scales with
/// the current size, so the SAME variant is picked at every size. Index 0
/// unused.
const big_ladder_idx = [_]u8{ 0, 1, 4, 6, 7 };

/// Ink target (em) per \big level for delimiters WITHOUT a variant ladder
/// (| \| / \\ fall back to the continuous scaled-base glyph sized so its
/// ink reaches the target).
const big_target_ink = [_]f32{ 0, 1.094, 1.792, 2.392, 2.990 };

/// Ink targets (em) of amsmath's FIXED fraction-delimiter rule: a display
/// `\binom`/`\genfrac`-with-delims covers the style's standard fraction
/// box and the XeTeX/KaTeX/MathJax refs draw parenleft.v6 there, the
/// smaller styles the BASE paren — both rungs of the ladder above, read
/// from it instead of restated here.
const ams_delim_req_display_em: f32 = big_target_ink[3];
const ams_delim_req_small_em: f32 = big_target_ink[1];

/// Bit 21 of a \middle delimiter char leaf's `data` (the low 21 bits hold
/// the codepoint — delimiterCp/layoutChar read only those via @truncate).
/// Mirrors the parser's marker. layoutRow emits such leaves as zero-width
/// placeholder boxes; layoutLeftRight rewrites them in place with the
/// fence's required ink (applied to the delimiter's OWN variant ladder).
const middle_marker: u32 = 1 << 21;

/// The `data` a \not row node carries (set by the parser): children
/// [base]. layoutInner routes such rows through layoutNot — the base
/// relation with the U+0338 overlay slash — instead of the ordinary row
/// path.
const not_row_data: u32 = 3;

/// The `data` a \pmod row node carries (set by the parser): children ['(',
/// roman "mod" word, 6mu space, arg, ')']. layoutInner routes such rows
/// through layoutPmod — the 8mu leading \mkern (style-invariant: the
/// amsmath \if@display 18mu branch never fires inside \array cells,
/// measured on XeTeX) plus the fixed \mkern6mu mod-n gap — instead of the
/// ordinary row path.
const pmod_row_data: u32 = 4;

/// The `data` a \pod row node carries (set by the parser): children ['(',
/// arg, ')'] — the parenthesized argument without the "mod" word.
const pod_row_data: u32 = 5;

/// The `data` a \bmod row node carries (set by the parser): children [5mu
/// space, roman "mod" word, 5mu space]. layoutInner routes such rows
/// through layoutBmod — the pieces placed back to back with the two 5mu
/// kerns (amsmath's \bmod: the \mskip-\medmuskip\mkern5mu dance around the
/// \mathbin{mod} nets to 5mu each side) — instead of the ordinary row path.
const bmod_row_data: u32 = 6;

/// The `data` a \mod row node carries (set by the parser): children [roman
/// "mod" word, 6mu space, arg]. layoutInner routes such rows through
/// layoutMod — the 12mu leading \mkern (style-invariant: the amsmath
/// \if@display 18mu branch never fires inside \array cells, measured on
/// XeTeX) plus the fixed \mkern6mu mod-arg gap — instead of the ordinary
/// row path.
const mod_row_data: u32 = 7;

/// The `data` an \overset / \underset / \stackrel row node carries (set by the
/// parser): children [script, base]. layoutInner routes it through
/// layoutLimits — a \mathop with FORCED limits (amsmath's \overset) — instead
/// of the ordinary row path. The three markers share one geometry and differ
/// only in the class the row reports (see leftRole).
const overset_row_data: u32 = 8;
const underset_row_data: u32 = 9;
const stackrel_row_data: u32 = 10;

/// The `data` an \underbrace / \overbrace row node carries (set by the
/// parser): children [content] or [content, annotation]. layoutInner routes
/// it through layoutBrace — the brace band below/above the content plus the
/// optional forced-limit annotation — instead of the ordinary row path.
const underbrace_row_data: u32 = 11;
const overbrace_row_data: u32 = 12;

/// The `data` a \widehat / \widetilde row node carries (set by the parser):
/// children [base, accent-mark char] — the SAME shape as accent_row_data.
/// layoutInner routes them through layoutAccent with the EXTENSIBLE form
/// enabled: amsfonts.sty:79-86 (and amstex.sty:1931-1938) measure the
/// argument in \textstyle and use the narrow mark at or below 2em, a
/// leader-filled wide accent above it. Mirrors the parser's encoding.
const wide_hat_row_data: u32 = 14;
const wide_tilde_row_data: u32 = 15;

/// The `data` a \tag row node carries (set by the parser): children [the
/// braced argument in a `.styled` roman scope]. layoutInner routes it
/// through layoutTag. Bit 6 keeps it clear of the fixed markers 1..12, the
/// class row's 13, the phantom family's bit 4 and the kern family's bit 5.
/// Mirrors the parser's encoding.
const tag_row_data: u32 = 1 << 6;

/// Whether the accent's base is exactly ONE drawn character, which is the
/// only case the real combining mark is the right form for: TeX draws
/// `\widehat{M}` as the narrow glyph. A MULTI-character argument is spanned
/// by the extensible stroke however short it is — `\widehat{xy}` is about
/// 1em wide and still gets a hat, not one little mark parked in the middle.
/// amsfonts switched on an explicit width threshold
/// (`\ifdim\wd\z@>\tw@ em`); the SHAPE of the argument is the real
/// distinction, and two letters are already wider than the narrow glyph's
/// own ink. The test is structural — one `.char` box, possibly wrapped in
/// single-child hboxes — so it never reads the source spelling and never
/// allocates.
/// The trailing italic correction TeX's fin_mlist appends to EVERY math
/// list: the last character's MATH italic correction. The row already
/// appends it between adjacent char noads, but a group ENDING in a char
/// whose next atom is not a char (here: the accent mark itself) carries
/// only the bare advance — `\hat{AB}` must add B's 0.025em back before
/// halving. 0 for a base that is not a character row.
fn trailingGroupIc(
    list: *const box.BoxList,
    base: u32,
    fm: *const metrics.FontMetrics,
    size_pt: f32,
) f32 {
    var cur = base;
    while (true) {
        const b = list.get(cur);
        if (b.kind == .char) break;
        const ch = list.children(cur);
        if (b.kind != .hbox or ch.len == 0) return 0;
        cur = ch[ch.len - 1].idx;
    }
    const cd = list.charData(cur);
    // The box already carries the DRAWN codepoint in the base's own style,
    // so the correction is the same one layoutRow appends after this atom:
    // the font arm's base-point value scaled by s(), the static em value
    // scaled by the size directly (see charIc).
    if (metrics.fontItalicCorrection(fm, cd.cp, cd.style)) |ic| return s(ic, size_pt);
    return envIc(cd.cp) * size_pt;
}

fn baseIsSingleChar(list: *const box.BoxList, base: u32) bool {
    var cur = base;
    while (true) {
        const b = list.get(cur);
        if (b.kind == .char) return true;
        const ch = list.children(cur);
        if (b.kind != .hbox or ch.len != 1) return false;
        cur = ch[0].idx;
    }
}

/// amsmath's `\mintagsep` (amsmath.sty:1313), the gap between the equation
/// and its tag: `.5\fontdimen6\textfont\tw@` = half the text font's quad
/// (fontdimen6 of an OT1 text font IS the quad, 1em) = 0.5em.
/// amsmath.sty:2865 places it exactly there: `\unhcopy\z@\unskip\hfil\hskip
/// \mintagsep\copy4` — the formula, then flexible fill, then the gap, then
/// the tag. ztex has no display width, so this is "the right end of the
/// formula plus \mintagsep", not "the right margin of a text block".
const mintagsep_em: f32 = 0.5;

/// A class-override row (\mathord \mathrel \mathbin \mathopen \mathclose
/// \mathpunct \mathinner, and \colon) carries `atom.classRowData`: the low
/// four bits are the marker 13 and bits 8-10 the class. It deliberately has
/// NO layoutInner arm — the construct is a single-child row, so the
/// ordinary row path boxes it exactly as it boxes the bare field, and the
/// class reaches the glue only through leftRole/rightRole.
/// Bit 5 of an explicit-kern row's `data` marks the family (\hspace / \kern /
/// \mkern and `\:`'s constant mu skip); bits 0-1 carry the dimension's unit
/// and the magnitude rides in the row's single `.space` child (a space leaf's
/// f32 em payload). Mirrors the parser's encoding.
const kern_row_data: u32 = 1 << 5;
const dim_unit_mask: u32 = 3;

/// Dimension units of an explicit kern (see layoutKern for how each scales).
const dim_pt: u32 = 0;
const dim_em: u32 = 1;
const dim_ex: u32 = 2;
const dim_mu: u32 = 3;

/// Bit 4 of a \phantom-family row's `data` marks the family; the low bits are
/// the keep mask — which of the argument box's dimensions survive. \phantom
/// keeps all three, \vphantom the height and depth, \hphantom the width, and
/// \smash the width alone (amsmath's `\smash[<axes>]` zeroes ht and/or dp and
/// always keeps the advance, so its default `[tb]` IS \hphantom's geometry).
/// Mirrors the parser's encoding. Bit 4 ALONE routes the row to layoutPhantom:
/// the fixed markers 1..12 (bits 0-3) and the kern family's bit 5 never set it.
const phantom_row_data: u32 = 1 << 4;
const keep_width: u32 = 1;
const keep_height: u32 = 2;
const keep_depth: u32 = 4;

/// Bit 7 of a \phantom-family row's `data` marks `\smash` itself. The keep
/// mask alone cannot tell it from `\hphantom` — `\smash` with no axis
/// argument is exactly "keep the width" — and the two differ in what they
/// DRAW: the phantoms are latex.ltx's `\finph@nt`, an empty box that paints
/// nothing, while `\smash` is `\hbox to <width>{\vbox to 0pt{…}\vss}` and
/// still paints its content (XeTeX at 20pt: `\smash{b}` width 8.86, height
/// 0, depth 0, and the b is drawn). Set on every `\smash` form. Mirrors the
/// parser's `smash_row`.
const smash_row: u32 = 1 << 7;

/// Lay out the atom tree rooted at `idx` into the box pool and return that
/// root box's index.
///
/// This is the LOW-LEVEL entry. `layout.render` validates a tree once and
/// then calls it, and every datum this function reads out of `ast` — child
/// indices, token runs, the source spans they name, and each `data` that
/// decodes to an enum — is checked THERE and not here. Calling it directly
/// therefore carries a precondition: `ast` is a tree that passed that
/// validation (child counts against each tag's arity, in-bounds child
/// indices, a tree-shaped root-reachable subgraph, depth within
/// `atom.max_ast_depth`, token runs inside the token table, token spans
/// inside `ast.src`, in-range enum payloads, and `.hline` only as an `.env`
/// entry). A tree that breaks it reads out of bounds or panics in
/// `@enumFromInt`; it does not report an error.
///
/// `list` receives every box and must outlive the caller's use of the
/// returned index. `size_pt` is the current font size in POINTS and must be
/// finite and positive — nothing here checks it, which is why the public
/// boundary refuses a size that is not before it gets here. `current_style`
/// is the effective font style inherited from enclosing `styled` atoms
/// (default `.italic` math).
pub fn layout(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    current_style: atom.CharStyle,
) Error!u32 {
    return layoutInner(list, ast, idx, fm, style, size_pt, current_style, false);
}

/// Internal layout carrying the TeX "cramped" style bit (tex.web: odd math
/// styles). Cramped contexts (fraction denominators, subscripts) select sup3
/// for the superscript raise floor instead of sup1/sup2. The public layout()
/// entry always starts uncramped; the flag propagates through rows, groups,
/// styled atoms and nested fractions/scripts.
fn layoutInner(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    current_style: atom.CharStyle,
    cramped: bool,
) Error!u32 {
    const n = ast.node(idx);
    return switch (n.tag) {
        .char => layoutChar(list, ast, idx, fm, size_pt, current_style),
        .row => if (n.data == sqrt_row_data)
            layoutSqrt(list, ast, idx, fm, style, size_pt, current_style)
        else if (n.data == accent_row_data or n.data == wide_hat_row_data or
            n.data == wide_tilde_row_data)
            layoutAccent(
                list,
                ast,
                idx,
                fm,
                style,
                size_pt,
                current_style,
                cramped,
                n.data != accent_row_data,
            )
        else if (n.data == not_row_data)
            layoutNot(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else if (n.data == pmod_row_data or n.data == pod_row_data)
            layoutPmod(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else if (n.data == bmod_row_data)
            layoutBmod(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else if (n.data == mod_row_data)
            layoutMod(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else if (n.data == overset_row_data or n.data == underset_row_data or
            n.data == stackrel_row_data)
            layoutLimits(
                list,
                ast,
                idx,
                fm,
                style,
                size_pt,
                current_style,
                cramped,
                n.data == underset_row_data,
            )
        else if (n.data == underbrace_row_data or n.data == overbrace_row_data)
            layoutBrace(
                list,
                ast,
                idx,
                fm,
                style,
                size_pt,
                current_style,
                cramped,
                n.data == underbrace_row_data,
            )
        else if ((n.data & phantom_row_data) != 0)
            layoutPhantom(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else if ((n.data & kern_row_data) != 0)
            layoutKern(list, ast, idx, fm, style, size_pt)
            // \tag{n}: amsmath's equation number, axis-centred after the formula
            // and a \mintagsep gap (see layoutTag).
        else if (n.data == tag_row_data)
            layoutTag(list, ast, idx, fm, style, size_pt, current_style, cramped)
        else
            layoutRow(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .group => layoutInner(
            list,
            ast,
            ast.child(idx, 0),
            fm,
            style,
            size_pt,
            current_style,
            cramped,
        ),
        .styled => layoutInner(
            list,
            ast,
            ast.child(idx, 0),
            fm,
            style,
            size_pt,
            combineStyle(current_style, @fromBackingInt(@intCast(n.data))),
            cramped,
        ),
        // \color{red}… and \textcolor{red}{…}: a paint scope. The child
        // lays out EXACTLY as it would unscoped — same geometry, same math
        // class, same scripts — and the wrapper box only carries the color
        // (see layoutColorScope), so a colored relation keeps its glue and
        // nothing already flattened is rewritten.
        .color, .textcolor => layoutColorScope(
            list,
            ast,
            idx,
            fm,
            style,
            size_pt,
            current_style,
            cramped,
        ),
        // \boxed{x}: LaTeX's \fbox around \m@th$\displaystyle x$ (see
        // layoutBoxed).
        .boxed => layoutBoxed(list, ast, idx, fm, style, size_pt, current_style, cramped),
        // A \hline outside an environment is a parser error, so an .hline
        // node never reaches a list; layoutEnv consumes the real ones as
        // rule entries between its rows.
        .hline => unreachable,
        // A forced math style (\displaystyle \textstyle \scriptstyle
        // \scriptscriptstyle): the content lays out with the FORCED style
        // at the style-ratio-adjusted size (TeX: the style determines the
        // font size — \displaystyle in a script grows the content back to
        // cramped bit clears (forced styles are uncramped — the classic
        // escape from a denominator's cramped textstyle).
        .mathstyle => blk: {
            const ms: Style = @fromBackingInt(@intCast(n.data));
            const gl = metrics.glue(fm);
            break :blk layoutInner(
                list,
                ast,
                ast.child(idx, 0),
                fm,
                ms,
                size_pt * (styleScale(gl, ms) / styleScale(gl, style)),
                current_style,
                false,
            );
        },
        // An operator word: the letters row, always roman (like \mathrm).
        .opname => layoutInner(
            list,
            ast,
            ast.child(idx, 0),
            fm,
            style,
            size_pt,
            .roman,
            cramped,
        ),
        .left => layoutLeftRight(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .script => layoutScript(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .fraction => layoutFraction(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .space => layoutSpace(list, ast, idx, fm, style, size_pt),
        .text => layoutText(list, ast, idx, fm, size_pt, current_style),
        .op => layoutOp(list, ast, idx, style, size_pt),
        .overline => layoutOverUnder(list, ast, idx, fm, style, size_pt, current_style, cramped),
        .mathchoice => layoutMathChoice(list, ast, idx, fm, style, size_pt, current_style),
        // \substack: the script-size multi-line stack (children = the
        // lines). The lines are always \scriptstyle (uncramped), so no
        // cramped bit is needed.
        .substack => layoutSubstack(list, ast, idx, fm, style, size_pt, current_style),
        // \begin{env}...\end{env} (matrix family, cases, aligned, array).
        .env => layoutEnv(list, ast, idx, fm, style, size_pt, current_style, cramped),
    };
}

/// Unwrap transparent .group/.styled wrappers to the underlying atom. TeX
/// attaches scripts to the LAST noad of a braced mlist ({x}^2 ≡ x^2, {\int}^2
/// attaches to the ∫), while a braced LIST becomes a box; ztex's transparent
/// groups reproduce the single-noad case, so the unwrapped tag classifies a
/// base or script content as TeX would. A `\color` declaration is transparent
/// for the same reason (it wraps one atom and changes nothing else);
/// `\textcolor` is an ordinary group and stays a box.
fn unwrapAtom(ast: *const atom.Ast, idx: u32) u32 {
    var i = idx;
    while (true) {
        const n = ast.node(i);
        // A class-override row holds exactly ONE atom, so it is transparent
        // for TeX's single-noad purposes: `\mathrel{x}^2` places its scripts
        // from the x, exactly like `{x}^2`. The class is read from `data` by
        // leftRole/rightRole, never from the child.
        const class_row = n.tag == .row and atom.isClassRow(n.data) and n.num_children == 1;
        if (n.tag != .group and n.tag != .styled and n.tag != .mathstyle and
            n.tag != .color and !class_row) return i;
        if (n.num_children == 0) return i;
        i = ast.child(i, 0);
    }
}

/// The effective font style inside a `\mathbf`-style scope. A TEXT face
/// nested inside another text face COMBINES — `\textbf{\textit{x}}` is bold
/// italic, and the outer face is restored when the inner scope ends
/// (amsmath/LaTeX: the two modifiers accumulate). A text face inside MATH
/// takes its own, because the scope is what selects the face there: a bare
/// `\text{}` stays roman inside an italic formula, and `\mathbf{\mathbb R}`
/// stays double-struck (a math alphabet has no text modifiers at all).
fn combineStyle(outer: atom.CharStyle, inner: atom.CharStyle) atom.CharStyle {
    if (!metrics.isTextFace(outer) or !metrics.isTextFace(inner)) return inner;
    return atom.combineTextStyles(outer, inner);
}

/// Superscript/subscript FLOORS from the math-symbol font (family 2) at the
/// CURRENT style's size. With XeTeX+unicode-math these are the Latin-Modern-
/// Math MATH-table constants, read at the current size and scaled LINEARLY
/// (measured x^{y^2} at script size: sup raise 2.541pt = 3.63 × 0.7 — the
/// optically scaled cmsy7/cmsy5 values 4.311/4.036 are CM-only). So one
/// 10pt-base set serves every style; layout scales by size/10 via s().
const SymParams = struct {
    sup1: f32,
    sup2: f32,
    sup3: f32,
    sub1: f32,
    sub2: f32,
};

/// The values now come from `glue(fm)`, so the `.font` arm uses the ACTIVE
/// face's MATH SuperscriptShiftUp / SuperscriptShiftUpCramped /
/// SubscriptShiftDown (glue already folds them in) and the static arm keeps
/// its measured Latin Modern Math rows — same numbers, one source.
fn symFor(fm: *const metrics.FontMetrics) SymParams {
    const gl = metrics.glue(fm);
    return .{
        .sup1 = gl.sup1, // SuperscriptShiftUp
        .sup2 = gl.sup2, // SuperscriptShiftUp (no display/text distinction)
        .sup3 = gl.sup3, // SuperscriptShiftUpCramped
        .sub1 = gl.sub1, // SubscriptShiftDown
        .sub2 = gl.sub2, // SubscriptShiftDown (no separate "with superscript" const)
    };
}

/// TeX atom class for inter-atom spacing (tex.web math_spacing; MicroTeX
/// AtomType). Composite atoms report the class of their first/last child;
/// delimiter-less fractions are `ord` (tex.web: fraction_noad → ord_noad,
/// verified against XeTeX), scripted atoms are `ord` (MicroTeX ScriptsAtom);
/// `inner` is reserved for \left..\right constructs (not yet modeled).
const Role = enum(u8) {
    ord,
    op,
    bin,
    rel,
    open,
    close,
    punct,
    inner,
};

/// Inter-atom glue table, the exact TeX rule (tex.web §799, the 64-digit
/// math_spacing string "0234..." — verified empirically against XeTeX
/// \showbox). Indexed [left role][right role]; each entry packs 4 nibbles:
/// display, text, script, scriptscript glue units (0 none, 1 thin, 2 med,
/// 3 thick).
///
/// Digits decode to nibbles: '1' = conditional thin (display/text only),
/// '2' = thin in ALL styles, '3'/'4' = med/thick (display/text only), '*' =
/// impossible (bin is demoted before it fires). So med/thick AND the
/// conditional thins (ord→inner, punct→*, close→inner, inner→ord, …) are
/// SUPPRESSED in script/scriptscript styles — measured: the subscript `i=1`
/// has NO glue, while `a∑` in a script keeps thin (1.3657pt at 7pt, using the
/// script symbol font's quad). Only ord↔op and close→op keep thin in scripts.
const glue_table = blk: {
    const rows = [_][8]u16{
        .{ 0x0000, 0x1111, 0x2200, 0x3300, 0x0000, 0x0000, 0x0000, 0x1100 }, // ord
        .{ 0x1111, 0x1111, 0x0000, 0x3300, 0x0000, 0x0000, 0x0000, 0x1100 }, // op
        .{ 0x2200, 0x2200, 0x0000, 0x0000, 0x2200, 0x0000, 0x0000, 0x2200 }, // bin
        .{ 0x3300, 0x3300, 0x0000, 0x0000, 0x3300, 0x0000, 0x0000, 0x3300 }, // rel
        .{ 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000 }, // open
        .{ 0x0000, 0x1111, 0x2200, 0x3300, 0x0000, 0x0000, 0x0000, 0x1100 }, // close
        .{ 0x1100, 0x1100, 0x0000, 0x1100, 0x1100, 0x1100, 0x1100, 0x1100 }, // punct
        .{ 0x1100, 0x1111, 0x2200, 0x3300, 0x1100, 0x0000, 0x1100, 0x1100 }, // inner
    };
    var t: [8][8][4]u8 = undefined;
    for (rows, 0..) |row, l| {
        for (row, 0..) |v, r| {
            t[l][r] = .{
                @intCast((v >> 12) & 0xF), // display
                @intCast((v >> 8) & 0xF), // text
                @intCast((v >> 4) & 0xF), // script
                @intCast(v & 0xF), // scriptscript
            };
        }
    }
    break :blk t;
};

/// TeX class of a raw codepoint, matching MicroTeX's symbol types
/// (tex_symbols.res.cpp: bin = + - ± × ÷ · ∗ ∘ ∙ ∩ ∪ ∧ ∨ ⊕ ⊖ ⊗ ⊘ ⊙ ∖ ≀ ⊎
/// ⊓ ⊔ ⋆ ◇ ⋁ ⋀ † ‡ ◃ ▹ ○ ⨿ etc, rel = = < > : ≤ ≥ ≠ ≡ ≺ ≻ ⊆ ⊇ ∈ ∉ ∋ →
/// rel adds: arrows, ∝ ∣ ∥ ⊥ ⊢ ⊨ ≪ ≫ ⊑ ⊒ ⋈ etc,
/// open/close = ( [ { ⟨ ⌈ ⌊ / ) ] }, punct = , ;, big-op codepoints = op).
fn roleOfCp(cp: u21) Role {
    // Comptime LUT for ASCII codepoints (< 128)
    const ascii_roles = comptime blk: {
        var lut: [128]Role = @splat(.ord);
        const bin = [_]u21{ 0x2B, 0x2D };
        const rel = [_]u21{ 0x3D, 0x3C, 0x3E, 0x3A };
        const open = [_]u21{ 0x28, 0x5B, 0x7B };
        const close = [_]u21{ 0x29, 0x5D, 0x7D };
        const punct = [_]u21{ 0x2C, 0x3B };
        for (bin) |c| lut[c] = .bin;
        for (rel) |c| lut[c] = .rel;
        for (open) |c| lut[c] = .open;
        for (close) |c| lut[c] = .close;
        for (punct) |c| lut[c] = .punct;
        break :blk lut;
    };
    if (cp < 128) return ascii_roles[cp];

    return switch (cp) {
        0x2212, 0x2213, 0x00B1, 0x00D7, 0x00F7 => .bin,
        0x22C5, 0x2217, 0x2218, 0x2219 => .bin,
        0x2229, 0x222A, 0x2227, 0x2228 => .bin,
        0x2295, 0x2296, 0x2297, 0x2298, 0x2299 => .bin,
        0x22C2, 0x22C3 => .bin,
        0x2020, 0x2021 => .bin,
        0x2216, 0x2240, 0x228E, 0x2293, 0x2294 => .bin,
        0x22C4, 0x22C6, 0x25B9, 0x25C3, 0x25CB, 0x2A3F, 0x00B7 => .bin,

        0x2260, 0x2261, 0x2262 => .rel,
        0x2264, 0x2265, 0x2266, 0x2267 => .rel,
        0x2243, 0x2244, 0x2245, 0x2246, 0x2247, 0x2248, 0x2249, 0x223C, 0x2241 => .rel,
        0x2282, 0x2283, 0x2284, 0x2285, 0x2286, 0x2287, 0x2288, 0x2289 => .rel,
        0x2208, 0x2209, 0x220B, 0x220C => .rel,
        0x227A, 0x227B, 0x2280, 0x2281 => .rel,
        0x226D, 0x226E, 0x226F, 0x2270, 0x2271, 0x22E0, 0x22E1, 0x22AC => .rel,
        0x2190, 0x2192, 0x2194 => .rel,
        0x21D0, 0x21D2, 0x21D4 => .rel,
        0x2A7D, 0x2A7E => .rel,
        0x2191, 0x2193, 0x2195, 0x2196, 0x2197, 0x2198, 0x2199 => .rel,
        0x21A6, 0x21A9, 0x21AA => .rel,
        0x21BC, 0x21BD, 0x21C0, 0x21C1 => .rel,
        0x21D1, 0x21D3, 0x21D5 => .rel,
        0x221D, 0x2223, 0x2224, 0x2225, 0x2226 => .rel,
        0x2234, 0x2235 => .rel,
        0x224D, 0x2250 => .rel,
        0x226A, 0x226B => .rel,
        0x2291, 0x2292 => .rel,
        0x22A2, 0x22A3, 0x22A5, 0x22A8 => .rel,
        0x22C8, 0x2322, 0x2323 => .rel,
        0x27F5, 0x27F6, 0x27F7, 0x27F8, 0x27F9, 0x27FA => .rel,
        0x2AAF, 0x2AB0 => .rel,

        // The colon family: RATIO ∶, PROPORTION ∷ (\Colon), COLON EQUALS ⋔
        // (\coloneqq) and EQUALS COLON ⋕ (\coloneq) — all relations in both
        // references (unicode-math's symbol table classes every one of them
        // \mathrel; mathtools builds \coloneqq/\Coloneqq as \mathrel). A
        // bare `:` stays a relation here; `\colon` never reaches roleOfCp as
        // a bare char — the parser wraps it in a forced-class row.
        0x2236, 0x2237, 0x2254, 0x2255 => .rel,
        0x27E8, 0x2308, 0x230A => .open,
        0x27E9, 0x2309, 0x230B => .close,

        0x2211, 0x220F, 0x222B, 0x2210, 0x222E, 0x2A06, 0x22C0, 0x22C1, 0x2A00, 0x2A01, 0x2A02, 0x2A04, 0x2A05 => .op,

        else => .ord,
    };
}

/// The layout mirror of `atom.MathClass`: the same eight TeX classes, so a
/// parser-recorded override (`\mathrel{...}`, `\colon`) enters the glue
/// table on its own row. Written as an explicit switch so a class added to
/// one enum but not the other fails to compile here.
fn roleOfClass(cls: atom.MathClass) Role {
    return switch (cls) {
        .ord => .ord,
        .op => .op,
        .bin => .bin,
        .rel => .rel,
        .open => .open,
        .close => .close,
        .punct => .punct,
        .inner => .inner,
    };
}

/// First codepoint of the atom's source span (0 for empty spans). A char
/// atom whose `data` carries an explicit codepoint override (parser \cdot)
/// reports that instead of the source bytes.
fn nodeCp(ast: *const atom.Ast, idx: u32) u21 {
    const n = ast.node(idx);
    if (n.data != 0) return @truncate(n.data);
    const sp = ast.span(idx);
    return firstCodepoint(ast.src[sp.start..sp.end]);
}

/// Left class of an atom: composite atoms report their first child.
/// A scripted big operator keeps the op class (TeX: an op_noad with
/// scripts is still an op), so inter-atom glue around \sum_{...} is
/// computed with the op role (thin before/after, not ord's none).
fn leftRole(ast: *const atom.Ast, idx: u32) Role {
    const n = ast.node(idx);
    return switch (n.tag) {
        // A \middle delimiter is TeX's "middle" atom; measured XeTeX of
        // `\left\{ x \middle| \frac{x}{2} \in S \right\}` shows NO glue
        // around the | — class close gives exactly that (ord→close and
        // close→ord are both 0, like the reference).
        .char => if (n.data & middle_marker != 0) .close else roleOfCp(nodeCp(ast, idx)),
        .op => .op,
        // A delimiter-less \over/\atop fraction is an ORD noad in TeX
        // (tex.web §14981: fraction_noad falls through to t := ord_noad),
        // measured: `{x\over n} x` has NO glue, `{x\over n} + y` gets med.
        // Only \left..\right constructs are inner.
        .fraction => .ord,
        .group, .styled, .mathstyle, .row => blk: {
            if (n.num_children == 0) break :blk .ord;
            // A forced class (\mathord \mathrel \mathbin \mathopen
            // \mathclose \mathpunct \mathinner, and \colon) is the atom's
            // class on BOTH sides of its content — the wrapped atom's own
            // role is discarded, which is the whole point: `a\mathrel{-}b`
            // spaces like `a-b` with the relation glue, and `\mathord{+}`
            // loses the binary's med spaces.
            if (n.tag == .row and atom.isClassRow(n.data)) {
                break :blk roleOfClass(atom.classRowClass(n.data));
            }
            // \tag is amsmath's equation number, hoisted OUT of the math
            // list (it is built as a separate box beside the display), so
            // it is a noad in no list and takes no inter-atom glue on
            // either side. `.open` is the one class whose whole glue ROW
            // and whose whole COLUMN are zero in the TeX table, so it
            // suppresses the glue against every neighbour class.
            if (n.tag == .row and n.data == tag_row_data) break :blk .open;
            // \mod: the style-dependent leading \mkern is NOT a noad — the
            // construct's first atom is the ord "mod" group (amsmath:
            // \mod#1{\allowbreak \if@display\mkern18mu\else\mkern12mu\fi
            // {\operator@font mod}\,\,#1}), so the preceding atom gets NO
            // glue (unlike the opname word's op role).
            if (n.tag == .row and n.data == mod_row_data) break :blk .ord;
            // \stackrel IS a \mathrel (measured: the thick 5mu of a rel on
            // both sides), while amsmath's \overset / \underset expand to an
            // EMPTY \mathrel before the construct — an atom with no class, so
            // the row itself is ord (measured: `x\overset{a}{b}` carries no
            // inter-atom glue at all).
            if (n.tag == .row and n.data == stackrel_row_data) break :blk .rel;
            // \underbrace / \overbrace are \mathop atoms: no glue before, a
            // thin space after (measured: `x\underbrace{ab}y` = 3mu).
            if (n.tag == .row and (n.data == underbrace_row_data or
                n.data == overbrace_row_data)) break :blk .op;
            break :blk leftRole(ast, ast.child(idx, 0));
        },
        // Operator words are TeX \mathop atoms — role OP — so the inter-atom
        // glue around them is the op spacing: \sin x gets a thin space
        // (op→ord thin, matching XeTeX: sin and x separated by 3/18 em).
        .opname => .op,
        // \left..\right is an inner atom: thin glue to ord/punct neighbors.
        // A \big/\Big/\bigg/\Bigg node (data = level 1..4) is amsmath's
        // \bBigg@ \box — a BOX atom, class ORD (XeTeX \showbox of `\Big[ x
        // \Big]` has NO glue around the brackets; measured). Only the real
        // \left..\right fences are inner.
        .left => if (n.data != 0) .ord else .inner,
        // \overline/\underline is an ord noad in TeX (over_noad/under_noad
        // are ordinary), so the inter-atom glue around it is ord spacing.
        .overline => .ord,
        // \mathchoice resolves to its chosen branch at layout time (the
        // branch's own atoms enter the list, per TeX math_choice); ztex
        // classifies the node ord, like a fraction/overline box. Branch
        // contents are normally ord (fractions, letters); exotic bin/rel
        // branches lose their glue — documented simplification.
        .mathchoice => .ord,
        // \substack is a box (amsmath \subarray = \vcenter of an \ialign):
        // class ORD, like any box atom.
        .substack => .ord,
        // A \begin{env} with delimiters (pmatrix ... cases) is amsmath's
        // \left...\right fence — class INNER (thin glue to ord/punct).
        // Delimiter-less envs (matrix, aligned, array) are \vcenter boxes —
        // class ORD (measured XeTeX: no glue around a bare matrix).
        .env => if (envHasDelims(ast, idx)) .inner else .ord,
        // A scripted base keeps the base's class: a scripted big operator OR
        // operator word (\sum_{...}, \sin^2 x, \lim_{x\to0}) is still an op.
        .script => if (n.num_children > 0) blk: {
            const base = unwrapAtom(ast, ast.child(idx, 0));
            const bt = ast.node(base).tag;
            break :blk if (bt == .op or bt == .opname) .op else .ord;
        } else .ord,
        .text, .space => .ord,
        // \boxed is a \fbox around a formula: a box atom, class ORD.
        .boxed => .ord,
        // A \hline leaf is consumed by layoutEnv as a rule between rows; the
        // parser rejects it anywhere else, so no list ever classifies one.
        .hline => .ord,
        // \color is a DECLARATION, not a group (xcolor: it changes the
        // colour and nothing else), so the wrapped atom keeps its own class
        // and its glue: `a\color{red}=b` spaces like `a=b` (measured
        // 46.11pt at 20pt). \textcolor takes an argument, and xcolor
        // typesets it inside an ordinary group, so the content is an ORD and
        // a colored relation loses its rel glue (measured:
        // `a\textcolor{red}{=}b` 35.0pt at 20pt = `a\mathord{=}b`).
        .color => if (n.num_children == 0) .ord else leftRole(ast, ast.child(idx, 0)),
        .textcolor => .ord,
    };
}

/// Right class of an atom: composite atoms report their last child.
fn rightRole(ast: *const atom.Ast, idx: u32) Role {
    const n = ast.node(idx);
    return switch (n.tag) {
        .char => if (n.data & middle_marker != 0) .close else roleOfCp(nodeCp(ast, idx)),
        .op => .op,
        .fraction => .ord,
        .group, .styled, .mathstyle, .row => blk: {
            if (n.num_children == 0) break :blk .ord;
            // A forced class reports itself on both sides (see leftRole).
            if (n.tag == .row and atom.isClassRow(n.data)) {
                break :blk roleOfClass(atom.classRowClass(n.data));
            }
            // \tag takes no glue on either side (see leftRole).
            if (n.tag == .row and n.data == tag_row_data) break :blk .open;
            // \stackrel is a \mathrel and \underbrace / \overbrace are
            // \mathop atoms (see leftRole).
            if (n.tag == .row and n.data == stackrel_row_data) break :blk .rel;
            if (n.tag == .row and (n.data == underbrace_row_data or
                n.data == overbrace_row_data)) break :blk .op;
            break :blk rightRole(ast, ast.child(idx, n.num_children - 1));
        },
        // Operator words are \mathop atoms: OP role (see leftRole).
        .opname => .op,
        // \left..\right is an inner atom (thin glue to ord/punct); a
        // \big-family node (data = level) is a \box — class ORD (measured
        // XeTeX: no glue around \Big[ x \Big]).
        .left => if (n.data != 0) .ord else .inner,
        // \overline/\underline is an ord noad (see leftRole).
        .overline => .ord,
        // \mathchoice is an ord atom (see leftRole).
        .mathchoice => .ord,
        // \substack is a box (see leftRole).
        .substack => .ord,
        // \begin{env}: inner when it has delimiters, ord otherwise (see
        // leftRole).
        .env => if (envHasDelims(ast, idx)) .inner else .ord,
        .script => if (n.num_children > 0) blk: {
            const base = unwrapAtom(ast, ast.child(idx, 0));
            const bt = ast.node(base).tag;
            break :blk if (bt == .op or bt == .opname) .op else .ord;
        } else .ord,
        .text, .space => .ord,
        // \boxed is a \fbox around a formula: a box atom, class ORD. A
        // \hline leaf is consumed by layoutEnv (see leftRole).
        .boxed => .ord,
        .hline => .ord,
        // \color is a declaration, \textcolor an ordinary group (see
        // leftRole for the measured widths).
        .color => if (n.num_children == 0) .ord else rightRole(ast, ast.child(idx, n.num_children - 1)),
        .textcolor => .ord,
    };
}

/// Glue units → em fractions: thin 3/18, med 4/18, thick 5/18 (MicroTeX
/// glue.cpp _glueTypes); index 0 (no space) yields 0.
const glue_em: [4]f32 = .{ 0, 3, 4, 5 };

/// Mu-unit quad (in em) of the symbol font (family 2) at the current style.
/// TeX computes 1mu = quad/18 from \scriptfont2 etc. (tex.web §13864).
/// With XeTeX+unicode-math the Latin-Modern-Math quad is 1em at EVERY size
/// (measured: script-size \, = 3/18 × 6.9738 = 1.162pt and \; = 5/18 ×
/// 6.9738 = 1.937pt on x^{1\,1}/x^{1\;1} — the old cmsy7 quad 1.170641em
/// (1.3657pt thin) is a Computer-Modern value that does not apply to LM).
inline fn quadEm(_: Style) f32 {
    return 1.0;
}

/// Glue units (0-3) between two adjacent atoms in the current style.
fn glueUnits(l: Role, r: Role, style: Style) u8 {
    const i: usize = @backingInt(l);
    const j: usize = @backingInt(r);
    return glue_table[i][j][@backingInt(style)];
}

/// Scale a 10pt-base metric to the current size.
inline fn s(v: f32, size_pt: f32) f32 {
    return v * (size_pt / 10.0);
}

/// Size scale of a math style relative to the text size (TeX: D/T use the
/// text font, S the script font, SS the scriptscript font). A forced-style
/// wrapper/fraction rescales its content by target/current — \scriptstyle
/// in display shrinks to script size, \displaystyle in a script grows back
/// to the text size (root-relative sizing, the same ladder layoutScript
/// uses). A plain atom keeps target == current, ratio 1.0, so existing
/// output is untouched.
inline fn styleScale(gl: metrics.GlueParams, st: Style) f32 {
    return switch (st) {
        .display, .text => 1.0,
        .script => gl.scriptfactor,
        .script_script => gl.scriptscriptfactor,
    };
}

/// Decode the first codepoint of `bytes` with zg's DFA decoder (ASCII fast
/// path; no view/iterator setup). Empty or malformed UTF-8 yields 0: zg
/// substitutes U+FFFD (len 1) for a malformed sequence, which is folded back
/// to 0, while a genuine U+FFFD (EF BF BD) decodes with len 3 and is kept.
inline fn firstCodepoint(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0;
    if (bytes[0] < 0x80) return bytes[0];
    var cursor: zg.code_point.uoffset = 0;
    const d = zg.code_point.decodeAtCursor(bytes, &cursor) orelse return 0;
    return if (d.code == 0xfffd and d.len == 1) 0 else d.code;
}

/// Map a codepoint to its math-italic form via the Unicode Math
/// Alphanumeric Symbols block (U+1D400–U+1D7FF): each style series is a
/// CONTIGUOUS RUN, so the mapping is arithmetic — a handful of range
/// checks + offsets, NOT a per-character table. Series for math-italic:
///
///   Latin capital A–Z (U+0041..005A) → U+1D434..U+1D44D (off = cp − 'A')
///   Latin small a–z   (U+0061..007A) → U+1D44E..U+1D467 (off = cp − 'a')
///   Greek small α–ω   (U+03B1..03C9) → U+1D6FC..U+1D714 (off = cp − U+03B1)
///   Greek variants    (U+03F5 ϵ, U+03D1 ϑ, U+03F1 ϱ, U+03D5 ϕ, U+03D6 ϖ)
///                      → their Unicode compat slots U+1D716/U+1D717/
///                        U+1D71A/U+1D719/U+1D71B (all in LM Math's cmap,
///                        verified with fontTools; the font-cmap validation
///                        in the callers keeps the base cp if one is not)
///   ∂ U+2202 → U+1D715 (math-italic partial, the Math Alphanumeric Symbols
///                      slot): the XeTeX+unicode-math reference emits
///                      U+1D715 for \partial — measured `\frac{\partial
///                      L}{\partial \dot{q}}` ref render (u1D715 glyph,
///                      advance 0.531em vs the upright 0.586em — a DIFFERENT
///                      glyph). Systematic companion to the letter mapping:
///                      math style renders the math-italic form, roman
///                      (\mathrm{\partial}) keeps U+2202.
///
/// Notes:
///  · U+1D455 (math-italic h) is UNASSIGNED in Unicode and absent from LM
///    Math; the math-italic h is U+210E ℎ (Planck constant) — exactly what
///    XeTeX+unicode-math emits for `$h$` (verified).
///  · ς U+03C2 (final sigma) sits INSIDE the α–ω run, so the series covers
///    it (→ U+1D70D).
///  · Greek CAPITALS are deliberately NOT mapped: unicode-math's TeX-style
///    math keeps uppercase Greek upright — the XeTeX+unicode-math reference
///    emits `\Gamma` → U+0393 (probe-verified), so `\Gamma(x)` stays
///    upright. The U+1D6E2..U+1D6FA series (off = cp − U+0391) belongs to
///    a future \varGamma/\mathit-capitals path.
///
/// Only `.italic` (default math variables) maps: roman (\text, \mathrm,
/// \sin) and bold stay upright ASCII — the callers gate on style.
inline fn mathItalic(cp: u21) ?u21 {
    if (cp >= 0x41 and cp <= 0x5A) return cp - 0x41 + 0x1D434;
    if (cp >= 0x61 and cp <= 0x7A) return if (cp == 0x68) 0x210E else cp - 0x61 + 0x1D44E;
    if (cp >= 0x3B1 and cp <= 0x3C9) return cp - 0x3B1 + 0x1D6FC;
    return switch (cp) {
        0x3F5 => 0x1D716, // ϵ lunate epsilon → math-italic epsilon symbol
        0x3D1 => 0x1D717, // ϑ theta symbol
        0x3F1 => 0x1D71A, // ϱ rho symbol
        0x3D5 => 0x1D719, // ϕ phi symbol
        0x3D6 => 0x1D71B, // ϖ pi symbol
        0x2202 => 0x1D715, // ∂ → math-italic partial (unicode-math emits U+1D715)
        else => null,
    };
}

/// Blackboard (`\mathbb`) codepoint of a char, or null when it has none.
/// Maps:
///  · A–Z → U+1D538.. (math double-struck capitals);
///  · a–z → U+1D552.. (math double-struck smalls);
///  · 0–9 → U+1D7D8.. (math double-struck digits — \mathbb{1} → 𝟙 U+1D7D9);
///  · C/H/N/P/Q/R/Z → the Letterlike double-struck ℂ U+2102, ℍ U+210D,
///    ℕ U+2115, ℙ U+2119, ℚ U+211A, ℝ U+211D, ℤ U+2124 (unicode-math maps
///    these to the Letterlike codepoints, NOT the U+1D538 series — the
///    U+1D53B/1D53D/1D540..1D544/1D546/1D54A slots are unused gaps in the
///    math-double-struck run).
/// Callers gate on `.bb`; other styles never reach here.
inline fn mathBb(cp: u21) ?u21 {
    if (cp >= 0x41 and cp <= 0x5A) {
        return switch (cp) {
            0x43 => 0x2102, // C → ℂ
            0x48 => 0x210D, // H → ℍ
            0x4E => 0x2115, // N → ℕ
            0x50 => 0x2119, // P → ℙ
            0x51 => 0x211A, // Q → ℚ
            0x52 => 0x211D, // R → ℝ
            0x5A => 0x2124, // Z → ℤ
            else => cp - 0x41 + 0x1D538,
        };
    }
    if (cp >= 0x61 and cp <= 0x7A) return cp - 0x61 + 0x1D552;
    if (cp >= 0x30 and cp <= 0x39) return cp - 0x30 + 0x1D7D8;
    return null;
}

/// Mathematical Calligraphic / Script mapping (\mathcal):
///  · Latin letters A–Z → U+1D49C.. (Mathematical Script Capital)
///  · Exceptions with reserved legacy codepoints:
///    B → U+212C, E → U+2130, F → U+2131, H → U+210B, I → U+2110, L → U+2112,
///    M → U+2133, R → U+211B, e → U+212F, g → U+210A, o → U+2134.
inline fn mathCal(cp: u21) ?u21 {
    if (cp >= 0x41 and cp <= 0x5A) {
        return switch (cp) {
            0x42 => 0x212C, // B → ℬ
            0x45 => 0x2130, // E → ℰ
            0x46 => 0x2131, // F → ℱ
            0x48 => 0x210B, // H → ℋ
            0x49 => 0x2110, // I → ℐ
            0x4C => 0x2112, // L → ℒ
            0x4D => 0x2133, // M → ℳ
            0x52 => 0x211B, // R → ℛ
            else => cp - 0x41 + 0x1D49C,
        };
    }
    if (cp >= 0x61 and cp <= 0x7A) {
        return switch (cp) {
            0x65 => 0x212F, // e → ℯ
            0x67 => 0x210A, // g → ℊ
            0x6F => 0x2134, // o → ℴ
            else => cp - 0x61 + 0x1D4B6,
        };
    }
    return null;
}

/// Mathematical Fraktur mapping (\mathfrak):
///  · Latin letters A–Z → U+1D504..
///  · Exceptions: C → U+212D, H → U+210C, I → U+2111, R → U+211C, Z → U+2128
inline fn mathFrak(cp: u21) ?u21 {
    if (cp >= 0x41 and cp <= 0x5A) {
        return switch (cp) {
            0x43 => 0x212D, // C → ℭ
            0x48 => 0x210C, // H → ℌ
            0x49 => 0x2111, // I → ℑ
            0x52 => 0x211C, // R → ℜ
            0x5A => 0x2128, // Z → ℨ
            else => cp - 0x41 + 0x1D504,
        };
    }
    if (cp >= 0x61 and cp <= 0x7A) return cp - 0x61 + 0x1D51E;
    return null;
}

inline fn mathPlainAlphabet(
    cp: u21,
    comptime upper: u21,
    comptime lower: u21,
    comptime digit: u21,
) ?u21 {
    if (cp >= 'A' and cp <= 'Z') return upper + cp - 'A';
    if (cp >= 'a' and cp <= 'z') return lower + cp - 'a';
    if (cp >= '0' and cp <= '9') return digit + cp - '0';
    return null;
}

fn layoutChar(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    // A nonzero `data` overrides the codepoint (parser \cdot → U+22C5); the
    // glyph then has no matching source bytes, so it must be marked
    // synthetic for flatten to dupe instead of aliasing "\cdot".
    const cp: u21 = if (n.data != 0) @truncate(n.data) else firstCodepoint(ast.src[span.start..span.end]);
    // Math-italic letters/Greek map to their U+1D4xx/U+1D6xx codepoints
    // (series arithmetic, see mathItalic) so the box carries the TRUE
    // math-italic form — the LM Math advance and the slanted drawn glyph —
    // instead of the upright letter (unicode-math reference: `$x$` →
    // U+1D465, `\alpha` → U+1D6FC). The mapped cp is validated against the
    // ACTIVE metric source before emitting: a wired font's cmap (font
    // first, so a font without the math-italic glyph keeps the base), or
    // the static table when no font is wired (it covers the U+1D4xx Latin
    // series but not the U+1D6xx Greek series — those fall back to the
    // base cp gracefully). A mapped box is marked synthetic (its utf-8 no
    // longer equals the source bytes) so flatten dupes it into the arena.
    var mcp: u21 = cp;
    // `-` is TeX's \mathbin{-}: unicode-math maps the math hyphen to the
    // FULL-WIDTH MINUS SIGN U+2212 (the XeTeX reference emits U+2212 for
    // `-x^2` and `-\infty`). The raw U+002D hyphen-minus in LM Math is a
    // SHORT hyphen (ink 0.245em tall, 0.265em wide vs the minus 0.666em
    // wide) — the "your - sign is too short" defect. The box then takes
    // the U+2212 advance (7.78pt at 10pt vs 3.33pt) and the drawn glyph.
    // \text runs bypass layoutChar (layoutText reads the source directly),
    // so `\text{a-b}` keeps the text hyphen, exactly like XeTeX.
    if (cp == 0x2D) mcp = 0x2212;
    // `:` is TeX's math RATIO: unicode-math draws the MATH colon U+2236,
    // whose dots sit higher and closer than the text colon's. Both `a:b`
    // and `a\colon b` arrive here as 0x3A; `\text{a:b}` bypasses
    // layoutChar, so the text colon is untouched. The class still comes
    // from the source codepoint, so `:` stays a relation.
    if (cp == 0x3A) mcp = 0x2236;
    if (cstyle == .italic) {
        if (mathItalic(cp)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) mcp = m;
        }
    } else if (cstyle == .bb) {
        // \mathbb: map to the double-struck glyph (letters/digits → the
        // U+1D5xx/U+1D7Dx math-double-struck codepoints, C/H/N/P/Q/R/Z →
        // the Letterlike ℂ/ℍ/ℕ/ℙ/ℚ/ℝ/ℤ). Without this, \mathbb{R} drew a
        // plain R and \mathbb{1} a plain 1 — not the double-struck ℝ/𝟙.
        if (mathBb(cp)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) mcp = m;
        }
    } else if (cstyle == .cal) {
        if (mathCal(cp)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) mcp = m;
        }
    } else if (cstyle == .frak) {
        if (mathFrak(cp)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) mcp = m;
        }
    } else if (cstyle == .sans) {
        if (mathPlainAlphabet(cp, 0x1D5A0, 0x1D5BA, 0x1D7E2)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) mcp = m;
        }
    } else if (cstyle == .mono) {
        if (mathPlainAlphabet(cp, 0x1D670, 0x1D68A, 0x1D7F6)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) mcp = m;
        }
    }
    // Size-aware lookup: script/scriptscript sizes use the real optically
    // scaled cmr7/cmmi7/cmsy7 (resp. cmr5/...) metrics (values in the same
    // 10pt-base convention, so the s() scaling below lands on true points);
    // any other size uses the 10pt table (linear scaling). When the mapped
    // cp has no metric (a font without the math-italic glyphs), fall back
    // to the ASCII letter's entry — the static table keeps the U+0078 etc.
    // rows, so the no-font path still works.
    const g = metrics.glyphAt(fm, mcp, cstyle, size_pt) orelse
        metrics.glyphAt(fm, cp, cstyle, size_pt) orelse
        metrics.glyphEstimate(fm, cp, cstyle);
    // Box height/depth by the DRAWN ink (em × drawn size), not the
    // cmr10/cmmi10 metric h/d: the metric box describes the Computer-Modern
    // design while the ink is what the SVG draws, and it pokes past the
    // metric box (∫ sup '1' 9.32pt of ink in a 9.02pt box at 14pt) —
    // clipping the frame. `glyphInkAt` answers with the ACTIVE FACE's own
    // real ink for a text face (a bold or italic letter is a different,
    // taller design, and boxing it by the upright Latin-Modern-Math ink
    // clips it) and by the LM Math rows for every math face. Width stays the
    // metric advance.
    const ink = metrics.glyphInkAt(mcp, cstyle);
    const box_idx = try list.create(
        .char,
        s(g.width, size_pt),
        ink.asc * size_pt,
        ink.desc * size_pt,
        &.{},
        mcp,
        cstyle,
        size_pt,
        span,
    );
    if (n.data != 0 or mcp != cp) list.charDataPtr(box_idx).synthetic = true;
    setCharOverhang(list, box_idx, ink, size_pt);
    return box_idx;
}

/// Record a drawn glyph's horizontal ink overhang, in points, on its own
/// `CharData`; draw.zig unions it into the ink bounds, so an italic `f`, a
/// `\not` overlay or a combining mark is framed by what it really paints
/// instead of by its advance box alone. One assignment per producer — the
/// overhang comes from the same `glyphInk`/`glyphInkAt` lookup that boxed the
/// glyph, never a second one.
///
/// `GlyphInk.left` is how far the ink reaches left of the origin and
/// `GlyphInk.right_edge` where it ends, both in em of the drawn size. The
/// right overhang is what is left past THIS box's own advance, so it is
/// measured against the box: a static table's optical advance (the LMRoman17
/// bands, the text faces' own hmtx) can be narrower than the advance the ink
/// was recorded against, and an overhang carried over from the wider advance
/// would under-frame the ink it has to enclose.
fn setCharOverhang(list: *box.BoxList, idx: u32, ink: metrics.GlyphInk, size_pt: f32) void {
    const cd = list.charDataPtr(idx);
    cd.ink_left = ink.left * size_pt;
    cd.ink_right = @max(0.0, ink.right_edge * size_pt - list.get(idx).width);
}

/// \dot \hat \bar \vec \ddot \tilde (a row marked `accent_row_data`;
/// children [base, accent-mark char]): lays out the base normally, then
/// draws the combining mark as a separate char box AT THE BASE SIZE on the
/// SAME baseline as the base, centred over it. The narrow mark is ZERO-WIDTH
/// (the LM Math hmtx advance of every combining mark is 0, measured with
/// fontTools) — it never widens the box, exactly TeX's zero-width accents.
/// The mark's ink pokes above the base box, so the result box HEIGHT grows
/// to bound it (TeX: an accent noad's height is max(base, accent)); width
/// and depth stay the base's.
///
/// Horizontal placement facts (measured on latinmodern-math.otf 2.005 and
/// both reference engines at 10–60pt):
///   · each engine lands the MARK's own MATH-table TopAccentAttachment on
///     the BASE's MathTopAccentAttachment. Measured `\hat{x}` at 20pt: the
///     mark origin sits at base 0.329em minus mark −0.264em = 0.593em. The
///     mark's attachment is NOT its ink centre: a combining mark has a zero
///     advance with its whole ink left of the origin, so `ink_metrics`
///     clamps `right_edge` to 0 and the ink centre lands 0.041em left of
///     the attachment for U+0302.
///   · that attachment belongs to a SINGLE-character base (`\hat{x}`,
///     `\dot{q}`, and `\hat{=}`, whose group is one glyph). A multi-character
///     argument has no one skew to inherit, so its mark is placed by the
///     same rule against the argument's TeX width INCLUDING the trailing
///     italic correction TeX's fin_mlist appends: `\hat{AB}` lands at
///     (0.750 + 0.759 + 0.025) / 2 − mark attachment. A base with no MATH
///     attachment (`=`, `+`) falls back to half its advance box. The old
///     ink-centre rule put every mark left of all of these.
///   · the mark ORIGIN follows from that target, by the mark's own datum. A
///     rung that is the bare COMBINING glyph takes the mark's MATH
///     TopAccentAttachment (origin = target − mark attachment): a zero-advance
///     mark has its whole ink left of the origin, so its ink centre is the
///     wrong datum. A SIZE VARIANT is not that glyph — it is a full-advance
///     drawing whose ink is centred on the advance, so origin = target −
///     variant ink centre. Subtracting the combining attachment from a
///     variant parks every wide \widetilde/\widehat 0.264em + advance/2 to
///     the right of where both engines draw it.
///   · every mark's ink floats above the baseline (0.554–0.749em up for
///     U+0302), and each engine places `\dot{q}`'s dot at the BASE baseline
///     (measured: every glyph, mark included, sits on y = 7.427), so the mark
///     baseline is NOT raised — the font's own ink does that.
///
/// Extensible accents select the largest horizontal MATH variant that FITS
/// the nucleus, or the first rung when even that is wider. A request past
/// the ladder's last rung keeps that top rung UNSTRETCHED and centred —
/// both reference engines draw the 1.916em tilde over `abcd` through
/// `abcdefghij` alike, never a stretched stroke. One-character bases use
/// the same width rule and keep their accent attachment.
fn layoutAccent(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
    extensible: bool,
) !u32 {
    const span = ast.span(idx);
    const base = try layoutInner(list, ast, ast.child(idx, 0), fm, style, size_pt, cstyle, cramped);
    const bb = list.get(base);

    const accent_size = size_pt;
    const mark_atom = ast.node(ast.child(idx, 1));
    const mark_cp: u21 = @truncate(mark_atom.data);

    // The base's drawn glyph: the LAST char box inside the base. A braced
    // base ({q}, the common case) is a group → row hbox whose cp is 0, so
    // the MATH attachment must come from its inner char (TeX places the
    // accent over the box with the last character's skew — the XeTeX MATH
    // attachment of the same glyph; a plain atom base is already the char).
    // Descend only through rows (hbox), never into vboxes/scripts (accents
    // over those already fall back to centring — the tall-base limitation).
    var attach_cp: u21 = 0;
    var char_x: f32 = 0;
    {
        var cur = base;
        var xoff: f32 = 0;
        while (true) {
            const b = list.get(cur);
            if (b.kind == .char) {
                attach_cp = list.charData(cur).cp;
                char_x = xoff;
                break;
            }
            const ch = list.children(cur);
            if (b.kind != .hbox or ch.len == 0) break;
            const last = ch[ch.len - 1];
            xoff += last.x_shift;
            cur = last.idx;
        }
    }
    // The base's own top-accent attachment comes from the DRAWN glyph: the
    // `.font` arm's MATH TopAccentAttachment when the face records one, the
    // measured `accentAttach` row otherwise (the static fallback). Only a
    // SINGLE-character base places by it; a multi-character argument has no
    // one skew to inherit.
    const attach = if (attach_cp != 0)
        (metrics.fontTopAccentAttachment(fm, attach_cp, cstyle) orelse
            metrics.accentAttach(attach_cp))
    else
        null;
    const single = baseIsSingleChar(list, base);

    // The mark's OWN top-accent attachment: where it wants the base's
    // attachment to land, and the datum for the ladder's ZERO-ADVANCE rung.
    // A combining mark has a zero advance with its whole ink left of the
    // origin, so the ink centre is NOT the attachment — for U+0302 the ink
    // centre is 0.223em left of the origin while the MATH value is 0.264em,
    // and ink-centring lands every accent 0.041em left of both reference
    // engines. A full-advance SIZE VARIANT is not that glyph at all — it is
    // placed by its own ink centre (mark_centre below). The font arm reads
    // the real value; the static row carries the same measured marks.
    const mark_attach = metrics.fontTopAccentAttachment(fm, mark_cp, .italic) orelse
        metrics.accentAttach(mark_cp) orelse
        0;
    // The argument's TeX width INCLUDES the trailing italic correction
    // TeX's fin_mlist appends to every math list — `\hat{AB}` centres on
    // 0.750 + 0.759 + 0.025, not on the bare row advance.
    const tex_w = bb.width + trailingGroupIc(list, base, fm, size_pt);
    // The horizontal REQUEST: the base's own width, in em of the accent size.
    // A non-zero request also rides the mark box out to the back ends, so the
    // SVG and the rasterizer resolve the SAME variant this layout boxed.
    const req_em = bb.width / accent_size;

    // Only wide accents select a horizontal variant. A plain hat or tilde
    // keeps its base glyph even when its argument is a wide character.
    const native: ?metrics.StretchGeometry = blk: {
        if (!extensible) break :blk null;
        break :blk switch (mark_cp) {
            0x0302, 0x0303 => try metrics.horizontalGlyph(fm, mark_cp, req_em),
            else => null,
        };
    };

    // The DRAWN form: the resolved variant, or the base combining glyph when
    // the face declares no horizontal construction for this codepoint. A
    // request past the ladder's last rung keeps that top rung UNSTRETCHED:
    // both reference engines draw the 1.916em tilde centred over `abcd`
    // through `abcdefghij` alike, never a stretched stroke.
    const geom = native orelse metrics.StretchGeometry{
        .advance_em = 0,
        .ink = metrics.glyphInk(mark_cp),
    };
    const ink = geom.ink;
    // Where the drawn form's INK must land, measured back from its ORIGIN.
    // A zero-advance rung is the bare COMBINING glyph and keeps the mark's
    // MATH attachment. Every SIZE VARIANT reserves a full advance and centres
    // its ink on it, so the base's attachment has to meet the VARIANT's ink
    // centre: `\widetilde{xy}` at 20pt draws the 0.931em rung with its ink at
    // 0.466em, not at −0.264em, and subtracting the combining attachment
    // there parked the whole tilde 0.73em right of the reference. The test is
    // the ADVANCE, not `native != null`: a narrow argument that resolves to
    // the base rung keeps mark_attach.
    const mark_centre: f32 = if (geom.advance_em > 0)
        (geom.ink.right_edge - geom.ink.left) / 2
    else
        mark_attach;

    // Where the mark's datum must land. Both engines put the mark's own
    // TopAccentAttachment on the base's, or — for a drawn size variant — the
    // variant's ink centre: origin = base target − mark datum. A single base
    // with a MATH attachment places by it; a base with none (`=`, `+`) falls
    // back to half its advance box; a group places by the same rule against
    // its TeX width INCLUDING the trailing italic correction TeX appends to
    // the math list.
    const base_target = if (single and attach != null)
        char_x + attach.? * accent_size
    else if (single)
        bb.width / 2
    else
        tex_w / 2;
    const x = base_target - mark_centre * accent_size;

    // Vertical: the mark sits on the base's baseline UNLESS the base's ink
    // is taller than AccentBaseHeight (LM Math MATH-table: 0.45em), when
    // the mark is RAISED so its ink bottom clears the base's ink top — the
    // XeTeX+unicode-math rule (measured \hat{H} at 36pt: hat ink bottom
    // 0.819em = H ink top 0.683em + (0.587 natural bottom − 0.45)em; a
    // 13-base probe: clearance 0.1368em constant for every tall base,
    // natural position for short ones; \dot{q} — q ink top 0.442em — stays
    // unraised, exactly as before). Without the raise the \hat{H} hat ink
    // (bottom 0.587em) overlapped the H ink (top 0.683em) — the merge.
    //
    // The height the raise clears is the BASE BOX's own ink top — the tallest
    // glyph the argument really contains, not just the character the mark is
    // attached to. `\widehat{abc}` ends on a short c but carries a tall b, and
    // raising only to c's 0.442em left the mark straight through the b.
    const accent_base_height = metrics.accentBaseHeightEm(fm) * accent_size;
    const raise = @max(0.0, bb.height - accent_base_height);

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = base, .x_shift = 0, .shift = 0 });
    // ONE native mark over the argument: the resolved horizontal variant, or
    // the base combining glyph when the face declares no construction. Never
    // a run of repeated marks (a sawtooth row of little hats, not an accent)
    // and never a parametric stroke: a request past the ladder's last rung
    // keeps that top rung UNSTRETCHED, exactly what both engines draw.
    const accent_height: f32 = raise + ink.asc * accent_size;
    // A native variant carries the request; the base glyph, with no
    // horizontal construction of its own, carries none.
    const mark = try accentMarkBox(
        list,
        mark_cp,
        geom,
        if (native != null) req_em else 0,
        accent_size,
        span,
    );
    try list.scratch.append(list.gpa, .{ .idx = mark, .x_shift = x, .shift = -raise });
    // Width/depth stay the base's (the accent never widens it); the height
    // grows to bound the raised mark's ink above the row baseline.
    return list.create(
        .hbox,
        bb.width,
        @max(bb.height, accent_height),
        bb.depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// One combining-mark box of an accent: a `.char` at the base size drawing
/// `geom`'s form — the resolved horizontal size variant, or the base glyph
/// when the face declares no horizontal construction for this codepoint — in
/// the MATH font family (.italic) so the rasterizer and the browser pick the
/// LM Math face that carries the marks. The mark's utf-8 is the combining
/// codepoint, which never equals the command's source bytes, so the box is
/// synthetic and flatten dupes it into the arena.
///
/// The box is the ADVANCE the form reserves and is bounded by the form's OWN
/// ink, never the base codepoint's: `setCharOverhang` reads `geom.ink`, the
/// same outline the resolver returned, so the frame encloses the variant that
/// is really painted. That matters most at the ladder's base rung, a
/// zero-advance glyph whose whole 0.446em ink hangs LEFT of the origin — a
/// frame from the advance box alone would shave all of it off. `req_em`
/// carries the request that chose the form out to the back ends (0 when the
/// drawn form is the base glyph itself and has no construction to resolve).
fn accentMarkBox(
    list: *box.BoxList,
    mark_cp: u21,
    geom: metrics.StretchGeometry,
    req_em: f32,
    accent_size: f32,
    span: atom.Span,
) !u32 {
    const box_idx = try list.create(
        .char,
        geom.advance_em * accent_size,
        geom.ink.asc * accent_size,
        geom.ink.desc * accent_size,
        &.{},
        mark_cp,
        .italic,
        accent_size,
        span,
    );
    const cd = list.charDataPtr(box_idx);
    cd.synthetic = true;
    cd.horizontal_req = req_em;
    setCharOverhang(list, box_idx, geom.ink, accent_size);
    return box_idx;
}

/// \tag{n} (a row marked `tag_row_data`; children [the braced argument in a
/// `.styled` roman scope]): amsmath's equation number. Plain amsmath renders
/// it as `(n)` — `\maketag@@@{(#1)}` builds `\hbox{\m@th\normalfont(#1)}`
/// (amsmath.sty:1210-1211), so the PARENTHESES ARE PART OF THE TAG, drawn
/// upright beside the number. The number itself is laid out at the current
/// style and size — the child carries the roman scope, so the digits draw
/// exactly as \operatorname's letters do, in the NORMAL TEXT font.
///
/// The parentheses are synthesized here: the parser never sees them, and the
/// tag's source bytes are `\tag{3}` rather than a parenthesis, so both carry
/// the tag's WHOLE span and are marked synthetic — flatten dupes the glyph
/// instead of aliasing command bytes.
///
/// Placement: the tag is NOT a noad in the formula's list (amsmath builds it
/// beside the display), so it carries no inter-atom glue — leftRole and
/// rightRole report it as the one class whose whole glue row and column are
/// zero. It follows the formula after amsmath's `\mintagsep`
/// (amsmath.sty:2865: `\unhcopy\z@\unskip\hfil\hskip\mintagsep\copy4`), which
/// here is part of the tag box's own advance rather than a separate glue
/// box, so nothing is emitted between the formula and the tag. Vertically
/// the WHOLE `(n)` box — parentheses included, which are the tallest part —
/// is AXIS-CENTRED with the operator/delimiter rule `(h − d)/2 − axis` (y-down:
/// a positive shift drops the children), and the shifted extents become the
/// result box's h/d so the row absorbs them.
///
/// Documented simplification: ztex has no display width, so the tag lands at
/// the right end of the FORMULA plus \mintagsep, not at the right margin of
/// a text block, and it sits wherever in the formula it was written.
fn layoutTag(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const span = ast.span(idx);
    const child = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
    );
    const cb = list.get(child);
    const axis = s(metrics.glue(fm).axis_height, size_pt);
    const gap = mintagsep_em * size_pt;
    // amsmath's own parentheses (see the doc comment).
    const paren_l = try tagParen(list, fm, '(', size_pt, span);
    const paren_r = try tagParen(list, fm, ')', size_pt, span);
    const pl = list.get(paren_l);
    const pr = list.get(paren_r);
    const w = pl.width + cb.width + pr.width;
    const h = @max(pl.height, cb.height);
    const d = @max(pl.depth, cb.depth);
    const shift = (h - d) / 2 - axis;
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = paren_l, .x_shift = gap, .shift = shift });
    try list.scratch.append(list.gpa, .{ .idx = child, .x_shift = gap + pl.width, .shift = shift });
    try list.scratch.append(list.gpa, .{
        .idx = paren_r,
        .x_shift = gap + pl.width + cb.width,
        .shift = shift,
    });
    return list.create(
        .hbox,
        gap + w,
        h - shift,
        d + shift,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// One of the parentheses amsmath's `\tag` puts around its number: a roman
/// `(` / `)` at the tag's own size, boxed by the drawn ink and marked
/// SYNTHETIC with the tag's whole span — the source bytes there are the
/// `\tag{…}` command, not a parenthesis, so flatten must dupe the glyph
/// rather than alias them.
fn tagParen(
    list: *box.BoxList,
    fm: *const metrics.FontMetrics,
    cp: u21,
    size_pt: f32,
    span: atom.Span,
) !u32 {
    const g = metrics.glyphAt(fm, cp, .roman, size_pt) orelse
        metrics.glyphEstimate(fm, cp, .roman);
    // The paren is drawn in the ROMAN face, so its ink edges come from that
    // face (`glyphInkAt`), never from the math face it happens to share a
    // codepoint with. Numerically inert today — neither face's `(` / `)` ink
    // reaches past the advance it is boxed by — but it is the face the glyph
    // is painted from.
    const ink = metrics.glyphInkAt(cp, .roman);
    const b = try list.create(
        .char,
        s(g.width, size_pt),
        ink.asc * size_pt,
        ink.desc * size_pt,
        &.{},
        cp,
        .roman,
        size_pt,
        span,
    );
    list.charDataPtr(b).synthetic = true;
    setCharOverhang(list, b, ink, size_pt);
    return b;
}

/// \not<relation> (a row marked `not_row_data`; children [base]): lays the
/// base relation out normally, then overlays the U+0338 COMBINING LONG
/// SOLIDUS OVERLAY — the same glyph XeTeX+unicode-math draws for \not's
/// overlay fallback (\notaccent) — as a zero-width char box at the base
/// size, positioned exactly like XeTeX's \mathaccentoverlay placement
/// (xetex.web make_math_accent, measured on 20 XeTeX overlay renders at
/// 10pt/24.88pt):
///
///   Horizontal: XeTeX anchors the slash to the FIRST character inside the
///   base box (the accent's placement uses the base's MATH-table top-accent
///   attachment, or half the character's advance when it has none) and
///   lands the slash's own attachment (U+0338: −0.263em — its ink center)
///   on that anchor, so the slash origin sits (anchor + 0.264) × size right
///   of the base origin. Measured (all within 0.001em): \not y origin
///   +0.567em (attachment 0.304), \not\smile +0.763em (half 0.5em),
///   \not\bowtie +0.574em (0.311 → half 0.311), \not\top +0.652em (half
///   0.389), \not{ab} +0.550em (FIRST char a's attachment 0.287),
///   \not{xy} +0.592em (x's attachment 0.329), \not{\le x} +0.652em (half
///   of ≤'s advance 0.389), \not{\nabla x} +0.679em (half 0.4165).
///   Vertical: the vlist [slash, kern −δ, base] with δ = min(base_height,
///   AccentBaseHeight 0.45em) puts the slash's ink BOTTOM at max(0,
///   h − 0.45em) above the baseline; with the slash's own ink desc 0.25em
///   that raises the slash baseline by max(0.25em, h − 0.20em), where h is
///   the FIRST character's height (measured: smile/frown/y/q 0.250, bowtie
///   0.305, cup 0.404, top 0.464, nabla 0.483, \not\perp 0.484, {ab}/{xy}
///   0.250 via a/x, {\nabla x} 0.483 — every one within 0.009em). Bases
///   with no char inside (fractions, scripts) fall back to the base box's
///   half-width and height.
///   The slash box is ZERO-WIDTH (LM Math hmtx advance of combining marks
///   is 0) and synthetic (its utf-8 ≠ the "\not" source bytes), so flatten
///   dupes it into the arena like the accent marks. Result box: width and
///   depth stay the base's (the slash never pokes below the baseline —
///   raise ≥ 0.25em); the height grows to bound the slash's ink above.
fn layoutNot(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const span = ast.span(idx);
    const base = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
    );
    const bb = list.get(base);

    // The slash: U+0338, drawn at the base size, zero advance, boxed by
    // its drawn LM Math ink (asc 0.75em / desc 0.25em, measured with
    // fontTools: ink x[−0.458, −0.069], y[−0.25, +0.75] — a diagonal
    // across the em box, angle ≈ 68.7° from horizontal, which is exactly
    // the slash XeTeX draws for \not's overlay fallback).
    const ink = metrics.glyphInk(0x0338);
    const slash = try list.create(
        .char,
        0, // combining marks are zero-advance in LM Math
        ink.asc * size_pt,
        ink.desc * size_pt,
        &.{},
        0x0338,
        .italic, // the MATH font carries the combining overlay
        size_pt,
        span,
    );
    // The slash's utf-8 (U+0338) does not match the source span ("\not"),
    // so flatten must dupe it into the arena instead of aliasing.
    list.charDataPtr(slash).synthetic = true;
    setCharOverhang(list, slash, ink, size_pt);

    // XeTeX anchors the overlay to the FIRST character of the base box
    // (measured above). Descend hboxes to that char, accumulating the
    // horizontal offset; the char's attachment (or half its advance) and
    // its box height drive the placement. A bare char base is found at
    // depth 0; a braced group {≤ x} anchors on the ≤. Bases without a char
    // (fractions, scripts, empty groups) fall back to the whole box.
    var attach_cp: u21 = 0;
    var char_x: f32 = 0;
    var char_w: f32 = 0;
    var char_h: f32 = 0;
    {
        var cur = base;
        var xoff: f32 = 0;
        while (true) {
            const b = list.get(cur);
            if (b.kind == .char) {
                attach_cp = list.charData(cur).cp;
                char_x = xoff;
                char_w = b.width;
                char_h = b.height;
                break;
            }
            const ch = list.children(cur);
            if (b.kind != .hbox or ch.len == 0) break;
            const first = ch[0];
            xoff += first.x_shift;
            cur = first.idx;
        }
    }
    const anchor_w = if (attach_cp != 0) char_w else bb.width;
    const anchor_h = if (attach_cp != 0) char_h else bb.height;
    const attach = if (attach_cp != 0) metrics.accentAttach(attach_cp) else null;
    const x = if (attach) |a|
        char_x + (a + 0.264) * size_pt
    else
        char_x + anchor_w / 2 + 0.264 * size_pt;

    // Vertical: raise the slash baseline by max(axis, h − (AccentBaseHeight
    // − axis)), where the axis is the slash's ink desc (= the LM Math axis
    // height, 0.25em) and AccentBaseHeight = 0.45em — XeTeX's overlay
    // vlist [accent, kern −min(h, 0.45em), base], measured above. Both
    // fractions enter as 10pt-base metrics routed through gl.axis_height
    // (2.5pt / 4.5−2.5 = 2.0pt), scaled by s() like every other em
    // parameter in this file.
    const gl = metrics.glue(fm);
    const axis = s(gl.axis_height, size_pt);
    const raise = @max(axis, anchor_h - s(4.5 - gl.axis_height, size_pt));

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = base, .x_shift = 0, .shift = 0 });
    try list.scratch.append(list.gpa, .{ .idx = slash, .x_shift = x, .shift = -raise });
    // Width/depth stay the base's (the slash's ink bottom is at or above
    // the baseline — raise ≥ 0.25em); the height grows to bound the
    // slash's ink above the row baseline.
    return list.create(
        .hbox,
        bb.width,
        @max(bb.height, raise + ink.asc * size_pt),
        bb.depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// \overline{x} / \underline{x} (a `.overline` atom; data = 0 over / 1
/// under): lay out the content, then draw a rule of thickness rt =
/// rule_thickness (TeX's default_rule_thickness) at a clearance of 3·rt
/// from the content's box edge, spanning exactly the content width. This
/// is tex.web's overbar/make_over and make_under verbatim:
///
///   \overline: vlist [kern rt, rule rt, kern 3·rt, content] → box height
///     grows by 5·rt (rt of air above the rule), depth unchanged; the
///     rule's bottom edge sits at height(content) + 3·rt. The content is
///     laid out CRAMPED (make_over's cramped_style), squeezing scripts.
///   \underline: vlist [content, kern 3·rt, rule rt] → box depth grows by
///     4·rt, height unchanged; the rule's top edge sits at
///     depth(content) + 3·rt below the baseline. The content keeps the
///     current (uncramped) style (make_under's clean_box at cur_style).
///
/// Measured against the XeTeX reference (unicode-math, 36pt): the rule is
/// 0.04em thick and its inner edge sits 0.120em = 3·0.04em from the
/// content ink (LM Math hmtx height/depth == the drawn ink, so the
/// ink-based boxes place the rule exactly like TeX's font-metric boxes).
fn layoutOverUnder(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const under = n.data != 0;
    const gl = metrics.glue(fm);
    const rt = s(gl.rule_thickness, size_pt);
    // \overline lays its content out CRAMPED (tex.web make_over:
    // cramped_style(cur_style)); \underline keeps the current style
    // (make_under: clean_box at cur_style).
    const content_cramped = if (under) cramped else true;
    const content = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        style,
        size_pt,
        cstyle,
        content_cramped,
    );
    const cb = list.get(content);

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = content, .x_shift = 0, .shift = 0 });
    if (under) {
        // Rule centered at depth + 3·rt + rt/2 BELOW the baseline (its own
        // height = depth = rt/2 spans [depth + 3·rt, depth + 4·rt]); the
        // box depth grows by 4·rt, the height stays the content's.
        const rule = try list.createLeaf(.rule, cb.width, rt / 2, rt / 2, span);
        try list.scratch.append(list.gpa, .{ .idx = rule, .x_shift = 0, .shift = cb.depth + 3 * rt + rt / 2 });
        return list.create(
            .hbox,
            cb.width,
            cb.height,
            cb.depth + 4 * rt,
            list.scratch.items[saved_len..],
            0,
            cstyle,
            0,
            span,
        );
    }
    // Rule centered at height + 3·rt + rt/2 ABOVE the baseline (spans
    // [height + 3·rt, height + 4·rt]); the box height grows by 5·rt — the
    // extra rt is TeX's leading kern, so the rule is NOT at the box top.
    const rule = try list.createLeaf(.rule, cb.width, rt / 2, rt / 2, span);
    try list.scratch.append(list.gpa, .{ .idx = rule, .x_shift = 0, .shift = -(cb.height + 3 * rt + rt / 2) });
    return list.create(
        .hbox,
        cb.width,
        cb.height + 5 * rt,
        cb.depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// Whether an atom is a TeX CHARACTER noad for the italic-correction rule:
/// a char leaf, or a script node whose base is a char (`x^2` is still one
/// math_char noad — XeTeX inserts the preceding char's italic correction
/// before it). Groups/rows/fractions are subformula BOXES in TeX
/// (math_type sub_box), which get no preceding IC (tex.web math_trans),
/// so they do not qualify.
fn isCharNoad(ast: *const atom.Ast, idx: u32) bool {
    const n = ast.node(idx);
    return switch (n.tag) {
        .char => true,
        .script => n.num_children > 0 and ast.node(ast.child(idx, 0)).tag == .char,
        else => false,
    };
}

/// Whether a char leaf is a TeX DELIMITER codepoint (( ) [ ] { } ⟨ ⟩
/// ⌈ ⌉ ⌊ ⌋ ∣ | ‖ /) — via the same MATH size-variant ladder the layout uses
/// for \left..\right and \big (metrics.delimVariants). Delimiters are NOT
/// math_char noads, so the inter-character italic-correction kern must not
/// fire for them (a `(` followed by `m` gets no IC — TeX math_trans only
/// corrects genuine character atoms).
fn isDelimiterNode(ast: *const atom.Ast, idx: u32, n: atom.Node) bool {
    if (n.tag != .char) return false;
    const sp = ast.span(idx);
    const cp: u21 = if (n.data != 0) @truncate(n.data) else firstCodepoint(ast.src[sp.start..sp.end]);
    return metrics.delimVariants(cp) != null;
}

fn layoutRow(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    const gl = metrics.glue(fm);
    var x: f32 = 0;
    var height: f32 = 0;
    var depth: f32 = 0;
    var prev_role: ?Role = null;
    var prev_is_space = false;
    for (0..n.num_children) |i| {
        const child_idx = ast.child(idx, i);
        const child_atom = ast.node(child_idx);
        // TeX: a bin atom is demoted to ord at the start of a list, after
        // bin/op/rel/open/punct, or before rel/close/punct (TeXBook p.170;
        // MicroTeX RowAtom::changeToOrd).
        var role = leftRole(ast, child_idx);
        if (role == .bin) {
            const demote_prev = if (prev_role) |pr|
                pr == .bin or pr == .op or pr == .rel or pr == .open or pr == .punct
            else
                true;
            const demote_next = if (i + 1 < n.num_children) blk: {
                const nr = leftRole(ast, ast.child(idx, i + 1));
                break :blk nr == .rel or nr == .close or nr == .punct;
            } else true;
            if (demote_prev or demote_next) role = .ord;
        }
        // Inter-atom glue (TeXBook p.181), suppressed around explicit spaces
        // and between no-glue pairs.
        if (i > 0 and !prev_is_space and child_atom.tag != .space) {
            if (prev_role) |pr| {
                const units = glueUnits(pr, role, style);
                if (units != 0) {
                    const w = glue_em[units] * size_pt * quadEm(style) / 18.0;
                    const g = try list.createLeaf(.glue, w, 0, 0, span);
                    try list.scratch.append(list.gpa, .{ .idx = g, .x_shift = x, .shift = 0 });
                    x += w;
                }
            }
        }
        // TeX math_trans appends a character atom's italic correction when
        // the NEXT atom is a KERN (\mkern). \pmod/\pod/\mod begin with
        // their leading \mkern, so a directly preceding char's IC joins the
        // lead — measured XeTeX at \fontsize{30}: `b \pod 3` puts the ( at
        // b-advance + 8mu + IC(b) (0.458em, not the bare 8mu 0.444em);
        // \bmod starts with \mskip (a GLUE, not a kern), so it gets no IC.
        // Only a DIRECT char atom qualifies — TeX does not reach into a
        // preceding group's box (charIc returns 0 for non-chars).
        if (i > 0 and child_atom.tag == .row and
            (child_atom.data == pmod_row_data or child_atom.data == pod_row_data or
                child_atom.data == mod_row_data))
        {
            const prev_idx = ast.child(idx, i - 1);
            x += charIc(ast, prev_idx, ast.node(prev_idx), fm, cstyle, size_pt);
        }
        // A \middle delimiter: a zero-width placeholder box. The enclosing
        // \left...\right's layoutLeftRight computes the fence's required ink
        // from the inner content (the placeholder contributes nothing) and
        // then rewrites this box in place to the fence-sized delimiter — the
        // delimiter's OWN smallest MATH variant covering the same req.
        const child_box = if (child_atom.tag == .char and (child_atom.data & middle_marker) != 0) blk: {
            const mn = ast.node(child_idx);
            const mcp: u21 = @truncate(mn.data);
            const ph = try list.create(.char, 0, 0, 0, &.{}, mcp, cstyle, size_pt, span);
            // The delimiter glyph does not match the "\middle..." source
            // bytes, so flatten must dupe it into the arena, not alias.
            list.charDataPtr(ph).synthetic = true;
            break :blk ph;
        } else try layoutInner(
            list,
            ast,
            child_idx,
            fm,
            style,
            size_pt,
            cstyle,
            cramped,
        );
        const cb = list.get(child_box);
        // A BARE big operator is axis-centered: make_op sets the op box's
        // shift_amount to (h−d)/2 − axis in EVERY style (TeXbook rule 13b).
        // The box's h/d are the DRAWN glyph's ink extents (metrics.bigOpInk × drawn
        // size), so this shift puts the ink CENTER on the math axis — the
        // old cmex10 hang-below box placed the LMMath glyph's baseline where
        // the cmex glyph's baseline should be, riding 0.75–1.1em too high
        // (top-clipped). The row absorbs the shift into its height/depth so
        // the operand stays on the baseline (the row of `\int x` is
        // h=13.61 d=8.61 at 10pt, x on the baseline).
        const op_shift: f32 = if (ast.node(unwrapAtom(ast, child_idx)).tag == .op)
            (cb.height - cb.depth) / 2 - s(gl.axis_height, size_pt)
        else
            0;
        try list.scratch.append(list.gpa, .{ .idx = child_box, .x_shift = x, .shift = op_shift });
        x += cb.width;
        // Inter-character italic-correction kern (XeTeX+unicode-math
        // math_trans / OpenType MATH MathItalicsCorrectionInfo): a char's
        // italic correction joins the advance when the NEXT atom is a
        // character noad. LM Math's advances are TIGHT (unlike CM's, which
        // built the room in), so without the kern adjacent italics collide
        // — measured `\frac{\partial^2 u}{\partial x^2}` at 30pt: the
        // denom x sits at ∂-advance + IC(∂) + x, ref gap 1.70pt vs ztex's
        // −0.18pt overlap. The rule fires only for a genuine TeX math_char
        // noad: the placed child must be an ITALIC char (the OpenType MATH
        // ItalicsCorrection is designed for the slanted math-italic forms —
        // ∂ f g; upright \mathbf and \operatorname's roman letters get NO
        // IC, measured `\mathbf{ab}` b-at-bare-advance and `\pmod`'s "mod")
        // that is NOT a delimiter codepoint (( ) [ ] { } … are delimiters,
        // not math_char noads — TeX gives them no IC). Scripted chars count
        // (x^2 is one math_char noad); spaces/kerns and subformula boxes do
        // not. charIc reads the same LM Math IC table the env cells use;
        // letters with no MATH-table IC (x, a, digits…) contribute 0, so
        // plain `x y` and `x\,y` keep their current spacing.
        if (child_atom.tag == .char and cstyle == .italic and
            i + 1 < n.num_children and
            isCharNoad(ast, ast.child(idx, i + 1)) and
            !isDelimiterNode(ast, child_idx, child_atom))
        {
            x += charIc(ast, child_idx, child_atom, fm, cstyle, size_pt);
        }
        // Post-op italic-correction tail: TeX appends the operator's
        // italic correction to the advance before the next atom (TeXbook
        // p.170; measured post-∫ advance 16.15pt = box + ic + thin — ztex
        // was 6.65pt short).
        x += opTailIc(ast, child_idx, style, size_pt);
        height = @max(height, cb.height - op_shift);
        depth = @max(depth, cb.depth + op_shift);
        prev_role = if (child_atom.tag == .char) role else rightRole(ast, child_idx);
        prev_is_space = child_atom.tag == .space;
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// \substack{a \\ b \\ c} (atom `.substack`, children = the line rows):
/// amsmath's script-size multi-line stack for limits. Each line lays out
/// at \scriptstyle (one level down from display/text; the root-relative
/// ladder grows the lines back to the script size from deeper styles), is
/// centered horizontally in the stack, and the lines stack vertically with
/// the TeX \subarray gaps (amsmath.sty, the XeTeX/OT-math branch):
///
///     \baselineskip = \Umathstacknumup + \Umathstackdenomdown (script size)
///     \lineskip     = \Umathstackvgap (script size)
///     \lineskiplimit = \lineskip
///
/// with Latin Modern Math's MATH-table constants StackTopShiftUp 0.444em,
/// StackBottomShiftDown 0.345em, StackGapMin 0.120em at the SCRIPT size —
/// baseline-to-baseline = max(0.789·script, d_prev + h_next + 0.120·script),
/// measured against the XeTeX reference of
/// \sum_{\substack{i=1 \\ j=1}}^{n} x_i x_j at 36pt: the lines separate by
/// exactly d_prev + h_next + vgap (20.08pt; the 0.789·script nominal
/// baselineskip 19.88pt loses to the digit-height lines), and the stack's
/// line-1 baseline lands at op_bottom + max(bigop2, bigop4 − stack_h) +
/// stack_h — i.e. the reported stack box is the RAW stack (height = line
/// 1's height, depth = the last line's depth below line 1's baseline), NOT
/// the amsmath \vcenter'd (H−D)/2 ± axis box: the measured reference
/// placement under a display ∑ matches the raw box exactly (38.92pt vs
/// 38.85pt measured) while the vcenter model would sit 3.9pt higher. The
/// depth folds in the full stack (last line's baseline + depth) so the box
/// bounds every line's ink.
fn layoutSubstack(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const gl = metrics.glue(fm);
    // amsmath \subarray: every cell is $\m@th\scriptstyle##$ — the lines
    // are ALWAYS script style. The size follows the root-relative ladder:
    // display/text → script size (×0.7), script → unchanged (the limits
    // path already passes the script size), scriptscript → back up to the
    // script size (0.7/0.5), exactly a forced \scriptstyle.
    const s_size = size_pt * (styleScale(gl, .script) / styleScale(gl, style));
    const baselineskip = (0.444 + 0.345) * s_size; // StackTopShiftUp + StackBottomShiftDown
    const lineskip = 0.120 * s_size; // StackGapMin

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var max_w: f32 = 0;
    var h1: f32 = 0;
    var y_last: f32 = 0; // last line's baseline below line 1's baseline
    var d_last: f32 = 0;
    var prev_d: f32 = 0;
    var y: f32 = 0;
    for (0..n.num_children) |i| {
        const line = try layoutInner(list, ast, ast.child(idx, i), fm, .script, s_size, cstyle, false);
        const lb = list.get(line);
        if (i > 0) {
            // baseline separation: max(nominal baselineskip, prev depth +
            // this height + \lineskiplimit), the TeX \baselineskip rule
            y += @max(baselineskip, prev_d + lb.height + lineskip);
        }
        // Record the placement; x-centering is applied once the max width
        // is known, so store the raw line box and patch the x_shift below.
        try list.scratch.append(list.gpa, .{ .idx = line, .x_shift = 0, .shift = y });
        max_w = @max(max_w, lb.width);
        if (i == 0) h1 = lb.height;
        y_last = y;
        d_last = lb.depth;
        prev_d = lb.depth;
    }
    // Center each line horizontally in the stack box.
    for (list.scratch.items[saved_len..]) |*cr| {
        const b = list.get(cr.idx);
        cr.x_shift = (max_w - b.width) / 2;
    }
    return list.create(.hbox, max_w, h1, y_last + d_last, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// \pmod{n} / \pod{n} (a row marked pmod_row_data / pod_row_data; children
/// ['(', (opname "mod", 6mu space, for \pmod), arg, ')']): amsmath's
/// parenthesized mod — amsmath.sty:
///
///     \pod#1{\allowbreak \if@display\mkern18mu\else\mkern8mu\fi (#1)}
///     \pmod#1{\pod{{\operator@font mod}\mkern6mu#1}}
///
/// The leading \mkern is style-INVARIANT here: 8mu (8/18 em) in every
/// style. TeX's \if@display never fires inside \array cells (the cells are
/// \m@th text-mode lists), so `\displaystyle \begin{array} ... \pmod ...`
/// still takes the 8mu branch — measured on the XeTeX reference at
/// \fontsize{30}: the \displaystyle rows render pixel-identical to the
/// text rows, and the b→( gap is b advance + 8mu + IC(b) (see layoutRow's
/// mod-lead IC). The rest is
/// placed back to back with NO inter-atom glue: every pair in the
/// composition (kern–(, (–mod, mod–6mu, 6mu–arg, arg–)) has zero glue in
/// the TeX table, and TeX's \mkern suppresses any letter kern across it —
/// so the pieces are simply laid at their advances with the two explicit
/// kerns. The 6mu mod-n gap is a plain 6/18-em space leaf. The "mod" word
/// is the ordinary opname mechanism (roman letters, no kerning), measured
/// from the bundled LM Roman regular face at every size in both pipelines.
fn layoutPmod(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    // 8mu in ALL styles: the \if@display 18mu branch never fires in array
    // cells (measured), and the corpus target is the array form.
    const kern_leading = (8.0 / 18.0) * size_pt;
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    const lead = try list.createLeaf(.glue, kern_leading, 0, 0, span);
    try list.scratch.append(list.gpa, .{ .idx = lead, .x_shift = 0, .shift = 0 });
    var x = kern_leading;
    var height: f32 = 0;
    var depth: f32 = 0;
    for (0..n.num_children) |i| {
        const cb = try layoutInner(list, ast, ast.child(idx, i), fm, style, size_pt, cstyle, cramped);
        const b = list.get(cb);
        try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = x, .shift = 0 });
        x += b.width;
        height = @max(height, b.height);
        depth = @max(depth, b.depth);
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// \bmod (a row marked bmod_row_data; children [5mu space, roman "mod"
/// word, 5mu space]): amsmath's binary mod —
///
///     \def\bmod{\mskip-\medmuskip\mkern5mu\mathbin{\operator@font mod}
///               \penalty900\mkern5mu\mskip-\medmuskip}
///
/// The ord↔bin glue TeX inserts around the \mathbin (medmuskip, 4mu) is
/// cancelled by the two \mskip-\medmuskip kerns, so the NET spacing is
/// exactly 5mu before and after the word (measured on the XeTeX reference:
/// `a \bmod 2` at 30pt — a→m 24.20pt = a advance + 8.334pt = 5mu, m→2
/// 8.334pt — in every style; the \mkern5mu is a fixed kern, unlike the
/// style-suppressed glue of the ordinary row path). The pieces are laid at
/// their advances with NO inter-atom glue (the kerns carry all the spacing
/// — TeX's \mskip/\mkern suppress any letter kern across them), and the row
/// is class ORD (the space leaves are ord), so neighbors add no glue either.
fn layoutBmod(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var x: f32 = 0;
    var height: f32 = 0;
    var depth: f32 = 0;
    for (0..n.num_children) |i| {
        const cb = try layoutInner(list, ast, ast.child(idx, i), fm, style, size_pt, cstyle, cramped);
        const b = list.get(cb);
        try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = x, .shift = 0 });
        x += b.width;
        height = @max(height, b.height);
        depth = @max(depth, b.depth);
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// \mod{arg} (a row marked mod_row_data; children [roman "mod" word, 6mu
/// space, arg]): amsmath's mod with its argument — amsmath.sty:
///
///     \def\mod#1{\allowbreak \if@display\mkern18mu\else\mkern12mu\fi
///                {\operator@font mod}\,\,#1}
///
/// The leading \mkern is style-INVARIANT here: 12mu (12/18 em) in every
/// style. TeX's \if@display never fires inside \array cells (the cells are
/// \m@th text-mode lists), so `\displaystyle \begin{array} ... \mod ...`
/// still takes the 12mu branch — measured on the XeTeX reference at
/// \fontsize{30}: the \displaystyle rows render pixel-identical to the
/// text rows, and the d→m gap is d advance + 12mu + IC(d) (see layoutRow's
/// mod-lead IC). The rest is placed back to back with NO
/// inter-atom glue: kern–mod, mod–6mu, 6mu–arg all have zero glue in the
/// composition (the \,\,\, are the explicit 6mu space leaf), exactly like
/// \pmod. The row's left role is ord (see leftRole — the leading \mkern is
/// not a noad), so the preceding atom adds no glue.
fn layoutMod(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    // 12mu in ALL styles: the \if@display 18mu branch never fires in array
    // cells (measured), and the corpus target is the array form.
    const kern_leading = (12.0 / 18.0) * size_pt;
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    const lead = try list.createLeaf(.glue, kern_leading, 0, 0, span);
    try list.scratch.append(list.gpa, .{ .idx = lead, .x_shift = 0, .shift = 0 });
    var x = kern_leading;
    var height: f32 = 0;
    var depth: f32 = 0;
    for (0..n.num_children) |i| {
        const cb = try layoutInner(list, ast, ast.child(idx, i), fm, style, size_pt, cstyle, cramped);
        const b = list.get(cb);
        try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = x, .shift = 0 });
        x += b.width;
        height = @max(height, b.height);
        depth = @max(depth, b.depth);
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// Forced limits keep the nucleus's baseline and use the face's MATH spacing.
/// The annotation follows the style ladder; under-limits are cramped.
fn limitBox(
    list: *box.BoxList,
    ast: *const atom.Ast,
    script_idx: u32,
    base: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
    under: bool,
    span: atom.Span,
) !u32 {
    const gl = metrics.glue(fm);
    const l_style: Style = switch (style) {
        .display, .text => .script,
        .script, .script_script => .script_script,
    };
    const l_size = size_pt * (styleScale(gl, l_style) / styleScale(gl, style));
    const script = try layoutInner(
        list,
        ast,
        script_idx,
        fm,
        l_style,
        l_size,
        cstyle,
        if (under) true else cramped,
    );
    const bb = list.get(base);
    const sb = list.get(script);
    const width = @max(bb.width, sb.width);
    // MATH gaps are inner clearances. TeX's outer operator padding must not
    // be added between the nucleus and its annotation.
    const rise: f32 = if (under)
        bb.depth + @max(s(gl.bigop_spacing4, size_pt), sb.height + s(gl.bigop_spacing2, size_pt))
    else
        bb.height + @max(s(gl.bigop_spacing3, size_pt), sb.depth + s(gl.bigop_spacing1, size_pt));
    // The limit hangs off the base's edge, so the result box reaches as far
    // as whichever of the two does — adding the base's depth to the limit's
    // own drop counted it twice.
    const height = if (under) bb.height else @max(bb.height, rise + sb.height);
    const depth = if (under) @max(bb.depth, rise + sb.depth) else bb.depth;
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{
        .idx = base,
        .x_shift = (width - bb.width) / 2,
        .shift = 0,
    });
    try list.scratch.append(list.gpa, .{
        .idx = script,
        .x_shift = (width - sb.width) / 2,
        .shift = if (under) rise else -rise,
    });
    return list.create(.vbox, width, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// \overset{top}{base} / \underset{bot}{base} / \stackrel{top}{base} (a row
/// carrying one of the three markers; children [script, base]): a \mathop
/// with FORCED limits, so the script is centred over/under the base in EVERY
/// math style — measured: `\overset{a}{b}` is identical in display and text
/// style, where a bare `\sum^{a}` would set its script beside. The three
/// markers differ only in the class the row reports (see leftRole): amsmath's
/// pair expands to `\mathrel{\nonscript\relax{}}` before the construct, and
/// that empty \mathrel takes no class, while the kernel's \stackrel IS a
/// \mathrel (measured: `x\overset{a}{b}` has no inter-atom glue on either
/// side, `x\stackrel{a}{b}` the thick 5mu of a rel).
///
/// One deviation: XeTeX axis-centres a single-character \stackrel base (the
/// char-nucleus path of make_op), ztex keeps every base on its own baseline —
/// the same choice layoutOpLimits makes for an operator WORD base (`\lim`).
/// The reference's own `\overset{ab}{y}` box keeps its base on the baseline.
fn layoutLimits(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
    under: bool,
) !u32 {
    const base = try layoutInner(
        list,
        ast,
        ast.child(idx, 1),
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
    );
    return limitBox(
        list,
        ast,
        ast.child(idx, 0),
        base,
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
        under,
        ast.span(idx),
    );
}

/// \underbrace{x}_{c} / \overbrace{x}^{c} (a row carrying one of the two
/// markers; children [content] or [content, annotation]): a \mathop — so
/// class OP, no glue before and a thin space after (measured:
/// `x\underbrace{ab}` has none, `x\underbrace{ab}y` a 3mu thin space) —
/// carrying a brace below (underbrace) or above (overbrace) the content, and
/// an optional forced-limit annotation.
///
/// The brace is the MATH HORIZONTAL FORM the font itself draws — U+23DF under
/// the content, U+23DE over it — resolved through `metrics.horizontalGlyph`
/// for the content's own advance: the LARGEST horizontal size variant whose
/// AdvanceMeasurement fits it. Requests beyond the ladder use the balanced
/// GlyphAssembly of the glyph's own parts, which reaches any width.
/// Measured with XeTeX+unicode-math, `\overbrace{a+b}` at 60pt paints U+23DE as
/// ONE 1.996em glyph (the MATH variant with AdvanceMeasurement 1.997)
/// centred on the content, and `\underbrace{\frac{a}{b}}` paints U+23DF as
/// one glyph — a real curly brace with its cusp, never a rectangle.
///
/// Everything else follows the ink that will really be painted:
///   · the chosen form's ADVANCE is the band's width, CENTRED on the content.
///     The construct keeps the CONTENT's advance — an op's width is its
///     content's, as the reference's box does too — and ink that overhangs it
///     is recorded through `setCharOverhang`, so the draw list's bounds still
///     enclose it.
///   · the band's ink is cleared from the content's box edge by the font's own
///     `rule_thickness`, the same clearance layoutOverUnder gives an overline
///     (measured on the reference: the over brace's ink bottom sits 0.056em
///     above the content's ink top, and `rule_thickness` is 0.0441em).
///   · the height/depth grow to BOUND that ink, never by a guessed constant:
///     U+23DE's ink floats above its own baseline (yMin 0.49–0.55em up, yMax
///     0.78–0.85em), U+23DF's hangs below it (yMax 0, yMin 0.35–0.42em down),
///     so each is placed by its own `bottom`/`asc`/`desc`.
///
/// The glyph's bytes are the codepoint, which never equals the `\underbrace`
/// source, so the box is synthetic and `flatten` dupes them into the arena;
/// `CharData.horizontal_req` carries the request so svg.zig and the rasterizer
/// resolve the SAME form the layout boxed.
fn layoutBrace(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
    under: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const content = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
    );
    const cb = list.get(content);
    // The two halves of the extensible brace: U+23DF below the content, U+23DE
    // above it. The request is the CONTENT's own advance, in em of the drawn
    // size — the width the brace has to span.
    const cp: u21 = if (under) 0x23DF else 0x23DE;
    const req_em = if (size_pt > 0) cb.width / size_pt else 0;
    // A wired face that declares no horizontal construction for this glyph
    // answers null — a real "this face has no such form" — and the bundled
    // ladder must NOT be substituted for it. The band then degrades to the
    // glyph's own BASE form at the base size, the contract every other char
    // box has, and never invents a stroke: with no request recorded the back
    // ends draw that same base glyph.
    const stretched = try metrics.horizontalGlyph(fm, cp, req_em);
    const geo: metrics.StretchGeometry = stretched orelse blk: {
        const g = metrics.glyphAt(fm, cp, .italic, size_pt) orelse
            metrics.glyphEstimate(fm, cp, .italic);
        break :blk .{
            .advance_em = if (size_pt > 0) s(g.width, size_pt) / size_pt else 0,
            .ink = metrics.glyphInkAt(cp, .italic),
        };
    };
    const advance = geo.advance_em * size_pt;
    const ink_asc = geo.ink.asc * size_pt;
    const ink_desc = geo.ink.desc * size_pt;
    // The band's own box: the drawn glyph, boxed by the ink of the form that
    // was selected, at the base size in the MATH font family so the rasterizer
    // and the browser pick the face that carries it.
    const brace = try list.create(
        .char,
        advance,
        ink_asc,
        ink_desc,
        &.{},
        cp,
        .italic,
        size_pt,
        span,
    );
    const cd = list.charDataPtr(brace);
    cd.synthetic = true;
    if (stretched != null) cd.horizontal_req = req_em;
    setCharOverhang(list, brace, geo.ink, size_pt);
    // XeTeX puts an underbrace on the nucleus's depth. An overbrace's baseline
    // is AccentBaseHeight below the nucleus's top, not its glyph's lower edge.
    const shift: f32 = if (under)
        cb.depth
    else
        metrics.accentBaseHeightEm(fm) * size_pt - cb.height;
    const height = if (under) cb.height else @max(cb.height, ink_asc - shift);
    const depth = if (under) @max(cb.depth, shift + ink_desc) else cb.depth;
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = content, .x_shift = 0, .shift = 0 });
    try list.scratch.append(list.gpa, .{ .idx = brace, .x_shift = (cb.width - advance) / 2, .shift = shift });
    const band_box = try list.create(
        .hbox,
        cb.width,
        height,
        depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
    if (n.num_children < 2) return band_box;
    return limitBox(
        list,
        ast,
        ast.child(idx, 1),
        band_box,
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
        under,
        span,
    );
}

/// \phantom{x} / \hphantom{x} / \vphantom{x} (a row carrying
/// `phantom_row_data | keep`; children [content]): the argument laid out at
/// the CURRENT math style, then re-boxed with the dimensions the keep mask
/// selects and NO children — latex.ltx's \finph@nt returns an empty box whose
/// ht/dp/wd were copied off the argument box, so nothing is drawn and the
/// content's style never changes (measured: `x^{a\phantom{b^2}}` keeps
/// b^2's script-size height). A `.strut` box is metrics-only by construction
/// (draw.flatten draws nothing for it), which is exactly \phantom's contract.
///
/// \smash is NOT that: it keeps the advance but PAINTS its content, with the
/// axes in its argument flattened away. amsmath's definition is
/// `\def\smash{\ifmmode\mathpalette\smash@\else\expandafter\smashb\fi}` →
/// `\hbox to <width>{\vbox to 0pt{…}\vss}` (and the single-axis forms the
/// same with `\vbox to` / `\vss`), so the result is a real box holding the
/// content with the smashed dimensions forced to zero — XeTeX at 20pt:
/// `\smash{b}` width 8.86, height 0, depth 0, with the b still drawn. Making
/// it an empty `.strut` (as the phantoms are) paints nothing at all, which is
/// how `\smash{b}` came out as a bare background rectangle.
fn layoutPhantom(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const content = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
    );
    const cb = list.get(content);
    const keep_w = n.data & keep_width != 0;
    const keep_h = n.data & keep_height != 0;
    const keep_d = n.data & keep_depth != 0;
    const w: f32 = if (keep_w) cb.width else 0;
    const h: f32 = if (keep_h) cb.height else 0;
    const d: f32 = if (keep_d) cb.depth else 0;
    if (n.data & smash_row == 0) {
        return list.createLeaf(.strut, w, h, d, ast.span(idx));
    }
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = content, .x_shift = 0, .shift = 0 });
    return list.create(
        .hbox,
        w,
        h,
        d,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        ast.span(idx),
    );
}

/// \color{<spec>}… / \textcolor{<spec>}{…} (a `.color` / `.textcolor` node;
/// exactly one child): a PAINT scope, not a geometry one. The child lays out
/// exactly as it would unscoped and the wrapper box carries ONLY the color,
/// so flatten's nearest-scope resolution paints the subtree and nothing else
/// moves: a colored relation keeps its relation glue, the content's font
/// styles and sizes are untouched, and a nested scope shadows this one for
/// its own subtree only — leaving the scope restores the enclosing color
/// without the layout rewriting a single flattened primitive.
fn layoutColorScope(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    if (n.num_children == 0) {
        return list.createLeaf(.strut, 0, 0, 0, ast.span(idx));
    }
    const child = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        style,
        size_pt,
        cstyle,
        cramped,
    );
    const cb = list.get(child);
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = child, .x_shift = 0, .shift = 0 });
    const scope = try list.create(
        .hbox,
        cb.width,
        cb.height,
        cb.depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        ast.span(idx),
    );
    // The scope's own color, INCLUDING an explicit transparent {0,0,0,0}
    // and an explicit black: both are real overrides, never "inherit".
    list.colorPtr(scope).* = atom.nodeColor(n.data);
    return scope;
}

/// LaTeX's \fboxsep (latex.ltx: `\setlength{\fboxsep}{3ptplus1ptminus1pt}`)
/// and \fboxrule (`0.4pt`) — ABSOLUTE physical dimensions, never scaled by
/// the font size: `\boxed` at 10pt and at 40pt have the same 3pt gap and
/// 0.4pt frame, exactly as a reference render shows.
const fboxsep_pt: f32 = 3.0;
const fboxrule_pt: f32 = 0.4;

/// LaTeX's `\arrayrulewidth` (latex.ltx: `\setlength\arrayrulewidth{.4pt}`):
/// the fixed weight of an `\hline` rule and of an array's `|` column rules —
/// a fixed dimension, so it never scales with the font size, and the same
/// 0.4pt as `\fboxrule` above.
const arrayrulewidth_pt: f32 = 0.4;

/// LaTeX's `\doublerulesep` (article.cls: `\setlength\doublerulesep{2pt}`),
/// fixed like `\arrayrulewidth` and never scaled with the font size.
/// latex.ltx:16728 spells `\hline` as `\noalign{\hrule \@height
/// \arrayrulewidth}` followed by a `\futurelet`, and `@xhline` — which sees
/// whether the next token is another `\hline` — inserts `\vskip\doublerulesep
/// \vskip-\arrayrulewidth` between the two. That is why two rules on ONE
/// boundary are 2pt apart from ink top to ink top, and why the boundary opens
/// up by \arrayrulewidth + (n − 1)·\doublerulesep rather than n thicknesses.
/// Measured on the exact-font XeLaTeX reference at 20pt: the leading pair of
/// `\begin{matrix}\hline\hline a&b\\c&d\\\hline\end{matrix}` has its rule
/// centres 2.0004pt apart.
const doublerulesep_pt: f32 = 2.0;

/// \boxed{x} — LaTeX's `\fbox{\m@th$\displaystyle#1$}` (latex.ltx:1093):
/// the frame goes OUTSIDE the content, the content keeps its baseline, and
/// the formula is set in DISPLAY style even when \boxed appears in inline
/// math (measured against XeTeX at 20pt: `\boxed{\frac ab}` has the height
/// and depth of a display fraction, and `\boxed{x}` is 18.24 × 12.24 × 3.62
/// = x's 11.44 × 8.84 × 0.22 plus 2·(3 + 0.4) around it).
///
/// The four rules are `.rule` boxes, so they take the enclosing color scope
/// like any other primitive: an uncolored `\boxed` paints on the host's own
/// foreground, and `\textcolor{black}{\boxed{x}}` frames it black.
fn layoutBoxed(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    _ = cramped;
    const span = ast.span(idx);
    const n = ast.node(idx);
    if (n.num_children == 0) return list.createLeaf(.strut, 0, 0, 0, span);
    // `\fbox{\m@th$\displaystyle#1$}` — the content is a fresh, UNCRAMPED
    // display-style list, so a \boxed in a denominator still shows a display
    // fraction. The forced style carries the size ladder with it, exactly as
    // a `.mathstyle` node does.
    const gl = metrics.glue(fm);
    const content = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        .display,
        size_pt * (styleScale(gl, .display) / styleScale(gl, style)),
        cstyle,
        false,
    );
    const cb = list.get(content);
    const outer_w = cb.width + 2 * (fboxsep_pt + fboxrule_pt);
    const outer_h = cb.height + fboxsep_pt + fboxrule_pt;
    const outer_d = cb.depth + fboxsep_pt + fboxrule_pt;
    const inset = fboxsep_pt + fboxrule_pt;

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{
        .idx = content,
        .x_shift = inset,
        .shift = 0,
    });
    // A `.rule` box paints the band [shift − height, shift + depth] in the
    // y-DOWN draw frame (draw.zig: `rect.y = y − height`, `height + depth`),
    // so `shift` is the rule's OWN baseline: a rule that must sit `k` points
    // ABOVE the row baseline takes `shift = −(k − height)`. Each rule below
    // is placed by the OUTER edge it must land on, and the two side rules run
    // only between the horizontal ones: a closed rectangle painted exactly
    // ONCE, so a translucent frame never doubles up (and darkens) a corner.
    const side_h = outer_h - fboxrule_pt;
    const side_d = outer_d - fboxrule_pt;
    const rules = [_]struct { x: f32, shift: f32, w: f32, h: f32, d: f32 }{
        // top: its underside sits fboxsep above the content's top
        .{ .x = 0, .shift = -side_h, .w = outer_w, .h = fboxrule_pt, .d = 0 },
        // bottom: its upper side sits fboxsep below the content's bottom
        .{ .x = 0, .shift = side_d, .w = outer_w, .h = 0, .d = fboxrule_pt },
        // left and right: between the two horizontal rules, flush with the
        // outer edges
        .{ .x = 0, .shift = 0, .w = fboxrule_pt, .h = side_h, .d = side_d },
        .{ .x = outer_w - fboxrule_pt, .shift = 0, .w = fboxrule_pt, .h = side_h, .d = side_d },
    };
    for (rules) |r| {
        const rule = try list.createLeaf(.rule, r.w, r.h, r.d, span);
        try list.scratch.append(list.gpa, .{ .idx = rule, .x_shift = r.x, .shift = r.shift });
    }
    return list.create(
        .hbox,
        outer_w,
        outer_h,
        outer_d,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// \hspace{<dim>} / \kern<dim> / \mkern<dim> / `\: / \mkern's constant
/// siblings (a row carrying `kern_row_data | unit` whose single `.space` child
/// holds the magnitude): an invisible skip whose unit decides the scaling.
///
///   pt  absolute — TeX dimensions never scale with the font size, and
///       \genfrac's rule thickness follows the same rule here
///   em  the current em, so it follows the style ladder (a \hspace{1em} in a
///       script is 0.7 of its width in text style)
///   ex  the current x-height, same scaling
///   mu  1/18 em of the ladder-NEUTRAL em — `size_pt / styleScale(style)` is
///       the size the construct would have in text style, so a mu kern is
///       style-INVARIANT: identical in display and text style, and unchanged
///       by a \scriptstyle/\displaystyle switch inside it. This is ztex's mu
///       convention, the one \pmod's leading 8mu, \mod's 12mu and \bmod's
///       5mu kerns already follow.
fn layoutKern(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
) !u32 {
    const n = ast.node(idx);
    const value = atom.fixedToEm(ast.node(ast.child(idx, 0)).data);
    const gl = metrics.glue(fm);
    const width: f32 = switch (n.data & dim_unit_mask) {
        dim_em => value * size_pt,
        dim_ex => value * s(gl.x_height, size_pt),
        dim_mu => (value / 18.0) * (size_pt / styleScale(gl, style)),
        else => value,
    };
    return list.createLeaf(.glue, width, 0, 0, ast.span(idx));
}

/// The italic correction (in em of the glyph's font-size) that
/// XeTeX+unicode-math appends after a character in a math list — read from
/// the MathItalicsCorrectionInfo table of latinmodern-math.otf (fontTools).
/// The MATH coverage is keyed by GLYPH NAME, so this table is the
/// MathItalicsCorrectionInfo materialized from glyph names to codepoints
/// through the font's cmap (each cp → glyph name → its IC); every entry was
/// verified to match the installed font's coverage with 0 mismatches. TeX
/// adds a char's italic correction to the width when it ends a math list
/// (tex.web math_trans), so an \halign CELL's width is advance + IC of its
/// last char — measured on the XeTeX reference: the pmatrix column 2 box is
/// 10 + max(b 4.29 + 0.14, d 5.20 + 0.24) = 15.44pt at 10pt, and the
/// aligned left column is right-aligned to max(a 5.29 + 0, d 5.20 + 0.24) =
/// 5.44pt. The static metrics table's italic corrections are Computer-Modern
/// values (b/d = 0), which would shrink the columns by 0.14/0.24pt at 10pt
/// (0.5/0.86pt at 36pt) — so the env layout reads the LM Math ICs from this
/// table. Glyphs without an entry (math-italic a/b, x, digits except 7,
/// relations, big ops) have IC 0.
const env_ic_table = [_]struct { cp: u21, ic: f32 }{
    .{ .cp = 0x0037, .ic = 0.0130 },
    .{ .cp = 0x0052, .ic = 0.0240 },
    .{ .cp = 0x0056, .ic = 0.0080 },
    .{ .cp = 0x0057, .ic = 0.0090 },
    .{ .cp = 0x0058, .ic = 0.0040 },
    .{ .cp = 0x0059, .ic = 0.0160 },
    .{ .cp = 0x005B, .ic = 0.0060 },
    .{ .cp = 0x005E, .ic = 0.0330 },
    .{ .cp = 0x005F, .ic = 0.0280 },
    .{ .cp = 0x0061, .ic = 0.0110 },
    .{ .cp = 0x0066, .ic = 0.0790 },
    .{ .cp = 0x0067, .ic = 0.0130 },
    .{ .cp = 0x0068, .ic = 0.0070 },
    .{ .cp = 0x006B, .ic = 0.0110 },
    .{ .cp = 0x006C, .ic = 0.0050 },
    .{ .cp = 0x006D, .ic = 0.0080 },
    .{ .cp = 0x006E, .ic = 0.0070 },
    .{ .cp = 0x0071, .ic = 0.0270 },
    .{ .cp = 0x0075, .ic = 0.0070 },
    .{ .cp = 0x0076, .ic = 0.0080 },
    .{ .cp = 0x0077, .ic = 0.0090 },
    .{ .cp = 0x0078, .ic = 0.0160 },
    .{ .cp = 0x0079, .ic = 0.0080 },
    .{ .cp = 0x007E, .ic = 0.0270 },
    .{ .cp = 0x1D435, .ic = 0.0250 },
    .{ .cp = 0x1D436, .ic = 0.0730 },
    .{ .cp = 0x1D437, .ic = 0.0040 },
    .{ .cp = 0x1D438, .ic = 0.0540 },
    .{ .cp = 0x1D439, .ic = 0.1340 },
    .{ .cp = 0x1D43B, .ic = 0.0780 },
    .{ .cp = 0x1D43C, .ic = 0.0850 },
    .{ .cp = 0x1D43D, .ic = 0.1060 },
    .{ .cp = 0x1D43E, .ic = 0.0680 },
    .{ .cp = 0x1D440, .ic = 0.1020 },
    .{ .cp = 0x1D441, .ic = 0.1060 },
    .{ .cp = 0x1D442, .ic = 0.0050 },
    .{ .cp = 0x1D443, .ic = 0.1400 },
    .{ .cp = 0x1D445, .ic = 0.0240 },
    .{ .cp = 0x1D446, .ic = 0.0600 },
    .{ .cp = 0x1D447, .ic = 0.1480 },
    .{ .cp = 0x1D448, .ic = 0.1050 },
    .{ .cp = 0x1D449, .ic = 0.2140 },
    .{ .cp = 0x1D44A, .ic = 0.1320 },
    .{ .cp = 0x1D44B, .ic = 0.0510 },
    .{ .cp = 0x1D44C, .ic = 0.2090 },
    .{ .cp = 0x1D44D, .ic = 0.0680 },
    .{ .cp = 0x1D44F, .ic = 0.0140 },
    .{ .cp = 0x1D450, .ic = 0.0250 },
    .{ .cp = 0x1D451, .ic = 0.0240 },
    .{ .cp = 0x1D453, .ic = 0.0900 },
    .{ .cp = 0x1D454, .ic = 0.0250 },
    .{ .cp = 0x1D457, .ic = 0.0130 },
    .{ .cp = 0x1D458, .ic = 0.0150 },
    .{ .cp = 0x1D45C, .ic = 0.0120 },
    .{ .cp = 0x1D45D, .ic = 0.0150 },
    .{ .cp = 0x1D45E, .ic = 0.0340 },
    .{ .cp = 0x1D45F, .ic = 0.0130 },
    .{ .cp = 0x1D463, .ic = 0.0110 },
    .{ .cp = 0x1D464, .ic = 0.0030 },
    .{ .cp = 0x1D466, .ic = 0.0280 },
    .{ .cp = 0x1D467, .ic = 0.0300 },
    .{ .cp = 0x1D6E3, .ic = 0.0250 },
    .{ .cp = 0x1D6E4, .ic = 0.1340 },
    .{ .cp = 0x1D6E6, .ic = 0.0540 },
    .{ .cp = 0x1D6E7, .ic = 0.0680 },
    .{ .cp = 0x1D6E8, .ic = 0.0780 },
    .{ .cp = 0x1D6E9, .ic = 0.0050 },
    .{ .cp = 0x1D6EA, .ic = 0.0850 },
    .{ .cp = 0x1D6EB, .ic = 0.0680 },
    .{ .cp = 0x1D6ED, .ic = 0.1020 },
    .{ .cp = 0x1D6EE, .ic = 0.1060 },
    .{ .cp = 0x1D6EF, .ic = 0.0630 },
    .{ .cp = 0x1D6F0, .ic = 0.0050 },
    .{ .cp = 0x1D6F1, .ic = 0.0770 },
    .{ .cp = 0x1D6F2, .ic = 0.1400 },
    .{ .cp = 0x1D6F3, .ic = 0.0050 },
    .{ .cp = 0x1D6F4, .ic = 0.0540 },
    .{ .cp = 0x1D6F5, .ic = 0.1480 },
    .{ .cp = 0x1D6F6, .ic = 0.1460 },
    .{ .cp = 0x1D6F7, .ic = 0.0040 },
    .{ .cp = 0x1D6F8, .ic = 0.0510 },
    .{ .cp = 0x1D6F9, .ic = 0.1090 },
    .{ .cp = 0x1D6FA, .ic = 0.0420 },
    .{ .cp = 0x1D6FD, .ic = 0.0360 },
    .{ .cp = 0x1D6FE, .ic = 0.0530 },
    .{ .cp = 0x1D6FF, .ic = 0.0360 },
    .{ .cp = 0x1D701, .ic = 0.0640 },
    .{ .cp = 0x1D702, .ic = 0.0270 },
    .{ .cp = 0x1D703, .ic = 0.0140 },
    .{ .cp = 0x1D708, .ic = 0.0580 },
    .{ .cp = 0x1D709, .ic = 0.0360 },
    .{ .cp = 0x1D70A, .ic = 0.0120 },
    .{ .cp = 0x1D70B, .ic = 0.0250 },
    .{ .cp = 0x1D70C, .ic = 0.0130 },
    .{ .cp = 0x1D70D, .ic = 0.0740 },
    .{ .cp = 0x1D70E, .ic = 0.0240 },
    .{ .cp = 0x1D70F, .ic = 0.1020 },
    .{ .cp = 0x1D710, .ic = 0.0120 },
    .{ .cp = 0x1D713, .ic = 0.0120 },
    .{ .cp = 0x1D714, .ic = 0.0100 },
    .{ .cp = 0x1D715, .ic = 0.0630 },
    .{ .cp = 0x1D719, .ic = 0.0050 },
    .{ .cp = 0x1D71A, .ic = 0.0130 },
    .{ .cp = 0x1D71B, .ic = 0.0170 },
    .{ .cp = 0x1D7D5, .ic = 0.0110 },
};

/// The LM Math italic correction (em) of a drawn codepoint; 0 when the
/// glyph has no MATH-table entry.
fn envIc(cp: u21) f32 {
    var lo: usize = 0;
    var hi: usize = env_ic_table.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (env_ic_table[mid].cp < cp) lo = mid + 1 else hi = mid;
    }
    if (lo < env_ic_table.len and env_ic_table[lo].cp == cp) return env_ic_table[lo].ic;
    return 0;
}

/// Whether an `.env` node carries delimiter children (the pmatrix family
/// and cases). The parser stores the open/close delimiter char leaves as
/// the first/last children; delimiter-less envs (matrix, aligned, array)
/// are plain \vcenter boxes.
fn envHasDelims(ast: *const atom.Ast, idx: u32) bool {
    const n = ast.node(idx);
    return n.num_children > 0 and ast.node(n.first_child).tag == .char;
}

/// The array colspec alignment nibble for column `c`: the c-th NON-rule
/// nibble of the packed spec (`|` markers occupy spec slots but not column
/// slots — `{l|r}` packs [l, rule, r], so column 0 reads l and column 1
/// reads r); null beyond the spec (columns default to centered, TeX).
fn envColAlign(data: u32, c: usize) ?u32 {
    var seen: usize = 0;
    var spec_index: usize = 0;
    while (atom.envColSpec(data, spec_index)) |nib| : (spec_index += 1) {
        if (nib == atom.EnvBits.col_rule) continue;
        if (seen == c) return nib;
        seen += 1;
    }
    return null;
}

/// The italic correction (in pt at the current size) XeTeX appends after a
/// cell's LAST character. The env's column widths and the aligned/right
/// alignments measure it (see layoutEnv): resolve the cell's last atom,
/// map it to the DRAWN codepoint the way layoutChar does (math-italic
/// letters, - → U+2212), and read the LM Math IC (env_ic_table).
fn cellTrailingIc(
    ast: *const atom.Ast,
    cell: u32,
    fm: *const metrics.FontMetrics,
    cstyle: atom.CharStyle,
    size_pt: f32,
) f32 {
    // Walk to the LAST atom: transparent wrappers and rows report their
    // last child; a group's content is the cell's only child; a scripted
    // cell ends in its last script's content. `.color` / `.textcolor` are
    // PAINT scopes over the atoms they contain, so the last atom of a
    // colored cell is the last atom the scope holds: a `\color{red} f`
    // column measures exactly the 1.8pt italic correction of `f` that the
    // uncolored column does, instead of dropping it.
    var u = cell;
    while (true) {
        const c = ast.node(u);
        switch (c.tag) {
            .group, .styled, .mathstyle, .color, .textcolor => {
                if (c.num_children == 0) return 0;
                u = ast.child(u, 0);
            },
            .row, .left, .script => {
                if (c.num_children == 0) return 0;
                u = ast.child(u, c.num_children - 1);
            },
            else => break,
        }
    }
    const n = ast.node(u);
    return charIc(ast, u, n, fm, cstyle, size_pt);
}

/// The LM Math italic correction (in pt at the current size) of a char
/// atom, read from the OpenType MATH MathItalicsCorrectionInfo by the
/// glyph's NAME (the MATH coverage is keyed by glyph name, not codepoint):
/// the char's DRAWN codepoint is resolved the way layoutChar does
/// (math-italic letters, - → U+2212), then its IC is looked up in
/// env_ic_table — the MathItalicsCorrectionInfo coverage materialized from
/// glyph names to codepoints through the LM Math cmap (verified: 0
/// mismatches against the installed latinmodern-math.otf). 0 for non-char
/// atoms or chars whose glyph has no IC entry (e.g. math-italic 'a' =
/// glyph u1D44E is absent from the coverage → 0, so `ab` keeps a's bare
/// advance).
///
/// On the `.font` path the ACTIVE FACE's own MATH value wins over that
/// static coverage: it is read from the glyph that is actually drawn, so
/// the correction tracks the face instead of a transcription of it. The
/// static path is byte-identical to before.
fn charIc(
    ast: *const atom.Ast,
    idx: u32,
    n: atom.Node,
    fm: *const metrics.FontMetrics,
    cstyle: atom.CharStyle,
    size_pt: f32,
) f32 {
    if (n.tag != .char) return 0;
    const sp = ast.span(idx);
    var cp: u21 = if (n.data != 0) @truncate(n.data) else firstCodepoint(ast.src[sp.start..sp.end]);
    if (cp == 0x2D) cp = 0x2212;
    if (cstyle == .italic) {
        if (mathItalic(cp)) |m| {
            if (metrics.hasGlyph(fm, m, cstyle)) cp = m;
        }
    }
    // The DRAWN glyph's OpenType MATH correction when the active face
    // supplies one — the same number the reference engine reads from the
    // glyph — and the measured static coverage otherwise (below).
    if (metrics.fontItalicCorrection(fm, cp, cstyle)) |ic| return s(ic, size_pt);
    const ic = envIc(cp);
    return if (ic == 0) 0 else ic * size_pt;
}

/// \begin{env}...\end{env} (atom `.env`; children [open?, row1..rowN,
/// close?], each row a `.row` of cell atoms): the matrix family (matrix /
/// pmatrix / bmatrix / Bmatrix / vmatrix / Vmatrix), cases, aligned and
/// array. Every geometry constant below was verified against the
/// XeTeX+unicode-math reference (\showbox at 10pt plus per-glyph extraction
/// at 36pt):
///   · CELLS lay out at the current style/size. cases forces its SECOND
///     column to text style (per the feature spec; TeX's \array sets ALL
///     cells in $...$ text style — a nuance that only shows in
///     style-sensitive cells like fractions).
///   · COLUMN WIDTH = max over rows of (cell box width + the last char's
///     italic correction) — XeTeX appends the MATH-table IC of a cell's
///     last char (measured: pmatrix col2 = 10 + max(b 4.29+0.14,
///     d 5.20+0.24) = 15.44pt at 10pt; the aligned left column is
///     right-aligned to max(a 5.29+0, d 5.20+0.24) = 5.44pt). The ICs come
///     from env_ic_table (the static metrics table's ICs are CM values).
///   · COLUMNS are \halign columns `\hskip\arraycolsep \hfil cell \hfil
///     \hskip\arraycolsep` — \arraycolsep = 5pt FIXED on each side of
///     every column box, boxes adjacent (tabskip 0), so the
///     content-to-content gap is 2·arraycolsep = 10pt. amsmath's
///     \hskip -\arraycolsep around the matrix cancels the outer pads:
///     measured content-to-content 10pt, delimiters flush against the
///     array (the pmatrix `a` sits exactly at the paren box's right edge).
///     array applies the packed colspec: l/c/r alignment, and `|` draws a
///     \vrule of \arrayrulewidth = 0.4pt centered at the column boundary,
///     spanning the row's strut extent (each row carries its own rule —
///     TeX's template puts the vrule inside every row's column box, so the
///     overlapping rules read as one continuous line). cases uses
///     \arraycolsep = 0 with a \quad (1em) between columns (the @{\quad}
///     preamble puts it INSIDE the column width, measured 10pt at 10pt).
///     aligned builds \hfil\strut cell \tabskip0 / cell \hfil: the left
///     parts right-aligned to the max left width, the right parts
///     left-aligned, adjacent (the \minalignsep trailing tabskip is
///     cancelled by \math@cr@@@aligned's \kern-\alignsep@ — the "10pt"
///     gap between a and = is the THICK rel glue inside the right part).
///   · ROWS get amsmath's `\strut@`, which copies LaTeX's `\strutbox`:
///     0.7\baselineskip tall and 0.3\baselineskip deep (latex.ltx:12596 —
///     `\normallineskiplimit` is 0pt, so `\strutbox` is never re-set per
///     size), scaled by \arraystretch (1.2 for cases). matrix/array/cases
///     stack rows DIRECTLY (LaTeX \@array zeroes \baselineskip/\lineskip —
///     the strut forces the baseline distance = \baselineskip, measured 12pt
///     at 10pt, 43.2pt at 36pt). aligned \openup\jot's the interline:
///     baselineskip+3pt, limit 3pt, lineskip 4pt — measured 3pt gap at both
///     sizes.
///   · the whole array is \vcenter'd (its vertical center sits on the math
///     axis — TeX \vcenter shift (h−d)/2 − axis, measured (14.5−9.5)/2 =
///     axis at 10pt); the pmatrix-family delimiters box via the variant
///     ladder like \left..\right (layoutDelimChar), req from the array's
///     extent — the 2×2 letter matrix resolves parenleft.v6 at 10pt,
///     exactly the reference \showbox (h 14.46, d 9.46).
fn layoutEnv(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const kind = atom.envKind(n.data);
    const gl = metrics.glue(fm);
    const axis = s(gl.axis_height, size_pt);

    // Row/column geometry parameters (see the doc comment; values measured
    // against the XeTeX reference at 10pt and 36pt).
    const acs: f32 = if (kind == .cases) 0 else 5.0; // \arraycolsep (fixed pt)
    const bs = 1.2 * size_pt; // \baselineskip (LaTeX normalsize ratio)
    // amsmath's `\strut@` copies `\strutbox@`, which latex.ltx:12596 builds
    // as 0.7\baselineskip tall and 0.3\baselineskip deep (`\normallineskiplimit`
    // is 0pt, so the box is never re-set per size; amsmath's `\strut@` is the
    // same 0.7/0.3 rule). The text paren's `(` box is NOT it: at 0.75em/0.25em
    // that made every row 0.09em taller and 0.11em deeper than \baselineskip
    // allows, which is the loose bottom under a trailing \hline.
    const strut_h0 = 0.7 * bs;
    const strut_d0 = 0.3 * bs;
    const quad = size_pt; // 1em, the cases column gap

    // Children: [open?, row1..rowN, close?] — the delimiter char leaves
    // (tag .char) bracket the row atoms (tag .row).
    var row_first: u32 = 0;
    var row_count: u32 = n.num_children;
    var open_idx: ?u32 = null;
    var close_idx: ?u32 = null;
    if (n.num_children > 0 and ast.node(n.first_child).tag == .char) {
        open_idx = n.first_child;
        row_first = 1;
        row_count -= 1;
    }
    if (row_count > 0 and ast.node(n.first_child + row_first + row_count - 1).tag == .char) {
        close_idx = n.first_child + row_first + row_count - 1;
        row_count -= 1;
    }
    // An entry is either a `.row` (cells) or a `.hline` LEAF (a rule
    // between rows). A rule is NOT a row: leading, intermediate and
    // trailing `\hline`s stay separate entries and never fabricate an empty
    // row, so the column count, the row struts and the stack walk over the
    // ROW entries only, and every rule is placed at the boundary it sits on.
    const Entry = struct { node: u32, rule: bool };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(list.gpa);
    var row_entry: std.ArrayList(u32) = .empty;
    defer row_entry.deinit(list.gpa);
    for (0..row_count) |i| {
        const node = n.first_child + row_first + @as(u32, @intCast(i));
        const rule = ast.node(node).tag == .hline;
        try entries.append(list.gpa, .{ .node = node, .rule = rule });
        if (!rule) try row_entry.append(list.gpa, @intCast(entries.items.len - 1));
    }
    const nrows = row_entry.items.len;

    // 1. Lay out every cell. Each cell records its box plus its TeX width
    // (box width + the last char's italic correction — what \halign
    // measures the columns by). For ALIGNED right parts (columns ≥ 1) the
    // amsmath preamble prepends an empty ord ({}##): TeX's math spacing
    // then adds the ord→first-atom glue (thick before a relation —
    // measured: the `=` of `a &= b` sits 5mu right of the left part's box
    // at every size; med before a bin, thin before an op).
    const Cell = struct { box: u32, w: f32, h: f32, d: f32, lead_w: f32 = 0 };
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(list.gpa);
    var row_start: std.ArrayList(u32) = .empty;
    defer row_start.deinit(list.gpa);
    var ncols: usize = 0;
    for (0..nrows) |r| {
        const row_node = ast.node(entries.items[row_entry.items[r]].node);
        try row_start.append(list.gpa, @intCast(cells.items.len));
        for (0..row_node.num_children) |ci| {
            const child = row_node.first_child + @as(u32, @intCast(ci));
            // TeX's \array (matrix/array/cases) typesets EVERY cell in text
            // style regardless of the enclosing style — measured
            // XeTeX+unicode-math at 30pt: `\displaystyle \begin{matrix}
            // \frac{a}{b}\end{matrix}` renders the fraction's parts at the
            // SCRIPT size (a 20.92pt), and plain `\matrix` behaves the
            // same; only `aligned` keeps the current style (its cells are
            // set at the enclosing \displaystyle — parts at text size).
            const cell_style: Style = if (kind == .aligned) style else .text;
            const box_idx = try layoutInner(list, ast, child, fm, cell_style, size_pt, cstyle, cramped);
            const b = list.get(box_idx);
            const ic = cellTrailingIc(ast, child, fm, cstyle, size_pt);
            var lead_w: f32 = 0;
            if (kind == .aligned and ci >= 1) {
                const units = glueUnits(.ord, leftRole(ast, child), cell_style);
                lead_w = glue_em[units] * size_pt * quadEm(cell_style) / 18.0;
            }
            try cells.append(list.gpa, .{
                .box = box_idx,
                .w = b.width + ic + lead_w,
                .h = b.height,
                .d = b.depth,
                .lead_w = lead_w,
            });
        }
        ncols = @max(ncols, row_node.num_children);
    }
    if (nrows == 0) {
        // An empty environment: a zero box (delimiters still drawn at the
        // base variant — TeX renders \begin{pmatrix}\end{pmatrix} as a
        // pair of base-size parens).
        const saved_len = list.scratch.items.len;
        defer list.scratch.items.len = saved_len;
        var x: f32 = 0;
        var height: f32 = 0;
        var depth: f32 = 0;
        if (open_idx) |o| {
            const ob = try layoutDelimChar(list, ast, o, fm, axis / size_pt, 0, size_pt, cstyle);
            const b = list.get(ob);
            const sh = (b.height - b.depth) / 2 - axis;
            try list.scratch.append(list.gpa, .{ .idx = ob, .x_shift = x, .shift = sh });
            x += b.width;
            height = @max(height, b.height - sh);
            depth = @max(depth, b.depth + sh);
        }
        if (close_idx) |c| {
            const cb = try layoutDelimChar(list, ast, c, fm, axis / size_pt, 0, size_pt, cstyle);
            const b = list.get(cb);
            const sh = (b.height - b.depth) / 2 - axis;
            try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = x, .shift = sh });
            x += b.width;
            height = @max(height, b.height - sh);
            depth = @max(depth, b.depth + sh);
        }
        return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
    }

    // \arraystretch: an explicit `\arraystretch{n}` before the environment
    // rides on the FIRST row's `data` (atom.rowStretch — a row's `data` is
    // otherwise unused here, and layoutEnv walks cells, never the row node
    // itself). With no assignment the per-kind default applies: amsmath's
    // `\env@cases` sets `\def\arraystretch{1.2}` (amsmath.sty:1124) while
    // every other environment keeps LaTeX's 1. A `cases` written after an
    // explicit assignment takes the assignment, not amsmath's 1.2 — amsmath's
    // inner \def would win there, but the assignment is what the user asked
    // for. `\arraystretch{0}` collapses the strut, which the 0-means-unset
    // encoding cannot express, so it falls back to the default.
    const stretch: f32 = atom.rowStretch(ast.node(entries.items[row_entry.items[0]].node).data) orelse
        (if (kind == .cases) 1.2 else 1.0);
    const strut_h = strut_h0 * stretch;
    const strut_d = strut_d0 * stretch;

    // 2. Column widths = max cell width per column.
    var col_w: std.ArrayList(f32) = .empty;
    defer col_w.deinit(list.gpa);
    try col_w.appendNTimes(list.gpa, 0, ncols);
    for (0..nrows) |r| {
        const start = row_start.items[r];
        const end = if (r + 1 < nrows) row_start.items[r + 1] else @as(u32, @intCast(cells.items.len));
        for (start..end) |ci| {
            const c = ci - start;
            col_w.items[c] = @max(col_w.items[c], cells.items[ci].w);
        }
    }
    // cases: the \quad lives INSIDE every non-last column's width (the
    // @{\quad} preamble), so the array advance includes it.
    if (kind == .cases) {
        for (0..ncols - 1) |c| col_w.items[c] += quad;
    }
    // 3. Row boxes: the strut forces each row to at least 0.7/0.3
    // \baselineskip; rows stack directly (matrix/array/cases) or with the
    // \openup\jot interline algorithm (aligned).
    var row_h: std.ArrayList(f32) = .empty;
    defer row_h.deinit(list.gpa);
    var row_d: std.ArrayList(f32) = .empty;
    defer row_d.deinit(list.gpa);
    for (0..nrows) |r| {
        const start = row_start.items[r];
        const end = if (r + 1 < nrows) row_start.items[r + 1] else @as(u32, @intCast(cells.items.len));
        var h: f32 = 0;
        var d: f32 = 0;
        for (cells.items[start..end]) |cl| {
            h = @max(h, cl.h);
            d = @max(d, cl.d);
        }
        try row_h.append(list.gpa, @max(strut_h, h));
        try row_d.append(list.gpa, @max(strut_d, d));
    }
    // A \hline is a zero-height \noalign entry holding a bare \hrule, so the
    // boundary it sits on opens up by the rule's own thickness — that is
    // where the rule is drawn, and it is the only geometry a rule adds (it
    // is not a row, so it never touches the column count or the struts).
    // index k = the gap ABOVE row k; nrows = the gap below the last row.
    // A boundary with n rules opens up n × \arrayrulewidth plus (n − 1) gaps
    // of \doublerulesep − \arrayrulewidth; a gap and a thickness make up
    // exactly \doublerulesep, so that is \arrayrulewidth plus (n − 1) ×
    // \doublerulesep (doublerulesep_pt). One rule stays a plain
    // \arrayrulewidth, which is what the single-rule case always was.
    const hline_thickness: f32 = arrayrulewidth_pt;
    var rule_count: std.ArrayList(u32) = .empty;
    defer rule_count.deinit(list.gpa);
    try rule_count.appendNTimes(list.gpa, 0, nrows + 1);
    var rule_gap: std.ArrayList(f32) = .empty;
    defer rule_gap.deinit(list.gpa);
    try rule_gap.appendNTimes(list.gpa, 0, nrows + 1);
    for (entries.items, 0..) |e, i| {
        if (!e.rule) continue;
        var above: usize = 0;
        for (entries.items[0..i]) |prev| {
            if (!prev.rule) above += 1;
        }
        rule_count.items[above] += 1;
    }
    for (rule_count.items, 0..) |count, k| {
        if (count == 0) continue;
        rule_gap.items[k] = hline_thickness +
            @as(f32, @floatFromInt(count - 1)) * doublerulesep_pt;
    }
    const bs_jot = bs + 3.0; // \openup\jot for aligned
    // y-down model (positive shift = below the baseline): each row sits
    // below the previous by the previous row's DEPTH + this row's HEIGHT
    // + the inter-row gap (TeX's baseline distance = d_prev + h_cur + g).
    var row_shift: std.ArrayList(f32) = .empty;
    defer row_shift.deinit(list.gpa);
    try row_shift.append(list.gpa, 0);
    for (1..nrows) |r| {
        var gap: f32 = bs_jot - (row_h.items[r - 1] + row_d.items[r]);
        if (kind == .aligned) {
            if (gap < 3.0) gap = 4.0; // \lineskiplimit 3, \lineskip 4
        } else {
            gap = 0;
        }
        const step = row_shift.items[r - 1] + row_d.items[r - 1] + row_h.items[r] + gap;
        try row_shift.append(list.gpa, step + rule_gap.items[r]);
    }
    // Natural extent of the stacked rows (row 1's baseline is the array's
    // reference baseline).
    const h_nat = row_h.items[0] + rule_gap.items[0];
    const d_nat = row_shift.items[nrows - 1] + row_d.items[nrows - 1] + rule_gap.items[nrows];
    // \vcenter: the array's vertical CENTER lands on the math axis. TeX's
    // shift is (h−d)/2 − axis; in the y-down model the content must move
    // UP by that amount (negative shift = above the baseline).
    const shift_s = (h_nat - d_nat) / 2 - axis;
    var arr_h: f32 = 0;
    var arr_d: f32 = 0;
    for (0..nrows) |r| {
        const rs = row_shift.items[r] + shift_s;
        arr_h = @max(arr_h, row_h.items[r] - rs);
        arr_d = @max(arr_d, row_d.items[r] + rs);
    }
    // A leading / trailing rule sits OUTSIDE the row stack, so it widens
    // the array's own extent; an intermediate one lives in the gap its
    // boundary already opened up.
    arr_h += rule_gap.items[0];
    arr_d += rule_gap.items[nrows];

    // 4. Column x origins (content-area starts) and the array advance.
    // The matrix family is amsmath's \env@matrix: \hskip -\arraycolsep
    // around the \array cancels the FIRST column's leading \arraycolsep
    // and the LAST column's trailing \arraycolsep — measured: the
    // pmatrix content is flush against the parens (the `a` sits exactly
    // at the paren box's right edge, 0pt gap), so the content origins
    // start at 0 and the effective array width drops one \arraycolsep.
    // array (bare \array, no wrapper): content x_i = acs + Σ_{j<i}
    // (2·acs + W_j), full width. cases: [content][quad] — content x_i =
    // Σ_{j<i} W_j (quad included in the widths). aligned: [content]
    // adjacent — x_0 = 0, x_1 = W_0.
    const amsmath_wrapped = kind != .cases and kind != .aligned and kind != .array;
    var col_origin: std.ArrayList(f32) = .empty;
    defer col_origin.deinit(list.gpa);
    var x: f32 = 0;
    if (kind == .aligned or kind == .cases) {
        for (0..ncols) |c| {
            // aligned: amsmath's \ialign preamble repeats every two
            // templates, with \tabskip\alignsep@ (= \minalignsep = 10pt, a
            // FIXED dimension) after template B — the gap lands BEFORE
            // columns 2, 4, ... (0-indexed). Measured on the XeTeX
            // reference (\showbox at 30pt): tabskip 10.0 between the
            // `= 1` and `b` columns, 0 between `a`-`=` and `b`-`=`, and
            // \math@cr@@@aligned's phantom \kern-\alignsep@ cancels the
            // TRAILING tabskip (no gap after the last column).
            if (kind == .aligned and c >= 2 and c % 2 == 0) x += 10.0;
            try col_origin.append(list.gpa, x);
            x += col_w.items[c];
        }
    } else if (amsmath_wrapped) {
        // The leading pad is cancelled by the outer -\arraycolsep.
        for (0..ncols) |c| {
            try col_origin.append(list.gpa, x);
            x += 2 * acs + col_w.items[c];
        }
    } else {
        for (0..ncols) |c| {
            try col_origin.append(list.gpa, x + acs);
            x += 2 * acs + col_w.items[c];
        }
    }
    // The matrix family: BOTH outer pads are cancelled — the leading one
    // by the leading -\arraycolsep (content 0 flush at the left edge) and
    // the trailing one by the trailing -\arraycolsep (the close delimiter
    // flush at the last content's advance+IC right edge — measured: the
    // 36pt pmatrix `)` sits exactly at the d box right = array − 2·acs).
    const arr_w = if (ncols > 0 and amsmath_wrapped) x - 2 * acs else x;

    // 5. Build the array vbox: per row, the row hbox places each cell at
    // its column x + alignment offset; array `|` rules (and a leading
    // rule) are drawn in every row at the boundary, spanning the row's
    // strut extent. The row hbox width = the array width (the \halign
    // stretches every row), and the array vbox stacks the rows with the
    // \vcenter shift.
    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var array_children: std.ArrayList(box.ChildRef) = .empty;
    defer array_children.deinit(list.gpa);
    for (0..nrows) |r| {
        const start = row_start.items[r];
        const end = if (r + 1 < nrows) row_start.items[r + 1] else @as(u32, @intCast(cells.items.len));
        var row_children: std.ArrayList(box.ChildRef) = .empty;
        defer row_children.deinit(list.gpa);
        for (start..end) |ci| {
            const c = ci - start;
            const cl = cells.items[ci];
            // Alignment within the column: matrix family centered; array
            // per the packed colspec (default centered); cases left;
            // aligned: EVEN columns right, ODD columns left (amsmath's
            // \ialign preamble cycles two templates — template A starts
            // \hfil\strut@$\displaystyle{##}$ (right-aligned), template B
            // $\displaystyle{{}##}$\hfil (left-aligned)).
            const off: f32 = if (kind == .aligned)
                (if (c % 2 == 0) col_w.items[c] - cl.w else 0)
            else if (kind == .cases)
                0
            else blk: {
                // The array colspec: `|` markers occupy spec slots but not
                // column slots — column c reads the c-th NON-rule nibble
                // (envColAlign), and the rules are emitted at the column
                // boundaries below. Beyond the spec, columns default to
                // centered (TeX).
                const spec = if (kind == .array) envColAlign(n.data, c) else null;
                const mode = spec orelse atom.EnvBits.col_c;
                break :blk switch (mode) {
                    atom.EnvBits.col_l => 0,
                    atom.EnvBits.col_r => col_w.items[c] - cl.w,
                    else => (col_w.items[c] - cl.w) / 2,
                };
            };
            var cx = col_origin.items[c] + off;
            if (cl.lead_w > 0) {
                // The aligned right part's leading ord-glue (see step 1).
                const g = try list.createLeaf(.glue, cl.lead_w, 0, 0, span);
                try row_children.append(list.gpa, .{ .idx = g, .x_shift = cx, .shift = 0 });
                cx += cl.lead_w;
            }
            try row_children.append(list.gpa, .{ .idx = cl.box, .x_shift = cx, .shift = 0 });
        }
        // array colspec `|` rules: a rule nibble at spec position i sits
        // at the boundary BEFORE the column that follows it (the count of
        // non-rule nibbles before i); a leading rule sits at the array's
        // left edge. Every row carries its own rule (TeX's template), so
        // the overlapping rules read as one continuous line spanning the
        // array. bx tracks the column-box boundary.
        if (kind == .array) {
            var col_count: usize = 0;
            var bx: f32 = 0;
            var spec_index: usize = 0;
            while (atom.envColSpec(n.data, spec_index)) |nib| : (spec_index += 1) {
                if (nib == atom.EnvBits.col_rule) {
                    const rule = try list.createLeaf(.rule, 0.4, row_h.items[r], row_d.items[r], span);
                    try row_children.append(list.gpa, .{ .idx = rule, .x_shift = bx - 0.2, .shift = 0 });
                } else {
                    if (col_count < ncols) bx += 2 * acs + col_w.items[col_count];
                    col_count += 1;
                }
            }
        }
        const row_box = try list.create(
            .hbox,
            arr_w,
            row_h.items[r],
            row_d.items[r],
            row_children.items,
            0,
            cstyle,
            0,
            span,
        );
        try array_children.append(list.gpa, .{ .idx = row_box, .x_shift = 0, .shift = row_shift.items[r] + shift_s });
    }
    // \hline: one rule per rule entry, at the boundary it sits on. A `.rule`
    // box paints [shift − height, shift], so `shift` is the rule's OWN bottom
    // edge. The space a boundary opened up is filled from its top edge
    // downward — each rule one \doublerulesep below the previous one's TOP —
    // which is the pitch the reference shows and what keeps two rules on one
    // boundary from painting over each other. The LAST rule of a boundary is
    // the one flush against the row below it, or, at the leading boundary,
    // against the first row's top edge.
    //
    // A `\hline` is `\noalign{\hrule}` (latex.ltx:16729), and a noalign rule
    // spans the WHOLE \halign width — the outer \arraycolsep pads included. The
    // matrix family's `\hskip -\arraycolsep` wrapper cancels those pads from
    // the ADVANCE only, so its rule overhangs the array box by \arraycolsep on
    // each side: measured on XeTeX at 20pt, `\begin{matrix}\hline a&b…` is a
    // 41.5402pt rule around a 31.5405pt box. array keeps its pads (cases and
    // aligned never had any), so those rules start flush at the left edge.
    // The rules are children of the array vbox, not of a row, so they never
    // enter the column count.
    const rule_x: f32 = if (amsmath_wrapped) -acs else 0;
    const rule_w: f32 = x;
    var above: usize = 0;
    var at_boundary: u32 = 0;
    for (entries.items) |e| {
        if (!e.rule) {
            above += 1;
            at_boundary = 0;
            continue;
        }
        const top: f32 = if (above == 0)
            // the leading boundary hangs above the first row
            row_shift.items[0] + shift_s - row_h.items[0] - rule_gap.items[0]
        else if (above == nrows)
            // the trailing boundary hangs below the last row
            row_shift.items[nrows - 1] + shift_s + row_d.items[nrows - 1]
        else
            // an interior boundary starts at the row above's bottom edge
            row_shift.items[above - 1] + shift_s + row_d.items[above - 1];
        const rule = try list.createLeaf(
            .rule,
            rule_w,
            hline_thickness,
            0,
            ast.span(e.node),
        );
        try array_children.append(list.gpa, .{
            .idx = rule,
            .x_shift = rule_x,
            .shift = top + @as(f32, @floatFromInt(at_boundary)) * doublerulesep_pt +
                hline_thickness,
        });
        at_boundary += 1;
    }
    const arr_box = try list.create(.vbox, arr_w, arr_h, arr_d, array_children.items, 0, cstyle, 0, span);

    // 6. The env box: [open, array, close] with the delimiters sized by
    // the variant ladder from the array's extent (like \left..\right) and
    // axis-centered; the array sits flush between them (the amsmath
    // -\arraycolsep pads cancel the array's edge pads, measured 0pt).
    const delta = @max(arr_h - axis, arr_d + axis);
    const minh_pt = @max(2 * delta * 0.901, 2 * delta - 5.0);
    const req_em = minh_pt / size_pt;
    const h_saved = list.scratch.items.len;
    defer list.scratch.items.len = h_saved;
    var bx: f32 = 0;
    var height: f32 = arr_h;
    var depth: f32 = arr_d;
    if (open_idx) |o| {
        const ob = try layoutDelimChar(list, ast, o, fm, req_em, 0, size_pt, cstyle);
        const b = list.get(ob);
        const sh = (b.height - b.depth) / 2 - axis;
        try list.scratch.append(list.gpa, .{ .idx = ob, .x_shift = bx, .shift = sh });
        bx += b.width;
        height = @max(height, b.height - sh);
        depth = @max(depth, b.depth + sh);
    }
    try list.scratch.append(list.gpa, .{ .idx = arr_box, .x_shift = bx, .shift = 0 });
    bx += arr_w;
    if (close_idx) |c| {
        const cb = try layoutDelimChar(list, ast, c, fm, req_em, 0, size_pt, cstyle);
        const b = list.get(cb);
        const sh = (b.height - b.depth) / 2 - axis;
        try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = bx, .shift = sh });
        bx += b.width;
        height = @max(height, b.height - sh);
        depth = @max(depth, b.depth + sh);
    }
    return list.create(.hbox, bx, height, depth, list.scratch.items[h_saved..], 0, cstyle, 0, span);
}

/// \left <delim> ... \right <delim> (atom `.left`, children [open?, inner,
/// close?]): lays out the inner row, then sizes the two delimiter glyphs
/// from their MATH-table size-VARIANT ladder (parenleft.v1..v7 etc.) so the
/// chosen variant's INK covers the inner's extent, and centers the variant
/// on the math axis — TeX make_delim, verified against XeTeX+unicode-math:
/// `\left( \frac{\partial L}{\partial \dot{q}} \right)` renders parens AT
/// THE BASE FONT SIZE using the variant glyphs (the ref draws parenleft.v6
/// — ink span 2.392em — at 39.85pt ≈ base size), with the content centered
/// between the variant boxes (measured: the fraction ink center sits 1.4pt
/// off the visible paren-gap center at 40pt, vs 20.6pt when the parens were
/// scaled to 101.3pt).
///   · required delimiter ink height (TeX make_delim — tex.web §1114,
///     MicroTeX FencedAtom): with δ = max(h − a, d + a),
///     ink ≥ max(2·δ·901/1000, 2·δ − shortfall), shortfall = 5pt;
///   · pick the SMALLEST variant whose ink (asc + desc) covers it (the
///     LARGEST when none does — TeX's "exceed if it can't match"); the
///     ladder's base entry covers a plain \left(x\right), byte-identical
///     to the un-stretched render;
///   · the box uses the selected variant or assembly's actual horizontal
///     advance and ink. SVG and CPU resolve the same request at the base size,
///     rather than thickening a scaled copy of the base drawing;
///   · delimiters without a variant ladder (e.g. \left\backslash) fall back
///     to the old continuous scaled-base path (layoutScaledChar); | \| /
///     now have ladders (divides/parallel/slash), so they pick real
///     variants too;
///   · \big \Big \bigg \Bigg (a `.left` node with a SINGLE delimiter child,
///     data = level 1..4) box the delimiter by the FIXED ladder entry
///     (layoutDelimLevel); \middle leaves inside the inner get rewritten
///     with the fence's size (sizeMiddleDelims).
/// amsmath `\binom`/`\genfrac-with-delims` sizes its `\left`/`\right`
/// delimiters by a FIXED fraction-delimiter rule, independent of the
/// numerator/denominator content (`\binom{1}{2}` == `\binom{n}{k}`): the
/// delimiters cover the STYLE's standard fraction box, not the ink teX's
/// content-`\left` floor reaches. Measured refs: a display `\binom{n}{k}`
/// draws parenleft.v6 (ink 2.392em — the exact variant the XeTeX/KaTeX/
/// MathJax refs draw; the content ink floor lands on v5, 2.092em), while a
/// text-style `\genfrac{(}{)}{0.8pt}{1}{x}{y}` draws the BASE paren
/// (1.094em ink, still v1). Return a req that selects the refs' variant —
/// v6 at display, the base paren at the smaller styles.
fn binomDelimReqEm(style: Style) f32 {
    return switch (style) {
        .display => ams_delim_req_display_em,
        .text, .script, .script_script => ams_delim_req_small_em,
    };
}

fn layoutLeftRight(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const gl = metrics.glue(fm);
    const axis = s(gl.axis_height, size_pt);

    // Children: [open?, inner, close?] — the delimiter leaves are `.char`,
    // the inner is the row parsed between \left and \right. `\left.` /
    // `\right.` (null delimiters) contribute no char. A \big/\Big/\bigg/
    // \Bigg node (data = level 1..4) has ONLY a single delimiter child and
    // no inner — a fixed ladder variant, not a stretched fence.
    var open_idx: ?u32 = null;
    var inner_idx: ?u32 = null;
    var close_idx: ?u32 = null;
    for (0..n.num_children) |i| {
        const c = ast.child(idx, i);
        if (ast.node(c).tag == .char) {
            if (inner_idx == null) open_idx = c else close_idx = c;
        } else inner_idx = c;
    }
    // Fixed-size delimiters: the \big family at its ladder level, centered
    // on the math axis (the reference draws \big( at parenleft.v1 with the
    // variant ink center ON the axis — measured 36pt above=0.297em /
    // below=0.797em of the baseline, exactly the v1 ink extents).
    if (inner_idx == null) {
        const level = n.data; // 1..4 (\big \Big \bigg \Bigg)
        const saved_len = list.scratch.items.len;
        defer list.scratch.items.len = saved_len;
        var x: f32 = 0;
        var height: f32 = 0;
        var depth: f32 = 0;
        if (open_idx) |o| {
            const ob = try layoutDelimLevel(list, ast, o, fm, level, size_pt, cstyle);
            const b = list.get(ob);
            const shift = (b.height - b.depth) / 2 - axis;
            try list.scratch.append(list.gpa, .{ .idx = ob, .x_shift = 0, .shift = shift });
            x += b.width;
            height = @max(height, b.height - shift);
            depth = @max(depth, b.depth + shift);
        }
        return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
    }

    const inner = try layoutInner(list, ast, inner_idx.?, fm, style, size_pt, cstyle, cramped);
    const ib = list.get(inner);

    // Required delimiter ink height (TeX make_delim — tex.web §1114 as
    // transcribed by MicroTeX FencedAtom): with δ = max(h − a, d + a) the
    // delimiter ink must be ≥ max(2·δ·901/1000, 2·δ − shortfall), shortfall
    // = 0.1em (TeX \delimitershortfall). Verified against the XeTeX ref of
    // `\left( \frac{\partial L}{\partial \dot{q}} \right)` at 40pt: this
    // floor is 87.0pt → parenleft.v6 (2.392em ink) — the exact variant the
    // reference draws (measured ink span 2.392em at its drawn size).
    const delta = @max(ib.height - axis, ib.depth + axis);
    const minh_pt = @max(2 * delta * 0.901, 2 * delta - 5.0);
    // amsc `\binom`/`\genfrac{..}{..}` (inner fraction marked fixed_delim):
    // amsc sizes the `\left(` `)` parens to its FIXED fraction-delimiter
    // rule, not TeX's content-`\left` delta — ztex's content floor
    // undershoots (parenleft.v5, ink 2.092em, vs the refs' v6 2.392em;
    // `\binom{1}{2}` == `\binom{n}{k}` — the rule is content-independent).
    const binom_fixed = ast.node(inner_idx.?).tag == .fraction and atom.fracFixedDelim(ast.node(inner_idx.?).data);
    // The fixed rule is STYLE-driven: a display `\binom` draws parenleft.v6
    // (2.392em), but a text-style `\genfrac{(}{)}{0.8pt}{1}{x}{y}` draws the
    // BASE paren (1.094em). \genfrac's style arg ({1} = text) governs the
    // delimiter even inside a display formula — take the fraction's FORCED
    // style, falling back to the outer style for `\binom` (which relaxes to
    // the current style).
    const fixed_style = if (binom_fixed)
        atom.fracForcedStyle(ast.node(inner_idx.?).data) orelse style
    else
        style;
    const req_em = if (binom_fixed) binomDelimReqEm(fixed_style) else (minh_pt / size_pt);

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var x: f32 = 0;
    var height: f32 = ib.height;
    var depth: f32 = ib.depth;
    // The FENCE delimiter boxes (chosen by req_em above), used to size any
    // \middle delimiters: TeXBook p.291 — "\middle gives a delimiter that is
    // as tall as the delimiters that \left and \right produce", so the
    // middle req comes from the FENCE's own box, NOT the content (measured
    // XeTeX `\left\{ x \middle| \frac{x}{2} \in S \right\}` at 36pt: the {
    // resolves braceleft.v4 (box 41.40/23.40) and the \middle| resolves
    // divides.v3 (ink 1.734em) — δ = max(41.40−9, 23.40+9) = 32.40 → req
    // 1.70em → v3; the content-derived req 1.772em would wrongly pick v4).
    var fence_asc: f32 = 0;
    var fence_desc: f32 = 0;
    // Each delimiter is centered on the math axis (baseline shift
    // (h−d)/2 − axis, the same axis formula as big-op glyphs; for the LM
    // variants asc−desc = 0.5em, so the shift is 0.25·size − axis = 0 — the
    // variant ink center sits ON the axis like the reference).
    if (open_idx) |o| {
        const fixed_req = if (binom_fixed) req_em else 0;
        const ob = try layoutDelimChar(list, ast, o, fm, req_em, fixed_req, size_pt, cstyle);
        const b = list.get(ob);
        fence_asc = b.height;
        fence_desc = b.depth;
        const shift = (b.height - b.depth) / 2 - axis;
        try list.scratch.append(list.gpa, .{ .idx = ob, .x_shift = x, .shift = shift });
        x += b.width;
        height = @max(height, b.height - shift);
        depth = @max(depth, b.depth + shift);
    }
    // \middle delimiters inside the inner: rewrite their zero-width
    // placeholder boxes in place with a req derived from the FENCE box (or
    // the content req when the pair has no delimiters — \left. ... \right.),
    // applied to the delimiter's OWN ladder. The returned extents bound the
    // hbox so the frame covers the middle's ink too.
    var mid_req_em = req_em;
    if (fence_asc > 0) {
        const fdelta = @max(fence_asc - axis, fence_desc + axis);
        mid_req_em = @max(2 * fdelta * 0.901, 2 * fdelta - 5.0) / size_pt;
    }
    const mid_ext = try sizeMiddleDelims(list, ast, inner, fm, mid_req_em, size_pt, cstyle);
    height = @max(height, mid_ext.asc_pt);
    depth = @max(depth, mid_ext.desc_pt);

    try list.scratch.append(list.gpa, .{ .idx = inner, .x_shift = x, .shift = 0 });
    x += list.get(inner).width;
    if (close_idx) |c| {
        const fixed_req = if (binom_fixed) req_em else 0;
        const cb = try layoutDelimChar(list, ast, c, fm, req_em, fixed_req, size_pt, cstyle);
        const b = list.get(cb);
        const shift = (b.height - b.depth) / 2 - axis;
        try list.scratch.append(list.gpa, .{ .idx = cb, .x_shift = x, .shift = shift });
        x += b.width;
        height = @max(height, b.height - shift);
        depth = @max(depth, b.depth + shift);
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

/// The box and both backends resolve the same MATH form or assembly request.
/// Delimiters without a ladder use the measured, continuously scaled base.
fn layoutDelimChar(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    req_em: f32,
    fixed_req: f32,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const cp = delimiterCp(ast, idx);
    if (metrics.delimVariants(cp)) |ladder| {
        var best_idx: usize = ladder.len - 1;
        var best = ladder[best_idx];
        for (ladder, 0..) |v, i| {
            if (v.asc + v.desc >= req_em) {
                best = v;
                best_idx = i;
                break;
            }
        }
        const box_idx = try list.create(
            .char,
            best.adv * size_pt,
            best.asc * size_pt,
            best.desc * size_pt,
            &.{},
            cp,
            .italic,
            size_pt,
            span,
        );
        const cd = list.charDataPtr(box_idx);
        if (n.data != 0) cd.synthetic = true;
        cd.delim_form = @intCast(best_idx);
        cd.delim_fixed = fixed_req;
        const largest_ink = ladder[ladder.len - 1].asc + ladder[ladder.len - 1].desc;
        if (req_em > largest_ink) cd.delim_req = req_em;
        try measureVerticalChar(list, fm, box_idx);
        return box_idx;
    }
    const ink = metrics.glyphInk(cp);
    const half = (ink.asc + ink.desc) / 2;
    const del_size = @max(size_pt, req_em * size_pt / (2 * half));
    return layoutScaledChar(list, ast, idx, fm, del_size, cstyle);
}

/// The codepoint a delimiter char leaf renders (node data override or the
/// source byte), like layoutChar.
fn delimiterCp(ast: *const atom.Ast, idx: u32) u21 {
    const n = ast.node(idx);
    if (n.data != 0) return @truncate(n.data);
    const sp = ast.span(idx);
    return firstCodepoint(ast.src[sp.start..sp.end]);
}

fn measureVerticalChar(list: *box.BoxList, fm: *const metrics.FontMetrics, idx: u32) !void {
    const cd = list.charData(idx);
    const geometry = try metrics.verticalGlyph(
        fm,
        cd.cp,
        cd.delim_form,
        cd.delim_req,
        cd.delim_fixed,
    ) orelse return;
    const b = &list.boxes.items[idx];
    b.width = geometry.advance_em * cd.size;
    b.height = geometry.ink.asc * cd.size;
    b.depth = geometry.ink.desc * cd.size;
    setCharOverhang(list, idx, geometry.ink, cd.size);
}

/// A delimiter without a MATH ladder, measured at its actual drawn size.
fn layoutScaledChar(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    glyph_size: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const cp: u21 = if (n.data != 0) @truncate(n.data) else firstCodepoint(ast.src[span.start..span.end]);
    const g = metrics.glyphAt(fm, cp, cstyle, glyph_size) orelse
        metrics.glyphEstimate(fm, cp, cstyle);
    const ink = metrics.glyphInk(cp);
    const box_idx = try list.create(
        .char,
        s(g.width, glyph_size),
        ink.asc * glyph_size,
        ink.desc * glyph_size,
        &.{},
        cp,
        cstyle,
        glyph_size,
        span,
    );
    if (n.data != 0) list.charDataPtr(box_idx).synthetic = true;
    setCharOverhang(list, box_idx, ink, glyph_size);
    return box_idx;
}

/// A \big/\Big/\bigg/\Bigg delimiter box: the FIXED ladder entry
/// `big_ladder_idx[level]` boxed at the base font size by its hmtx advance
/// and ink extents — the same box layoutDelimChar produces for a stretched
/// \left..\right delimiter, but at a fixed level instead of a required
/// height (measured XeTeX+unicode-math picks the SAME variant at 10/14/24/
/// 36pt because amsmath's \bBigg@ vcenter height scales with the size).
/// Codepoints without a variant ladder fall back to the continuous
/// scaled-base path sized so the glyph's ink reaches the level's target
/// (big_target_ink[level]).
fn layoutDelimLevel(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    level: u32,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const cp = delimiterCp(ast, idx);
    if (metrics.delimVariants(cp)) |ladder| {
        const best = ladder[big_ladder_idx[level]];
        const box_idx = try list.create(
            .char,
            best.adv * size_pt,
            best.asc * size_pt,
            best.desc * size_pt,
            &.{},
            cp,
            .italic,
            size_pt,
            span,
        );
        const cd = list.charDataPtr(box_idx);
        if (n.data != 0) cd.synthetic = true;
        cd.delim_form = @intCast(big_ladder_idx[level]);
        try measureVerticalChar(list, fm, box_idx);
        return box_idx;
    }
    // No variant ladder: scaled base glyph whose ink reaches the level's
    // target height (like layoutDelimChar's no-ladder fallback).
    const ink = metrics.glyphInk(cp);
    const half = (ink.asc + ink.desc) / 2;
    const gs = @max(size_pt, big_target_ink[level] * size_pt / (2 * half));
    return layoutScaledChar(list, ast, idx, fm, gs, cstyle);
}

/// Rewrite every \middle placeholder box inside `idx`'s subtree in place:
/// the zero-width box becomes the delimiter's SMALLEST MATH variant whose
/// ink covers the fence's required height `req_em` (the largest when none
/// does), boxed at the base font size — the exact rule layoutDelimChar
/// applies to the fence delimiters, but to the \middle delimiter's OWN
/// ladder (XeTeX `\left\{ x \middle| \frac{x}{2} \in S \right\}` at 36pt:
/// braceleft.v4 for the fence, divides.v3 for the |). Delimiters without a
/// ladder fall back to the continuous scaled-base path. Returns the largest
/// ink extents and reserves each middle's resolved width in its containing row.
fn sizeMiddleDelims(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    req_em: f32,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !struct { asc_pt: f32, desc_pt: f32, width_delta: f32 } {
    const b = &list.boxes.items[idx];
    if (b.kind == .char) {
        const cd = list.charDataPtr(idx);
        // A \middle placeholder: zero-width AND zero-height, delimiter cp.
        if (b.width == 0 and b.height == 0 and b.depth == 0 and cd.cp != 0) {
            if (metrics.delimVariants(cd.cp)) |ladder| {
                var best_idx: usize = ladder.len - 1;
                var best = ladder[best_idx];
                for (ladder, 0..) |v, i| {
                    if (v.asc + v.desc >= req_em) {
                        best = v;
                        best_idx = i;
                        break;
                    }
                }
                b.width = best.adv * size_pt;
                b.height = best.asc * size_pt;
                b.depth = best.desc * size_pt;
                cd.size = size_pt;
                cd.style = .italic;
                cd.delim_form = @intCast(best_idx);
                const largest = ladder[ladder.len - 1];
                if (req_em > largest.asc + largest.desc) cd.delim_req = req_em;
                try measureVerticalChar(list, fm, idx);
            } else {
                // No ladder: continuous scaled base (layoutDelimChar's
                // no-ladder fallback, with the same extent floor).
                const ink = metrics.glyphInk(cd.cp);
                const half = (ink.asc + ink.desc) / 2;
                const gs = @max(size_pt, req_em * size_pt / (2 * half));
                const g = metrics.glyphAt(fm, cd.cp, cd.style, gs) orelse
                    metrics.glyphEstimate(fm, cd.cp, cd.style);
                b.width = s(g.width, gs);
                b.height = ink.asc * gs;
                b.depth = ink.desc * gs;
                cd.size = gs;
                setCharOverhang(list, idx, ink, gs);
            }
            return .{ .asc_pt = b.height, .desc_pt = b.depth, .width_delta = b.width };
        }
        return .{ .asc_pt = 0, .desc_pt = 0, .width_delta = 0 };
    }
    var asc: f32 = 0;
    var desc: f32 = 0;
    const old_width = b.width;
    var added_width: f32 = 0;
    const children = list.childrefs.items[b.first_child .. b.first_child + b.num_children];
    for (children) |*cr| {
        if (b.kind == .hbox) cr.x_shift += added_width;
        const r = try sizeMiddleDelims(list, ast, cr.idx, fm, req_em, size_pt, cstyle);
        if (b.kind == .hbox) {
            added_width += r.width_delta;
        } else if (r.width_delta != 0) {
            b.width = @max(b.width, cr.x_shift + list.get(cr.idx).width);
        }
        asc = @max(asc, r.asc_pt - cr.shift);
        desc = @max(desc, r.desc_pt + cr.shift);
    }
    b.width += added_width;
    b.height = @max(b.height, asc);
    b.depth = @max(b.depth, desc);
    return .{ .asc_pt = asc, .desc_pt = desc, .width_delta = b.width - old_width };
}

/// \sqrt (a row marked `sqrt_row_data`; children [surd, radicand]): the TeX
/// radical construction — a √ glyph whose ink covers the radicand's extent,
/// plus the vinculum rule (the overbar) spanning the radicand's width at the
/// top. Matches XeTeX+unicode-math+LM Math (make_radical reading the MATH-
/// table gaps) and KaTeX:
///   · radicand set in cramped style (same size);
///   · clearance clr = RadicalDisplayStyleVerticalGap 0.148em in DISPLAY
///     style only, RadicalVerticalGap 0.05em in text/script/scriptscript —
///     the MATH table has no text-style gap of its own, and XeTeX reads the
///     display gap in display style ALONE (measured XeTeX \textstyle
///     \sqrt{\frac ab} at 20pt: the rule kerns 0.05em and the variant excess
///     above, clr 1.544pt; \displaystyle\sqrt{\frac ab}: 0.148em, clr
///     6.944pt);
///   · vinculum: a rule of thickness θ = rule_thickness at height
///     radicand_height + clr, spanning exactly the radicand's width;
///   · the radical glyph is drawn at the CURRENT font size (size_pt), NOT
///     scaled up. XeTeX selects the smallest MATH-table vertical variant
///     (radical.v1–v4) whose AdvanceMeasurement covers the radicand's full
///     extent (radicand_height + radicand_depth + clr + θ); the variant's
///     ink ascent (e.g. 1.45em for .v3) anchors at the vinculum's top and
///     its descent covers the radicand. The base glyph (AdvanceMeasurement
///     1.001em) is used for shallow radicands. Variants keep the width slim
///     (∼1em advance, ∼0.91em ink) while the height grows — the old code
///     scaled the base glyph to radicand_height + radicand_depth + clr + θ,
///     fattening it to ∼2em-wide ink.
///   · make_radical's clearance adjustment: the glyph box depth is replaced
///     by total−θ (the rule occupies the top θ of the ink); delta =
///     (total−θ) − (radicand_height + radicand_depth + clr), and half the
///     excess goes into the clearance. Tall variants add ~0.2em here,
///     floating the vinculum clear of the radicand and centering the radicand
///     on the radical. Past .v4 the extensible assembly gets NO such slack:
///     XeTeX sizes it to cover the radicand exactly (ink = radicand_height +
///     radicand_depth + clr, clr2 = clr), and every N+1 joint of the stack
///     overlaps by an equal share of the slack (the OpenType MATH assembly
///     rule), so the vertical advance never quantizes.
///   · the construction box: height = radicand_height + clr + 2θ (the empty
///     kern above the vinculum), depth = max(radicand_depth, total −
///     (radicand_height + clr + θ)).
///   · \sqrt[n]{x}: amsmath \r@@t sets the degree at 0.5×size, raises it by
///     RadicalDegreeBottomRaisePercent·(height − depth) of the construction
///     (its \raise .6\dimen@\copy\rootbox), brackets it with
///     RadicalKernBeforeDegree / RadicalKernAfterDegree at the CURRENT size
///     and lets it ride the radical's left shoulder: only the kern that does
///     not fit inside the radical's own advance widens the box.
fn layoutSqrt(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const span = ast.span(idx);
    const gl = metrics.glue(fm);
    const rt = s(gl.rule_thickness, size_pt);
    const clr: f32 = if (style == .display) 0.148 * size_pt else 0.05 * size_pt;

    // children: [surd, radicand]; a degree wraps the surd in a script node
    // (parser: \sqrt[n]{x} → script[surd, degree] with the SUP bit).
    const surd_child = ast.child(idx, 0);
    const radicand_child = ast.child(idx, 1);
    var surd_leaf = surd_child;
    var degree: ?u32 = null;
    if (ast.node(surd_child).tag == .script) {
        surd_leaf = ast.child(surd_child, 0);
        degree = ast.child(surd_child, 1);
    }

    const radicand = try layoutInner(list, ast, radicand_child, fm, style, size_pt, cstyle, true);
    const rb = list.get(radicand);
    const radicand_height = rb.height;
    const radicand_depth = rb.depth;

    // Height gate: only assemble (top + N*ext + bot pieces) when the required
    // radical ink height EXCEEDS the LARGEST pre-built MATH variant's
    // AdvanceMeasurement (radical.v4, 3.001em). Below this threshold XeTeX
    // selects the smallest variant covering the radicand (radical.v0–v4) — a
    // single glyph at the base math size with the variant's ink
    // extents. Pre-built variants give the "classic" look; the assembly is
    // only needed for genuinely tall stacks beyond what .v4 covers.
    const largest_variant_em: f32 = 3.001;
    const req_em = (radicand_height + radicand_depth + clr + rt) / size_pt;
    const vi = metrics.radicalVariant(req_em);
    const use_assembly = req_em > largest_variant_em;

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    const sn_surd = ast.node(surd_leaf);

    // Both forms anchor the glyph's ink top at rule_top.
    var radicand_x: f32 = undefined;
    var rad_ink_height: f32 = undefined;
    var rule_top: f32 = undefined;
    var clr2: f32 = undefined;
    var hbox_depth: f32 = undefined;
    var radical: u32 = undefined;

    if (!use_assembly) {
        // Variant path (shallow radicals).
        // Pre-built MATH variant (radical.v0–v4): a single √ char at the
        // current math size with the variant's adv/asc/desc — NOT scaled
        // up. The variant's ink ascent anchors at the vinculum top.
        const rv = metrics.radical_variants[vi];
        radicand_x = rv.adv * size_pt;
        rad_ink_height = (rv.asc + rv.desc) * size_pt;
        const delta_v = @max(
            0.0,
            rad_ink_height - rt - (radicand_height + radicand_depth + clr),
        );
        clr2 = clr + delta_v / 2;
        rule_top = radicand_height + clr2 + rt;
        hbox_depth = @max(radicand_depth, rad_ink_height - rule_top);

        const surd = try list.create(
            .char,
            rv.adv * size_pt,
            rv.asc * size_pt,
            rv.desc * size_pt,
            &.{},
            0x221A, // √ \surd
            .italic,
            size_pt,
            ast.span(surd_leaf),
        );
        radical = surd;
        if (sn_surd.data != 0) list.charDataPtr(surd).synthetic = true;
        list.charDataPtr(surd).radical_form = @intCast(vi);
        if (try metrics.verticalGlyph(fm, 0x221A, @intCast(vi + 1), 0, 0)) |geometry| {
            setCharOverhang(list, surd, geometry.ink, size_pt);
        }
        // glyph_baseline = rule_top − asc; shift = −glyph_baseline
        const glyph_baseline = rule_top - rv.asc * size_pt;
        try list.scratch.append(list.gpa, .{
            .idx = surd,
            .x_shift = 0,
            .shift = -glyph_baseline,
        });
    } else {
        // Match the radicand exactly; variant quantization adds no clearance.
        rad_ink_height = radicand_height + radicand_depth + clr;
        clr2 = clr;
        rule_top = radicand_height + clr + rt;
        hbox_depth = @max(radicand_depth, rad_ink_height - rule_top);

        // Keep every part in one glyph plan. Both backends then paint its
        // connector union once, including translucent scopes.
        const surd = try list.create(
            .char,
            metrics.radical_piece_adv * size_pt,
            rad_ink_height,
            0,
            &.{},
            0x221A,
            .italic,
            size_pt,
            ast.span(surd_leaf),
        );
        radical = surd;
        const cd = list.charDataPtr(surd);
        if (sn_surd.data != 0) cd.synthetic = true;
        cd.delim_req = rad_ink_height / size_pt;
        try measureVerticalChar(list, fm, surd);
        const sb = list.get(surd);
        radicand_x = sb.width;
        try list.scratch.append(list.gpa, .{
            .idx = surd,
            .x_shift = 0,
            .shift = sb.height - rule_top,
        });
    }

    // Radicand: flush at x = surd advance; baseline = row baseline (shift 0).
    try list.scratch.append(list.gpa, .{ .idx = radicand, .x_shift = radicand_x, .shift = 0 });
    if (rb.width > 0) {
        list.charDataPtr(radical).radical_bar = .{
            .x = radicand_x,
            .y = -list.get(radical).height,
            .w = rb.width,
            .h = rt,
        };
    }
    // The construction's height = vinculum top + rt: XeTeX's overbar is
    // [kern rt, rule rt, kern clr2, radicand], the empty kern above the rule
    // part of the box extent (measured \sqrt{x}: 25.485 = 13.26 + 9.825 +
    // 2·1.2). The degree raise (amsmath \r@@t) reads this height.
    var height = rule_top + rt;
    var width = radicand_x + rb.width;
    if (degree) |d| {
        // amsmath brackets the scriptscript index with MATH degree kerns.
        // LuaLaTeX evaluates them at the CURRENT size (the index sits
        // 0.278em right of the radical's own origin at 20pt and 60pt
        // alike); the old 10pt-based product was 0.139em here. The static
        // fallback carries the same em value scaled to the size.
        const mc = gl.math_constants;
        const kern_before: f32 = if (mc) |m| m.radical_kern_before_degree * size_pt else 0.278 * size_pt;
        const kern_after: f32 = if (mc) |m| m.radical_kern_after_degree * size_pt else -0.556 * size_pt;
        const deg_size = size_pt * gl.scriptscriptfactor;
        const db = try layoutInner(list, ast, d, fm, .script_script, deg_size, cstyle, true);
        const gb = list.get(db);
        // The index rides the radical's left shoulder: only the kern that
        // does not fit inside the radical's own advance widens the box.
        const over = @max(0.0, kern_before + gb.width + kern_after - radicand_x);
        for (list.scratch.items[saved_len..]) |*child| child.x_shift += over;
        width += over;
        // amsmath raises the degree from the construction's ht-dp.
        const raise_pct: f32 = if (mc) |m| m.radical_degree_bottom_raise_percent else 0.6;
        const raise = raise_pct * (height - hbox_depth);
        try list.scratch.append(list.gpa, .{ .idx = db, .x_shift = kern_before, .shift = -raise });
        height = @max(height, raise + gb.height);
    }
    return list.create(
        .hbox,
        width,
        height,
        hbox_depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// Italic-correction advance appended after a big-op atom (see layoutRow).
/// TeX appends the op's italic correction as a kern when the op has no
/// subscript (tex.web mlist_to_hlist: "if math_type(subscr)=empty and
/// delta≠0 then append new_kern(delta)"). With XeTeX+unicode-math the
/// measured post-op advances at 10pt are:
///   display \int x:   x at 11.606pt = 0.665em box + 0.334em + thin
///                     (the display .v1 variant advance 0.999em MINUS the
///                     base advance — measured bare \displaystyle\int x);
///   display \sum x:   x at 16.040pt = 1.444em box + thin (no tail);
///   text \int x:      x at 8.285pt = 0.665em box + thin (no tail).
/// So only a bare DISPLAY nolimits op (∫/∮) carries the variant-advance
/// tail; everything else — including every scripted op (the script box
/// already attaches at the variant advance) — has none. The old
/// base-ic tail (3.32pt for every ∫) over-counted text and under-counted
/// display by the variant-vs-base advance difference.
fn opTailIc(
    ast: *const atom.Ast,
    idx: u32,
    style: Style,
    size_pt: f32,
) f32 {
    const n = ast.node(idx);
    if (n.tag == .op) {
        if (style != .display) return 0;
        // \limits on a bare display op: the limits vbox takes over, so no
        // beside italic tail (TeX appends delta only when the op is NOT
        // limits). \displaylimits/\nolimits keep the default/beside tail.
        if ((n.data & atom.LimitsBits.mask) == atom.LimitsBits.force) return 0;
        const op: atom.BigOp = @fromBackingInt(@intCast(n.data & atom.LimitsBits.value_mask));
        if (bigOpLimits(op)) return 0;
        const base_adv = metrics.bigOpInk(op, false).advance;
        const disp_adv = metrics.bigOpInk(op, true).disp_advance;
        return s((disp_adv - base_adv) * 10.0, size_pt);
    }
    return 0;
}

fn layoutScript(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const has_sup = (n.data & atom.ScriptBits.sup) != 0;
    const has_sub = (n.data & atom.ScriptBits.sub) != 0;
    // children are [base, sup?, sub?]; sub-only → sub is child 1
    const base_idx = ast.child(idx, 0);
    const sup_idx = if (has_sup) ast.child(idx, 1) else null;
    const sub_idx = if (has_sub) (if (has_sup) ast.child(idx, 2) else ast.child(idx, 1)) else null;
    const base_u = unwrapAtom(ast, base_idx);
    const base_u_atom = ast.node(base_u);
    const is_op_base = base_u_atom.tag == .op;

    // Limits decision. \limits / \nolimits / \displaylimits set override
    // bits on the op/opname node's data (atom.LimitsBits); they win over
    // the per-op default:
    //   \limits        → over/under in display AND text styles (TeX applies
    //                    \limits in both), e.g. \int\limits_0^1 x;
    //   \nolimits      → beside scripts in every style, e.g.
    //                    \sum\nolimits_{i=1}^{n} x_i;
    //   \displaylimits → the op's default (big-op family → limits in
    //                    display style; int family → beside; operator words
    //                    → limits only for the limit-taking set).
    // Otherwise: big operators and limit-taking operator words (\lim \max
    // \min ...; parser tags them with a nonzero opname data) take
    // over/under limits in display style only — \lim_{x \to 0} puts "x→0"
    // under the word, centered, the TeX \mathop-with-limits behavior
    // (XeTeX: the under-limit row sits max(bigop2, bigop4 − sub.height)
    // below the word, centered on it). \int/\oint default to \intop\nolimits
    // (fontmath.ltx): beside scripts in every style.
    const op_bits = base_u_atom.data & atom.LimitsBits.mask;
    const forced_limits = op_bits == atom.LimitsBits.force;
    const forced_beside = op_bits == atom.LimitsBits.force_beside;
    const default_limits = if (base_u_atom.tag == .op)
        bigOpLimits(@fromBackingInt(@intCast(base_u_atom.data & atom.LimitsBits.value_mask)))
    else if (base_u_atom.tag == .opname)
        (base_u_atom.data & atom.LimitsBits.value_mask) != 0
    else
        false;
    if (!forced_beside and (forced_limits or (style == .display and default_limits))) {
        const base = try layoutInner(list, ast, base_idx, fm, style, size_pt, cstyle, cramped);
        return layoutOpLimits(list, ast, base, sup_idx, sub_idx, fm, size_pt, span, cramped);
    }

    const base = try layoutInner(list, ast, base_idx, fm, style, size_pt, cstyle, cramped);
    const bb = list.get(base);
    const gl = metrics.glue(fm);

    // Scripts are set one style level down (tex.web sup_style/sub_style).
    // The SIZES are root-relative, not multiplicative: 10pt → 7pt → 5pt
    // (XeTeX \showbox: the 2 in x_{y^2} and the 3 in x_{y_{2_3}} are both
    // cmr/m/n/5 — a script of a scriptscript stays scriptscript). So the
    // size step depends on the CURRENT level: display/text → size×0.7,
    // script → size×(0.5/0.7), scriptscript → size×1.0. The old
    // size×factor formula double-applied the factor (7×0.5 = 3.5pt).
    const s_style: Style = if (style == .display or style == .text) .script else .script_script;
    const s_size = switch (style) {
        .display, .text => size_pt * gl.scriptfactor,
        .script => size_pt * (gl.scriptscriptfactor / gl.scriptfactor),
        .script_script => size_pt,
    };
    const x_height = s(gl.x_height, size_pt);
    const rt = s(gl.rule_thickness, size_pt);
    // Script horizontal placement (TeX make_scripts, tex.web): the
    // superscript starts at the base's right edge plus the base's italic
    // correction, the subscript at the base's right edge — no leading
    // SCRIPT_SPACE (measured: x^2 / x_2 scripts sit at exactly w_base,
    // ztex's 0.5pt gap put them 0.52pt too far right). TeX's scriptspace
    // (0.5pt) instead pads AFTER the script box, so the box width includes
    // it (measured x^2 → '+' advance).
    var sup_ic: f32 = 0;
    var sub_ic: f32 = 0;
    if (bb.kind == .char) {
        if (is_op_base) {
            // A big operator's beside scripts attach at the op's ADVANCE
            // (measured with XeTeX+unicode-math at 10pt, kept for display):
            //   display \int_0^1: sup at 0.999em (the .v1 display-variant
            //                     advance), sub at 0.999 − 0.591 = 0.408em
            //                     (the .v1 MathItalicsCorrection).
            // NON-display ops (the base form) follow XeTeX's text-op rule:
            // sup at the base advance, sub at advance − base ic (∫ 0.665 /
            // 0.333em — see below).
            // The text ∑ (ic 0) puts both scripts at the advance 1.056em.
            const op: atom.BigOp = @fromBackingInt(@intCast(base_u_atom.data & atom.LimitsBits.value_mask));
            const ink = metrics.bigOpInk(op, style == .display);
            if (style == .display and !bigOpLimits(op)) {
                const base_adv = metrics.bigOpInk(op, false).advance;
                // display-variant advance − base advance (0.334em for ∫)
                const attach = (ink.disp_advance - base_adv) * 10.0;
                sup_ic = s(attach, size_pt);
                // variant advance − variant italic − base advance
                sub_ic = s(attach - ink.ic, size_pt);
            } else {
                // Non-display (text/script) op, base form — XeTeX's actual
                // text-op beside rule (measured XeTeX+unicode-math at 10pt
                // and 30pt): the superscript attaches at the base ADVANCE
                // (0.665em for ∫), the subscript at advance − the base
                // italic correction (0.665 − 0.332 = 0.333em) — TeX tucks
                // the subscript in by the glyph's lean. The earlier fix had
                // them SWAPPED (sub at the advance, sup at advance + ic =
                // 0.997em). Ops with ic 0 (∑ ∏ ⋃) put both scripts at the
                // advance 1.056em — unchanged by this rule.
                sup_ic = 0;
                sub_ic = -s(ink.ic, size_pt);
            }
        } else {
            // Ordinary char bases: the italic correction scales with the
            // current size like the letter font itself. XeTeX's OT math
            // folds a per-letter slant into the char box (measured x box
            // 0.572em at 10pt vs the 0.528em hmtx advance — the box carries
            // the italic); the superscript lands at the box edge plus this
            // correction (measured x^2 sup at 5.719pt = box 5.28 + 0.44).
            // Our box keeps the raw advance, so the sup gap approximates
            // the slant with the glyph's own italic correction: the DRAWN
            // glyph's OpenType MATH value when the active face supplies one
            // (the same number the reference engine reads, so `x^2` really
            // lands at advance + ic x size), and the metric table's row
            // otherwise.
            const base_cd = list.charData(base);
            const g = metrics.glyphAt(fm, base_cd.cp, base_cd.style, size_pt) orelse
                metrics.glyphEstimate(fm, base_cd.cp, base_cd.style);
            sup_ic = s(
                metrics.fontItalicCorrection(fm, base_cd.cp, base_cd.style) orelse g.italic_correction,
                size_pt,
            );
        }
    }
    const sup_gap = sup_ic;
    const sub_gap = sub_ic;
    const script_space = 0.5; // TeX \scriptspace: fixed 0.5pt, not em-scaled

    // A scripted big operator with BESIDE scripts is axis-centered at EVERY
    // style: make_op sets the op box's shift_amount to (h−d)/2 − axis for
    // any op (display \intop\nolimits keeps it, text and script ops too).
    // The script raises/drops below are computed from the SHIFTED
    // dimensions (height − shift, depth + shift) — exactly what tex.web
    // make_scripts sees after hpack absorbs the box's shift_amount. The box
    // h/d are the drawn glyph's ink (metrics.bigOpInk × size_pt), so at 10pt a
    // display ∫ (gs 10) gives base_h 8.05 / base_d 3.06 and the shift
    // (8.05−3.06)/2 − 2.5 ≈ 0 — the ink center sits on the math axis at
    // every style, the XeTeX-LMMath \showbox numbers.
    const axis = s(gl.axis_height, size_pt);
    const base_shift = if (is_op_base) (bb.height - bb.depth) / 2 - axis else 0;
    const base_h = bb.height - base_shift; // shifted top above the row baseline
    const base_d = bb.depth + base_shift; // shifted bottom below the row baseline

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    try list.scratch.append(list.gpa, .{ .idx = base, .x_shift = 0, .shift = base_shift });
    var width = bb.width;
    var height = base_h;
    var depth = base_d;

    // TeX make_scripts: a CHAR nucleus (incl. ligatures, \mathbf) starts
    // shift_up/shift_down at 0 — only the sup1|sup2|sup3 / sub1|sub2 and
    // x-height floors apply (verified: b^2 sup = sup2 3.62892, NOT
    // 6.94445 − sup_drop). A BOX nucleus (op, fraction, braced list,
    // \left..\right) starts from height − sup_drop / depth + sub_drop with
    // the SCRIPT-SIZE symbol font's parameters: cmsy7's sup_drop is
    // 2.4722pt (tftopl SUPDROP 0.353171 em × 7) and cmsy5's is 2.47223 —
    // NOT the 10pt 3.86108 (audit-scripts residual #3; the audit's
    // "2.88889" is cmsy10's SUP3, not sup_drop).
    // A CHAR nucleus (incl. an ACCENT base) starts shift_up/shift_down at 0
    // — only the sup1|sup2|sup3 / sub1|sub2 floors apply. \hat{A}^{\dagger}
    // is parsed by XeTeX as the hat over A^{\dagger}: the dagger scripts
    // on the BARE char, so its raise is the char floor (sup1 3.63em =
    // 10.89pt at 30pt), NOT the accent-box height (inflated by the hat on
    // top → ~25pt, the "dagger sits too high" defect). Treat an accent row
    // as a char nucleus for the script floors.
    const is_accent_base = base_u_atom.tag == .row and base_u_atom.data == accent_row_data;
    const base_is_char = base_u_atom.tag == .char or is_accent_base;
    // sup_drop/sub_drop for a BOX base (op, fraction, braced list,
    // \left..\right): TeX reads \fontdimen20/21 of family 2; XeTeX+LM uses
    // the MATH-table baseline-drop constants at the SCRIPT size — measured
    // \int_0^1 sup raise 11.860 = base_h 13.611 − 1.75 and sub drop 10.008 =
    // base_d 8.611 + 1.40 at 10pt (display ∫ drawn with the .v1 display
    // variant: asc 1.361em, desc 0.861em), and the text-style ∫/∑ probes
    // confirm the same drops (6.301 = 8.051 − 1.75, 5.749 = 7.501 − 1.75).
    // SuperscriptBaselineDropMax 0.25em / SubscriptBaselineDropMin 0.20em,
    // evaluated at the script size (× 0.7), so the 10pt-base values are
    // gl.supdrop/gl.subdrop (1.75/1.40) and they scale with size_pt like
    // the other em-relative parameters. The old constants 2.4722/0.5
    // (cmsy7 supdrop/subdrop) left the ∫ scripts ~1.2pt too tight at 10pt.
    const supdrop = s(gl.supdrop, size_pt);
    const subdrop = s(gl.subdrop, size_pt);
    const sym = symFor(fm);

    // Superscript raise: max(shift_up0, sup1|sup2|sup3, sup.depth +
    // x_height/4) with the floor from the CURRENT style's symbol font
    // (sup3 in cramped styles — fraction denominators, subscripts).
    var sup: ?u32 = null;
    var sup_depth: f32 = 0;
    var sup_op_shift: f32 = 0;
    var shift_up: f32 = 0;
    if (sup_idx != null) {
        // sup_style: cramped iff the current style is cramped.
        const sc = try layoutInner(list, ast, sup_idx.?, fm, s_style, s_size, cstyle, cramped);
        const sb = list.get(sc);
        sup = sc;
        // A bare op as the script content carries its own axis shift (make_op,
        // axis at the script size); fold it in so the glyph hangs off the
        // shifted box and the floors measure the shifted dimensions.
        if (ast.node(unwrapAtom(ast, sup_idx.?)).tag == .op) {
            sup_op_shift = (sb.height - sb.depth) / 2 - s(gl.axis_height, s_size);
        }
        sup_depth = sb.depth + sup_op_shift;
        // Superscript floor: KaTeX's sup1 (0.413em) for OPERATOR WORDS —
        // the measured \sin^2/\cos^2 placement; sup1|sup2|sup3 from the
        // current style's symbol font otherwise (sup3 in cramped styles).
        const is_opname_base = base_u_atom.tag == .opname;
        const sup_floor: f32 = if (is_opname_base)
            s(4.13, size_pt) // KaTeX fontMetrics sup1 (display floor)
        else if (cramped) s(sym.sup3, size_pt) else if (style == .display)
            s(sym.sup1, size_pt)
        else
            s(sym.sup2, size_pt);
        // Raise above the base: TeX's height − sup_drop for a BOX base, but
        // OPERATOR WORDS use KaTeX's rule — word_height − (supDrop at the
        // script size: 0.353em × 0.7 = 0.2471em) — which lands on the
        // 0.413em floor for x-height words, so \sin^2 and \cos^2 raise the
        // '2' to nearly the same height. TeX's height − sup_drop let the
        // dot of the 'i' in \sin dominate (17.36pt at 36pt vs KaTeX 15.15)
        // while \cos^2 fell to the 13.07pt sup2 floor (KaTeX 14.87) — the
        // "different heights & offsets" defect. Measured at 36pt vs KaTeX:
        // sin^2 raise 14.87pt (Δ 0.28), cos^2 14.87pt (Δ 0.00).
        const sup_base: f32 = if (base_is_char) 0 else if (is_opname_base)
            base_h - s(2.471, size_pt)
        else
            base_h - supdrop;
        shift_up = @max(@max(sup_base, sup_floor), sup_depth + x_height / 4);
    }
    // Subscript drop: max(shift_down0, sub1|sub2, sub.height − 0.8·x_height
    // for sub-only). sub2 when both scripts are present; the sub content is
    // always cramped (sub_style = smaller + cramped).
    var sub: ?u32 = null;
    var sub_height: f32 = 0;
    var sub_op_shift: f32 = 0;
    var shift_down: f32 = 0;
    if (sub_idx != null) {
        const sc = try layoutInner(list, ast, sub_idx.?, fm, s_style, s_size, cstyle, true);
        const sb = list.get(sc);
        sub = sc;
        if (ast.node(unwrapAtom(ast, sub_idx.?)).tag == .op) {
            sub_op_shift = (sb.height - sb.depth) / 2 - s(gl.axis_height, s_size);
        }
        sub_height = sb.height - sub_op_shift;
        const sub_base: f32 = if (base_is_char) 0 else base_d + subdrop;
        if (sup_idx != null) {
            shift_down = @max(sub_base, s(sym.sub2, size_pt));
        } else {
            shift_down = @max(
                @max(sub_base, s(sym.sub1, size_pt)),
                sub_height - 0.8 * x_height,
            );
        }
    }
    // When both scripts are present, keep at least 4·rule-thickness between
    // the superscript bottom and the subscript top (XeTeX make_scripts).
    // TeX LOWERs the subscript to gain the clearance (not raising the
    // superscript), then — ONLY inside the guard — applies the 0.8·x-height
    // refinement (raise sup by psi, lower sub by psi). Verified on x_i^j:
    // shift_up 4.80555, shift_down 2.7875, final interspace = 4·rt.
    if (sup != null and sub != null) {
        const interspace = shift_up - sup_depth + shift_down - sub_height;
        if (interspace < 4 * rt) {
            shift_down += 4 * rt - interspace;
            const psi = 0.8 * x_height - (shift_up - sup_depth);
            if (psi > 0) {
                shift_up += psi;
                shift_down -= psi;
            }
        }
    }
    if (sup) |supb| {
        const sb = list.get(supb);
        try list.scratch.append(list.gpa, .{
            .idx = supb,
            .x_shift = bb.width + sup_gap,
            .shift = -(shift_up - sup_op_shift),
        });
        width = @max(width, bb.width + sup_gap + sb.width + script_space);
        height = @max(height, shift_up + (sb.height - sup_op_shift));
    }
    if (sub) |subb| {
        const sb = list.get(subb);
        try list.scratch.append(list.gpa, .{
            .idx = subb,
            .x_shift = bb.width + sub_gap,
            .shift = shift_down + sub_op_shift,
        });
        width = @max(width, bb.width + sub_gap + sb.width + script_space);
        depth = @max(depth, shift_down + (sb.depth + sub_op_shift));
    }
    return list.create(
        .script,
        width,
        height,
        depth,
        list.scratch.items[saved_len..],
        0,
        cstyle,
        0,
        span,
    );
}

/// A big operator with limits: a vbox with the operator centered on the
/// axis, the superscript above and the subscript below. Gaps follow the
/// TeX big-op parameters (MicroTeX BigOperatorAtom::createLimits):
/// under-gap k = max(bigop2, bigop4 − sub.height), over-gap kern =
/// max(bigop1, bigop3 − over.depth), bigop5 outer padding.
fn layoutOpLimits(
    list: *box.BoxList,
    ast: *const atom.Ast,
    base: u32,
    sup_idx: ?u32,
    sub_idx: ?u32,
    fm: *const metrics.FontMetrics,
    size_pt: f32,
    span: atom.Span,
    cramped: bool,
) !u32 {
    const bb = list.get(base);
    const bcd = list.charData(base);
    const gl = metrics.glue(fm);
    // The big-op spacing params are the OpenType MATH-table constants of the
    // math font (UpperLimitGapMin 0.20em, LowerLimitGapMin 0.167em,
    // UpperLimitBaselineRiseMin 0.111em, LowerLimitBaselineDropMax 0.60em,
    // all ×10 for the 10pt base) — em-relative, so they scale LINEARLY with
    // size_pt (measured on `\sum_{i=1}^{n} x_i` in XeTeX+unicode-math: the
    // over-limit kern is 2.02pt at 10pt, 4.05pt at 20pt, 9.71pt at 48pt —
    // exactly bigop1 × size/10; the old cmex10 fontdimens were fixed at the
    // 10pt design size for every math size, but with Latin Modern Math the
    // limits gaps come from the MATH table and scale). The axis (family 2)
    // scales normally. The op's ITALIC correction is also em-relative
    // (XeTeX-LM: post-∫ kern 3.32pt at 10pt, 6.64pt at 20pt).

    // TeX skews the two limit rows horizontally (tex.web make_op limits
    // construction): the over-limit shifts right by half the operator's
    // italic correction, the under-limit left by the same amount. The
    // delta is the italic correction of the DRAWN form: the .v1 display
    // variant's ic for display ops (∫/∮ 0.591em — measured XeTeX: the
    // display-∫ limits skew ±0.2955em, i.e. the limits center on
    // vbox_c ± .v1 ic/2), the base glyph's ic for text/script ops (∫/∮
    // 0.332em — the verified text-∫ y sits 4.97pt right of the ink
    // center). ∑ has no italic in either form, so its limits stay
    // centered (verified: ∑ limits are centered on the display box to
    // 0.05pt).
    const axis = s(gl.axis_height, size_pt);
    const bigop5 = gl.bigop_spacing5;
    const variant = bcd.bigop_form == .variant;
    const delta = if (variant)
        s(bcd.disp_ic, size_pt)
    else if (bigOpByCp(bcd.cp)) |op|
        // Text/script ops: the BASE glyph's italic correction (∫/∮ 3.32 —
        // metrics.bigOpInk is the single source for every big-op advance/ic).
        s(metrics.bigOpInk(op, false).ic, size_pt)
    else
        0;

    // A big-operator GLYPH is centered on the axis (MicroTeX
    // SymbolAtom::createBox big-op branch: y-down shift = (h−d)/2 − axis; the
    // ink box is built axis-centered, so the shift is small). An OPERATOR
    // WORD base (a row box, e.g. "lim") stays on the baseline: XeTeX
    // \showbox of `\lim_{x\to 0} x` places the "lim" row at shift 0 inside
    // the limits vbox — the word ink center sits ~(h−d)/2 above the baseline
    // while the under-limit hangs below, so the vbox shift clamps to 0.
    const op_shift = if (bb.kind == .char) (bb.height - bb.depth) / 2 - axis else 0;
    const op_top = op_shift - bb.height;
    const op_bottom = op_shift + bb.depth;

    const s_style: Style = .script;
    const s_size = size_pt * gl.scriptfactor;

    var sup_box: ?u32 = null;
    var sup_w: f32 = 0;
    var sup_h: f32 = 0;
    var sup_d: f32 = 0;
    if (sup_idx) |c| {
        // sup_style: cramped iff the base style is cramped.
        const b = try layoutInner(list, ast, c, fm, s_style, s_size, .italic, cramped);
        const gb = list.get(b);
        sup_box = b;
        sup_w = gb.width;
        sup_h = gb.height;
        sup_d = gb.depth;
    }
    var sub_box: ?u32 = null;
    var sub_w: f32 = 0;
    var sub_h: f32 = 0;
    var sub_d: f32 = 0;
    if (sub_idx) |c| {
        // sub_style is always cramped.
        const b = try layoutInner(list, ast, c, fm, s_style, s_size, .italic, true);
        const gb = list.get(b);
        sub_box = b;
        sub_w = gb.width;
        sub_h = gb.height;
        sub_d = gb.depth;
    }
    // A DISPLAY big-op boxes by its .v1 VARIANT advance (XeTeX boxes the
    // display ∫/∮ mathop by 0.999em, not the base 0.665em: the drawn .v1
    // ink spans [0.056, 0.943]em of that box, so a 0.665em vbox would let
    // the ∫ tail overlap the next term — XeTeX clears the following '3' by
    // 7.9pt at 30pt, the old code overlapped by 2.08pt). The op sits at
    // (vbox_w − variant box)/2 — 0 when the limits are narrower, so the
    // glyph origin = the box origin and the drawn ink matches XeTeX's
    // position exactly; with limits wider than the variant advance XeTeX
    // CENTERS the variant-advance box (measured on
    // \sum_{i=1}^{100000} at 30pt: the ∑ box shifts (62.765−43.158)/2).
    // Text/script ops keep the base-advance box and the same centering.
    const op_w = if (variant) bcd.disp_advance * size_pt else bb.width;
    const vbox_w = @max(op_w, @max(sup_w, sub_w));

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var height = -op_top;
    var depth = op_bottom;
    if (sup_box) |supb| {
        const kern = @max(s(gl.bigop_spacing1, size_pt), s(gl.bigop_spacing3, size_pt) - sup_d);
        try list.scratch.append(list.gpa, .{
            .idx = supb,
            .x_shift = (vbox_w - sup_w) / 2 + delta / 2,
            .shift = op_top - kern - sup_d,
        });
        height = -op_top + kern + sup_h + sup_d + bigop5;
    }
    try list.scratch.append(list.gpa, .{
        .idx = base,
        .x_shift = (vbox_w - op_w) / 2,
        .shift = op_shift,
    });
    if (sub_box) |subb| {
        const k = @max(s(gl.bigop_spacing2, size_pt), s(gl.bigop_spacing4, size_pt) - sub_h);
        try list.scratch.append(list.gpa, .{
            .idx = subb,
            .x_shift = (vbox_w - sub_w) / 2 - delta / 2,
            .shift = op_bottom + k + sub_h,
        });
        depth = op_bottom + k + sub_h + sub_d + bigop5;
    }
    return list.create(.vbox, vbox_w, height, depth, list.scratch.items[saved_len..], 0, .italic, 0, span);
}

/// The Unicode codepoint rendered for a big operator.
fn bigOpCodepoint(op: atom.BigOp) u21 {
    return switch (op) {
        .sum => 0x2211, // ∑
        .int => 0x222B, // ∫
        .prod => 0x220F, // ∏
        .coprod => 0x2210, // ∐
        .bigcup => 0x22C3, // ⋃
        .bigcap => 0x22C2, // ⋂
        .bigsqcup => 0x2A06, // ⨆
        .oint => 0x222E, // ∮
        .oiint => 0x222F, // ∯
        .oiiint => 0x2230, // ∰
        .ointctrclockwise => 0x222E, // ∮ (contourintegral)
        // the \bigXXX n-ary family + \bigstar (amsmath's \slimits@ group;
        // KaTeX classes the same glyphs as `op`)
        .bigodot => 0x2A00, // ⨀
        .bigoplus => 0x2A01, // ⨁
        .bigotimes => 0x2A02, // ⨂
        .biguplus => 0x2A04, // ⨄
        .bigsqcap => 0x2A05, // ⨅
        .bigwedge => 0x22C0, // ⋀
        .bigvee => 0x22C1, // ⋁
        .bigstar => 0x22C6, // ⋆
        // The BIG integrals: no single big-integral codepoint exists in
        // Unicode, so they draw the ordinary integral signs scaled up (see
        // bigOpScale).
        .bigint => 0x222B, // ∫
        .bigiint => 0x222C, // ∬
        .bigiiint => 0x222D, // ∭
    };
}

/// The big-operator enum for a big-op codepoint (the inverse of
/// `bigOpCodepoint`); null for any other glyph.
fn bigOpByCp(cp: u21) ?atom.BigOp {
    return switch (cp) {
        0x2211 => .sum,
        0x222B => .int,
        0x220F => .prod,
        0x2210 => .coprod,
        0x22C3 => .bigcup,
        0x22C2 => .bigcap,
        0x2A06 => .bigsqcup,
        0x222E => .oint,
        0x222F => .oiint,
        0x2230 => .oiiint,
        0x2A11 => .ointctrclockwise,
        0x2A00 => .bigodot,
        0x2A01 => .bigoplus,
        0x2A02 => .bigotimes,
        0x2A04 => .biguplus,
        0x2A05 => .bigsqcap,
        0x22C0 => .bigwedge,
        0x22C1 => .bigvee,
        0x22C6 => .bigstar,
        // The big integrals are NOT listed: they share \int / \oiint /
        // \oiiint's codepoints (only the drawn size differs), so the map
        // from codepoint to operator is not injective and the plain integral
        // is the canonical answer.
        else => null,
    };
}

/// Whether a big operator takes display-style over/under limits. TeX's
/// fontmath.ltx defines the integral family as \intop\nolimits, so \int and
/// \oint keep their scripts beside as script-size sub/superscripts even in
/// display style; only \sum \prod \coprod \bigcup \bigcap \bigsqcup stack
/// limits over/under. The \bigXXX family stacks too: amsmath redeclares
/// \bigwedge \bigvee \biguplus \bigcap \bigcup \bigotimes \bigoplus \bigodot
/// \bigsqcup with `\DOTSB…\slimits@`, i.e. display limits. The big integrals
/// are the integral family (beside), and \bigstar is a star OPERATOR, so its
/// scripts stay beside as well.
fn bigOpLimits(op: atom.BigOp) bool {
    return switch (op) {
        .sum, .prod, .coprod, .bigcup, .bigcap, .bigsqcup => true,
        .bigodot, .bigoplus, .bigotimes, .biguplus, .bigsqcap, .bigwedge, .bigvee => true,
        .int, .oint, .oiint, .oiiint, .ointctrclockwise => false,
        .bigstar, .bigint, .bigiint, .bigiiint => false,
    };
}

/// The factor between the current math size and the size a big operator is
/// DRAWN at. Every operator draws at 1× — its box is the base or the display
/// variant ink of the glyph itself (see layoutOp) — EXCEPT the big
/// integrals, which Unicode has no codepoint for: \bigint \bigiint \bigiiint
/// draw the ordinary integral signs, linearly scaled (the CTAN `bigints`
/// package, v1.0 2010/02/15, defines `\bigint` as
/// `\mathop{\text{\Huge$\int$}}\nolimits`: a \mathop over an inline
/// integral set at \Huge, and \Huge is 24.88pt against the 10pt base —
/// 2.488× — in every LaTeX size table). The box follows the same factor: it
/// bounds the base glyph's ink at that scaled size (see layoutOp).
fn bigOpScale(op: atom.BigOp) f32 {
    return switch (op) {
        .bigint, .bigiint, .bigiiint => 2.488,
        else => 1.0,
    };
}

/// The unscaled ink row for each big integral. LM Math's double and triple
/// integrals have the same advance and extents as their contour counterparts.
fn bigOpBase(op: atom.BigOp) atom.BigOp {
    return switch (op) {
        .bigint => .int,
        .bigiint => .oiint,
        .bigiiint => .oiiint,
        else => op,
    };
}

/// Round a metric-table em value UP to the 1e-3 em the tables themselves
/// carry. Every ink number here is a three-decimal measurement, so a
/// product of two of them can sit half an ulp below the ink it describes;
/// a box that BOUNDS ink may not round that way.
fn emUp(v: f32) f32 {
    return @ceil(v * 1000.0) / 1000.0;
}

/// A big operator glyph: a char box at the operator codepoint, BOXED BY THE
/// DRAWN FONT'S INK (metrics.bigOpInk × drawn size) — the box WIDTH is the hmtx
/// ADVANCE and the height/depth the ink asc/desc, so the box bounds exactly
/// what the glyph occupies horizontally and what is drawn vertically. The
/// old cmex10 width (∑ 14.44448, ∫ 5.55557, unscaled design values)
/// under-sized the box ~1.8×, so the over-limit centered on a stub instead
/// of the ink, the next atom overlapped the ∑, the viewBox clipped, and the
/// ∫ side-script sat on top of the ink. The bigop spacing/limits gaps still
/// come from cmex10: those are spacing facts, independent of the drawn
/// glyph. In display style the BOX takes the font's display-variant extents
/// (metrics.bigOpInk display branch — ∑ advance 1.444em, ink 0.950/0.450; ∫ keeps
/// the base advance 0.665em with the variant ink 1.361/0.861), so the
/// over/under-limit kerns and the beside-script drops measure from the XeTeX
/// reference geometry. The BOX is what the limits/scripts/advance geometry
/// (and every parent shift) is computed from, and it stays AT DESIGN (the
/// variant extents × size_pt) in every style.
///
/// SVG and CPU resolve the selected MATH display variant from the same face.
/// The drawn size stays at design: scaling a base glyph to match the variant's
/// height would give the wrong width and overlap its beside scripts.
fn layoutOp(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    style: Style,
    size_pt: f32,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const op: atom.BigOp = @fromBackingInt(@intCast(n.data & atom.LimitsBits.value_mask));
    const cp = bigOpCodepoint(op);
    const display = style == .display;
    const ink = metrics.bigOpInk(op, display);
    // Box AT DESIGN: display ops box by the display-variant extents, all
    // other styles by the base extents, always × size_pt. The limits kerns,
    // beside-script drops and the row advance all measure from this box and
    // are byte-identical to round 1 (verified ≤0.2pt vs XeTeX).
    //
    // The box's height/depth ARE the ink bound the consumers frame from:
    // draw.flatten takes a char box's ink straight from them and both
    // svg.zig's viewBox and raster.zig's pixel buffer are cut from that
    // ink bbox, so anything the box misses is cut off at zero padding. For
    // every operator of scale 1 the per-op row IS the drawn glyph's ink and
    // is used verbatim. A SCALED operator paints the base glyph at
    // `glyph_size`, so its box must bound base_ink × scale instead — the
    // same product its own row restates rounded to 1e-3 em, and where that
    // rounding fell short (∫ depth 0.306 × 2.488 = 0.76133 → the row's
    // 0.761) the box sat 0.0002 em under the ink actually painted: measured
    // on the 4800 dpi raster of `\bigint` at 60pt, the painted ink ends
    // 0.03–0.045pt below the box while the painted top stays inside it.
    // emUp rounds the product outward so the frame encloses the drawn ink.
    // The ADVANCE stays the per-op row: it is a spacing fact, not an ink
    // bound, and the painted ink of every scaled operator sits well inside
    // it (⯯ at 60pt: ink to 146.16pt in a 154.5pt box).
    const scale = bigOpScale(op);
    const drawn = metrics.bigOpInk(bigOpBase(op), false);
    const box_w = ink.advance * size_pt;
    const box_h = if (scale == 1.0)
        ink.asc * size_pt
    else
        emUp(drawn.asc * scale) * size_pt;
    const box_d = if (scale == 1.0)
        ink.desc * size_pt
    else
        emUp(drawn.desc * scale) * size_pt;
    // DRAWN size: every big-op draws at the current size — display ops at
    // the FULL size (the rasterizer resolves the MATH .v1 display variant
    // at this size — XeTeX's display op, verified against the embedded
    // reference), text/script ops ALSO at the full size but as the BASE
    // form (XeTeX's text ∫ IS the base glyph at size_pt: ink 1.111em ×
    // size = 33.3pt at 30, matching KaTeX/MathJax). The old ratio
    // size × base_asc/disp_asc shrank the text op to 0.59× (ink 19.7pt,
    // 41% too small) to compensate for the rasterizer resolving .v1 at
    // every size — that workaround is obsolete: the box now carries the
    // big-op form (`.variant` for display), svg.zig emits it as data-op,
    // and the rasterizer resolves .v1 only for marked display ops.
    // The BIG integrals are the one exception: Unicode has no big-integral
    // codepoint, so they draw the ordinary integral sign scaled by
    // bigOpScale (2.488 — the `bigints` package's \Huge), and the box above
    // bounds that glyph's own ink at the scaled size. Every other operator
    // keeps a scale of 1, so their geometry is byte-identical to before.
    const glyph_size = size_pt * scale;
    const box_idx = try list.create(
        .char,
        box_w,
        box_h,
        box_d,
        &.{},
        cp,
        .italic,
        glyph_size,
        span,
    );
    // The glyph is synthesized: its utf-8 does not match the source span
    // (e.g. \sum → ∑), so flatten must dupe it instead of aliasing src.
    list.charDataPtr(box_idx).synthetic = true;
    // Display ops draw the MATH .v1 variant; text/script ops the base glyph.
    // The BIG integrals are the exception: they draw the BASE glyph scaled
    // by `bigOpScale` (there is no big-integral codepoint), and the font's
    // .v1 for those codepoints is a DIFFERENT, larger design — measured
    // with fontTools on the bundled latinmodern-math.otf 2.005:
    // integral.v1 ink 1.361/0.861em at advance 0.999em, against the base
    // integral's 0.805/0.306em at advance 0.665em. Marking a scaled big
    // integral as a display variant made the rasterizer paint that design
    // at `2.488 × size_pt` — 5.53em of ink in a box built for 2.76em, and a
    // 2.49em advance in a 1.655em box — so the ink bounds under-covered
    // what was painted and the frame clipped it top, bottom and right. The
    // base glyph at the scaled size is exactly what the scaled bigOpInk
    // rows describe, which is the whole point of those rows.
    // `disp_advance` / `disp_ic` still ride along either way: the beside
    // scripts of `\bigint_0^1` measure from them.
    if (display) {
        if (bigOpScale(op) == 1.0) list.charDataPtr(box_idx).bigop_form = .variant;
        list.charDataPtr(box_idx).disp_advance = ink.disp_advance;
        list.charDataPtr(box_idx).disp_ic = ink.ic;
    }
    return box_idx;
}

/// \mathchoice{D}{T}{S}{SS} — TeX's four-style choice primitive: the branch
/// matching the CURRENT math style (display→0, text→1, script→2,
/// scriptscript→3; the cramped bit is dropped — TeX math_choice chooses by
/// the style class) is laid out with the branch's OWN style FORCED — the
/// same forcing \displaystyle/\dfrac use (FeatStyleSwitches: branch i is set
/// at style i), so the D branch renders at the display size even inside a
/// script (a \mathchoice{\frac{1}{2}}{x}{y}{z} under \sum's scripts keeps
/// its full-size display fraction), and the chosen branch is always
/// UNCramped (TeX sets the branch's style to its non-cramped class, so a
/// choice in a denominator raises the branch's scripts by sup2, not sup3).
/// The size follows the style level root-relative like the .mathstyle
/// wrapper: size_pt × styleScale(branch)/styleScale(current). The other
/// three branches are never laid out — the box is the chosen branch's box
/// (its content span rides along, so provenance stays exact).
fn layoutMathChoice(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const branch: Style = style; // branch i is set at style i
    const child = ast.child(idx, @backingInt(branch));
    const gl = metrics.glue(fm);
    return layoutInner(
        list,
        ast,
        child,
        fm,
        branch,
        size_pt * (styleScale(gl, branch) / styleScale(gl, style)),
        cstyle,
        false, // forced styles are uncramped (like \displaystyle)
    );
}

/// The font size of the LAST character of the denominator, relative to the
/// fraction's effective size — XeTeX's fraction-clearance quirk.
///
/// make_fraction evaluates the OT gap-min constants (fractionNumGapMin etc.)
/// with `cur_f`, the font of the LAST CHARACTER PROCESSED before the clamp —
/// which, after clean_box(denominator), is the denominator's last glyph.
/// Since a fraction's parts are set one style level down (text parts at
/// 0.7× for a text-style fraction), and a NESTED-fraction denominator's own
/// parts another level down, the effective clearance scale is the product of
/// the part scales along the denominator's last-char path. Scripts keep the
/// scale of their NUCLEUS (the sub of ∂x₁ is at scriptscript but the
/// measured clearance uses the script size of the x — the last noad's
/// nucleus, not its script). Measured XeTeX+unicode-math at 30pt:
///   \dfrac{\frac{a}{b}}{\frac{c}{d}}: outer clr = 0.12em × 21 (the inner
///     frac's denom d is at script) — vs 0.12em × 30 for a plain denom;
///   \begin{matrix}\frac{\partial^2 f}{\partial x_1^2}: clr = 0.04em × 21
///     (text-style fraction, parts at script);
///   \frac{a}{\rule[-0.5em]{0pt}{2.5em}}: clr = 0.12em × 30 (a \rule is a
///     box, no char — cur_f stays the numerator's a at text).
fn denomLastCharScale(
    ast: *const atom.Ast,
    denom: u32,
    part_style: Style,
    gl: metrics.GlueParams,
) f32 {
    // The denom subtree lays out at the fraction's PART size: the scale
    // from the effective size to the parts' size.
    var scale: f32 = styleScale(gl, part_style);
    var style: Style = part_style;
    var u = denom;
    while (true) {
        const n = ast.node(u);
        switch (n.tag) {
            // A nested fraction: its own parts are another part-scale down;
            // the last char is its DENOMINATOR's last char.
            .fraction => {
                const eff: Style = atom.fracForcedStyle(n.data) orelse style;
                const ps: Style = if (atom.fracPartsDisplay(n.data))
                    .display
                else if (eff == .display) .text else if (eff == .text) .script else .script_script;
                // Absolute from base: each nested fraction's parts are at
                // a fixed scale from the document base, not a further
                // multiplication of the parent's part scale.
                scale = styleScale(gl, ps);
                style = eff;
                u = ast.child(u, 1);
            },
            // Transparent wrappers and rows: the last atom keeps the size.
            .row, .left, .opname, .env, .substack => {
                if (n.num_children == 0) return scale;
                u = ast.child(u, n.num_children - 1);
            },
            .group, .styled => {
                if (n.num_children == 0) return scale;
                u = ast.child(u, 0);
            },
            .mathstyle => {
                if (n.num_children == 0) return scale;
                const ms: Style = @fromBackingInt(@intCast(n.data));
                scale *= styleScale(gl, ms) / styleScale(gl, style);
                style = ms;
                u = ast.child(u, 0);
            },
            // A scripted atom: cur_f is the NUCLEUS font (measured ∂x₁).
            .script => {
                if (n.num_children == 0) return scale;
                u = ast.child(u, 0);
            },
            else => return scale,
        }
    }
}

fn layoutFraction(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
    cstyle: atom.CharStyle,
    cramped: bool,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    const line = atom.fracLine(n.data);
    const gl = metrics.glue(fm);

    // Forced style (\dfrac \tfrac) and \cfrac's parts-at-display flag:
    //   \dfrac = \frac in DISPLAY style (amsmath \genfrac style 0),
    //   \tfrac = \frac in TEXT style (style 2),
    //   \cfrac = display gaps AND both parts in display style (amsmath's
    //            \frac{\displaystyle{num}}{\displaystyle{den}}).
    // The effective style drives gap selection (num1/denom1 vs num2/denom2)
    // and the part-style ladder; the effective size follows the STYLE LEVEL
    // (target scale / current scale — styleScale), so \dfrac inside a
    // script renders at display size with text-size parts, exactly TeX's
    // style-force semantics (the style determines the font size). A plain
    // \frac/\atop has no forced style: eff = current, ratio 1.0, so every
    // existing path is byte-identical.
    const forced = atom.fracForcedStyle(n.data);
    const parts_display = atom.fracPartsDisplay(n.data);
    const eff_style: Style = forced orelse style;
    const eff_size = size_pt * (styleScale(gl, eff_style) / styleScale(gl, style));
    const axis = s(gl.axis_height, eff_size);
    // \genfrac's explicit rule thickness: an absolute TeX dimension (a
    // \genfrac{}{}{1pt} rule stays 1pt at every size, unlike \frac's
    // font-relative rule_thickness which scales with the size — measured
    // XeTeX: \frac rule 1.4345pt vs \genfrac 1pt rule 0.9963pt at 36pt, the
    // same absolute value as at 10pt). 0 for plain \frac/\atop and for a
    // 0pt genfrac (which is \atop-style: no rule at all).
    const thick = atom.fracThickness(n.data);
    const rt = if (thick > 0) thick else s(gl.rule_thickness, eff_size);

    // Numerator and denominator are set one style level down (MicroTeX
    // FractionAtom::createBox → env.numStyle()/dnomStyle(); tex.web
    // num_style/denom_style): display → text, text → script,
    // script/scriptscript → scriptscript. \cfrac instead sets BOTH parts
    // in display style. The NUMERATOR inherits the cramped bit (num_style:
    // cramped iff the current style is cramped); the DENOMINATOR is always
    // cramped (denom_style: smaller + cramped) — verified: display
    // \frac{x^2}{y^2} raises the numerator sup by sup2 (3.62892) but the
    // denominator sup by sup3 (2.88889). \cfrac's parts are explicit
    // \displaystyle fields (amsmath), so BOTH are uncramped.
    const part_style: Style = if (parts_display)
        .display
    else if (eff_style == .display) .text else if (eff_style == .text) .script else .script_script;
    const part_scale = styleScale(gl, part_style);
    // TeX sizes are absolute from the document base, not compounded
    // multiplicatively.  eff_size already reflects forced-style rescaling,
    // so dividing back by the fraction's OWN style scale recovers the
    // document base, and multiplying by the part style's scale gives the
    // correct absolute size at any nesting depth.
    const base_size = eff_size / styleScale(gl, eff_style);
    const part_size = base_size * part_scale;
    const part_cramped = !parts_display;
    const num = try layoutInner(
        list,
        ast,
        ast.child(idx, 0),
        fm,
        part_style,
        part_size,
        cstyle,
        cramped and part_cramped,
    );
    const den = try layoutInner(
        list,
        ast,
        ast.child(idx, 1),
        fm,
        part_style,
        part_size,
        cstyle,
        part_cramped,
    );
    const nb = list.get(num);
    const db = list.get(den);

    // \cfrac (amsmath): the NUMERATOR is `\strut #2` — an invisible
    // display-size strut that carries DEPTH below the numerator baseline.
    // TeX make_fraction's clearance check
    //   kern1 = num1 − numerator_depth − (axis + rt/2) ≥ 3·rt
    // uses that depth; a bare digit '1' has depth 0, so no bump fires and
    // the numerator sits ~2pt too low (measured: \cfrac{1}{a} at 30pt
    // numerator-to-rule 12.75pt vs XeTeX 14.62pt; the shortfall compounds
    // over a nested continuation to ~7.5pt). The strut is the \strutbox
    // at the effective size: height 0.84em, depth 0.36em (with the \cfrac
    // context's \baselineskip 1.2× the size, 0.7/0.3 × 1.2 = 0.84/0.36).
    // Apply the strut DEPTH to the numerator box so the clearance bump
    // raises the numerator exactly like XeTeX. Only \cfrac does this:
    // \dfrac = \frac in display style (NO strut).
    var num_height = nb.height;
    var num_depth = nb.depth;
    if (parts_display) {
        num_height = @max(num_height, 0.84 * eff_size);
        num_depth = @max(num_depth, 0.36 * eff_size);
    }

    const vbox_w = @max(nb.width, db.width);

    // Gap parameters and clearance (MicroTeX FractionAtom::createBox),
    // selected by the EFFECTIVE style (forced for \dfrac/\tfrac/\cfrac):
    // display → num1/denom1 with clearance 3·rt (rule) or 7·drt (\atop);
    // text/script → num2/denom2 (num3 for \atop) with clearance rt (3·drt).
    //
    // The clearance values are the LM Math OT gap-mins (fractionNumGapMin
    // 0.04em / fractionNumDisplayStyleGapMin 0.12em — equal to rt / 3·rt),
    // evaluated at the size of the denominator's LAST CHARACTER (XeTeX
    // make_fraction reads them with cur_f = the last processed glyph — see
    // denomLastCharScale): a text-style fraction's parts are at 0.7×, so
    // its clearance is 0.7× the text rt; a display fraction whose
    // denominator is itself a fraction gets the nested fraction's part
    // size. Plain-char denominators keep the old values byte-identical
    // (the scale is 1.0), so \frac{a}{b} etc. are untouched.
    const clr_scale = denomLastCharScale(ast, ast.child(idx, 1), part_style, gl);
    // The OPEN TYPE MATH clearance floors: the active face's own gap
    // minimums for the two sides, so a face that asks for a wider gap
    // between the rule and a part really gets one — this is what makes a
    // runtime `fractionNumDisplayStyleGapMin` a layout fact rather than
    // metadata. Display fractions use the display gap minimums and every
    // other style the plain ones, the same split as the shift amounts below.
    // The rule-multiple clearance is the fallback for a source with no MATH
    // table, and the floor is a MAXIMUM of the two, so nothing that used to
    // clear a smaller gap now clears less.
    const mc = gl.math_constants;
    // MATH constants are EM and `s()` scales a 10pt-BASE value, so they are
    // multiplied by the size directly. Routing them through `s()` divided
    // every runtime gap minimum by ten — a face asking for a 0.8em display
    // clearance got 0.08em, the floor never fired, and the clamped layout
    // silently ignored the face.
    const num_gap: f32 = if (mc) |m|
        (if (eff_style == .display)
            m.fraction_num_display_style_gap_min
        else
            m.fraction_numerator_gap_min) * eff_size * clr_scale
    else
        0;
    const den_gap: f32 = if (mc) |m|
        (if (eff_style == .display)
            m.fraction_denom_display_style_gap_min
        else
            m.fraction_denominator_gap_min) * eff_size * clr_scale
    else
        0;
    var shift_up: f32 = undefined;
    var shift_down: f32 = undefined;
    var clr: f32 = undefined;
    var clr_d: f32 = undefined;
    if (eff_style == .display) {
        shift_up = s(gl.num1, eff_size);
        shift_down = s(gl.denom1, eff_size);
        clr = (if (line) 3 * rt else 7 * rt) * clr_scale;
        clr_d = clr;
    } else {
        shift_down = s(gl.denom2, eff_size);
        if (line) {
            shift_up = s(gl.num2, eff_size);
            clr = rt * clr_scale;
        } else {
            shift_up = s(gl.num3, eff_size);
            clr = 3 * rt * clr_scale;
        }
        clr_d = clr;
    }
    clr = @max(clr, num_gap);
    clr_d = @max(clr_d, den_gap);

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    var num_shift: f32 = undefined;
    var den_shift: f32 = undefined;
    if (line) {
        // Rule is centered on the axis; enforce the clearance on both sides
        // by raising the shift amounts (MicroTeX kern1/kern2 adjustment).
        const delta = rt / 2;
        const kern1 = shift_up - num_depth - (axis + delta);
        const kern2 = (axis - delta) - (db.height - shift_down);
        if (kern1 < clr) shift_up += clr - kern1;
        if (kern2 < clr_d) shift_down += clr_d - kern2;
        num_shift = -shift_up;
        den_shift = shift_down;
    } else {
        // \atop: split any clearance deficit evenly between both parts.
        const kern = shift_up - num_depth - (db.height - shift_down);
        const delta = (clr - kern) / 2;
        if (delta > 0) {
            shift_up += delta;
            shift_down += delta;
        }
        num_shift = -shift_up;
        den_shift = shift_down;
    }
    const height = shift_up + num_height;
    const depth = shift_down + db.depth;

    // TeX wraps a delimiter-less generalized fraction (\over, \atop) in two
    // null-delimiter boxes of width \nulldelimiterspace (measured \showbox:
    // the row box is hbox{pad 1.2, vbox max(num,den), pad 1.2} — 11.44455pt
    // for a 9.04456pt vbox at 10pt). The pads are FIXED 1.2pt, unscaled in
    // script styles (measured at 5pt). A fraction with REAL delimiters —
    // the `\binom` family, `\genfrac{()}` — carries none: both engines draw
    // `\tbinom{n}{k}` flush between its parens. We keep the superflat model
    // by folding the pads into the vbox: widen it by 2·pad and shift every
    // child 1.2pt right (the rule spans only the inner max(num,den) width).
    const pad: f32 = if (atom.fracFixedDelim(n.data)) 0 else 1.2; // TeX \nulldelimiterspace
    const box_w = vbox_w + 2 * pad;

    try list.scratch.append(list.gpa, .{ .idx = num, .x_shift = pad + (vbox_w - nb.width) / 2, .shift = num_shift });
    if (line) {
        const rule = try list.createLeaf(.rule, vbox_w, rt / 2, rt / 2, span);
        // The rule sits on the math axis, `axis` above the vbox baseline
        // (MicroTeX FractionAtom stacks it at the axis; the old shift=0 put
        // it on the baseline, floating the numerator and letting the
        // denominator punch through the bar). The clearance math above
        // already measures kern1/kern2 from the axis, so only the rule's own
        // placement needed fixing.
        try list.scratch.append(list.gpa, .{ .idx = rule, .x_shift = pad, .shift = -axis });
    }
    try list.scratch.append(list.gpa, .{ .idx = den, .x_shift = pad + (vbox_w - db.width) / 2, .shift = den_shift });

    return list.create(.vbox, box_w, height, depth, list.scratch.items[saved_len..], 0, cstyle, 0, span);
}

fn layoutSpace(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    _: *const metrics.FontMetrics,
    style: Style,
    size_pt: f32,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    // Mu-unit spaces (\, \; \!) and quads are measured against the SYMBOL
    // font's quad at the current style (tex.web: 1mu = quad/18 of family 2;
    // \quad = 18mu). cmsy7's quad is 1.170641em, cmsy5's 1.472241em — a
    // thin space in a script is 3/18×1.170641×7 = 1.3657pt, not 1.1667
    // (measured via XeTeX \showbox on x^{a\,b}: glue 1.36574pt).
    const em = atom.fixedToEm(n.data); // f32 em width (raw bits)
    const width = em * size_pt * quadEm(style);
    return list.createLeaf(.glue, width, 0, 0, span);
}

fn layoutText(
    list: *box.BoxList,
    ast: *const atom.Ast,
    idx: u32,
    fm: *const metrics.FontMetrics,
    size_pt: f32,
    cstyle: atom.CharStyle,
) !u32 {
    const n = ast.node(idx);
    const span = ast.span(idx);
    // The leaf's own face COMBINED with the enclosing one: nested \textbf and
    // \textit must accumulate to bold italic (`\textbf{\textit{x}}`), and the
    // outer face is restored when the inner run ends, while a bare `\text{…}`
    // inside an italic formula stays roman and a math alphabet
    // (`\mathbf{\mathbb R}`) is untouched. See `combineStyle`.
    const base_style: atom.CharStyle = combineStyle(cstyle, @fromBackingInt(@intCast(n.data)));
    // The run's bytes are the INSIDE of the braces that frame it: the parser's
    // textFace leaf always spans the balanced group it opened, so the span's
    // first and last bytes are that group's `{` and `}`. Stripping them
    // UNCONDITIONALLY drops whatever byte a hand-built leaf happens to end on
    // — a trailing backslash (an escape the repertoire rejects) would vanish
    // with no error at all, which is the one failure this scanner exists to
    // prevent. A span that is not brace-framed is not a text run we can
    // typeset.
    const frame = ast.src[span.start..span.end];
    if (frame.len < 2 or frame[0] != '{' or frame[frame.len - 1] != '}') {
        return error.InvalidAst;
    }
    const inner = frame[1 .. frame.len - 1];

    const saved_len = list.scratch.items.len;
    defer list.scratch.items.len = saved_len;
    // Face scopes INSIDE the run: a \textit{…} / \textbf{…} / \text{…} in the
    // raw bytes opens one, adding its modifiers to the face in effect, and the
    // matching `}` restores it. `\textbf{a\textit{b}c}` is therefore ONE leaf
    // drawn in three faces (bold, bold italic, bold) — no extra AST node and no
    // allocation per character: `restore` is a fixed stack holding the face
    // each open `{` restores, bounded by the same constant the parser enforces
    // on the run's brace nesting (atom.max_text_nesting). A hand-built AST
    // that exceeds the bound is invalid.
    var face: atom.CharStyle = base_style;
    var restore: [atom.max_text_nesting]atom.CharStyle = undefined;
    var open_groups: u32 = 0;
    var x: f32 = 0;
    var height: f32 = 0;
    var depth: f32 = 0;

    // The \text content is parsed here (the atom is a leaf whose span covers
    // the braced group): braces are grouping (never output), `~` and `\ ` are
    // the ACTIVE face's interword space (a NON-BREAKING space in TeX; 0.302em
    // for Latin Modern Roman, \fontdimen2, measured on the XeTeX reference: the
    // `c~ {ab} \ e` corpus entry lays out as 9.06pt glues at 30pt), literal
    // spaces are the same width, and backslash escapes are consumed without
    // leaking the backslash (textAccentCp maps the common accents to the
    // precomposed char, \i → ı, \j → ȷ).
    //
    // The escape repertoire is `atom.textCommandSupported` — ONE list shared
    // with the parser, which rejects an unsupported command in a real parse
    // with `UnknownCommand` and its exact span. A hand-built AST can carry
    // raw bytes the parser never produces, and a `\text` run has no layout
    // model for anything outside that repertoire (a font switch, `\LaTeX`, a
    // `\\` line break): silently consuming the name and emitting NOTHING is
    // how a formula lost whole words. Such a run is `error.InvalidAst` here,
    // which is the same "this is not a text run we can typeset" answer.
    var off: usize = 0;
    while (off < inner.len) {
        const b = inner[off];
        if (b == '\\') {
            off += 1;
            // A trailing backslash is not an escape: no such bytes can come out
            // of the parser.
            if (off >= inner.len) return error.InvalidAst;
            const c = inner[off];
            if (c == ' ') {
                // `\ ` — the control space: one interword space.
                const gs: u32 = @intCast(span.start + 1 + off - 1);
                try textEmitSpace(list, fm, face, size_pt, gs, gs + 2, &x);
                off += 1;
                continue;
            }
            if (isAsciiLetter(c)) {
                var e = off;
                while (e < inner.len and isAsciiLetter(inner[e])) e += 1;
                const cmd = inner[off..e];
                const cmd_start = off - 1; // the backslash
                off = e;
                if (std.mem.eql(u8, cmd, "i")) {
                    // \i — the dotless i (U+0131); used bare or under an
                    // accent (\'\i → í via the 'i' base in textAccentCp).
                    const gs: u32 = @intCast(span.start + 1 + cmd_start);
                    try textEmitChar(list, ast.src, fm, face, size_pt, 0x0131, gs, gs + 2, &x, &height, &depth);
                    continue;
                }
                if (std.mem.eql(u8, cmd, "j")) {
                    const gs: u32 = @intCast(span.start + 1 + cmd_start);
                    try textEmitChar(list, ast.src, fm, face, size_pt, 0x0237, gs, gs + 2, &x, &height, &depth);
                    continue;
                }
                if (cmd.len == 1 and atom.isTextAccentControl(cmd[0]) and cmd[0] >= 'a') {
                    // \H \r \v \u \c \d \b \t: accent over the next
                    // braced group or single atom. The `>= 'a'` guard leaves
                    // the seven SYMBOL accents (`\' \` \" \^ \~ \. \=`) to
                    // the switch below, which handles them the same way.
                    const tgt = try textEscapeTarget(inner, &off);
                    const gs: u32 = @intCast(span.start + 1 + cmd_start);
                    const ge: u32 = @intCast(span.start + 1 + tgt.end);
                    try textEmitAccented(
                        list,
                        ast.src,
                        fm,
                        face,
                        size_pt,
                        cmd[0],
                        tgt.cp,
                        gs,
                        ge,
                        &x,
                        &height,
                        &depth,
                    );
                    continue;
                }
                // \textit{…} / \textbf{…} / \text{…} INSIDE the run: a face
                // scope, never typeset bytes. TeX swallows the spaces after a
                // control word, so `\textit {x}` opens the same scope.
                if (atom.textFaceCommand(cmd)) |f| {
                    var k = off;
                    while (k < inner.len and inner[k] == ' ') k += 1;
                    if (k < inner.len and inner[k] == '{') {
                        if (open_groups == restore.len) return error.InvalidAst;
                        restore[open_groups] = face;
                        open_groups += 1;
                        face = atom.combineTextStyles(face, f);
                        off = k + 1;
                        continue;
                    }
                }
                // Any other control word (a font switch, \LaTeX, `\\`): the
                // repertoire has no layout for it, so the run is invalid.
                return error.InvalidAst;
            }
            const cmd_start = off - 1; // the backslash
            switch (c) {
                // single-symbol accents: \' \` \" \^ \~ \. \=
                '\'', '`', '"', '^', '~', '.', '=' => {
                    off += 1;
                    const tgt = try textEscapeTarget(inner, &off);
                    const gs: u32 = @intCast(span.start + 1 + cmd_start);
                    const ge: u32 = @intCast(span.start + 1 + tgt.end);
                    try textEmitAccented(list, ast.src, fm, face, size_pt, c, tgt.cp, gs, ge, &x, &height, &depth);
                },
                // The escaped char itself, in the repertoire
                // `atom.textCommandSupported` admits: the seven special
                // characters LaTeX makes an escape out of. The backslash is
                // never output.
                '{', '}', '$', '%', '&', '#', '_' => {
                    const gs: u32 = @intCast(span.start + 1 + cmd_start);
                    try textEmitChar(list, ast.src, fm, face, size_pt, c, gs, gs + 2, &x, &height, &depth);
                    off += 1;
                },
                // `\\` — a line break inside a text run. There is no line
                // model here (the run is one hbox), so it is unsupported
                // rather than silently dropped.
                else => return error.InvalidAst,
            }
            continue;
        }
        if (b == '{') {
            // Grouping braces inside \text are never output (the parser already
            // verified the group is balanced), but the brace opens a restore
            // point for the face in effect.
            if (open_groups == restore.len) return error.InvalidAst;
            restore[open_groups] = face;
            open_groups += 1;
            off += 1;
            continue;
        }
        if (b == '}') {
            // Closing a group ends the scope it opened: a face scope restores
            // the face it was opened with, a plain group changes nothing.
            if (open_groups > 0) {
                open_groups -= 1;
                face = restore[open_groups];
            }
            off += 1;
            continue;
        }
        if (b == '~' or b == ' ') {
            // `~` — TeX's non-breaking space; ' ' — the interword space. Both
            // are the ACTIVE face's interword space (see `textSpaceWidth`).
            const gs: u32 = @intCast(span.start + 1 + off);
            try textEmitSpace(list, fm, face, size_pt, gs, gs + 1, &x);
            off += 1;
            continue;
        }
        // A plain grapheme: emit the base codepoint, then any combining
        // marks inside the cluster as zero-width boxes (\text{e̋} keeps the
        // double-acute, exactly like the source).
        var it = Graphemes.iterator(inner[off..]);
        const g = it.next() orelse break;
        const gbytes = g.bytes(inner[off..]);
        const gstart: u32 = @intCast(span.start + 1 + off);
        var cursor: zg.code_point.uoffset = 0;
        var first = true;
        while (zg.code_point.decodeAtCursor(gbytes, &cursor)) |d| {
            if (d.code == 0) break;
            const is_mark = d.code >= 0x0300 and d.code <= 0x036F;
            const cstart: u32 = @intCast(gstart + @as(u32, @intCast(cursor - d.len)));
            const cend: u32 = @intCast(cstart + d.len);
            if (!first and !is_mark) break; // only the base + combining marks
            if (first) {
                try textEmitChar(list, ast.src, fm, face, size_pt, d.code, cstart, cend, &x, &height, &depth);
            } else {
                // A combining mark: zero width (the font's marks are
                // zero-advance by design), boxed by its own ink.
                try textEmitMark(list, face, size_pt, d.code, cstart, cend, &x, &height, &depth);
            }
            first = false;
        }
        off += gbytes.len;
    }
    return list.create(.hbox, x, height, depth, list.scratch.items[saved_len..], 0, base_style, 0, span);
}

/// The interword space of the STATIC ROMAN path: \fontdimen2 of the roman text
/// font (3.02pt at 10pt for Latin Modern Roman, measured on the XeTeX
/// reference at 30pt: every `~`/space/`\ ` in `\text{c~ {ab} \ e}` lays out as
/// a 9.06pt glue), kept at every size because the cmr7/cmr5 optical rows and
/// the LMRoman17 band each carry a different space advance. The other faces
/// measure their own — see `textSpaceWidth`. The old render used the U+007E
/// glyph's advance (0.556em — the "wide space" the critic flagged); the
/// reference space is narrow, non-breaking, and font-relative.
const text_space_em: f32 = 0.302;

/// One output codepoint for a text accent over a base: precomposed where
/// Latin Modern Roman carries it, else null (the caller falls back to the
/// base + the accent's combining mark, or the plain base).
const text_accent_table = [_]struct { accent: u8, base: u8, cp: u21 }{
    .{ .accent = '"', .base = 'A', .cp = 0x00C4 },
    .{ .accent = '"', .base = 'E', .cp = 0x00CB },
    .{ .accent = '"', .base = 'I', .cp = 0x00CF },
    .{ .accent = '"', .base = 'O', .cp = 0x00D6 },
    .{ .accent = '"', .base = 'U', .cp = 0x00DC },
    .{ .accent = '"', .base = 'Y', .cp = 0x0178 },
    .{ .accent = '"', .base = 'a', .cp = 0x00E4 },
    .{ .accent = '"', .base = 'e', .cp = 0x00EB },
    .{ .accent = '"', .base = 'h', .cp = 0x1E27 },
    .{ .accent = '"', .base = 'i', .cp = 0x00EF },
    .{ .accent = '"', .base = 'o', .cp = 0x00F6 },
    .{ .accent = '"', .base = 't', .cp = 0x1E97 },
    .{ .accent = '"', .base = 'u', .cp = 0x00FC },
    .{ .accent = '"', .base = 'w', .cp = 0x1E85 },
    .{ .accent = '"', .base = 'x', .cp = 0x1E8D },
    .{ .accent = '"', .base = 'y', .cp = 0x00FF },
    .{ .accent = '\'', .base = 'A', .cp = 0x00C1 },
    .{ .accent = '\'', .base = 'C', .cp = 0x0106 },
    .{ .accent = '\'', .base = 'E', .cp = 0x00C9 },
    .{ .accent = '\'', .base = 'G', .cp = 0x01F4 },
    .{ .accent = '\'', .base = 'I', .cp = 0x00CD },
    .{ .accent = '\'', .base = 'K', .cp = 0x1E30 },
    .{ .accent = '\'', .base = 'L', .cp = 0x0139 },
    .{ .accent = '\'', .base = 'N', .cp = 0x0143 },
    .{ .accent = '\'', .base = 'O', .cp = 0x00D3 },
    .{ .accent = '\'', .base = 'R', .cp = 0x0154 },
    .{ .accent = '\'', .base = 'S', .cp = 0x015A },
    .{ .accent = '\'', .base = 'U', .cp = 0x00DA },
    .{ .accent = '\'', .base = 'Y', .cp = 0x00DD },
    .{ .accent = '\'', .base = 'Z', .cp = 0x0179 },
    .{ .accent = '\'', .base = 'a', .cp = 0x00E1 },
    .{ .accent = '\'', .base = 'c', .cp = 0x0107 },
    .{ .accent = '\'', .base = 'e', .cp = 0x00E9 },
    .{ .accent = '\'', .base = 'g', .cp = 0x01F5 },
    .{ .accent = '\'', .base = 'i', .cp = 0x00ED },
    .{ .accent = '\'', .base = 'k', .cp = 0x1E31 },
    .{ .accent = '\'', .base = 'l', .cp = 0x013A },
    .{ .accent = '\'', .base = 'n', .cp = 0x0144 },
    .{ .accent = '\'', .base = 'o', .cp = 0x00F3 },
    .{ .accent = '\'', .base = 'r', .cp = 0x0155 },
    .{ .accent = '\'', .base = 's', .cp = 0x015B },
    .{ .accent = '\'', .base = 'u', .cp = 0x00FA },
    .{ .accent = '\'', .base = 'y', .cp = 0x00FD },
    .{ .accent = '\'', .base = 'z', .cp = 0x017A },
    .{ .accent = '.', .base = 'C', .cp = 0x010A },
    .{ .accent = '.', .base = 'E', .cp = 0x0116 },
    .{ .accent = '.', .base = 'G', .cp = 0x0120 },
    .{ .accent = '.', .base = 'I', .cp = 0x0130 },
    .{ .accent = '.', .base = 'Z', .cp = 0x017B },
    .{ .accent = '.', .base = 'c', .cp = 0x010B },
    .{ .accent = '.', .base = 'e', .cp = 0x0117 },
    .{ .accent = '.', .base = 'g', .cp = 0x0121 },
    .{ .accent = '.', .base = 'z', .cp = 0x017C },
    .{ .accent = '=', .base = 'A', .cp = 0x0100 },
    .{ .accent = '=', .base = 'E', .cp = 0x0112 },
    .{ .accent = '=', .base = 'I', .cp = 0x012A },
    .{ .accent = '=', .base = 'O', .cp = 0x014C },
    .{ .accent = '=', .base = 'U', .cp = 0x016A },
    .{ .accent = '=', .base = 'a', .cp = 0x0101 },
    .{ .accent = '=', .base = 'e', .cp = 0x0113 },
    .{ .accent = '=', .base = 'i', .cp = 0x012B },
    .{ .accent = '=', .base = 'o', .cp = 0x014D },
    .{ .accent = '=', .base = 'u', .cp = 0x016B },
    .{ .accent = 'H', .base = 'O', .cp = 0x0150 },
    .{ .accent = 'H', .base = 'U', .cp = 0x0170 },
    .{ .accent = 'H', .base = 'o', .cp = 0x0151 },
    .{ .accent = 'H', .base = 'u', .cp = 0x0171 },
    .{ .accent = '^', .base = 'A', .cp = 0x00C2 },
    .{ .accent = '^', .base = 'C', .cp = 0x0108 },
    .{ .accent = '^', .base = 'E', .cp = 0x00CA },
    .{ .accent = '^', .base = 'G', .cp = 0x011C },
    .{ .accent = '^', .base = 'H', .cp = 0x0124 },
    .{ .accent = '^', .base = 'I', .cp = 0x00CE },
    .{ .accent = '^', .base = 'J', .cp = 0x0134 },
    .{ .accent = '^', .base = 'O', .cp = 0x00D4 },
    .{ .accent = '^', .base = 'S', .cp = 0x015C },
    .{ .accent = '^', .base = 'U', .cp = 0x00DB },
    .{ .accent = '^', .base = 'W', .cp = 0x0174 },
    .{ .accent = '^', .base = 'Y', .cp = 0x0176 },
    .{ .accent = '^', .base = 'a', .cp = 0x00E2 },
    .{ .accent = '^', .base = 'c', .cp = 0x0109 },
    .{ .accent = '^', .base = 'e', .cp = 0x00EA },
    .{ .accent = '^', .base = 'g', .cp = 0x011D },
    .{ .accent = '^', .base = 'h', .cp = 0x0125 },
    .{ .accent = '^', .base = 'i', .cp = 0x00EE },
    .{ .accent = '^', .base = 'j', .cp = 0x0135 },
    .{ .accent = '^', .base = 'o', .cp = 0x00F4 },
    .{ .accent = '^', .base = 's', .cp = 0x015D },
    .{ .accent = '^', .base = 'u', .cp = 0x00FB },
    .{ .accent = '^', .base = 'w', .cp = 0x0175 },
    .{ .accent = '^', .base = 'y', .cp = 0x0177 },
    .{ .accent = '`', .base = 'A', .cp = 0x00C0 },
    .{ .accent = '`', .base = 'E', .cp = 0x00C8 },
    .{ .accent = '`', .base = 'I', .cp = 0x00CC },
    .{ .accent = '`', .base = 'N', .cp = 0x01F8 },
    .{ .accent = '`', .base = 'O', .cp = 0x00D2 },
    .{ .accent = '`', .base = 'U', .cp = 0x00D9 },
    .{ .accent = '`', .base = 'W', .cp = 0x1E80 },
    .{ .accent = '`', .base = 'Y', .cp = 0x1EF2 },
    .{ .accent = '`', .base = 'a', .cp = 0x00E0 },
    .{ .accent = '`', .base = 'e', .cp = 0x00E8 },
    .{ .accent = '`', .base = 'i', .cp = 0x00EC },
    .{ .accent = '`', .base = 'n', .cp = 0x01F9 },
    .{ .accent = '`', .base = 'o', .cp = 0x00F2 },
    .{ .accent = '`', .base = 'u', .cp = 0x00F9 },
    .{ .accent = '`', .base = 'w', .cp = 0x1E81 },
    .{ .accent = '`', .base = 'y', .cp = 0x1EF3 },
    .{ .accent = 'c', .base = 'C', .cp = 0x00C7 },
    .{ .accent = 'c', .base = 'G', .cp = 0x0122 },
    .{ .accent = 'c', .base = 'K', .cp = 0x0136 },
    .{ .accent = 'c', .base = 'S', .cp = 0x015E },
    .{ .accent = 'c', .base = 'c', .cp = 0x00E7 },
    .{ .accent = 'c', .base = 'g', .cp = 0x0123 },
    .{ .accent = 'c', .base = 'k', .cp = 0x0137 },
    .{ .accent = 'c', .base = 's', .cp = 0x015F },
    .{ .accent = 'd', .base = 'A', .cp = 0x1EA0 },
    .{ .accent = 'd', .base = 'E', .cp = 0x1EB8 },
    .{ .accent = 'd', .base = 'O', .cp = 0x1ECC },
    .{ .accent = 'd', .base = 'U', .cp = 0x1EE4 },
    .{ .accent = 'd', .base = 'a', .cp = 0x1EA1 },
    .{ .accent = 'd', .base = 'e', .cp = 0x1EB9 },
    .{ .accent = 'd', .base = 'o', .cp = 0x1ECD },
    .{ .accent = 'd', .base = 'u', .cp = 0x1EE5 },
    .{ .accent = 'r', .base = 'A', .cp = 0x00C5 },
    .{ .accent = 'r', .base = 'U', .cp = 0x016E },
    .{ .accent = 'r', .base = 'a', .cp = 0x00E5 },
    .{ .accent = 'r', .base = 'u', .cp = 0x016F },
    .{ .accent = 'u', .base = 'A', .cp = 0x0102 },
    .{ .accent = 'u', .base = 'E', .cp = 0x0114 },
    .{ .accent = 'u', .base = 'G', .cp = 0x011E },
    .{ .accent = 'u', .base = 'I', .cp = 0x012C },
    .{ .accent = 'u', .base = 'O', .cp = 0x014E },
    .{ .accent = 'u', .base = 'U', .cp = 0x016C },
    .{ .accent = 'u', .base = 'a', .cp = 0x0103 },
    .{ .accent = 'u', .base = 'e', .cp = 0x0115 },
    .{ .accent = 'u', .base = 'g', .cp = 0x011F },
    .{ .accent = 'u', .base = 'i', .cp = 0x012D },
    .{ .accent = 'u', .base = 'o', .cp = 0x014F },
    .{ .accent = 'u', .base = 'u', .cp = 0x016D },
    .{ .accent = 'v', .base = 'C', .cp = 0x010C },
    .{ .accent = 'v', .base = 'D', .cp = 0x010E },
    .{ .accent = 'v', .base = 'E', .cp = 0x011A },
    .{ .accent = 'v', .base = 'G', .cp = 0x01E6 },
    .{ .accent = 'v', .base = 'L', .cp = 0x013D },
    .{ .accent = 'v', .base = 'N', .cp = 0x0147 },
    .{ .accent = 'v', .base = 'R', .cp = 0x0158 },
    .{ .accent = 'v', .base = 'S', .cp = 0x0160 },
    .{ .accent = 'v', .base = 'T', .cp = 0x0164 },
    .{ .accent = 'v', .base = 'Z', .cp = 0x017D },
    .{ .accent = 'v', .base = 'a', .cp = 0x01CE },
    .{ .accent = 'v', .base = 'c', .cp = 0x010D },
    .{ .accent = 'v', .base = 'd', .cp = 0x010F },
    .{ .accent = 'v', .base = 'e', .cp = 0x011B },
    .{ .accent = 'v', .base = 'g', .cp = 0x01E7 },
    .{ .accent = 'v', .base = 'i', .cp = 0x01D0 },
    .{ .accent = 'v', .base = 'k', .cp = 0x01E9 },
    .{ .accent = 'v', .base = 'l', .cp = 0x013E },
    .{ .accent = 'v', .base = 'n', .cp = 0x0148 },
    .{ .accent = 'v', .base = 'o', .cp = 0x01D2 },
    .{ .accent = 'v', .base = 'r', .cp = 0x0159 },
    .{ .accent = 'v', .base = 's', .cp = 0x0161 },
    .{ .accent = 'v', .base = 't', .cp = 0x0165 },
    .{ .accent = 'v', .base = 'u', .cp = 0x01D4 },
    .{ .accent = 'v', .base = 'z', .cp = 0x017E },
    .{ .accent = '~', .base = 'A', .cp = 0x00C3 },
    .{ .accent = '~', .base = 'E', .cp = 0x1EBC },
    .{ .accent = '~', .base = 'I', .cp = 0x0128 },
    .{ .accent = '~', .base = 'N', .cp = 0x00D1 },
    .{ .accent = '~', .base = 'O', .cp = 0x00D5 },
    .{ .accent = '~', .base = 'U', .cp = 0x0168 },
    .{ .accent = '~', .base = 'a', .cp = 0x00E3 },
    .{ .accent = '~', .base = 'e', .cp = 0x1EBD },
    .{ .accent = '~', .base = 'i', .cp = 0x0129 },
    .{ .accent = '~', .base = 'n', .cp = 0x00F1 },
    .{ .accent = '~', .base = 'o', .cp = 0x00F5 },
    .{ .accent = '~', .base = 'u', .cp = 0x0169 },
};

fn textAccentCp(accent: u8, base: u8) ?u21 {
    for (text_accent_table) |row| {
        if (row.accent == accent and row.base == base) return row.cp;
    }
    return null;
}
/// The combining mark (U+0300..U+036F) a text accent falls back to when no
/// precomposed character exists (e.g. \H{a} → a + U+030B).
fn textAccentMark(accent: u8) u21 {
    return switch (accent) {
        '\'' => 0x0301,
        '`' => 0x0300,
        '"' => 0x0308,
        '^' => 0x0302,
        '~' => 0x0303,
        '.' => 0x0307,
        '=' => 0x0304,
        'H' => 0x030B,
        'r' => 0x030A,
        'v' => 0x030C,
        'u' => 0x0306,
        'c' => 0x0327,
        'd' => 0x0323,
        'b' => 0x0331,
        't' => 0x0361,
        else => 0,
    };
}

inline fn isAsciiLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// The base atom of a text accent: either a braced group (the first
/// grapheme inside, which may itself be an escape like \i) or one
/// following grapheme/escape. Returns the base codepoint (an ASCII letter
/// or the dotless \i/\j bases) and the inner offset just past the target.
/// An escape the run's repertoire has no base for — any command other than
/// \i/\j — is `error.InvalidAst`, the same answer the surrounding dispatch
/// gives an unsupported command in any other position.
fn textEscapeTarget(
    inner: []const u8,
    off: *usize,
) error{InvalidAst}!struct { cp: u21, end: usize } {
    // TeX ignores spaces after a control sequence: `\H e` is \H{e}.
    while (off.* < inner.len and inner[off.*] == ' ') off.* += 1;
    if (off.* >= inner.len) return .{ .cp = 0, .end = off.* };
    if (inner[off.*] == '{') {
        // a braced group: the base is the first output char inside
        var i = off.* + 1;
        var depth: u32 = 1;
        while (i < inner.len and depth > 0) {
            if (inner[i] == '{') {
                depth += 1;
            } else if (inner[i] == '}') {
                depth -= 1;
            }
            i += 1;
        }
        const end = @min(i, inner.len);
        const cp = firstTextBase(inner[off.* + 1 .. end - 1]);
        off.* = end;
        return .{ .cp = cp, .end = end };
    }
    // a single atom: one grapheme or an \i/\j escape
    const i = off.*;
    if (inner[i] == '\\') {
        if (i + 1 < inner.len and inner[i + 1] == 'i') {
            off.* = i + 2;
            return .{ .cp = 'i', .end = i + 2 };
        }
        if (i + 1 < inner.len and inner[i + 1] == 'j') {
            off.* = i + 2;
            return .{ .cp = 'j', .end = i + 2 };
        }
        // A command other than \i/\j as the accent target: outside the
        // repertoire, exactly as it would be anywhere else in the run.
        return error.InvalidAst;
    }
    var it = Graphemes.iterator(inner[i..]);
    const g = it.next() orelse return .{ .cp = 0, .end = i };
    const gbytes = g.bytes(inner[i..]);
    off.* = i + gbytes.len;
    return .{ .cp = firstCodepoint(gbytes), .end = off.* };
}

/// The first base codepoint of a text target slice: a plain grapheme's
/// first codepoint, or the dotless base for \i/\j escapes (so \'\i → í
/// via the 'i' base).
fn firstTextBase(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0;
    if (bytes[0] == '\\') {
        if (bytes.len >= 2 and bytes[1] == 'i') return 'i';
        if (bytes.len >= 2 and bytes[1] == 'j') return 'j';
        return 0;
    }
    return firstCodepoint(bytes);
}

/// Emit one \text character box (advance from the metric table, boxed by
/// the drawn ink) at the current x; the box spans source bytes
/// [gs, ge) (absolute offsets into the original source).
fn textEmitChar(
    list: *box.BoxList,
    src: []const u8,
    fm: *const metrics.FontMetrics,
    tstyle: atom.CharStyle,
    size_pt: f32,
    cp: u21,
    gs: u32,
    ge: u32,
    x: *f32,
    height: *f32,
    depth: *f32,
) !void {
    var mcp: u21 = cp;
    if (tstyle == .italic) {
        if (mathItalic(cp)) |m| {
            if (metrics.hasGlyph(fm, m, tstyle)) mcp = m;
        }
    }
    var w: f32 = undefined;
    if (metrics.glyphAt(fm, mcp, tstyle, size_pt)) |gm| {
        w = s(gm.width, size_pt);
    } else if (metrics.glyphAt(fm, cp, tstyle, size_pt)) |gm| {
        w = s(gm.width, size_pt);
    } else {
        const cells: u8 = @intCast(DisplayWidth.strWidth(src[gs..ge]));
        w = @as(f32, @floatFromInt(cells)) * size_pt;
    }
    // The drawn glyph's own ink for its face: a text face is boxed by the
    // real ink of the LM Roman design it is drawn in, a math face by the
    // LM Math rows (see `glyphInkAt`).
    const ink = metrics.glyphInkAt(mcp, tstyle);
    const cbox = try list.create(
        .char,
        w,
        ink.asc * size_pt,
        ink.desc * size_pt,
        &.{},
        mcp,
        tstyle,
        size_pt,
        .{ .start = gs, .end = ge },
    );
    // Synthetic when the drawn glyph's utf-8 differs from the source bytes:
    // a math-italic mapping, a precomposed accent (\'\i → í over the "\'\i"
    // source), a dotless \i → ı, ... Flatten then dupes the glyph instead of
    // aliasing the source (which would leak the backslash/braces).
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(mcp, &buf) catch 0;
    if (mcp != cp or n == 0 or !std.mem.eql(u8, buf[0..n], src[gs..ge]))
        list.charDataPtr(cbox).synthetic = true;
    setCharOverhang(list, cbox, ink, size_pt);
    try list.scratch.append(list.gpa, .{ .idx = cbox, .x_shift = x.*, .shift = 0 });
    x.* += w;
    height.* = @max(height.*, ink.asc * size_pt);
    depth.* = @max(depth.*, ink.desc * size_pt);
}

/// Emit one zero-width combining mark (a text accent's combining fallback
/// or a mark inside a source grapheme): the LM fonts draw marks at 0
/// advance, so the box is a zero-width char at the base's position.
fn textEmitMark(
    list: *box.BoxList,
    tstyle: atom.CharStyle,
    size_pt: f32,
    cp: u21,
    gs: u32,
    ge: u32,
    x: *f32,
    height: *f32,
    depth: *f32,
) !void {
    // A text accent's mark is drawn in the text face, so it is bounded by
    // that face's own ink where the generated tables carry it.
    const ink = metrics.glyphInkAt(cp, tstyle);
    const cbox = try list.create(
        .char,
        0, // combining marks are zero-advance in the LM faces
        ink.asc * size_pt,
        ink.desc * size_pt,
        &.{},
        cp,
        tstyle,
        size_pt,
        .{ .start = gs, .end = ge },
    );
    list.charDataPtr(cbox).synthetic = true;
    setCharOverhang(list, cbox, ink, size_pt);
    try list.scratch.append(list.gpa, .{ .idx = cbox, .x_shift = x.*, .shift = 0 });
    height.* = @max(height.*, ink.asc * size_pt);
    depth.* = @max(depth.*, ink.desc * size_pt);
}

/// The width of a `\text` interword space at `size_pt`, in the face the run is
/// being drawn in. The generated LM Roman tables carry a real U+0020 advance
/// per face and `metrics.glyphAt` answers the embedded font first, so a bold or
/// italic space is THAT face's, not the roman one. The static roman path keeps
/// \fontdimen2 exactly (see `text_space_em`), as does a face with no space row.
fn textSpaceWidth(fm: *const metrics.FontMetrics, face: atom.CharStyle, size_pt: f32) f32 {
    const static_arm = switch (fm.*) {
        .static => true,
        .font => false,
    };
    if (static_arm and face == .roman) return text_space_em * size_pt;
    if (metrics.glyphAt(fm, 0x20, face, size_pt)) |g| return s(g.width, size_pt);
    return text_space_em * size_pt;
}

/// Emit a \text interword space in the run's current face at the current x.
fn textEmitSpace(
    list: *box.BoxList,
    fm: *const metrics.FontMetrics,
    face: atom.CharStyle,
    size_pt: f32,
    gs: u32,
    ge: u32,
    x: *f32,
) !void {
    const w = textSpaceWidth(fm, face, size_pt);
    const sb = try list.createLeaf(.glue, w, 0, 0, .{ .start = gs, .end = ge });
    try list.scratch.append(list.gpa, .{ .idx = sb, .x_shift = x.*, .shift = 0 });
    x.* += w;
}

/// Emit a text accent over a base: the precomposed char when one exists,
/// else the base followed by the accent's combining mark (when the base is
/// a plain letter), else the plain base. The backslash is never output.
fn textEmitAccented(
    list: *box.BoxList,
    src: []const u8,
    fm: *const metrics.FontMetrics,
    tstyle: atom.CharStyle,
    size_pt: f32,
    accent: u8,
    base: u21,
    gs: u32,
    ge: u32,
    x: *f32,
    height: *f32,
    depth: *f32,
) !void {
    if (base == 0) return; // no target: the escape emits nothing
    if (base >= 0x80 or !isAsciiLetter(@intCast(base))) {
        // Not an ASCII letter (Greek, digits, ...): emit the base as-is.
        try textEmitChar(list, src, fm, tstyle, size_pt, base, gs, ge, x, height, depth);
        return;
    }
    const b8: u8 = @intCast(base);
    if (textAccentCp(accent, b8)) |cp| {
        try textEmitChar(list, src, fm, tstyle, size_pt, cp, gs, ge, x, height, depth);
        return;
    }
    const mark = textAccentMark(accent);
    // Latin Modern Roman carries every combining mark 0x0300-0x030C plus
    // dot-below 0x0323 and macron-below 0x0331, but NOT cedilla 0x0327 or
    // tie 0x0361 — fall back to the plain base for those (a .notdef box
    // would be worse than no accent).
    if (mark != 0 and mark != 0x0327 and mark != 0x0361) {
        try textEmitChar(list, src, fm, tstyle, size_pt, base, gs, ge, x, height, depth);
        try textEmitMark(list, tstyle, size_pt, mark, gs, ge, x, height, depth);
        return;
    }
    try textEmitChar(list, src, fm, tstyle, size_pt, base, gs, ge, x, height, depth);
}

// ── tests ────────────────

const testing = std.testing;
const fm_default = metrics.default;

test {
    testing.refAllDecls(@This());
}

test "layout: group is transparent (no own box)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x");
    defer a.deinit();
    // hand-build: char 'x' wrapped in a group
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const c = try a.createLeaf(.char, 0, 1, 0); // spans token 0
    const g = try a.createNode(.group, 0, 1, &.{a.node(c)}, 0);
    const b = try layout(&list, &a, g, &fm_default, .text, 10, .italic);
    try testing.expectEqual(.char, list.get(b).kind);
}

test "layout: space becomes a glue box of em width" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "\\,");
    defer a.deinit();
    try a.pushToken(.{ .tag = .command, .start = 0, .end = 2 });
    const sp = try a.createLeaf(.space, 0, 0, f32Bits(0.166));
    const b = try layout(&list, &a, sp, &fm_default, .text, 10, .italic);
    const bb = list.get(b);
    try testing.expectEqual(.glue, bb.kind);
    try testing.expectApproxEqAbs(@as(f32, 1.66), bb.width, 0.01);
}

// A space node's `data` stores the f32 em width as raw bits (ztex.atom's
// `emToFixed`/`fixedToEm` are plain bitcasts — no Q16.16). Build the payload
// the same way the parser does.
fn f32Bits(v: f32) u32 {
    return @bitCast(v);
}

test "layout: sub-only script places subscript below base (F1)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x_2");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .sub, .start = 1, .end = 2 });
    try a.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    const base = try a.createLeaf(.char, 0, 1, 0);
    const sub = try a.createLeaf(.char, 2, 1, 0);
    const children = [_]atom.Node{ a.node(base), a.node(sub) };
    const script = try a.createNode(.script, 0, 3, &children, atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .text, 10, .italic);
    const sb = list.get(b);
    try testing.expectEqual(.script, sb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    // subscript must shift DOWN (positive shift), never up
    try testing.expect(ch[1].shift > 0);
}

test "layout: big operator limits in display style become a vbox" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.sum));
    const sup = try a.createLeaf(.char, 0, 1, 0); // 'a'
    const sub = try a.createLeaf(.char, 1, 1, 0); // 'b'
    const children = [_]atom.Node{ a.node(op), a.node(sup), a.node(sub) };
    const script = try a.createNode(.script, 0, 2, &children, atom.ScriptBits.sup | atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .display, 10, .italic);
    const sb = list.get(b);
    try testing.expectEqual(.vbox, sb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len);
    // children order: [sup, op, sub]; sup above (negative shift), sub below
    try testing.expect(ch[0].shift < 0);
    // display ∑ box is the drawn LM-Math ink extents at gs=1.4*10 (h=10.5, d=3.5)
    // centered on the math axis (2.5pt above baseline): the ∑ ink box at
    // design size 10pt (h=7.5, d=2.5) gives shift = (h−d)/2 − axis = 0
    try testing.expectApproxEqAbs(@as(f32, 0.0), ch[1].shift, 0.001);
    try testing.expect(ch[2].shift > 0);
}

test "layout: big operator beside scripts in text style is a script box" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.sum));
    const sup = try a.createLeaf(.char, 0, 1, 0);
    const children = [_]atom.Node{ a.node(op), a.node(sup) };
    const script = try a.createNode(.script, 0, 1, &children, atom.ScriptBits.sup);
    const b = try layout(&list, &a, script, &fm_default, .text, 10, .italic);
    try testing.expectEqual(.script, list.get(b).kind);
}

test "layout: \\limits forces over/under in TEXT style (TeX applies \\limits in both)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.sum) | atom.LimitsBits.force);
    const sub = try a.createLeaf(.char, 1, 1, 0);
    const children = [_]atom.Node{ a.node(op), a.node(sub) };
    const script = try a.createNode(.script, 0, 2, &children, atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .text, 10, .italic);
    const sb = list.get(b);
    // text style + \limits → the limits vbox, NOT a beside script box
    try testing.expectEqual(.vbox, sb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    // children [op, sub]: the subscript hangs BELOW (positive shift)
    try testing.expect(ch[1].shift > 0);
}

test "layout: \\nolimits forces beside scripts in DISPLAY style" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.sum) | atom.LimitsBits.force_beside);
    const sup = try a.createLeaf(.char, 0, 1, 0);
    const children = [_]atom.Node{ a.node(op), a.node(sup) };
    const script = try a.createNode(.script, 0, 1, &children, atom.ScriptBits.sup);
    const b = try layout(&list, &a, script, &fm_default, .display, 10, .italic);
    // display ∑ default is limits → a vbox; \nolimits forces a beside script box
    try testing.expectEqual(.script, list.get(b).kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    // the superscript sits to the RIGHT of the base (positive x)
    try testing.expect(ch[1].x_shift > 0);
}

test "layout: \\limits on \\int in display style becomes a limits vbox" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const op = try a.createLeaf(.op, 0, 0, @backingInt(atom.BigOp.int) | atom.LimitsBits.force);
    const sub = try a.createLeaf(.char, 1, 1, 0);
    const children = [_]atom.Node{ a.node(op), a.node(sub) };
    const script = try a.createNode(.script, 0, 2, &children, atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .display, 10, .italic);
    // display ∫ default is nolimits (beside); \limits forces the vbox
    try testing.expectEqual(.vbox, list.get(b).kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    // the under-limit hangs BELOW the ∫ (positive shift)
    try testing.expect(ch[1].shift > 0);
}

test "layout: \\limits on an operator word in text style is a limits vbox" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "lim");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const l = try a.createLeaf(.char, 0, 1, 'l');
    const i = try a.createLeaf(.char, 0, 1, 'i');
    const m = try a.createLeaf(.char, 0, 1, 'm');
    const word = try a.createNode(.row, 0, 1, &.{ a.node(l), a.node(i), a.node(m) }, 0);
    const opn = try a.createNode(.opname, 0, 1, &.{a.node(word)}, atom.LimitsBits.force);
    const sub = try a.createLeaf(.char, 0, 1, 0);
    const children = [_]atom.Node{ a.node(opn), a.node(sub) };
    const script = try a.createNode(.script, 0, 1, &children, atom.ScriptBits.sub);
    const b = try layout(&list, &a, script, &fm_default, .text, 10, .italic);
    // \lim defaults to beside in text style; \limits forces "x→0" UNDER the
    // word even in text style → a vbox with the sub below
    try testing.expectEqual(.vbox, list.get(b).kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    try testing.expect(ch[1].shift > 0);
}

test "layout: text yields one char box per grapheme" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{abc}");
    defer a.deinit();
    try a.pushToken(.{ .tag = .l_group, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    try a.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    try a.pushToken(.{ .tag = .char, .start = 3, .end = 4 });
    try a.pushToken(.{ .tag = .r_group, .start = 4, .end = 5 });
    const t = try a.createLeaf(.text, 0, 5, @backingInt(atom.CharStyle.roman));
    const b = try layout(&list, &a, t, &fm_default, .text, 10, .italic);
    const tb = list.get(b);
    try testing.expectEqual(.hbox, tb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len);
    for (ch) |cr| try testing.expectEqual(.char, list.get(cr.idx).kind);
    // a+b+c at 10pt with LM Math roman advances (5.0 + 5.56 + 4.44)
    try testing.expectApproxEqAbs(@as(f32, 15.0), tb.width, 0.01);
}

test "layout: text with a CJK char uses the DisplayWidth fallback" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{界}");
    defer a.deinit();
    try a.pushToken(.{ .tag = .l_group, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 4 });
    try a.pushToken(.{ .tag = .r_group, .start = 4, .end = 5 });
    const t = try a.createLeaf(.text, 0, 3, @backingInt(atom.CharStyle.roman));
    const b = try layout(&list, &a, t, &fm_default, .text, 10, .italic);
    const tb = list.get(b);
    try testing.expectEqual(.hbox, tb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 1), ch.len);
    const cb = list.get(ch[0].idx);
    try testing.expectEqual(.char, cb.kind);
    // fallback dims: h = 0.75*size (ink asc), d = 0.25*size (ink desc),
    // w = DisplayWidth*size
    try testing.expectApproxEqAbs(@as(f32, 7.5), cb.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2.5), cb.depth, 0.01);
    const dw: f32 = @floatFromInt(DisplayWidth.strWidth("界"));
    try testing.expectApproxEqAbs(dw * 10.0, cb.width, 0.01);
}

/// Build the AST the parser makes for a `\text` / `\textit` / `\textbf` run:
/// `a.src` is the run's raw bytes inside their group braces and the `.text`
/// leaf spans every token, so `a.src[span.start + 1 .. span.end - 1]` is the
/// run itself — exactly what the text renderer re-reads. Tokens follow the
/// parser's lexer (a control word is one `.command` token, braces are group
/// tokens, other bytes are `.char`); only the first and last token's byte
/// offsets reach the leaf.
fn textRunLeaf(a: *atom.Ast, face: atom.CharStyle) !u32 {
    var i: usize = 0;
    while (i < a.src.len) {
        const start: u32 = @intCast(i);
        if (a.src[i] == '\\' and i + 1 < a.src.len and isAsciiLetter(a.src[i + 1])) {
            i += 1;
            while (i < a.src.len and isAsciiLetter(a.src[i])) i += 1;
            try a.pushToken(.{ .tag = .command, .start = start, .end = @intCast(i) });
            continue;
        }
        const tag: atom.TokenTag = switch (a.src[i]) {
            '{' => .l_group,
            '}' => .r_group,
            else => .char,
        };
        i += 1;
        try a.pushToken(.{ .tag = tag, .start = start, .end = @intCast(i) });
    }
    return a.createLeaf(.text, 0, @intCast(a.tokens.items.len), @backingInt(face));
}

test "layout: a partial text-face nest draws bold, bold italic, bold and restores" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{a\\textit{b}c}");
    defer a.deinit();
    // The leaf carries the OUTER face; the inner one is a scope in the bytes.
    const leaf = try textRunLeaf(&a, .bold);
    const b = try layout(&list, &a, leaf, &fm_default, .text, 10, .italic);
    const tb = list.get(b);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len);
    const want_face = [_]atom.CharStyle{ .bold, .bold_italic, .bold };
    const want_cp = [_]u21{ 'a', 'b', 'c' };
    for (ch, want_face, want_cp) |cr, face, cp| {
        try testing.expectEqual(face, list.charData(cr.idx).style);
        try testing.expectEqual(cp, list.charData(cr.idx).cp);
    }
    // Every glyph advances by ITS OWN face — bold a 5.59, bold-italic b 5.32,
    // bold c 5.11 — and the run is exactly their sum.
    try testing.expectApproxEqAbs(@as(f32, 16.02), tb.width, 0.01);
    // …and the run is boxed by the tallest and deepest of those faces, not by
    // the first glyph's upright bounds.
    try testing.expectApproxEqAbs(@as(f32, 6.934472), tb.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.08), tb.depth, 0.001);
}

test "layout: a \\text run with an inner \\textit scope is roman, italic, roman" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{a\\textit{b}c}");
    defer a.deinit();
    const leaf = try textRunLeaf(&a, .roman);
    const b = try layout(&list, &a, leaf, &fm_default, .text, 10, .italic);
    const tb = list.get(b);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len);
    const want_face = [_]atom.CharStyle{ .roman, .text_italic, .roman };
    for (ch, want_face) |cr, face| {
        try testing.expectEqual(face, list.charData(cr.idx).style);
    }
    // roman a 5.0 (cmr10) + LM Roman italic b 4.6 + roman c 4.44
    try testing.expectApproxEqAbs(@as(f32, 14.04), tb.width, 0.01);
    // the italic b is 6.94 tall against the upright rows' 4.31
    try testing.expectApproxEqAbs(@as(f32, 6.94), tb.height, 0.01);
}

test "layout: a face scope keeps its own ink, the outer face does not clip it" {
    // \textbf{a\textit{g}c}: the bold-italic g descends 2.02pt while both
    // neighbours are bold (0.06), so the run's depth is the inner face's.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{a\\textit{g}c}");
    defer a.deinit();
    const leaf = try textRunLeaf(&a, .bold);
    const b = try layout(&list, &a, leaf, &fm_default, .text, 10, .italic);
    const tb = list.get(b);
    try testing.expectApproxEqAbs(@as(f32, 2.02), tb.depth, 0.01);
    // height stays the bold a's 4.53 (the bold-italic g is 4.52)
    try testing.expectApproxEqAbs(@as(f32, 4.53), tb.height, 0.01);
}

test "layout: an accent or escape inside a scope is drawn in that scope's face" {
    // \textbf{\'e} is the precomposed é in the BOLD face (5.27pt) and
    // \textit{\i} the dotless ı in the ITALIC one (3.07pt): an escape follows
    // the face in effect inside the run, not the face the run started in.
    const acute = "'";
    const run = "\\textbf{\\" ++ acute ++ "e}\\textit{\\i}";
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{" ++ run ++ "}");
    defer a.deinit();
    const leaf = try textRunLeaf(&a, .roman);
    const b = try layout(&list, &a, leaf, &fm_default, .text, 10, .italic);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    try testing.expectEqual(atom.CharStyle.bold, list.charData(ch[0].idx).style);
    try testing.expectEqual(@as(u21, 0x00E9), list.charData(ch[0].idx).cp);
    try testing.expectApproxEqAbs(@as(f32, 5.27), list.get(ch[0].idx).width, 0.001);
    try testing.expectEqual(atom.CharStyle.text_italic, list.charData(ch[1].idx).style);
    try testing.expectEqual(@as(u21, 0x0131), list.charData(ch[1].idx).cp);
    try testing.expectApproxEqAbs(@as(f32, 3.07), list.get(ch[1].idx).width, 0.001);
}

test "layout: a text run's interword space is the face it is drawn in" {
    // Static roman keeps \fontdimen2 (0.302em = 3.02pt at 10pt); the LM Roman
    // text faces have their own space advance, and a scope switches the space
    // with the face.
    const cases = [_]struct {
        src: []const u8,
        face: atom.CharStyle,
        want: f32,
    }{
        .{ .src = "{a b}", .face = .roman, .want = 3.02 },
        .{ .src = "{a b}", .face = .text_italic, .want = 3.58 },
        .{ .src = "{a b}", .face = .bold, .want = 3.83 },
        // a space inside a nested scope takes that scope's face
        .{ .src = "{a\\textit{b c}}", .face = .bold, .want = 4.14 },
    };
    for (cases) |c| {
        var list = box.BoxList.init(testing.allocator);
        defer list.deinit();
        var a = atom.Ast.init(testing.allocator, c.src);
        defer a.deinit();
        const leaf = try textRunLeaf(&a, c.face);
        const b = try layout(&list, &a, leaf, &fm_default, .text, 10, .italic);
        var glues: usize = 0;
        for (list.children(b)) |cr| {
            const cb = list.get(cr.idx);
            if (cb.kind != .glue) continue;
            glues += 1;
            try testing.expectApproxEqAbs(c.want, cb.width, 0.001);
        }
        try testing.expectEqual(@as(usize, 1), glues);
    }
}

test "layout: an overdeep raw text leaf is invalid" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const depth = atom.max_text_nesting + 8;
    const open = comptime blk: {
        var bytes: [depth * "\\textit{".len]u8 = undefined;
        for (0..depth) |i| {
            @memcpy(bytes[i * "\\textit{".len ..][0.."\\textit{".len], "\\textit{");
        }
        break :blk bytes;
    };
    const run = open ++ "x" ++ @as([depth]u8, @splat('}'));
    var a = atom.Ast.init(testing.allocator, "{" ++ run ++ "}");
    defer a.deinit();
    const leaf = try textRunLeaf(&a, .roman);
    try testing.expectError(
        error.InvalidAst,
        layout(&list, &a, leaf, &fm_default, .text, 10, .italic),
    );
}

test "layout: a raw text leaf with an unsupported escape is invalid" {
    // The parser already rejects these in a real parse (`UnknownCommand` plus
    // the exact span), but a hand-built leaf can carry them, and a `\text` run
    // has no layout for anything outside `atom.textCommandSupported`. Swallowing
    // the name and emitting nothing is how a formula lost whole words, so such
    // a run is invalid rather than quietly short.
    const cases = [_][]const u8{
        "{a\\LaTeX b}", // a control word outside the repertoire
        "{a\\mathrm{b}c}", // a real command, still not a text-run escape
        "{a\\\\b}", // a line break: one hbox has no line model
        "{a\\@b}", // a symbol escape outside the repertoire
        "{ab\\}", // a trailing backslash inside the frame is not an escape
        "{ab\\", // and a run that never closes its frame is not a text run
    };
    for (cases) |src| {
        var list = box.BoxList.init(testing.allocator);
        defer list.deinit();
        var a = atom.Ast.init(testing.allocator, src);
        defer a.deinit();
        const leaf = try textRunLeaf(&a, .roman);
        try testing.expectError(
            error.InvalidAst,
            layout(&list, &a, leaf, &fm_default, .text, 10, .italic),
        );
    }
}

test "layout: the raw text repertoire's literal escapes all reach the page" {
    // The seven characters LaTeX makes an escape out of draw themselves, in
    // order, and the backslash never leaks: the repertoire that rejects
    // everything outside it must keep admitting these.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "{\\$\\%\\&\\#\\_\\{\\}}");
    defer a.deinit();
    const leaf = try textRunLeaf(&a, .roman);
    const b = try layout(&list, &a, leaf, &fm_default, .text, 10, .italic);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 7), ch.len);
    for (ch, [_]u21{ 0x24, 0x25, 0x26, 0x23, 0x5F, 0x7B, 0x7D }) |cr, cp| {
        try testing.expectEqual(.char, list.get(cr.idx).kind);
        try testing.expectEqual(cp, list.charData(cr.idx).cp);
        // synthetic: the drawn glyph is the escaped char, not the `\$` bytes.
        try testing.expect(list.charData(cr.idx).synthetic);
    }
}

test "layout: styled wraps a char with the declared style" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const c = try a.createLeaf(.char, 0, 1, 0);
    const st = try a.createNode(.styled, 0, 1, &.{a.node(c)}, @backingInt(atom.CharStyle.roman));
    const b = try layout(&list, &a, st, &fm_default, .text, 10, .italic);
    const cb = list.get(b);
    try testing.expectEqual(.char, cb.kind);
    try testing.expectEqual(atom.CharStyle.roman, list.charData(b).style);
}

test "layout: atop fraction is a vbox with no rule child" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const frac = try a.createNode(
        .fraction,
        0,
        2,
        &.{ a.node(num), a.node(den) },
        atom.fracData(false, null, false), // atop: no rule line
    );
    const b = try layout(&list, &a, frac, &fm_default, .text, 10, .italic);
    const fb = list.get(b);
    try testing.expectEqual(.vbox, fb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    for (ch) |cr| try testing.expectEqual(.char, list.get(cr.idx).kind);
}

test "layout: dfrac in a script context renders at display size (text-size parts)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "12");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const frac = try a.createNode(
        .fraction,
        0,
        2,
        &.{ a.node(num), a.node(den) },
        atom.fracData(true, .display, false),
    );
    // laid out in a SCRIPT context (7pt): \dfrac forces display → the parts
    // jump back to the text size (10pt) with display gaps (num1/denom1).
    const b = try layout(&list, &a, frac, &fm_default, .script, 7, .italic);
    const fb = list.get(b);
    try testing.expectEqual(.vbox, fb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len); // num, rule, den
    const nb = list.get(ch[0].idx);
    try testing.expectEqual(.char, nb.kind);
    // part at 10pt (text size), NOT the plain-fraction 7×0.5 = 3.5pt
    try testing.expectApproxEqAbs(@as(f32, 10.0), list.charData(ch[0].idx).size, 0.01);
    // the rule sits on the axis at the effective (10pt) scale
    try testing.expectApproxEqAbs(@as(f32, -2.5), ch[1].shift, 0.01);
    // display fraction at 10pt: num1 (6.765) above the axis, denom1 (6.8595) below
    try testing.expectApproxEqAbs(@as(f32, 6.765 + nb.height), fb.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 6.8595 + list.get(ch[2].idx).depth), fb.depth, 0.01);
}

test "layout: tfrac in display keeps text gaps and script-size parts" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "12");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const frac = try a.createNode(.fraction, 0, 2, &.{ a.node(num), a.node(den) }, atom.fracData(true, .text, false));
    const b = try layout(&list, &a, frac, &fm_default, .display, 10, .italic);
    const fb = list.get(b);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 3), ch.len);
    // \tfrac parts are script-size (7pt), not the display \frac's 10pt
    try testing.expectApproxEqAbs(@as(f32, 7.0), list.charData(ch[0].idx).size, 0.01);
    // text gaps: num2 (3.9373) not num1 (6.765)
    try testing.expectApproxEqAbs(@as(f32, 3.9373 + list.get(ch[0].idx).height), fb.height, 0.01);
}

test "layout: cfrac sets both parts in display style (uncramped, display gaps)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "12");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const frac = try a.createNode(.fraction, 0, 2, &.{ a.node(num), a.node(den) }, atom.fracData(true, .display, true));
    const b = try layout(&list, &a, frac, &fm_default, .text, 10, .italic);
    const ch = list.children(b);
    // parts in DISPLAY style: same text size but the box carries display
    // style semantics (uncramped; gap params num1/denom1 like display)
    try testing.expectApproxEqAbs(@as(f32, 10.0), list.charData(ch[0].idx).size, 0.01);
    // The cfrac NUMERATOR is \strut #2 (amsmath): a display-size strut
    // forces the numerator box to height 0.84em (a char with height 1pt
    // gets strutted up to 0.84×10 = 8.4) and depth 0.36em. So the vbox
    // height = num1 (6.765) + max(1, 8.4) = 15.165, not the bare char's.
    // num1 6.765 + clearance bump (clr 3*rt=1.2 - kern1, where
    // kern1 = 6.765 - strut_depth 3.6 - (axis 2.5 + rt/2 0.2) = 0.465
    // → bump 0.735) + strut height 0.84*10=8.4 = 15.9.
    try testing.expectApproxEqAbs(@as(f32, 15.9), list.get(b).height, 0.01);
}

test "layout: a radical reads the display clearance gap in display style alone" {
    // XeTeX takes RadicalDisplayStyleVerticalGap (0.148em) in DISPLAY style and
    // RadicalVerticalGap (0.05em) in text/script/scriptscript — the MATH table
    // has no text-style gap. Over a 20pt \frac ab (h+d 21.122) the text radical
    // needs 21.122 + 1.0 + θ 0.8 = 22.92pt, which radical.v1 covers (advance
    // 1.201em = 24.02), while the display gap raised the requirement to 24.88
    // and bought the 1.801em .v2: a 36pt surd for a 21pt radicand, its 11.1pt
    // excess floating the vinculum 8.5pt clear of the numerator. Measured
    // XeTeX (20.075pt em): \textstyle the rule kerns 0.05em then half the .v1
    // excess (clr 1.544), \displaystyle 0.148em then half the .v3 excess
    // (clr 6.944) — the glyphs are radical.v1 (gid 3081) and .v3 (gid 3083).
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "sqrtab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    try a.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    try a.pushToken(.{ .tag = .char, .start = 3, .end = 4 });
    const num = try a.createLeaf(.char, 1, 1, 0x1D44E); // 𝑎
    const den = try a.createLeaf(.char, 2, 1, 0x1D44F); // 𝑏
    const frac = try a.createNode(
        .fraction,
        1,
        2,
        &.{ a.node(num), a.node(den) },
        atom.fracData(true, null, false),
    );
    const surd = try a.createLeaf(.char, 0, 1, 0x221A);
    const row = try a.createNode(
        .row,
        0,
        4,
        &.{ a.node(surd), a.node(frac) },
        sqrt_row_data,
    );
    for ([_]struct { style: Style, extent: f32 }{
        .{ .style = .text, .extent = 24.80 },
        .{ .style = .display, .extent = 48.80 },
    }) |c| {
        const b = try layout(&list, &a, row, &fm_default, c.style, 20, .italic);
        const bb = list.get(b);
        // Exact-font XeTeX box extents, rescaled from its 20.075pt em.
        // Static glyph metrics account for the sub-point difference.
        try testing.expectApproxEqAbs(c.extent, bb.height + bb.depth, 0.6);
    }
}

test "layout: mathstyle wrapper forces style and rescales size" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const c = try a.createLeaf(.char, 0, 1, 0);
    // \scriptstyle in display context: content shrinks to script size (7pt)
    const ms1 = try a.createNode(.mathstyle, 0, 1, &.{a.node(c)}, @backingInt(atom.MathStyle.script));
    const b1 = try layout(&list, &a, ms1, &fm_default, .display, 10, .italic);
    try testing.expectApproxEqAbs(@as(f32, 7.0), list.charData(b1).size, 0.01);
    // \displaystyle in a script context: content grows back to text size (10pt)
    const ms2 = try a.createNode(.mathstyle, 0, 1, &.{a.node(c)}, @backingInt(atom.MathStyle.display));
    const b2 = try layout(&list, &a, ms2, &fm_default, .script, 7, .italic);
    try testing.expectApproxEqAbs(@as(f32, 10.0), list.charData(b2).size, 0.01);
}

test "layout: unknown codepoint falls back to glyph estimate" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "😀"); // U+1F600, 4 bytes
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 4 });
    const c = try a.createLeaf(.char, 0, 1, 0);
    const b = try layout(&list, &a, c, &fm_default, .text, 10, .italic);
    const cb = list.get(b);
    try testing.expectEqual(.char, cb.kind);
    try testing.expect(cb.width > 0);
    // glyphEstimate at 10pt: 0.5em wide, 0.7em tall, 0.2em deep
    try testing.expectApproxEqAbs(@as(f32, 5.0), cb.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 7.5), cb.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2.5), cb.depth, 0.01);
}

test "layout: math-italic maps against the static table (Latin yes, Greek no)" {
    // The systematic math-italic mapping (mathItalic) is validated against
    // the ACTIVE metric source. With the bundled tables (fm_default, no
    // font), a mapped codepoint is only emitted when the static table
    // carries it: the tables cover the U+1D4xx Latin series (and U+210E)
    // but NOT the U+1D6xx Greek series, so `x` maps to U+1D465 while
    // `\alpha` keeps its base U+03B1 — the graceful static fallback.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();

    var a1 = atom.Ast.init(testing.allocator, "x");
    defer a1.deinit();
    try a1.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const c1 = try a1.createLeaf(.char, 0, 1, 0);
    const b1 = try layout(&list, &a1, c1, &fm_default, .text, 10, .italic);
    try testing.expectEqual(@as(u21, 0x1D465), list.charData(b1).cp);

    var a2 = atom.Ast.init(testing.allocator, "α"); // U+03B1, like \alpha
    defer a2.deinit();
    try a2.pushToken(.{ .tag = .char, .start = 0, .end = 2 });
    const c2 = try a2.createLeaf(.char, 0, 1, 0x03B1);
    const b2 = try layout(&list, &a2, c2, &fm_default, .text, 10, .italic);
    try testing.expectEqual(@as(u21, 0x03B1), list.charData(b2).cp);
}

test "layout: substack stacks two lines at script size with the subarray gap" {
    // \substack{i=1 \\ j=2} at display 10pt: lines at 7pt, baseline
    // separation = max(0.789·7, d1 + h2 + 0.120·7), each line centered.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "substack");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 8 }); // span source
    // line 1: 'i','=','1'  line 2: 'j','=','2' (explicit codepoints so the
    // boxes are deterministic: i 0x1D456, = 0x3D, 1 0x31, j 0x1D457, 2 0x32)
    var line1 = std.ArrayList(atom.Node).empty;
    defer line1.deinit(testing.allocator);
    for ([_]u21{ 0x1D456, 0x3D, 0x31 }) |cp| {
        const c = try a.createLeaf(.char, 0, 1, cp);
        try line1.append(testing.allocator, a.node(c));
    }
    const l1 = try a.createNode(.row, 0, 1, line1.items, 0);
    var line2 = std.ArrayList(atom.Node).empty;
    defer line2.deinit(testing.allocator);
    for ([_]u21{ 0x1D457, 0x3D, 0x32 }) |cp| {
        const c = try a.createLeaf(.char, 0, 1, cp);
        try line2.append(testing.allocator, a.node(c));
    }
    const l2 = try a.createNode(.row, 0, 1, line2.items, 0);
    const st = try a.createNode(.substack, 0, 1, &.{ a.node(l1), a.node(l2) }, 0);
    const b = try layout(&list, &a, st, &fm_default, .display, 10, .italic);
    const sb = list.get(b);
    try testing.expectEqual(.hbox, sb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(u32, 2), sb.num_children);
    // both lines at script size 7pt (the line's char boxes carry the size;
    // the hbox itself has size 0)
    const l1b = list.get(ch[0].idx);
    const l2b = list.get(ch[1].idx);
    try testing.expectApproxEqAbs(@as(f32, 7.0), list.charData(list.children(ch[0].idx)[0].idx).size, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 7.0), list.charData(list.children(ch[1].idx)[0].idx).size, 0.01);
    // baseline separation: d1 + h2 + 0.120·7 (the lines beat the nominal
    // 0.789·7 baselineskip — digit-height lines, like the 36pt reference)
    const sep = ch[1].shift - ch[0].shift;
    const expected = l1b.depth + l2b.height + 0.120 * 7.0;
    try testing.expectApproxEqAbs(expected, sep, 0.01);
    // centered: each line's x_shift = (max_w − w)/2
    const max_w = @max(l1b.width, l2b.width);
    try testing.expectApproxEqAbs((max_w - l1b.width) / 2, ch[0].x_shift, 0.001);
    try testing.expectApproxEqAbs((max_w - l2b.width) / 2, ch[1].x_shift, 0.001);
    // box: width = max line width, height = line-1 height, depth = last
    // line baseline + depth (bounds every line's ink)
    try testing.expectApproxEqAbs(max_w, sb.width, 0.001);
    try testing.expectApproxEqAbs(l1b.height, sb.height, 0.001);
    try testing.expectApproxEqAbs(ch[1].shift + l2b.depth, sb.depth, 0.001);
}

test "layout: pmod composes kern, parens, mod word, 6mu gap and arg" {
    // \pmod{n} at display 10pt: leading 8mu (8/18·10 = 4.444pt — the lead
    // is style-INVARIANT: the amsmath \if@display 18mu branch never fires
    // inside \array cells, measured on XeTeX) + ( + mod word
    // (0.833+0.5+0.556 em) + 6mu (10/3 pt) + n (0.6em) + ) — the children
    // are ['(', mod-opname, 6mu space, n, ')'].
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "pmod");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 4 }); // span source
    const open = try a.createLeaf(.char, 0, 1, 0x28);
    // the roman mod word: opname wrapping a row of m,o,d letter leaves
    var letters = std.ArrayList(atom.Node).empty;
    defer letters.deinit(testing.allocator);
    for ([_]u21{ 'm', 'o', 'd' }) |cp| {
        const c = try a.createLeaf(.char, 0, 1, cp);
        try letters.append(testing.allocator, a.node(c));
    }
    const word_row = try a.createNode(.row, 0, 1, letters.items, 0);
    const word = try a.createNode(.opname, 0, 1, &.{a.node(word_row)}, 0);
    const gap = try a.createLeaf(.space, 0, 1, atom.emToFixed(6.0 / 18.0));
    const arg = try a.createLeaf(.char, 0, 1, 0x1D45B); // math-italic n
    const close = try a.createLeaf(.char, 0, 1, 0x29);
    const row = try a.createNode(
        .row,
        0,
        1,
        &.{ a.node(open), a.node(word), a.node(gap), a.node(arg), a.node(close) },
        pmod_row_data,
    );
    const b = try layout(&list, &a, row, &fm_default, .display, 10, .italic);
    const rb = list.get(b);
    try testing.expectEqual(.hbox, rb.kind);
    // leading 8mu = 8/18 em at EVERY style (display included)
    const expect_w = 10.0 * 8.0 / 18.0 + 0.389 * 10 + (0.833 + 0.5 + 0.556) * 10 + 10.0 / 3.0 + 0.6 * 10 + 0.389 * 10;
    try testing.expectApproxEqAbs(expect_w, rb.width, 0.01);
    // the first child is the 8mu glue, the paren/word/gap/arg/close follow
    const ch = list.children(b);
    try testing.expectEqual(@as(u32, 6), rb.num_children);
    try testing.expectEqual(.glue, list.get(ch[0].idx).kind);
    try testing.expectApproxEqAbs(@as(f32, 10.0 * 8.0 / 18.0), list.get(ch[0].idx).width, 0.01);
    // the mod word renders roman: its letters are upright ASCII
    const wb = list.get(ch[2].idx);
    try testing.expectEqual(.hbox, wb.kind);
}

test "layout: pod omits the mod word and keeps the 8mu kern in text style" {
    // \pod{n} at text 10pt: 8mu = 8/18·10 leading + ( + n + ).
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "pod");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 3 }); // span source
    const open = try a.createLeaf(.char, 0, 1, 0x28);
    const arg = try a.createLeaf(.char, 0, 1, 0x1D45B);
    const close = try a.createLeaf(.char, 0, 1, 0x29);
    const row = try a.createNode(.row, 0, 1, &.{ a.node(open), a.node(arg), a.node(close) }, pod_row_data);
    const b = try layout(&list, &a, row, &fm_default, .text, 10, .italic);
    const rb = list.get(b);
    const expect_w = 10.0 * 8.0 / 18.0 + 0.389 * 10 + 0.6 * 10 + 0.389 * 10;
    try testing.expectApproxEqAbs(expect_w, rb.width, 0.01);
}

/// Lay out a hand-built char leaf for `cp` (an explicit codepoint, as the
/// parser emits for a synthesized glyph) at `style` / `size_pt`, and return
/// the box index so a test can compare a construct against its own parts.
fn charBox(
    list: *box.BoxList,
    a: *atom.Ast,
    cp: u21,
    style: Style,
    size_pt: f32,
) !u32 {
    const leaf = try a.createLeaf(.char, 0, 1, cp);
    return layout(list, a, leaf, &fm_default, style, size_pt, .italic);
}

/// Push one single-byte char token per source byte, so a hand-built leaf can
/// re-read its codepoint from the source span the way the parser's do.
fn pushCharTokens(a: *atom.Ast, src: []const u8) !void {
    for (src, 0..) |_, i| {
        try a.pushToken(.{
            .tag = .char,
            .start = @intCast(i),
            .end = @intCast(i + 1),
        });
    }
}

/// A `\script`-style size at the 10pt base (gl.scriptfactor).
const script_size: f32 = 7.0;

test "layout: \\stackrel is a relation, \\overset takes no inter-atom class" {
    // The kernel's \stackrel IS a \mathrel (thick 5mu on both sides); amsmath's
    // \overset expands to an EMPTY \mathrel before the construct, which takes
    // no class, so its neighbours add no glue. Measured on XeTeX:
    // `x\stackrel{a}{b}` = x + 5mu + construct + 5mu + y, `x\overset{a}{b}y` =
    // x + construct + y.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "stackrel");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 8 });
    const thick = 5.0 * 10.0 / 18.0; // glue_em[3] at 10pt
    for ([_]struct { data: u32, want_glue: f32 }{
        .{ .data = stackrel_row_data, .want_glue = 2 * thick },
        .{ .data = overset_row_data, .want_glue = 0 },
        .{ .data = underset_row_data, .want_glue = 0 },
    }) |c| {
        const script = try a.createLeaf(.char, 0, 1, 0x1D466);
        const base = try a.createLeaf(.char, 0, 1, 0x1D465);
        const limits = try a.createNode(.row, 0, 1, &.{ a.node(script), a.node(base) }, c.data);
        const x1 = try a.createLeaf(.char, 0, 1, 0x1D465);
        const x2 = try a.createLeaf(.char, 0, 1, 0x1D465);
        const kids = [_]atom.Node{ a.node(x1), a.node(limits), a.node(x2) };
        const row = try a.createNode(.row, 0, 1, &kids, 0);
        const b = try layout(&list, &a, row, &fm_default, .text, 10, .italic);
        // The construct's own box (laid out standalone; the row boxes it
        // identically) plus the two neighbours and the class's glue.
        const construct = list.get(try layout(&list, &a, limits, &fm_default, .text, 10, .italic));
        const xb = list.get(try charBox(&list, &a, 0x1D465, .text, 10));
        const want = 2 * xb.width + construct.width + c.want_glue;
        try testing.expectApproxEqAbs(want, list.get(b).width, 0.01);
    }
}

test "layout: the phantoms are invisible and \\smash still draws" {
    // \phantom reserves the whole box, \vphantom the height and depth and
    // \hphantom only the width — each an INVISIBLE box, latex.ltx's
    // \finph@nt, which a .strut is by construction. \smash keeps the
    // advance and zeroes the axes it is given, but it is NOT one of those:
    // amsmath builds it as `\hbox to <width>{\vbox to 0pt{…}\vss}`, a real
    // box that still PAINTS its content (a \smash{b} that drew nothing came
    // out as a bare background rectangle).
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "phantom");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 7 });

    const content_box = try charBox(&list, &a, 0x1D45E, .text, 10); // q
    const cb = list.get(content_box);
    // The phantom must be able to CLEAR both axes: q has a real descender and
    // a height above the x-height.
    try testing.expect(cb.height > 0 and cb.depth > 0 and cb.width > 0);

    // \\phantom keeps all three, \\vphantom the height and depth,
    // \\hphantom the width; \\smash[t] drops the height, \\smash[b] the
    // depth, and the default [tb] both.
    const full = phantom_row_data | keep_width | keep_height | keep_depth;
    const cases = [_]struct { data: u32, w: f32, h: f32, d: f32 }{
        .{ .data = full, .w = cb.width, .h = cb.height, .d = cb.depth },
        .{ .data = phantom_row_data | keep_height | keep_depth, .w = 0, .h = cb.height, .d = cb.depth },
        .{ .data = phantom_row_data | keep_width, .w = cb.width, .h = 0, .d = 0 },
        .{
            .data = smash_row | phantom_row_data | keep_width,
            .w = cb.width,
            .h = 0,
            .d = 0,
        },
        .{
            .data = smash_row | phantom_row_data | keep_width | keep_depth,
            .w = cb.width,
            .h = 0,
            .d = cb.depth,
        },
        .{
            .data = smash_row | phantom_row_data | keep_width | keep_height,
            .w = cb.width,
            .h = cb.height,
            .d = 0,
        },
    };
    for (cases) |c| {
        const content = try a.createLeaf(.char, 0, 1, 0x1D45E);
        const row = try a.createNode(.row, 0, 1, &.{a.node(content)}, c.data);
        const b = try layout(&list, &a, row, &fm_default, .text, 10, .italic);
        const rb = list.get(b);
        try testing.expectApproxEqAbs(c.w, rb.width, 0.0001);
        try testing.expectApproxEqAbs(c.h, rb.height, 0.0001);
        try testing.expectApproxEqAbs(c.d, rb.depth, 0.0001);
        if (c.data & smash_row != 0) {
            // \smash: a real box holding the drawn content, with the
            // smashed axes flattened to nothing.
            try testing.expectEqual(.hbox, rb.kind);
            try testing.expectEqual(@as(u16, 1), rb.num_children);
            const held = list.children(b);
            try testing.expectEqual(.char, list.get(held[0].idx).kind);
            try testing.expectEqual(@as(u21, 0x1D45E), list.charData(held[0].idx).cp);
        } else {
            // \phantom / \vphantom / \hphantom: an empty metrics-only box.
            try testing.expectEqual(.strut, rb.kind);
            try testing.expectEqual(@as(u16, 0), rb.num_children);
        }
    }
}

test "layout: a face without the brace's horizontal form keeps the base glyph" {
    // A wired face that declares no construction for the brace answers null —
    // a real "no such form" — and the bundled ladder must NOT be stood in for
    // it: the band degrades to the glyph's OWN base form at the base size,
    // records no request (so the back ends draw that same glyph), and never
    // replaces it with a synthesised stroke. A resolver that FAILS stays an
    // error instead of quietly painting some other form.
    const glyph_hook = struct {
        fn get(_: *anyopaque, _: u21, _: atom.CharStyle, _: f32) ?metrics.Glyph {
            return null;
        }
    }.get;
    const absent = struct {
        fn get(_: *anyopaque, _: u21, _: f32) metrics.StretchError!?metrics.StretchGeometry {
            return null;
        }
    }.get;
    const failing = struct {
        fn get(_: *anyopaque, _: u21, _: f32) metrics.StretchError!?metrics.StretchGeometry {
            return error.OutOfMemory;
        }
    }.get;
    var anchor: u8 = 0;
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "underbrace");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 10 });

    const content = try a.createLeaf(.char, 0, 1, 0x1D465);
    const row = try a.createNode(.row, 0, 1, &.{a.node(content)}, underbrace_row_data);

    const no_form: metrics.FontMetrics = .{ .font = .{
        .ctx = &anchor,
        .glyph = glyph_hook,
        .horizontal_glyph = absent,
    } };
    const b = try layout(&list, &a, row, &no_form, .text, 10, .italic);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 2), ch.len);
    const band = ch[1];
    const bb = list.get(band.idx);
    const cd = list.charData(band.idx);
    try testing.expectEqual(.char, bb.kind);
    try testing.expectEqual(@as(u21, 0x23DF), cd.cp);
    try testing.expectEqual(@as(f32, 0), cd.horizontal_req);
    // No construction: preserve the base glyph's advance and ink.
    const base = metrics.glyphAt(&no_form, 0x23DF, .italic, 10) orelse
        metrics.glyphEstimate(&no_form, 0x23DF, .italic);
    const ink = metrics.glyphInkAt(0x23DF, .italic);
    try testing.expectApproxEqAbs(base.width, bb.width, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), bb.height, 0.0001);
    try testing.expectApproxEqAbs(ink.desc * 10, bb.depth, 0.0001);

    const broken: metrics.FontMetrics = .{ .font = .{
        .ctx = &anchor,
        .glyph = glyph_hook,
        .horizontal_glyph = failing,
    } };
    try testing.expectError(
        error.OutOfMemory,
        layout(&list, &a, row, &broken, .text, 10, .italic),
    );
}

test "layout: mu spacing is style-invariant while em spacing follows the style" {
    // \mkern4mu reserves 4/18 em of the ladder-NEUTRAL em: the same width in
    // display, text AND script style (a mu skip does not shrink with the
    // script ladder). \hspace{1em} is the CURRENT em, so it follows the
    // ladder; \hspace{2pt} is absolute and never scales.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "kern");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 4 });
    const mu = 4.0 * 10.0 / 18.0;
    for ([_]struct { unit: u32, value: f32 }{
        .{ .unit = dim_mu, .value = 4 },
        .{ .unit = dim_em, .value = 1 },
        .{ .unit = dim_pt, .value = 2 },
    }) |c| {
        const leaf = try a.createLeaf(.space, 0, 1, atom.emToFixed(c.value));
        const row = try a.createNode(.row, 0, 1, &.{a.node(leaf)}, kern_row_data | c.unit);
        for ([_]struct { style: Style, size_pt: f32 }{
            .{ .style = .display, .size_pt = 10 },
            .{ .style = .text, .size_pt = 10 },
            .{ .style = .script, .size_pt = script_size },
        }) |st| {
            const b = try layout(&list, &a, row, &fm_default, st.style, st.size_pt, .italic);
            const k = list.get(b);
            try testing.expectEqual(.glue, k.kind);
            const want: f32 = switch (c.unit) {
                dim_mu => mu,
                dim_em => c.value * st.size_pt,
                else => c.value,
            };
            try testing.expectApproxEqAbs(want, k.width, 0.0001);
        }
    }
}

test "layout: the constant spaces keep their em widths" {
    // Regression guard: \, \; \! \quad \qquad and the interword space \  are
    // plain em-fraction space leaves (style-dependent through size_pt), and
    // `\:` is the mu skip above — none of them changed.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, " ");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const em_widths = [_]f32{ 0.166, 0.277, -0.166, 1.0, 2.0, 1.0 / 3.0 };
    for (em_widths) |em| {
        const leaf = try a.createLeaf(.space, 0, 1, atom.emToFixed(em));
        const text_b = try layout(&list, &a, leaf, &fm_default, .text, 10, .italic);
        try testing.expectApproxEqAbs(em * 10, list.get(text_b).width, 0.0001);
        // A space leaf scales with the style's size, unlike a mu skip.
        const script_b = try layout(&list, &a, leaf, &fm_default, .script, script_size, .italic);
        try testing.expectApproxEqAbs(em * script_size, list.get(script_b).width, 0.0001);
    }
}

/// A one-child row carrying a forced class around the glyph `cp` — the shape
/// the parser builds for `\mathord`…`\mathinner` and `\colon` — or the bare
/// char leaf when `cls` is null (a typed glyph, whose class layout derives
/// from the codepoint).
fn classProbeMid(a: *atom.Ast, cp: u21, cls: ?atom.MathClass) !atom.Node {
    const leaf = try a.createLeaf(.char, 0, 1, cp);
    if (cls) |c| {
        return a.node(try a.createNode(.row, 0, 1, &.{a.node(leaf)}, atom.classRowData(c)));
    }
    return a.node(leaf);
}

/// Lay out `x <mid> y` at 10pt text style, where the middle atom is either
/// the bare glyph `cp` or that same glyph wrapped in a forced class — the two
/// shapes `\mathrel{...}` and a bare relation produce. The neighbours are
/// math-italic 𝑥/𝑦, whose italic corrections are 0 in the IC table, so the
/// row's width differs by the GLUE alone.
fn classProbeRow(
    list: *box.BoxList,
    a: *atom.Ast,
    cp: u21,
    cls: ?atom.MathClass,
) !f32 {
    const x = try a.createLeaf(.char, 0, 1, 0x1D465);
    const y = try a.createLeaf(.char, 0, 1, 0x1D466);
    const kids = [_]atom.Node{ a.node(x), try classProbeMid(a, cp, cls), a.node(y) };
    const row = try a.createNode(.row, 0, 1, &kids, 0);
    return list.get(try layout(list, a, row, &fm_default, .text, 10, .italic)).width;
}

/// The same probe as `classProbeRow`, but as the NUMERATOR of a ruled
/// fraction over a 𝑘: the class must reach the glue wherever the wrapper sits.
fn fracProbeWidth(
    list: *box.BoxList,
    a: *atom.Ast,
    cp: u21,
    cls: ?atom.MathClass,
) !f32 {
    const x = try a.createLeaf(.char, 0, 1, 0x1D465);
    const y = try a.createLeaf(.char, 0, 1, 0x1D466);
    const num = try a.createNode(
        .row,
        0,
        1,
        &.{ a.node(x), try classProbeMid(a, cp, cls), a.node(y) },
        0,
    );
    const den = try a.createLeaf(.char, 0, 1, 0x1D4F7);
    const frac = try a.createNode(
        .fraction,
        0,
        1,
        &.{ a.node(num), a.node(den) },
        atom.fracData(true, null, false),
    );
    // DISPLAY style, so the numerator is set at TEXT style: the thick
    // relation spaces are suppressed in the script styles (the glue table's
    // script column is 0 for med/thick), and this probe is about the CLASS.
    return list.get(try layout(list, a, frac, &fm_default, .display, 10, .italic)).width;
}

/// The 10pt text-style glue of one class pair, from the TeX table
/// (tex.web §799): thin 3/18, med 4/18, thick 5/18 em of the current size.
fn glueAt(units: u8) f32 {
    return glue_em[units] * 10.0 / 18.0;
}

test "layout: a forced class replaces the atom's own class on both sides" {
    // TeX's \mathXXX must reach the GLUE, not just the tree. A forced rel
    // around a glyph that is itself a bin takes the relation's thick 5/18 em
    // on BOTH sides; a forced ord around the same bin takes none; a forced
    // bin around a glyph that is itself a rel drops the thick to med. Every
    // wrapper is the parser's shape: a `.row` of one child whose `data` is
    // atom.classRowData(cls).
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x-y");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const eq = 0x3D; // `=` — a relation
    const minus = 0x2212; // the glyph a `-` draws — a bin
    const thick = glueAt(3);
    const med = glueAt(2);
    const thin = glueAt(1);

    // `=` is already a relation: forcing rel reproduces the bare row exactly,
    // and forcing another class moves both sides away from thick.
    const bare_eq = try classProbeRow(&list, &a, eq, null);
    try testing.expectApproxEqAbs(bare_eq, try classProbeRow(&list, &a, eq, .rel), 0.0001);
    try testing.expectApproxEqAbs(bare_eq - 2 * thick, try classProbeRow(&list, &a, eq, .ord), 0.01);
    try testing.expectApproxEqAbs(
        bare_eq - 2 * (thick - med),
        try classProbeRow(&list, &a, eq, .bin),
        0.01,
    );
    // open/close take nothing against an ord neighbour; punct takes nothing
    // BEFORE it and a thin space after (ord→punct is 0, punct→ord is thin).
    try testing.expectApproxEqAbs(bare_eq - 2 * thick, try classProbeRow(&list, &a, eq, .open), 0.01);
    try testing.expectApproxEqAbs(bare_eq - 2 * thick, try classProbeRow(&list, &a, eq, .close), 0.01);
    try testing.expectApproxEqAbs(
        bare_eq - 2 * thick + thin,
        try classProbeRow(&list, &a, eq, .punct),
        0.01,
    );
    // inner takes a thin space on both sides.
    try testing.expectApproxEqAbs(
        bare_eq - 2 * (thick - thin),
        try classProbeRow(&list, &a, eq, .inner),
        0.01,
    );

    // `-` is a bin: forcing bin reproduces the bare row, forcing ord removes
    // the med spaces, and forcing rel promotes them to thick.
    const bare_minus = try classProbeRow(&list, &a, minus, null);
    try testing.expectApproxEqAbs(bare_minus, try classProbeRow(&list, &a, minus, .bin), 0.0001);
    try testing.expectApproxEqAbs(bare_minus - 2 * med, try classProbeRow(&list, &a, minus, .ord), 0.01);
    try testing.expectApproxEqAbs(
        bare_minus + 2 * (thick - med),
        try classProbeRow(&list, &a, minus, .rel),
        0.01,
    );
}

test "layout: a forced class still spaces inside a fraction" {
    // The override is a property of the ATOM, not of the row it happens to
    // sit in: the same two thick spaces appear when the wrapped relation is
    // the numerator of a fraction, so the whole fraction is 2·(5/18)em wider
    // than one built from the bare relation.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x=y");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const rel_frac = try fracProbeWidth(&list, &a, 0x3D, null);
    const ord_frac = try fracProbeWidth(&list, &a, 0x3D, .ord);
    try testing.expectApproxEqAbs(2 * glueAt(3), rel_frac - ord_frac, 0.01);
}

test "layout: \\colon spaces as punctuation, a bare : as a relation" {
    // Plain TeX's `\def\colon{\mathpunct{:}}`: the glyph is the same colon, so
    // the two rows differ ONLY in glue — `x: y` takes thick on both sides of
    // the relation, `x\colon y` takes none before and a thin space after.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x:y");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const colon = 0x3A;
    const glyphs = list.get(try charBox(&list, &a, 0x1D465, .text, 10)).width +
        list.get(try charBox(&list, &a, 0x1D466, .text, 10)).width +
        list.get(try charBox(&list, &a, colon, .text, 10)).width;
    const rel_row = try classProbeRow(&list, &a, colon, null);
    const punct_row = try classProbeRow(&list, &a, colon, .punct);
    try testing.expectApproxEqAbs(glyphs + 2 * glueAt(3), rel_row, 0.01);
    try testing.expectApproxEqAbs(glyphs + glueAt(1), punct_row, 0.01);
    // and the difference is exactly the class change: two thick → one thin.
    try testing.expectApproxEqAbs(2 * glueAt(3) - glueAt(1), rel_row - punct_row, 0.01);
}

test "layout: \\mathop is a roman op atom whose scripts stay beside" {
    // The `.opname` model TeX's \mathop produces: the field is laid out in
    // upright roman (its box carries the roman style) and the atom takes the
    // OP class, so `x\mathop f y` gets the op↔ord thin space on both sides —
    // exactly what `\sin x` gets. `data` 0 means no limits: even in display
    // style a subscript stays beside instead of stacking.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "mathop");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const f = try a.createLeaf(.char, 0, 1, 0x66);
    const opn = try a.createNode(.opname, 0, 1, &.{a.node(f)}, 0);
    const op_box = try layout(&list, &a, opn, &fm_default, .text, 10, .italic);
    try testing.expectEqual(.char, list.get(op_box).kind);
    try testing.expectEqual(.roman, list.charData(op_box).style);

    const x = try a.createLeaf(.char, 0, 1, 0x1D465);
    const y = try a.createLeaf(.char, 0, 1, 0x1D466);
    const row = try a.createNode(.row, 0, 1, &.{ a.node(x), a.node(opn), a.node(y) }, 0);
    const row_b = try layout(&list, &a, row, &fm_default, .text, 10, .italic);
    const glyphs = list.get(try charBox(&list, &a, 0x1D465, .text, 10)).width +
        list.get(try charBox(&list, &a, 0x1D466, .text, 10)).width +
        list.get(op_box).width;
    try testing.expectApproxEqAbs(glyphs + 2 * glueAt(1), list.get(row_b).width, 0.01);

    // \limits is not implied: a subscript in DISPLAY style stays beside.
    const sub = try a.createLeaf(.char, 0, 1, 0x1D462);
    const scripted = try a.createNode(
        .script,
        0,
        1,
        &.{ a.node(opn), a.node(sub) },
        atom.ScriptBits.sub,
    );
    const sb = try layout(&list, &a, scripted, &fm_default, .display, 10, .italic);
    try testing.expectEqual(.script, list.get(sb).kind);
}

test "layout: the big operators box by their measured font ink" {
    // Every new big operator boxes itself by the ink of the glyph it draws:
    // the base form in the smaller styles, the .v1 display variant in display.
    // The drawn FONT SIZE is the current size for all of them EXCEPT the big
    // integrals, which draw the plain integral sign scaled by 2.488 (the
    // `bigints` package's \Huge). Those three BOX the base glyph's ink at
    // that scaled size instead of the per-op row, which is the same product
    // rounded to 1e-3 em (see layoutOp) — so the assertion is coverage of
    // the drawn ink, not the row's exact digits.
    const cases = [_]struct { op: atom.BigOp, cp: u21, draw_scale: f32 }{
        .{ .op = .bigodot, .cp = 0x2A00, .draw_scale = 1.0 },
        .{ .op = .bigoplus, .cp = 0x2A01, .draw_scale = 1.0 },
        .{ .op = .bigotimes, .cp = 0x2A02, .draw_scale = 1.0 },
        .{ .op = .biguplus, .cp = 0x2A04, .draw_scale = 1.0 },
        .{ .op = .bigsqcap, .cp = 0x2A05, .draw_scale = 1.0 },
        .{ .op = .bigwedge, .cp = 0x22C0, .draw_scale = 1.0 },
        .{ .op = .bigvee, .cp = 0x22C1, .draw_scale = 1.0 },
        .{ .op = .bigstar, .cp = 0x22C6, .draw_scale = 1.0 },
        .{ .op = .bigint, .cp = 0x222B, .draw_scale = 2.488 },
        .{ .op = .bigiint, .cp = 0x222C, .draw_scale = 2.488 },
        .{ .op = .bigiiint, .cp = 0x222D, .draw_scale = 2.488 },
    };
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "bigop");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 5 });
    for (cases) |c| {
        const leaf = try a.createLeaf(.op, 0, 1, @backingInt(c.op));
        for ([_]struct { style: Style, display: bool }{
            .{ .style = .text, .display = false },
            .{ .style = .display, .display = true },
        }) |st| {
            const b = try layout(&list, &a, leaf, &fm_default, st.style, 10, .italic);
            const ink = metrics.bigOpInk(c.op, st.display);
            const bx = list.get(b);
            try testing.expectEqual(.char, bx.kind);
            try testing.expectApproxEqAbs(ink.advance * 10, bx.width, 0.001);
            if (c.draw_scale == 1.0) {
                try testing.expectApproxEqAbs(ink.asc * 10, bx.height, 0.001);
                try testing.expectApproxEqAbs(ink.desc * 10, bx.depth, 0.001);
            } else {
                const drawn = metrics.bigOpInk(bigOpBase(c.op), false);
                try testing.expect(bx.height >= drawn.asc * 10 * c.draw_scale);
                try testing.expect(bx.depth >= drawn.desc * 10 * c.draw_scale);
            }
            const cd = list.charData(b);
            try testing.expectEqual(c.cp, cd.cp);
            try testing.expectApproxEqAbs(10 * c.draw_scale, cd.size, 0.001);
        }
    }
}

test "layout: the plain operators still draw at the current size" {
    // Regression guard: the drawn-size factor belongs to the big integrals
    // alone — every operator that already worked keeps size_pt, so no
    // existing formula's geometry moves.
    const cases = [_]struct { op: atom.BigOp }{
        .{ .op = .sum },      .{ .op = .int },              .{ .op = .prod },
        .{ .op = .coprod },   .{ .op = .bigcup },           .{ .op = .bigcap },
        .{ .op = .bigsqcup }, .{ .op = .oint },             .{ .op = .oiint },
        .{ .op = .oiiint },   .{ .op = .ointctrclockwise },
    };
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "op");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 2 });
    for (cases) |c| {
        const leaf = try a.createLeaf(.op, 0, 1, @backingInt(c.op));
        const b = try layout(&list, &a, leaf, &fm_default, .display, 10, .italic);
        try testing.expectApproxEqAbs(10, list.charData(b).size, 0.0001);
    }
}

test "layout: \\dbinom takes the amsmath display fence, \\tbinom the small one" {
    // Both are the same amsmath-delimited fraction; only the FORCED style
    // differs, and it governs the fence: display covers the standard fraction
    // box (parenleft.v6, 2.392em ink) while the smaller styles draw the base
    // paren (1.094em). The paren BOX is the variant's ink, so its height +
    // depth measures which rung was picked.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "dbinom");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 6 });
    for ([_]struct { forced: atom.MathStyle, ink_em: f32 }{
        .{ .forced = .display, .ink_em = 2.392 },
        .{ .forced = .text, .ink_em = 1.094 },
    }) |c| {
        const open = try a.createLeaf(.char, 0, 1, 0x28);
        const n = try a.createLeaf(.char, 0, 1, 0x1D45B);
        const k = try a.createLeaf(.char, 0, 1, 0x1D4F7);
        const data = atom.fracData(false, c.forced, false) | atom.FractionBits.fixed_delim;
        const frac = try a.createNode(.fraction, 0, 1, &.{ a.node(n), a.node(k) }, data);
        const close = try a.createLeaf(.char, 0, 1, 0x29);
        const left = try a.createNode(
            .left,
            0,
            1,
            &.{ a.node(open), a.node(frac), a.node(close) },
            0,
        );
        // Laid out in DISPLAY style either way: the forced style argument, not
        // the ambient one, picks the fence.
        const b = try layout(&list, &a, left, &fm_default, .display, 10, .italic);
        const kids = list.children(b);
        try testing.expectEqual(@as(usize, 3), kids.len);
        const paren = list.get(kids[0].idx);
        try testing.expectApproxEqAbs(c.ink_em * 10, paren.height + paren.depth, 0.01);
    }
}

/// A two-row environment over the source "xy": each row is one cell holding
/// the char at its own byte, and the FIRST row carries `stretch` (the f32 em
/// bits, null = no `\arraystretch`). `cases` gets its `{` delimiter leaf
/// first, exactly as parseBegin emits it.
fn twoRowEnv(
    a: *atom.Ast,
    kind: atom.EnvKind,
    stretch: ?f32,
) !u32 {
    const cells = [_]u32{
        try a.createLeaf(.char, 0, 1, 0),
        try a.createLeaf(.char, 1, 1, 0),
    };
    const rows = [_]atom.Node{
        a.node(try a.createNode(
            .row,
            0,
            1,
            &.{a.node(cells[0])},
            if (stretch) |f| atom.emToFixed(f) else 0,
        )),
        a.node(try a.createNode(.row, 1, 1, &.{a.node(cells[1])}, 0)),
    };
    // The child count is the real node shape, not a padded array: cases
    // carries the `{` leaf parseBegin emits, every other kind is its two
    // rows alone, so pack the widest case and slice it.
    var kids: [3]atom.Node = undefined;
    var n: usize = 0;
    if (kind == .cases) {
        kids[0] = a.node(try a.createLeaf(.char, 0, 1, 0x7B));
        n = 1;
    }
    kids[n] = rows[0];
    kids[n + 1] = rows[1];
    return a.createNode(.env, 0, 2, kids[0 .. n + 2], atom.envData(kind, ""));
}

/// Baseline distance between the two rows of a two-row environment: the
/// strut-driven stack, `strut_depth + strut_height = \baselineskip ×
/// \arraystretch`.
fn envRowPitch(list: *box.BoxList, env_box: u32) f32 {
    const kids = list.children(env_box);
    // [open?, array] — the array vbox is the one non-delimiter child.
    var arr: u32 = 0;
    for (kids) |cr| {
        if (list.get(cr.idx).kind == .vbox) arr = cr.idx;
    }
    const rows = list.children(arr);
    return rows[1].shift - rows[0].shift;
}

test "layout: \\arraystretch scales the row struts; cases keeps its own default" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "xy");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    // amsmath's `\strut@` copies LaTeX's `\strutbox`: 0.7\baselineskip tall
    // and 0.3\baselineskip deep, so a stretched row's baseline distance is
    // exactly \baselineskip × \arraystretch (12pt at 10pt).
    const strut_pitch = 1.2 * 10.0;

    // A matrix with no assignment: LaTeX's \arraystretch default of 1.
    const plain = try twoRowEnv(&a, .matrix, null);
    const plain_pitch =
        envRowPitch(&list, try layout(&list, &a, plain, &fm_default, .display, 10, .italic));
    try testing.expectApproxEqAbs(strut_pitch, plain_pitch, 0.001);
    // The same matrix with \arraystretch{1.4}: the exact factor, since both
    // rows are shallower than the strut at either stretch.
    const wide = try twoRowEnv(&a, .matrix, 1.4);
    const wide_pitch =
        envRowPitch(&list, try layout(&list, &a, wide, &fm_default, .display, 10, .italic));
    try testing.expectApproxEqAbs(1.4 * strut_pitch, wide_pitch, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.4), wide_pitch / plain_pitch, 0.001);
    // cases with no assignment keeps amsmath's \def\arraystretch{1.2}.
    const cases = try twoRowEnv(&a, .cases, null);
    const cases_pitch =
        envRowPitch(&list, try layout(&list, &a, cases, &fm_default, .display, 10, .italic));
    try testing.expectApproxEqAbs(1.2 * strut_pitch, cases_pitch, 0.001);
    // ... and an explicit assignment overrides it.
    const stretched = try twoRowEnv(&a, .cases, 2.0);
    const stretched_pitch =
        envRowPitch(&list, try layout(&list, &a, stretched, &fm_default, .display, 10, .italic));
    try testing.expectApproxEqAbs(2.0 * strut_pitch, stretched_pitch, 0.001);
}

/// The `\tag{3}` atom of a source holding `\tag{3}` with its backslash at
/// byte `start`: a `tag_row_data` row of the argument in a roman scope, its
/// token range covering the WHOLE construct (`\tag` … `}`, seven tokens) the
/// way the parser emits it, and the digit keeping the byte span of the `3`.
fn tagNode(a: *atom.Ast, start: u32) !u32 {
    const digit_tok = start + 5;
    const digit = try a.createLeaf(.char, digit_tok, 1, 0);
    const arg = try a.createNode(.row, digit_tok, 1, &.{a.node(digit)}, 0);
    const styled = try a.createNode(
        .styled,
        digit_tok,
        1,
        &.{a.node(arg)},
        @backingInt(atom.CharStyle.roman),
    );
    return a.createNode(.row, start, 7, &.{a.node(styled)}, tag_row_data);
}

test "layout: \\tag is axis-centred and draws amsmath's (number)" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "x=1 \\tag{3}";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);

    const size_pt: f32 = 20;
    const axis = s(metrics.glue(&fm_default).axis_height, size_pt);
    const b = try layout(&list, &a, try tagNode(&a, 4), &fm_default, .text, size_pt, .italic);
    const tb = list.get(b);
    // The ink is centred on the math axis: the result box's own mid-height
    // above the baseline IS the axis.
    try testing.expectApproxEqAbs(axis, (tb.height - tb.depth) / 2, 0.001);
    // The construct spans `\tag{3}`; the first child sits after amsmath's
    // \mintagsep.
    try testing.expectEqual(@as(u32, 4), tb.src_start);
    try testing.expectEqual(@as(u32, 11), tb.src_end);
    try testing.expectEqualStrings("\\tag{3}", src[tb.src_start..tb.src_end]);
    const ch = list.children(b);
    // Plain amsmath renders the tag as `(n)` — \maketag@@@{(#1)} — so the
    // parentheses are part of the tag, not an implementation detail.
    try testing.expectEqual(@as(usize, 3), ch.len);
    const gap = mintagsep_em * size_pt;
    try testing.expectApproxEqAbs(gap, ch[0].x_shift, 0.001);
    // The parentheses amsmath synthesizes: real roman glyphs, but carrying
    // the tag's WHOLE span and marked synthetic, so flatten dups the glyph
    // instead of aliasing the `\tag{3}` bytes.
    for ([_]struct { ref: box.ChildRef, cp: u21 }{
        .{ .ref = ch[0], .cp = '(' },
        .{ .ref = ch[2], .cp = ')' },
    }) |p| {
        const pb = list.get(p.ref.idx);
        try testing.expectEqual(box.Kind.char, pb.kind);
        try testing.expectEqual(@as(u32, 4), pb.src_start);
        try testing.expectEqual(@as(u32, 11), pb.src_end);
        const pcd = list.charData(p.ref.idx);
        try testing.expectEqual(atom.CharStyle.roman, pcd.style);
        try testing.expectEqual(p.cp, pcd.cp);
        try testing.expect(pcd.synthetic);
    }
    const paren_l = list.get(ch[0].idx);
    const paren_r = list.get(ch[2].idx);
    // The argument sits BETWEEN the parentheses, and the middle child is the
    // argument BOX: the `.styled` scope is transparent, so the roman style
    // reaches the GLYPH, and the braced argument is itself a row (the `\tag`
    // row holds the styled argument, the argument holds the digit), so the
    // drawn char box is one level further in. `charData` is the parallel side
    // table: it reads a DEFAULT record for a non-char box, so reading it off
    // the argument row would report the default `.italic` and prove nothing.
    const arg_box = ch[1].idx;
    try testing.expectApproxEqAbs(gap + paren_l.width, ch[1].x_shift, 0.001);
    const arg_w = list.get(arg_box).width;
    try testing.expectApproxEqAbs(gap + paren_l.width + arg_w, ch[2].x_shift, 0.001);
    try testing.expectEqual(box.Kind.hbox, list.get(arg_box).kind);
    const digits = list.children(arg_box);
    try testing.expectEqual(@as(usize, 1), digits.len);
    const digit = list.get(digits[0].idx);
    const cd = list.charData(digits[0].idx);
    // Upright roman (amsmath sets the tag in \normalfont), and the glyph is
    // NOT synthetic, so flatten aliases the real source bytes — the digit
    // keeps its own byte span inside the command.
    try testing.expectEqual(atom.CharStyle.roman, cd.style);
    try testing.expectEqual(@as(u21, '3'), cd.cp);
    try testing.expect(!cd.synthetic);
    try testing.expectEqual(@as(u32, 9), digit.src_start);
    try testing.expectEqual(@as(u32, 10), digit.src_end);
    try testing.expectEqualStrings("3", src[digit.src_start..digit.src_end]);
    // The advance is the whole `(n)`: both parentheses, the gap, and the
    // number. The parentheses are the tallest part, so the AXIS CENTRING above
    // is measured over them, not over the digit.
    try testing.expectApproxEqAbs(
        gap + paren_l.width + digit.width + paren_r.width,
        tb.width,
        0.001,
    );
    try testing.expect(paren_l.height > digit.height);
}

test "layout: \\tag adds no inter-atom glue to its neighbours" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "x\\tag{3}x";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const tag = try tagNode(&a, 1);
    const x1 = try a.createLeaf(.char, 0, 1, 0);
    const x2 = try a.createLeaf(.char, 8, 1, 0);
    const row = try a.createNode(.row, 0, 1, &.{ a.node(x1), a.node(tag), a.node(x2) }, 0);
    const b = try layout(&list, &a, row, &fm_default, .text, 10, .italic);
    const xw = list.get(try charBox(&list, &a, 0x1D465, .text, 10)).width;
    const tagw = list.get(try layout(&list, &a, tag, &fm_default, .text, 10, .italic)).width;
    // A rel→ord pair would add 5mu and an op→ord pair 3mu: the tag takes
    // none, so the row is exactly the three boxes back to back.
    try testing.expectApproxEqAbs(2 * xw + tagw, list.get(b).width, 0.001);
    try testing.expectEqual(@as(usize, 3), list.children(b).len);
}

/// A `\hat{...}` / `\widehat{...}` / `\widetilde{...}` atom over the `n` char
/// cells starting at source byte `first`, each the math-italic letter there.
fn wideAccentNode(
    a: *atom.Ast,
    marker: u32,
    mark_cp: u21,
    first: usize,
    n: usize,
) !u32 {
    var cells: std.ArrayList(atom.Node) = .empty;
    defer cells.deinit(a.gpa);
    for (0..n) |i| {
        try cells.append(a.gpa, a.node(try a.createLeaf(.char, @intCast(first + i), 1, 0)));
    }
    const base = try a.createNode(.row, 0, @intCast(n), cells.items, 0);
    const mark = try a.createLeaf(.char, 0, 1, mark_cp);
    return a.createNode(.row, 0, @intCast(n), &.{ a.node(base), a.node(mark) }, marker);
}

/// A laid-out accent's mark box, read the way a consumer reads it: the
/// reserved geometry, the recorded char state, and where the mark's INK
/// CENTRE landed. The centre comes from the recorded overhangs and the
/// advance, because that is all the draw list has — and it is the only
/// measure that locates every form, the ladder's zero-advance base rung
/// included.
const AccentMark = struct {
    box: box.Box,
    cd: box.CharData,
    x: f32,
    ink_center: f32,
};

fn accentMark(list: *const box.BoxList, accent: u32) AccentMark {
    const ch = list.children(accent);
    std.debug.assert(ch.len == 2);
    const mb = list.get(ch[1].idx);
    const cd = list.charData(ch[1].idx);
    return .{
        .box = mb,
        .cd = cd,
        .x = ch[1].x_shift,
        .ink_center = ch[1].x_shift + (mb.width + cd.ink_right - cd.ink_left) / 2,
    };
}

test "layout: \\widehat is the face's own horizontal variant at every width" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "Mabcdefghij";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    // The largest variant the ladder holds: asking far past its end is what
    // the resolver answers with the top rung, unscaled.
    const largest = (try metrics.horizontalGlyph(&fm_default, 0x0302, 1e9)) orelse
        return error.MissingGlyph;
    const ladder_top = largest.advance_em;

    for ([_]f32{ 8, 20, 60 }) |size_pt| {
        var widths: [4]f32 = undefined;
        // ONE character, two, four and ten: a wide base, a middle one inside
        // the ladder, and two that outrun it.
        for ([_]usize{ 1, 2, 4, 10 }, 0..) |n, i| {
            const node = try wideAccentNode(&a, wide_hat_row_data, 0x0302, 0, n);
            const b = try layout(&list, &a, node, &fm_default, .text, size_pt, .italic);
            const m = accentMark(&list, b);
            widths[i] = m.box.width;
            // ONE mark box, the real combining codepoint, and NEVER a stroke:
            // the face draws the hat, with its single apex and its own
            // proportions. The three-kink parametric chevron this replaced
            // was the defect, not the mark.
            try testing.expectEqual(box.Kind.char, m.box.kind);
            try testing.expectEqual(@as(u21, 0x0302), m.cd.cp);
            try testing.expect(m.cd.synthetic);
            // The accent never widens its base, and the request it carries is
            // the base's own width in em — so every back end resolves the SAME
            // variant this box reserves.
            const base_w = list.get(list.children(b)[0].idx).width;
            try testing.expectApproxEqAbs(base_w, list.get(b).width, 0.001);
            const req_em = base_w / size_pt;
            try testing.expectApproxEqAbs(req_em, m.cd.horizontal_req, 0.0001);
            const geom = (try metrics.horizontalGlyph(&fm_default, 0x0302, req_em)) orelse
                return error.MissingGlyph;
            // The reserved advance IS the variant's own hmtx advance: a real
            // width, never the base glyph's 0 and never a made-up one.
            try testing.expectApproxEqAbs(geom.advance_em * size_pt, m.box.width, 0.001);
            // The box is bounded by the DRAWN VARIANT's own ink, which is
            // what the back ends actually paint.
            try testing.expectApproxEqAbs(geom.ink.left * size_pt, m.cd.ink_left, 0.001);
            try testing.expectApproxEqAbs(
                @max(0.0, geom.ink.right_edge * size_pt - m.box.width),
                m.cd.ink_right,
                0.001,
            );
            try testing.expectApproxEqAbs(
                (geom.ink.asc - geom.ink.desc) * size_pt,
                m.box.height - m.box.depth,
                0.001,
            );
            // The result box still bounds the hat above the base's own ink.
            try testing.expect(list.get(b).height >= m.box.height - 0.001);
        }
        // The two the ladder covers grow with their argument...
        try testing.expect(widths[1] > widths[0]);
        // ... and the two it does NOT both keep the SAME top variant, so
        // nothing is stretched to fit: `\widehat{abcd}` keeps the font's own
        // rise instead of flattening into a chevron.
        try testing.expectApproxEqAbs(widths[2], widths[3], 0.001);
        try testing.expectApproxEqAbs(ladder_top * size_pt, widths[3], 0.001);
    }
}

test "layout: an accent mark rides ITS OWN top-accent attachment" {
    // A combining mark has a ZERO advance with its whole ink LEFT of the
    // origin, so `ink_metrics` records `right_edge = max(0, xMax) = 0` and the
    // ink centre (left/2) is NOT the mark's attachment. Both reference engines
    // put the MARK's TopAccentAttachment on the base's attachment: at 20pt
    // `\hat{x}` puts the mark origin at 0.329 - (-0.264) = 0.593em, while
    // ink-centring lands it at 0.552em — 0.041em left of every accent.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "xAB";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const size_pt: f32 = 20;
    const node = try wideAccentNode(&a, accent_row_data, 0x0302, 0, 1);
    const b = try layout(&list, &a, node, &fm_default, .text, size_pt, .italic);
    const m = accentMark(&list, b);
    const base_attach = metrics.accentAttach(0x1D465) orelse return error.MissingGlyph;
    const mark_attach = metrics.accentAttach(0x0302) orelse return error.MissingGlyph;
    // Attachment onto attachment, for ONE base character.
    try testing.expectApproxEqAbs((base_attach - mark_attach) * size_pt, m.x, 0.001);
    // ... and NOT the ink centre the clamp invents (0.223em, 0.041em left).
    const ink_centre = metrics.glyphInk(0x0302);
    try testing.expect(@abs(ink_centre.left / 2 - mark_attach) > 0.03);
}

test "layout: an accent over a group centres on the group's TeX width" {
    // `\hat{AB}`: the reference's mark ink centre is 0.767em — half of the
    // argument's TeX width 1.534em = 0.750 (A) + 0.759 (B) + 0.025 (B's
    // italic correction, the one TeX's fin_mlist appends to EVERY math list),
    // not half of the bare 1.509em row advance.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "AB";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const size_pt: f32 = 20;
    const node = try wideAccentNode(&a, accent_row_data, 0x0302, 0, 2);
    const b = try layout(&list, &a, node, &fm_default, .text, size_pt, .italic);
    const m = accentMark(&list, b);
    const base_node = a.child(node, 0);
    const last = a.child(base_node, 1);
    const ic = charIc(&a, last, a.node(last), &fm_default, .italic, size_pt);
    const base_w = list.get(list.children(b)[0].idx).width;
    const mark_attach = metrics.accentAttach(0x0302) orelse return error.MissingGlyph;
    // The row ends in a char whose next atom is the mark, so the bare
    // advance carries NO correction — the helper adds B's 0.025em back.
    try testing.expectApproxEqAbs(@as(f32, 0.025) * size_pt, ic, 0.01);
    try testing.expectApproxEqAbs((base_w + ic) / 2 - mark_attach * size_pt, m.x, 0.001);
}

test "layout: a tiny accent base takes the zero-advance rung and is framed by its ink" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "lM";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const size_pt: f32 = 20;
    const node = try wideAccentNode(&a, wide_hat_row_data, 0x0302, 0, 1);
    const b = try layout(&list, &a, node, &fm_default, .text, size_pt, .italic);
    const m = accentMark(&list, b);
    const base_w = list.get(list.children(b)[0].idx).width;
    const geom = (try metrics.horizontalGlyph(&fm_default, 0x0302, base_w / size_pt)) orelse
        return error.MissingGlyph;
    // 𝑙 is 2.98pt at the 10pt base — 0.298em, under the ladder's first
    // AdvanceMeasurement — so the resolver answers with the BASE rung: hmtx 0,
    // with the whole ink drawn LEFT of the origin. Framing on the advance
    // would cut all of it away.
    try testing.expect(geom.advance_em == 0);
    try testing.expect(geom.ink.left > 0);
    try testing.expectApproxEqAbs(@as(f32, 0), m.box.width, 0.0001);
    try testing.expectApproxEqAbs(geom.ink.left * size_pt, m.cd.ink_left, 0.001);
    try testing.expect(m.cd.horizontal_req > 0);
    // The mark's own frame is that ink, and it does poke left of the box: the
    // zero-padded viewBox and pixel buffer have to contain it.
    var mark_list = draw.DrawList.init(testing.allocator);
    defer mark_list.deinit();
    try draw.flatten(&list, list.children(b)[1].idx, src, 0, 0, &mark_list);
    const mark_ink = mark_list.bounds();
    try testing.expectApproxEqAbs(-m.cd.ink_left, mark_ink.min_x, 0.001);
    try testing.expect(mark_ink.min_x < 0);
    var whole = draw.DrawList.init(testing.allocator);
    defer whole.deinit();
    try draw.flatten(&list, b, src, 0, 0, &whole);
    try testing.expect(whole.bounds().min_x <= m.x - m.cd.ink_left + 0.001);
}

test "layout: a \\widetilde past the ladder keeps the face's own top rung" {
    // Both reference engines draw ONE native horizontal variant at every
    // width: rung 0.932em for `xy`, 1.336em for `abc`, and the 1.916em top
    // rung — UNSTRETCHED and centred — for `abcd`, `abcde` and `abcdefghij`
    // alike, at 8pt, 20pt and 60pt and in display and text alike. A
    // parametric sine wave is the one form no reference engine draws.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "Mabcdefghij";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const size_pt: f32 = 20;
    const top = (try metrics.horizontalGlyph(&fm_default, 0x0303, 1e9)) orelse
        return error.MissingGlyph;
    var widths: [4]f32 = undefined;
    for ([_]usize{ 1, 2, 4, 10 }, 0..) |n, i| {
        const node = try wideAccentNode(&a, wide_tilde_row_data, 0x0303, 0, n);
        const b = try layout(&list, &a, node, &fm_default, .text, size_pt, .italic);
        const m = accentMark(&list, b);
        widths[i] = m.box.width;
        // ONE char box, the real combining codepoint, and NEVER a stroke.
        try testing.expectEqual(box.Kind.char, m.box.kind);
        try testing.expectEqual(@as(u21, 0x0303), m.cd.cp);
        const geom = (try metrics.horizontalGlyph(&fm_default, 0x0303, m.cd.horizontal_req)) orelse
            return error.MissingGlyph;
        // The reserved advance IS the rung's own advance, at every width.
        try testing.expectApproxEqAbs(geom.advance_em * size_pt, m.box.width, 0.001);
        try testing.expect(m.box.width <= list.get(list.children(b)[0].idx).width + 0.001);
    }
    // The two the ladder covers grow with their argument...
    try testing.expect(widths[1] > widths[0]);
    // ... and the two it does NOT both keep the SAME top rung.
    try testing.expectApproxEqAbs(widths[2], widths[3], 0.001);
    try testing.expectApproxEqAbs(top.advance_em * size_pt, widths[3], 0.001);
}

test "layout: a wide accent centres the DRAWN VARIANT's ink" {
    // Both reference engines paint ONE native size variant and centre the
    // INK they paint on the argument's TeX width — trailing italic
    // correction included, the way TeX's fin_mlist appends it. The mark's own
    // TopAccentAttachment belongs to the ladder's ZERO-ADVANCE rung only, so
    // subtracting it from a variant parked every wide accent 0.264em + half
    // its advance to the RIGHT of the reference.
    const size_pt: f32 = 20;
    for ([_]struct { cp: u21, marker: u32, src: []const u8 }{
        .{ .cp = 0x0303, .marker = wide_tilde_row_data, .src = "xy" },
        .{ .cp = 0x0303, .marker = wide_tilde_row_data, .src = "abcd" },
        .{ .cp = 0x0303, .marker = wide_tilde_row_data, .src = "abcdefghij" },
        .{ .cp = 0x0302, .marker = wide_hat_row_data, .src = "xy" },
        .{ .cp = 0x0302, .marker = wide_hat_row_data, .src = "abcd" },
        .{ .cp = 0x0302, .marker = wide_hat_row_data, .src = "abcdefghij" },
    }) |c| {
        var list = box.BoxList.init(testing.allocator);
        defer list.deinit();
        var a = atom.Ast.init(testing.allocator, c.src);
        defer a.deinit();
        try pushCharTokens(&a, c.src);
        const node = try wideAccentNode(&a, c.marker, c.cp, 0, c.src.len);
        const b = try layout(&list, &a, node, &fm_default, .text, size_pt, .italic);
        const m = accentMark(&list, b);
        const base = list.children(b)[0].idx;
        const base_w = list.get(base).width;
        const target = (base_w + trailingGroupIc(&list, base, &fm_default, size_pt)) / 2;
        const geom = (try metrics.horizontalGlyph(&fm_default, c.cp, base_w / size_pt)) orelse
            return error.MissingGlyph;
        // A full-advance variant, never the bare combining glyph: that is the
        // case whose datum the placement reads, and this fixture is not it.
        try testing.expect(geom.advance_em > 0);
        try testing.expectEqual(box.Kind.char, m.box.kind);
        try testing.expectEqual(c.cp, m.cd.cp);
        try testing.expectApproxEqAbs(geom.advance_em * size_pt, m.box.width, 0.001);
        // The drawn variant's advance centre lands on the argument's TeX
        // width: `\widetilde{xy}` puts its tilde at 0.079em, `\widetilde{abcd}`
        // at 0.029em and the ten-letter argument at 1.477em.
        try testing.expectApproxEqAbs(target, m.x + m.box.width / 2, 0.001);
        // ... and NOT where the mark's own combining attachment puts it: the
        // old rule missed by the whole mark attachment plus half the advance.
        const mark_attach = metrics.accentAttach(c.cp) orelse return error.MissingGlyph;
        try testing.expect(@abs(m.x - (target - mark_attach * size_pt)) > 0.2 * size_pt);
    }
}

test "layout: a narrow-base extensible accent rides the rung" {
    // The datum follows the DRAWING, not the command. `x` is past the hat
    // ladder's first AdvanceMeasurement, so `\widehat{x}` draws the 0.644em
    // rung variant: its ink centre (0.322em) is what the base's 0.329em
    // attachment meets. `l` is 0.298em, UNDER that measurement: the resolver
    // answers with the zero-advance base rung and the mark keeps its MATH
    // attachment, origin 0.184 + 0.264em, exactly as before.
    const size_pt: f32 = 20;
    for ([_]struct { src: []const u8 }{
        .{ .src = "x" },
        .{ .src = "l" },
    }) |c| {
        var list = box.BoxList.init(testing.allocator);
        defer list.deinit();
        var a = atom.Ast.init(testing.allocator, c.src);
        defer a.deinit();
        try pushCharTokens(&a, c.src);
        const node = try wideAccentNode(&a, wide_hat_row_data, 0x0302, 0, c.src.len);
        const b = try layout(&list, &a, node, &fm_default, .text, size_pt, .italic);
        const m = accentMark(&list, b);
        const base = list.children(b)[0].idx;
        const base_cp = list.charData(list.children(base)[0].idx).cp;
        const attach = metrics.accentAttach(base_cp) orelse return error.MissingGlyph;
        const geom = (try metrics.horizontalGlyph(
            &fm_default,
            0x0302,
            list.get(base).width / size_pt,
        )) orelse return error.MissingGlyph;
        try testing.expectApproxEqAbs(geom.advance_em * size_pt, m.box.width, 0.001);
        if (geom.advance_em > 0) {
            try testing.expectApproxEqAbs(attach * size_pt, m.x + m.box.width / 2, 0.001);
        } else {
            const mark_attach = metrics.accentAttach(0x0302) orelse return error.MissingGlyph;
            try testing.expectApproxEqAbs((attach - mark_attach) * size_pt, m.x, 0.001);
        }
    }
}

test "layout: a single-char base places its wide accent by the variant's ink centre" {
    // `M` is 0.97em with a TopAccentAttachment of 0.625em — far left of the
    // glyph's own centre, so it is where a single-character argument and a
    // multi-character one disagree most. The base's attachment still picks
    // the TARGET; the drawn variant only supplies the datum its ink is
    // measured back from, so `\widehat{M}` puts the hat's advance centre on
    // 0.625em and `\widetilde{M}` on 0.625em too — not at 0.625 + 0.264em.
    const size_pt: f32 = 20;
    const src = "M";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const attach = metrics.accentAttach(0x1D440) orelse return error.MissingGlyph;
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    for ([_]struct { cp: u21, marker: u32 }{
        .{ .cp = 0x0302, .marker = wide_hat_row_data },
        .{ .cp = 0x0303, .marker = wide_tilde_row_data },
    }) |c| {
        const node = try wideAccentNode(&a, c.marker, c.cp, 0, 1);
        const b = try layout(&list, &a, node, &fm_default, .text, size_pt, .italic);
        const m = accentMark(&list, b);
        const base = list.children(b)[0].idx;
        const geom = (try metrics.horizontalGlyph(
            &fm_default,
            c.cp,
            list.get(base).width / size_pt,
        )) orelse return error.MissingGlyph;
        try testing.expect(geom.advance_em > 0);
        try testing.expectApproxEqAbs(geom.advance_em * size_pt, m.box.width, 0.001);
        try testing.expectApproxEqAbs(attach * size_pt, m.x + m.box.width / 2, 0.001);
        const mark_attach = metrics.accentAttach(c.cp) orelse return error.MissingGlyph;
        try testing.expect(@abs(m.x - (attach - mark_attach) * size_pt) > 0.2 * size_pt);
    }
}

test "layout: the radical degree rides RadicalKernBeforeDegree at the current size" {
    // LuaLaTeX puts the index 0.278em (RadicalKernBeforeDegree) right of the
    // radical's own origin and widens the construction by NOTHING — the index
    // rides the radical's left shoulder. A kern evaluated against a 10pt em
    // is 0.139em here and 0.417em at 60pt, which is the size-invariance the
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "3x";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const surd = try a.createLeaf(.char, 0, 1, 0x221A);
    const degree = try a.createLeaf(.char, 0, 1, 0x33);
    const wrapped = try a.createNode(
        .script,
        0,
        2,
        &.{ a.node(surd), a.node(degree) },
        atom.ScriptBits.sup,
    );
    const radicand = try a.createLeaf(.char, 1, 1, 0);
    const row = try a.createNode(
        .row,
        0,
        2,
        &.{ a.node(wrapped), a.node(radicand) },
        sqrt_row_data,
    );
    for ([_]f32{ 10, 20, 60 }) |size_pt| {
        const b = try layout(&list, &a, row, &fm_default, .display, size_pt, .italic);
        const kids = list.children(b);
        // The degree is the LAST child; the radical keeps its own origin.
        const deg = kids[kids.len - 1];
        try testing.expectApproxEqAbs(0.278 * size_pt, deg.x_shift, 0.05 * size_pt);
        // The construction is NOT widened for the index: it rides the
        // radical's left shoulder inside its advance.
        try testing.expectApproxEqAbs(@as(f32, 0), kids[0].x_shift, 0.001);
    }
}

test "layout: a fixed-delimiter fraction carries no \\nulldelimiterspace" {
    // TeX's null-delimiter wrap pads a fraction that has NO delimiters
    // (`\over`, `\genfrac{}{}`) by \nulldelimiterspace on each side. The
    // `\binom` family puts REAL parentheses around the same fraction, and both
    // reference engines draw its parts flush between them: `\tbinom{n}{k}` is
    // 1.264em wide = 2x0.422 paren + 0.42 parts, with no pad at all.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try pushCharTokens(&a, "ab");
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    const fixed = try a.createNode(
        .fraction,
        0,
        2,
        &.{ a.node(num), a.node(den) },
        atom.fracData(true, .text, false) | atom.FractionBits.fixed_delim,
    );
    const b = try layout(&list, &a, fixed, &fm_default, .text, 20, .italic);
    const num_box = list.get(list.children(b)[0].idx);
    const den_box = list.get(list.children(b)[1].idx);
    // The box IS the parts' width — the delimiters, not a pad, carry the rest.
    try testing.expectApproxEqAbs(@max(num_box.width, den_box.width), list.get(b).width, 0.001);
}

test "layout: an environment row strut is LaTeX's \\strutbox" {
    // amsmath's `\strut@` copies `\strutbox@`, which latex.ltx:12596 builds as
    // 0.7\baselineskip tall and 0.3\baselineskip deep (`\normallineskiplimit`
    // is 0pt, so the box is never re-set per size). With \baselineskip =
    // 1.2·size that is h 0.84·size and d 0.36·size at EVERY size: 8.4/3.6 at
    // 10pt, 16.8/7.2 at 20pt, 50.4/21.6 at 60pt — the reference \showbox of
    // `\begin{matrix}a&b\end{matrix}`. The text paren's `(` box is NOT it: at
    // 0.75em/0.25em every row came out 0.09em taller and 0.11em deeper, the
    // "loose bottom" under a trailing \hline.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "ab";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const row = try a.createNode(.row, 0, 2, &.{
        a.node(try a.createLeaf(.char, 0, 1, 0)),
        a.node(try a.createLeaf(.char, 1, 1, 0)),
    }, 0);
    const env = try a.createNode(.env, 0, 1, &.{a.node(row)}, atom.envData(.array, "cc"));
    for ([_]f32{ 10, 20, 60 }) |size_pt| {
        const b = try layout(&list, &a, env, &fm_default, .display, size_pt, .italic);
        // The ROW box is the strut itself — \vcenter moves the stack but
        // never re-measures a row — so its own extent is the box amsmath
        // copies in: 8.4/3.6 at 10pt, 16.8/7.2 at 20pt, 50.4/21.6 at 60pt.
        const row_box = list.get(list.children(envArray(&list, b))[0].idx);
        try testing.expectApproxEqAbs(0.84 * size_pt, row_box.height, 0.001);
        try testing.expectApproxEqAbs(0.36 * size_pt, row_box.depth, 0.001);
        // The strut's two halves make one \baselineskip, which is the row
        // pitch of a matrix and the whole height of a one-row array.
        try testing.expectApproxEqAbs(1.2 * size_pt, row_box.height + row_box.depth, 0.001);
        try testing.expectApproxEqAbs(1.2 * size_pt, list.get(b).height + list.get(b).depth, 0.001);
    }
}

/// A `\frac{a}{b}` over the two-byte source `src`: the fraction and its two
/// char leaves claim the two tokens that really are there. `layout` reads
/// every char's codepoint from its node's token span, so a leaf pointing
/// past the token table aborts inside `Ast.span` — a fixture must hand the
/// nodes a token table they can index.
fn twoCharFrac(a: *atom.Ast, src: []const u8) !u32 {
    try pushCharTokens(a, src);
    const num = try a.createLeaf(.char, 0, 1, 0);
    const den = try a.createLeaf(.char, 1, 1, 0);
    return a.createNode(
        .fraction,
        0,
        2,
        &.{ a.node(num), a.node(den) },
        atom.fracData(true, null, false),
    );
}

test "layout: a forced under-limit clears a base that descends" {
    // \underset{n}{\frac{a}{b}}: the annotation is an ordinary SUBSCRIPT of
    // the base, so it must clear the base's DEPTH — the denominator's
    // bottom — not merely the base's baseline.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    const frac = try twoCharFrac(&a, "ab");
    const script = try a.createLeaf(.char, 0, 1, 0x6E); // n
    const row = try a.createNode(
        .row,
        0,
        2,
        &.{ a.node(script), a.node(frac) },
        underset_row_data,
    );
    const b = try layout(&list, &a, row, &fm_default, .text, 10, .italic);
    const rb = list.get(b);
    try testing.expectEqual(.vbox, rb.kind);
    // limitBox stacks [base, limit]: the base keeps the construct's own
    // baseline and the limit hangs off its bottom edge.
    const ch = list.children(b);
    try testing.expectEqual(@as(u16, 2), rb.num_children);
    const base = list.get(ch[0].idx);
    const ann = list.get(ch[1].idx);
    // The base really does descend — the fraction's denominator.
    try testing.expect(base.depth > 1.0);
    // The annotation's TOP is below the base's BOTTOM: no ink overlap.
    try testing.expect(ch[1].shift - ann.height >= base.depth);
    // The result box bounds both, without counting the base twice.
    try testing.expectApproxEqAbs(ch[1].shift + ann.depth, rb.depth, 0.001);
    try testing.expectApproxEqAbs(base.height, rb.height, 0.001);
}

test "layout: a forced over-limit clears a base that ascends" {
    // The mirror of the under case: the limit's BOTTOM must clear the base's
    // TOP, whatever the limit's own depth (`\overset{\frac12}{b}`).
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    // A fraction as the limit: it has real depth, which used to eat the gap.
    const lim = try twoCharFrac(&a, "ab");
    const base = try a.createLeaf(.char, 0, 1, 0);
    const row = try a.createNode(
        .row,
        0,
        2,
        &.{ a.node(lim), a.node(base) },
        overset_row_data,
    );
    const b = try layout(&list, &a, row, &fm_default, .text, 10, .italic);
    const rb = list.get(b);
    try testing.expectEqual(.vbox, rb.kind);
    const ch = list.children(b);
    try testing.expectEqual(@as(u16, 2), rb.num_children);
    const base_b = list.get(ch[0].idx);
    const ann = list.get(ch[1].idx);
    try testing.expect(ann.depth > 0);
    // The annotation's bottom clears the nucleus's top in y-down coordinates.
    try testing.expect(ch[1].shift + ann.depth < -base_b.height);
}

test "layout: a scaled big integral draws the base glyph its box was sized for" {
    // \bigint has no codepoint of its own: it draws the ordinary integral at
    // 2.488× the math size. Marking it as a display VARIANT made the
    // rasterizer paint integral.v1 (ink 1.361/0.861em, advance 0.999em) at
    // that scaled size, far outside a box built for the base glyph's scaled
    // ink, and the frame clipped it. The box must therefore describe the
    // BASE design at the scaled size, and the box must be marked .base so
    // the rasterizer draws exactly that.
    //
    // The second half of that is the part a digit comparison misses: the
    // consumers frame from the draw list's INK bounds, which for a lone
    // char box are exactly the box's own h/d, so at ZERO padding the frame
    // edge IS the box edge and any ink the box misses is cut off. The
    // per-op row restates the scaled base ink rounded to 1e-3 em, and where
    // that rounding fell short the box under-covered the painted glyph (see
    // layoutOp), so the assertion is coverage of the drawn ink against the
    // draw list's own bounds — not equality with a rounded constant.
    for ([_]f32{ 10, 24.88, 60 }) |size_pt| {
        for ([_]struct { op: atom.BigOp, scale: f32 }{
            .{ .op = .bigint, .scale = 2.488 },
            .{ .op = .bigiint, .scale = 2.488 },
            .{ .op = .bigiiint, .scale = 2.488 },
            // The pre-existing display operators keep their variant.
            .{ .op = .int, .scale = 1.0 },
            .{ .op = .oint, .scale = 1.0 },
            .{ .op = .sum, .scale = 1.0 },
        }) |c| {
            var list = box.BoxList.init(testing.allocator);
            defer list.deinit();
            var a = atom.Ast.init(testing.allocator, "op");
            defer a.deinit();
            try a.pushToken(.{ .tag = .char, .start = 0, .end = 2 });
            const op = try a.createLeaf(.op, 0, 1, @backingInt(c.op));
            const b = try layout(&list, &a, op, &fm_default, .display, size_pt, .italic);
            const cd = list.charData(b);
            try testing.expectApproxEqAbs(size_pt * c.scale, cd.size, 0.001);
            if (c.scale == 1.0) {
                try testing.expectEqual(box.BigOpForm.variant, cd.bigop_form);
                continue;
            }
            try testing.expectEqual(box.BigOpForm.base, cd.bigop_form);
            var dl = draw.DrawList.init(testing.allocator);
            defer dl.deinit();
            try draw.flatten(&list, b, "op", 0, 0, &dl);
            const ink = dl.bounds();
            const painted = metrics.bigOpInk(bigOpBase(c.op), false);
            const glyph_size = size_pt * c.scale;
            try testing.expect(ink.height > painted.asc * glyph_size);
            try testing.expect(ink.depth > painted.desc * glyph_size);
        }
    }
}

/// A `\boxed{x}` atom over one char cell, `data` 0 like the parser emits.
fn boxedNode(a: *atom.Ast) !u32 {
    return a.createNode(.boxed, 0, 1, &.{a.node(try a.createLeaf(.char, 0, 1, 0))}, 0);
}

test "layout: \\boxed frames outside the content at fixed fbox dimensions" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "x");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    const size_pt: f32 = 20;
    const b = try layout(&list, &a, try boxedNode(&a), &fm_default, .text, size_pt, .italic);
    const bb = list.get(b);
    // [content, two horizontal rules, two vertical rules] — four sides and
    // nothing else drawn.
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 5), ch.len);
    // A real closed rectangle: the two horizontal rules are the outer top and
    // bottom edges at \fboxrule, the two side rules are the outer left and
    // right edges running between them — they MEET, they never overlap, so
    // every point of the frame is painted exactly once.
    // Draw coordinates are y-down: a `.rule` paints [shift − height,
    // shift + depth], so a rule sitting `k` above the row baseline is at
    // `shift = −(k − height)`.
    var horiz: usize = 0;
    var vert: usize = 0;
    for (ch[1..]) |cr| {
        const rb = list.get(cr.idx);
        try testing.expectEqual(box.Kind.rule, rb.kind);
        if (rb.width > rb.height + rb.depth) {
            horiz += 1;
            // A horizontal rule is \fboxrule thick and spans the full width.
            try testing.expectApproxEqAbs(fboxrule_pt, rb.height + rb.depth, 0.001);
            try testing.expectApproxEqAbs(bb.width, rb.width, 0.001);
            try testing.expectApproxEqAbs(@as(f32, 0), cr.x_shift, 0.001);
            if (cr.shift < 0) {
                // Top edge: its upper side IS the box's own top.
                try testing.expectApproxEqAbs(-bb.height, cr.shift - rb.height, 0.001);
            } else {
                // Bottom edge: its lower side IS the box's own depth.
                try testing.expectApproxEqAbs(bb.depth, cr.shift + rb.depth, 0.001);
            }
        } else {
            vert += 1;
            // A side rule is \fboxrule wide and runs from the underside of
            // the top rule to the top side of the bottom one.
            try testing.expectApproxEqAbs(fboxrule_pt, rb.width, 0.001);
            try testing.expectApproxEqAbs(bb.depth - fboxrule_pt, rb.depth, 0.001);
            try testing.expectApproxEqAbs(bb.height - fboxrule_pt, rb.height, 0.001);
        }
    }
    try testing.expectEqual(@as(usize, 2), horiz);
    try testing.expectEqual(@as(usize, 2), vert);
    // The frame is OUTSIDE the content: a fixed fboxsep + fboxrule on every
    // side, with the content's baseline untouched.
    const cb = list.get(ch[0].idx);
    try testing.expectApproxEqAbs(fboxsep_pt + fboxrule_pt, ch[0].x_shift, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), ch[0].shift, 0.001);
    const margin = fboxsep_pt + fboxrule_pt;
    try testing.expectApproxEqAbs(cb.width + 2 * margin, bb.width, 0.001);
    try testing.expectApproxEqAbs(cb.height + margin, bb.height, 0.001);
    try testing.expectApproxEqAbs(cb.depth + margin, bb.depth, 0.001);
    // These margins are ABSOLUTE pt, so a 3x larger size keeps the very same
    // gap while the content itself grows.
    var big = box.BoxList.init(testing.allocator);
    defer big.deinit();
    const b2 = try layout(&big, &a, try boxedNode(&a), &fm_default, .text, 60, .italic);
    try testing.expectApproxEqAbs(margin, big.children(b2)[0].x_shift, 0.001);
    try testing.expect(big.get(b2).width > bb.width);
}

test "layout: \\boxed sets its content in display style even in inline math" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "ab");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    const size_pt: f32 = 20;
    const frac = try a.createNode(.fraction, 0, 2, &.{
        a.node(try a.createLeaf(.char, 0, 1, 0)),
        a.node(try a.createLeaf(.char, 1, 1, 0)),
    }, atom.fracData(true, null, false));
    // The same fraction bare, in each style, for reference.
    const text_frac = list.get(try layout(&list, &a, frac, &fm_default, .text, size_pt, .italic));
    const disp_frac = list.get(try layout(&list, &a, frac, &fm_default, .display, size_pt, .italic));
    // \boxed of it, written in INLINE math: the content is a fresh display
    // list (amsmath's `\fbox{\m@th$\displaystyle#1$}`), so the frame wraps a
    // DISPLAY fraction. The fixed margin is added around it, so the CONTENT
    // box is what carries the comparison.
    const boxed = try a.createNode(.boxed, 0, 2, &.{a.node(frac)}, 0);
    const b = try layout(&list, &a, boxed, &fm_default, .text, size_pt, .italic);
    const content = list.get(list.children(b)[0].idx);
    try testing.expectApproxEqAbs(disp_frac.height, content.height, 0.001);
    try testing.expectApproxEqAbs(disp_frac.depth, content.depth, 0.001);
    // ... and that is genuinely different from the inline form: the display
    // gaps (num1/denom1) are wider than the text ones on both sides.
    try testing.expect(text_frac.height < disp_frac.height);
    try testing.expect(text_frac.depth < disp_frac.depth);
}

test "layout: a color scope paints its subtree and nests without leaking" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    var a = atom.Ast.init(testing.allocator, "bcd");
    defer a.deinit();
    try a.pushToken(.{ .tag = .char, .start = 0, .end = 1 });
    try a.pushToken(.{ .tag = .char, .start = 1, .end = 2 });
    try a.pushToken(.{ .tag = .char, .start = 2, .end = 3 });
    const red: atom.Color = .{ .r = 0xFF, .g = 0, .b = 0, .a = 0xFF };
    const blue: atom.Color = .{ .r = 0, .g = 0, .b = 0xFF, .a = 0x80 };
    // \color{red} b \textcolor{blue}{c} d — a declaration around the whole
    // row with a grouped argument inside it.
    const row = try a.createNode(.row, 0, 3, &.{
        a.node(try a.createLeaf(.char, 0, 1, 0)),
        a.node(try a.createNode(.textcolor, 1, 1, &.{
            a.node(try a.createLeaf(.char, 1, 1, 0)),
        }, atom.colorData(blue))),
        a.node(try a.createLeaf(.char, 2, 1, 0)),
    }, 0);
    const scope = try a.createNode(.color, 0, 3, &.{a.node(row)}, atom.colorData(red));
    const b = try layout(&list, &a, scope, &fm_default, .text, 10, .italic);
    // The scope is its OWN box carrying the color; nothing below it is
    // rewritten, which is exactly what makes leaving the scope restore the
    // enclosing color.
    try testing.expectEqual(red, list.get(b).color.?);
    const ch = list.children(b);
    try testing.expectEqual(@as(usize, 1), ch.len);
    try testing.expect(list.get(ch[0].idx).color == null); // the row
    const glyphs = list.children(ch[0].idx);
    try testing.expectEqual(@as(usize, 3), glyphs.len);
    // The NESTED scope shadows the outer one, alpha included.
    try testing.expectEqual(blue, list.get(glyphs[1].idx).color.?);
    try testing.expectEqual(@as(u8, 0x80), list.get(glyphs[1].idx).color.?.a);
    // A TRANSPARENT foreground {0,0,0,0} is a real override, never "inherit":
    // it must be stored, not treated as an absent scope.
    const clear: atom.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const clear_node = try a.createNode(.color, 0, 3, &.{a.node(row)}, atom.colorData(clear));
    const cb = try layout(&list, &a, clear_node, &fm_default, .text, 10, .italic);
    try testing.expectEqual(clear, list.get(cb).color.?);
    try testing.expectEqual(@as(u8, 0), list.get(cb).color.?.a);
}

test "layout: \\hline draws one full-width rule per entry and never a row" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    // Five real tokens, one per entry: the env claims the whole run, so a
    // node pointing at a token the table does not have is a broken fixture,
    // not a layout question.
    const src = "abcde";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const row1 = try a.createNode(.row, 1, 1, &.{a.node(try a.createLeaf(.char, 1, 1, 0))}, 0);
    const row2 = try a.createNode(.row, 3, 1, &.{a.node(try a.createLeaf(.char, 3, 1, 0))}, 0);
    // Three SEPARATE rule entries — a leading one, one between the rows and
    // a trailing one, each its own leaf exactly as the parser emits them.
    const kids = [_]atom.Node{
        a.node(try a.createLeaf(.hline, 0, 1, 0)),
        a.node(row1),
        a.node(try a.createLeaf(.hline, 2, 1, 0)),
        a.node(row2),
        a.node(try a.createLeaf(.hline, 4, 1, 0)),
    };
    const env = try a.createNode(.env, 0, 5, &kids, atom.envData(.array, "cc"));
    const b = try layout(&list, &a, env, &fm_default, .display, 10, .italic);
    // [array] — the vbox, holding TWO rows plus THREE rules. A leading rule
    // does not fabricate an empty row: the row count is the ROW count.
    const array = list.children(b);
    try testing.expectEqual(@as(usize, 1), array.len);
    try testing.expectEqual(box.Kind.vbox, list.get(array[0].idx).kind);
    const stack = list.children(array[0].idx);
    const arr_w = list.get(array[0].idx).width;
    var rule_shifts: [3]f32 = undefined;
    var row_shifts: [2]f32 = undefined;
    var ri: usize = 0;
    var rj: usize = 0;
    for (stack) |cr| {
        const sb = list.get(cr.idx);
        if (sb.kind == .rule) {
            // Each rule spans the WHOLE array advance, at \arrayrulewidth.
            try testing.expectApproxEqAbs(arr_w, sb.width, 0.001);
            try testing.expectApproxEqAbs(arrayrulewidth_pt, sb.height + sb.depth, 0.001);
            rule_shifts[ri] = cr.shift;
            ri += 1;
        } else {
            row_shifts[rj] = cr.shift;
            rj += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), ri);
    try testing.expectEqual(@as(usize, 2), rj);
    // In SOURCE ORDER: above the first row, between the rows, below the last.
    try testing.expect(rule_shifts[0] < row_shifts[0]);
    try testing.expect(row_shifts[0] < rule_shifts[1]);
    try testing.expect(rule_shifts[1] < row_shifts[1]);
    try testing.expect(row_shifts[1] < rule_shifts[2]);
}

/// One entry of a `\begin{env}` body, in source order: a `\hline` rule leaf
/// at the given token, or a row whose CELLS are the given char tokens — one
/// cell per token, one token per source byte, the shape pushCharTokens
/// builds. An entry list with no rows at all is an environment with no rows.
const EnvEntry = union(enum) {
    rule: u32,
    row: []const u32,
};

/// A `\begin{kind}{colspec}` environment node whose body is exactly
/// `entries`: rule leaves and row nodes interleaved in source order, with the
/// delimiter leaves `open_cp`/`close_cp` bracket them the way parseBegin emits
/// them (null = none, as a bare `\begin{matrix}` or `\begin{array}`).
fn envFixture(
    a: *atom.Ast,
    kind: atom.EnvKind,
    colspec: []const u8,
    open_cp: ?u21,
    close_cp: ?u21,
    entries: []const EnvEntry,
) !u32 {
    var kids: std.ArrayList(atom.Node) = .empty;
    defer kids.deinit(a.gpa);
    if (open_cp) |cp| try kids.append(a.gpa, a.node(try a.createLeaf(.char, 0, 1, cp)));
    for (entries) |e| {
        switch (e) {
            .rule => |tok| try kids.append(a.gpa, a.node(try a.createLeaf(.hline, tok, 1, 0))),
            .row => |cells| {
                var nodes: std.ArrayList(atom.Node) = .empty;
                defer nodes.deinit(a.gpa);
                for (cells) |tok| {
                    try nodes.append(a.gpa, a.node(try a.createLeaf(.char, tok, 1, 0)));
                }
                const first = if (cells.len == 0) @as(u32, 0) else cells[0];
                try kids.append(a.gpa, a.node(try a.createNode(
                    .row,
                    first,
                    @intCast(cells.len),
                    nodes.items,
                    0,
                )));
            },
        }
    }
    if (close_cp) |cp| try kids.append(a.gpa, a.node(try a.createLeaf(.char, 0, 1, cp)));
    return a.createNode(.env, 0, 1, kids.items, atom.envData(kind, colspec));
}

/// The array vbox inside an environment box with no delimiter children.
fn envArray(list: *box.BoxList, env_box: u32) u32 {
    return list.children(env_box)[0].idx;
}

test "layout: consecutive \\hline rules stack \\doublerulesep apart and clear the rows" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "abcdefgh";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    // The corpus shape: a leading PAIR, two rows, one trailing rule. Two rules
    // on one boundary are two separate \noalign entries, and latex.ltx's
    // `\@xhline` (the \futurelet in `\hline`) sees the second one and adds
    // `\vskip\doublerulesep \vskip-\arrayrulewidth` after the first. Measured
    // on the exact-font XeLaTeX reference at 20pt: the pair's rule centres sit
    // 2.0004pt apart and the pair opens the array by 2 × 0.4 + 1.6 = 2.4pt.
    const env = try envFixture(&a, .array, "cc", null, null, &.{
        .{ .rule = 0 },
        .{ .rule = 1 },
        .{ .row = &.{ 2, 3 } },
        .{ .row = &.{ 4, 5 } },
        .{ .rule = 6 },
    });
    const env_box = try layout(&list, &a, env, &fm_default, .display, 10, .italic);
    const array = envArray(&list, env_box);
    const stack = list.children(array);
    // Rows first, then the rule entries in source order.
    try testing.expectEqual(@as(usize, 5), stack.len);
    const row0 = list.get(stack[0].idx);
    const row1 = list.get(stack[1].idx);
    // Three DISTINCT rules, every one \arrayrulewidth thick and spanning the
    // whole array advance (a bare \array keeps its pads, so no overhang).
    for (stack[2..]) |cr| {
        const rb = list.get(cr.idx);
        try testing.expectEqual(box.Kind.rule, rb.kind);
        try testing.expectApproxEqAbs(@as(f32, 0.4), rb.height + rb.depth, 0.001);
        try testing.expectApproxEqAbs(list.get(array).width, rb.width, 0.001);
    }
    // \doublerulesep between the two leading rules, so the ink bands clear
    // each other instead of painting on top of one another.
    try testing.expectApproxEqAbs(@as(f32, 2.0), stack[3].shift - stack[2].shift, 0.001);
    try testing.expect(stack[2].shift - 0.4 < stack[3].shift);
    // The LOWER leading rule is flush with the first row's top edge, the upper
    // one \doublerulesep − \arrayrulewidth of clear space above it: no rule
    // ever lands on a row's own strut.
    try testing.expectApproxEqAbs(stack[0].shift - row0.height, stack[3].shift, 0.001);
    // The trailing rule hangs directly under the last row's bottom edge: its
    // own top edge, one \arrayrulewidth above its shift, is that edge.
    try testing.expectApproxEqAbs(stack[1].shift + row1.depth, stack[4].shift - 0.4, 0.001);
    // The pair is the array's whole leading overhang and the trailing rule its
    // whole depth overhang.
    try testing.expectApproxEqAbs(@as(f32, 2.4), list.get(array).height - (row0.height - stack[0].shift), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), list.get(array).depth - (row1.depth + stack[1].shift), 0.001);
}

test "layout: an interior \\hline pair opens the row pitch by its own stack" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "abcdef";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    // \begin{matrix}a&b\\\hline\hline c&d\end{matrix}: rows stack directly, so
    // the pitch is \baselineskip plus whatever the rules between them occupy.
    // Measured at 20pt on XeLaTeX: 26.49pt against a 24.09pt \baselineskip —
    // 2 × \arrayrulewidth plus one \doublerulesep − \arrayrulewidth of air.
    const env = try envFixture(&a, .array, "cc", null, null, &.{
        .{ .row = &.{ 0, 1 } },
        .{ .rule = 2 },
        .{ .rule = 3 },
        .{ .row = &.{ 4, 5 } },
    });
    const env_box = try layout(&list, &a, env, &fm_default, .display, 10, .italic);
    const array = envArray(&list, env_box);
    const stack = list.children(array);
    // Rows first, then the rule entries: [row0, row1, rule0, rule1].
    try testing.expectEqual(@as(usize, 4), stack.len);
    const row0 = list.get(stack[0].idx);
    const row1 = list.get(stack[1].idx);
    // The rows stack directly, so the pitch is row0's own depth plus row1's own
    // height — whatever the struts make them — plus the pair's stack. The two
    // rules contribute 2 × \arrayrulewidth and one \doublerulesep − \arrayrulewidth.
    try testing.expectApproxEqAbs(row0.depth + row1.height + 2.4, stack[1].shift - stack[0].shift, 0.001);
    // The pair is \doublerulesep apart, and its LAST rule ends flush against
    // the row below it while the first one sits on the row above's bottom.
    try testing.expectApproxEqAbs(@as(f32, 2.0), stack[3].shift - stack[2].shift, 0.001);
    try testing.expectApproxEqAbs(stack[1].shift - row1.height, stack[3].shift, 0.001);
    try testing.expect(stack[2].shift - 0.4 < stack[3].shift - 0.4);
    try testing.expect(stack[2].shift - 0.4 >= stack[0].shift + row0.depth);
}

test "layout: a matrix \\hline overhangs the box by \\arraycolsep, an \\array's does not" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "abcd";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    // latex.ltx:16728 makes `\hline` a `\noalign{\hrule}`, and a noalign rule
    // spans the WHOLE \halign width — the outer \arraycolsep pads included.
    // amsmath's matrix family cancels those pads from the ADVANCE only
    // (`\hskip -\arraycolsep` either side of `\array`), so the rule overhangs
    // the matrix box by \arraycolsep per side. Measured at 20pt: box
    // 31.5405pt, rule 41.5402pt, first ink 5.0pt left of the box.
    const rows = [_]EnvEntry{
        .{ .row = &.{0} },
        .{ .row = &.{1} },
    };
    const bare = try envFixture(&a, .matrix, "", null, null, &rows);
    const ruled = [_]EnvEntry{
        .{ .rule = 2 },
        .{ .row = &.{0} },
        .{ .row = &.{1} },
        .{ .rule = 3 },
    };
    const ruled_env = try envFixture(&a, .matrix, "", null, null, &ruled);
    const bare_box = try layout(&list, &a, bare, &fm_default, .display, 10, .italic);
    const ruled_box = try layout(&list, &a, ruled_env, &fm_default, .display, 10, .italic);
    const bare_array = envArray(&list, bare_box);
    const ruled_array = envArray(&list, ruled_box);
    // The rules change the array's HEIGHT only: the matrix advance is the
    // plain one, both pads cancelled, and \begin{matrix}a\\b\end{matrix} is
    // not one point wider than its ruled sibling.
    try testing.expectApproxEqAbs(
        list.get(bare_array).width,
        list.get(ruled_array).width,
        0.001,
    );
    const stack = list.children(ruled_array);
    try testing.expectEqual(@as(usize, 4), stack.len);
    for ([_]usize{ 2, 3 }) |i| {
        const rb = list.get(stack[i].idx);
        try testing.expectApproxEqAbs(list.get(ruled_array).width + 10.0, rb.width, 0.001);
        try testing.expectApproxEqAbs(@as(f32, -5.0), stack[i].x_shift, 0.001);
    }
    // A bare \begin{array} keeps its pads, so the same rule spans the box
    // exactly and starts flush at its left edge.
    const arr_env = try envFixture(&a, .array, "c", null, null, &[_]EnvEntry{
        .{ .rule = 2 },
        .{ .row = &.{0} },
        .{ .rule = 3 },
    });
    const arr_box = try layout(&list, &a, arr_env, &fm_default, .display, 10, .italic);
    const arr_array = envArray(&list, arr_box);
    const arr_stack = list.children(arr_array);
    try testing.expectEqual(@as(usize, 3), arr_stack.len);
    for ([_]usize{ 1, 2 }) |i| {
        const rb = list.get(arr_stack[i].idx);
        try testing.expectApproxEqAbs(list.get(arr_array).width, rb.width, 0.001);
        try testing.expectApproxEqAbs(@as(f32, 0.0), arr_stack[i].x_shift, 0.001);
    }
}

test "layout: a row with missing cells keeps the column origins and the array width" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "abc";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    // \begin{matrix}a\\a&b\end{matrix}: TeX's \halign pads a short row to the
    // alignment width, so the row keeps the cell it HAS at column 0's origin
    // and its row box still spans the whole advance. Measured on XeTeX at
    // 20pt: the short row's content starts exactly where the long row's first
    // cell does, at the matrix's flush left edge.
    //
    // Both rows open with the SAME cell, so each column is exactly as wide as
    // that cell and every centering offset is zero — a difference in x_shift
    // here would be a moved column, not a centered cell.
    const env = try envFixture(&a, .matrix, "", null, null, &[_]EnvEntry{
        .{ .row = &.{0} },
        .{ .row = &.{ 0, 1 } },
    });
    // \halign measures a column by each cell's ADVANCE plus the MATH italic
    // correction of its last char (cellTrailingIc, verified against XeTeX), so
    // a column is never its bare advance: math-italic `a` (U+1D44E) has no IC
    // entry, `b` (U+1D44F) adds 0.014em = 0.14pt here. The origins and the
    // array advance below are measured from the same advance + IC.
    const full = a.child(env, 1);
    const col_a = list.get(try charBox(&list, &a, 0x1D44E, .text, 10)).width +
        cellTrailingIc(&a, a.child(full, 0), &fm_default, .italic, 10);
    const col_b = list.get(try charBox(&list, &a, 0x1D44F, .text, 10)).width +
        cellTrailingIc(&a, a.child(full, 1), &fm_default, .italic, 10);
    const env_box = try layout(&list, &a, env, &fm_default, .display, 10, .italic);
    const array = envArray(&list, env_box);
    const stack = list.children(array);
    try testing.expectEqual(@as(usize, 2), stack.len);
    const short_row = list.children(stack[0].idx);
    const full_row = list.children(stack[1].idx);
    // No phantom cell is invented for the column the short row never reaches.
    try testing.expectEqual(@as(usize, 1), short_row.len);
    try testing.expectEqual(@as(usize, 2), full_row.len);
    // Column 0 is flush at the matrix's left edge (both outer pads cancelled)
    // and column 1 starts one \arraycolsep pair after column 0's content.
    try testing.expectApproxEqAbs(@as(f32, 0.0), short_row[0].x_shift, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), full_row[0].x_shift, 0.001);
    try testing.expectApproxEqAbs(col_a + 10.0, full_row[1].x_shift, 0.001);
    // The array advance is its columns plus one \arraycolsep pair between
    // them, and BOTH rows are stretched to it.
    try testing.expectApproxEqAbs(col_a + 10.0 + col_b, list.get(array).width, 0.001);
    for (stack) |cr| {
        try testing.expectApproxEqAbs(list.get(array).width, list.get(cr.idx).width, 0.001);
    }
}

test "layout: an environment with no rows draws only its delimiters" {
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "ab";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    // \begin{pmatrix}\end{pmatrix}: no row entry at all, so no array vbox is
    // fabricated — TeX renders a pair of base-size parens.
    const pm = try envFixture(&a, .pmatrix, "", '(', ')', &.{});
    const pm_box = try layout(&list, &a, pm, &fm_default, .display, 10, .italic);
    const pm_kids = list.children(pm_box);
    try testing.expectEqual(@as(usize, 2), pm_kids.len);
    for (pm_kids) |cr| try testing.expectEqual(box.Kind.char, list.get(cr.idx).kind);
    // A bare environment with no rows is an empty box: zero advance, no
    // children, and no rule geometry invented for a body that has none.
    const bare = try envFixture(&a, .array, "c", null, null, &.{});
    const bare_box = try layout(&list, &a, bare, &fm_default, .display, 10, .italic);
    try testing.expectEqual(@as(usize, 0), list.children(bare_box).len);
    try testing.expectApproxEqAbs(@as(f32, 0.0), list.get(bare_box).width, 0.001);
}

test "layout: a matrix row strut is \\baselineskip" {
    // LaTeX's `\@array` zeroes \baselineskip and \lineskip inside a matrix,
    // so the strut alone fixes the baseline distance between two rows: 0.7 +
    // 0.3 of \baselineskip. Measured 12pt at 10pt and 43.2pt at 36pt; 24pt
    // at 20pt and 72pt at 60pt close the series, and none of them is the text
    // paren's 0.75 + 0.25em box this replaced.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "xy";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    for ([_]f32{ 10, 20, 36, 60 }) |size_pt| {
        const env = try twoRowEnv(&a, .matrix, null);
        const b = try layout(&list, &a, env, &fm_default, .display, size_pt, .italic);
        try testing.expectApproxEqAbs(1.2 * size_pt, envRowPitch(&list, b), 0.001);
    }
}

test "layout: a \\hline sits flush on the strut" {
    // \begin{array}{c}\hline a\\\hline\end{array} at 20pt. A rule is a bare
    // \noalign \hrule: it opens its boundary by its own \arrayrulewidth and
    // never lands ON a row's strut. The leading rule's own bottom edge IS the
    // row's top edge, the trailing rule's own top edge IS the row's bottom
    // edge, and the whole box is the row's 16.8 + 7.2 strut with one 0.4pt
    // rule above and one below — h 17.4 / d 7.4.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "abc";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const env = try envFixture(&a, .array, "c", null, null, &.{
        .{ .rule = 0 },
        .{ .row = &.{1} },
        .{ .rule = 2 },
    });
    const b = try layout(&list, &a, env, &fm_default, .display, 20, .italic);
    const array = envArray(&list, b);
    const ab = list.get(array);
    try testing.expectApproxEqAbs(@as(f32, 17.4), ab.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 7.4), ab.depth, 0.001);
    const stack = list.children(array);
    try testing.expectEqual(@as(usize, 3), stack.len);
    const row = list.get(stack[0].idx);
    try testing.expectApproxEqAbs(@as(f32, 16.8), row.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 7.2), row.depth, 0.001);
    for (stack[1..]) |cr| {
        const rb = list.get(cr.idx);
        try testing.expectEqual(box.Kind.rule, rb.kind);
        try testing.expectApproxEqAbs(@as(f32, 0.4), rb.height + rb.depth, 0.001);
        try testing.expectApproxEqAbs(ab.width, rb.width, 0.001);
    }
    try testing.expectApproxEqAbs(stack[0].shift - row.height, stack[1].shift, 0.001);
    try testing.expectApproxEqAbs(stack[0].shift + row.depth, stack[2].shift - 0.4, 0.001);
}

test "layout: a leading \\hline pair opens by \\arrayrulewidth + \\doublerulesep" {
    // \begin{array}{c}\hline\hline a\\\hline\end{array} at 20pt. Two rules on
    // the LEADING boundary are two separate \noalign entries, so latex.ltx's
    // \@xhline puts \doublerulesep of air between their ink bands and the
    // boundary opens by \arrayrulewidth + \doublerulesep = 2.4pt: h 18.4 /
    // d 8.4, the pair 2.0pt apart, and the LOWER of the two the one flush
    // against the row's top edge.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "abcd";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const env = try envFixture(&a, .array, "c", null, null, &.{
        .{ .rule = 0 },
        .{ .rule = 1 },
        .{ .row = &.{2} },
        .{ .rule = 3 },
    });
    const b = try layout(&list, &a, env, &fm_default, .display, 20, .italic);
    const array = envArray(&list, b);
    const ab = list.get(array);
    try testing.expectApproxEqAbs(@as(f32, 18.4), ab.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8.4), ab.depth, 0.001);
    const stack = list.children(array);
    try testing.expectEqual(@as(usize, 4), stack.len);
    const row = list.get(stack[0].idx);
    for (stack[1..]) |cr| {
        const rb = list.get(cr.idx);
        try testing.expectEqual(box.Kind.rule, rb.kind);
        try testing.expectApproxEqAbs(@as(f32, 0.4), rb.height + rb.depth, 0.001);
    }
    // The pair is the array's whole leading overhang: one thickness plus one
    // \doublerulesep above the row's own top edge.
    try testing.expectApproxEqAbs(@as(f32, 2.4), ab.height + (stack[0].shift - row.height), 0.001);
    try testing.expectApproxEqAbs(-ab.height, stack[1].shift - 0.4, 0.001);
    // The two ink bands clear each other instead of painting on top of one
    // another, and the lower rule is the one that meets the row.
    try testing.expectApproxEqAbs(@as(f32, 2.0), stack[2].shift - stack[1].shift, 0.001);
    try testing.expect(stack[1].shift - 0.4 < stack[2].shift);
    try testing.expectApproxEqAbs(stack[0].shift - row.height, stack[2].shift, 0.001);
    try testing.expectApproxEqAbs(stack[0].shift + row.depth, stack[3].shift - 0.4, 0.001);
}

test "layout: an array colspec rule spans the strut" {
    // latex.ltx's template puts a `|` \vrule INSIDE every row's column box, so
    // the overlapping rules read as one continuous line that spans each row's
    // own strut extent exactly — 16.8 + 7.2 = 24pt at 20pt, flush at both
    // edges, \arrayrulewidth thick across and centred on the array's left edge.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "abcd";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const env = try envFixture(&a, .array, "|cc", null, null, &.{
        .{ .row = &.{ 0, 1 } },
        .{ .row = &.{ 2, 3 } },
    });
    const b = try layout(&list, &a, env, &fm_default, .display, 20, .italic);
    const array = envArray(&list, b);
    const stack = list.children(array);
    try testing.expectEqual(@as(usize, 2), stack.len);
    // The rows stand one \baselineskip apart, so the two rules join into a
    // single line over both of them.
    try testing.expectApproxEqAbs(@as(f32, 24.0), stack[1].shift - stack[0].shift, 0.001);
    for (stack) |cr| {
        const row = list.get(cr.idx);
        const kids = list.children(cr.idx);
        // [cell, cell, rule]: the rule is the template's own column entry.
        try testing.expectEqual(@as(usize, 3), kids.len);
        const rb = list.get(kids[2].idx);
        try testing.expectEqual(box.Kind.rule, rb.kind);
        try testing.expectApproxEqAbs(@as(f32, 24.0), rb.height + rb.depth, 0.001);
        try testing.expectApproxEqAbs(row.height, rb.height, 0.001);
        try testing.expectApproxEqAbs(row.depth, rb.depth, 0.001);
        try testing.expectApproxEqAbs(@as(f32, 0.4), rb.width, 0.001);
        try testing.expectApproxEqAbs(@as(f32, -0.2), kids[2].x_shift, 0.001);
    }
}

test "layout: \\hline is \\arrayrulewidth thick at every size" {
    // \arrayrulewidth is a FIXED 0.4pt (article.cls), never scaled with the
    // font: a rule on a 60pt row is exactly as thick as one on a 10pt row,
    // and the strut beside it is untouched at every size.
    var list = box.BoxList.init(testing.allocator);
    defer list.deinit();
    const src = "abc";
    var a = atom.Ast.init(testing.allocator, src);
    defer a.deinit();
    try pushCharTokens(&a, src);
    const env = try envFixture(&a, .array, "c", null, null, &.{
        .{ .rule = 0 },
        .{ .row = &.{1} },
    });
    for ([_]f32{ 10, 20, 60 }) |size_pt| {
        const b = try layout(&list, &a, env, &fm_default, .display, size_pt, .italic);
        const array = envArray(&list, b);
        const ab = list.get(array);
        const stack = list.children(array);
        try testing.expectEqual(@as(usize, 2), stack.len);
        const row = list.get(stack[0].idx);
        const rb = list.get(stack[1].idx);
        try testing.expectEqual(box.Kind.rule, rb.kind);
        try testing.expectApproxEqAbs(@as(f32, 0.4), rb.height + rb.depth, 0.001);
        // The rule is the whole overhang, and the row's strut stands whole
        // under it — nothing of it is eaten by the rule's own thickness.
        try testing.expectApproxEqAbs(@as(f32, 0.4), ab.height + (stack[0].shift - row.height), 0.001);
        try testing.expectApproxEqAbs(stack[0].shift - row.height, stack[1].shift, 0.001);
        try testing.expectApproxEqAbs(1.2 * size_pt, row.height + row.depth, 0.001);
    }
}
