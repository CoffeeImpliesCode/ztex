//! ztex.glyph — the one OpenType MATH glyph selection both back ends draw.
//!
//! A stretchy item — a display big operator, a `\sqrt`, a `\left`/`\right`
//! fence, a `\hat` or an overbrace — does not name the glyph it paints:
//! layout records WHAT it boxed, and the back end asks the face for it. The
//! answer comes from the face's OWN tables, so it is never a constant and
//! never borrowed from another font.
//!
//! One resolver, two back ends. `raster.rasterize` fills the outlines
//! `plan` yields; `svg.render` emits the same outlines as path geometry.
//! Both therefore draw the same variant, and a face with no MATH table
//! degrades to the base cmap glyph in both rather than failing.
//!
//! The request is a plain value, not a layout type: this module imports
//! `ztex.font` and nothing else, so parse and layout never reach a font
//! through it, and an extension axis is a FIELD rather than a branch — the
//! horizontal MATH forms (a wide bar, an extensible arrow, a top brace) add
//! `horizontal_req` and reuse the ladder and assembly walk below.
//!
//! `stretchGeometry` and `verticalGeometry` measure what a request paints
//! without drawing it, over the same `formFor` resolution both back ends
//! draw from: the box a generator reserves and the outlines a renderer fills
//! are one answer.
//!
//! Reached as `ztex.glyph`; `ztex.svg` and `ztex.raster` are its two
//! consumers, and both take the same `Request` and paint the same `Plan`.
//! This module does no I/O, opens no file and reads no environment: the face
//! is handed to it and every answer comes from that face's bytes. Nothing here
//! outlives its call except a `Plan`, which borrows the face it was built
//! from; every `gpa` argument pays for temporary curve lists that are released
//! before the call returns, on the error path too.

const std = @import("std");
const font = @import("ztex.font");

/// Everything this module can fail with. Decoding a glyph outline builds a
/// curve list from `gpa`, so `error.OutOfMemory` travels WITH the font
/// errors rather than being folded into one of them: an allocation failure
/// must never reach a caller as "this font is malformed", which would make a
/// resolver that runs out of memory look like a face with no MATH data.
pub const Error = error{OutOfMemory} || font.FontError;

/// What one draw item asks the MATH table for. `cp` is the codepoint the
/// item names; every other field selects a form of it. With every field at
/// its default the request is a plain cmap lookup and the item is ordinary
/// text no back end has to do geometry work for.
///
/// Precedence, when a caller sets more than one field and `plan` has to pick
/// one: `horizontal_req` wins over everything, then `delim_req`'s vertical
/// assembly, then `bigop_variant`, `radical_form`, `delim_form` and
/// `delim_fixed` in that order, and finally the plain cmap glyph. Two of the
/// fence fields are deliberately exclusive — a non-zero `delim_form` reads as
/// a content-sized rung and `delim_fixed` is then never consulted — so a
/// caller that sets both is asking for the rung, not the fixed height.
///
/// The em fields are SIZES in the item's own em units, not rung indices; every
/// one reads 0 or less as "no request", and a request the face cannot answer
/// degrades to a smaller form or the base glyph rather than failing. Nothing
/// here is validated: `plan` never returns an error because a field was out of
/// range, so a caller passes recorded values through unchanged.
///
/// A `Request` is plain scalars with no owner and no lifetime: copying it
/// copies the request, and it stays meaningful after the face that resolved
/// one is released.
pub const Request = struct {
    /// the codepoint the item names — its base glyph, and the key its MATH
    /// table indexes its constructions under, on whichever axis it grows.
    cp: u21,
    /// display big operator: draw the first rung of its own ladder, the
    /// form XeTeX draws in display style (every other style draws the base).
    bigop_variant: bool = false,
    /// 1..4 select a radical variant; `radical_form_top`/`_extender`/
    /// `_bottom` select one explicit assembly piece. A whole tall radical
    /// uses `delim_req`, like every other vertical assembly.
    radical_form: u8 = 0,
    /// content-sized `\left`/`\right` fence: 1-based rung of the codepoint's
    /// own ladder, the smallest one that covered the enclosed content.
    delim_form: u8 = 0,
    /// amsmath FIXED-rule fence height in em (`\binom`, `\genfrac`): the
    /// rung is the smallest one of THIS fence's own ladder whose designed
    /// height reaches it. 0 = a content-sized fence.
    delim_fixed: f32 = 0,
    /// Required vertical assembly ink height in em for a fence or radical.
    /// Parts repeat and overlap to reach it; a face without a construction
    /// degrades to the otherwise selected glyph.
    delim_req: f32 = 0,
    /// Horizontal target advance in the item's em units. Braces U+23DE/U+23DF
    /// and zero-advance glyphs choose the largest rung that fits the target;
    /// other glyphs choose the smallest rung covering it. Targets beyond the
    /// ladder use an assembly when available, otherwise its last rung.
    /// On bundled LM Math this fits combining accents and brace halves to
    /// their bases: a 0.574em `x` takes the 0.492em brace, not the 0.993em one.
    horizontal_req: f32 = 0,
};

/// True when the item asked for a stretch, so a back end that has to decode
/// outlines to draw it can tell before it spends that work.
pub fn needsGeometry(r: Request) bool {
    return r.bigop_variant or r.radical_form > 0 or r.delim_form > 0 or
        r.delim_fixed > 0 or r.delim_req > 0 or r.horizontal_req > 0;
}

/// The MATH key for radical variants, whole assemblies and explicit pieces.
pub const radical_cp: u21 = 0x221A;

/// Which piece of the radical's MATH glyph assembly a form number selects.
/// Values below `radical_form_top` are pre-built vertical size variants;
/// these three name one piece of the assembly instead, and `radicalPiece`
/// maps each to the piece it draws.
pub const radical_form_top: u8 = 5;
/// The repeated extender: the piece a renderer copies to reach a tall radical.
pub const radical_form_extender: u8 = 6;
/// The bottom piece: the bar and the stem below the rule.
pub const radical_form_bottom: u8 = 7;

/// One piece of a glyph assembly: its top, its extender, or its bottom.
pub const Piece = enum { top, extender, bottom };

/// The axis a stretch grows along. A vertical stack climbs — a fence, a
/// radical, a `\sum` — and is centred on the math axis; a horizontal one
/// runs left to right — a wide bar, an extensible arrow, an overbrace — and
/// starts at the item's own origin, because an accent is placed by its
/// left edge and its height is the accent's own.
pub const Axis = enum { vertical, horizontal };

/// One glyph a request paints, and where its origin sits: `x_em` and `y_em`
/// are the run along each axis in em, measured from the item's own origin,
/// y growing UP. Both are 0 for a single-glyph request. On a vertical stack
/// `x_em` is 0 and `y_em` rises per part; on a horizontal one `y_em` is 0
/// and `x_em` rises per part. A negative value is a part reaching back past
/// the origin — the shift that centres a fence on the math axis, whose axis
/// sits below a text baseline.
pub const Placed = struct {
    glyph: u32,
    x_em: f32,
    y_em: f32,
};

/// One glyph's painted extent across y in em, Y-up, relative to its own
/// origin. Read from the OUTLINE, never inferred from the MATH table: a
/// connector length is an overlap zone shared with a neighbour, not a
/// margin of blank ink, so a stacked fence's painted height comes from the
/// parts' real boxes.
pub const Ink = struct {
    min: f32,
    max: f32,
};

/// One glyph's painted extent on both axes, in em, relative to its own
/// origin: the box a caller frames against, measured from real outlines.
pub const Bounds = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
};

/// What a stretch request actually paints: the advance it reserves and its
/// real ink bounds. `stretchGeometry` reports the extent ALONG the axis the
/// item grew on; `verticalGeometry` reports the reserved HORIZONTAL advance
/// of the vertical form — a width, not the height the form reached. The ink
/// is one measurement either way: real outlines, never an estimate. Layout
/// and both renderers frame the same geometry.
pub const Stretch = struct {
    advance_em: f32,
    ink: Bounds,
    /// The width past which this form has NO design left: the last
    /// AdvanceMeasurement of a horizontal ladder that declares no glyph
    /// assembly, so the face drew that width and nothing wider. Set for that
    /// form alone, and read as "did the request genuinely outgrow the font":
    /// `request > finite_ceiling_em` means the face ran out of drawings. A
    /// request the form merely FITS under — a hat or a brace narrower than
    /// its nucleus — is answered from inside the ladder and still carries
    /// this ceiling: the property belongs to the FORM, not to the rung it
    /// picked.
    /// An assembly has no ceiling: it reaches any width.
    finite_ceiling_em: ?f32 = null,
};

/// The glyph at the 1-based MATH size-variant position `variant_index` of
/// `cp`'s VERTICAL ladder. Null when the face carries no MATH table, the
/// codepoint has no glyph, or the ladder is shorter than the requested rung —
/// the caller degrades rather than inventing an id. `variants` excludes the
/// base glyph, hence the -1. Allocation free: the ladder is a view over the
/// face's bytes.
pub fn variantGlyph(face: *const font.FontFace, cp: u21, variant_index: u8) ?u32 {
    if (variant_index == 0) return null;
    const base_gid = face.glyphIndex(cp) orelse return null;
    const ladder = face.variants(base_gid) orelse return null;
    const rung: usize = @as(usize, variant_index) - 1;
    if (rung >= ladder.len()) return null;
    return ladder.glyph(rung);
}

/// `cp`'s ladder along `axis`: the rungs the face designed for growth on
/// that axis, smallest first, base glyph excluded. A glyph grows on one axis
/// or the other — a fence vertically, a wide bar horizontally — so each half
/// answers only for its own.
fn ladderFor(face: *const font.FontFace, gid: u32, axis: Axis) ?font.MathVariants {
    return switch (axis) {
        .vertical => face.variants(gid),
        .horizontal => face.horizontalVariants(gid),
    };
}

/// `gid`'s glyph assembly along `axis`: the caps and repeatable extenders a
/// renderer stacks to reach a size past the last rung.
fn assemblyFor(face: *const font.FontFace, gid: u32, axis: Axis) ?font.MathAssembly {
    return switch (axis) {
        .vertical => face.assembly(gid),
        .horizontal => face.horizontalAssembly(gid),
    };
}

/// One rung of a ladder: the glyph, the size the face DESIGNED for it along
/// the growth axis (the MATH advance measurement, which is what SELECTS a
/// rung), and the glyph's own advance, which is what an item laid out with it
/// advances by. The two are never confused — the measurement belongs to the
/// ladder record, the advance to the glyph's own hmtx.
const Rung = struct {
    glyph: u32,
    size_em: f32,
    advance_em: f32,
};

/// The smallest rung of `base_gid`'s ladder along `axis` that covers
/// `req_em`, else the largest rung it has — a face is never scaled past the
/// shape it drew, because scaling thickens a stroke and a rung is a
/// different DRAWING rather than a bigger copy of the same one. A ladder
/// that carries the base glyph offers it as its smallest rung, which is what
/// a one-letter accent wants; one that does not starts at the first size
/// variant.
fn rungFor(face: *const font.FontFace, base_gid: u32, req_em: f32, axis: Axis) Rung {
    const base = Rung{
        .glyph = base_gid,
        .size_em = face.advanceEm(base_gid),
        .advance_em = face.advanceEm(base_gid),
    };
    const ladder = ladderFor(face, base_gid, axis) orelse return base;
    var chosen = base;
    for (0..ladder.len()) |rung| {
        const glyph = ladder.glyph(rung);
        chosen = .{
            .glyph = glyph,
            .size_em = ladder.advanceEm(rung),
            .advance_em = face.advanceEm(glyph),
        };
        if (chosen.size_em >= req_em) break;
    }
    return chosen;
}

/// The rung a horizontal stretch draws, and whether the ladder has a rung
/// that SPANS the request. `covered` false is the one request the ladder
/// cannot answer on its own — the item is wider than every drawing the face
/// made for it — and the only one that reaches the assembly.
const Fit = struct {
    rung: Rung,
    covered: bool,
};

/// The largest rung of `base_gid`'s ladder along `axis` that still FITS
/// `req_em`, else the base glyph, and whether some rung SPANS `req_em`.
/// `rungFor` asks which rung covers the request; this one asks which the
/// nucleus can hold, and it is the rule accents and braces read. The two
/// differ by a rung or more for every accent and every brace, and the FACE
/// decides which is right: measured against this exact Latin Modern Math,
/// XeTeX + unicode-math drawing `\widehat`/`\widetilde` at 20pt puts the
/// 0.920em variant (ink 18.24pt) over `M` (0.970em) and the 1.321em one
/// (26.40pt) over `abc` (1.391em), and draws the brace half of
/// `\underbrace{x}` — `x` is 0.574em — as the 0.492em rung, under `xx`
/// (1.148em) as the 0.993em one and under `\frac{a}{b}` (0.651em) as the
/// 0.492em one again: the LARGEST variant each nucleus still holds, never
/// the smallest one that spans it. A request narrower than every rung keeps
/// the base glyph, and a request wider than every rung takes the LAST one —
/// an item stays a finite set of real drawings and is never scaled into a
/// shape the face never drew — but reports `covered` false so the caller
/// offers it the assembly.
fn fittingRung(face: *const font.FontFace, base_gid: u32, req_em: f32, axis: Axis) Fit {
    const base = Rung{
        .glyph = base_gid,
        .size_em = face.advanceEm(base_gid),
        .advance_em = face.advanceEm(base_gid),
    };
    const ladder = ladderFor(face, base_gid, axis) orelse
        return .{ .rung = base, .covered = base.size_em >= req_em };
    var chosen = base;
    for (0..ladder.len()) |rung| {
        const size_em = ladder.advanceEm(rung);
        if (size_em > req_em) break;
        const glyph = ladder.glyph(rung);
        chosen = .{
            .glyph = glyph,
            .size_em = size_em,
            .advance_em = face.advanceEm(glyph),
        };
    }
    // The ladder answers the request itself when some rung is at least as wide
    // as it; only a request WIDER than every rung is a width the face drew no
    // variant for, and the only one that reaches the assembly.
    const covered = if (ladder.len() == 0)
        base.size_em >= req_em
    else
        req_em <= ladder.advanceEm(ladder.len() - 1);
    return .{ .rung = chosen, .covered = covered };
}

/// The width past which this horizontal form has no design left: the last
/// AdvanceMeasurement of a real horizontal ladder that declares NO glyph
/// assembly, so the face drew that width and nothing wider. Null with no
/// ladder at all, and null whenever an assembly exists — an assembly reaches
/// any width, so a caller asking "did the request outgrow the font?" must not
/// be handed a ceiling it can always grow past. This is a property of the FORM
/// and not of the rung chosen: a request the form merely fits under, answered
/// from inside the ladder, still carries the ceiling.
fn finiteCeiling(face: *const font.FontFace, base_gid: u32) ?f32 {
    const ladder = ladderFor(face, base_gid, .horizontal) orelse return null;
    if (ladder.len() == 0) return null;
    if (assemblyFor(face, base_gid, .horizontal) != null) return null;
    return ladder.advanceEm(ladder.len() - 1);
}

/// The rung of `cp`'s VERTICAL ladder that covers `req_em` of ink: how an
/// amsmath FIXED-rule fence (`\binom`, `\genfrac` with delimiters) is sized.
/// The fence's own ladder answers, so a `|` 4.5 ems tall picks a rung that
/// really is 4.5 ems tall instead of whichever rung a threshold table
/// happened to name for a parenthesis. Null when `cp` has no glyph.
pub fn coveringVariantGlyph(face: *const font.FontFace, cp: u21, req_em: f32) ?u32 {
    const base_gid = face.glyphIndex(cp) orelse return null;
    return rungFor(face, base_gid, req_em, .vertical).glyph;
}

/// One piece of a glyph assembly: its top, its extender, or its bottom.
/// Null when the face has no MATH table, no glyph at `cp`, no assembly, an
/// empty one, or no extender to repeat.
pub fn assemblyPieceGlyph(face: *const font.FontFace, cp: u21, piece: Piece) ?u32 {
    const gid = face.glyphIndex(cp) orelse return null;
    const stack = face.assembly(gid) orelse return null;
    if (stack.partCount() == 0) return null;
    return switch (piece) {
        .top => stack.part(stack.partCount() - 1).glyph,
        .bottom => stack.part(0).glyph,
        .extender => blk: {
            // A construction may list several extender glyphs; the last one
            // is the piece the top part stacks onto, so that is the one a
            // renderer repeats.
            var i: usize = stack.partCount();
            while (i > 0) {
                i -= 1;
                if (stack.part(i).extender) break :blk stack.part(i).glyph;
            }
            break :blk null;
        },
    };
}

/// The assembly piece a `radical_form_*` form number selects. Null for a form
/// that is neither a pre-built variant nor one of the three pieces, so the
/// assembly walk is never asked for a part that does not exist.
pub fn radicalPiece(radical_form: u8) ?Piece {
    return switch (radical_form) {
        radical_form_top => .top,
        radical_form_extender => .extender,
        radical_form_bottom => .bottom,
        else => null,
    };
}

/// One glyph's painted extent across y, decoded from the face's own outline.
/// The outline is built from `gpa` and released before this returns, on the
/// error path too.
///
/// A glyph whose outline is empty — a blank, or a `gid` the face has no
/// contours for — has no ink to report, and this returns the DEGENERATE ink
/// `{ .min = 0, .max = 0 }` rather than null: a caller framing a stack's
/// centring needs a length from every part, and zero says "this part paints
/// nothing here". Use `glyphBox` when "paints nothing" and "paints at the
/// origin" must be told apart; this cannot, because it collapses both to one
/// zero-height span.
///
/// Both values are in em relative to the glyph's own origin, Y-up. `face` is
/// borrowed and not mutated. Fails with `error.OutOfMemory` from the
/// temporary curve list, which is then released, so a retry starts from a
/// clean allocator state; the font errors mean the outline itself could not be
/// decoded. `Ink` is a value, so the result outlives the face.
pub fn glyphInk(gpa: std.mem.Allocator, face: *font.FontFace, gid: u32) Error!Ink {
    const box = (try glyphBox(gpa, face, gid)) orelse return .{ .min = 0, .max = 0 };
    return .{ .min = box.y_min, .max = box.y_max };
}

/// One glyph's painted extent on BOTH axes, decoded from the face's own
/// outline. Null when the outline is empty (a blank glyph paints nothing),
/// which is what lets a caller tell "no ink" from "ink at the origin".
///
/// The box is measured over the outline's CONTROL points rather than sampled
/// along the curves, so it encloses the painted outline and can be wider than
/// the ink itself; it never under-reports it. All four values are in em
/// relative to the glyph's own origin, and they assume a face whose
/// `unitsPerEm` is non-zero — a font declaring 0 is rejected when the face is
/// parsed, so no caller reaches a division by zero here.
///
/// `gpa` holds the decoded curve list for the duration of the call only; it is
/// released before returning and on the error path, so the returned `Bounds`
/// borrows nothing. `face` is borrowed and not mutated. `error.OutOfMemory`
/// leaves nothing allocated. `Bounds` is a value and outlives the face.
pub fn glyphBox(gpa: std.mem.Allocator, face: *font.FontFace, gid: u32) Error!?Bounds {
    var outline = try face.glyphOutline(gpa, gid);
    defer outline.deinit();
    if (outline.curves.items.len == 0) return null;
    var x_min: f32 = std.math.inf(f32);
    var x_max: f32 = -std.math.inf(f32);
    var y_min: f32 = std.math.inf(f32);
    var y_max: f32 = -std.math.inf(f32);
    for (outline.curves.items) |c| {
        for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
            x_min = @min(x_min, p[0]);
            x_max = @max(x_max, p[0]);
            y_min = @min(y_min, p[1]);
            y_max = @max(y_max, p[1]);
        }
    }
    const upem: f32 = @floatFromInt(face.unitsPerEm());
    return .{
        .x_min = x_min / upem,
        .y_min = y_min / upem,
        .x_max = x_max / upem,
        .y_max = y_max / upem,
    };
}

/// What one request paints: a single glyph for an ordinary run and for every
/// size variant, or a STACK for a stretch whose request outgrew the whole
/// ladder on that axis. One union, so both back ends consume a request
/// identically.
///
/// A `Plan` owns nothing and allocates nothing. `single` is a value; `stack`
/// holds the construction records as they sit in `face`'s own bytes, so a
/// `.stack` plan borrows the face and is invalid once the face is released or
/// its font bytes are overwritten. Constructing a plan may allocate transient
/// outlines while measuring a stack, but a returned plan retains none of them
/// and does not borrow the allocator.
///
/// Walking is `Iterator.next`, which advances the copy it is called on, so one
/// plan is walked ONCE: a second walk of the same value yields nothing. Copy
/// the plan before each walk to walk it again — a copy is an independent cursor
/// over the same records and paints the same placements in the same order.
/// Copies of one plan may be walked concurrently on different threads, because
/// `next` writes only the cursor's own fields; the face they read is not
/// mutated, so it must not be mutated by anyone else while they run.
pub const Plan = union(enum) {
    single: Placed,
    stack: Iterator,
};

/// The plan plus the size it paints along the stretch axis — the two answers
/// a generator sizes a box with and a back end paints from, resolved
/// together so they cannot disagree.
const Form = struct {
    plan: Plan,
    advance_em: f32,
    /// The form's finite horizontal capacity, carried to `Stretch`. Null for
    /// every non-horizontal answer and for a horizontal one with an assembly.
    finite_ceiling_em: ?f32 = null,
};

/// The MATH form knobs `requestFor` takes by name, one per field layout records
/// on a draw item. Each field carries the same default as the `Request` field
/// it lands in, so `.{}` is the plain cmap lookup, and the per-field clauses
/// below are the same ones `Request` carries. Precedence between them is
/// `Request`'s and is not restated here.
pub const RequestOptions = struct {
    /// display big operator: draw the first rung of its own ladder, the form
    /// XeTeX draws in display style (every other style draws the base).
    bigop_variant: bool = false,
    /// 1..4 select a radical variant; `radical_form_top`/`_extender`/
    /// `_bottom` select one explicit assembly piece. A whole tall radical
    /// uses `delim_req`, like every other vertical assembly.
    radical_form: u8 = 0,
    /// content-sized `\left`/`\right` fence: 1-based rung of the codepoint's
    /// own ladder, the smallest one that covered the enclosed content. 0 = a
    /// fence that asked for no rung, and `delim_fixed` then decides instead.
    delim_form: u8 = 0,
    /// amsmath FIXED-rule fence height in em (`\binom`, `\genfrac`): the
    /// rung is the smallest one of THIS fence's own ladder whose designed
    /// height reaches it. 0 = a content-sized fence.
    delim_fixed: f32 = 0,
    /// Required vertical assembly ink height in em for a fence or radical.
    /// Parts repeat and overlap to reach it; a face without a construction
    /// degrades to the otherwise selected glyph.
    delim_req: f32 = 0,
    /// Horizontal target advance in the item's em units. Braces U+23DE/U+23DF
    /// and zero-advance glyphs choose the largest rung that fits the target;
    /// other glyphs choose the smallest rung covering it. Targets beyond the
    /// ladder use an assembly when available, otherwise its last rung.
    horizontal_req: f32 = 0,
};

/// A single placement at the item's own origin: what every size variant, and
/// every one-off glyph a request degrades to, paints.
fn placedGlyph(g: u32) Plan {
    return .{ .single = .{ .glyph = g, .x_em = 0, .y_em = 0 } };
}

/// Build the request for one draw item from its run bytes and the MATH fields
/// layout recorded on it. The one place the two back ends agree on what a run
/// asks for. `bytes` is the run itself; `options` carries the form knobs by
/// name, and `.{}` is an ordinary run that paints its base glyph.
///
/// Null when the run names no codepoint — empty bytes, a leading byte that is
/// not a valid UTF-8 sequence start, or a sequence the run truncates — and
/// there is then no codepoint to resolve. A bare combining mark IS a
/// codepoint, so it yields a request; whether the face has a glyph for it is
/// `plan`'s answer, not this one's.
///
/// Fields are not validated here. A form the face cannot answer degrades to a
/// smaller form or to the base glyph rather than failing, so a caller never has
/// to check a knob before passing it. Allocates nothing and retains neither
/// argument: the returned `Request` owns scalars only.
pub fn requestFor(bytes: []const u8, options: RequestOptions) ?Request {
    const cp = codepointOf(bytes) orelse return null;
    return .{
        .cp = cp,
        .bigop_variant = options.bigop_variant,
        .radical_form = options.radical_form,
        .delim_form = options.delim_form,
        .delim_fixed = options.delim_fixed,
        .delim_req = options.delim_req,
        .horizontal_req = options.horizontal_req,
    };
}

/// The first codepoint in a UTF-8 run, or null when there is none.
///
/// Null covers the three cases that leave nothing to resolve: an empty run, a
/// leading byte that cannot start a sequence (a continuation byte or an
/// out-of-range lead), and a sequence the run truncates. Everything after the
/// first codepoint is NOT examined — a run whose tail is malformed still
/// answers with its first codepoint — and a combining mark is a codepoint like
/// any other, so it is returned rather than skipped. Reads at most four bytes,
/// allocates nothing, and borrows nothing.
pub fn codepointOf(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    const width = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (width > bytes.len) return null;
    return switch (width) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch null,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch null,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch null,
        else => null,
    };
}

/// Resolve one request into what it paints. Null when the codepoint has no
/// glyph at all — nothing to draw, and no id invented from another font.
///
/// Every knob is answered from the face's own tables, and each request form
/// degrades rather than failing: a horizontal stretch past the ladder falls
/// back to the last rung, a vertical assembly that the face cannot build
/// falls back to the rung or the base glyph the request would have selected,
/// and a bare glyph with no MATH construction is simply a `.single`. So a
/// face with no MATH table at all answers every request instead of returning
/// null, and null means only "this codepoint has no glyph".
///
/// `gpa` is used for the temporary curve lists that measuring a vertical
/// stack's centring needs, and every one of them is released before this
/// returns, on the error path too. `face` is borrowed, never retained and
/// never mutated; a `.stack` result keeps reading the face's bytes after
/// this call, so the face must outlive the plan.
///
/// `error.OutOfMemory` leaves nothing behind: no allocation from this call
/// survives it, and no glyph id is cached, so the same request may be
/// retried. The font errors mean the face's own tables could not be read.
pub fn plan(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    r: Request,
) Error!?Plan {
    const form = (try formFor(gpa, face, r)) orelse return null;
    return form.plan;
}

/// A stretch's logical advance and actual two-dimensional ink bounds.
///
/// Null when the request asks for no stretch at all (`horizontal_req`,
/// `delim_req`, `delim_fixed` all at or below 0 and `delim_form` 0), when
/// the codepoint has no glyph, or when the resolved form paints nothing — an
/// ordinary run is not this function's answer, and a blank one has no ink to
/// frame. `advance_em` is the extent ALONG the axis the item grew on, in em;
/// `ink` is the painted box in em from the item's own origin.
///
/// Resolved over the same `formFor` walk both back ends draw from, so the box
/// a generator reserves and the outlines a renderer fills cannot disagree.
/// Temporary outline decodes are released before returning, error path
/// included; `face` is borrowed and a `.stack` resolution is not retained in
/// the result, so `Stretch` outlives the face.
pub fn stretchGeometry(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    r: Request,
) Error!?Stretch {
    if (r.horizontal_req <= 0 and r.delim_req <= 0 and r.delim_fixed <= 0 and
        r.delim_form == 0) return null;
    const form = (try formFor(gpa, face, r)) orelse return null;
    const ink = (try planBounds(gpa, face, form.plan)) orelse return null;
    return .{
        .advance_em = form.advance_em,
        .ink = ink,
        .finite_ceiling_em = form.finite_ceiling_em,
    };
}

/// The geometry a VERTICAL form reserves: the HORIZONTAL advance of the
/// glyphs it places — the glyph's own hmtx for one variant, the widest part's
/// for a stack — and the ink those placements really paint, in em from the
/// item's own origin. A fence climbs the page, so the size its plan reached
/// along that axis is a HEIGHT; reporting it as the advance is how a
/// delimiter comes to reserve a column as wide as itself is tall.
/// The resolution is the `formFor` walk both back ends draw through, so the
/// box a generator reserves and the outlines a renderer fills are one answer
/// and cannot disagree. Null when `cp` has no glyph at all, or when the
/// resolved form paints nothing — a blank outline has no ink to frame, and
/// no advance is invented for it. Also null for a request that grows along x:
/// `horizontal_req` names no vertical form, and the advance such an item
/// reserved is exactly what the caller already has, so `stretchGeometry`
/// answers it instead. `advance_em` here is a WIDTH in em.
pub fn verticalGeometry(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    r: Request,
) Error!?Stretch {
    // A horizontal request names no vertical form: it grows along x, and the
    // advance it reserved is exactly what the caller already has.
    if (r.horizontal_req > 0) return null;
    const form = (try formFor(gpa, face, r)) orelse return null;
    const measured = (try measurePlan(gpa, face, form.plan)) orelse return null;
    return .{ .advance_em = measured.advance_em, .ink = measured.ink };
}

/// The box a request PAINTS, in em from the item's own origin: every
/// placement's real outline union, both axes. Null when nothing draws. This
/// is the frame the geometry itself reports, so a caller can check what the
/// back end drew against what the generator asked for.
///
/// Resolves its own plan rather than taking one, so it never consumes a
/// caller's `Plan` and holds no cursor: the outlines it decodes are
/// temporary and released before returning, error path included, and the
/// `Bounds` it returns is a value that outlives the face. Each distinct part
/// of an assembly is decoded once however many copies the walk placed.
pub fn paintedBounds(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    r: Request,
) Error!?Bounds {
    const form = (try formFor(gpa, face, r)) orelse return null;
    return planBounds(gpa, face, form.plan);
}

fn planBounds(gpa: std.mem.Allocator, face: *font.FontFace, built: Plan) Error!?Bounds {
    const measured = try measurePlan(gpa, face, built);
    return if (measured) |m| m.ink else null;
}

/// The running measurement of one plan: the painted union of its placements
/// and the widest advance among the glyphs it PLACES. A single placement
/// advances by its own hmtx; a stack's parts all sit in the ONE box its
/// construction reserves, so it advances by their maximum — never by the
/// stack's extent, which is a height and says nothing about a width.
const Measured = struct {
    ink: Bounds = .{
        .x_min = std.math.inf(f32),
        .y_min = std.math.inf(f32),
        .x_max = -std.math.inf(f32),
        .y_max = -std.math.inf(f32),
    },
    advance_em: f32 = 0,
    painted: bool = false,
};

/// One walk of a plan, measuring both answers together so they cannot
/// disagree. Null when nothing paints. Only the LAST placement's box is
/// kept, so a stack that repeats one extender decodes that outline once per
/// part kind instead of once per copy; the walk itself keeps O(1) state, so
/// an assembly of any height is measured without buffering its placements.
fn measurePlan(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    built: Plan,
) Error!?Measured {
    var walk = built;
    var acc: Measured = .{};
    var cached: CachedBounds = .{};
    switch (walk) {
        .single => |part| try accumulate(gpa, face, &acc, &cached, part),
        .stack => |*cursor| {
            while (cursor.next()) |part| try accumulate(gpa, face, &acc, &cached, part);
        },
    }
    return if (acc.painted) acc else null;
}

/// The last placement's own box and advance, kept so a run of equal parts
/// decodes its outline once.
const CachedBounds = struct {
    glyph: ?u32 = null,
    box: ?Bounds = null,
    advance_em: f32 = 0,
};

/// Fold one placement into the union and into the widest advance: its real
/// outline box translated by where the placement sits, and its own hmtx.
fn accumulate(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    acc: *Measured,
    cached: *CachedBounds,
    part: Placed,
) Error!void {
    const reused = if (cached.glyph) |gid| gid == part.glyph else false;
    if (!reused) {
        cached.* = .{
            .glyph = part.glyph,
            .box = try glyphBox(gpa, face, part.glyph),
            .advance_em = face.advanceEm(part.glyph),
        };
    }
    acc.advance_em = @max(acc.advance_em, cached.advance_em);
    const box = cached.box orelse return;
    acc.ink.x_min = @min(acc.ink.x_min, part.x_em + box.x_min);
    acc.ink.x_max = @max(acc.ink.x_max, part.x_em + box.x_max);
    acc.ink.y_min = @min(acc.ink.y_min, part.y_em + box.y_min);
    acc.ink.y_max = @max(acc.ink.y_max, part.y_em + box.y_max);
    acc.painted = true;
}

/// Resolve a request: the placements a back end paints and the advance they
/// cover. One walk, so the two can never disagree.
fn formFor(gpa: std.mem.Allocator, face: *font.FontFace, r: Request) Error!?Form {
    // A horizontal request wins: a wide bar, an extensible arrow and a brace
    // grow along x, and an item stretches on one axis.
    if (r.horizontal_req > 0) return try horizontalForm(gpa, face, r);
    if (r.delim_req > 0) {
        if (try assemblyPlan(gpa, face, r.cp, r.delim_req, .vertical)) |stack| {
            return .{ .plan = .{ .stack = stack }, .advance_em = stack.extent_em };
        }
    }
    return singleForm(face, r);
}

/// Accents and braces fit their nucleus with the largest fitting rung.
/// Other horizontal stretches retain the smallest covering rung. Both
/// reach an assembly only past the ladder, and a face without an assembly
/// keeps its last designed rung without scaling it.
fn horizontalForm(gpa: std.mem.Allocator, face: *font.FontFace, r: Request) Error!?Form {
    const base_gid = face.glyphIndex(r.cp) orelse return null;
    const ceiling = finiteCeiling(face, base_gid);
    const fit = if (r.cp == 0x23DE or r.cp == 0x23DF or face.advanceEm(base_gid) == 0)
        fittingRung(face, base_gid, r.horizontal_req, .horizontal)
    else blk: {
        const rung = rungFor(face, base_gid, r.horizontal_req, .horizontal);
        break :blk Fit{ .rung = rung, .covered = rung.size_em >= r.horizontal_req };
    };
    if (fit.covered) {
        return .{
            .plan = placedGlyph(fit.rung.glyph),
            .advance_em = fit.rung.advance_em,
            .finite_ceiling_em = ceiling,
        };
    }
    if (try assemblyPlan(gpa, face, r.cp, r.horizontal_req, .horizontal)) |stack| {
        return .{ .plan = .{ .stack = stack }, .advance_em = stack.extent_em };
    }
    return .{
        .plan = placedGlyph(fit.rung.glyph),
        .advance_em = fit.rung.advance_em,
        .finite_ceiling_em = ceiling,
    };
}

/// One size variant, one radical piece, the rung a fixed-rule fence asks
/// for, or the base glyph: everything a request paints without an assembly.
fn singleForm(face: *const font.FontFace, r: Request) ?Form {
    if (r.bigop_variant) {
        if (variantGlyph(face, r.cp, 1)) |g| return oneGlyph(face, g);
    }
    if (r.radical_form > 0) {
        // Rungs above the ladder (form 5..7) fall through to the assembly;
        // anything past `radical_form_bottom` is rejected by both.
        const piece = variantGlyph(face, radical_cp, r.radical_form) orelse
            if (radicalPiece(r.radical_form)) |which|
                assemblyPieceGlyph(face, radical_cp, which)
            else
                null;
        if (piece) |g| return oneGlyph(face, g);
    }
    if (r.delim_form > 0) {
        // Layout's own rung: read its designed height straight off the
        // ladder. A glyph's own advance is its WIDTH, which says nothing
        // about the height a fence was chosen for.
        const base_gid = face.glyphIndex(r.cp);
        const ladder = if (base_gid) |g| ladderFor(face, g, .vertical) else null;
        const rung: usize = @as(usize, r.delim_form) - 1;
        if (ladder) |l| {
            if (rung < l.len()) {
                return .{ .plan = placedGlyph(l.glyph(rung)), .advance_em = l.advanceEm(rung) };
            }
        }
    } else if (r.delim_fixed > 0) {
        // A FIXED-rule fence asks for a HEIGHT, not a rung number: this
        // fence's own ladder picks the rung, so `\binom` beside a 4-em `|`
        // draws a 4-em-tall fence.
        const base_gid = face.glyphIndex(r.cp) orelse return null;
        const rung = rungFor(face, base_gid, r.delim_fixed, .vertical);
        return .{ .plan = placedGlyph(rung.glyph), .advance_em = rung.advance_em };
    }
    const g = face.glyphIndex(r.cp) orelse return null;
    return oneGlyph(face, g);
}

/// A one-off glyph: its own advance is what it paints, and the caller sized
/// the item for that.
fn oneGlyph(face: *const font.FontFace, g: u32) Form {
    return .{ .plan = placedGlyph(g), .advance_em = face.advanceEm(g) };
}

/// A walking plan for one assembled stretch. Every quantity that does not
/// depend on WHICH placement comes next — the repeat count, how far the joins
/// are opened up, the rise that centres a vertical stack on the axis — is
/// settled when the plan is built, from the construction's own records and
/// the parts' real outlines. `next` then walks the table once and keeps O(1)
/// state, so an arbitrarily tall fence costs exactly as many placements as
/// it has parts and is never truncated or buffered.
///
/// `stack` is a view over `face`'s own font bytes and borrows it, so an
/// `Iterator` must not outlive the face or be used after the face's bytes are
/// overwritten. It owns nothing and allocates nothing.
///
/// `next` ADVANCES this value, so one cursor yields its placements once and
/// then null forever. To walk the same stretch again, copy the cursor first:
/// a copy is an independent cursor over the same records and yields the same
/// placements in the same order. Independent copies may be walked on
/// different threads at the same time, because `next` writes only the cursor's
/// own fields and reads `stack` without mutating it; the face they borrow must
/// not be mutated while any copy is walking.
///
/// `part`, `copies_left` and `rise` are the cursor's own position, the copies
/// of the current part still to come, and the rise so far in em. They are the
/// only fields `next` writes, and they are what makes a second walk of the
/// same value yield nothing.
///
/// Every em field is a length in the face's own em units, so each scales with
/// the size the caller paints at, never with a point size. `repeats` is a
/// COUNT of extender copies rather than a length: a construction with no
/// extender has nothing to repeat, so the builder stops at the largest stack
/// it can actually grow.
pub const Iterator = struct {
    /// The construction records as they sit in the face's bytes. Borrows the
    /// face; never owned, never copied out of it.
    stack: font.MathAssembly,
    /// Which way the parts run. The run lands on `y_em` for a vertical stack
    /// and on `x_em` for a horizontal one; the other axis stays 0.
    axis: Axis,
    /// Copies each extender contributes. 0 drops the extenders entirely —
    /// the smallest legal stack.
    repeats: usize,
    /// Opened up from EVERY join, in em, to bring the stack to the request.
    /// Each join opens by at most its own room to the connector ceiling.
    trim: f32,
    /// Rise added to every placement of a VERTICAL stack so its painted ink
    /// is centred on the math axis. A horizontal stack starts at the item's
    /// own origin instead, so it is 0.
    shift: f32,
    /// The extent the walk paints along `axis`, in em, between the first
    /// placement's origin and the last one's far end — what an assembled
    /// item advances by.
    extent_em: f32,
    /// How much LONGER than the request the smallest legal stack came out,
    /// in em. Zero whenever the joins could absorb the whole difference;
    /// otherwise the construction cannot legally shrink further and layout
    /// may want to know before it frames the formula.
    excess_em: f32,
    /// Index of the construction record the cursor is on. The walk ends when it
    /// reaches `stack.partCount()`.
    part: usize = 0,
    /// Copies of the current record still to yield. 0 means the record is
    /// exhausted and the next call moves to the one after it; a record dropped
    /// at this size (an extender with `repeats` 0) is skipped without yielding.
    copies_left: usize = 0,
    /// Rise along `axis` in em, accumulated from the first placement's origin.
    /// The next placement lands here, after its join overlap is subtracted.
    rise: f32 = 0,

    /// The font's MinConnectorOverlap: the least two joined parts may share.
    min_overlap: f32 = 0,

    /// The next part to paint, bottom to top on a vertical stack and left to
    /// right on a horizontal one, or null when it is exhausted. The same
    /// placements, in the same order, for every caller.
    ///
    /// Advances the cursor, so one cursor is walked once; a copy walked
    /// separately yields the same placements again. Returns the placement by
    /// value and borrows nothing. Cannot fail and allocates nothing. The glyph
    /// id remains specific to the original face; an equal numeric id in a
    /// different face need not identify the same glyph.
    pub fn next(self: *Iterator) ?Placed {
        const count = self.stack.partCount();
        while (self.part < count) {
            const record = self.stack.part(self.part);
            if (self.copies_left == 0) {
                const copies: usize = if (record.extender) self.repeats else 1;
                if (copies == 0) {
                    // Dropped at this size: it leaves no placement of its
                    // own, and the join between the parts that DO paint is
                    // measured straight across it.
                    self.part += 1;
                    continue;
                }
                // A part starts that much short of the one below it, so a
                // connector zone is counted once rather than twice.
                self.rise -= self.overlapBetween(self.part);
                self.copies_left = copies;
            } else {
                self.rise -= joinOverlap(record, record, self.min_overlap, self.trim);
            }
            const out = Placed{
                .glyph = record.glyph,
                .x_em = if (self.axis == .horizontal) self.rise else 0,
                .y_em = if (self.axis == .horizontal) 0 else self.rise + self.shift,
            };
            self.rise += record.full_advance;
            self.copies_left -= 1;
            if (self.copies_left == 0) self.part += 1;
            return out;
        }
        return null;
    }

    /// The overlap between the last copy of the part below `i` and the first
    /// copy of part `i`: the floor the font permits, opened by this stack's
    /// trim and capped by the two parts' own connector material.
    fn overlapBetween(self: *const Iterator, i: usize) f32 {
        if (i == 0) return 0;
        var below = i - 1;
        while (below > 0 and self.stack.part(below).extender and self.repeats == 0) below -= 1;
        if (self.repeats == 0 and self.stack.part(below).extender) return 0;
        return joinOverlap(
            self.stack.part(below),
            self.stack.part(i),
            self.min_overlap,
            self.trim,
        );
    }
};

/// The connector material two joined parts share: the floor the font permits,
/// opened by `trim` and never past the ceiling the parts' own connectors
/// allow.
fn joinOverlap(
    lower: font.MathAssemblyPart,
    upper: font.MathAssemblyPart,
    floor: f32,
    trim: f32,
) f32 {
    const ceiling = @min(lower.end_connector_length, upper.start_connector_length);
    return @min(floor + trim, ceiling);
}

/// How much one join may open: from the floor the font permits up to the
/// ceiling its two parts' connector material allows. Never negative — a font
/// that demands more overlap than it drew leaves the join closed.
fn joinRoom(lower: font.MathAssemblyPart, upper: font.MathAssemblyPart, floor: f32) f32 {
    const ceiling = @min(lower.end_connector_length, upper.start_connector_length);
    return @max(0, ceiling - floor);
}

/// One walk of an assembly's parts: what the stack paints at one repeat
/// count and one opening, and how much room its joins still have.
const Walk = struct {
    /// Extent between the first placement's origin and the last one's far
    /// end: every advance, less the overlap each join shares.
    size: f32,
    /// How far every join has opened at this trim.
    opened: f32,
    /// The largest opening any single join still allows.
    max_open: f32,

    fn add(
        self: *Walk,
        lower: font.MathAssemblyPart,
        upper: font.MathAssemblyPart,
        floor: f32,
        trim: f32,
    ) void {
        const room = joinRoom(lower, upper, floor);
        self.size -= joinOverlap(lower, upper, floor, trim);
        self.opened += @min(trim, room);
        self.max_open = @max(self.max_open, room);
    }
};

/// Walk an assembly at one repeat count and one opening. Every part appears
/// once, except an extender, which contributes `repeats` copies — zero
/// drops it entirely, the smallest legal stack. A part with no copies joins
/// nothing, so the next real part is what the join is measured against.
fn walkStack(stack: font.MathAssembly, repeats: usize, floor: f32, trim: f32) Walk {
    var out: Walk = .{ .size = 0, .opened = 0, .max_open = 0 };
    var below: ?usize = null;
    var i: usize = 0;
    while (i < stack.partCount()) : (i += 1) {
        const record = stack.part(i);
        const copies: usize = if (record.extender) repeats else 1;
        if (copies == 0) continue;
        if (below) |b| out.add(stack.part(b), record, floor, trim);
        // The copies of one extender share each other's connectors.
        var c: usize = 1;
        while (c < copies) : (c += 1) out.add(record, record, floor, trim);
        out.size += @as(f32, @floatFromInt(copies)) * record.full_advance;
        below = i;
    }
    return out;
}

/// The opening every join takes so the stack lands on `want_em` less than it
/// is with its joins closed to the floor: each join opens by the SAME amount
/// until its own connector material caps it, which keeps the shape the font
/// designed. The total opens monotonically in the trim, so the bisection
/// lands on the exact opening; `max_open` when the joins cannot absorb the
/// whole difference, which the caller reports as excess.
fn uniformOpen(stack: font.MathAssembly, repeats: usize, floor: f32, want_em: f32) f32 {
    const widest = walkStack(stack, repeats, floor, 0);
    if (want_em <= 0 or widest.max_open <= 0) return 0;
    if (walkStack(stack, repeats, floor, widest.max_open).opened < want_em) return widest.max_open;
    var lo: f32 = 0;
    var hi = widest.max_open;
    // f32 has a 24-bit significand, so 32 halvings of any em-scaled range
    // land below the resolution of the measurement itself.
    for (0..32) |_| {
        const mid = (lo + hi) / 2;
        if (walkStack(stack, repeats, floor, mid).opened < want_em) lo = mid else hi = mid;
    }
    return hi;
}

/// Build the stack for a stretch whose request outgrew the variant ladder on
/// `axis`. Null when the face carries no MATH table, no glyph at `cp`, or no
/// assembly for it — the caller then degrades to a variant glyph.
fn assemblyPlan(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    cp: u21,
    target_em: f32,
    axis: Axis,
) Error!?Iterator {
    const base_gid = face.glyphIndex(cp) orelse return null;
    const stack = assemblyFor(face, base_gid, axis) orelse return null;
    const count = stack.partCount();
    if (count == 0) return null;
    const floor = face.mathMinConnectorOverlapEm();

    // The smallest repeat count whose widest legal stack reaches the
    // request, extenders dropped first — the smallest legal stack is where
    // the search starts. Equal repeats for every extender is what keeps a
    // brace symmetric; a greedy fill of one extender would not.
    var repeats: usize = 0;
    var laid = walkStack(stack, repeats, floor, 0);
    while (laid.size < target_em) {
        const grown = walkStack(stack, repeats + 1, floor, 0);
        // The construction cannot grow (no extenders, or their copies share
        // more than they add): take the largest it reaches and report the
        // shortfall rather than painting a silently short stack.
        if (grown.size <= laid.size) break;
        repeats += 1;
        laid = grown;
    }

    // Open every join by the same amount, from the floor up, until the stack
    // is the size the request asked for — both when it came out too tall and
    // when the joins can still stretch it further.
    const trim = uniformOpen(stack, repeats, floor, laid.size - target_em);
    const placed = walkStack(stack, repeats, floor, trim);

    var shift: f32 = 0;
    if (axis == .vertical) {
        // Centre the PAINTED ink on the axis: the first and last
        // placements' real outlines, not an inference from connector lengths.
        const constants = face.mathConstants() orelse return null;
        var first: ?usize = null;
        var last: ?usize = null;
        for (0..count) |i| {
            if (copiesOf(stack.part(i), repeats) == 0) continue;
            if (first == null) first = i;
            last = i;
        }
        const first_i = first orelse return null;
        const last_i = last orelse return null;
        // The last placement's origin is everything the stack advanced less
        // what it painted, less that part's own advance.
        const last_rise = placed.size - stack.part(last_i).full_advance;
        const ink_first = try glyphInk(gpa, face, stack.part(first_i).glyph);
        const ink_last = try glyphInk(gpa, face, stack.part(last_i).glyph);
        shift = constants.axis_height - (ink_first.min + last_rise + ink_last.max) / 2;
    }

    return .{
        .stack = stack,
        .axis = axis,
        .repeats = repeats,
        .trim = trim,
        .shift = shift,
        .extent_em = placed.size,
        .excess_em = @max(0, placed.size - target_em),
        .min_overlap = floor,
    };
}

/// How many placements one table part contributes at a repeat count.
fn copiesOf(record: font.MathAssemblyPart, repeats: usize) usize {
    return if (record.extender) repeats else 1;
}

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

fn mathTest(gpa: std.mem.Allocator) !struct { ctx: font.FontContext, face: *font.FontFace } {
    const ctx = try font.FontContext.init(gpa);
    return .{ .ctx = ctx, .face = ctx.math };
}

/// Walk a planned stack and report what it paints: the extent ALONG THE
/// STACK'S OWN AXIS, the part count, how far the stack overshot the request,
/// and the first blank seam along the run (0 when the ink is continuous).
const Painted = struct {
    min: f32 = std.math.inf(f32),
    max: f32 = -std.math.inf(f32),
    parts: usize = 0,
    worst_gap: f32 = 0,
    excess_em: f32 = 0,
    first_glyph: u32 = 0,
    last_glyph: u32 = 0,
};

fn paintStack(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    cp: u21,
    target_em: f32,
    axis: Axis,
) !?Painted {
    const planned = try assemblyPlan(gpa, face, cp, target_em, axis) orelse return null;
    var it = planned;
    var out: Painted = .{ .excess_em = planned.excess_em };
    var previous_far: ?f32 = null;
    while (it.next()) |placement| {
        const box = (try glyphBox(gpa, face, placement.glyph)) orelse continue;
        const at = if (axis == .horizontal) placement.x_em else placement.y_em;
        const near = if (axis == .horizontal) box.x_min else box.y_min;
        const far = if (axis == .horizontal) box.x_max else box.y_max;
        out.min = @min(out.min, at + near);
        out.max = @max(out.max, at + far);
        if (previous_far) |reached| {
            // A connector zone is shared ink: the next part must start no
            // later than this one ended, or the stack has a hole in it.
            out.worst_gap = @max(out.worst_gap, (at + near) - reached);
        }
        previous_far = at + far;
        if (out.parts == 0) out.first_glyph = placement.glyph;
        out.last_glyph = placement.glyph;
        out.parts += 1;
    }
    return out;
}

// A fence whose content outgrew the ladder must reach the height layout
// asked for — that is the whole point of the assembly — stay centred on the
// math axis, and grow by adding parts, never by stretching one.
test "glyph: an assembled fence reaches the requested height, centred and gap-free" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const axis = (both.face.mathConstants() orelse return error.MissingGlyph).axis_height;

    var previous_parts: usize = 0;
    for ([_]f32{ 3.4, 4.5, 6.0, 9.0, 12.0, 20.0 }) |target| {
        const painted = (try paintStack(testing.allocator, both.face, '(', target, .vertical)) orelse
            return error.MissingGlyph;
        try testing.expect(painted.parts >= 3);
        try testing.expect(painted.parts >= previous_parts);
        // The stack paints the requested ink, within the construction's own
        // slack (the table's measurements are the designed extent).
        try testing.expectApproxEqAbs(target, painted.max - painted.min, 0.2);
        // Centred on the axis, like the size variant it replaces.
        try testing.expectApproxEqAbs(axis, (painted.min + painted.max) / 2, 0.05);
        // No blank seam anywhere in the stack.
        try testing.expect(painted.worst_gap <= 0.02);
        // And nothing left over: the fence is the size its content needs.
        try testing.expectApproxEqAbs(@as(f32, 0), painted.excess_em, 0.001);
        previous_parts = painted.parts;
    }
}

// The size the plan reports and the run the walk places are ONE measurement.
// Dropping the extenders entirely is the smallest legal stack, and the join
// between the two caps is still measured across the extender the walk did
// not place — otherwise the stack comes out a whole connector longer than
// the box the generator sized for it.
test "glyph: the painted extent is the extent the plan reports" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;

    for ([_]f32{ 2.0, 2.5, 3.4, 6.0, 12.0 }) |target| {
        const planned = (try assemblyPlan(testing.allocator, face, '(', target, .vertical)) orelse
            return error.NoAssembly;
        const painted = (try paintStack(testing.allocator, face, '(', target, .vertical)) orelse
            return error.MissingGlyph;
        try testing.expectApproxEqAbs(planned.extent_em, painted.max - painted.min, 0.2);
        try testing.expect(painted.worst_gap <= 0.02);

        if (planned.repeats != 0) continue;
        const stack = planned.stack;
        const lower = stack.part(0);
        const upper = stack.part(stack.partCount() - 1);
        const ceiling = @min(lower.end_connector_length, upper.start_connector_length);
        const joined = lower.full_advance - @min(planned.min_overlap + planned.trim, ceiling);
        var walk = planned;
        const first = walk.next() orelse return error.NoStack;
        const second = walk.next() orelse return error.NoStack;
        // A vertical stack keeps x at the item's origin; only the rise
        // carries it, and the centring shift is the same for both.
        try testing.expectEqual(@as(f32, 0), first.x_em);
        try testing.expectApproxEqAbs(joined, second.y_em - first.y_em, 0.0001);
    }
}

// The regression for the fixed-size placement buffer this walk replaced: a
// fence far taller than any realistic formula must still be assembled in
// full. Truncating the part list silently draws a fence that stops halfway
// down the content it is supposed to hold.
test "glyph: a fence needing hundreds of parts is assembled whole" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const painted = (try paintStack(testing.allocator, both.face, '(', 200.0, .vertical)) orelse
        return error.MissingGlyph;
    try testing.expect(painted.parts > 64);
    try testing.expectApproxEqAbs(200.0, painted.max - painted.min, 1.0);
    try testing.expect(painted.worst_gap <= 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0), painted.excess_em, 0.001);
}

// A brace is the case where a greedy fill would show: equal repeats through
// the middle keep the stack symmetric, so the hooks sit the same distance
// from the axis and the painted height stays balanced.
test "glyph: an assembled brace is balanced about the axis" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const axis = (both.face.mathConstants() orelse return error.MissingGlyph).axis_height;

    var previous_parts: usize = 0;
    for ([_]f32{ 4.0, 6.0, 10.0, 24.0 }) |target| {
        const painted = (try paintStack(testing.allocator, both.face, '{', target, .vertical)) orelse
            return error.MissingGlyph;
        try testing.expect(painted.parts >= 3);
        try testing.expect(painted.parts >= previous_parts);
        const above = painted.max - axis;
        const below = axis - painted.min;
        try testing.expectApproxEqAbs(above, below, 0.05);
        try testing.expectApproxEqAbs(target, above + below, 0.2);
        try testing.expect(painted.worst_gap <= 0.02);
        // First and last are the hooks, not repeat copies of one extender.
        try testing.expect(painted.first_glyph != painted.last_glyph);
        previous_parts = painted.parts;
    }
}

// A size BETWEEN two rungs is not the largest rung below it: the connector
// material the font drew can still be opened up, and that is what makes a
// 3.5 em fence reach 3.5 em instead of stopping at the brace's 3.0 em
// assembly. Closing every join to the font's minimum overlap is the most a
// construction can legally stretch, and the walk must use all of it.
test "glyph: a fence between two rungs reaches its size by opening the joins" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;
    // The brace's ladder stops at 3.0 em, and so does its tightest assembly:
    // every size above that is reachable only through the joins.
    const ladder = face.variants(face.glyphIndex('{') orelse return error.MissingGlyph) orelse
        return error.MissingGlyph;
    try testing.expect(ladder.advanceEm(ladder.len() - 1) <= 3.01);

    for ([_]f32{ 3.1, 3.4, 3.9 }) |target| {
        const planned = (try assemblyPlan(testing.allocator, face, '{', target, .vertical)) orelse
            return error.NoAssembly;
        // The joins brought the stack to exactly the requested size, and
        // nothing is left over: the fence holds its content.
        try testing.expectApproxEqAbs(target, planned.extent_em, 0.001);
        try testing.expectApproxEqAbs(@as(f32, 0), planned.excess_em, 0.001);

        const painted = (try paintStack(testing.allocator, face, '{', target, .vertical)) orelse
            return error.MissingGlyph;
        try testing.expectApproxEqAbs(target, painted.max - painted.min, 0.2);
        try testing.expect(painted.worst_gap <= 0.02);
    }
}

// A fixed-rule fence asks for a HEIGHT; the rung comes from that fence's own
// ladder, so every delimiter is sized by the rungs the font drew for it —
// not by whatever a threshold table happened to name for a parenthesis.
test "glyph: a fixed-rule fence takes the rung its own ladder designs" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;

    for ([_]u21{ '(', '|', 0x27E8, 0x2308 }) |cp| {
        const base_gid = face.glyphIndex(cp) orelse return error.MissingGlyph;
        const ladder = face.variants(base_gid) orelse return error.MissingGlyph;
        const tallest = ladder.advanceEm(ladder.len() - 1);
        for ([_]f32{ 0.8, 1.5, 2.392, 3.2 }) |req| {
            const chosen = coveringVariantGlyph(face, cp, req) orelse return error.MissingGlyph;
            if (req > tallest) {
                // This fence has nothing that tall: the honest answer is its
                // biggest rung, never a stretched copy of it.
                try testing.expectEqual(ladder.glyph(ladder.len() - 1), chosen);
                continue;
            }
            const ink = try glyphInk(testing.allocator, face, chosen);
            try testing.expect(ink.max - ink.min >= req - 0.01);
            // Nothing smaller does: the rung below the chosen one is short,
            // so this is the smallest rung that reaches.
            var rung: usize = ladder.len();
            for (0..ladder.len()) |i| {
                if (ladder.glyph(i) == chosen) {
                    rung = i;
                    break;
                }
            }
            try testing.expect(rung < ladder.len());
            if (rung > 0) {
                const below = try glyphInk(testing.allocator, face, ladder.glyph(rung - 1));
                try testing.expect(below.max - below.min < req);
            }
        }
    }
}

// Every horizontal form FITS the nucleus it is set on. XeTeX + unicode-math
// draws the LARGEST variant the nucleus still holds — the 0.920em hat over `M`
// (0.970em), not the 1.101em one that would span it; the 0.492em brace half
// under `x` (0.574em), not the 0.993em one — so a covering walk overpaints
// every accent and every brace by a rung. The face's own ladder is the
// authority and each rung's AdvanceMeasurement is the exact boundary: asking
// for a rung's own designed size takes THAT rung, never the next one up.
test "glyph: a horizontal form FITS its nucleus, taking the widest rung it holds" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;

    for ([_]u21{ 0x0302, 0x0303, 0x23DE, 0x23DF }) |cp| {
        const base_gid = face.glyphIndex(cp) orelse return error.MissingGlyph;
        const ladder = face.horizontalVariants(base_gid) orelse return error.MissingGlyph;
        for (0..ladder.len()) |rung| {
            const built = (try plan(testing.allocator, face, .{
                .cp = cp,
                .horizontal_req = ladder.advanceEm(rung),
            })) orelse return error.MissingGlyph;
            try testing.expectEqual(.single, std.meta.activeTag(built));
            try testing.expectEqual(ladder.glyph(rung), built.single.glyph);
            // A thousandth of an em under a rung's own designed size takes the
            // rung below it, so the boundary is the measurement itself.
            if (rung == 0) continue;
            const under = (try plan(testing.allocator, face, .{
                .cp = cp,
                .horizontal_req = ladder.advanceEm(rung) - 0.001,
            })) orelse return error.MissingGlyph;
            try testing.expectEqual(ladder.glyph(rung - 1), under.single.glyph);
        }
        // A nucleus narrower than every rung keeps the BASE drawing: the form
        // is never shrunk below the smallest thing the face drew for it.
        const narrow = (try plan(testing.allocator, face, .{
            .cp = cp,
            .horizontal_req = ladder.advanceEm(0) - 0.001,
        })) orelse return error.MissingGlyph;
        try testing.expectEqual(.single, std.meta.activeTag(narrow));
        try testing.expectEqual(base_gid, narrow.single.glyph);

        // The nuclei XeTeX was measured on at 20pt, and the rung each really
        // gets: over `M` (0.970em) and `abc` (1.391em) for an accent, under
        // `x` (0.574em), `\frac{a}{b}` (0.651em), `xx` (1.148em), `xxx`
        // (1.722em) and `xxxxxx` (3.445em) for a brace half.
        const nuclei: []const f32 = if (cp == 0x0302 or cp == 0x0303)
            &.{ 0.970, 1.391 }
        else
            &.{ 0.574, 0.651, 1.148, 1.722, 3.445 };
        for (nuclei) |nucleus| {
            const built = (try plan(testing.allocator, face, .{
                .cp = cp,
                .horizontal_req = nucleus,
            })) orelse return error.MissingGlyph;
            try testing.expectEqual(.single, std.meta.activeTag(built));
            // The widest rung the nucleus still holds, read off the face's
            // own measurements rather than named here.
            var fit: usize = 0;
            while (fit + 1 < ladder.len() and ladder.advanceEm(fit + 1) <= nucleus) fit += 1;
            try testing.expectEqual(ladder.glyph(fit), built.single.glyph);
            // The rung a covering walk would have taken really does span the
            // nucleus, so the two rules cannot pass for one another.
            try testing.expect(fit + 1 < ladder.len());
            try testing.expect(ladder.advanceEm(fit + 1) > nucleus);
            // A form that cannot assemble names its finite capacity — the
            // widest drawing the face has for it — so a caller can tell
            // "outgrew the font" from "fits inside it" without comparing
            // widths. A brace ASSEMBLES, so it names no ceiling at all.
            const geometry = (try stretchGeometry(testing.allocator, face, .{
                .cp = cp,
                .horizontal_req = nucleus,
            })) orelse return error.MissingGlyph;
            const ceiling = geometry.finite_ceiling_em;
            if (face.horizontalAssembly(base_gid) == null) {
                try testing.expectApproxEqAbs(
                    ladder.advanceEm(ladder.len() - 1),
                    ceiling orelse return error.MissingGlyph,
                    0.001,
                );
            } else {
                try testing.expect(ceiling == null);
            }
        }
    }
}

// Past the last rung the hat has nothing to assemble from — LM Math draws no
// horizontal extender for it — so the honest answer is its widest rung, not
// a guess. What it must never do is invent parts or stretch one.
test "glyph: a hat with no assembly degrades to its widest rung" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;
    const base = face.glyphIndex(0x0302) orelse return error.MissingGlyph;
    try testing.expect(face.horizontalAssembly(base) == null);
    const ladder = face.horizontalVariants(base) orelse return error.MissingGlyph;

    const built = (try plan(testing.allocator, face, .{
        .cp = 0x0302,
        .horizontal_req = 8.0,
    })) orelse return error.MissingGlyph;
    try testing.expectEqual(.single, std.meta.activeTag(built));
    try testing.expectEqual(ladder.glyph(ladder.len() - 1), built.single.glyph);
}

// A brace DOES grow along x, and past its last rung it does so from the
// face's own assembly: a left hook, repeated extenders and a right hook,
// placed left to right from the item's origin, joined without a hole and
// reaching the width the content under the brace needs.
test "glyph: a brace past its ladder assembles left to right to the requested width" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;

    const painted = (try paintStack(testing.allocator, face, 0x23DE, 5.0, .horizontal)) orelse
        return error.MissingGlyph;
    try testing.expect(painted.parts >= 3);
    try testing.expectApproxEqAbs(5.0, painted.max - painted.min, 0.2);
    try testing.expect(painted.worst_gap <= 0.02);
    // The hooks are the two ends of the run, not two copies of one piece.
    try testing.expect(painted.first_glyph != painted.last_glyph);

    // The walk starts at the item's own origin and only ever moves right.
    const built = (try plan(testing.allocator, face, .{
        .cp = 0x23DE,
        .horizontal_req = 5.0,
    })) orelse return error.MissingGlyph;
    try testing.expectEqual(.stack, std.meta.activeTag(built));
    var walk = built.stack;
    const first = walk.next() orelse return error.NoStack;
    try testing.expectEqual(@as(f32, 0), first.x_em);
    try testing.expectEqual(@as(f32, 0), first.y_em);
    var last_x: f32 = 0;
    while (walk.next()) |part| {
        try testing.expect(part.x_em > last_x);
        try testing.expectEqual(@as(f32, 0), part.y_em);
        last_x = part.x_em;
    }
}

// An accent is placed by its left edge and keeps its own height: a
// horizontal stack is NOT centred on the math axis the way a fence is.
test "glyph: a horizontal stack starts at the origin, not on the axis" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;
    const axis = (face.mathConstants() orelse return error.MissingGlyph).axis_height;

    const stretch = (try stretchGeometry(testing.allocator, face, .{
        .cp = 0x23DE,
        .horizontal_req = 6.0,
    })) orelse return error.MissingGlyph;
    try testing.expectApproxEqAbs(6.0, stretch.advance_em, 0.05);
    // An assembling brace reaches any width, so it names no ceiling.
    try testing.expect(stretch.finite_ceiling_em == null);
    // An overbrace sits ABOVE its content, so its ink stays off the axis.
    try testing.expect(stretch.ink.y_min > axis);
}

// The size a generator boxes against and the box the geometry paints are one
// measurement: the advance reaches the request, and the painted bounds
// cover the outline that actually draws it.
test "glyph: the reported advance and painted bounds are the geometry itself" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;

    for ([_]struct { cp: u21, req: f32, axis: Axis }{
        .{ .cp = '(', .req = 4.5, .axis = .vertical },
        .{ .cp = '{', .req = 12.0, .axis = .vertical },
        .{ .cp = 0x23DE, .req = 7.0, .axis = .horizontal },
        .{ .cp = 0x0302, .req = 1.5, .axis = .horizontal },
    }) |case| {
        const request = if (case.axis == .horizontal)
            Request{ .cp = case.cp, .horizontal_req = case.req }
        else
            Request{ .cp = case.cp, .delim_req = case.req };
        const stretch = (try stretchGeometry(testing.allocator, face, request)) orelse
            return error.MissingGlyph;
        const bounds = (try paintedBounds(testing.allocator, face, request)) orelse
            return error.MissingGlyph;
        const painted = bounds.y_max - bounds.y_min;
        try testing.expect(painted > 0);
        // The painted box is never taller than the extent the plan reports
        // plus a part's own overhang, and never a blank margin wider than the
        // stack itself: a connector is shared ink, not empty space.
        try testing.expect(painted <= stretch.advance_em + 0.5);
        if (case.axis == .horizontal) {
            try testing.expect(bounds.x_max > bounds.x_min);
        }
    }
}

/// The widest hmtx advance among the glyphs a plan PLACES, walked the way a
/// back end walks it — the independent answer `verticalGeometry` must match.
fn widestPlacedAdvance(face: *const font.FontFace, built: Plan) f32 {
    var walk = built;
    var widest: f32 = 0;
    switch (walk) {
        .single => |part| widest = face.advanceEm(part.glyph),
        .stack => |*cursor| {
            while (cursor.next()) |part| widest = @max(widest, face.advanceEm(part.glyph));
        },
    }
    return widest;
}

/// The one rule a vertical answer obeys, whatever asked for it: the advance
/// is the widest hmtx among the glyphs the back end PLACES, and the ink is
/// the union of their real outlines.
fn expectVerticalMatch(gpa: std.mem.Allocator, face: *font.FontFace, r: Request) !void {
    const built = (try plan(gpa, face, r)) orelse return error.NoPlan;
    const geo = (try verticalGeometry(gpa, face, r)) orelse return error.NoGeometry;
    try testing.expectEqual(widestPlacedAdvance(face, built), geo.advance_em);
    const painted = (try paintedBounds(gpa, face, r)) orelse return error.NoInk;
    try testing.expectEqual(painted.x_min, geo.ink.x_min);
    try testing.expectEqual(painted.x_max, geo.ink.x_max);
    try testing.expectEqual(painted.y_min, geo.ink.y_min);
    try testing.expectEqual(painted.y_max, geo.ink.y_max);
    // A WIDTH, with the parts' own side bearings left over — never a box as
    // wide as the fence is tall.
    try testing.expect(geo.advance_em < 2.0);
    try testing.expect(geo.advance_em >= geo.ink.x_max - geo.ink.x_min);
}

// A VERTICAL form reserves a WIDTH: the fence climbs the page, and what the
// generator needs beside the formula is how wide the form is, not how tall.
// Reporting the plan's extent along the growth axis as the advance is what
// made a 22 em pmatrix bracket box 22 em of page. Every request kind answers
// from the one resolution the back ends draw through, so the advance is the
// widest hmtx among the placed glyphs and the ink is their real union.
test "glyph: a vertical form reserves the width of the glyphs it places" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;
    const gpa = testing.allocator;

    // The base glyph...
    try expectVerticalMatch(gpa, face, .{ .cp = '(' });
    // ...every rung of this fence's own ladder...
    const ladder = face.variants(face.glyphIndex('(') orelse return error.MissingGlyph) orelse
        return error.MissingGlyph;
    for (0..ladder.len()) |rung| {
        try expectVerticalMatch(gpa, face, .{ .cp = '(', .delim_form = @intCast(rung + 1) });
    }
    // ...a FIXED-rule fence, which asks for a height and not a rung number...
    for ([_]f32{ 0.8, 2.392, 3.2 }) |req| {
        try expectVerticalMatch(gpa, face, .{ .cp = 0x2308, .delim_fixed = req });
    }
    // ...and the assemblies past the whole ladder.
    for ([_]f32{ 3.4, 6.0, 12.0 }) |req| {
        try expectVerticalMatch(gpa, face, .{ .cp = '(', .delim_req = req });
    }
}

// The regression for measuring a stream by its extent: a fence far taller
// than any realistic formula is assembled in FULL — hundreds of placements,
// none of them truncated or buffered — and still reserves exactly one fence
// of width beside the content.
test "glyph: a fence hundreds of parts tall reserves one fence of width" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;
    const request: Request = .{ .cp = '(', .delim_req = 200.0 };

    const built = (try plan(testing.allocator, face, request)) orelse return error.NoPlan;
    var walk = built.stack;
    var parts: usize = 0;
    while (walk.next()) |_| parts += 1;
    try testing.expect(parts > 64);

    const geo = (try verticalGeometry(testing.allocator, face, request)) orelse
        return error.NoGeometry;
    // Every part placed, so the ink really is 200 em of fence...
    try testing.expectApproxEqAbs(200.0, geo.ink.y_max - geo.ink.y_min, 1.0);
    // ...and the column it reserves is the WIDEST part, not that height.
    try testing.expectEqual(widestPlacedAdvance(face, built), geo.advance_em);
    try testing.expect(geo.advance_em < 1.0);
    // Centred on the axis, exactly as the ladder rung it replaces is.
    const axis = (face.mathConstants() orelse return error.MissingGlyph).axis_height;
    try testing.expectApproxEqAbs(axis, (geo.ink.y_max + geo.ink.y_min) / 2, 0.05);
}

// The resolver answers only what a face can honestly draw. A face with no
// MATH table degrades to its base cmap glyph — the base hmtx beside the base
// ink, exactly as the back ends degrade — and only a codepoint with no glyph
// at all, or a request that names no vertical form, is null.
test "glyph: vertical geometry degrades to base and nulls only on no glyph" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();

    const measured = (try verticalGeometry(testing.allocator, faces.roman, .{
        .cp = '(',
        .delim_form = 7,
        .delim_req = 5.0,
    })) orelse return error.MissingGlyph;
    const gid = faces.roman.glyphIndex('(') orelse return error.MissingGlyph;
    try testing.expectEqual(faces.roman.advanceEm(gid), measured.advance_em);
    const own = (try glyphBox(testing.allocator, faces.roman, gid)) orelse
        return error.NoInk;
    try testing.expectEqual(own.y_max, measured.ink.y_max);

    var math = try mathTest(testing.allocator);
    defer math.ctx.deinit();
    try testing.expectEqual(
        @as(?Stretch, null),
        try verticalGeometry(testing.allocator, math.face, .{ .cp = 0xE000, .delim_req = 5.0 }),
    );
    // A horizontal request grows along x and names no vertical form.
    try testing.expectEqual(
        @as(?Stretch, null),
        try verticalGeometry(testing.allocator, math.face, .{
            .cp = 0x23DE,
            .horizontal_req = 5.0,
        }),
    );
}

// A run that asks for no stretch has no stretch geometry to report: the
// caller sizes it with the ordinary metrics. The painted bounds are still
// the glyph's own outline, because a back end frames what is drawn.
test "glyph: an ordinary run reports no stretch geometry" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    try testing.expectEqual(
        @as(?Stretch, null),
        try stretchGeometry(testing.allocator, both.face, .{ .cp = 'x' }),
    );
    const bounds = (try paintedBounds(testing.allocator, both.face, .{ .cp = 'x' })) orelse
        return error.MissingGlyph;
    const gid = both.face.glyphIndex('x') orelse return error.MissingGlyph;
    const own = (try glyphBox(testing.allocator, both.face, gid)) orelse
        return error.MissingGlyph;
    try testing.expectApproxEqAbs(own.x_min, bounds.x_min, 0.0001);
    try testing.expectApproxEqAbs(own.y_max, bounds.y_max, 0.0001);
}

// A face with no MATH table, or a codepoint with no assembly, must degrade to
// what it can honestly draw — the rung, then the base glyph — never to
// nothing, which would drop a fence from the formula entirely.
test "glyph: an unassemblable fence degrades to a glyph instead of vanishing" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const latin = try plan(testing.allocator, faces.roman, .{
        .cp = '(',
        .delim_form = 7,
        .delim_req = 5.0,
    });
    // LM Roman has no MATH table at all: the request still answers with its
    // own base glyph.
    const fallback = latin orelse return error.MissingGlyph;
    try testing.expectEqual(.single, std.meta.activeTag(fallback));
    // The size it reports is then the base glyph's own advance, not an
    // invented height: a face with no MATH table cannot promise a fence.
    const measured = (try stretchGeometry(testing.allocator, faces.roman, .{
        .cp = '(',
        .delim_req = 5.0,
    })) orelse return error.MissingGlyph;
    const gid = faces.roman.glyphIndex('(') orelse return error.MissingGlyph;
    try testing.expectApproxEqAbs(
        faces.roman.advanceEm(gid),
        measured.advance_em,
        0.0001,
    );
    const math = try plan(testing.allocator, faces.math, .{ .cp = 0xE000, .delim_req = 5.0 });
    try testing.expect(math == null); // a codepoint with no glyph has nothing to draw
}

// A codepoint with no glyph draws nothing at all rather than borrowing an id
// from another font's numbering.
test "glyph: a codepoint no face maps has nothing to draw" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    try testing.expectEqual(
        @as(?Plan, null),
        try plan(testing.allocator, both.face, .{ .cp = 0xE000 }),
    );
}

// Every rung of a ladder is a different drawing of a different height, which
// is what makes a stretched fence a fence rather than a scaled base glyph.
test "glyph: a fence grows through its ladder, one distinct shape per rung" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;
    const paren = face.glyphIndex('(') orelse return error.MissingGlyph;
    const ladder = face.variants(paren) orelse return error.MissingGlyph;
    try testing.expect(ladder.len() >= 7);

    var previous_gid: ?u32 = null;
    for (0..ladder.len()) |rung| {
        const built = (try plan(testing.allocator, face, .{
            .cp = '(',
            .delim_form = @intCast(rung + 1),
        })) orelse return error.MissingGlyph;
        try testing.expectEqual(.single, std.meta.activeTag(built));
        const placed = built.single;
        try testing.expect(placed.x_em == 0);
        try testing.expect(placed.y_em == 0);
        try testing.expect(placed.glyph != previous_gid);
        previous_gid = placed.glyph;
        const ink = try glyphInk(testing.allocator, face, placed.glyph);
        try testing.expectApproxEqAbs(ladder.advanceEm(rung), ink.max - ink.min, 0.01);
    }
}

// A display big operator is a different DRAWING, not the base form at a
// bigger size: the display form is taller, and the unmarked operator is the
// base form at the item's own baseline.
test "glyph: a display big operator draws its own variant, not the base form" {
    var both = try mathTest(testing.allocator);
    defer both.ctx.deinit();
    const face = both.face;
    const base_gid = face.glyphIndex(0x2211) orelse return error.MissingGlyph;
    const built = (try plan(testing.allocator, face, .{
        .cp = 0x2211,
        .bigop_variant = true,
    })) orelse return error.MissingGlyph;
    const variant = built.single;
    try testing.expect(variant.glyph != base_gid);
    const variant_ink = try glyphInk(testing.allocator, face, variant.glyph);
    const base_ink = try glyphInk(testing.allocator, face, base_gid);
    try testing.expect(variant_ink.max - variant_ink.min > base_ink.max - base_ink.min);
    const plain = (try plan(testing.allocator, face, .{ .cp = 0x2211 })) orelse
        return error.MissingGlyph;
    try testing.expectEqual(base_gid, plain.single.glyph);
}

test "glyph: dropped leading extenders do not leave a phantom first join" {
    // Three MATH PartRecords: one optional leading extender and two caps.
    const bytes = [_]u8{
        0, 1, 0, 50,  0, 50,  1, 244, 0, 1,
        0, 2, 0, 100, 0, 100, 3, 232, 0, 0,
        0, 3, 0, 100, 0, 100, 3, 232, 0, 0,
    };
    var cursor: Iterator = .{
        .stack = .{ .italic_correction = 0, .parts = &bytes, .units_per_em = 1000 },
        .axis = .horizontal,
        .repeats = 0,
        .trim = 0,
        .shift = 0,
        .extent_em = 1.98,
        .excess_em = 0,
        .min_overlap = 0.02,
    };
    const first = cursor.next() orelse return error.TestUnexpectedResult;
    const second = cursor.next() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), first.glyph);
    try testing.expectEqual(@as(u32, 3), second.glyph);
    try testing.expectApproxEqAbs(@as(f32, 0), first.x_em, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.98), second.x_em, 0.0001);
    try testing.expectEqual(@as(?Placed, null), cursor.next());
}
