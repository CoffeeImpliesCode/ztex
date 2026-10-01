//! ztex.parse.parser — token table → superflat atom pool (recursive descent).
//!
//! Walks the pre-lexed token table once, appending flat `atom.Node`s to the
//! Ast's pool via the duplication protocol (children copied as values before
//! their parent), so every node's child run is contiguous. Each node records
//! its token range for O(1) source-provenance.

const std = @import("std");
const atom = @import("ztex.atom");
const lexer = @import("lexer.zig");
const parse_err = @import("error.zig");

pub const Error = atom.Error || error{
    UnexpectedRGroup,
    UnexpectedScript,
    DoubleScript,
    UnknownCommand,
    MissingArgument,
    MissingScript,
    UnclosedGroup,
    /// \middle outside \left...\right (TeX: "You can't use \middle in math
    /// mode"; it needs the enclosing fence's required size).
    UnexpectedMiddle,
    MisplacedHline,
    /// \begin with an unknown environment name (TeX: "Environment xxx
    /// undefined").
    UnknownEnvironment,
    /// \end{NAME} whose name does not match the \begin{NAME}.
    MismatchedEnd,
    /// \begin{...} never closed by \end{...} (or \end missing its name).
    UnclosedEnvironment,
    /// The parse nested deeper than `max_nesting`. A few-KB input of nested
    /// braces/fractions is ~1 level per byte and would overflow the C stack;
    /// Zig cannot catch a stack overflow, so without this guard the host
    /// process would die. See `max_nesting`.
    NestingTooDeep,
};

/// Opcode for each supported command name; `cmd_map` returns one of these and
/// `parseCommand`'s switch applies the command's effect.
const Command = enum {
    space_comma,
    space_semicolon,
    space_bang,
    quad,
    qquad,
    frac,
    /// \dfrac: \frac forced to display style (display gaps, parts one level
    /// down from display)
    frac_display,
    /// \tfrac: \frac forced to text style (text gaps, script-size parts)
    frac_text,
    /// \cfrac: display-style continued fraction — display gaps AND both
    /// parts set in display style (amsmath: \frac{\displaystyle..}{\displaystyle..})
    cfrac,
    atop,
    /// \binom{num}{den} = \genfrac{(}{)}{0pt}{}{num}{den}: a ruleless
    /// fraction inside \left( \right) parens (auto-sized by the variant
    /// ladder)
    binom,
    /// \dbinom{num}{den} = \genfrac{(}{)}{0pt}{0}{num}{den}: \binom with
    /// the style argument FORCED to display (amsmath), so the parts and the
    /// amsc fixed-delimiter parens both size as display even inside a
    /// script or a text-style formula
    dbinom,
    /// \tbinom{num}{den} = \genfrac{(}{)}{0pt}{1}{num}{den}: \binom forced
    /// to text style (amsmath)
    tbinom,
    /// \genfrac{left}{right}{thick}{style}{num}{den}: the generalized
    /// fraction — explicit delimiters (possibly empty), rule thickness
    /// (0pt = \atop-style no rule), forced style (0=display 1=text
    /// 2=script 3=scriptscript, empty = current), numerator, denominator
    genfrac,
    text,
    style_roman,
    /// \operatorname{...} / \operatorname*{...}: amsmath's declarable
    /// operator name — a \mathop whose content is the braced group set in
    /// upright roman (unstarred = nolimits, starred = displaylimits).
    operatorname,
    style_bold,
    style_bb,
    style_cal,
    style_frak,
    style_sans,
    style_mono,
    cdot,
    op_sum,
    op_int,
    op_prod,
    op_coprod,
    op_bigcup,
    op_bigcap,
    op_bigsqcup,
    op_oint,
    op_oiint,
    op_oiiint,
    op_ointctrclockwise,
    /// the \bigXXX n-ary family + \bigstar (amsmath's \slimits@ group) and
    /// the big integrals \bigint \bigiint \bigiiint
    op_bigodot,
    op_bigoplus,
    op_bigotimes,
    op_biguplus,
    op_bigsqcap,
    op_bigwedge,
    op_bigvee,
    op_bigstar,
    op_bigint,
    op_bigiint,
    op_bigiiint,
    /// \mathop{<field>}: TeX's generic \mathop — the math field in upright
    /// roman with the OP class and no limits (the `.opname` model, data 0)
    mathop,
    /// \mathord \mathrel \mathbin \mathopen \mathclose \mathpunct
    /// \mathinner: the math field wrapped in a forced class (a `.row` of one
    /// child whose data packs the class — atom.classRowData)
    mathord,
    mathrel,
    mathbin,
    mathopen,
    mathclose,
    mathpunct,
    mathinner,
    /// \colon: the colon as PUNCTUATION (plain TeX's `\def\colon
    /// {\mathpunct{:}}`), unlike a bare `:` which is a relation
    colon,
    /// an operator word (\sin \lim \log ...): roman styled run of the name
    opname,
    /// \left ... \right delimited construct
    left,
    /// a stray \right (extra, outside any \left)
    right,
    /// \big \Big \bigg \Bigg: a delimiter at a FIXED ladder level
    /// (1..4); the parsed result is a `.left` node with a single
    /// delimiter child and `data` = the level.
    big,
    Big,
    bigg,
    Bigg,
    /// \middle <delim> inside \left...\right: a delimiter sized like the
    /// enclosing pair.
    middle,
    /// \limits / \nolimits / \displaylimits: consumed by parseScripts
    /// between a base and its scripts, setting the limits override bit on
    /// the preceding op/opname atom; as standalone atoms they become a
    /// zero-width space
    limits,
    nolimits,
    displaylimits,
    /// \sqrt[degree]{radicand}: surd char + radicand row
    sqrt,
    /// \dot \hat \bar \vec \ddot \tilde: an accent row (children
    /// [base, accent-mark char]; data = accent_row_data)
    dot,
    hat,
    bar,
    vec,
    /// \widehat{x} / \widetilde{x}: the EXTENSIBLE accents amsfonts picks
    /// for an argument wider than 2em (a wide-accent row — children
    /// [base, accent-mark char], data = wide_hat_row_data /
    /// wide_tilde_row_data). The mark codepoint is the ordinary combining
    /// one (\hat / \tilde): Latin Modern Math carries no U+0362 / U+0365,
    /// the spacing forms amsfonts' narrow branch uses.
    widehat,
    widetilde,
    ddot,
    tilde,
    /// \overline{x} / \underline{x}: a `.overline` atom (children
    /// [content]; data = 0 over / 1 under)
    overline,
    underline,
    /// \mathchoice{D}{T}{S}{SS}: a `.mathchoice` atom (children = the four
    /// style branches [D, T, S, SS]); layout picks the branch matching the
    /// current math style and forces the branch's own style
    mathchoice,
    /// \not<relation>: a negation PREFIX — the following atom/group gets a
    /// diagonal slash. Emits the pre-composed glyph when one exists (see
    /// `not_cp_map`), else a `not_row_data` row whose layout overlays the
    /// U+0338 combining long solidus overlay.
    not,
    /// \substack{...}: a script-size multi-line stack for limits (children
    /// = the \\-separated line rows; a `.substack` atom)
    substack,
    /// \pmod{n} / \pod{n}: amsmath's parenthesized mod — a composed row
    /// ['(', (roman "mod" + 6mu space, for \pmod), arg, ')'] with the
    /// leading \mkern 8mu in every style (the amsmath \if@display 18mu
    /// branch never fires inside \array cells — measured on XeTeX).
    pmod,
    pod,
    /// \bmod: amsmath's binary mod — a row ['5mu space, roman "mod" word,
    /// 5mu space'] (the \mskip-\medmuskip\mkern5mu dance around the
    /// \mathbin{mod} nets to 5mu on each side; see bmod()).
    bmod,
    /// \mod{arg}: amsmath's display-style mod — a row [roman "mod" word,
    /// 6mu space, arg] with the leading \mkern 12mu in every style (the
    /// amsmath \if@display 18mu branch never fires inside \array cells —
    /// measured on XeTeX; see mod()).
    mod,
    /// \overset{top}{base} / \underset{bot}{base} / \stackrel{top}{base}:
    /// amsmath's / the kernel's \mathop-with-forced-limits forms (a row of
    /// children [script, base], laid out as centred over/under limits)
    overset,
    underset,
    stackrel,
    /// \phantom{x} / \hphantom{x} / \vphantom{x} / \smash{x}: an invisible
    /// box keeping the argument's dimensions in the four combinations amsmath
    /// defines (a row of children [content], data = the keep mask)
    phantom,
    hphantom,
    vphantom,
    smash,
    /// \underbrace{x}_{c} / \overbrace{x}^{c}: a brace band under/over the
    /// content (a row of children [content] or [content, annotation])
    underbrace,
    overbrace,
    /// \hspace{<dim>} / \kern<dim> / \mkern<dim>: an explicit horizontal skip
    /// whose dimension unit decides how layout scales it
    hspace,
    kern,
    mkern,
    /// \: — LaTeX's medium math space (\tmspace+\medmuskip = +4mu)
    space_colon,
    /// \  — the interword space (one third of the em)
    space_control,
    /// \arraystretch{n}: the row-strut factor for the environments that
    /// follow (a zero-width `.space` leaf; the value rides on the env's
    /// first row — see `Stretch`)
    arraystretch,
    /// \tag{n}: amsmath's equation number — a `tag_row_data` row of the
    /// braced argument set in upright roman
    tag,
    /// \begin{env}...\end{env}: a math environment (matrix family, cases,
    /// aligned, array) — parsed by parseBegin into a `.env` atom.
    begin,
    /// \boxed{x}: a frame around ONE math field (amsmath \boxed =
    /// \fbox{\m@th$\displaystyle #1$}), a `.boxed` atom
    boxed,
    /// \color{<spec>}: a foreground-color DECLARATION — the color applies
    /// to the rest of the current group/row/cell and is restored when that
    /// scope ends (intercepted by parseRow, never by parseCommand)
    color,
    /// \textcolor{<spec>}{<text>}: the color applied to the braced argument
    /// only, a `.textcolor` atom of one child (an ORD GROUP — see the tag)
    textcolor,
    /// \hline: a full-width rule BETWEEN environment rows (a `.hline`
    /// leaf; legal only at an environment row boundary, see parseEnvBody)
    hline,
    /// \textit{...}: a TEXT italic face — raw bytes in LM Roman Italic,
    /// NOT math italic (a `.text` leaf carrying CharStyle.text_italic)
    textit,
    /// \textbf{...}: a TEXT bold face — a `.text` leaf carrying the
    /// existing CharStyle.bold
    textbf,
};

/// Comptime command table keyed by the exact command names (no backslash).
/// std.StaticStringMap sorts the keys by length at comptime: `getIndex`
/// rejects unknown lengths O(1) and scans only the equal-length bucket with
/// byte equality — no length off-by-one is possible because the compiler
/// derives key lengths from the literal strings.
const cmd_map = std.StaticStringMap(Command).initComptime(&[_]struct { []const u8, Command }{
    .{ ",", .space_comma },
    .{ ";", .space_semicolon },
    .{ "!", .space_bang },
    .{ "quad", .quad },
    .{ "qquad", .qquad },
    .{ "frac", .frac },
    .{ "dfrac", .frac_display },
    .{ "tfrac", .frac_text },
    .{ "cfrac", .cfrac },
    .{ "atop", .atop },
    .{ "binom", .binom },
    .{ "dbinom", .dbinom },
    .{ "tbinom", .tbinom },
    .{ "genfrac", .genfrac },
    .{ "text", .text },
    .{ "mathrm", .style_roman },
    .{ "operatorname", .operatorname },
    .{ "mathbf", .style_bold },
    .{ "mathbb", .style_bb },
    .{ "mathcal", .style_cal },
    .{ "mathfrak", .style_frak },
    .{ "mathsf", .style_sans },
    .{ "mathtt", .style_mono },
    .{ "cdot", .cdot },
    .{ "sum", .op_sum },
    .{ "int", .op_int },
    .{ "prod", .op_prod },
    .{ "coprod", .op_coprod },
    .{ "bigcup", .op_bigcup },
    .{ "bigcap", .op_bigcap },
    .{ "bigsqcup", .op_bigsqcup },
    .{ "oint", .op_oint },
    .{ "oiint", .op_oiint },
    .{ "oiiint", .op_oiiint },
    .{ "ointctrclockwise", .op_ointctrclockwise },
    .{ "ointctrclockwisectr", .op_ointctrclockwise },
    // the remaining big operators: the \bigXXX n-ary family and \bigstar
    // (amsmath redeclares exactly these with \slimits@), then the big
    // integrals, which reuse the plain integral codepoints at a larger size
    .{ "bigodot", .op_bigodot },
    .{ "bigoplus", .op_bigoplus },
    .{ "bigotimes", .op_bigotimes },
    .{ "biguplus", .op_biguplus },
    .{ "bigsqcap", .op_bigsqcap },
    .{ "bigwedge", .op_bigwedge },
    .{ "bigvee", .op_bigvee },
    .{ "bigstar", .op_bigstar },
    .{ "bigint", .op_bigint },
    .{ "bigiint", .op_bigiint },
    .{ "bigiiint", .op_bigiiint },
    // TeX's class primitives: \mathop and the \mathXXX family, plus \colon
    // (punctuation, unlike a bare `:`)
    .{ "mathop", .mathop },
    .{ "mathord", .mathord },
    .{ "mathrel", .mathrel },
    .{ "mathbin", .mathbin },
    .{ "mathopen", .mathopen },
    .{ "mathclose", .mathclose },
    .{ "mathpunct", .mathpunct },
    .{ "mathinner", .mathinner },
    .{ "colon", .colon },
    .{ "left", .left },
    .{ "right", .right },
    .{ "big", .big },
    .{ "Big", .Big },
    .{ "bigg", .bigg },
    .{ "Bigg", .Bigg },
    .{ "middle", .middle },
    .{ "limits", .limits },
    .{ "nolimits", .nolimits },
    .{ "displaylimits", .displaylimits },
    .{ "sqrt", .sqrt },
    // accents: a combining mark over the following atom/group
    .{ "dot", .dot },
    .{ "hat", .hat },
    .{ "bar", .bar },
    .{ "vec", .vec },
    .{ "ddot", .ddot },
    .{ "tilde", .tilde },
    // the EXTENSIBLE accents: the same marks as \hat / \tilde, but layout
    // builds the amsfonts-style wide accent past 2em
    .{ "widehat", .widehat },
    .{ "widetilde", .widetilde },
    // a rule over / under the following atom/group
    .{ "overline", .overline },
    .{ "underline", .underline },
    // the four-style choice primitive: pick the branch matching the
    // current math style, forced to the branch's own style
    .{ "mathchoice", .mathchoice },
    // a negation slash through the following atom/group
    .{ "not", .not },
    // a script-size multi-line stack for limits; the parenthesized mod
    .{ "substack", .substack },
    .{ "pmod", .pmod },
    .{ "pod", .pod },
    .{ "begin", .begin },
    // operator names → roman words (\sin x, \lim_{...}); see opname()
    .{ "sin", .opname },
    .{ "cos", .opname },
    .{ "tan", .opname },
    .{ "cot", .opname },
    .{ "sec", .opname },
    .{ "csc", .opname },
    .{ "arcsin", .opname },
    .{ "arccos", .opname },
    .{ "arctan", .opname },
    .{ "sinh", .opname },
    .{ "cosh", .opname },
    .{ "tanh", .opname },
    .{ "coth", .opname },
    .{ "sech", .opname },
    .{ "csch", .opname },
    .{ "arcsec", .opname },
    .{ "arccsc", .opname },
    .{ "log", .opname },
    .{ "ln", .opname },
    .{ "lg", .opname },
    .{ "exp", .opname },
    .{ "lim", .opname },
    .{ "limsup", .opname },
    .{ "liminf", .opname },
    .{ "max", .opname },
    .{ "min", .opname },
    .{ "sup", .opname },
    .{ "inf", .opname },
    .{ "arg", .opname },
    .{ "ker", .opname },
    .{ "dim", .opname },
    .{ "det", .opname },
    .{ "gcd", .opname },
    .{ "Pr", .opname },
    .{ "hom", .opname },
    .{ "deg", .opname },
    // \mod and \bmod are NOT \mathop words: \mod takes an argument and a
    // style-dependent leading \mkern, \bmod is a \mathbin with 5mu kerns
    // (see bmod()/mod()).
    .{ "mod", .mod },
    .{ "bmod", .bmod },
    // forced-limit scripts over/under a base: a row of [script, base]
    .{ "overset", .overset },
    .{ "underset", .underset },
    .{ "stackrel", .stackrel },
    // the four invisible boxes; the keep mask distinguishes the variants
    .{ "phantom", .phantom },
    .{ "hphantom", .hphantom },
    .{ "vphantom", .vphantom },
    .{ "smash", .smash },
    // the brace decorations, each with an optional _ / ^ annotation
    .{ "underbrace", .underbrace },
    .{ "overbrace", .overbrace },
    // explicit horizontal skips; \: is LaTeX's medium math space and \  its
    // interword space (a control symbol's name IS its single byte, so the
    // control space is the command " ")
    .{ "hspace", .hspace },
    .{ "kern", .kern },
    .{ "mkern", .mkern },
    .{ ":", .space_colon },
    .{ " ", .space_control },
    // the row-strut factor for the environments that follow, and amsmath's
    // equation number
    .{ "arraystretch", .arraystretch },
    .{ "tag", .tag },
    .{ "boxed", .boxed },
    .{ "color", .color },
    .{ "textcolor", .textcolor },
    .{ "hline", .hline },
    .{ "textit", .textit },
    .{ "textbf", .textbf },
});

/// \displaystyle \textstyle \scriptstyle \scriptscriptstyle → forced math
/// styles. A style switch applies to the REST OF THE CURRENT GROUP (TeX
/// mathlist semantics), so parseRow and parseScriptArg intercept the command
/// name directly and wrap the remaining atoms in a `.mathstyle` node;
/// parseCommand never sees these names.
const mathstyle_map = std.StaticStringMap(atom.MathStyle).initComptime(&[_]struct { []const u8, atom.MathStyle }{
    .{ "displaystyle", .display },
    .{ "textstyle", .text },
    .{ "scriptstyle", .script },
    .{ "scriptscriptstyle", .script_script },
});

/// Greek, relations, arrows, binary ops, and misc symbols: command name →
/// Unicode codepoint. Each maps to a `.char` leaf carrying the codepoint in
/// its `data` (same mechanism as \cdot), so layout resolves the glyph, the
/// role (roleOfCp), and the metrics. `\atop \over \choose` are NOT here:
/// they are infix row-level commands intercepted by parseRow.
const symbol_map = std.StaticStringMap(u21).initComptime(&[_]struct { []const u8, u21 }{
    // Greek lowercase (U+03B1..U+03C9 + variants). \epsilon and \varepsilon
    // follow unicode-math (XeTeX reference emits \varepsilon → U+03B5, the
    // ROUNDED epsilon; \epsilon → U+03F5, the lunate) — the OPPOSITE of
    // classic Computer-Modern TeX. Verified against the XeTeX reference
    // render of \frac{\rho}{\varepsilon_0}: \varepsilon → U+1D700 (rounded
    // math-italic), while the old mapping emitted U+1D716 (lunate).
    .{ "alpha", 0x03B1 },
    .{ "beta", 0x03B2 },
    .{ "gamma", 0x03B3 },
    .{ "delta", 0x03B4 },
    .{ "epsilon", 0x03F5 },
    .{ "varepsilon", 0x03B5 },
    .{ "zeta", 0x03B6 },
    .{ "eta", 0x03B7 },
    .{ "theta", 0x03B8 },
    .{ "vartheta", 0x03D1 },
    .{ "iota", 0x03B9 },
    .{ "kappa", 0x03BA },
    .{ "lambda", 0x03BB },
    .{ "mu", 0x03BC },
    .{ "nu", 0x03BD },
    .{ "xi", 0x03BE },
    .{ "pi", 0x03C0 },
    .{ "varpi", 0x03D6 },
    .{ "rho", 0x03C1 },
    .{ "varrho", 0x03F1 },
    .{ "sigma", 0x03C3 },
    .{ "varsigma", 0x03C2 },
    .{ "tau", 0x03C4 },
    .{ "upsilon", 0x03C5 },
    .{ "phi", 0x03C6 },
    .{ "varphi", 0x03D5 },
    .{ "chi", 0x03C7 },
    .{ "psi", 0x03C8 },
    .{ "omega", 0x03C9 },
    // Greek uppercase
    .{ "Gamma", 0x0393 },
    .{ "Delta", 0x0394 },
    .{ "Theta", 0x0398 },
    .{ "Lambda", 0x039B },
    .{ "Xi", 0x039E },
    .{ "Pi", 0x03A0 },
    .{ "Sigma", 0x03A3 },
    .{ "Upsilon", 0x03A5 },
    .{ "Phi", 0x03A6 },
    .{ "Psi", 0x03A8 },
    .{ "Omega", 0x03A9 },
    // Relations
    .{ "leq", 0x2264 },
    .{ "le", 0x2264 },
    .{ "leqq", 0x2266 },
    .{ "geq", 0x2265 },
    .{ "ge", 0x2265 },
    .{ "geqq", 0x2267 },
    .{ "neq", 0x2260 },
    .{ "ne", 0x2260 },
    .{ "in", 0x2208 },
    .{ "ni", 0x220B },
    .{ "notin", 0x2209 },
    // pre-composed negated relations (unicode-math codepoints; every one is
    // in LM Math's cmap, verified with fontTools)
    .{ "nleq", 0x2270 },
    .{ "ngeq", 0x2271 },
    .{ "nsubseteq", 0x2288 },
    .{ "nsupseteq", 0x2289 },
    .{ "nmid", 0x2224 },
    .{ "nparallel", 0x2226 },
    .{ "nprec", 0x2280 },
    .{ "nsucc", 0x2281 },
    .{ "npreceq", 0x22E0 },
    .{ "nsucceq", 0x22E1 },
    .{ "nsim", 0x2241 },
    .{ "ncong", 0x2247 },
    .{ "napprox", 0x2249 },
    .{ "subset", 0x2282 },
    .{ "supset", 0x2283 },
    .{ "subseteq", 0x2286 },
    .{ "supseteq", 0x2287 },
    .{ "sim", 0x223C },
    .{ "simeq", 0x2243 },
    .{ "cong", 0x2245 },
    .{ "approx", 0x2248 },
    .{ "propto", 0x221D },
    .{ "equiv", 0x2261 },
    .{ "ll", 0x226A },
    .{ "gg", 0x226B },
    .{ "prec", 0x227A },
    .{ "succ", 0x227B },
    .{ "preceq", 0x2AAF },
    .{ "succeq", 0x2AB0 },
    .{ "vdash", 0x22A2 },
    .{ "dashv", 0x22A3 },
    .{ "perp", 0x22A5 },
    .{ "parallel", 0x2225 },
    .{ "mid", 0x2223 },
    .{ "asymp", 0x224D },
    .{ "doteq", 0x2250 },
    .{ "models", 0x22A8 },
    .{ "bowtie", 0x22C8 },
    .{ "frown", 0x2322 },
    .{ "smile", 0x2323 },
    // Arrows
    .{ "leftarrow", 0x2190 },
    .{ "rightarrow", 0x2192 },
    .{ "to", 0x2192 },
    .{ "leftrightarrow", 0x2194 },
    .{ "Leftarrow", 0x21D0 },
    .{ "Rightarrow", 0x21D2 },
    .{ "implies", 0x21D2 },
    .{ "impliedby", 0x21D0 },
    .{ "Leftrightarrow", 0x21D4 },
    .{ "iff", 0x21D4 },
    .{ "uparrow", 0x2191 },
    .{ "downarrow", 0x2193 },
    .{ "updownarrow", 0x2195 },
    .{ "Uparrow", 0x21D1 },
    .{ "Downarrow", 0x21D3 },
    .{ "Updownarrow", 0x21D5 },
    .{ "mapsto", 0x21A6 },
    .{ "longmapsto", 0x27FC },
    .{ "nearrow", 0x2197 },
    .{ "searrow", 0x2198 },
    .{ "swarrow", 0x2199 },
    .{ "nwarrow", 0x2196 },
    .{ "hookleftarrow", 0x21A9 },
    .{ "hookrightarrow", 0x21AA },
    .{ "leftharpoonup", 0x21BC },
    .{ "leftharpoondown", 0x21BD },
    .{ "rightharpoonup", 0x21C0 },
    .{ "rightharpoondown", 0x21C1 },
    // Binary ops
    .{ "pm", 0x00B1 },
    .{ "mp", 0x2213 },
    .{ "times", 0x00D7 },
    .{ "div", 0x00F7 },
    .{ "ast", 0x2217 },
    .{ "star", 0x22C6 },
    .{ "circ", 0x2218 },
    .{ "bullet", 0x2219 },
    .{ "oplus", 0x2295 },
    .{ "ominus", 0x2296 },
    .{ "otimes", 0x2297 },
    .{ "oslash", 0x2298 },
    .{ "odot", 0x2299 },
    .{ "wedge", 0x2227 },
    .{ "vee", 0x2228 },
    .{ "land", 0x2227 },
    .{ "lor", 0x2228 },
    .{ "cup", 0x222A },
    .{ "cap", 0x2229 },
    .{ "sqcup", 0x2294 },
    .{ "sqcap", 0x2293 },
    .{ "setminus", 0x2216 },
    .{ "dagger", 0x2020 },
    .{ "ddagger", 0x2021 },
    .{ "diamond", 0x22C4 },
    .{ "wr", 0x2240 },
    .{ "uplus", 0x228E },
    .{ "amalg", 0x2A3F },
    .{ "triangleleft", 0x25C3 },
    .{ "triangleright", 0x25B9 },
    .{ "bigcirc", 0x25CB },
    // Misc symbols
    .{ "infty", 0x221E },
    .{ "partial", 0x2202 },
    .{ "nabla", 0x2207 },
    .{ "prime", 0x2032 },
    .{ "dots", 0x2026 },
    .{ "ldots", 0x2026 },
    .{ "cdots", 0x22EF },
    .{ "ddots", 0x22F1 },
    .{ "ell", 0x2113 },
    .{ "Re", 0x211C },
    .{ "Im", 0x2111 },
    .{ "wp", 0x2118 },
    .{ "aleph", 0x2135 },
    .{ "forall", 0x2200 },
    .{ "exists", 0x2203 },
    .{ "neg", 0x00AC },
    .{ "lnot", 0x00AC },
    .{ "top", 0x22A4 },
    .{ "bot", 0x22A5 },
    .{ "emptyset", 0x2205 },
    .{ "varnothing", 0x2205 },
    .{ "angle", 0x2220 },
    .{ "triangle", 0x25B3 },
    .{ "square", 0x25A1 },
    .{ "surd", 0x221A },
    .{ "clubsuit", 0x2663 },
    .{ "diamondsuit", 0x2662 },
    .{ "heartsuit", 0x2661 },
    .{ "spadesuit", 0x2660 },
    .{ "backslash", 0x2216 },
    .{ "lbrace", 0x7B },
    .{ "rbrace", 0x7D },
    .{ "vert", 0x7C },
    .{ "Vert", 0x2016 },
    .{ "langle", 0x27E8 },
    .{ "rangle", 0x27E9 },
    .{ "lfloor", 0x230A },
    .{ "rfloor", 0x230B },
    .{ "lceil", 0x2308 },
    .{ "rceil", 0x2309 },
    .{ "therefore", 0x2234 },
    .{ "because", 0x2235 },
    // The colon family. \colon is NOT here: plain TeX typesets it as
    // PUNCTUATION (`\def\colon{\mathpunct{:}}`) while a bare `:` is a
    // relation, so it needs a forced class and lives in cmd_map.
    // \coloneqq / \Coloneqq are mathtools' `:=` / `::=`; unicode-math spells
    // the same two symbols \coloneq (U+2254) and \Coloneq (U+2A74) — but
    // Latin Modern Math has NO U+2A74, so \Coloneqq falls back to the
    // single-glyph COLON EQUALS U+2254 (it still draws a relation glyph with
    // relation glue; only the doubled colon is lost). \Colon and \ratio are
    // unicode-math's U+2237 PROPORTION and U+2236 RATIO.
    .{ "coloneqq", 0x2254 },
    .{ "coloneqqs", 0x2254 },
    .{ "Coloneqq", 0x2254 },
    .{ "Coloneqqs", 0x2254 },
    .{ "coloneq", 0x2255 },
    .{ "Colon", 0x2237 },
    .{ "ratio", 0x2236 },
    .{ "hbar", 0x210F },
    .{ "imath", 0x0131 },
    .{ "jmath", 0x0237 },
});

/// Delimiter commands accepted after \left / \right → codepoint.
const delim_map = std.StaticStringMap(u21).initComptime(&[_]struct { []const u8, u21 }{
    .{ "{", 0x7B },
    .{ "}", 0x7D },
    .{ "langle", 0x27E8 },
    .{ "rangle", 0x27E9 },
    .{ "lfloor", 0x230A },
    .{ "rfloor", 0x230B },
    .{ "lceil", 0x2308 },
    .{ "rceil", 0x2309 },
    .{ "lbrace", 0x7B },
    .{ "rbrace", 0x7D },
    .{ "vert", 0x7C },
    .{ "Vert", 0x2016 },
    .{ "|", 0x2016 }, // \|
    .{ "backslash", 0x2216 },
    .{ "\\", 0x2216 }, // \\
    .{ "/", 0x2F },
});

/// The single answer to "what commands does this parser support": the union
/// of the four dispatch tables' keys (cmd_map + mathstyle_map + symbol_map +
/// delim_map), GENERATED comptime from the tables so it cannot drift from
/// them. A command added to any table appears here automatically; a
/// hand-written entry here without a backing table fails the coverage test
/// below. The union is deduplicated and sorted for deterministic external
/// enumeration: a name shared by two tables is listed ONCE (the intended
/// reuse is delim_map ↔ symbol_map — see the collision test), so this is a
/// true set, not a multiset.
pub const supported_commands: []const []const u8 = blk: {
    // The comptime pdq sort over ~230 names exceeds the default 1000-branch
    // comptime eval budget.
    @setEvalBranchQuota(200_000);
    const tables = [_][]const []const u8{
        cmd_map.keys(),
        mathstyle_map.keys(),
        symbol_map.keys(),
        delim_map.keys(),
    };
    var total: usize = 0;
    for (tables) |t| total += t.len;
    var names: [total][]const u8 = undefined;
    var n: usize = 0;
    for (tables) |t| for (t) |k| {
        names[n] = k;
        n += 1;
    };
    std.mem.sort([]const u8, &names, {}, supportedLessThan);
    // Count distinct names (the dedup tracks the LAST DISTINCT value, not a
    // raw index — a raw `names[j-1]` can be a stale duplicate after earlier
    // collapses), then materialize into a const array so the returned slice
    // references comptime-constant memory (a slice into the `var names`
    // buffer itself would be "a reference to comptime var").
    var last: ?[]const u8 = null;
    var m: usize = 0;
    for (names) |k| {
        if (last == null or !std.mem.eql(u8, last.?, k)) {
            m += 1;
            last = k;
        }
    }
    const result: [m][]const u8 = result_blk: {
        var out: [m][]const u8 = undefined;
        var j: usize = 0;
        for (names) |k| {
            if (j == 0 or !std.mem.eql(u8, out[j - 1], k)) {
                out[j] = k;
                j += 1;
            }
        }
        break :result_blk out;
    };
    break :blk &result;
};

/// Byte-wise less-than for `supported_commands`' deterministic sort.
fn supportedLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The `data` a \sqrt row node carries so layout routes it through
/// layoutSqrt (stretchy radical + vinculum) instead of the ordinary row
/// path. Ordinary parseRow rows always carry data 0, so this is unambiguous.
const sqrt_row_data: u32 = 1;

/// The `data` an accent row node carries so layout routes it through
/// layoutAccent (base + combining mark) instead of the ordinary row path.
const accent_row_data: u32 = 2;

/// Bit 21 of a \middle delimiter char leaf's `data`: the low 21 bits hold
/// the delimiter's codepoint (delimiterCp/layoutChar read only those via
/// @truncate), bit 21 marks the leaf as a \middle delimiter — layout sizes
/// it with the enclosing \left...\right pair's required ink instead of
/// rendering it at the base size. Mirrored in layout.zig (middle_marker).
const middle_marker: u32 = 1 << 21;

/// The `data` a \not row node carries (children [base]) so layout routes it
/// through layoutNot — the base relation with the U+0338 overlay slash —
/// instead of the ordinary row path. Ordinary parseRow rows always carry
/// data 0, so this is unambiguous.
const not_row_data: u32 = 3;

/// The `data` a \pmod row node carries (children ['(', roman "mod" word,
/// 6mu space, arg, ')']) so layout routes it through layoutPmod — the
/// 8mu leading \mkern (style-invariant: amsmath's \if@display 18mu branch
/// never fires inside \array cells — measured on XeTeX) plus the fixed
/// \mkern6mu mod-n gap — instead of the ordinary row path.
const pmod_row_data: u32 = 4;

/// The `data` a \pod row node carries (children ['(', arg, ')']): the
/// parenthesized argument WITHOUT the "mod" word (layoutPmod still applies
/// the leading \mkern).
const pod_row_data: u32 = 5;

/// The `data` a \bmod row node carries (children [5mu space, roman "mod"
/// word, 5mu space]) so layout routes it through layoutBmod — the pieces
/// placed back to back with the two 5mu kerns (amsmath's \bmod dance
/// \mskip-\medmuskip\mkern5mu\mathbin{mod}\penalty900\mkern5mu
/// \mskip-\medmuskip nets to 5mu on each side once the ord↔bin glue is
/// summed) — instead of the ordinary row path.
const bmod_row_data: u32 = 6;

/// The `data` a \mod row node carries (children [roman "mod" word, 6mu
/// space, arg]) so layout routes it through layoutMod — the 12mu leading
/// \mkern (style-invariant: amsmath's \if@display 18mu branch never fires
/// inside \array cells — measured on XeTeX) plus the fixed \mkern6mu
/// mod-arg gap — instead of the ordinary row path.
const mod_row_data: u32 = 7;

/// The `data` an \overset / \underset / \stackrel row node carries (children
/// [script, base]) so layout routes it through the forced-limits path — the
/// three share one geometry; only the class the row reports differs.
const overset_row_data: u32 = 8;
const underset_row_data: u32 = 9;
const stackrel_row_data: u32 = 10;

/// The `data` an \underbrace / \overbrace row node carries (children
/// [content] or [content, annotation]) so layout routes it through the brace
/// path — the brace band plus the optional forced-limit annotation.
const underbrace_row_data: u32 = 11;
const overbrace_row_data: u32 = 12;

/// The `data` a \widehat / \widetilde row node carries (children [base,
/// accent-mark char] — the SAME shape as accent_row_data) so layout routes
/// it through the EXTENSIBLE-accent path. amsfonts.sty:79-86 (and
/// amstex.sty:1931-1938) measure the argument in \textstyle and pick the
/// narrow \mathaccent"0362 / "0365 below 2em, the wide extensible accent
/// above it; Latin Modern Math maps neither U+0362 nor U+0365, so the mark
/// is the ordinary combining U+0302 / U+0303 that \hat / \tilde already
/// draw. Markers 13 (atom.ClassBits), 16 (the phantom family) and 32 (the
/// kern family) are taken, so 14 and 15 are the first free values.
const wide_hat_row_data: u32 = 14;
const wide_tilde_row_data: u32 = 15;

/// Bit 6 of a \tag row node's `data` marks the construct (children [the
/// braced argument, wrapped in a `.styled` roman scope] so the digits draw
/// upright like \operatorname's). amsmath's equation number is hoisted OUT
/// of the math list (amsmath.sty:1210-1212 builds it as a separate
/// \hbox{...} beside the display), so it is a noad in no list and takes no
/// inter-atom glue on either side; bit 6 keeps it clear of the fixed
/// markers 1..12, atom.ClassBits's 13, the phantom family's bit 4 and the
/// kern family's bit 5.
const tag_row_data: u32 = 1 << 6;

/// Bit 5 of an explicit-kern row's `data` marks the family (\hspace / \kern /
/// \mkern, and `\:`'s constant mu skip); bits 0-1 carry the dimension's unit
/// (see `dim_pt`) and the magnitude rides in the row's single `.space` child
/// (a space leaf's f32 em payload). Values 32..35, disjoint from the fixed row
/// markers 1..12 above and from the phantom family (bit 4).
const kern_row_data: u32 = 1 << 5;

/// Dimension units: TeX's absolute-point ones never scale with the font size;
/// em/ex follow the current style's size; mu is style-invariant (1/18 em of
/// the ladder-neutral em, the convention \pmod's 8mu and \mod's 12mu already
/// follow).
const dim_pt: u32 = 0;
const dim_em: u32 = 1;
const dim_ex: u32 = 2;
const dim_mu: u32 = 3;

/// Bit 4 of a \phantom-family row's `data` marks the family; the low bits are
/// the keep mask — which of the argument box's dimensions survive. \phantom
/// keeps all three, \vphantom the height and depth, \hphantom the width, and
/// \smash the width alone (amsmath's `\smash[<axes>]` zeroes ht and/or dp of
/// the argument box and always keeps the advance, so its default `[tb]` is
/// exactly \hphantom).
const phantom_row_data: u32 = 1 << 4;
const keep_width: u32 = 1;
const keep_height: u32 = 2;
const keep_depth: u32 = 4;
const keep_vertical: u32 = keep_height | keep_depth;

/// Bit 7 of a \phantom-family row's `data` marks `\smash`, the ONE member
/// of the family that DRAINS its content instead of hiding it. The keep
/// mask alone cannot tell them apart — `\smash{tb}` and `\hphantom` are
/// both `keep_width` — but they are not the same box: `\smash` keeps the
/// argument as its single child and zeroes only the selected axes
/// (measured: `\smash{b}` at 30pt is 8.86pt wide on the XeTeX reference,
/// still PAINTED, with h 0 and d 0), while every `\phantom` variant is an
/// empty metrics-only box. Bit 7 is free: bit 4 is the family marker, bits
/// 0-3 the keep mask, bit 5 the kern family, bit 6 the \tag row.
const smash_row: u32 = 1 << 7;

/// Relation codepoint → its pre-composed negated form, for \not<relation>.
/// unicode-math's \not command uses the pre-composed glyph when one exists
/// (verified against the XeTeX reference: \not\in → U+2209, \not\leq →
/// U+2270, \not= → U+2260, \not\subset → U+2284, \not\simeq → U+2244 — all
/// single glyphs), so ztex emits the same codepoint; relations without a
/// pre-composed form fall back to the U+0338 overlay row (layoutNot). Every
/// target is in LM Math's cmap (verified with fontTools), and every target
/// has a row in the layout metric table, so the emitted char resolves.
/// Sorted by `cp` for the linear scan; matches unicode-math-table.tex.
const not_cp_map = [_]struct { cp: u21, neg: u21 }{
    .{ .cp = 0x3C, .neg = 0x226E }, // < → ≮ \nless
    .{ .cp = 0x3D, .neg = 0x2260 }, // = → ≠ \neq
    .{ .cp = 0x3E, .neg = 0x226F }, // > → ≯ \ngtr
    .{ .cp = 0x2208, .neg = 0x2209 }, // ∈ → ∉ \notin
    .{ .cp = 0x220B, .neg = 0x220C }, // ∋ → ∌ \notni
    .{ .cp = 0x2223, .neg = 0x2224 }, // ∣ → ∤ \nmid
    .{ .cp = 0x2225, .neg = 0x2226 }, // ∥ → ∦ \nparallel
    .{ .cp = 0x223C, .neg = 0x2241 }, // ∼ → ≁ \nsim
    .{ .cp = 0x2243, .neg = 0x2244 }, // ≃ → ≄ \nsimeq
    .{ .cp = 0x2245, .neg = 0x2247 }, // ≅ → ≇ \ncong
    .{ .cp = 0x2248, .neg = 0x2249 }, // ≈ → ≉ \napprox
    .{ .cp = 0x224D, .neg = 0x226D }, // ≍ → ≭ \nasymp
    .{ .cp = 0x2261, .neg = 0x2262 }, // ≡ → ≢ \nequiv
    .{ .cp = 0x2264, .neg = 0x2270 }, // ≤ → ≰ \nleq
    .{ .cp = 0x2265, .neg = 0x2271 }, // ≥ → ≱ \ngeq
    .{ .cp = 0x227A, .neg = 0x2280 }, // ≺ → ⊀ \nprec
    .{ .cp = 0x227B, .neg = 0x2281 }, // ≻ → ⊁ \nsucc
    .{ .cp = 0x2282, .neg = 0x2284 }, // ⊂ → ⊄ \nsubset
    .{ .cp = 0x2283, .neg = 0x2285 }, // ⊃ → ⊅ \nsupset
    .{ .cp = 0x2286, .neg = 0x2288 }, // ⊆ → ⊈ \nsubseteq
    .{ .cp = 0x2287, .neg = 0x2289 }, // ⊇ → ⊉ \nsupseteq
    .{ .cp = 0x22A2, .neg = 0x22AC }, // ⊢ → ⊬ \nvdash
    .{ .cp = 0x2AAF, .neg = 0x22E0 }, // ⪯ → ⋠ \npreceq
    .{ .cp = 0x2AB0, .neg = 0x22E1 }, // ⪰ → ⋡ \nsucceq
};

/// Maximum parse-nesting depth, counted as active `parseRow` frames.
/// parseRow/parseGroup/parseCommand/parseDelimiter recurse mutually at
/// ~4 frames per nesting level, so 500 levels ≈ 2K frames — comfortably
/// inside the default stack — while still admitting any realistic formula.
/// Deeper input fails with `error.NestingTooDeep` instead of overflowing
/// the stack (Zig cannot catch a stack overflow, so the host process
/// would otherwise die).
pub const max_nesting: u32 = 500;

/// Recursive-descent parser over a flat token table.
/// The `\arraystretch` state the parser carries: the factor in force and
/// whether this factor was assigned at the level being parsed right now. The
/// two travel together because a scope that ends one ends the other — every
/// group, `\left … \right` pair and environment body saves the pair and hands
/// it back — so `assigned` says "the CELL being parsed assigned a factor" and
/// never "a group, a pair or a nested body inside it did".
const Stretch = struct {
    /// the factor in force, as the f32 em bits `atom.emToFixed` stores;
    /// 0 = no assignment in effect
    factor: u32 = 0,
    /// 1 when `factor` was assigned by an `\arraystretch` at THIS level —
    /// never inside a group, a `\left … \right` pair or an environment body,
    /// each of which restores the pair it found
    assigned: bool = false,
};

pub const Parser = struct {
    gpa: std.mem.Allocator,
    src: []const u8,
    tokens: []const atom.Token,
    pos: usize = 0,
    /// 1 while parsing the interior of a \left ... \right pair (parseRow in
    /// .delimited mode): \middle is only valid there (TeX). parseLeftRight
    /// increments before the interior and decrements after.
    delim_depth: u32 = 0,
    /// Current parse-nesting depth: the number of active parseRow frames.
    /// parseRow is the common recursion point of every mutually-recursive
    /// path (groups, fractions, \left..\right, environments, style
    /// switches, substacks), so counting it there bounds them all. When the
    /// depth exceeds `max_nesting` the parse fails with NestingTooDeep
    /// instead of overflowing the stack.
    depth: u32 = 0,
    /// \arraystretch's state: the factor the environments that follow are
    /// built from, and whether it was assigned at the level being parsed.
    ///
    /// GROUP-LOCAL, like the LaTeX `\def\arraystretch{…}` it mirrors:
    /// `{\arraystretch{1.4}\begin{array}…\end{array}}` must not change the
    /// strut of a LATER environment outside the braces, so parseGroup saves
    /// and restores this pair around the group's body, and parseLeftRight
    /// does the same around `\left … \right`. Within one group a factor
    /// stays in force until reassigned and applies to every environment
    /// after it.
    ///
    /// CELL-LOCAL inside an environment body: parseEnvBody hands the pair
    /// back after every cell, so an `\arraystretch` written in a cell sizes
    /// the environments opened AFTER it in that same cell and nothing else.
    /// What the environment's OWN rows are built from is captured apart from
    /// this field (`env_factor` in parseEnvBody) from the cells of its FIRST
    /// row: an assignment in one cell keeps its factor through the plain
    /// cells after it, an assignment in a later cell replaces it, and the
    /// last one written wins.
    stretch: Stretch = .{},
    /// Cells parsed so far in the environment row in progress; 0 at a row
    /// boundary. parseRow consults it in `.env_cell` mode so `\hline` ends a
    /// cell ONLY before the row's first `&` (TeX: \noalign is legal solely
    /// between rows), and parseEnvBody resets it after every `\\`.
    env_row_cells: u32 = 0,
    /// Caller-provided parse-error context: filled (when non-null) with the
    /// kind + offending span immediately before any error is returned.
    err_info: ?*parse_err.Info = null,

    pub fn init(
        gpa: std.mem.Allocator,
        src: []const u8,
        tokens: []const atom.Token,
        err_info: ?*parse_err.Info,
    ) Parser {
        return .{ .gpa = gpa, .src = src, .tokens = tokens, .err_info = err_info };
    }

    fn atEnd(self: *const Parser) bool {
        return self.pos >= self.tokens.len;
    }

    fn peek(self: *const Parser) ?atom.Token {
        if (self.atEnd()) return null;
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) ?atom.Token {
        if (self.atEnd()) return null;
        const t = self.tokens[self.pos];
        self.pos += 1;
        return t;
    }

    /// Fill the caller's Info (when provided) with a kind + span.
    fn setErr(self: *Parser, kind: parse_err.Kind, span: atom.Span) void {
        if (self.err_info) |info| info.* = .{ .kind = kind, .span = span };
    }

    /// Record semantic parser error context and return the matching error-set
    /// value. Node-construction failures use `createNode` so child-count
    /// overflow records the construct span before propagating.
    /// The error VALUES remain unchanged (`expectError` still sees
    /// `error.Xxx`), and the Info is always filled before the caller's
    /// `catch` observes a parser error.
    /// This switch is the parser's kind→error mapping; lexer-only kinds never
    /// reach the parser because `fail` is called only with parser kinds.
    fn fail(self: *Parser, kind: parse_err.Kind, span: atom.Span) Error {
        self.setErr(kind, span);
        return switch (kind) {
            .unexpected_r_group => error.UnexpectedRGroup,
            .unexpected_script => error.UnexpectedScript,
            .double_script => error.DoubleScript,
            .unknown_command => error.UnknownCommand,
            .missing_argument => error.MissingArgument,
            .missing_script => error.MissingScript,
            .unclosed_group => error.UnclosedGroup,
            .unexpected_middle => error.UnexpectedMiddle,
            .misplaced_hline => error.MisplacedHline,
            .unknown_environment => error.UnknownEnvironment,
            .mismatched_end => error.MismatchedEnd,
            .unclosed_environment => error.UnclosedEnvironment,
            .child_count_overflow => error.ChildCountOverflow,
            .nesting_too_deep => error.NestingTooDeep,
            // The lexer-only kinds have no parser error values (they are
            // returned directly by lex()/parse() at their own sites), so a
            // call here is a programming error. Abort loudly in EVERY build
            // mode: `unreachable` is undefined behavior in ReleaseFast and
            // could corrupt the process instead of failing.
            .dangling_escape, .invalid_utf8, .source_too_large => @panic(
                "parse.parser.fail: lexer-only kind routed to the parser",
            ),
        };
    }

    /// Span of the token at `pos`, or a zero-width span at end of source
    /// (for "expected X but hit end of input" errors).
    fn spanAt(self: *const Parser, pos: usize) atom.Span {
        if (pos < self.tokens.len) {
            const t = self.tokens[pos];
            return .{ .start = t.start, .end = t.end };
        }
        const end: u32 = @intCast(self.src.len);
        return .{ .start = end, .end = end };
    }

    /// Span of the CURRENT token (or zero-width at EOF).
    fn curSpan(self: *const Parser) atom.Span {
        return self.spanAt(self.pos);
    }

    /// Span of a token value (from peek/advance).
    fn spanOf(t: atom.Token) atom.Span {
        return .{ .start = t.start, .end = t.end };
    }

    /// Create a node and report child-count overflow at the construct span.
    fn createNode(
        self: *Parser,
        ast: *atom.Ast,
        node_kind: atom.Tag,
        first_token: u32,
        num_tokens: u32,
        children: []const atom.Node,
        data: u32,
    ) Error!u32 {
        return ast.createNode(node_kind, first_token, num_tokens, children, data) catch |err| {
            if (err == error.ChildCountOverflow) {
                return self.fail(.child_count_overflow, self.nodeSpan(first_token, num_tokens));
            }
            return err;
        };
    }

    fn nodeSpan(self: *const Parser, first_token: u32, num_tokens: u32) atom.Span {
        const first: usize = @intCast(first_token);
        if (num_tokens == 0) return self.spanAt(first);
        if (first >= self.tokens.len) return self.spanAt(first);
        const last = @min(
            first + @as(usize, @intCast(num_tokens)) - 1,
            self.tokens.len - 1,
        );
        return .{ .start = self.tokens[first].start, .end = self.tokens[last].end };
    }

    /// Parse the whole token table into a row atom (the root).
    pub fn parse(self: *Parser, ast: *atom.Ast) Error!u32 {
        const root = try self.parseRow(ast, .top);
        if (!self.atEnd()) return self.fail(.unexpected_r_group, self.curSpan());
        return root;
    }

    const RowMode = enum {
        /// end of input
        top,
        /// `}` (not consumed)
        group,
        /// `\right` (not consumed) or `}` — the interior of \left ... \right
        delimited,
        /// `\\` (not consumed) or `}` — ONE LINE of a \substack: parseRow
        /// stops at the line separator or the closing brace, so each line
        /// becomes its own row.
        substack_line,
        /// ONE CELL of a \begin{env} body: parseRow stops at `&` (char),
        /// `\\` (command), `\end` (command), or `}` (not consumed), so the
        /// env parser can split rows on `\\` and cells on `&`.
        env_cell,
    };

    /// Parse atoms until end-of-input (.top), `}` (.group, not consumed), or
    /// `\right` (.delimited, not consumed).
    ///
    /// Infix generalized fractions: `\atop \over \choose` split the row —
    /// everything before the delimiter becomes the numerator, everything
    /// after it (to the row's end) the denominator, and the whole row is
    /// returned as a fraction node (TeX: `{a \atop b}`). A second delimiter
    /// is ambiguous (TeX: "you need another { and }") and errors.
    fn parseRow(self: *Parser, ast: *atom.Ast, mode: RowMode) Error!u32 {
        self.depth += 1;
        defer self.depth -= 1;
        // Nesting guard: every recursive path (parseGroup, fractions'
        // required args, \left..\right, environments, style switches,
        // substacks) re-enters parseRow, so this counts the whole mutual
        // recursion. Beyond `max_nesting` the input is pathological — a
        // few-KB source of nested braces is ~1 level per byte, and without
        // the cap it would overflow the C stack (uncatchable in Zig).
        if (self.depth > max_nesting) return self.fail(.nesting_too_deep, self.curSpan());
        const start_tok: u32 = @intCast(self.pos);
        var last_tok: u32 = start_tok;
        // Collect each child's node value, then copy the whole run
        // contiguously via createNode (duplication protocol), so the row's
        // children land in one block at [first_child, first_child+count).
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        // Pre-reserve from the remaining token count so dense rows do not
        // realloc while collecting children (capacity-only; the list grows
        // past this when atoms span fewer than 2 tokens).
        try children.ensureTotalCapacity(self.gpa, (self.tokens.len - self.pos) / 2 + 1);
        // Infix fraction state: set when \atop/\over/\choose splits the row.
        var frac_line: ?bool = null; // true = rule (\over), false = \atop/\choose
        var frac_choose = false;
        var frac_tok: u32 = undefined; // the delimiter command's token
        var frac_split: usize = 0; // children index where the denominator begins
        var num_end_tok: u32 = start_tok; // last numerator token (span anchor)
        while (self.peek()) |t| {
            switch (t.tag) {
                .r_group => {
                    if (mode == .top) return self.fail(.unexpected_r_group, spanOf(t));
                    break;
                },
                .sup, .sub => return self.fail(.unexpected_script, spanOf(t)),
                .command => {
                    const nm = self.src[t.start + 1 .. t.end];
                    if (mode == .delimited and std.mem.eql(u8, nm, "right")) break;
                    // \\ ends a \substack line (each line is parsed as its
                    // own row in .substack_line mode). Elsewhere \\ stays
                    // an UnknownCommand error, exactly as before.
                    if (mode == .substack_line and std.mem.eql(u8, nm, "\\")) break;
                    // `\end` and `\\` end an environment cell (the env body
                    // parser splits rows on `\\` and expects `\end` to
                    // close the environment; neither is consumed here).
                    if (mode == .env_cell and std.mem.eql(u8, nm, "\\")) break;
                    if (mode == .env_cell and std.mem.eql(u8, nm, "end")) break;
                    // `\hline` also ends an environment cell, so parseEnvBody
                    // sees it as a standalone token and turns it into a rule
                    // entry between rows. ONLY as the FIRST token of the
                    // row's first cell: TeX's \hline is \noalign, legal solely
                    // between rows, so `a \hline b` and `a & \hline b` must
                    // reach parseCommand and be rejected there.
                    if (mode == .env_cell and std.mem.eql(u8, nm, "hline") and
                        self.env_row_cells == 0 and self.pos == @as(usize, start_tok)) break;
                    // A style switch forces the style for the REST of the
                    // row (TeX rest-of-group semantics): consume the
                    // command, parse the remaining atoms as a sub-row, wrap
                    // that row in a `.mathstyle` node, and stop the loop —
                    // the rest is inside the wrapper. `\displaystyle a \over
                    // b` correctly wraps the whole infix fraction.
                    if (mathstyle_map.get(nm)) |ms| {
                        const cmd_tok: u32 = @intCast(self.pos);
                        _ = self.advance();
                        const rest = try self.parseRow(ast, mode);
                        const rn = ast.node(rest);
                        const num_tokens = (rn.first_token + rn.num_tokens) - cmd_tok;
                        const children_one = [_]atom.Node{rn};
                        const node = try self.createNode(
                            ast,
                            .mathstyle,

                            cmd_tok,

                            num_tokens,

                            &children_one,

                            @intFromEnum(ms),
                        );
                        const cn = ast.node(node);
                        try children.append(self.gpa, cn);
                        last_tok = cn.first_token + cn.num_tokens;
                        break; // the rest of the row is consumed
                    }
                    // \color{<spec>} is a DECLARATION: the color applies to
                    // the REST of this row and is restored when the row — or
                    // the group / cell / env body owning it — ends. Same
                    // shape as a style switch: consume the command and its
                    // color spec, parse the remaining atoms as a sub-row,
                    // wrap that row in a `.color` node, and stop the loop.
                    if (std.mem.eql(u8, nm, "color")) {
                        const col_cmd_tok: u32 = @intCast(self.pos);
                        _ = self.advance(); // consume \color
                        const col = try self.parseColorSpec();
                        // Past the command AND its spec: a trailing
                        // `\color{red}` with no rest leaves the sub-row
                        // empty, and the scope must still span the bytes it
                        // was written with.
                        const after_spec: u32 = @intCast(self.pos);
                        const rest = try self.parseRow(ast, mode);
                        const rn = ast.node(rest);
                        const col_tokens = @max(rn.first_token + rn.num_tokens, after_spec) -
                            col_cmd_tok;
                        const col_children = [_]atom.Node{rn};
                        const col_node = try self.createNode(
                            ast,
                            .color,
                            col_cmd_tok,
                            col_tokens,
                            &col_children,
                            atom.colorData(col),
                        );
                        const coln = ast.node(col_node);
                        try children.append(self.gpa, coln);
                        last_tok = coln.first_token + coln.num_tokens;
                        break; // the rest of the row is inside the scope
                    }
                    if (std.mem.eql(u8, nm, "atop") or
                        std.mem.eql(u8, nm, "over") or
                        std.mem.eql(u8, nm, "choose"))
                    {
                        if (frac_line != null) return self.fail(.missing_argument, spanOf(t));
                        frac_tok = @intCast(self.pos);
                        _ = self.advance(); // consume the delimiter command
                        frac_line = std.mem.eql(u8, nm, "over");
                        frac_choose = std.mem.eql(u8, nm, "choose");
                        frac_split = children.items.len;
                        num_end_tok = last_tok;
                        continue;
                    }
                    const child = try self.parseAtom(ast);
                    const cn = ast.node(child);
                    try children.append(self.gpa, cn);
                    last_tok = cn.first_token + cn.num_tokens;
                },
                else => {
                    // `&` ends an environment cell (column separator; the
                    // env body parser consumes it and starts the next
                    // cell). Outside an environment `&` is an ordinary
                    // char atom.
                    if (mode == .env_cell and t.tag == .char and self.src[t.start] == '&') break;
                    const child = try self.parseAtom(ast);
                    const cn = ast.node(child);
                    try children.append(self.gpa, cn);
                    last_tok = cn.first_token + cn.num_tokens;
                },
            }
        }
        const num_tokens = last_tok - start_tok;
        if (frac_line) |line| {
            const num = try self.createNode(
                ast,
                .row,
                start_tok,
                num_end_tok - start_tok,
                children.items[0..frac_split],
                0,
            );
            const den = try self.createNode(
                ast,
                .row,
                num_end_tok,
                last_tok - num_end_tok,
                children.items[frac_split..],
                0,
            );
            const nn = ast.node(num);
            const dn = ast.node(den);
            const frac_children = [_]atom.Node{ nn, dn };
            const frac = try self.createNode(ast, .fraction, start_tok, num_tokens, &frac_children, @intFromBool(line));
            const result: u32 = if (!frac_choose) frac else blk: {
                // \choose = \atop wrapped in parentheses
                const open = try ast.createLeaf(.char, frac_tok, 1, 0x28);
                const close = try ast.createLeaf(.char, frac_tok, 1, 0x29);
                const fn_ = ast.node(frac);
                const choose_children = [_]atom.Node{ ast.node(open), fn_, ast.node(close) };
                break :blk try self.createNode(ast, .row, start_tok, num_tokens, &choose_children, 0);
            };
            // Inside a group the whole content IS the fraction (`{a \atop b}`);
            // at top level the root stays a row per ztex's root convention.
            if (mode != .top) return result;
            const rn = ast.node(result);
            const wrap = [_]atom.Node{rn};
            return self.createNode(ast, .row, start_tok, num_tokens, &wrap, 0);
        }
        return self.createNode(ast, .row, start_tok, num_tokens, children.items, 0);
    }

    /// Parse one atom (base + optional scripts + trailing primes).
    ///
    /// `'` after an atom is TeX's prime (mathcode 0x8000): a superscript
    /// U+2032. Consecutive primes accumulate into one superscript: `''` →
    /// U+2033 (double prime), `'''`+ → U+2034. The wrap happens AFTER
    /// parseScripts so `x_1'` keeps its subscript and gains the prime
    /// superscript (TeX: a noad carries both), while `x'^2` still errors
    /// (DoubleScript — TeX's "Double superscript") because the `^2` is left
    /// as a row-leading script.
    ///
    /// A trailing prime on an ALREADY-SCRIPTED atom merges into the SAME
    fn parseAtom(self: *Parser, ast: *atom.Ast) Error!u32 {
        const base = try self.parseSingleAtom(ast);
        var result = try self.parseScripts(ast, base);
        var prime_count: usize = 0;
        const first_prime_tok: u32 = @intCast(self.pos);
        while (self.peek()) |t| {
            if (t.tag != .char) break;
            if (self.src[t.start] != '\'') break;
            prime_count += 1;
            _ = self.advance();
        }
        if (prime_count == 0) return result;
        const cp: u21 = if (prime_count == 1) 0x2032 else if (prime_count == 2) 0x2033 else 0x2034;
        const prime = try ast.createLeaf(.char, first_prime_tok, @intCast(prime_count), cp);
        const rn = ast.node(result);
        const pn = ast.node(prime);
        if (rn.tag == .script) {
            // Merge into the existing script: [base, sup?, sub?] — a prime
            // fills the sup slot. A sup already present is TeX's double
            // superscript.
            if ((rn.data & atom.ScriptBits.sup) != 0)
                return self.fail(.double_script, self.curSpan());
            const sb = ast.child(result, 0);
            const sub = ast.child(result, rn.num_children - 1);
            const children = [_]atom.Node{ ast.node(sb), pn, ast.node(sub) };
            const num_tokens = (first_prime_tok + @as(u32, @intCast(prime_count))) -
                ast.node(sb).first_token;
            result = try self.createNode(
                ast,
                .script,
                ast.node(sb).first_token,
                num_tokens,
                &children,
                atom.ScriptBits.sup | atom.ScriptBits.sub,
            );
        } else {
            const children = [_]atom.Node{ rn, pn };
            const num_tokens = (first_prime_tok + @as(u32, @intCast(prime_count))) - rn.first_token;
            result = try self.createNode(ast, .script, rn.first_token, num_tokens, &children, atom.ScriptBits.sup);
        }

        // After prime merging, any subsequent ^ or _ attaches to the script/base (e.g. x_0'^2 or f'(x))
        return self.parseScripts(ast, result);
    }

    /// Parse exactly one base atom (no scripts).
    fn parseSingleAtom(self: *Parser, ast: *atom.Ast) Error!u32 {
        const t = self.advance() orelse return self.fail(.missing_script, self.spanAt(self.pos));
        return switch (t.tag) {
            .char => self.makeChar(ast),
            .l_group => self.parseGroup(ast),
            .command => blk: {
                const name = self.src[t.start + 1 .. t.end];
                break :blk self.parseCommand(ast, name);
            },
            .r_group => self.fail(.unexpected_r_group, spanOf(t)),
            .sup, .sub => self.fail(.unexpected_script, spanOf(t)),
        };
    }

    /// Parse `{ ... }` as a transparent group atom.
    fn parseGroup(self: *Parser, ast: *atom.Ast) Error!u32 {
        const open_tok: u32 = @intCast(self.pos - 1);
        // \arraystretch is a LaTeX `\def`: its effect ends with the group
        // that made it. `{\arraystretch{1.4}\begin{array}…\end{array}}`
        // must leave a later environment's strut alone.
        const outer_stretch = self.stretch;
        defer self.stretch = outer_stretch;
        const inner = try self.parseRow(ast, .group);
        // Unclosed group: point at the group's opening brace.
        _ = self.advance() orelse
            return self.fail(.unclosed_group, self.spanAt(open_tok)); // consume }
        const inode = ast.node(inner);
        const num_tokens = (inode.first_token + inode.num_tokens) - open_tok + 1;
        const children = [_]atom.Node{ast.node(inner)};
        return self.createNode(ast, .group, open_tok, num_tokens, &children, 0);
    }

    /// Attach `^`/`_` scripts to `base`.
    ///
    /// `data` carries presence bits (ScriptBits.sup/sub) so layout does not
    /// misread a sub-only script (children are [base, sup?, sub?]).
    fn parseScripts(self: *Parser, ast: *atom.Ast, base: u32) Error!u32 {
        var sup: ?u32 = null;
        var sub: ?u32 = null;
        const base_node = ast.node(base);
        var last_tok = base_node.first_token + base_node.num_tokens;
        while (self.peek()) |t| {
            // \limits / \nolimits / \displaylimits between a base and its
            // scripts (`\int\limits_0^1`) set the limits-override bits on
            // the PRECEDING op/opname atom: \limits forces over/under in
            // display AND text styles, \nolimits forces beside scripts in
            // every style, \displaylimits restores the op's default. The
            // bits ride in the base node's `data` high bits (atom.LimitsBits)
            // and are copied with the base into any script node; the layout
            // consults them. On a non-op base TeX errors ("Limit controls
            // must follow a math operator"); ztex consumes it as a no-op.
            if (t.tag == .command) {
                const nm = self.src[t.start + 1 .. t.end];
                if (std.mem.eql(u8, nm, "limits") or
                    std.mem.eql(u8, nm, "nolimits") or
                    std.mem.eql(u8, nm, "displaylimits"))
                {
                    _ = self.advance();
                    const bt = ast.node(base).tag;
                    if (bt == .op or bt == .opname) {
                        const bits: u32 = if (std.mem.eql(u8, nm, "limits"))
                            atom.LimitsBits.force
                        else if (std.mem.eql(u8, nm, "nolimits"))
                            atom.LimitsBits.force_beside
                        else
                            0;
                        ast.nodes.items[base].data =
                            (ast.nodes.items[base].data & ~atom.LimitsBits.mask) | bits;
                    }
                    continue;
                }
            }
            if (t.tag == .sup) {
                if (sup != null) return self.fail(.double_script, spanOf(t));
                _ = self.advance();
                sup = try self.parseScriptArg(ast);
                last_tok = endOf(ast, sup.?);
            } else if (t.tag == .sub) {
                if (sub != null) return self.fail(.double_script, spanOf(t));
                _ = self.advance();
                sub = try self.parseScriptArg(ast);
                last_tok = endOf(ast, sub.?);
            } else break;
        }
        if (sup == null and sub == null) return base;
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        try children.append(self.gpa, ast.node(base));
        if (sup) |s| try children.append(self.gpa, ast.node(s));
        if (sub) |s| try children.append(self.gpa, ast.node(s));
        const num_tokens = last_tok - base_node.first_token;
        const data = (@as(u32, @intFromBool(sup != null)) * atom.ScriptBits.sup) |
            (@as(u32, @intFromBool(sub != null)) * atom.ScriptBits.sub);
        return self.createNode(ast, .script, base_node.first_token, num_tokens, children.items, data);
    }

    /// The content of one script: a single atom, or a braced group.
    fn parseScriptArg(self: *Parser, ast: *atom.Ast) Error!u32 {
        // Missing script: point at the position where the field was expected.
        const t = self.peek() orelse return self.fail(.missing_script, self.spanAt(self.pos));
        if (t.tag == .l_group) {
            _ = self.advance(); // consume `{` before parseGroup
            return self.parseGroup(ast);
        }
        // An UNBRACED script field may open with a style switch
        // (`x^{\displaystyle 2}`... without braces: `x^\displaystyle 2`):
        // the field is its own implicit group, so the switch forces the
        // style for the field's single atom (TeX: the field ends after one
        // atom — the rest of the outer row is unaffected).
        if (t.tag == .command) {
            if (mathstyle_map.get(self.src[t.start + 1 .. t.end])) |ms| {
                const cmd_tok: u32 = @intCast(self.pos);
                _ = self.advance();
                const rest = try self.parseSingleAtom(ast);
                const rn = ast.node(rest);
                const num_tokens = (rn.first_token + rn.num_tokens) - cmd_tok;
                const children = [_]atom.Node{ast.node(rest)};
                return self.createNode(ast, .mathstyle, cmd_tok, num_tokens, &children, @intFromEnum(ms));
            }
        }
        return self.parseSingleAtom(ast);
    }

    /// A required braced argument; returns the inner atom.
    fn parseRequiredArg(self: *Parser, ast: *atom.Ast) Error!u32 {
        const open_tok: u32 = @intCast(self.pos);
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        _ = self.advance();
        const inner = try self.parseRow(ast, .group);
        // Unclosed group: point at the argument's opening brace.
        _ = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
        return inner;
    }

    fn endOf(ast: *atom.Ast, node_idx: u32) u32 {
        const n = ast.node(node_idx);
        return n.first_token + n.num_tokens;
    }

    fn parseCommand(self: *Parser, ast: *atom.Ast, name: []const u8) Error!u32 {
        const cmd_tok: u32 = @intCast(self.pos - 1);
        const cmd = cmd_map.get(name) orelse {
            // Single-glyph symbols (\alpha, \leq, \infty, ...): a char leaf
            // whose data carries the codepoint, exactly like \cdot.
            if (symbol_map.get(name)) |cp| return self.symbol(ast, cmd_tok, cp);
            return self.fail(.unknown_command, self.spanAt(cmd_tok));
        };
        return switch (cmd) {
            .space_comma => self.space(ast, cmd_tok, 0.166),
            .space_semicolon => self.space(ast, cmd_tok, 0.277),
            .space_bang => self.space(ast, cmd_tok, -0.166),
            .quad => self.space(ast, cmd_tok, 1.0),
            .qquad => self.space(ast, cmd_tok, 2.0),
            .frac => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, true, null, false);
            },
            .frac_display => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, true, .display, false);
            },
            .frac_text => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, true, .text, false);
            },
            .cfrac => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, true, .display, true);
            },
            .atop => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.fraction(ast, cmd_tok, num, den, false, null, false);
            },
            .binom => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.binom(ast, cmd_tok, num, den);
            },
            .dbinom => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.binomVariant(ast, cmd_tok, .display, num, den);
            },
            .tbinom => blk: {
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.binomVariant(ast, cmd_tok, .text, num, den);
            },
            .genfrac => blk: {
                const ld = try self.parseGenfracDelim();
                const rd = try self.parseGenfracDelim();
                const thick = try self.parseGenfracThickness();
                const gstyle = try self.parseGenfracStyle();
                const num = try self.parseRequiredArg(ast);
                const den = try self.parseRequiredArg(ast);
                break :blk self.genfrac(ast, cmd_tok, ld, rd, thick, gstyle, num, den);
            },
            .text => self.textFace(ast, .roman),
            .operatorname => self.operatorname(ast, cmd_tok),
            .style_roman => self.style(ast, cmd_tok, .roman),
            .style_bold => self.style(ast, cmd_tok, .bold),
            .style_bb => self.style(ast, cmd_tok, .bb),
            .style_cal => self.style(ast, cmd_tok, .cal),
            .style_frak => self.style(ast, cmd_tok, .frak),
            .style_sans => self.style(ast, cmd_tok, .sans),
            .style_mono => self.style(ast, cmd_tok, .mono),
            .cdot => self.cdot(ast, cmd_tok),
            .op_sum => self.op(ast, cmd_tok, .sum),
            .op_int => self.op(ast, cmd_tok, .int),
            .op_prod => self.op(ast, cmd_tok, .prod),
            .op_coprod => self.op(ast, cmd_tok, .coprod),
            .op_bigcup => self.op(ast, cmd_tok, .bigcup),
            .op_bigcap => self.op(ast, cmd_tok, .bigcap),
            .op_bigsqcup => self.op(ast, cmd_tok, .bigsqcup),
            .op_oint => self.op(ast, cmd_tok, .oint),
            .op_oiint => self.op(ast, cmd_tok, .oiint),
            .op_oiiint => self.op(ast, cmd_tok, .oiiint),
            .op_ointctrclockwise => self.op(ast, cmd_tok, .ointctrclockwise),
            .op_bigodot => self.op(ast, cmd_tok, .bigodot),
            .op_bigoplus => self.op(ast, cmd_tok, .bigoplus),
            .op_bigotimes => self.op(ast, cmd_tok, .bigotimes),
            .op_biguplus => self.op(ast, cmd_tok, .biguplus),
            .op_bigsqcap => self.op(ast, cmd_tok, .bigsqcap),
            .op_bigwedge => self.op(ast, cmd_tok, .bigwedge),
            .op_bigvee => self.op(ast, cmd_tok, .bigvee),
            .op_bigstar => self.op(ast, cmd_tok, .bigstar),
            .op_bigint => self.op(ast, cmd_tok, .bigint),
            .op_bigiint => self.op(ast, cmd_tok, .bigiint),
            .op_bigiiint => self.op(ast, cmd_tok, .bigiiint),
            .mathop => self.mathop(ast, cmd_tok),
            .mathord => self.mathClass(ast, cmd_tok, .ord),
            .mathrel => self.mathClass(ast, cmd_tok, .rel),
            .mathbin => self.mathClass(ast, cmd_tok, .bin),
            .mathopen => self.mathClass(ast, cmd_tok, .open),
            .mathclose => self.mathClass(ast, cmd_tok, .close),
            .mathpunct => self.mathClass(ast, cmd_tok, .punct),
            .mathinner => self.mathClass(ast, cmd_tok, .inner),
            .colon => blk: {
                // The glyph is the plain colon; only the class differs from a
                // bare `:`.
                const leaf = try ast.createLeaf(.char, cmd_tok, 1, 0x3A);
                break :blk self.classRow(ast, cmd_tok, .punct, leaf);
            },
            .opname => self.opname(ast, cmd_tok, name),
            .left => self.parseLeftRight(ast, cmd_tok),
            .right => self.fail(.unexpected_r_group, self.spanAt(cmd_tok)),
            .big => self.fixedDelim(ast, cmd_tok, 1),
            .Big => self.fixedDelim(ast, cmd_tok, 2),
            .bigg => self.fixedDelim(ast, cmd_tok, 3),
            .Bigg => self.fixedDelim(ast, cmd_tok, 4),
            .middle => self.middle(ast, cmd_tok),
            .limits => self.space(ast, cmd_tok, 0),
            .nolimits => self.space(ast, cmd_tok, 0),
            .displaylimits => self.space(ast, cmd_tok, 0),
            .sqrt => self.sqrt(ast, cmd_tok),
            .dot => self.accent(ast, cmd_tok, 0x0307), // combining dot above
            .hat => self.accent(ast, cmd_tok, 0x0302), // combining circumflex
            .bar => self.accent(ast, cmd_tok, 0x0304), // combining macron
            .vec => self.accent(ast, cmd_tok, 0x20D7), // combining right arrow above
            .ddot => self.accent(ast, cmd_tok, 0x0308), // combining diaeresis
            .tilde => self.accent(ast, cmd_tok, 0x0303), // combining tilde
            .widehat => self.wideAccent(ast, cmd_tok, wide_hat_row_data, 0x0302),
            .widetilde => self.wideAccent(ast, cmd_tok, wide_tilde_row_data, 0x0303),
            .overline => self.overunder(ast, cmd_tok, false),
            .underline => self.overunder(ast, cmd_tok, true),
            .mathchoice => self.mathchoice(ast, cmd_tok),
            .not => self.not(ast, cmd_tok),
            .substack => self.substack(ast, cmd_tok),
            .pmod => self.pmod(ast, cmd_tok, true),
            .pod => self.pmod(ast, cmd_tok, false),
            .bmod => self.bmod(ast, cmd_tok),
            .mod => self.mod(ast, cmd_tok),
            .overset => self.limitScript(ast, cmd_tok, .over, false),
            .underset => self.limitScript(ast, cmd_tok, .under, false),
            .stackrel => self.limitScript(ast, cmd_tok, .over, true),
            .phantom => self.phantom(ast, cmd_tok, keep_width | keep_vertical, false),
            .hphantom => self.phantom(ast, cmd_tok, keep_width, false),
            .vphantom => self.phantom(ast, cmd_tok, keep_vertical, false),
            .smash => self.smash(ast, cmd_tok),
            .underbrace => self.brace(ast, cmd_tok, true),
            .overbrace => self.brace(ast, cmd_tok, false),
            .hspace => self.kern(ast, cmd_tok, true),
            .kern, .mkern => self.kern(ast, cmd_tok, false),
            .space_colon => self.kernRow(ast, cmd_tok, 4.0, .mu),
            .space_control => self.space(ast, cmd_tok, 1.0 / 3.0),
            .arraystretch => self.arraystretch(ast, cmd_tok),
            .tag => self.tag(ast, cmd_tok),
            .boxed => self.boxed(ast, cmd_tok),
            // \color is a declaration: parseRow intercepts it in every row
            // mode. This arm only fires where a bare atom is still expected
            // (an unbraced script field), where the scope is that field.
            .color => blk: {
                const col = try self.parseColorSpec();
                const field = try self.parseScriptArg(ast);
                const fnode = ast.node(field);
                const tokens = (fnode.first_token + fnode.num_tokens) - cmd_tok;
                break :blk self.createNode(
                    ast,
                    .color,
                    cmd_tok,
                    tokens,
                    &[_]atom.Node{fnode},
                    atom.colorData(col),
                );
            },
            .textcolor => self.textcolor(ast, cmd_tok),
            .hline => self.fail(.misplaced_hline, self.spanAt(cmd_tok)),
            .textit => self.textFace(ast, .text_italic),
            .textbf => self.textFace(ast, .bold),
            .begin => self.parseBegin(ast, cmd_tok),
        };
    }

    fn makeChar(self: *Parser, ast: *atom.Ast) Error!u32 {
        const tok: u32 = @intCast(self.pos - 1);
        return ast.createLeaf(.char, tok, 1, 0);
    }
    /// \cdot → a char atom at U+22C5. The source span holds "\cdot", so the
    /// codepoint override rides in the node's `data` (nonzero = explicit cp);
    /// layout reads it for the glyph, the role, and marks the box synthetic.
    fn cdot(_: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        return ast.createLeaf(.char, cmd_tok, 1, 0x22C5);
    }
    /// A single-glyph command (\alpha, \leq, \infty, \to, ...): a char leaf
    /// with the codepoint override in `data`, like \cdot.
    fn symbol(_: *Parser, ast: *atom.Ast, cmd_tok: u32, cp: u21) Error!u32 {
        return ast.createLeaf(.char, cmd_tok, 1, cp);
    }
    /// An operator name (\sin, \lim, \log, ...): the name's letters become
    /// char leaves (each carrying its ASCII codepoint in `data`) grouped in a
    /// row wrapped by an `.opname` node (roman word). Scripts then attach to
    /// the opname node (`\sin^2 x`, `\lim_{x \to 0}`), and layout routes the
    /// LIMIT-TAKING words (\lim \max \min ... — see `limitOpName`) through the
    /// big-op limits path in display style, so `\lim_{x \to 0}` puts "x→0"
    /// UNDER the word, centered, exactly like `\sum` limits. All leaves share
    /// the command token's span, so provenance stays exact and the synthetic
    /// flag keeps flatten from aliasing the "\sin" source text.
    fn opname(self: *Parser, ast: *atom.Ast, cmd_tok: u32, name: []const u8) Error!u32 {
        var letters: std.ArrayList(atom.Node) = .empty;
        defer letters.deinit(self.gpa);
        for (name) |b| {
            const c = try ast.createLeaf(.char, cmd_tok, 1, b);
            try letters.append(self.gpa, ast.node(c));
        }
        const word = try self.createNode(ast, .row, cmd_tok, 1, letters.items, 0);
        const wn = ast.node(word);
        const child = [_]atom.Node{wn};
        const limits = @intFromBool(limitOpName(name));
        return self.createNode(ast, .opname, cmd_tok, 1, &child, limits);
    }
    /// Whether an operator name takes display-style limits in TeX. TeX's
    /// fontmath.ltx defines only these as \mathop with limits by default
    /// (display style: scripts over/under, centered); the trig/log words
    /// (\sin \cos \tan \log \ln \exp ...) are \mathop\nolimits — their
    /// scripts stay beside as regular sub/superscripts (\sin^2 x), and
    /// \mod/\bmod are not ops at all.
    fn limitOpName(name: []const u8) bool {
        const limit_names = std.StaticStringMap(void).initComptime(&[_]struct { []const u8, void }{
            .{ "lim", {} },
            .{ "limsup", {} },
            .{ "liminf", {} },
            .{ "max", {} },
            .{ "min", {} },
            .{ "sup", {} },
            .{ "inf", {} },
            .{ "det", {} },
            .{ "gcd", {} },
            .{ "Pr", {} },
            .{ "arg", {} },
            .{ "ker", {} },
            .{ "dim", {} },
            .{ "hom", {} },
            .{ "deg", {} },
        });
        return limit_names.has(name);
    }
    /// \operatorname{...} / \operatorname*{...}: amsmath's declarable
    /// operator name — a \mathop whose content is the braced group set in
    /// upright roman (amsopn.sty: \qopname → \mathop{\operator@font #3}
    /// followed by \nolimits@ for the unstarred form, \displaylimits for
    /// the starred). The result is an `.opname` atom whose child row is the
    /// parsed braced content (laid out roman by the layout, OP role — thin
    /// glue to ord/op/inner, none to open — plus the limits machinery):
    /// `data` 0 = nolimits (scripts attach beside the word, like \sin^2),
    /// `data` 1 = displaylimits (over/under limits centered on the word in
    /// display style, like \lim; beside in text style). The `*` is a LaTeX
    /// macro suffix — the lexer emits it as a separate `*` char token
    /// (whitespace between name and `*` is skipped, so `\operatorname *` is
    /// the starred form exactly like TeX's \@ifstar); it is consumed here
    /// and never rendered. The content parses as a normal math row, so `\,
    /// \mathrm{...}` etc. work inside and literal whitespace follows math
    /// mode (ignored — measured: XeTeX and KaTeX both drop it; amsopn sets
    /// mathcodes so only `'` `*` `.` `/` `:` become ordinary chars).
    fn operatorname(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        var limits: u32 = 0;
        if (self.peek()) |t| {
            if (t.tag == .char and self.src[t.start] == '*') {
                limits = 1;
                _ = self.advance(); // consume the star suffix
            }
        }
        const inner = try self.parseRequiredArg(ast);
        const inode = ast.node(inner);
        // The span covers the command (and the `*`, if any) through the end
        // of the braced content — provenance stays exact.
        const num_tokens = (inode.first_token + inode.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ast.node(inner)};
        return self.createNode(ast, .opname, cmd_tok, num_tokens, &children, limits);
    }

    /// \mathop{<field>}: TeX's generic \mathop — the math field in upright
    /// roman with the OP class and NO limits. The `.opname` atom is exactly
    /// that shape (a child laid out roman, `leftRole`/`rightRole` = op), and
    /// `data` 0 selects beside scripts; unlike `\operatorname` the content
    /// may be a bare atom (`\mathop\lim`), since TeX's \mathXXX takes a math
    /// FIELD, not a braced argument.
    fn mathop(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const field = try self.parseScriptArg(ast);
        const fnode = ast.node(field);
        const num_tokens = (fnode.first_token + fnode.num_tokens) - cmd_tok;
        const children = [_]atom.Node{fnode};
        return self.createNode(ast, .opname, cmd_tok, num_tokens, &children, 0);
    }

    /// \mathord \mathrel \mathbin \mathopen \mathclose \mathpunct
    /// \mathinner: the math field wrapped in a forced class.
    fn mathClass(self: *Parser, ast: *atom.Ast, cmd_tok: u32, cls: atom.MathClass) Error!u32 {
        const field = try self.parseScriptArg(ast);
        return self.classRow(ast, cmd_tok, cls, field);
    }

    /// Wrap an already-parsed atom in a class-override row: a `.row` of one
    /// child whose `data` packs the marker + class (atom.classRowData). The
    /// row lays out as the ordinary single-child row — the same box the
    /// field produces alone — and layout classifies it from `data` on BOTH
    /// sides, so the wrapper is invisible to the geometry and visible to
    /// the glue.
    fn classRow(
        self: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        cls: atom.MathClass,
        field: u32,
    ) Error!u32 {
        const fnode = ast.node(field);
        const num_tokens = (fnode.first_token + fnode.num_tokens) - cmd_tok;
        const children = [_]atom.Node{fnode};
        return self.createNode(ast, .row, cmd_tok, num_tokens, &children, atom.classRowData(cls));
    }

    /// \dbinom{num}{den} / \tbinom{num}{den} = \genfrac{(}{)}{0pt}{0|1}
    /// {num}{den} (amsmath): \binom with the style argument FORCED, which
    /// is the only difference: the parens take amsc's fixed fraction-
    /// delimiter size for the FORCED style (display → the v6 paren, text →
    /// the base paren) and the parts render at that style. The synthetic
    /// delimiter leaves borrow the command token, like \binom's.
    fn binomVariant(
        self: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        forced: atom.MathStyle,
        num: u32,
        den: u32,
    ) Error!u32 {
        const frac = try self.fraction(ast, cmd_tok, num, den, false, forced, false);
        ast.nodes.items[frac].data |= atom.FractionBits.fixed_delim;
        const fnode = ast.node(frac);
        const open = try ast.createLeaf(.char, cmd_tok, 1, 0x28);
        const close = try ast.createLeaf(.char, cmd_tok, 1, 0x29);
        const children = [_]atom.Node{ ast.node(open), fnode, ast.node(close) };
        const num_tokens = (ast.node(den).first_token + ast.node(den).num_tokens) - cmd_tok;
        return self.createNode(ast, .left, cmd_tok, num_tokens, &children, 0);
    }

    fn space(_: *Parser, ast: *atom.Ast, cmd_tok: u32, em: f32) Error!u32 {
        return ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(em));
    }

    fn op(_: *Parser, ast: *atom.Ast, cmd_tok: u32, which: atom.BigOp) Error!u32 {
        return ast.createLeaf(.op, cmd_tok, 1, @intFromEnum(which));
    }

    fn style(self: *Parser, ast: *atom.Ast, cmd_tok: u32, s: atom.CharStyle) Error!u32 {
        const inner = try self.parseRequiredArg(ast);
        const inode = ast.node(inner);
        const num_tokens = (inode.first_token + inode.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ast.node(inner)};
        return self.createNode(ast, .styled, cmd_tok, num_tokens, &children, @intFromEnum(s));
    }

    /// `\frac` (line, no force), `\dfrac`/`\tfrac` (line + forced style), or
    /// `\cfrac` (line + forced display + parts-at-display). The `data` packs
    /// line bit + forced-style code + parts flag via atom.fracData; a plain
    /// `\frac` keeps data 0/1 (byte-identical to the pre-feature encoding).
    fn fraction(
        self: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        num: u32,
        den: u32,
        line: bool,
        forced: ?atom.MathStyle,
        parts_display: bool,
    ) Error!u32 {
        const nn = ast.node(num);
        const dn = ast.node(den);
        const num_tokens = (dn.first_token + dn.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ nn, dn };
        return self.createNode(
            ast,
            .fraction,
            cmd_tok,
            num_tokens,
            &children,
            atom.fracData(line, forced, parts_display),
        );
    }

    /// \binom{num}{den} = \genfrac{(}{)}{0pt}{}{num}{den}: a ruleless
    /// fraction (\atop gaps, no rule) inside \left( \right) parens that the
    /// variant ladder auto-sizes to cover the fraction — a `.left` node of
    /// [open '(', fraction, close ')'], exactly the parseLeftRight shape
    /// (data 0), so layout stretches the parens and the whole construct sits
    /// on the fraction's baseline (TeX: \binom is a delimiter-wrapped atop,
    /// NOT centered on the axis like \frac). The style is NOT forced: both
    /// references leave \binom's style empty (XeTeX amsmath \genfrac with an
    /// empty style arg relaxes to the current style; KaTeX \binom size
    /// "auto") — at 36pt display the parts render at display size, measured
    /// against the XeTeX reference. The paren leaves are synthetic (the
    /// source holds \binom, not parentheses), like \choose's.
    fn binom(self: *Parser, ast: *atom.Ast, cmd_tok: u32, num: u32, den: u32) Error!u32 {
        const frac = try self.fraction(ast, cmd_tok, num, den, false, null, false);
        // Mark the fraction as amsmath-delimited (fixed fraction-delimiter
        // paren size) so layout sizes the `(` `)` to amsc's fixed rule, not
        // TeX's content-`\left` delta — amsc `\binom{1}{2}` == `\binom{n}{k}`.
        ast.nodes.items[frac].data |= atom.FractionBits.fixed_delim;
        const fn_ = ast.node(frac);
        const open = try ast.createLeaf(.char, cmd_tok, 1, 0x28);
        const close = try ast.createLeaf(.char, cmd_tok, 1, 0x29);
        const children = [_]atom.Node{ ast.node(open), fn_, ast.node(close) };
        const num_tokens = (ast.node(den).first_token + ast.node(den).num_tokens) - cmd_tok;
        return self.createNode(ast, .left, cmd_tok, num_tokens, &children, 0);
    }

    /// \genfrac{left}{right}{thick}{style}{num}{den}: a fraction with
    /// explicit delimiters (empty groups contribute none — `\genfrac{}{}
    /// {0pt}{}{a}{b}` == \atop), an explicit rule thickness (0pt → no rule,
    /// \atop-style; > 0pt → a rule of EXACTLY that thickness, a TeX
    /// dimension that does NOT scale with the font size), and a forced style
    /// (the 4th arg). With at least one delimiter the result is a `.left`
    /// node like \binom/\left..\right, so the delimiters auto-size to the
    /// fraction and the construct sits on the fraction's baseline; with no
    /// delimiters it is a bare `.fraction`.
    ///
    /// Style mapping follows BOTH references (XeTeX amsmath \@mathstyle and
    /// KaTeX stylArray — verified empirically at 36pt): "" → current style
    /// (no force), "0" → \displaystyle, "1" → \textstyle, "2" →
    /// \scriptstyle, anything else → \scriptscriptstyle. (The spec draft's
    /// "(0=text, 1=display)" is inverted vs amsmath/KaTeX; the references
    /// win — \genfrac{(}{)}{0.8pt}{1}{x}{y} renders script-size parts at
    /// display, measured in XeTeX.)
    fn genfrac(
        self: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        ld: ?Delimiter,
        rd: ?Delimiter,
        thick_pt: f32,
        forced: ?atom.MathStyle,
        num: u32,
        den: u32,
    ) Error!u32 {
        const line = thick_pt > 0;
        var data = atom.fracData(line, forced, false);
        if (line) data |= atom.fracThicknessBits(thick_pt);
        // amsmath `\genfrac` with delimiters (\binom-like): its `\left` parens are
        // sized by amsc's FIXED fraction-delimiter rule, not content-`\left`
        // (`\binom{1}{2}` == `\binom{n}{k}` (verified)).
        if (ld != null or rd != null) data |= atom.FractionBits.fixed_delim;
        const nn = ast.node(num);
        const dn = ast.node(den);
        const num_tokens = (dn.first_token + dn.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ nn, dn };
        const frac = try self.createNode(ast, .fraction, cmd_tok, num_tokens, &children, data);
        if (ld == null and rd == null) return frac;
        const fn_ = ast.node(frac);
        var fence_children: std.ArrayList(atom.Node) = .empty;
        defer fence_children.deinit(self.gpa);
        if (ld) |d| {
            const c = try ast.createLeaf(.char, d.tok, 1, d.cp);
            try fence_children.append(self.gpa, ast.node(c));
        }
        try fence_children.append(self.gpa, fn_);
        if (rd) |d| {
            const c = try ast.createLeaf(.char, d.tok, 1, d.cp);
            try fence_children.append(self.gpa, ast.node(c));
        }
        return self.createNode(ast, .left, cmd_tok, num_tokens, fence_children.items, 0);
    }

    /// One \genfrac delimiter argument: a braced group holding either
    /// nothing, one delimiter char, or one delimiter command (`\lbrace`).
    /// Reuses the \left/\right delimiter set (parseDelimiter); an empty
    /// group yields null (no delimiter). `\genfrac{...}{.}...` — a `.` —
    /// also yields null, like `\left.`.
    fn parseGenfracDelim(self: *Parser) Error!?Delimiter {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        _ = self.advance(); // consume {
        const n = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (n.tag == .r_group) {
            _ = self.advance(); // consume }
            return null;
        }
        const d = try self.parseDelimiter();
        const c = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (c.tag != .r_group) return self.fail(.missing_argument, spanOf(c));
        _ = self.advance(); // consume }
        return d;
    }

    /// A \genfrac rule-thickness argument: a braced TeX dimension like
    /// `0pt`, `1pt`, `0.8pt` (or empty → 0). The lexer splits it into char
    /// tokens, so the bytes are re-read from the token spans. Only `pt`
    /// units are accepted (a bare number means pt); negative thicknesses
    /// clamp to 0 (no rule).
    fn parseGenfracThickness(self: *Parser) Error!f32 {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        const open_tok: u32 = @intCast(self.pos);
        _ = self.advance(); // consume {
        const start: u32 = @intCast(self.pos);
        while (self.peek()) |c| {
            if (c.tag == .r_group) break;
            _ = self.advance();
        }
        const c = self.peek() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
        if (c.tag != .r_group) return self.fail(.unclosed_group, self.spanAt(open_tok));
        const end: u32 = @intCast(self.pos);
        _ = self.advance(); // consume }
        if (end <= start) return 0;
        const first = self.tokens[start].start;
        const last = self.tokens[end - 1].end;
        var txt = self.src[first..last];
        if (txt.len >= 2 and std.mem.eql(u8, txt[txt.len - 2 ..], "pt")) txt = txt[0 .. txt.len - 2];
        if (txt.len == 0) return 0;
        // The span covers the unparseable dimension text.
        const bad: atom.Span = .{ .start = first, .end = last };
        const v = std.fmt.parseFloat(f32, txt) catch return self.fail(.missing_argument, bad);
        return @max(v, 0);
    }

    /// A \genfrac style argument: a braced digit (or empty → no force).
    /// Mapping (see genfrac): 0 → display, 1 → text, 2 → script, anything
    /// else → scriptscript (amsmath's \ifcase fall-through).
    fn parseGenfracStyle(self: *Parser) Error!?atom.MathStyle {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        _ = self.advance(); // consume {
        const n = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (n.tag == .r_group) {
            _ = self.advance(); // consume }
            return null;
        }
        if (n.tag != .char) return self.fail(.missing_argument, spanOf(n));
        const ch = self.src[n.start];
        _ = self.advance();
        const c = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (c.tag != .r_group) return self.fail(.missing_argument, spanOf(c));
        _ = self.advance(); // consume }
        return switch (ch) {
            '0' => .display,
            '1' => .text,
            '2' => .script,
            else => .script_script,
        };
    }

    /// `\mathchoice{D}{T}{S}{SS}` — TeX's four-style choice primitive: four
    /// required braced arguments (the display/text/script/scriptscript
    /// branches). The result is a `.mathchoice` atom whose children are the
    /// four branches in order; layout picks the branch matching the current
    /// math style and lays it out with the branch's own style forced. The
    /// span covers the command through the last branch's closing brace.
    fn mathchoice(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const d = try self.parseRequiredArg(ast);
        const t = try self.parseRequiredArg(ast);
        const s = try self.parseRequiredArg(ast);
        const ss = try self.parseRequiredArg(ast);
        const dn = ast.node(d);
        const tn = ast.node(t);
        const sn = ast.node(s);
        const ssn = ast.node(ss);
        const num_tokens = (ssn.first_token + ssn.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ dn, tn, sn, ssn };
        return self.createNode(ast, .mathchoice, cmd_tok, num_tokens, &children, 0);
    }

    /// \boxed{<field>}: a frame around ONE math field — amsmath
    /// \newcommand\boxed[1]{\fbox{\m@th$\displaystyle #1$}}. The result is a
    /// `.boxed` atom of exactly one child; layout draws the four rules
    /// outside that child (fboxsep 3pt, fboxrule 0.4pt). The field is a math
    /// FIELD like \overline's, so `\boxed x` frames the bare atom and
    /// `\boxed{xy}` the group; the node's span covers the command through
    /// the end of the field. The DISPLAY style is layout's concern: a
    /// \boxed inside a script keeps the script's style, exactly like every
    /// other construct (only \dfrac forces a style).
    fn boxed(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const field = try self.parseScriptArg(ast);
        const fnode = ast.node(field);
        const num_tokens = (fnode.first_token + fnode.num_tokens) - cmd_tok;
        const children = [_]atom.Node{fnode};
        return self.createNode(ast, .boxed, cmd_tok, num_tokens, &children, 0);
    }

    /// \textcolor{<spec>}{<text>}: the foreground color of the braced
    /// argument ONLY. xcolor's \textcolor is `\leavevmode{\color…#2}`, so
    /// the braces make the content an ORD GROUP — that is why the result is
    /// a `.textcolor` atom and NOT a `.color` one. The two differ in the math
    /// CLASS they report, which is measured, not assumed: at 20pt
    /// `a\textcolor{red}{=}b` is 35.0pt wide, exactly `a\mathord{=}b`,
    /// while `a\color{red}=b` keeps the 46.11pt of `a=b`. A colored
    /// relation therefore loses its relation glue under \textcolor and keeps
    /// it under \color. Both atoms carry `data` = 0xRRGGBBAA and exactly one
    /// child, and both end their scope where the node ends.
    ///
    /// The second argument is a required braced group (not a math field):
    /// LaTeX's \textcolor takes `#1` and `#2` as mandatory arguments, and
    /// `\textcolor{red}x` is a LaTeX error, not the color of the rest of
    /// the row.
    fn textcolor(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const col = try self.parseColorSpec();
        const arg = try self.parseRequiredArg(ast);
        const an = ast.node(arg);
        // parseRequiredArg consumed the closing `}`, which the argument's
        // own token range does not cover — the same +1 anchor \tag uses.
        const num_tokens = (an.first_token + an.num_tokens + 1) - cmd_tok;
        const children = [_]atom.Node{an};
        const data = atom.colorData(col);
        return self.createNode(ast, .textcolor, cmd_tok, num_tokens, &children, data);
    }

    /// The `<spec>` of \color / \textcolor: a braced group whose BYTES are
    /// the color, read straight from the token spans (the lexer has already
    /// split `red` or `#ff8000` into char tokens, so this never goes
    /// through the atom parser — `#` and the hex digits are not math).
    ///
    /// The eleven names and the `#RRGGBB[AA]` forms come from
    /// atom.parseColorChecked, so a typo is reported exactly as the CLI's
    /// `-b` typo is. `none` / `transparent` mean TRANSPARENT INK there, not
    /// "no scope": `\color{transparent}x` paints nothing, which is what
    /// xcolor does, so the scope still exists and the {0,0,0,0} color is
    /// recorded rather than inherited from the enclosing scope.
    fn parseColorSpec(self: *Parser) Error!atom.Color {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        const open_tok: u32 = @intCast(self.pos);
        _ = self.advance(); // consume {
        const start_tok: u32 = @intCast(self.pos);
        while (self.peek()) |c| {
            if (c.tag == .r_group) break;
            _ = self.advance();
        }
        const end_tok: u32 = @intCast(self.pos);
        const close = self.peek() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
        if (close.tag != .r_group) return self.fail(.unclosed_group, self.spanAt(open_tok));
        _ = self.advance(); // consume }
        if (end_tok == start_tok) return self.fail(.missing_argument, self.spanAt(open_tok));
        const st = self.tokens[start_tok];
        const et = self.tokens[end_tok - 1];
        const name = self.src[st.start..et.end];
        // The span covers the offending color spec, braces excluded, so the
        // caret points at `blak` and not at the whole construct. An
        // undefined NAME reuses .unknown_command: parse_err has no
        // "undefined identifier" kind, and this is exactly the failure of a
        // name that is not in the table.
        const bad: atom.Span = .{ .start = st.start, .end = et.end };
        const parsed = atom.parseColorChecked(name) catch {
            return self.fail(.unknown_command, bad);
        };
        return parsed orelse atom.Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }

    /// \text{…} / \textit{…} / \textbf{…}: ONE raw byte run in one text face.
    /// The result is a `.text` leaf whose `data` carries the CharStyle — the
    /// layout text renderer re-reads the bytes from the node's span, so the run
    /// keeps its source text verbatim (no Unicode math remapping: these are
    /// TEXT faces, LM Roman Italic/Bold, not the MATH italic face).
    ///
    /// The leaf always spans the OUTER group, braces included, whatever the
    /// argument holds: a nested \textit / \textbf / \text inside it is part of
    /// that run's raw bytes and layout opens a face scope for each one, so the
    /// whole-argument nest `\textit{\textbf{ab}}` and the partial nest
    /// `\textbf{a\textit{b}c}` are the same single leaf and differ only in the
    /// scopes layout finds inside it. Splitting the argument into several
    /// leaves would need a per-brace AST the superflat tree has no room for,
    /// and would drop source bytes the text renderer reads.
    ///
    /// Nesting COMBINES rather than overwrites (atom.combineTextStyles, applied
    /// by that scope): \textit{\textbf{ab}} and \textbf{\textit{ab}} are both
    /// BOLD ITALIC, because the inner command's face adds its modifiers to the
    /// outer one's instead of replacing them.
    fn textFace(self: *Parser, ast: *atom.Ast, face: atom.CharStyle) Error!u32 {
        const open = self.advance() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (open.tag != .l_group) return self.fail(.missing_argument, spanOf(open));
        const open_tok: u32 = @intCast(self.pos - 1);
        // The whole argument, consumed ONCE: the balanced scan leaves self.pos
        // just past the closing `}`, so whatever follows the run is the next
        // atom of the enclosing row.
        const close_tok = try self.scanBracedGroup(open_tok);
        return ast.createLeaf(.text, open_tok, close_tok - open_tok + 1, @intFromEnum(face));
    }

    /// The token index of the `}` closing the group that opens at
    /// `open_tok`, consuming every token through it. A missing `}` is
    /// error.UnclosedGroup at the opening brace — the same site every other
    /// braced argument reports. Nesting past `atom.max_text_nesting` is
    /// error.NestingTooDeep, at that same opening brace: a raw text run deeper
    /// than the bound has no layout-side face-scope stack to hold it.
    fn scanBracedGroup(self: *Parser, open_tok: u32) Error!u32 {
        var depth: u32 = 1;
        while (true) {
            const t = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
            switch (t.tag) {
                .l_group => {
                    depth += 1;
                    if (depth > atom.max_text_nesting) {
                        return self.fail(.nesting_too_deep, self.spanAt(open_tok));
                    }
                },
                .r_group => {
                    depth -= 1;
                    if (depth == 0) return @intCast(self.pos - 1);
                },
                else => {},
            }
        }
    }

    /// \sqrt[degree]{radicand} → a row of the surd (U+221A, with the optional
    /// degree as a superscript) followed by the radicand, marked with
    /// `sqrt_row_data` in the row's `data` so layout routes it through
    /// layoutSqrt (stretchy radical + vinculum) instead of the ordinary row
    /// path (which would draw the surd as a plain base-size glyph).
    fn sqrt(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        var degree: ?u32 = null;
        if (self.peek()) |t| {
            if (t.tag == .char and self.src[t.start] == '[') {
                _ = self.advance(); // consume `[`
                degree = try self.parseUntilRBracket(ast);
                const close = self.advance() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
                if (close.tag != .char or self.src[close.start] != ']')
                    return self.fail(.missing_argument, spanOf(close));
            }
        }
        const radicand = try self.parseRequiredArg(ast);
        const surd = try ast.createLeaf(.char, cmd_tok, 1, 0x221A);
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        if (degree) |d| {
            const dn = ast.node(d);
            const sn = ast.node(surd);
            const deg_span = (dn.first_token + dn.num_tokens) - sn.first_token;
            const sc = try self.createNode(ast, .script, sn.first_token, deg_span, &.{ sn, dn }, atom.ScriptBits.sup);
            try children.append(self.gpa, ast.node(sc));
        } else {
            try children.append(self.gpa, ast.node(surd));
        }
        const rn = ast.node(radicand);
        try children.append(self.gpa, rn);
        const num_tokens = (rn.first_token + rn.num_tokens) - cmd_tok;
        // data = sqrt_row_data marks this row as a \sqrt construct; layout
        // routes it through layoutSqrt (stretchy radical + vinculum).
        return self.createNode(ast, .row, cmd_tok, num_tokens, children.items, sqrt_row_data);
    }

    /// \dot{q} \hat x \vec{v} ...: the accent applies to ONE following atom
    /// or braced group. The result is an accent row (data =
    /// accent_row_data) of [base, mark]: the base atom and a char leaf
    /// carrying the combining-mark codepoint in `data` (like \cdot), so
    /// layout resolves the glyph and marks the box synthetic. Scripts after
    /// the accent (`\dot q^2`) attach to the whole accent row via the usual
    /// parseAtom path — exactly TeX's mathaccent behavior.
    fn accent(self: *Parser, ast: *atom.Ast, cmd_tok: u32, cp: u21) Error!u32 {
        const base = try self.parseScriptArg(ast); // single atom or group
        const bn = ast.node(base);
        const mark = try ast.createLeaf(.char, cmd_tok, 1, cp);
        const mn = ast.node(mark);
        const children = [_]atom.Node{ bn, mn };
        const num_tokens = (bn.first_token + bn.num_tokens) - cmd_tok;
        return self.createNode(ast, .row, cmd_tok, num_tokens, &children, accent_row_data);
    }

    /// \widehat{x} / \widetilde{x}: the EXTENSIBLE accents. The node is the
    /// same [base, mark] accent row `accent` builds, carrying one of the two
    /// wide markers so layout knows to pick the amsfonts branch:
    /// amsfonts.sty:79-86 measures the argument in \textstyle and uses the
    /// narrow \mathaccent"0362 / "0365 at or below 2em, the extensible
    /// accent above it. Latin Modern Math maps neither U+0362 nor U+0365
    /// (cmap lookup: both absent), so the mark is the U+0302 / U+0303 that
    /// \hat / \tilde already draw — the same outlines amsfonts' narrow
    /// branch resolves to. A mandatory braced group is TeX's \mathaccent
    /// argument shape here, so a bare `\widehat x` is the one-atom form
    /// \hat already accepts.
    fn wideAccent(
        self: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        marker: u32,
        cp: u21,
    ) Error!u32 {
        const base = try self.parseScriptArg(ast); // single atom or group
        const bn = ast.node(base);
        const mark = try ast.createLeaf(.char, cmd_tok, 1, cp);
        const children = [_]atom.Node{ bn, ast.node(mark) };
        const num_tokens = (bn.first_token + bn.num_tokens) - cmd_tok;
        return self.createNode(ast, .row, cmd_tok, num_tokens, &children, marker);
    }

    /// \arraystretch{n}: a LaTeX assignment, not an atom — it sets the row
    /// strut factor of the environments that follow. The node is a
    /// zero-width `.space` leaf, exactly the shape a standalone \limits takes
    /// (a space also suppresses the inter-atom glue on both sides in
    /// layoutRow, so the assignment never shifts its neighbours), spanning
    /// the command AND its braced argument. The factor itself travels in
    /// `Stretch.factor` and lands on the environment's first row
    /// (finishEnvRow), the one place layoutEnv can read it from: an `.env`
    /// node's `data` is bit-exhausted by EnvBits, and a row's `data` is
    /// otherwise free inside an environment because layoutEnv walks a row's
    /// cells and never lays the row node out itself.
    fn arraystretch(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const arg = try self.parseRequiredArg(ast);
        const an = ast.node(arg);
        // The braced argument is one bare decimal factor (LaTeX's
        // \arraystretch takes a number, not a dimension — no unit is
        // scanned). An empty group, a non-number, or a non-finite one is
        // MissingArgument at the argument's own span; the token span is
        // read here rather than from the node's, which is empty for `{}`.
        if (an.num_tokens == 0) return self.fail(.missing_argument, self.spanAt(an.first_token));
        const st = self.tokens[an.first_token];
        const et = self.tokens[an.first_token + an.num_tokens - 1];
        const bad: atom.Span = .{ .start = st.start, .end = et.end };
        const factor = std.fmt.parseFloat(f32, self.src[st.start..et.end]) catch
            return self.fail(.missing_argument, bad);
        if (!std.math.isFinite(factor)) return self.fail(.missing_argument, bad);
        self.stretch = .{ .factor = atom.emToFixed(factor), .assigned = true };
        const num_tokens = (an.first_token + an.num_tokens + 1) - cmd_tok;
        return ast.createLeaf(.space, cmd_tok, num_tokens, atom.emToFixed(0));
    }

    /// \tag{n}: amsmath's equation number. amsmath.sty:1210-1212 typesets it
    /// as `\hbox{\m@th\normalfont<arg>}` — upright text font, and NOT a noad
    /// in the formula's list (it is built beside the display and placed at
    /// the margin). The node is a `tag_row_data` row of ONE child: the
    /// braced argument wrapped in a `.styled` roman scope, so the digits
    /// draw exactly as \operatorname's roman letters do while the row still
    /// reports an ord class (see layout's leftRole). The argument keeps its
    /// own token span, so each drawn glyph aliases its real source bytes
    /// (no synthetic flag, no arena copy) and the span lies inside `\tag{…}`.
    fn tag(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        // At end of input there is no offending token for parseRequiredArg
        // to point at, and its EOF span is zero-width — the CLI's caret
        // needs real bytes, so the error covers the command itself.
        if (self.atEnd()) return self.fail(.missing_argument, self.spanAt(cmd_tok));
        const arg = try self.parseRequiredArg(ast);
        const an = ast.node(arg);
        const styled = try self.createNode(
            ast,
            .styled,
            an.first_token,
            an.num_tokens,
            &[_]atom.Node{an},
            @intFromEnum(atom.CharStyle.roman),
        );
        const sn = ast.node(styled);
        const children = [_]atom.Node{sn};
        // parseRequiredArg consumed the closing `}`, which the argument's own
        // token range does not cover — the +1 is the same anchor \arraystretch
        // uses, so the row spans `\tag{…}` whole.
        const num_tokens = (sn.first_token + sn.num_tokens + 1) - cmd_tok;
        return self.createNode(ast, .row, cmd_tok, num_tokens, &children, tag_row_data);
    }

    /// \not<relation> — the negation prefix (a diagonal slash through the
    /// following atom/group). Matches unicode-math's \not command: when the
    /// base is a single relation glyph with a pre-composed negated form in
    /// `not_cp_map`, the result is that glyph (a char leaf carrying the
    /// codepoint in `data`, like \cdot — layout marks it synthetic because
    /// the drawn glyph differs from the "\not\leq" source bytes); otherwise
    /// the result is a `not_row_data` row of [base], whose layout overlays
    /// the U+0338 combining long solidus overlay exactly like XeTeX's
    /// \mathaccentoverlay placement (see layoutNot). The span covers
    /// `\not` through the base so provenance stays exact. Scripts after the
    /// negation (`\not\leq^2`) attach to the result via the usual
    /// parseAtom path.
    fn not(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const base = try self.parseScriptArg(ast); // single atom or group
        const bn = ast.node(base);
        const num_tokens = (bn.first_token + bn.num_tokens) - cmd_tok;
        // Unwrap transparent wrappers to the underlying single atom: \not{a}
        // negates the GROUP's content, but a braced single glyph ({=}) is
        // still TeX's one-noad case — the pre-composed form applies (the
        // XeTeX reference renders \not{=} → ≠ and \not{\leq} → ≰). A group
        // wraps its row, so single-child rows are descended too; multi-child
        // groups ({ab}) keep the overlay path (XeTeX anchors that slash to
        // the group's FIRST character — layoutNot's first-char rule).
        var u = base;
        while (true) {
            const n = ast.node(u);
            const transparent = n.tag == .group or n.tag == .styled or n.tag == .mathstyle;
            if (!transparent and !(n.tag == .row and n.num_children == 1)) break;
            if (n.num_children == 0) break;
            u = ast.child(u, 0);
        }
        const un = ast.node(u);
        if (un.tag == .char) {
            const cp: u21 = if (un.data != 0) @truncate(un.data) else blk: {
                const sp = ast.span(u);
                break :blk if (sp.end - sp.start == 1) self.src[sp.start] else 0;
            };
            for (not_cp_map) |e| {
                if (e.cp == cp) {
                    // Pre-composed glyph: a char leaf like \cdot (the
                    // codepoint rides in `data`; layout marks it synthetic).
                    return ast.createLeaf(.char, cmd_tok, num_tokens, e.neg);
                }
            }
        }
        // Overlay: a row marked `not_row_data`, children [base].
        const children = [_]atom.Node{ast.node(base)};
        return self.createNode(ast, .row, cmd_tok, num_tokens, &children, not_row_data);
    }

    /// \overline{x} / \underline{x}: a rule over/under ONE following atom or
    /// braced group (TeX: the argument is a math field — `\overline x` is
    /// the overline of x, `\overline{xy}` of the group). The node is a
    /// `.overline` atom whose data = 0 over / 1 under, so layout draws the
    /// rule (rect, rule_thickness thick) above/below the content at a
    /// clearance of 3·rule_thickness, spanning exactly the content's width.
    /// Scripts after it (`\overline{x}^2`) attach to the whole overline via
    /// the usual parseAtom path.
    fn overunder(self: *Parser, ast: *atom.Ast, cmd_tok: u32, under: bool) Error!u32 {
        const base = try self.parseScriptArg(ast); // single atom or group
        const bn = ast.node(base);
        const num_tokens = (bn.first_token + bn.num_tokens) - cmd_tok;
        const children = [_]atom.Node{ast.node(base)};
        return self.createNode(ast, .overline, cmd_tok, num_tokens, &children, @intFromBool(under));
    }

    /// \substack{a \\ b \\ c}: amsmath's script-size multi-line stack for
    /// limits (`\sum_{\substack{i=1 \\ j=2}} x_i x_j`). The braced content
    /// is split on `\\` into lines, each parsed as its own row in
    /// .substack_line mode (so `\\` and `}` end a line; scripts, infix
    /// fractions and style switches inside a line behave exactly as in a
    /// normal row). The lines become the children of a `.substack` atom;
    /// layout stacks them at script size, centered, with the TeX \subarray
    /// baseline gaps. Scripts after the stack (`\substack{...}^2`) attach
    /// via the usual parseAtom path, like any base.
    fn substack(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        const open_tok: u32 = @intCast(self.pos);
        _ = self.advance(); // consume `{`
        var lines: std.ArrayList(atom.Node) = .empty;
        defer lines.deinit(self.gpa);
        var close_tok: u32 = cmd_tok;
        while (true) {
            const line = try self.parseRow(ast, .substack_line);
            const ln = ast.node(line);
            try lines.append(self.gpa, ln);
            // Unclosed substack: point at its opening brace.
            const nxt = self.peek() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
            if (nxt.tag == .r_group) {
                close_tok = @intCast(self.pos);
                _ = self.advance(); // consume `}`
                break;
            }
            // Otherwise the next token is the `\\` line separator (parseRow
            // stopped right at it).
            if (nxt.tag != .command or !std.mem.eql(u8, self.src[nxt.start + 1 .. nxt.end], "\\"))
                return self.fail(.unclosed_group, spanOf(nxt));
            _ = self.advance(); // consume `\\`
        }
        const num_tokens = (close_tok + 1) - cmd_tok;
        return self.createNode(ast, .substack, cmd_tok, num_tokens, lines.items, 0);
    }

    /// \begin{env}...\end{env}: parse the environment name (`{name}` or
    /// bare letters), the array colspec (for \begin{array}{...}), then the
    /// body — rows split on `\\` (also `\\[dimen]`), cells split on `&` —
    /// until the matching `\end{NAME}`. The result is a `.env` node whose
    /// children are [open?, row1, ..., rowN, close?]: the delimiter char
    /// leaves (pmatrix/bmatrix/Bmatrix/vmatrix/Vmatrix/cases — codepoints
    /// in `data`, like \cdot) around the row atoms. Each row is a `.row`
    /// whose children are the cell atoms; the cells are parsed by parseRow
    /// in `.env_cell` mode, so nested environments, groups, scripts and
    /// \left..\right inside a cell all work.
    fn parseBegin(self: *Parser, ast: *atom.Ast, begin_tok: u32) Error!u32 {
        const name = try self.parseEnvName(ast);
        const kind = env_kind_map.get(name) orelse {
            // The offending input is the environment name itself.
            const start: u32 = @intCast(@intFromPtr(name.ptr) - @intFromPtr(self.src.ptr));
            const span: atom.Span = .{ .start = start, .end = start + @as(u32, @intCast(name.len)) };
            return self.fail(.unknown_environment, span);
        };
        var colspec: []const u8 = "";
        if (kind == .array) colspec = try self.parseColspec(ast);
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        // The delimiter char leaves around the rows (pmatrix → ( ), ...);
        // the char leaf data carries the codepoint (layout marks synthetic).
        if (envOpenDelim(kind)) |cp| {
            const leaf = try ast.createLeaf(.char, begin_tok, 1, cp);
            try children.append(self.gpa, ast.node(leaf));
        }
        // Each environment body starts at a row boundary. A NESTED
        // environment's rules and cells are its own, so the enclosing
        // body's counter is restored afterwards.
        const outer_row_cells = self.env_row_cells;
        defer self.env_row_cells = outer_row_cells;
        self.env_row_cells = 0;
        // `\arraystretch` needs nothing here: parseEnvBody hands the parser
        // state back to the factor it opened with after every cell, so the
        // body can neither leak an assignment out nor carry one from one
        // cell into the next.
        var entries = try self.parseEnvBody(ast);
        defer entries.deinit(self.gpa);
        for (entries.items) |r| try children.append(self.gpa, r);
        if (envCloseDelim(kind)) |cp| {
            const leaf = try ast.createLeaf(.char, begin_tok, 1, cp);
            try children.append(self.gpa, ast.node(leaf));
        }
        // Expect the matching `\end` and verify the name.
        const t = self.advance() orelse return self.fail(.unclosed_environment, self.spanAt(self.pos));
        if (t.tag != .command or !std.mem.eql(u8, self.src[t.start + 1 .. t.end], "end"))
            return self.fail(.unclosed_environment, spanOf(t));
        const end_name = try self.parseEnvName(ast);
        if (!std.mem.eql(u8, end_name, name)) {
            // The offending input is the mismatched \end name.
            const start: u32 = @intCast(@intFromPtr(end_name.ptr) - @intFromPtr(self.src.ptr));
            const span: atom.Span = .{ .start = start, .end = start + @as(u32, @intCast(end_name.len)) };
            return self.fail(.mismatched_end, span);
        }
        const num_tokens = @as(u32, @intCast(self.pos)) - begin_tok;
        return self.createNode(ast, .env, begin_tok, num_tokens, children.items, atom.envData(kind, colspec));
    }

    /// The environment body: rows split on `\\` (an optional `[dimen]` row
    /// gap is consumed and discarded), cells split on `&`, and `\hline`
    /// entries BETWEEN rows. Each cell is a row parsed in `.env_cell` mode
    /// (which stops at `&`, `\\`, `\end`, and at a leading `\hline`).
    ///
    /// Returns the `.env` node's entries — `.row` nodes and `.hline` rule
    /// leaves interleaved in source order. A rule is NEITHER a row NOR a
    /// cell: `\hline`, `a \\ \hline` and `a \\ \hline \\end` all yield
    /// exactly the real rows, so a leading, intermediate or trailing rule
    /// never fabricates an empty row. Repeated rules stay SEPARATE entries
    /// (`\hline \hline` is two rules), exactly as written.
    ///
    /// `\arraystretch` is CELL-SCOPED in a body: the parser state returns to
    /// the factor the body opened with after every cell, so the next cell —
    /// and every environment that cell opens — reads the outer factor and
    /// never the previous cell's assignment. The factor THIS environment's
    /// own rows are built from is captured separately (`env_factor`) and
    /// stamped on the first row alone.
    fn parseEnvBody(self: *Parser, ast: *atom.Ast) Error!std.ArrayList(atom.Node) {
        var entries: std.ArrayList(atom.Node) = .empty;
        errdefer entries.deinit(self.gpa);
        var cells: std.ArrayList(atom.Node) = .empty;
        defer cells.deinit(self.gpa);
        // The state the body opened with: what every cell hands back, and
        // what the body hands on to whatever follows it.
        const outer_stretch = self.stretch;
        defer self.stretch = outer_stretch;
        // What this environment's own rows are built from. It starts at the
        // factor the body opened with and follows the cells of the FIRST row
        // that ASSIGN one — the row the stamp rides on. A cell that only
        // inherits a factor leaves it alone, so a plain cell after the
        // assigning one keeps that factor, a second assignment replaces it
        // (the last one written wins), and
        // `\begin{array}\hline\arraystretch{2}a…` still stretches.
        var env_factor = outer_stretch.factor;
        // 1 once a real `.row` entry exists. The `\arraystretch` factor rides
        // on the FIRST ROW, so a leading `\hline` in front of it must not
        // steal the stamp — the row is identified by its tag, not by its
        // position in the entry list.
        var have_row = false;
        // 1 while the entry just appended was a rule. An all-empty row
        // hanging off a TRAILING `\hline` is that rule's `\end` artefact,
        // not a row the author wrote, so it is dropped instead of laid out.
        // A plain trailing `\\` keeps the behavior it always had.
        var after_rule = false;
        while (true) {
            // A factor inherited from outside the body never claims the cell
            // it lands in: only an assignment THIS cell makes is one.
            self.stretch.assigned = false;
            const cell = try self.parseRow(ast, .env_cell);
            try cells.append(self.gpa, ast.node(cell));
            // Only a cell that assigned a factor itself moves this
            // environment's strut; a group, a `\left … \right` pair or a
            // nested body inside the cell restored its own state, so its
            // assignments never reach this line.
            if (!have_row and self.stretch.assigned) env_factor = self.stretch.factor;
            // Every cell hands the outer factor back, with no claim left over.
            self.stretch = .{ .factor = outer_stretch.factor, .assigned = false };

            const nxt = self.peek();
            if (nxt == null) return self.fail(.unclosed_environment, self.spanAt(self.pos)); // no \end
            const t = nxt.?;
            switch (t.tag) {
                .r_group => return self.fail(.unexpected_r_group, spanOf(t)), // stray } in the body
                .char => {
                    // `&` starts the next cell; anything else is a stray
                    // char parseRow left unparsed.
                    if (self.src[t.start] != '&') return self.fail(.unexpected_r_group, spanOf(t));
                    _ = self.advance(); // consume `&`
                    self.env_row_cells += 1;
                },
                .command => {
                    const nm = self.src[t.start + 1 .. t.end];
                    if (std.mem.eql(u8, nm, "end")) {
                        // \end closes the environment: finalize the current
                        // row only if it has cells — a trailing `\\` before
                        // \end does not add an empty row (TeX's \crcr is
                        // absorbed after an explicit \cr).
                        // After a TRAILING \hline there is no row left: the
                        // empty cell parseRow returned belongs to the rule,
                        // so it is dropped rather than laid out.
                        if (cells.items.len > 0 and !(after_rule and self.rowIsEmpty(&cells))) {
                            try self.finishEnvRow(ast, &entries, &cells, !have_row, env_factor);
                        }
                        return entries;
                    }
                    if (std.mem.eql(u8, nm, "hline")) {
                        // A rule sits BETWEEN rows: finish the row above it
                        // (when that row has real content), then emit the
                        // rule as its own entry. An all-empty pending row —
                        // the leading `\hline`, and every `\hline` right
                        // after a `\\` — is dropped, never made into a row.
                        const rule_tok: u32 = @intCast(self.pos);
                        _ = self.advance(); // consume \hline
                        if (self.rowIsEmpty(&cells)) {
                            // Nothing was written on this line: drop the
                            // placeholder cell, or the NEXT row would start
                            // with it and gain a phantom column.
                            cells.clearRetainingCapacity();
                        } else {
                            try self.finishEnvRow(ast, &entries, &cells, !have_row, env_factor);
                            have_row = true;
                            after_rule = false;
                        }
                        const rule = try ast.createLeaf(.hline, rule_tok, 1, 0);
                        try entries.append(self.gpa, ast.node(rule));
                        after_rule = true;
                        self.env_row_cells = 0;
                        continue;
                    }
                    if (std.mem.eql(u8, nm, "\\")) {
                        _ = self.advance(); // consume `\\`
                        // Optional `[dimen]` row gap after `\\` is consumed
                        // (its value is not modeled; the strut gap governs).
                        if (self.peek()) |d| {
                            if (d.tag == .char and self.src[d.start] == '[') {
                                _ = self.advance();
                                while (self.peek()) |c| {
                                    if (c.tag == .char and self.src[c.start] == ']') break;
                                    _ = self.advance();
                                }
                                const close = self.advance() orelse
                                    return self.fail(.missing_argument, self.spanAt(self.pos));
                                if (close.tag != .char or self.src[close.start] != ']')
                                    return self.fail(.missing_argument, spanOf(close));
                            }
                        }
                        try self.finishEnvRow(ast, &entries, &cells, !have_row, env_factor);
                        have_row = true;
                        after_rule = false;
                        self.env_row_cells = 0;
                        continue;
                    }
                    return self.fail(.unexpected_r_group, spanOf(t));
                },
                else => return self.fail(.unexpected_r_group, spanOf(t)),
            }
        }
    }

    /// Whether the pending row carries no cell content at all — a single
    /// empty cell. Such a row is what a leading/trailing `\hline` leaves
    /// behind, never a row the author wrote, so it must not be appended.
    fn rowIsEmpty(_: *Parser, cells: *const std.ArrayList(atom.Node)) bool {
        return cells.items.len == 1 and cells.items[0].num_children == 0;
    }

    /// Wrap the collected cells of the current row into a `.row` node and
    /// append it to the env's entries. The FIRST ROW carries `env_factor` —
    /// the factor this environment's rows are built from (the f32 em bits,
    /// 0 = no assignment) — in its `data`, because a row's `data` is
    /// otherwise unused inside an environment and `layoutEnv` reads it back
    /// for the row struts. The caller passes `first_row`, because with
    /// `\hline` in play "first" means the first `.row` ENTRY, not the first
    /// entry of any kind: a leading rule must not steal the stamp from the
    /// row behind it.
    fn finishEnvRow(
        self: *Parser,
        ast: *atom.Ast,
        entries: *std.ArrayList(atom.Node),
        cells: *std.ArrayList(atom.Node),
        first_row: bool,
        env_factor: u32,
    ) Error!void {
        const first = cells.items[0];
        const last = cells.items[cells.items.len - 1];
        const num_tokens = (last.first_token + last.num_tokens) - first.first_token;
        const data: u32 = if (first_row) env_factor else 0;
        const row = try self.createNode(
            ast,
            .row,
            first.first_token,
            num_tokens,
            cells.items,
            data,
        );
        try entries.append(self.gpa, ast.node(row));
        cells.clearRetainingCapacity();
    }

    /// The environment name after \begin/\end: `{name}` or bare letters
    /// (`\begin matrix`). Returns the name bytes (a slice of the source).
    fn parseEnvName(self: *Parser, _: *atom.Ast) Error![]const u8 {
        const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        var start_tok: u32 = undefined;
        var end_tok: u32 = undefined;
        if (t.tag == .l_group) {
            const open_tok: u32 = @intCast(self.pos);
            _ = self.advance(); // consume `{`
            start_tok = @intCast(self.pos);
            while (self.peek()) |c| {
                if (c.tag != .char) break;
                _ = self.advance();
            }
            end_tok = @intCast(self.pos);
            const close = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
            if (close.tag != .r_group) return self.fail(.missing_argument, spanOf(close));
        } else if (t.tag == .char and isEnvNameChar(self.src[t.start])) {
            start_tok = @intCast(self.pos);
            while (self.peek()) |c| {
                if (c.tag != .char or !isEnvNameChar(self.src[c.start])) break;
                _ = self.advance();
            }
            end_tok = @intCast(self.pos);
        } else {
            return self.fail(.missing_argument, spanOf(t));
        }
        if (end_tok == start_tok) return self.fail(.missing_argument, spanOf(t)); // empty name
        const st = self.tokens[start_tok];
        const et = self.tokens[end_tok - 1];
        return self.src[st.start..et.end];
    }

    /// The array column spec: a required braced string of l/c/r/| chars
    /// (`\begin{array}{l|r}`). Returns the bytes between the braces.
    fn parseColspec(self: *Parser, _: *atom.Ast) Error![]const u8 {
        const t = self.advance() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
        const open_tok: u32 = @intCast(self.pos - 1);
        const start_tok: u32 = @intCast(self.pos);
        while (self.peek()) |c| {
            if (c.tag != .char) break;
            _ = self.advance();
        }
        const end_tok: u32 = @intCast(self.pos);
        const close = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
        if (close.tag != .r_group) return self.fail(.missing_argument, spanOf(close));
        if (end_tok == start_tok) return self.fail(.missing_argument, spanOf(t));
        const st = self.tokens[start_tok];
        const et = self.tokens[end_tok - 1];
        return self.src[st.start..et.end];
    }

    /// \pmod{n} / \pod{n}: amsmath's parenthesized-mod constructs (the
    /// " (mod n)" after a congruence). amsmath.sty:
    ///   \pod#1{\allowbreak \if@display\mkern18mu\else\mkern8mu\fi (#1)}
    ///   \pmod#1{\pod{{\operator@font mod}\mkern6mu#1}}
    /// so \pmod = leading \mkern + '(' + roman "mod" + 6mu + arg + ')' and
    /// \pod = the same without the word. The parse result is a row marked
    /// pmod_row_data / pod_row_data whose children are
    /// ['(', (opname "mod", 6mu space leaf, for \pmod), arg, ')'] — the
    /// synthesized glyphs (parens, letters) carry their codepoints in
    /// `data` and share the command token's span, so layout marks them
    /// synthetic. layoutPmod applies the leading \mkern — 8mu in every
    /// style (the \if@display 18mu branch never fires inside \array cells,
    /// measured on XeTeX: the \displaystyle array rows render identical to
    /// the text rows) — and places the pieces back to back (every
    /// inter-atom glue in the composition is zero in TeX).
    fn pmod(self: *Parser, ast: *atom.Ast, cmd_tok: u32, with_mod: bool) Error!u32 {
        const arg = try self.parseScriptArg(ast); // single atom or braced group
        const an = ast.node(arg);
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        const open = try ast.createLeaf(.char, cmd_tok, 1, 0x28); // (
        try children.append(self.gpa, ast.node(open));
        if (with_mod) {
            // the roman "mod" word (the same opname mechanism as \sin):
            // letters with ASCII codepoints in data, laid out roman
            const word = try self.opname(ast, cmd_tok, "mod");
            try children.append(self.gpa, ast.node(word));
            // \mkern6mu between the word and the argument (6/18 em)
            const gap = try ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(6.0 / 18.0));
            try children.append(self.gpa, ast.node(gap));
        }
        try children.append(self.gpa, an);
        const close = try ast.createLeaf(.char, cmd_tok, 1, 0x29); // )
        try children.append(self.gpa, ast.node(close));
        const num_tokens = (an.first_token + an.num_tokens) - cmd_tok;
        return self.createNode(
            ast,
            .row,
            cmd_tok,
            num_tokens,
            children.items,
            if (with_mod) pmod_row_data else pod_row_data,
        );
    }

    /// \bmod: amsmath's binary mod. amsmath.sty:
    ///   \def\bmod{\mskip-\medmuskip\mkern5mu\mathbin{\operator@font mod}
    ///             \penalty900\mkern5mu\mskip-\medmuskip}
    /// The ord↔bin glue TeX inserts around the \mathbin (4mu medmuskip) is
    /// cancelled by the two \mskip-\medmuskip kerns, so the NET spacing is
    /// exactly 5mu before and after the roman "mod" word (measured on the
    /// XeTeX reference: `a \bmod 2` at 30pt has 8.334pt = 5mu on each
    /// side). The parse result is a row marked bmod_row_data whose children
    /// are [5mu space, opname "mod", 5mu space]; the row's role is ord (the
    /// space leaves are ord), so layoutRow adds no inter-atom glue around
    /// it and layoutBmod places the three pieces back to back.
    fn bmod(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const word = try self.opname(ast, cmd_tok, "mod");
        const gap = try ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(5.0 / 18.0));
        const wn = ast.node(word);
        const gn = ast.node(gap);
        const children = [_]atom.Node{ gn, wn, gn };
        return self.createNode(ast, .row, cmd_tok, 1, &children, bmod_row_data);
    }

    /// \mod{arg}: amsmath's mod with its argument. amsmath.sty:
    ///   \def\mod#1{\allowbreak \if@display\mkern18mu\else\mkern12mu\fi
    ///              {\operator@font mod}\,\,#1}
    /// so \mod = the leading \mkern — 12mu in every style (the \if@display
    /// 18mu branch never fires inside \array cells, measured on XeTeX: the
    /// \displaystyle array rows render identical to the text rows) — plus
    /// the roman "mod" word + TWO thin spaces (\, \, = 6mu) + the argument.
    /// The parse result is a row marked mod_row_data whose children are
    /// [opname "mod", 6mu space, arg]; layoutMod applies the leading \mkern
    /// and places the pieces back to back (the composition's inter-atom
    /// glues are all zero in TeX). The row's left role is forced to ord
    /// (the leading \mkern is not a noad — TeX's first atom of the
    /// construct is the ord "mod" group, so the preceding atom gets NO
    /// glue).
    fn mod(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        const arg = try self.parseScriptArg(ast); // single atom or braced group
        const an = ast.node(arg);
        const word = try self.opname(ast, cmd_tok, "mod");
        // \,\,\! — the two thin spaces between the word and the argument
        // (6/18 em, exactly like \pmod's \mkern6mu).
        const gap = try ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(6.0 / 18.0));
        const children = [_]atom.Node{ ast.node(word), ast.node(gap), an };
        const num_tokens = (an.first_token + an.num_tokens) - cmd_tok;
        return self.createNode(ast, .row, cmd_tok, num_tokens, &children, mod_row_data);
    }

    /// \overset{top}{base} / \underset{bot}{base} / \stackrel{top}{base}:
    /// amsmath.sty:
    ///   \overset#1#2{\binrel@{#2}\binrel@@{\mathop{\kern\z@#2}\limits^{#1}}}
    ///   \underset#1#2{\binrel@{#2}\binrel@@{\mathop{\kern\z@#2}\limits_{#1}}}
    /// and the kernel (latex.ltx):
    ///   \stackrel#1#2{\mathrel{\mathop{#2}\limits^{#1}}}
    /// — a \mathop with FORCED limits, so the script is centred over (or
    /// under) the base in EVERY math style: measured on the XeTeX reference,
    /// `\overset{a}{b}` is byte-identical in display and text style, where a
    /// bare `\sum^{a}` would put its script beside. The \kern\z@ inside the
    /// \mathop is an empty kern and contributes no geometry, so all three
    /// share one parse shape and one layout; they differ only in the ATOM
    /// CLASS the row reports — the amsmath pair expands to
    /// `\mathrel{\nonscript\relax{}}` + base + the construct, and that empty
    /// \mathrel takes no class (measured: `x\overset{a}{b}` carries NO
    /// inter-atom glue on either side, while `x\stackrel{a}{b}` gets the thick
    /// 5mu of a \mathrel). The children are [script, base], the argument
    /// order of the macros.
    fn limitScript(
        self: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        placement: enum { over, under },
        rel: bool,
    ) Error!u32 {
        const script = try self.parseRequiredArg(ast);
        const base = try self.parseRequiredArg(ast);
        const sn = ast.node(script);
        const bn = ast.node(base);
        const children = [_]atom.Node{ sn, bn };
        const num_tokens = (bn.first_token + bn.num_tokens) - cmd_tok;
        const data: u32 = if (rel)
            stackrel_row_data
        else if (placement == .under)
            underset_row_data
        else
            overset_row_data;
        return self.createNode(ast, .row, cmd_tok, num_tokens, &children, data);
    }

    /// \phantom{x} / \hphantom{x} / \vphantom{x} / \smash{x} — latex.ltx:
    ///   \vphantom → \v@true \h@false \ph@nt, \hphantom → \v@false \h@true
    ///   \ph@nt, \phantom → \v@true \h@true \ph@nt, and \ph@nt typesets the
    ///   argument in an \hbox then copies the selected dimensions off it
    ///   (\finph@nt), leaving an EMPTY box — nothing is drawn.
    /// The argument is typeset at the CURRENT math style (measured:
    /// `x^{a\phantom{b^2}}` keeps b^2's script-size height), so only the
    /// dimensions are zeroed, never the content. `keep` is the keep mask the
    /// layout reads: \phantom keeps width AND height/depth, \vphantom only the
    /// vertical extent, \hphantom and \smash only the width.
    fn phantom(self: *Parser, ast: *atom.Ast, cmd_tok: u32, keep: u32, is_smash: bool) Error!u32 {
        const content = try self.parseRequiredArg(ast);
        const cn = ast.node(content);
        const children = [_]atom.Node{cn};
        const num_tokens = (cn.first_token + cn.num_tokens) - cmd_tok;
        const flags: u32 = if (is_smash) smash_row else 0;
        return self.createNode(ast, .row, cmd_tok, num_tokens, &children, phantom_row_data | flags | keep);
    }

    /// \smash[<axes>]{x} — amsmath's smash, whose optional argument selects
    /// which axes it zeroes:
    ///   \edef\finsm@sh{\csname mb@#1\endcsname\z@\z@\box\z@}
    /// with `\def\mb@t{\ht}` (ht → 0, depth and advance kept),
    /// `\def\mb@b{\dp}` (dp → 0) and `\def\mb@tb{\ht\z@\z@\dp}` (both). The
    /// default is `[tb]`, which zeroes both and leaves exactly \hphantom's
    /// geometry. An option that is not a subset of `t`/`b` is amsmath's
    /// `\csname mb@…\endcsname` on an undefined name — TeX errors, so ztex
    /// reports `error.MissingArgument` at the option text.
    fn smash(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        var keep: u32 = keep_width;
        if (self.peek()) |t| {
            if (t.tag == .char and self.src[t.start] == '[') {
                const open_tok: u32 = @intCast(self.pos);
                _ = self.advance(); // consume [
                const start_tok: u32 = @intCast(self.pos);
                while (self.peek()) |c| {
                    if (c.tag == .char and self.src[c.start] == ']') break;
                    _ = self.advance();
                }
                const end_tok: u32 = @intCast(self.pos);
                const close = self.advance() orelse
                    return self.fail(.unclosed_group, self.spanAt(open_tok));
                if (close.tag != .char or self.src[close.start] != ']')
                    return self.fail(.unclosed_group, self.spanAt(open_tok));
                const first = self.tokens[start_tok];
                const last = self.tokens[end_tok - 1];
                const axes = self.src[first.start..last.end];
                const bad: atom.Span = .{ .start = first.start, .end = last.end };
                keep = if (std.mem.eql(u8, axes, "t"))
                    keep_width | keep_depth
                else if (std.mem.eql(u8, axes, "b"))
                    keep_width | keep_height
                else if (std.mem.eql(u8, axes, "tb"))
                    keep_width
                else
                    return self.fail(.missing_argument, bad);
            }
        }
        // `smash` is the one family member whose box KEEPS its content: the
        // bit is what tells layoutPhantom to hold the argument instead of
        // draining it, because \smash[tb] and \hphantom share a keep mask.
        return self.phantom(ast, cmd_tok, keep, true);
    }

    /// \underbrace{x}_{c} / \overbrace{x}^{c}: plain TeX's brace macro
    /// (amsmath does not redefine it) — a \mathop whose nucleus is a \vtop
    /// (\underbrace) or \vbox (\overbrace) holding the content at
    /// \displaystyle followed by the extensible brace pieces, with an
    /// OPTIONAL `_{...}` / `^{...}` annotation attached as a limit (the
    /// annotation under an \underbrace, over an \overbrace; both are accepted
    /// in either position, exactly as a script after the macro). The children
    /// are [content] or [content, annotation]; layout draws the brace band and
    /// applies the annotation through the same forced-limits path as
    /// \overset.
    fn brace(self: *Parser, ast: *atom.Ast, cmd_tok: u32, under: bool) Error!u32 {
        const content = try self.parseRequiredArg(ast);
        const cn = ast.node(content);
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        try children.append(self.gpa, cn);
        var last = cn;
        // The optional annotation: exactly one script right after the content.
        if (self.peek()) |t| {
            if (t.tag == .sub or t.tag == .sup) {
                _ = self.advance(); // consume _ or ^
                const ann = try self.parseScriptArg(ast);
                const an = ast.node(ann);
                try children.append(self.gpa, an);
                last = an;
            }
        }
        const num_tokens = (last.first_token + last.num_tokens) - cmd_tok;
        return self.createNode(
            ast,
            .row,
            cmd_tok,
            num_tokens,
            children.items,
            if (under) underbrace_row_data else overbrace_row_data,
        );
    }

    /// \hspace{<dim>} / \kern<dim> / \mkern<dim>: an explicit horizontal skip.
    /// `braced` selects the two argument shapes (`\hspace` takes a braced
    /// group, `\kern`/`\mkern` a bare dimension, like TeX). \kern and \mkern
    /// are the same primitive in math mode (both an ord-grade kern).
    fn kern(self: *Parser, ast: *atom.Ast, cmd_tok: u32, braced: bool) Error!u32 {
        const dim = try self.parseDimension(braced);
        return self.kernRow(ast, cmd_tok, dim.value, dim.unit);
    }

    /// The kern row itself: the unit in `data`, the magnitude in the single
    /// `.space` child (a space leaf's f32 em payload — no layout change is
    /// needed to carry it, only to interpret it under the right unit).
    fn kernRow(
        self: *Parser,
        ast: *atom.Ast,
        cmd_tok: u32,
        value: f32,
        unit: DimUnit,
    ) Error!u32 {
        const leaf = try ast.createLeaf(.space, cmd_tok, 1, atom.emToFixed(value));
        const ln = ast.node(leaf);
        const children = [_]atom.Node{ln};
        const data = kern_row_data | @intFromEnum(unit);
        return self.createNode(ast, .row, cmd_tok, 1, &children, data);
    }

    /// A TeX dimension, braced (`\hspace{...}`) or bare (`\kern1em`):
    /// `<sign><digits>[.<digits>]<unit>`, the unit optional (a bare number is
    /// pt, as in TeX's scan_dimen). The bytes are re-read from the token
    /// spans. A missing brace, an unclosed group, or text that is not a
    /// dimension is `error.MissingArgument` at the offending span (an
    /// unclosed `{` reports `error.UnclosedGroup` at the brace, like every
    /// other braced argument here).
    ///
    /// The two forms scan DIFFERENTLY, because only the braced one is
    /// delimited by `}`. A braced dimension is simply every char token
    /// between the braces. A bare one is NOT a run of char tokens: the next
    /// atom's letters are char tokens too, so `\kern 2mu+y` scanned as the
    /// text `2mu+y` and was rejected. TeX's scan_dimen reads a number and
    /// then scan_units reads letters while they can still complete a legal
    /// unit, stopping at the first that cannot — so the bare scan is
    /// `scanBareDim` below and `2mu+y` is a 2mu kern, then `+`, then `y`.
    ///
    /// The pt default for a run with no unit applies only when the run ENDS
    /// there — `2` at end of source, or before a structural token such as `}`
    /// or `^`. An ordinary char token right behind the digits (`2+y`, `2*3`)
    /// means the author never closed the dimension and left the unit off,
    /// which is TeX's "Illegal unit of measure".
    fn parseDimension(self: *Parser, braced: bool) Error!Dim {
        const open_tok: u32 = @intCast(self.pos);
        if (braced) {
            const t = self.peek() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
            if (t.tag != .l_group) return self.fail(.missing_argument, spanOf(t));
            _ = self.advance(); // consume {
        }
        const start_tok: u32 = @intCast(self.pos);
        // A braced run has no unit scan at all: `}` delimits it. The bare
        // scan reports whether it read one (see scanBareDim's contract).
        var has_unit: bool = true;
        if (braced) {
            while (self.peek()) |t| {
                if (t.tag != .char) break;
                _ = self.advance();
            }
        } else {
            has_unit = self.scanBareDim();
        }
        const end_tok: u32 = @intCast(self.pos);
        if (braced) {
            const c = self.advance() orelse return self.fail(.unclosed_group, self.spanAt(open_tok));
            if (c.tag != .r_group) return self.fail(.unclosed_group, self.spanAt(open_tok));
        }
        if (end_tok == start_tok) return self.fail(.missing_argument, self.spanAt(start_tok));
        const st = self.tokens[start_tok];
        const et = self.tokens[end_tok - 1];
        const bad: atom.Span = .{ .start = st.start, .end = et.end };
        const dim = parseDim(self.src[st.start..et.end]) orelse
            return self.fail(.missing_argument, bad);
        // A bare number is a pt dimension — TeX's scan_dimen default — only
        // when it IS the whole run. An ordinary char token right behind the
        // digits (`2+y`, `2*3`) proves the run continued, so the unit is
        // missing rather than defaulted: TeX's "Illegal unit of measure",
        // reported at the run. A structural token or end of source ends it.
        if (!braced and !has_unit and self.peekByte() != null) {
            return self.fail(.missing_argument, bad);
        }
        return dim;
    }

    /// The single byte of the next token when it is a one-byte char token,
    /// else null. A control sequence, a group delimiter or a multi-byte
    /// glyph is never part of a dimension.
    fn peekByte(self: *const Parser) ?u8 {
        const t = self.peek() orelse return null;
        if (t.tag != .char or t.end - t.start != 1) return null;
        return self.src[t.start];
    }

    /// TeX's scan_dimen token run for a BARE `\kern` / `\mkern` dimension:
    /// an optional sign, the digits with an optional fraction, then the
    /// unit. The unit is scanned by TeX's scan_units rule — read letters
    /// until they SPELL an accepted unit, then stop — so `2mu+y` is a 2mu
    /// kern followed by `+y`, `1em+y` the same, `3pt+\alpha` a 3pt kern
    /// followed by `+\alpha`, and `2emu` a 2em kern followed by the atom
    /// `u`. A letter run that never spells a unit (`2zz`, `2px`, `2e`) is
    /// consumed and then rejected by parseDim with the run's own span,
    /// which is TeX's "Illegal unit of measure"; a number with no letters
    /// at all is a bare pt, as in TeX. The accepted unit set is unchanged
    /// — see `dim_unit_names`.
    ///
    /// Returns whether a unit was scanned. False means the run is a bare
    /// number, which parseDimension accepts as pt only when the run ends
    /// there.
    fn scanBareDim(self: *Parser) bool {
        if (self.peekByte()) |b| {
            if (b == '-' or b == '+') _ = self.advance();
        }
        while (self.peekByte()) |b| {
            if (!std.ascii.isDigit(b) and b != '.') break;
            _ = self.advance();
        }
        const unit_start: u32 = @intCast(self.pos);
        while (self.peekByte()) |b| {
            if (!std.ascii.isAlphabetic(b)) break;
            const t = self.advance() orelse break;
            if (isDimUnit(self.src[self.tokens[unit_start].start..t.end])) return true;
        }
        return false;
    }

    /// Parse the \sqrt[n] degree: atoms until a `]` char at this row level.
    fn parseUntilRBracket(self: *Parser, ast: *atom.Ast) Error!u32 {
        const start_tok: u32 = @intCast(self.pos);
        var last_tok: u32 = start_tok;
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        while (self.peek()) |t| {
            if (t.tag == .char and self.src[t.start] == ']') break;
            const child = try self.parseAtom(ast);
            const cn = ast.node(child);
            try children.append(self.gpa, cn);
            last_tok = cn.first_token + cn.num_tokens;
        }
        return self.createNode(ast, .row, start_tok, last_tok - start_tok, children.items, 0);
    }

    /// \big \Big \bigg \Bigg <delim> → a `.left` node of a SINGLE delimiter
    /// child (no inner, no \right) with `data` = the size level 1..4. TeX
    /// (amsmath \bBigg@) makes these \left<delim>\vcenter to n·\big@size{}
    /// \right.; XeTeX+unicode-math draws the SAME MATH-ladder variant at
    /// every size — measured 10/14/24/36pt: \big → parenleft.v1 (ink
    /// 1.094em), \Big → .v4 (1.792em), \bigg → .v6 (2.392em), \Bigg → .v7
    /// (2.990em) — because \big@size scales with the current size. Layout
    /// boxes the delimiter by the fixed ladder entry at the base font size,
    /// axis-centered like \left..\right. `\big.` (null delimiter, like
    /// `\left.`) contributes nothing — a zero-width space, exactly TeX's
    /// empty \big. with nulldelimiterspace 0.
    fn fixedDelim(self: *Parser, ast: *atom.Ast, cmd_tok: u32, level: u32) Error!u32 {
        const d = try self.parseDelimiter();
        if (d == null) return self.space(ast, cmd_tok, 0);
        const dd = d.?;
        const leaf = try ast.createLeaf(.char, dd.tok, 1, dd.cp);
        const children = [_]atom.Node{ast.node(leaf)};
        const num_tokens = (dd.tok + 1) - cmd_tok;
        return self.createNode(ast, .left, cmd_tok, num_tokens, &children, level);
    }

    /// \middle <delim> — valid only between \left and \right (TeX: "You
    /// can't use \middle in math mode" outside; it needs the enclosing
    /// pair's required size). The delimiter becomes a char leaf whose `data`
    /// packs (middle_marker << 21) | cp: layout's leftRole classifies it
    /// CLOSE (measured: NO glue around the \middle| in the XeTeX reference
    /// of `\left\{ x \middle| \frac{x}{2} \in S \right\}`), layoutRow emits
    /// a zero-width placeholder box, and layoutLeftRight rewrites it with
    /// the fence's required ink applied to the delimiter's OWN variant
    /// ladder (\middle| at 36pt = divides.v3 — the |'s smallest variant
    /// covering the same req the { fence resolved). `\middle.` renders
    /// nothing, like `\big.`.
    fn middle(self: *Parser, ast: *atom.Ast, cmd_tok: u32) Error!u32 {
        if (self.delim_depth == 0) return self.fail(.unexpected_middle, self.spanAt(cmd_tok));
        const d = try self.parseDelimiter();
        if (d == null) return self.space(ast, cmd_tok, 0);
        const dd = d.?;
        return ast.createLeaf(.char, dd.tok, 1, middle_marker | dd.cp);
    }

    /// \left <delim> ... \right <delim> → a `.left` node of [open, inner,
    /// close]: the two delimiter chars around the parsed interior. Layout
    /// stretches the delimiters to cover the inner's height (TeX delimiter
    /// sizing), so \left( \frac{a}{b} \right) shows parens spanning the
    /// fraction. `\left.` and `\right.` (null delimiters) contribute no char.
    fn parseLeftRight(self: *Parser, ast: *atom.Ast, left_tok: u32) Error!u32 {
        const open = try self.parseDelimiter();
        self.delim_depth += 1;
        errdefer self.delim_depth -= 1;
        // `\left … \right` bounds its interior like a group: a factor
        // written between the delimiters ends with the pair.
        const outer_stretch = self.stretch;
        defer self.stretch = outer_stretch;
        const inner = try self.parseRow(ast, .delimited);
        // expect the matching \right — checked while the pair is still
        // "open" (delim_depth 1), so an error here unwinds via the
        // errdefer and the depth is NOT double-decremented. An unclosed
        // \left points at the \left command itself (nothing was consumed
        // after the opening delimiter), or at whatever stands in place of
        // \right.
        const t = self.peek() orelse return self.fail(.unclosed_group, self.spanAt(left_tok));
        if (t.tag != .command or !std.mem.eql(u8, self.src[t.start + 1 .. t.end], "right"))
            return self.fail(.unclosed_group, spanOf(t));
        self.delim_depth -= 1;
        _ = self.advance(); // consume \right
        const close = try self.parseDelimiter();
        var children: std.ArrayList(atom.Node) = .empty;
        defer children.deinit(self.gpa);
        if (open) |d| {
            const c = try ast.createLeaf(.char, d.tok, 1, d.cp);
            try children.append(self.gpa, ast.node(c));
        }
        try children.append(self.gpa, ast.node(inner));
        if (close) |d| {
            const c = try ast.createLeaf(.char, d.tok, 1, d.cp);
            try children.append(self.gpa, ast.node(c));
        }
        // pos sits just past the closing delimiter token
        const num_tokens = @as(u32, @intCast(self.pos)) - left_tok;
        return self.createNode(ast, .left, left_tok, num_tokens, children.items, 0);
    }

    /// Consume one delimiter after \left/\right; null for `\left.` / `\right.`.
    fn parseDelimiter(self: *Parser) Error!?Delimiter {
        const t = self.advance() orelse return self.fail(.missing_argument, self.spanAt(self.pos));
        const tok: u32 = @intCast(self.pos - 1);
        return switch (t.tag) {
            .char => switch (self.src[t.start]) {
                '.' => null,
                '(', ')', '[', ']', '|' => .{ .cp = self.src[t.start], .tok = tok },
                else => self.fail(.missing_argument, spanOf(t)),
            },
            .command => blk: {
                const cp = delim_map.get(self.src[t.start + 1 .. t.end]) orelse
                    return self.fail(.missing_argument, spanOf(t));
                break :blk .{ .cp = cp, .tok = tok };
            },
            else => self.fail(.missing_argument, spanOf(t)),
        };
    }
};

/// A delimiter consumed by \left/\right: codepoint + its token index.
const Delimiter = struct {
    cp: u21,
    tok: u32,
};

/// The unit of an explicit horizontal skip, which decides how layout scales
/// it: the absolute-point units never scale with the font size, em/ex follow
/// the current style's size, and mu is style-invariant (1/18 em of the
/// ladder-neutral em — the convention \pmod's 8mu and \mod's 12mu already
/// follow).
const DimUnit = enum(u8) {
    pt = dim_pt,
    em = dim_em,
    ex = dim_ex,
    mu = dim_mu,
};

/// One TeX dimension: the magnitude plus the unit that scales it. `value` is
/// in points for `.pt` and in ems for `.em`/`.ex`/`.mu`.
const Dim = struct {
    value: f32,
    unit: DimUnit,
};

/// The unit names parseDim accepts, spelled out one letter at a time by the
/// bare `\kern` scan. This is the accepted set, unchanged: pt, bp, pc, in,
/// cm, mm (absolute) and em, ex, mu (relative). TeX's other internal units
/// — px, dd, cc, sp, nd, nc — stay rejected.
const dim_unit_names = [_][]const u8{
    "pt", "bp", "pc", "in", "cm", "mm", "em", "ex", "mu",
};

/// Whether `text` is one of the unit names parseDim accepts.
fn isDimUnit(text: []const u8) bool {
    for (dim_unit_names) |u| {
        if (std.mem.eql(u8, u, text)) return true;
    }
    return false;
}

/// Parse `<sign><digits>[.<digits>]<unit>` (TeX's scan_dimen grammar, minus
/// the internal units) from `text`, or null when it is not a dimension. The
/// unit is optional — a bare number is pt. The absolute conversions are
/// TeX's (TeXbook p.331: 1in = 72.27pt, 1pc = 12pt, 1bp = 72/72.27 pt); `mu`
/// is accepted here even though TeX rejects it for \kern/\hspace with "Illegal
/// unit of measure" — a mu dimension is the one thing \kern exists for.
fn parseDim(text: []const u8) ?Dim {
    var i: usize = 0;
    var sign: f32 = 1;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) {
        if (text[i] == '-') sign = -1;
        i += 1;
    }
    var mantissa: f32 = 0;
    var digits: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        mantissa = mantissa * 10 + @as(f32, @floatFromInt(text[i] - '0'));
        digits += 1;
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        var place: f32 = 0.1;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            mantissa += @as(f32, @floatFromInt(text[i] - '0')) * place;
            place *= 0.1;
            digits += 1;
        }
    }
    if (digits == 0) return null;
    // The unit decides the scaling (see DimUnit); the absolute units are
    // converted to points here, the em-relative ones are kept in ems.
    const unit_text = text[i..];
    const absolute: ?f32 = if (unit_text.len == 0 or std.mem.eql(u8, unit_text, "pt"))
        1.0
    else if (std.mem.eql(u8, unit_text, "bp"))
        72.0 / 72.27
    else if (std.mem.eql(u8, unit_text, "pc"))
        12.0
    else if (std.mem.eql(u8, unit_text, "in"))
        72.27
    else if (std.mem.eql(u8, unit_text, "cm"))
        72.27 / 2.54
    else if (std.mem.eql(u8, unit_text, "mm"))
        72.27 / 25.4
    else
        null;
    if (absolute) |k| return .{ .value = sign * mantissa * k, .unit = .pt };
    if (std.mem.eql(u8, unit_text, "em")) return .{ .value = sign * mantissa, .unit = .em };
    if (std.mem.eql(u8, unit_text, "ex")) return .{ .value = sign * mantissa, .unit = .ex };
    if (std.mem.eql(u8, unit_text, "mu")) return .{ .value = sign * mantissa, .unit = .mu };
    return null;
}

/// Environment name → kind, for \begin{env}. matrix/pmatrix/bmatrix/
/// Bmatrix/vmatrix/Vmatrix/cases/aligned are amsmath environments; array is
/// LaTeX's array. Unknown names error (UnknownEnvironment).
const env_kind_map = std.StaticStringMap(atom.EnvKind).initComptime(&[_]struct { []const u8, atom.EnvKind }{
    .{ "matrix", .matrix },
    .{ "pmatrix", .pmatrix },
    .{ "bmatrix", .bmatrix },
    .{ "Bmatrix", .Bmatrix },
    .{ "vmatrix", .vmatrix },
    .{ "Vmatrix", .Vmatrix },
    .{ "cases", .cases },
    .{ "aligned", .aligned },
    .{ "array", .array },
});

/// The delimiter char before the rows of an env (like \left), or null.
/// pmatrix ( ), bmatrix [ ], Bmatrix { }, vmatrix | |, Vmatrix ‖ ‖
/// (\lVert/\rVert — U+2016, which has a variant ladder), cases {.
fn envOpenDelim(kind: atom.EnvKind) ?u21 {
    return switch (kind) {
        .pmatrix => 0x28,
        .bmatrix => 0x5B,
        .Bmatrix => 0x7B,
        .vmatrix => 0x7C,
        .Vmatrix => 0x2016,
        .cases => 0x7B,
        else => null,
    };
}

/// The delimiter char after the rows of an env (like \right), or null.
fn envCloseDelim(kind: atom.EnvKind) ?u21 {
    return switch (kind) {
        .pmatrix => 0x29,
        .bmatrix => 0x5D,
        .Bmatrix => 0x7D,
        .vmatrix => 0x7C,
        .Vmatrix => 0x2016,
        else => null,
    };
}

/// ASCII letters only — environment names are letter runs.
fn isEnvNameChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
}

// ── tests ────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Lex + parse `src`, returning the populated Ast (caller must deinit).
fn parseSrc(gpa: std.mem.Allocator, src: []const u8) !atom.Ast {
    var ast = atom.Ast.init(gpa, src);
    errdefer ast.deinit();
    try lexer.lex(&ast, null);
    var p = Parser.init(gpa, src, ast.tokens.items, null);
    ast.root = try p.parse(&ast);
    return ast;
}

test "parser: empty source yields an empty row" {
    var ast = try parseSrc(testing.allocator, "");
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 1), ast.nodes.items.len);
    try testing.expectEqual(.row, ast.node(0).tag);
}

test "parser: chars become a row of char atoms" {
    var ast = try parseSrc(testing.allocator, "x+1");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(.row, root.tag);
    try testing.expectEqual(@as(u16, 3), root.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(ast.root, 0)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(ast.root, 2)).tag);
}

test "parser: script wraps base with sup and sub" {
    var ast = try parseSrc(testing.allocator, "x^2_3");
    defer ast.deinit();
    // root row → [script]
    const script = ast.child(ast.root, 0);
    const sn = ast.node(script);
    try testing.expectEqual(.script, sn.tag);
    try testing.expectEqual(@as(u16, 3), sn.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(script, 0)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(script, 1)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(script, 2)).tag);
}

test "parser: big operator becomes an op leaf" {
    var ast = try parseSrc(testing.allocator, "\\sum");
    defer ast.deinit();
    const op = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.op, op.tag);
}

test "parser: \\limits sets the force bit on the preceding op" {
    var ast = try parseSrc(testing.allocator, "\\int\\limits_0^1");
    defer ast.deinit();
    // root row → [script]; children [op, sub, sup]
    const script = ast.child(ast.root, 0);
    const op = ast.node(ast.child(script, 0));
    try testing.expectEqual(.op, op.tag);
    try testing.expectEqual(atom.LimitsBits.force, op.data & atom.LimitsBits.force);
    try testing.expectEqual(@as(u32, 0), op.data & atom.LimitsBits.force_beside);
    // the BigOp enum still decodes from the masked data
    try testing.expectEqual(atom.BigOp.int, @as(atom.BigOp, @enumFromInt(op.data & atom.LimitsBits.value_mask)));
}

test "parser: \\nolimits sets the force-beside bit on the preceding op" {
    var ast = try parseSrc(testing.allocator, "\\sum\\nolimits_{i=1}^{n} x_i");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const op = ast.node(ast.child(script, 0));
    try testing.expectEqual(.op, op.tag);
    try testing.expectEqual(atom.LimitsBits.force_beside, op.data & atom.LimitsBits.force_beside);
    try testing.expectEqual(@as(u32, 0), op.data & atom.LimitsBits.force);
    try testing.expectEqual(atom.BigOp.sum, @as(atom.BigOp, @enumFromInt(op.data & atom.LimitsBits.value_mask)));
}

test "parser: \\displaylimits restores the op default (no override bits)" {
    var ast = try parseSrc(testing.allocator, "\\int\\displaylimits_0^1");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const op = ast.node(ast.child(script, 0));
    try testing.expectEqual(.op, op.tag);
    try testing.expectEqual(@as(u32, 0), op.data & atom.LimitsBits.mask);
}

test "parser: last limits command wins on a repeated override" {
    var ast = try parseSrc(testing.allocator, "\\int\\nolimits\\limits_0^1");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const op = ast.node(ast.child(script, 0));
    try testing.expectEqual(atom.LimitsBits.force, op.data & atom.LimitsBits.force);
}

test "parser: \\limits sets the force bit on an operator word" {
    var ast = try parseSrc(testing.allocator, "\\lim\\limits_{x\\to 0}");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const opn = ast.node(ast.child(script, 0));
    try testing.expectEqual(.opname, opn.tag);
    try testing.expectEqual(atom.LimitsBits.force, opn.data & atom.LimitsBits.force);
}

test "parser: \\operatorname is an opname word with nolimits data" {
    var ast = try parseSrc(testing.allocator, "\\operatorname{tr}");
    defer ast.deinit();
    // root row → [opname]; the braced content is the opname's single child.
    const opn = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.opname, opn.tag);
    try testing.expectEqual(@as(u32, 0), opn.data); // unstarred = \nolimits
    try testing.expectEqual(@as(u16, 1), opn.num_children);
    // child is a row of the content's chars
    const row_idx = ast.child(ast.child(ast.root, 0), 0);
    try testing.expectEqual(.row, ast.node(row_idx).tag);
    try testing.expectEqual(@as(u16, 2), ast.node(row_idx).num_children);
    try testing.expectEqual(.char, ast.node(ast.child(row_idx, 1)).tag);
}

test "parser: \\operatorname* consumes the star and sets limits data" {
    var ast = try parseSrc(testing.allocator, "\\operatorname*{arg\\,max}");
    defer ast.deinit();
    // root row → [opname] — the `*` is a macro suffix, never an atom.
    try testing.expectEqual(@as(u16, 1), ast.node(ast.root).num_children);
    const opn = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.opname, opn.tag);
    try testing.expectEqual(@as(u32, 1), opn.data & atom.LimitsBits.value_mask); // \displaylimits
    // content row: a r g \, m a x → the \, is a space atom in the row
    const row_idx = ast.child(ast.child(ast.root, 0), 0);
    try testing.expectEqual(.row, ast.node(row_idx).tag);
    try testing.expectEqual(@as(u16, 7), ast.node(row_idx).num_children);
    try testing.expectEqual(.space, ast.node(ast.child(row_idx, 3)).tag); // the \,
}

test "parser: \\operatorname* with whitespace before the star is starred" {
    var ast = try parseSrc(testing.allocator, "\\operatorname * {x}");
    defer ast.deinit();
    const opn = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.opname, opn.tag);
    try testing.expectEqual(@as(u32, 1), opn.data & atom.LimitsBits.value_mask);
    try testing.expectEqual(@as(u16, 1), ast.node(ast.root).num_children);
}

test "parser: scripts attach to an \\operatorname base" {
    var ast = try parseSrc(testing.allocator, "\\operatorname{tr}^2");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    try testing.expectEqual(.script, ast.node(script).tag);
    const base = ast.node(ast.child(script, 0));
    try testing.expectEqual(.opname, base.tag);
    try testing.expectEqual(@as(u32, 0), base.data); // beside scripts by default
    const sup = ast.node(ast.child(script, 1));
    try testing.expectEqual(.char, sup.tag);
}

test "parser: \\operatorname without an argument is an error" {
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\operatorname"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\operatorname*"));
}

test "parser: sub-only script records SUB bit, not SUP" {
    var ast = try parseSrc(testing.allocator, "x_2");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const sn = ast.node(script);
    try testing.expectEqual(.script, sn.tag);
    try testing.expect(sn.data & atom.ScriptBits.sub != 0);
    try testing.expect(sn.data & atom.ScriptBits.sup == 0);
    try testing.expectEqual(@as(u16, 2), sn.num_children); // base + sub
}

test "parser: double script is an error" {
    try testing.expectError(error.DoubleScript, parseSrc(testing.allocator, "x^2^3"));
}

test "parser: atop produces a fraction with line=false" {
    var ast = try parseSrc(testing.allocator, "\\atop{a}{b}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expectEqual(@as(u32, 0), frac.data); // line = false
    try testing.expectEqual(@as(u16, 2), frac.num_children);
}

test "parser: binom is a left-wrapped ruleless fraction with parens" {
    var ast = try parseSrc(testing.allocator, "\\binom{n}{k}");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    try testing.expectEqual(@as(u32, 0), left.data); // fence path, not \big
    try testing.expectEqual(@as(u16, 3), left.num_children);
    // [open '(', fraction, close ')'] — the parens are synthetic char leaves
    const open = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.char, open.tag);
    try testing.expectEqual(@as(u32, 0x28), open.data);
    const frac = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expect(!atom.fracLine(frac.data)); // no rule (\atop-style)
    try testing.expectEqual(null, atom.fracForcedStyle(frac.data)); // current style
    try testing.expectEqual(@as(f32, 0), atom.fracThickness(frac.data));
    const close = ast.node(ast.child(ast.child(ast.root, 0), 2));
    try testing.expectEqual(.char, close.tag);
    try testing.expectEqual(@as(u32, 0x29), close.data);
}

test "parser: genfrac with empty delims and 0pt is a bare atop fraction" {
    var ast = try parseSrc(testing.allocator, "\\genfrac{}{}{0pt}{}{a}{b}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expectEqual(@as(u32, 0), frac.data); // exactly \atop's encoding
}

test "parser: genfrac explicit thickness sets line + thickness bits" {
    var ast = try parseSrc(testing.allocator, "\\genfrac{}{}{1pt}{}{a}{b}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expect(atom.fracLine(frac.data));
    try testing.expectApproxEqAbs(@as(f32, 1), atom.fracThickness(frac.data), 1e-3);
    try testing.expectEqual(null, atom.fracForcedStyle(frac.data));
}

test "parser: genfrac style argument maps like amsmath/KaTeX" {
    const cases = [_]struct { src: []const u8, forced: ?atom.MathStyle }{
        // "" → current style; 0 → display; 1 → text; 2 → script; else → scriptscript
        .{ .src = "\\genfrac{}{}{0pt}{}{a}{b}", .forced = null },
        .{ .src = "\\genfrac{}{}{0pt}{0}{a}{b}", .forced = .display },
        .{ .src = "\\genfrac{}{}{0pt}{1}{a}{b}", .forced = .text },
        .{ .src = "\\genfrac{}{}{0pt}{2}{a}{b}", .forced = .script },
        .{ .src = "\\genfrac{}{}{0pt}{3}{a}{b}", .forced = .script_script },
        .{ .src = "\\genfrac{}{}{0pt}{x}{a}{b}", .forced = .script_script },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const frac = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.fraction, frac.tag);
        try testing.expectEqual(c.forced, atom.fracForcedStyle(frac.data));
    }
}

test "parser: genfrac delimiters wrap the fraction in a left fence" {
    var ast = try parseSrc(testing.allocator, "\\genfrac{[}{]}{0pt}{}{a}{b}");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    try testing.expectEqual(@as(u16, 3), left.num_children);
    const open = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.char, open.tag);
    try testing.expectEqual(@as(u32, 0x5B), open.data);
    const frac = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(.fraction, frac.tag);
    try testing.expect(!atom.fracLine(frac.data));
    // a command delimiter (\lbrace) and a non-0.8pt thickness + style 1
    var b = try parseSrc(testing.allocator, "\\genfrac{\\lbrace}{\\rbrace}{0.8pt}{1}{x}{y}");
    defer b.deinit();
    const bl = b.node(b.child(b.root, 0));
    try testing.expectEqual(.left, bl.tag);
    const bopen = b.node(b.child(b.child(b.root, 0), 0));
    try testing.expectEqual(@as(u32, 0x7B), bopen.data);
    const bfrac = b.node(b.child(b.child(b.root, 0), 1));
    try testing.expect(atom.fracLine(bfrac.data));
    try testing.expectApproxEqAbs(@as(f32, 0.8), atom.fracThickness(bfrac.data), 1e-3);
    try testing.expectEqual(atom.MathStyle.text, atom.fracForcedStyle(bfrac.data));
}

test "parser: genfrac dot delimiters and missing args" {
    // \genfrac{.}{.} → null delimiters (like \left.), bare fraction
    var ast = try parseSrc(testing.allocator, "\\genfrac{.}{.}{0pt}{}{a}{b}");
    defer ast.deinit();
    try testing.expectEqual(.fraction, ast.node(ast.child(ast.root, 0)).tag);
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\genfrac{}{}{0pt}{}{a}"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\genfrac{}{}{abc}{}{a}{b}"));
}

test "parser: dfrac/tfrac/cfrac carry forced-style fraction data" {
    const cases = [_]struct {
        src: []const u8,
        line: bool,
        forced: ?atom.MathStyle,
        parts_display: bool,
    }{
        .{ .src = "\\dfrac{1}{2}", .line = true, .forced = .display, .parts_display = false },
        .{ .src = "\\tfrac{1}{2}", .line = true, .forced = .text, .parts_display = false },
        .{ .src = "\\cfrac{1}{2}", .line = true, .forced = .display, .parts_display = true },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const frac = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.fraction, frac.tag);
        try testing.expectEqual(c.line, atom.fracLine(frac.data));
        try testing.expectEqual(c.forced, atom.fracForcedStyle(frac.data));
        try testing.expectEqual(c.parts_display, atom.fracPartsDisplay(frac.data));
    }
    // a plain \frac keeps the legacy data encoding (0/1)
    var ast = try parseSrc(testing.allocator, "\\frac{1}{2}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(@as(u32, 1), frac.data);
    try testing.expectEqual(null, atom.fracForcedStyle(frac.data));
}

test "parser: style switches wrap the rest of the group in mathstyle" {
    var ast = try parseSrc(testing.allocator, "\\displaystyle x y");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(@as(u16, 1), root.num_children);
    const ms = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.mathstyle, ms.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.display)), ms.data);
    // the wrapped child is a row of BOTH atoms (rest-of-group semantics)
    const inner = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.row, inner.tag);
    try testing.expectEqual(@as(u16, 2), inner.num_children);
}

test "parser: textstyle sum keeps limits inside the wrapper" {
    var ast = try parseSrc(testing.allocator, "\\textstyle \\sum_{i=1}^{n} x_i");
    defer ast.deinit();
    const ms = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.mathstyle, ms.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.text)), ms.data);
    const inner = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.row, inner.tag);
    try testing.expectEqual(@as(u16, 2), inner.num_children); // \sum_{i=1}^{n}, x_i
    const scripted_sum = ast.node(ast.child(ast.child(ast.child(ast.root, 0), 0), 0));
    try testing.expectEqual(.script, scripted_sum.tag);
    const sum_base = ast.node(ast.child(ast.child(ast.child(ast.child(ast.root, 0), 0), 0), 0));
    try testing.expectEqual(.op, sum_base.tag);
}

test "parser: braced style switch in a script field wraps the group's row" {
    var ast = try parseSrc(testing.allocator, "x^{\\displaystyle 2}");
    defer ast.deinit();
    const script = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.script, script.tag);
    // the braced field is a group → its row → the mathstyle wrapper
    const sup = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(.group, sup.tag);
    const inner_row = ast.node(ast.child(ast.child(ast.child(ast.root, 0), 1), 0));
    try testing.expectEqual(.row, inner_row.tag);
    const ms = ast.node(ast.child(ast.child(ast.child(ast.child(ast.root, 0), 1), 0), 0));
    try testing.expectEqual(.mathstyle, ms.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.display)), ms.data);
}

test "parser: unbraced style switch in a script field wraps the single atom" {
    var ast = try parseSrc(testing.allocator, "x^\\displaystyle 2");
    defer ast.deinit();
    const script = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.script, script.tag);
    const sup = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(.mathstyle, sup.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.display)), sup.data);
    // the wrapped child is the single atom '2' (the rest of the row is outside)
    const inner = ast.node(ast.child(ast.child(ast.child(ast.root, 0), 1), 0));
    try testing.expectEqual(.char, inner.tag);
}

test "parser: empty braced style switch parses as an empty mathstyle group" {
    var ast = try parseSrc(testing.allocator, "\\frac{\\displaystyle}{b}");
    defer ast.deinit();
    const frac = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.fraction, frac.tag);
    // parseRequiredArg returns the inner row (no group wrapper)
    const num_row = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.row, num_row.tag);
    const ms = ast.node(ast.child(ast.child(ast.child(ast.root, 0), 0), 0));
    try testing.expectEqual(.mathstyle, ms.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.MathStyle.display)), ms.data);
}

test "parser: horizontal space commands carry em widths" {
    const cases = [_]struct { src: []const u8, em: f32 }{
        .{ .src = "\\,", .em = 0.166 },
        .{ .src = "\\;", .em = 0.277 },
        .{ .src = "\\quad", .em = 1.0 },
        .{ .src = "\\qquad", .em = 2.0 },
        .{ .src = "\\!", .em = -0.166 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const sp = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.space, sp.tag);
        try testing.expectApproxEqAbs(c.em, atom.fixedToEm(sp.data), 0.001);
    }
}

test "parser: text becomes a roman text leaf" {
    var ast = try parseSrc(testing.allocator, "\\text{hi}");
    defer ast.deinit();
    const txt = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.text, txt.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.CharStyle.roman)), txt.data);
}

test "parser: style commands set CharStyle data" {
    const cases = [_]struct { src: []const u8, style: atom.CharStyle }{
        .{ .src = "\\mathrm{x}", .style = .roman },
        .{ .src = "\\mathbf{x}", .style = .bold },
        .{ .src = "\\mathbb{x}", .style = .bb },
        .{ .src = "\\mathcal{x}", .style = .cal },
        .{ .src = "\\mathfrak{x}", .style = .frak },
        .{ .src = "\\mathsf{x}", .style = .sans },
        .{ .src = "\\mathtt{x}", .style = .mono },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const st = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.styled, st.tag);
        try testing.expectEqual(@as(u32, @intFromEnum(c.style)), st.data);
        try testing.expectEqual(@as(u16, 1), st.num_children);
    }
}

test "parser: sup-only script records SUP bit" {
    var ast = try parseSrc(testing.allocator, "x^2");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const sn = ast.node(script);
    try testing.expectEqual(.script, sn.tag);
    try testing.expect(sn.data & atom.ScriptBits.sup != 0);
    try testing.expect(sn.data & atom.ScriptBits.sub == 0);
    try testing.expectEqual(@as(u16, 2), sn.num_children); // base + sup
    try testing.expectEqual(.char, ast.node(ast.child(script, 1)).tag);
}

test "parser: braced superscript becomes a group child" {
    var ast = try parseSrc(testing.allocator, "x^{ab}");
    defer ast.deinit();
    const script = ast.child(ast.root, 0);
    const sn = ast.node(script);
    try testing.expectEqual(.script, sn.tag);
    try testing.expect(sn.data & atom.ScriptBits.sup != 0);
    try testing.expectEqual(@as(u16, 2), sn.num_children);
    try testing.expectEqual(.group, ast.node(ast.child(script, 1)).tag);
}

test "parser: all error paths are reported" {
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\frac{1}"));
    try testing.expectError(error.MissingScript, parseSrc(testing.allocator, "x^"));
    try testing.expectError(error.UnclosedGroup, parseSrc(testing.allocator, "\\frac{1}{2"));
    try testing.expectError(error.UnexpectedRGroup, parseSrc(testing.allocator, "x}"));
    try testing.expectError(error.UnexpectedScript, parseSrc(testing.allocator, "^x"));
    try testing.expectError(error.DoubleScript, parseSrc(testing.allocator, "x^2^3"));
}

test "parser: not resolves pre-composed negations to their codepoints" {
    // \not\in → ∉, \not\leq → ≰, \not= → ≠, \not\subset → ⊄, \not\simeq →
    // ≄ — the XeTeX+unicode-math reference renders all five as single
    // pre-composed glyphs, so ztex emits the same codepoints.
    const cases = [_]struct { src: []const u8, cp: u21 }{
        .{ .src = "\\not\\in", .cp = 0x2209 },
        .{ .src = "\\not\\leq", .cp = 0x2270 },
        .{ .src = "\\not=", .cp = 0x2260 },
        .{ .src = "\\not\\subset", .cp = 0x2284 },
        .{ .src = "\\not\\simeq", .cp = 0x2244 },
        .{ .src = "\\not\\ge", .cp = 0x2271 },
        .{ .src = "\\not\\equiv", .cp = 0x2262 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const ch = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.char, ch.tag);
        try testing.expectEqual(c.cp, @as(u21, @truncate(ch.data)));
        // the span covers \not + the relation
        try testing.expectEqual(@as(u32, 2), ch.num_tokens);
    }
}

test "parser: not on a relation without a pre-composed form emits the overlay row" {
    // \not\smile has no pre-composed negation in unicode-math/LM Math, so
    // the result is the U+0338-overlay row (children [base]).
    var ast = try parseSrc(testing.allocator, "\\not\\smile");
    defer ast.deinit();
    const row = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(not_row_data, row.data);
    try testing.expectEqual(@as(u16, 1), row.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.root, 0), 0)).tag);
}

test "parser: not on a plain char and a braced group" {
    // \not x → overlay row (no pre-composed form for x); \not{=} still
    // resolves the pre-composed ≠ through the transparent group.
    var ast = try parseSrc(testing.allocator, "\\not x");
    defer ast.deinit();
    const row = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(not_row_data, row.data);
    var ast2 = try parseSrc(testing.allocator, "\\not{=}");
    defer ast2.deinit();
    const ch = ast2.node(ast2.child(ast2.root, 0));
    try testing.expectEqual(.char, ch.tag);
    try testing.expectEqual(@as(u21, 0x2260), @as(u21, @truncate(ch.data)));
}

test "parser: pre-composed negation commands emit their codepoints" {
    const cases = [_]struct { src: []const u8, cp: u21 }{
        .{ .src = "\\nleq", .cp = 0x2270 },
        .{ .src = "\\ngeq", .cp = 0x2271 },
        .{ .src = "\\nsubseteq", .cp = 0x2288 },
        .{ .src = "\\nsupseteq", .cp = 0x2289 },
        .{ .src = "\\nmid", .cp = 0x2224 },
        .{ .src = "\\nparallel", .cp = 0x2226 },
        .{ .src = "\\nprec", .cp = 0x2280 },
        .{ .src = "\\nsucc", .cp = 0x2281 },
        .{ .src = "\\npreceq", .cp = 0x22E0 },
        .{ .src = "\\nsucceq", .cp = 0x22E1 },
        .{ .src = "\\nsim", .cp = 0x2241 },
        .{ .src = "\\ncong", .cp = 0x2247 },
        .{ .src = "\\napprox", .cp = 0x2249 },
        .{ .src = "\\neq", .cp = 0x2260 },
        .{ .src = "\\notin", .cp = 0x2209 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const ch = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.char, ch.tag);
        try testing.expectEqual(c.cp, @as(u21, @truncate(ch.data)));
    }
}

test "parser: big family emits single-delimiter .left nodes with level data" {
    const cases = [_]struct { src: []const u8, level: u32, cp: u21 }{
        .{ .src = "\\big(", .level = 1, .cp = 0x28 },
        .{ .src = "\\Big[", .level = 2, .cp = 0x5B },
        .{ .src = "\\bigg\\{", .level = 3, .cp = 0x7B },
        .{ .src = "\\Bigg\\langle", .level = 4, .cp = 0x27E8 },
        .{ .src = "\\big\\vert", .level = 1, .cp = 0x7C },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const left = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.left, left.tag);
        try testing.expectEqual(c.level, left.data);
        try testing.expectEqual(@as(u16, 1), left.num_children);
        const d = ast.node(ast.child(ast.child(ast.root, 0), 0));
        try testing.expectEqual(.char, d.tag);
        try testing.expectEqual(c.cp, @as(u21, @truncate(d.data)));
    }
}

test "parser: big with a null delimiter renders nothing" {
    var ast = try parseSrc(testing.allocator, "\\big.");
    defer ast.deinit();
    const sp = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.space, sp.tag);
    try testing.expectEqual(@as(u32, 0), sp.data); // zero width
}

test "parser: middle inside left-right packs marker plus codepoint" {
    var ast = try parseSrc(testing.allocator, "\\left\\{ x \\middle| \\frac{x}{2} \\in S \\right\\}");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    try testing.expectEqual(@as(u32, 0), left.data);
    try testing.expectEqual(@as(u16, 3), left.num_children); // [open, inner, close]
    // the inner row holds [x, middle|, frac, ∈, S]; the middle leaf carries
    // (middle_marker | 0x7C) in its data
    const inner = ast.child(ast.child(ast.root, 0), 1);
    const inode = ast.node(inner);
    const mid = ast.node(ast.child(inner, 1));
    try testing.expectEqual(.char, mid.tag);
    try testing.expectEqual(@as(u21, 0x7C), @as(u21, @truncate(mid.data)));
    try testing.expect(mid.data & middle_marker != 0);
    _ = inode;
}

test "parser: middle outside left-right errors" {
    try testing.expectError(error.UnexpectedMiddle, parseSrc(testing.allocator, "\\middle|"));
    try testing.expectError(error.UnexpectedMiddle, parseSrc(testing.allocator, "x \\middle| y"));
}

test "parser: plain left-right keeps open/inner/close structure" {
    var ast = try parseSrc(testing.allocator, "\\left( \\frac{a}{b} \\right)");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    try testing.expectEqual(@as(u32, 0), left.data); // auto-sizing fence, not a \big level
    try testing.expectEqual(@as(u16, 3), left.num_children); // [open, inner, close]
    try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.root, 0), 0)).tag);
    try testing.expectEqual(.row, ast.node(ast.child(ast.child(ast.root, 0), 1)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.root, 0), 2)).tag);
}

test "parser: middle inside a braced group within the pair is accepted" {
    var ast = try parseSrc(testing.allocator, "\\left( {a \\middle| b} \\right)");
    defer ast.deinit();
    const left = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.left, left.tag);
    // the pair's inner row holds the group; the group wraps its own inner
    // row [a, middle|, b]
    const inner = ast.child(ast.child(ast.root, 0), 1);
    const grp = ast.node(ast.child(inner, 0));
    try testing.expectEqual(.group, grp.tag);
    const grow = ast.child(ast.child(inner, 0), 0);
    const mid = ast.node(ast.child(grow, 1));
    try testing.expect(mid.data & middle_marker != 0);
}

test "parser: substack splits the braced content on double backslash" {
    var ast = try parseSrc(testing.allocator, "\\substack{i=1 \\\\ j=2}");
    defer ast.deinit();
    const st = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.substack, st.tag);
    // two line children, each a row of three atoms (i, =, 1 / j, =, 2)
    try testing.expectEqual(@as(u16, 2), st.num_children);
    for (0..2) |i| {
        const line = ast.node(ast.child(ast.child(ast.root, 0), i));
        try testing.expectEqual(.row, line.tag);
        try testing.expectEqual(@as(u16, 3), line.num_children);
        try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.child(ast.root, 0), i), 0)).tag);
    }
}

test "parser: substack allows scripts and trailing separators" {
    // \substack{a^2 \\} → two lines, the second empty
    var ast = try parseSrc(testing.allocator, "\\substack{a^2 \\\\}");
    defer ast.deinit();
    const st = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.substack, st.tag);
    try testing.expectEqual(@as(u16, 2), st.num_children);
    const first = ast.node(ast.child(ast.child(ast.root, 0), 0));
    try testing.expectEqual(.row, first.tag);
    try testing.expectEqual(@as(u16, 1), first.num_children); // the script atom
    try testing.expectEqual(.script, ast.node(ast.child(ast.child(ast.child(ast.root, 0), 0), 0)).tag);
    const second = ast.node(ast.child(ast.child(ast.root, 0), 1));
    try testing.expectEqual(@as(u16, 0), second.num_children); // empty line
}

test "parser: substack requires a braced argument" {
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\substack"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\substack a"));
}

test "parser: pmod composes parens, roman mod word, 6mu space and arg" {
    var ast = try parseSrc(testing.allocator, "a \\equiv b \\pmod{n}");
    defer ast.deinit();
    // root row [a, ≡, b, pmod-row]
    const row = ast.node(ast.child(ast.root, 3));
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(pmod_row_data, row.data);
    try testing.expectEqual(@as(u16, 5), row.num_children); // (, mod, 6mu, n, )
    const open = ast.node(ast.child(ast.child(ast.root, 3), 0));
    try testing.expectEqual(.char, open.tag);
    try testing.expectEqual(@as(u21, 0x28), @as(u21, @truncate(open.data))); // (
    const word = ast.node(ast.child(ast.child(ast.root, 3), 1));
    try testing.expectEqual(.opname, word.tag);
    const gap = ast.node(ast.child(ast.child(ast.root, 3), 2));
    try testing.expectEqual(.space, gap.tag);
    try testing.expectApproxEqAbs(@as(f32, 6.0 / 18.0), atom.fixedToEm(gap.data), 0.001); // \mkern6mu
    const close = ast.node(ast.child(ast.child(ast.root, 3), 4));
    try testing.expectEqual(.char, close.tag);
    try testing.expectEqual(@as(u21, 0x29), @as(u21, @truncate(close.data))); // )
}

test "parser: pod omits the mod word" {
    var ast = try parseSrc(testing.allocator, "a \\pod{n}");
    defer ast.deinit();
    const row = ast.node(ast.child(ast.root, 1));
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(pod_row_data, row.data);
    try testing.expectEqual(@as(u16, 3), row.num_children); // (, n, )
}

test "parser: \\begin{pmatrix} builds an env with delimiters and rows" {
    var ast = try parseSrc(testing.allocator, "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}");
    defer ast.deinit();
    // root row → [env]
    const env = ast.child(ast.root, 0);
    const en = ast.node(env);
    try testing.expectEqual(.env, en.tag);
    // children: [open '(', row1, row2, close ')']
    try testing.expectEqual(@as(u16, 4), en.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(env, 0)).tag);
    try testing.expectEqual(.row, ast.node(ast.child(env, 1)).tag);
    try testing.expectEqual(.row, ast.node(ast.child(env, 2)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(env, 3)).tag);
    try testing.expectEqual(atom.EnvKind.pmatrix, atom.envKind(en.data));
    // each row has two cell rows (cells are parsed as rows)
    try testing.expectEqual(@as(u16, 2), ast.node(ast.child(env, 1)).num_children);
    try testing.expectEqual(@as(u16, 2), ast.node(ast.child(env, 2)).num_children);
    // the delimiter codepoints ride in data
    try testing.expectEqual(@as(u32, 0x28), ast.node(ast.child(env, 0)).data);
    try testing.expectEqual(@as(u32, 0x29), ast.node(ast.child(env, 3)).data);
}

test "parser: array packs the colspec and rules skip column slots" {
    var ast = try parseSrc(testing.allocator, "\\begin{array}{l|r} a & b \\end{array}");
    defer ast.deinit();
    const env = ast.child(ast.root, 0);
    const en = ast.node(env);
    try testing.expectEqual(.env, en.tag);
    try testing.expectEqual(atom.EnvKind.array, atom.envKind(en.data));
    // spec [l, rule, r]: col 0 → l, col 1 → r, rule before col 1
    try testing.expectEqual(@as(usize, 3), atom.envSpecCount(en.data));
    try testing.expectEqual(@as(?u32, atom.EnvBits.col_l), atom.envColSpec(en.data, 0));
    try testing.expectEqual(@as(?u32, atom.EnvBits.col_rule), atom.envColSpec(en.data, 1));
    try testing.expectEqual(@as(?u32, atom.EnvBits.col_r), atom.envColSpec(en.data, 2));
}

test "parser: env errors" {
    try testing.expectError(error.UnknownEnvironment, parseSrc(testing.allocator, "\\begin{foo} x \\end{foo}"));
    try testing.expectError(error.MismatchedEnd, parseSrc(testing.allocator, "\\begin{pmatrix} a \\end{bmatrix}"));
    try testing.expectError(error.UnclosedEnvironment, parseSrc(testing.allocator, "\\begin{pmatrix} a"));
}

test "parser: & outside an environment is an ordinary char" {
    var ast = try parseSrc(testing.allocator, "a & b");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(@as(u16, 3), root.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(ast.root, 1)).tag);
}

/// The first atom of `src`, unwrapped through the root row.
fn firstAtom(ast: *const atom.Ast) u32 {
    return ast.child(ast.root, 0);
}

test "parser: \\overset / \\underset / \\stackrel build a [script, base] row" {
    const cases = [_]struct { src: []const u8, data: u32 }{
        .{ .src = "\\overset{a}{b}", .data = overset_row_data },
        .{ .src = "\\underset{a}{b}", .data = underset_row_data },
        .{ .src = "\\stackrel{a}{b}", .data = stackrel_row_data },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const row = ast.node(firstAtom(&ast));
        try testing.expectEqual(.row, row.tag);
        try testing.expectEqual(c.data, row.data);
        // The macro's argument order: #1 is the script, #2 the base.
        try testing.expectEqual(@as(u16, 2), row.num_children);
        const script = ast.child(firstAtom(&ast), 0);
        const base = ast.child(firstAtom(&ast), 1);
        try testing.expectEqual(.row, ast.node(script).tag);
        try testing.expectEqual(.row, ast.node(base).tag);
        // The macro's argument order: #1 is the script, #2 the base.
        const ss = ast.span(script);
        const bs = ast.span(base);
        try testing.expectEqualStrings("a", ast.src[ss.start..ss.end]);
        try testing.expectEqualStrings("b", ast.src[bs.start..bs.end]);
    }
}

test "parser: the phantom family carries its keep mask" {
    const cases = [_]struct { src: []const u8, keep: u32, smash: bool }{
        // \phantom keeps the width AND the vertical extent
        .{ .src = "\\phantom{ab}", .keep = keep_width | keep_vertical, .smash = false },
        .{ .src = "\\vphantom{ab}", .keep = keep_vertical, .smash = false },
        // \hphantom keeps only the width
        .{ .src = "\\hphantom{ab}", .keep = keep_width, .smash = false },
        // amsmath's \smash[<axes>] zeroes ht and/or dp and always keeps the
        // advance, so its default [tb] shares \hphantom's mask — the smash
        // bit is the ONLY thing that separates the two boxes.
        .{ .src = "\\smash{ab}", .keep = keep_width, .smash = true },
        .{ .src = "\\smash[tb]{ab}", .keep = keep_width, .smash = true },
        .{ .src = "\\smash[t]{ab}", .keep = keep_width | keep_depth, .smash = true },
        .{ .src = "\\smash[b]{ab}", .keep = keep_width | keep_height, .smash = true },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const row = ast.node(firstAtom(&ast));
        try testing.expectEqual(.row, row.tag);
        const smash: u32 = if (c.smash) smash_row else 0;
        try testing.expectEqual(phantom_row_data | smash | c.keep, row.data);
        try testing.expectEqual(@as(u16, 1), row.num_children);
    }
}

test "parser: only \\smash sets the keeps-content bit" {
    // \smash[tb] and \hphantom are byte-identical masks, so the bit is the
    // only discriminator layout has: set on EVERY \smash spelling, clear on
    // every \phantom spelling.
    const smashes = [_][]const u8{
        "\\smash{ab}", "\\smash[t]{ab}", "\\smash[b]{ab}", "\\smash[tb]{ab}",
    };
    for (smashes) |src| {
        var ast = try parseSrc(testing.allocator, src);
        defer ast.deinit();
        const row = ast.node(firstAtom(&ast));
        try testing.expect(row.data & smash_row != 0);
        try testing.expect(row.data & phantom_row_data != 0);
    }
    const phantoms = [_][]const u8{ "\\phantom{ab}", "\\hphantom{ab}", "\\vphantom{ab}" };
    for (phantoms) |src| {
        var ast = try parseSrc(testing.allocator, src);
        defer ast.deinit();
        const row = ast.node(firstAtom(&ast));
        try testing.expect(row.data & smash_row == 0);
    }
    // the bit is disjoint from every other row marker
    try testing.expectEqual(@as(u32, 0), smash_row & phantom_row_data);
    try testing.expectEqual(@as(u32, 0), smash_row & kern_row_data);
    try testing.expectEqual(@as(u32, 0), smash_row & tag_row_data);
    try testing.expectEqual(@as(u32, 0), smash_row & keep_width);
    try testing.expectEqual(@as(u32, 0), smash_row & keep_height);
    try testing.expectEqual(@as(u32, 0), smash_row & keep_depth);
}

test "parser: \\underbrace takes an optional subscript annotation" {
    var bare = try parseSrc(testing.allocator, "\\underbrace{x+y}");
    defer bare.deinit();
    const row = bare.node(firstAtom(&bare));
    try testing.expectEqual(underbrace_row_data, row.data);
    try testing.expectEqual(@as(u16, 1), row.num_children);

    var annotated = try parseSrc(testing.allocator, "\\underbrace{x+y}_{n}");
    defer annotated.deinit();
    const arow = annotated.node(firstAtom(&annotated));
    try testing.expectEqual(underbrace_row_data, arow.data);
    try testing.expectEqual(@as(u16, 2), arow.num_children);
    const content = annotated.node(annotated.child(firstAtom(&annotated), 0));
    try testing.expectEqual(@as(u16, 3), content.num_children); // x + y
    const ann = annotated.node(annotated.child(firstAtom(&annotated), 1));
    // A braced annotation is a script field: a `.group` over its content.
    try testing.expectEqual(.group, ann.tag);
    try testing.expectEqual(@as(u16, 1), ann.num_children);
    // Inside the group the annotation is the `n` field itself.
    const inner = annotated.child(annotated.child(firstAtom(&annotated), 1), 0);
    const ann_span = annotated.span(inner);
    try testing.expectEqualStrings("n", annotated.src[ann_span.start..ann_span.end]);

    var over = try parseSrc(testing.allocator, "\\overbrace{x}^{n}");
    defer over.deinit();
    try testing.expectEqual(overbrace_row_data, over.node(firstAtom(&over)).data);
    try testing.expectEqual(@as(u16, 2), over.node(firstAtom(&over)).num_children);
}

test "parser: \\kern / \\mkern / \\hspace carry the dimension's unit" {
    const cases = [_]struct { src: []const u8, unit: u32, value: f32 }{
        .{ .src = "\\kern2mu", .unit = dim_mu, .value = 2 },
        .{ .src = "\\mkern-1.5mu", .unit = dim_mu, .value = -1.5 },
        .{ .src = "\\hspace{4mu}", .unit = dim_mu, .value = 4 },
        .{ .src = "\\kern1em", .unit = dim_em, .value = 1 },
        .{ .src = "\\hspace{0.5ex}", .unit = dim_ex, .value = 0.5 },
        // A bare number is pt, as in TeX's scan_dimen.
        .{ .src = "\\kern2.5pt", .unit = dim_pt, .value = 2.5 },
        .{ .src = "\\hspace{3}", .unit = dim_pt, .value = 3 },
        // TeX's absolute conversions: 1in = 72.27pt, 1pc = 12pt.
        .{ .src = "\\kern1in", .unit = dim_pt, .value = 72.27 },
        .{ .src = "\\kern0.5pc", .unit = dim_pt, .value = 6 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const row = ast.node(firstAtom(&ast));
        try testing.expectEqual(.row, row.tag);
        try testing.expectEqual(kern_row_data | c.unit, row.data);
        // The magnitude rides in the single space child.
        const leaf = ast.node(ast.child(firstAtom(&ast), 0));
        try testing.expectEqual(.space, leaf.tag);
        try testing.expectApproxEqAbs(c.value, atom.fixedToEm(leaf.data), 1e-4);
    }
}

test "parser: \\: is the medium math space and \\  the interword space" {
    var colon = try parseSrc(testing.allocator, "x\\:y");
    defer colon.deinit();
    const kern = colon.node(colon.child(colon.root, 1));
    try testing.expectEqual(.row, kern.tag);
    try testing.expectEqual(kern_row_data | dim_mu, kern.data);
    const leaf = colon.node(colon.child(colon.child(colon.root, 1), 0));
    try testing.expectApproxEqAbs(@as(f32, 4), atom.fixedToEm(leaf.data), 1e-5);

    // The control space lexes as the one-byte command " " and reserves a third
    // of an em — the text font's interword space (measured 3.33pt at 10pt).
    var ctrl = try parseSrc(testing.allocator, "x\\ y");
    defer ctrl.deinit();
    const space = ctrl.node(ctrl.child(ctrl.root, 1));
    try testing.expectEqual(.space, space.tag);
    try testing.expectApproxEqAbs(@as(f32, 1) / 3.0, atom.fixedToEm(space.data), 1e-5);
}

test "parser: a malformed or missing dimension argument is a spanned error" {
    var info: parse_err.Info = undefined;
    // A non-brace argument: the span points at the offending token.
    try expectSpanError(&info, error.MissingArgument, "\\hspace x", .missing_argument);
    // Not a dimension at all — the span covers the text.
    try expectSpanError(&info, error.MissingArgument, "\\kern em", .missing_argument);
    try expectSpanError(&info, error.MissingArgument, "\\hspace{1zz}", .missing_argument);
    // An unclosed \hspace group reports at the opening brace.
    try expectSpanError(&info, error.UnclosedGroup, "\\hspace{1mu", .unclosed_group);
    // Missing arguments for the new constructs.
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\hspace"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\kern"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\overset{a}"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\underset{a}"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\stackrel{a}"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\underbrace"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\overbrace"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\phantom"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\smash"));
    // \smash's option must be a subset of t/b (amsmath's \csname mb@…\endcsname
    // on an undefined name).
    try expectSpanError(&info, error.MissingArgument, "\\smash[zz]{x}", .missing_argument);
}

/// Parse `src` expecting `err`, and check the reported kind and span: a
/// zero-width span is rejected, so every error must point at real bytes.
fn expectSpanError(
    info: *parse_err.Info,
    err: Error,
    src: []const u8,
    kind: parse_err.Kind,
) !void {
    var ast = atom.Ast.init(testing.allocator, src);
    defer ast.deinit();
    try lexer.lex(&ast, info);
    var p = Parser.init(testing.allocator, src, ast.tokens.items, info);
    try testing.expectError(err, p.parse(&ast));
    try testing.expectEqual(kind, info.kind);
    try testing.expect(info.span.end > info.span.start);
    try testing.expect(info.span.end <= src.len);
}

test "parser: \\arraystretch stamps its factor on the next env's first row" {
    // The assignment is a zero-width space leaf in the enclosing row ...
    var ast = try parseSrc(testing.allocator, "\\arraystretch{1.4}\\begin{matrix}a\\\\b\\end{matrix}");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(@as(u16, 2), root.num_children);
    const leaf = ast.child(ast.root, 0);
    try testing.expectEqual(.space, ast.node(leaf).tag);
    try testing.expectEqual(@as(f32, 0), atom.fixedToEm(ast.node(leaf).data));
    // ... and the factor rides on the environment's first row.
    const env = ast.child(ast.root, 1);
    try testing.expectEqual(.env, ast.node(env).tag);
    const row0 = ast.node(ast.child(env, 0));
    try testing.expectEqual(.row, row0.tag);
    const factor = atom.rowStretch(row0.data) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 1.4), factor, 1e-6);
    // Only the FIRST row carries it; the rest keep the "unset" encoding.
    try testing.expectEqual(@as(u32, 0), ast.node(ast.child(env, 1)).data);
}

test "parser: an environment without \\arraystretch keeps the unset encoding" {
    var ast = try parseSrc(testing.allocator, "\\begin{cases}a\\\\b\\end{cases}");
    defer ast.deinit();
    const env = firstAtom(&ast);
    // cases brackets its rows with a `{` delimiter leaf, so row 0 is child 1.
    try testing.expectEqual(.char, ast.node(ast.child(env, 0)).tag);
    try testing.expectEqual(@as(u32, 0), ast.node(ast.child(env, 1)).data);
    try testing.expect(atom.rowStretch(0) == null);
}

test "parser: \\arraystretch rejects a non-numeric factor with a span" {
    var info: parse_err.Info = undefined;
    try expectSpanError(
        &info,
        error.MissingArgument,
        "\\arraystretch{two}\\begin{matrix}a\\end{matrix}",
        .missing_argument,
    );
    try expectSpanError(
        &info,
        error.MissingArgument,
        "\\arraystretch{}\\begin{matrix}a\\end{matrix}",
        .missing_argument,
    );
}

test "parser: \\tag is a row of the braced argument in a roman scope" {
    var ast = try parseSrc(testing.allocator, "x=1 \\tag{3}");
    defer ast.deinit();
    // The \tag row is the THIRD atom of the enclosing row — "first atom" is
    // the `x` char leaf — so pick the node the tag marker actually marks.
    const root = ast.node(ast.root);
    var marked: ?u32 = null;
    for (0..root.num_children) |i| {
        const cn = ast.node(ast.child(ast.root, i));
        if (cn.tag == .row and cn.data == tag_row_data) {
            marked = ast.child(ast.root, i);
            break;
        }
    }
    const tag_node = marked orelse return error.TestUnexpectedResult;
    const row = ast.node(tag_node);
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(tag_row_data, row.data);
    try testing.expectEqual(@as(u16, 1), row.num_children);
    // The whole construct's span, byte for byte out of the original input,
    // so the drawn glyphs lie inside `\tag{3}`.
    const sp = ast.span(tag_node);
    try testing.expectEqual(@as(u32, 4), sp.start);
    try testing.expectEqual(@as(u32, 11), sp.end);
    try testing.expectEqualStrings("\\tag{3}", ast.src[sp.start..sp.end]);
    const styled_idx = ast.child(tag_node, 0);
    const styled = ast.node(styled_idx);
    try testing.expectEqual(.styled, styled.tag);
    try testing.expectEqual(@intFromEnum(atom.CharStyle.roman), styled.data);
    // The argument keeps its OWN token span, so its glyph aliases the real
    // source bytes instead of a synthesized copy.
    const arg = ast.node(ast.child(styled_idx, 0));
    try testing.expectEqual(.row, arg.tag);
    const arg_sp = ast.span(styled_idx);
    try testing.expectEqualStrings("3", ast.src[arg_sp.start..arg_sp.end]);
}

test "parser: \\tag requires its braced argument" {
    var info: parse_err.Info = undefined;
    try expectSpanError(&info, error.MissingArgument, "x \\tag", .missing_argument);
    try expectSpanError(&info, error.UnclosedGroup, "x \\tag{3", .unclosed_group);
}

test "parser: \\widehat / \\widetilde build a [base, mark] wide-accent row" {
    const cases = [_]struct { src: []const u8, data: u32, mark: u21 }{
        .{ .src = "\\widehat{abc}", .data = wide_hat_row_data, .mark = 0x0302 },
        .{ .src = "\\widetilde{abc}", .data = wide_tilde_row_data, .mark = 0x0303 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const wide = firstAtom(&ast);
        const row = ast.node(wide);
        try testing.expectEqual(.row, row.tag);
        try testing.expectEqual(c.data, row.data);
        try testing.expectEqual(@as(u16, 2), row.num_children);
        // The base is the braced group; the mark is a char leaf carrying the
        // combining codepoint in `data`, exactly like \hat / \tilde.
        try testing.expectEqual(.group, ast.node(ast.child(wide, 0)).tag);
        const mark = ast.node(ast.child(wide, 1));
        try testing.expectEqual(.char, mark.tag);
        try testing.expectEqual(c.mark, @as(u21, @truncate(mark.data)));
        const sp = ast.span(wide);
        try testing.expectEqualStrings(c.src, ast.src[sp.start..sp.end]);
    }
    // The markers must not collide with the rows layoutInner routes on.
    try testing.expect(wide_hat_row_data != accent_row_data);
    try testing.expect(wide_tilde_row_data != wide_hat_row_data);
    try testing.expectEqual(@as(u32, 0), wide_hat_row_data & phantom_row_data);
    try testing.expectEqual(@as(u32, 0), wide_tilde_row_data & phantom_row_data);
    try testing.expectEqual(@as(u32, 0), wide_hat_row_data & kern_row_data);
    try testing.expectEqual(@as(u32, 0), tag_row_data & (phantom_row_data | kern_row_data));
}

test "parser: a bare \\kern dimension stops before the next atom" {
    // The scan is a number plus a recognized unit, not a greedy run of char
    // tokens: `\kern 2mu+y` used to be read as the text `2mu+y` and fail.
    const cases = [_]struct { src: []const u8, unit: u32, value: f32 }{
        .{ .src = "x+\\kern 2mu+y", .unit = dim_mu, .value = 2 },
        .{ .src = "x+\\kern1em+y", .unit = dim_em, .value = 1 },
        .{ .src = "x+\\kern 3pt+\\alpha", .unit = dim_pt, .value = 3 },
        .{ .src = "x+\\kern 2mu", .unit = dim_mu, .value = 2 },
        .{ .src = "x+\\mkern-2.5mu", .unit = dim_mu, .value = -2.5 },
        // TeX's scan_units stops as soon as the letters spell a unit, so the
        // trailing `u` is an ordinary atom, not a rejected dimension.
        .{ .src = "x+\\kern 2emu", .unit = dim_em, .value = 2 },
        // The same constructs at the START of the source, where the run is
        // terminated by the following operator rather than by end of input.
        .{ .src = "\\kern2mu+y", .unit = dim_mu, .value = 2 },
        .{ .src = "\\kern 3pt+\\alpha", .unit = dim_pt, .value = 3 },
        // A bare number is still TeX's pt default when the run ENDS it.
        .{ .src = "\\kern 2", .unit = dim_pt, .value = 2 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const root = ast.node(ast.root);
        var found = false;
        for (0..root.num_children) |i| {
            const cn = ast.node(ast.child(ast.root, i));
            if (cn.tag == .row and cn.data & kern_row_data != 0) {
                try testing.expectEqual(kern_row_data | c.unit, cn.data);
                const leaf = ast.node(ast.child(ast.child(ast.root, i), 0));
                try testing.expectApproxEqAbs(c.value, atom.fixedToEm(leaf.data), 1e-5);
                found = true;
            }
        }
        try testing.expect(found);
    }
}

test "parser: a bare \\kern with no legal unit fails with a span" {
    var info: parse_err.Info = undefined;
    // No unit at all, and a unit no accepted name starts with — TeX's
    // "Illegal unit of measure", reported at the scanned run.
    try expectSpanError(&info, error.MissingArgument, "x+\\kern 2+y", .missing_argument);
    try expectSpanError(&info, error.MissingArgument, "x+\\kern 2zz", .missing_argument);
    try expectSpanError(&info, error.MissingArgument, "x+\\kern 2e", .missing_argument);
    // The unit set is unchanged: TeX's px/dd/cc/sp/nd/nc stay rejected.
    try expectSpanError(&info, error.MissingArgument, "x+\\kern 2px", .missing_argument);
    // The braced form still takes everything between the braces.
    try expectSpanError(&info, error.MissingArgument, "\\hspace{2zz}", .missing_argument);
}

test "parser: a bare \\kern run with no unit reports the run's own span" {
    var info: parse_err.Info = undefined;
    const src = "x+\\kern 2+y";
    try expectSpanError(&info, error.MissingArgument, src, .missing_argument);
    // The caret covers the scanned run — the digits whose unit is missing —
    // not the operator that proved the run never ended.
    try testing.expectEqualStrings("2", src[info.span.start..info.span.end]);
}

// ── supported_commands ──────────────────────────

/// Independent comptime recomputation of the DISTINCT command count across
/// the four dispatch tables. `supported_commands` is built from these same
/// tables, so this is the ground truth its length must equal — it keeps the
/// coverage test from merely echoing the list's own length (a hand-added
/// entry without a backing table would break the length match).
const supported_distinct_count: usize = blk: {
    // O(n²) byte-compare over ~230 names exceeds the default 1000-branch
    // comptime eval budget.
    @setEvalBranchQuota(400_000);
    const tables = [_][]const []const u8{
        cmd_map.keys(),
        mathstyle_map.keys(),
        symbol_map.keys(),
        delim_map.keys(),
    };
    var total: usize = 0;
    for (tables) |t| total += t.len;
    var names: [total][]const u8 = undefined;
    var n: usize = 0;
    for (tables) |t| for (t) |k| {
        names[n] = k;
        n += 1;
    };
    var dups: usize = 0;
    for (0..n) |i| {
        var seen_before = false;
        for (0..i) |j| {
            if (std.mem.eql(u8, names[i], names[j])) {
                seen_before = true;
                break;
            }
        }
        if (seen_before) dups += 1;
    }
    break :blk total - dups;
};

test "parser: \\dbinom and \\tbinom are \\binom with a FORCED style" {
    // Both are \genfrac{(}{)}{0pt}{0|1}{n}{d}: a ruleless fraction inside a
    // synthetic paren fence marked as amsmath-delimited, and the ONLY
    // difference is the forced style — which layout turns into both the
    // parts' size and the fixed fence the parens are boxed by.
    const cases = [_]struct { src: []const u8, forced: atom.MathStyle }{
        .{ .src = "\\dbinom{n}{k}", .forced = .display },
        .{ .src = "\\tbinom{n}{k}", .forced = .text },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const left_idx = ast.child(ast.root, 0);
        const left = ast.node(left_idx);
        try testing.expectEqual(.left, left.tag);
        try testing.expectEqual(@as(u16, 3), left.num_children);
        // the fence leaves carry the paren codepoints, like \binom's
        try testing.expectEqual(@as(u32, 0x28), ast.node(ast.child(left_idx, 0)).data);
        try testing.expectEqual(@as(u32, 0x29), ast.node(ast.child(left_idx, 2)).data);
        const frac = ast.node(ast.child(left_idx, 1));
        try testing.expectEqual(.fraction, frac.tag);
        try testing.expect(!atom.fracLine(frac.data)); // 0pt: no rule
        try testing.expect(atom.fracFixedDelim(frac.data));
        const forced = atom.fracForcedStyle(frac.data) orelse
            return error.TestExpectedEqual;
        try testing.expectEqual(c.forced, forced);
    }
    // \binom itself keeps the CURRENT style (both references leave \genfrac's
    // style arg empty) — the forced variants must not have changed it.
    var plain = try parseSrc(testing.allocator, "\\binom{n}{k}");
    defer plain.deinit();
    const pf = plain.node(plain.child(plain.child(plain.root, 0), 1));
    try testing.expect(atom.fracFixedDelim(pf.data));
    try testing.expect(atom.fracForcedStyle(pf.data) == null);
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\dbinom{n}"));
}

test "parser: the big operators parse to .op leaves with their BigOp" {
    const cases = [_]struct { src: []const u8, which: atom.BigOp }{
        .{ .src = "\\bigodot", .which = .bigodot },
        .{ .src = "\\bigoplus", .which = .bigoplus },
        .{ .src = "\\bigotimes", .which = .bigotimes },
        .{ .src = "\\biguplus", .which = .biguplus },
        .{ .src = "\\bigsqcap", .which = .bigsqcap },
        .{ .src = "\\bigwedge", .which = .bigwedge },
        .{ .src = "\\bigvee", .which = .bigvee },
        .{ .src = "\\bigstar", .which = .bigstar },
        .{ .src = "\\bigint", .which = .bigint },
        .{ .src = "\\bigiint", .which = .bigiint },
        .{ .src = "\\bigiiint", .which = .bigiiint },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const op = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.op, op.tag);
        try testing.expectEqual(@as(u32, @intFromEnum(c.which)), op.data);
        // A big operator takes scripts like any atom (\bigwedge_{i}).
        var buf: [32]u8 = undefined;
        const scripted_src = try std.fmt.bufPrint(&buf, "{s}_{{i}}", .{c.src});
        var scripted = try parseSrc(testing.allocator, scripted_src);
        defer scripted.deinit();
        const script_idx = scripted.child(scripted.root, 0);
        try testing.expectEqual(.script, scripted.node(script_idx).tag);
        try testing.expectEqual(.op, scripted.node(scripted.child(script_idx, 0)).tag);
    }
}

test "parser: \\mathop is a roman operator word with no limits" {
    // TeX's \mathop takes a math FIELD: \mathop{ab} wraps the group, while
    // \mathop a takes the single bare atom. Either way the result is the
    // `.opname` model — one child, laid out roman, class op — with `data` 0,
    // i.e. NO display limits (unlike \lim, whose name is in limitOpName).
    for ([_][]const u8{ "\\mathop{ab}", "\\mathop a" }) |src| {
        var ast = try parseSrc(testing.allocator, src);
        defer ast.deinit();
        const opn = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.opname, opn.tag);
        try testing.expectEqual(@as(u16, 1), opn.num_children);
        try testing.expectEqual(@as(u32, 0), opn.data);
    }
    // \mathop\lim is the op word `lim` as a field, NOT the limit-taking
    // `\lim` command (which is a different atom with its own limits).
    var wrapped = try parseSrc(testing.allocator, "\\mathop\\lim");
    defer wrapped.deinit();
    const w = wrapped.node(wrapped.child(wrapped.root, 0));
    try testing.expectEqual(.opname, w.tag);
    try testing.expectEqual(@as(u32, 0), w.data);
}

test "parser: the \\mathXXX family wraps a math field in a class row" {
    // A math FIELD, not a braced argument: `\mathord a` and `\mathbin{a}`
    // both parse, and the wrapper carries the class in its `data` with the
    // field as its ONLY child.
    const cases = [_]struct { src: []const u8, cls: atom.MathClass }{
        .{ .src = "\\mathord{a}", .cls = .ord },
        .{ .src = "\\mathrel{a}", .cls = .rel },
        .{ .src = "\\mathbin{a}", .cls = .bin },
        .{ .src = "\\mathopen{a}", .cls = .open },
        .{ .src = "\\mathclose{a}", .cls = .close },
        .{ .src = "\\mathpunct{a}", .cls = .punct },
        .{ .src = "\\mathinner{a}", .cls = .inner },
        .{ .src = "\\mathord a", .cls = .ord },
        .{ .src = "\\mathbin a", .cls = .bin },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const row = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.row, row.tag);
        try testing.expect(atom.isClassRow(row.data));
        try testing.expectEqual(c.cls, atom.classRowClass(row.data));
        try testing.expectEqual(@as(u16, 1), row.num_children);
        try testing.expectEqual(atom.classRowData(c.cls), row.data);
    }
    try testing.expectError(error.MissingScript, parseSrc(testing.allocator, "\\mathrel"));
    try testing.expectError(error.MissingScript, parseSrc(testing.allocator, "\\mathbin"));
}

test "parser: \\colon is punctuation while a bare : is a plain char" {
    // plain TeX: `\def\colon{\mathpunct{:}}`. The GLYPH is the same colon, so
    // \colon is a class row around a `:` char leaf, while a typed `:` stays a
    // bare char atom (whose class layout derives from the codepoint).
    var ast = try parseSrc(testing.allocator, "a\\colon b");
    defer ast.deinit();
    const row_idx = ast.child(ast.root, 1);
    const row = ast.node(row_idx);
    try testing.expectEqual(.row, row.tag);
    try testing.expectEqual(atom.classRowData(.punct), row.data);
    const inner = ast.node(ast.child(row_idx, 0));
    try testing.expectEqual(.char, inner.tag);
    try testing.expectEqual(@as(u32, 0x3A), inner.data);

    var plain = try parseSrc(testing.allocator, "a:b");
    defer plain.deinit();
    const colon = plain.node(plain.child(plain.root, 1));
    try testing.expectEqual(.char, colon.tag);
    try testing.expect(!atom.isClassRow(colon.data));
}

test "parser: the colon relation family maps to the unicode-math glyphs" {
    // \coloneqq / \Coloneqq are mathtools' `:=` / `::=`, which unicode-math
    // spells \coloneq (U+2254) and \Coloneq (U+2A74); Latin Modern Math has no
    // U+2A74, so \Coloneqq falls back to the single-glyph COLON EQUALS. Every
    // one of them is a plain char leaf — a relation, classified in layout.
    const cases = [_]struct { src: []const u8, cp: u21 }{
        .{ .src = "\\coloneqq", .cp = 0x2254 },
        .{ .src = "\\coloneqqs", .cp = 0x2254 },
        .{ .src = "\\Coloneqq", .cp = 0x2254 },
        .{ .src = "\\Coloneqqs", .cp = 0x2254 },
        .{ .src = "\\coloneq", .cp = 0x2255 },
        .{ .src = "\\Colon", .cp = 0x2237 },
        .{ .src = "\\ratio", .cp = 0x2236 },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const leaf = ast.node(ast.child(ast.root, 0));
        try testing.expectEqual(.char, leaf.tag);
        try testing.expectEqual(c.cp, leaf.data);
    }
}

test "parser: supported_commands is exactly the union of the four tables" {
    // 1. Every table key appears in the list — the tables are the source of
    // truth, and dropping one from the union fails here.
    inline for (.{ cmd_map, mathstyle_map, symbol_map, delim_map }) |m| {
        for (m.keys()) |k| {
            var found = false;
            for (supported_commands) |s| {
                if (std.mem.eql(u8, s, k)) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
    }
    // 2. Every list entry is backed by at least one table: a hand-written
    // entry with no backing map fails here (the audit's coverage guard).
    for (supported_commands) |s| {
        try testing.expect(
            cmd_map.has(s) or mathstyle_map.has(s) or symbol_map.has(s) or delim_map.has(s),
        );
    }
    // 3. The list is a true SET: no name repeats (cross-table duplicates
    // collapse to one entry).
    for (supported_commands, 0..) |s, i| {
        for (supported_commands[0..i]) |prev| {
            try testing.expect(!std.mem.eql(u8, s, prev));
        }
    }
    // 4. Independent count check: length == recomputed distinct union size.
    try testing.expectEqual(@as(usize, supported_distinct_count), supported_commands.len);
}

test "parser: command dispatch is unambiguous (collision test)" {
    // The tables consulted when a command appears in ATOM position
    // (parseRow → parseSingleAtom → parseCommand, plus the inline mathstyle
    // interception in parseRow/parseScriptArg) must be pairwise disjoint: a
    // name in two of them would be ambiguous dispatch. delim_map is
    // consulted ONLY by parseDelimiter (after \left/\right/\big/\genfrac) —
    // a separate context — so it may reuse symbol names, but it must not
    // collide with the atom-position tables, and its symbol reuse is pinned
    // to the documented set below.
    for (cmd_map.keys()) |k| {
        try testing.expect(!mathstyle_map.has(k));
        try testing.expect(!symbol_map.has(k));
        try testing.expect(!delim_map.has(k));
    }
    for (mathstyle_map.keys()) |k| {
        try testing.expect(!symbol_map.has(k));
        try testing.expect(!delim_map.has(k));
    }
    // symbol_map ↔ delim_map reuse is INTENTIONAL (delimiter words that are
    // also standalone symbols, e.g. \langle); pin it so an accidental new
    // overlap fails the test.
    const intended_reuse = [_][]const u8{
        "langle", "rangle", "lfloor", "rfloor", "lceil",     "rceil",
        "lbrace", "rbrace", "vert",   "Vert",   "backslash",
    };
    var reused: usize = 0;
    for (delim_map.keys()) |k| {
        if (!symbol_map.has(k)) continue;
        var found = false;
        for (intended_reuse) |r| {
            if (std.mem.eql(u8, k, r)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
        reused += 1;
    }
    try testing.expectEqual(@as(usize, intended_reuse.len), reused);
}

test "parser: every cmd_map command is reachable through dispatch" {
    // For every command name in cmd_map, a minimal parse that routes through
    // the command dispatcher must recognize it: the outcome is either a
    // successful parse or a recognized parse error — never
    // error.UnknownCommand (the unknown-command path). Argument-taking
    // commands (\frac{}{}, \sqrt{}, \operatorname{}, \text{}, styles...)
    // fail on their MISSING required argument when parsed bare, which is a
    // recognized error and still PROVES the name reached the cmd_map
    // dispatch (a name absent from cmd_map and symbol_map would be the
    // UnknownCommand path). Success is the strongest assertion; a recognized
    // non-unknown error is the documented weaker one for argument-taking
    // commands — chosen to avoid reimplementing the grammar.
    for (cmd_map.keys()) |k| {
        var src_buf: [64]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "\\{s}", .{k}) catch unreachable;
        if (parseSrc(testing.allocator, src)) |ast| {
            var owned = ast;
            owned.deinit();
        } else |err| {
            try testing.expect(err != error.UnknownCommand);
        }
    }
}

test "parser: symbol and mathstyle tables are reachable too" {
    // Light reachability check for the two tables that dispatch OUTSIDE
    // cmd_map: a symbol name (\alpha) parses to a char leaf, and a style
    // switch (\displaystyle) wraps the rest of the group rather than
    // failing as unknown.
    var ast = try parseSrc(testing.allocator, "\\alpha");
    defer ast.deinit();
    try testing.expectEqual(.char, ast.node(ast.child(ast.root, 0)).tag);

    var ast2 = try parseSrc(testing.allocator, "\\displaystyle x");
    defer ast2.deinit();
    try testing.expectEqual(.mathstyle, ast2.node(ast2.child(ast2.root, 0)).tag);
}

test "parser: \\boxed frames exactly one math field" {
    // A math FIELD, like \overline: the braced group is the usual form and
    // a bare atom is accepted; either way ONE child.
    for ([_][]const u8{ "\\boxed{x}", "\\boxed x", "\\boxed{\\frac{a}{b}}" }) |src| {
        var ast = try parseSrc(testing.allocator, src);
        defer ast.deinit();
        const boxed = ast.node(firstAtom(&ast));
        try testing.expectEqual(.boxed, boxed.tag);
        try testing.expectEqual(@as(u16, 1), boxed.num_children);
        try testing.expectEqual(@as(u32, 0), boxed.data);
    }
    // The span covers the command through the end of the field.
    var ast = try parseSrc(testing.allocator, "\\boxed{xy}");
    defer ast.deinit();
    const span = ast.span(firstAtom(&ast));
    try testing.expectEqualStrings("\\boxed{xy}", ast.src[span.start..span.end]);
    // A script after the frame attaches to the frame, like any base.
    var scripted = try parseSrc(testing.allocator, "\\boxed{x}^2");
    defer scripted.deinit();
    try testing.expectEqual(.script, scripted.node(firstAtom(&scripted)).tag);
    try testing.expectError(error.MissingScript, parseSrc(testing.allocator, "\\boxed"));
}

test "parser: \\textcolor colors its argument only, with the full span" {
    var ast = try parseSrc(testing.allocator, "a\\textcolor{red}{b}c");
    defer ast.deinit();
    // The color node is the SECOND atom; `a` and `c` stay uncolored.
    const root = ast.node(ast.root);
    try testing.expectEqual(@as(u16, 3), root.num_children);
    const scope = ast.node(ast.child(ast.root, 1));
    try testing.expectEqual(.textcolor, scope.tag);
    try testing.expectEqual(@as(u16, 1), scope.num_children);
    try testing.expectEqual(atom.colorData(.{ .r = 255, .g = 0, .b = 0 }), scope.data);
    // the node spans the whole command, spec and argument
    const span = ast.span(ast.child(ast.root, 1));
    try testing.expectEqualStrings("\\textcolor{red}{b}", ast.src[span.start..span.end]);
    // the single child is the argument's own content
    const arg = ast.span(ast.child(ast.child(ast.root, 1), 0));
    try testing.expectEqualStrings("b", ast.src[arg.start..arg.end]);
}

test "parser: the atoms before a \\color declaration stay outside its scope" {
    // At the top level the scope runs to the end of the root row, so the
    // atoms BEFORE the declaration are outside it.
    var ast = try parseSrc(testing.allocator, "a\\color{red}bc");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(@as(u16, 2), root.num_children);
    const scope = ast.node(ast.child(ast.root, 1));
    try testing.expectEqual(.color, scope.tag);
    try testing.expectEqual(@as(u16, 1), scope.num_children);
    // the scope's one child is the REST of the row, `bc`
    const rest = ast.span(ast.child(ast.child(ast.root, 1), 0));
    try testing.expectEqualStrings("bc", ast.src[rest.start..rest.end]);
    // the scope itself spans `\color{red}bc`
    const span = ast.span(ast.child(ast.root, 1));
    try testing.expectEqualStrings("\\color{red}bc", ast.src[span.start..span.end]);
}

test "parser: a color declaration with nothing after it still has a span" {
    // The sub-row is empty, so the node's token range must come from the
    // command and its spec — a zero-token node would lose its provenance.
    var ast = try parseSrc(testing.allocator, "\\color{red}");
    defer ast.deinit();
    const scope = ast.node(firstAtom(&ast));
    try testing.expectEqual(.color, scope.tag);
    const span = ast.span(firstAtom(&ast));
    try testing.expectEqualStrings("\\color{red}", ast.src[span.start..span.end]);
}

test "parser: color specs accept names, hex, and the transparent forms" {
    const cases = [_]struct { src: []const u8, color: atom.Color }{
        .{ .src = "\\color{red}x", .color = .{ .r = 255, .g = 0, .b = 0 } },
        .{ .src = "\\color{green}x", .color = .{ .r = 0, .g = 128, .b = 0 } },
        .{ .src = "\\color{#00ff00}x", .color = .{ .r = 0, .g = 255, .b = 0 } },
        .{ .src = "\\color{#0000ff80}x", .color = .{ .r = 0, .g = 0, .b = 255, .a = 128 } },
        // `none` / `transparent` are TRANSPARENT INK here, not "no scope":
        // the scope exists and its color really is {0,0,0,0}.
        .{ .src = "\\color{none}x", .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
        .{ .src = "\\color{transparent}x", .color = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const scope = ast.node(firstAtom(&ast));
        try testing.expectEqual(.color, scope.tag);
        try testing.expectEqual(c.color, atom.nodeColor(scope.data));
    }
}

test "parser: a malformed color spec is a spanned error" {
    var info: parse_err.Info = undefined;
    // no brace at all: the offending token is the one that should have
    // opened the spec
    try expectSpanError(&info, error.MissingArgument, "\\color red", .missing_argument);
    // an empty spec has no color to name
    try expectSpanError(&info, error.MissingArgument, "\\color{}x", .missing_argument);
    // the group is never closed
    try expectSpanError(&info, error.UnclosedGroup, "\\color{red", .unclosed_group);
    try expectSpanError(&info, error.UnclosedGroup, "\\color{red x", .unclosed_group);
    // an undefined name: the span covers the spec text itself
    try expectSpanError(&info, error.UnknownCommand, "\\color{blak}x", .unknown_command);
    // a bad hex digit is the same failure as a bad name
    try expectSpanError(&info, error.UnknownCommand, "\\color{#zz0000}x", .unknown_command);
    // \textcolor needs BOTH arguments; the missing one at end of input has no
    // offending token, so only the error VALUE is assertable there.
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\textcolor{red}"));
    try expectSpanError(&info, error.UnclosedGroup, "\\textcolor{red}{x", .unclosed_group);
    // the caret must point at the spec, not at the whole construct
    var ast = atom.Ast.init(testing.allocator, "\\color{blak}x");
    defer ast.deinit();
    try lexer.lex(&ast, &info);
    var p = Parser.init(testing.allocator, ast.src, ast.tokens.items, &info);
    try testing.expectError(error.UnknownCommand, p.parse(&ast));
    try testing.expectEqualStrings("blak", ast.src[info.span.start..info.span.end]);
}

test "parser: \\text / \\textit / \\textbf are one raw text leaf in the requested face" {
    const cases = [_]struct {
        src: []const u8,
        style: atom.CharStyle,
        span: []const u8,
        text: []const u8,
    }{
        .{ .src = "\\text{ab}", .style = .roman, .span = "{ab}", .text = "ab" },
        .{ .src = "\\textit{ab}", .style = .text_italic, .span = "{ab}", .text = "ab" },
        .{ .src = "\\textbf{ab}", .style = .bold, .span = "{ab}", .text = "ab" },
        // an empty run is legal and still a leaf
        .{ .src = "\\textit{}", .style = .text_italic, .span = "{}", .text = "" },
        // a partial nest stays in the run's bytes; the leaf still carries the
        // OUTER face (the inner scopes are layout's)
        .{
            .src = "\\textbf{a\\textit{b}c}",
            .style = .bold,
            .span = "{a\\textit{b}c}",
            .text = "a\\textit{b}c",
        },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const leaf = ast.node(firstAtom(&ast));
        try testing.expectEqual(.text, leaf.tag);
        try testing.expectEqual(@as(u16, 0), leaf.num_children);
        try testing.expectEqual(@as(u32, @intFromEnum(c.style)), leaf.data);
        // The span is the run's OWN braces: the command is consumed (never
        // typeset), and the drawn bytes are everything between the braces.
        const span = ast.span(firstAtom(&ast));
        try testing.expectEqualStrings(c.span, ast.src[span.start..span.end]);
        try testing.expectEqualStrings(c.text, ast.src[span.start + 1 .. span.end - 1]);
    }
}

test "parser: a nested text face is one run, and the outer cursor resumes after it" {
    // Whole-argument and partial nests are the SAME leaf: the run keeps its raw
    // bytes and the face it carries is the outer command's. The face scopes
    // inside the run are layout's, not the parser's.
    const cases = [_]struct { src: []const u8, style: atom.CharStyle }{
        .{ .src = "\\textit{\\textbf{ab}}", .style = .text_italic },
        .{ .src = "\\textbf{\\textit{ab}}", .style = .bold },
        .{ .src = "\\textit{\\textbf{\\textit{ab}}}", .style = .text_italic },
        .{ .src = "\\textit{\\text{ab}}", .style = .text_italic },
        .{ .src = "\\text{a\\textit{b}c}", .style = .roman },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const leaf = ast.node(firstAtom(&ast));
        try testing.expectEqual(.text, leaf.tag);
        try testing.expectEqual(@as(u16, 0), leaf.num_children);
        try testing.expectEqual(@as(u32, @intFromEnum(c.style)), leaf.data);
        const span = ast.span(firstAtom(&ast));
        try testing.expectEqual(c.src.len, @as(usize, span.end));
        try testing.expectEqual(@as(u8, '{'), c.src[span.start]);
        try testing.expectEqual(@as(u8, '}'), c.src[span.end - 1]);
    }
    // The run is consumed whole, so what follows it is still the next atom of
    // the row — the inner group's `}` never ends the run early.
    var ast = try parseSrc(testing.allocator, "\\textbf{a\\textit{b}c}x");
    defer ast.deinit();
    const root = ast.node(ast.root);
    try testing.expectEqual(@as(u16, 2), root.num_children);
    const run = ast.node(ast.child(ast.root, 0));
    try testing.expectEqual(.text, run.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(atom.CharStyle.bold)), run.data);
    const tail = ast.node(ast.child(ast.root, 1));
    try testing.expectEqual(.char, tail.tag);
    const tail_span = ast.span(ast.child(ast.root, 1));
    try testing.expectEqualStrings("x", ast.src[tail_span.start..tail_span.end]);
}

test "parser: a text run deeper than the face-scope bound is NestingTooDeep" {
    // Layout opens a face scope per nested group inside the run, in a fixed
    // stack of `atom.max_text_nesting`, so a deeper run has no representation.
    var info: parse_err.Info = undefined;
    const over = atom.max_text_nesting + 8;
    const deep = "\\text{" ++ "{" ** over ++ "a" ++ "}" ** over ++ "}";
    try expectSpanError(&info, error.NestingTooDeep, deep, .nesting_too_deep);
    // the run's own brace counts as one level, so the bound is inclusive
    const within = atom.max_text_nesting - 1;
    const ok = "\\text{" ++ "{" ** within ++ "a" ++ "}" ** within ++ "}";
    var ast = try parseSrc(testing.allocator, ok);
    defer ast.deinit();
    const span = ast.span(firstAtom(&ast));
    try testing.expectEqual(ok.len, @as(usize, span.end));
}

test "parser: a text face needs its braced run" {
    var info: parse_err.Info = undefined;
    // At end of input there is no offending token, so only the error VALUE
    // is assertable (the Info span is the documented zero-width EOF caret).
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\textit"));
    try testing.expectError(error.MissingArgument, parseSrc(testing.allocator, "\\textbf"));
    // a bare atom is not a run: \textit takes a mandatory group
    try expectSpanError(&info, error.MissingArgument, "\\textit ab", .missing_argument);
    // the run must close
    try expectSpanError(&info, error.UnclosedGroup, "\\textit{ab", .unclosed_group);
    // nested braces are balanced, not taken literally
    var ast = try parseSrc(testing.allocator, "\\textit{a{b}c}");
    defer ast.deinit();
    const span = ast.span(firstAtom(&ast));
    try testing.expectEqualStrings("a{b}c", ast.src[span.start + 1 .. span.end - 1]);
}

test "parser: \\hline is a rule entry BETWEEN rows, never a row" {
    const cases = [_]struct {
        src: []const u8,
        want: []const atom.Tag,
    }{
        // leading rule, then two rows
        .{
            .src = "\\begin{array}{cc}\\hline a&b\\\\c&d\\end{array}",
            .want = &.{ .hline, .row, .row },
        },
        // intermediate rule
        .{
            .src = "\\begin{array}{cc}a&b\\\\\\hline c&d\\end{array}",
            .want = &.{ .row, .hline, .row },
        },
        // trailing rule
        .{
            .src = "\\begin{array}{cc}a&b\\\\c&d\\\\\\hline\\end{array}",
            .want = &.{ .row, .row, .hline },
        },
        // leading AND trailing: the integration case
        .{
            .src = "\\begin{array}{cc}\\hline a&b\\\\\\hline c&d\\\\\\hline\\end{array}",
            .want = &.{ .hline, .row, .hline, .row, .hline },
        },
        // repeated rules stay separate entries
        .{
            .src = "\\begin{matrix}a\\\\\\hline\\hline b\\end{matrix}",
            .want = &.{ .row, .hline, .hline, .row },
        },
        // no rules at all: unchanged
        .{
            .src = "\\begin{matrix}a\\\\b\\end{matrix}",
            .want = &.{ .row, .row },
        },
    };
    for (cases) |c| {
        var ast = try parseSrc(testing.allocator, c.src);
        defer ast.deinit();
        const env = ast.child(ast.root, 0);
        try testing.expectEqual(.env, ast.node(env).tag);
        const env_node = ast.node(env);
        try testing.expectEqual(c.want.len, @as(usize, env_node.num_children));
        for (c.want, 0..) |tag, i| {
            const entry = ast.node(ast.child(env, i));
            try testing.expectEqual(tag, entry.tag);
            // a rule is a LEAF: it has no cells and no row of its own
            if (tag == .hline) try testing.expectEqual(@as(u16, 0), entry.num_children);
        }
    }
}

test "parser: a rule entry keeps the environment's delimiters outside it" {
    // pmatrix brackets the ENTRIES, so a rule must not be mistaken for a
    // closing delimiter.
    var ast = try parseSrc(
        testing.allocator,
        "\\begin{pmatrix}\\hline a\\\\b\\end{pmatrix}",
    );
    defer ast.deinit();
    const env = ast.node(ast.child(ast.root, 0));
    // open '(' + hline + row + row + close ')'
    try testing.expectEqual(@as(u16, 5), env.num_children);
    try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.root, 0), 0)).tag);
    try testing.expectEqual(.hline, ast.node(ast.child(ast.child(ast.root, 0), 1)).tag);
    try testing.expectEqual(.row, ast.node(ast.child(ast.child(ast.root, 0), 2)).tag);
    try testing.expectEqual(.row, ast.node(ast.child(ast.child(ast.root, 0), 3)).tag);
    try testing.expectEqual(.char, ast.node(ast.child(ast.child(ast.root, 0), 4)).tag);
}

test "parser: \\arraystretch stamps the first ROW, not a leading rule" {
    // The factor rides on the first `.row` entry, so a leading \hline in
    // front of it must not steal the stamp.
    var ast = try parseSrc(
        testing.allocator,
        "\\arraystretch{1.4}\\begin{array}{cc}\\hline a&b\\end{array}",
    );
    defer ast.deinit();
    const env = ast.child(ast.root, 1);
    try testing.expectEqual(.hline, ast.node(ast.child(env, 0)).tag);
    const row0 = ast.node(ast.child(env, 1));
    try testing.expectEqual(.row, row0.tag);
    const factor = atom.rowStretch(row0.data) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 1.4), factor, 1e-6);
}

test "parser: a repeated \\arraystretch inside one group still applies" {
    // The LAST assignment before the environment wins.
    var ast = try parseSrc(
        testing.allocator,
        "\\arraystretch{2}\\arraystretch{1.5}\\begin{matrix}a\\end{matrix}",
    );
    defer ast.deinit();
    const env = ast.child(ast.root, 2);
    const factor = atom.rowStretch(ast.node(ast.child(env, 0)).data) orelse
        return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 1.5), factor, 1e-6);
}

test "parser: \\hline outside an environment or inside a cell is a spanned error" {
    var info: parse_err.Info = undefined;
    // outside any environment, at the top level and inside a group
    try expectSpanError(&info, error.MisplacedHline, "\\hline", .misplaced_hline);
    try expectSpanError(&info, error.MisplacedHline, "x+\\hline+y", .misplaced_hline);
    try expectSpanError(&info, error.MisplacedHline, "{\\hline}", .misplaced_hline);
    try expectSpanError(&info, error.MisplacedHline, "\\frac{a}{\\hline}", .misplaced_hline);
    // inside a cell: TeX's \noalign is legal solely between rows
    try expectSpanError(
        &info,
        error.MisplacedHline,
        "\\begin{matrix}a \\hline b\\end{matrix}",
        .misplaced_hline,
    );
    try expectSpanError(
        &info,
        error.MisplacedHline,
        "\\begin{matrix}a & \\hline b\\end{matrix}",
        .misplaced_hline,
    );
    try expectSpanError(
        &info,
        error.MisplacedHline,
        "\\begin{matrix}{a \\hline}\\end{matrix}",
        .misplaced_hline,
    );
    // the caret covers the offending command itself
    var ast = atom.Ast.init(testing.allocator, "x+\\hline+y");
    defer ast.deinit();
    try lexer.lex(&ast, &info);
    var p = Parser.init(testing.allocator, ast.src, ast.tokens.items, &info);
    try testing.expectError(error.MisplacedHline, p.parse(&ast));
    try testing.expectEqualStrings("\\hline", ast.src[info.span.start..info.span.end]);
}
