//! ztex.svg — serialize a draw list into SVG.
//!
//! The draw model uses baseline-anchored coordinates (y = baseline; ascent is
//! negative). SVG is top-down, so this module offsets every primitive from
//! the frame origin — the draw list's INK minimum (see `render`) — so all
//! content sits at non-negative x and y inside the viewBox.
//!
//! Glyphs are emitted as OUTLINES, one `<path>` per draw item, taken from the
//! very faces the rasterizer fills (`Options.fonts`, or ztex's own embedded
//! Latin Modern). A `<text>` run is the browser's own typesetting: it snaps
//! the baseline onto its device pixel grid, so the run lands up to half a
//! pixel off the frame the layout measured and the root element clips
//! whatever pokes past it. Path geometry has no such snap, and it keeps the
//! browser's own font substitution out of the document: what is painted is
//! the shape ztex measured. A run naming a glyph no face carries is the one
//! exception — there is no outline to draw it from — and stays an escaped
//! `<text>` run in the caller's own CSS stack.
//! Use `render`, then free its bytes with the supplied allocator; it performs
//! no I/O. `writeFile` instead borrows explicit I/O and directory capabilities.

const std = @import("std");
const layout = @import("ztex.layout");
const font = @import("ztex.font");
const glyph = @import("ztex.glyph");
const draw = layout.draw;
const atom = draw.atom;

/// Point-coordinate framing and optional font/fallback styling.
/// Slices and `fonts` are borrowed only for the serialization call.
pub const Options = struct {
    /// empty margin around the content, on every side (pt). Must be 0 or
    /// greater; a negative margin is `error.InvalidArgument` and a
    /// non-finite one `error.NonFiniteCoordinate`.
    padding: f32 = 0,
    /// A fill covering the frame; `null` leaves the background transparent.
    background: ?draw.Color = null,
    /// CSS family stack for a math run (italic variables, operators, big
    /// ops) that names a glyph no face carries: with outlines, the only
    /// runs that reach a `<text>` element, so this names the browser's
    /// stack for them and for nothing else.
    font_family: []const u8 = "Latin Modern Math, Latin Modern Roman, DejaVu Serif, serif",
    /// the same, for an upright run (\text, \mathrm, \mathbf, …)
    text_font_family: []const u8 = "Latin Modern Roman, DejaVu Serif, serif",
    /// The faces EVERY glyph outline is resolved from, an ordinary letter
    /// included: a display big operator, a tall `\sqrt`, a `\left`/`\right`
    /// fence taller than its base glyph and a plain `x` are all painted as
    /// real path geometry from these tables, so a plain browser shows the
    /// same shapes the rasterizer draws. `null` builds ztex's own embedded
    /// Latin Modern faces for the length of the call, and a draw list with
    /// no text in it never builds them at all; a pointer borrows the
    /// caller's faces for the call. Serialize access to this context;
    /// resolving glyphs can mutate its caches.
    fonts: ?*font.FontContext = null,
};

/// SVG font attributes for one CharStyle, carried by the runs that stay
/// TEXT: a run whose glyphs the faces carry is painted as outline geometry
/// and names no family at all (see the module doc). Math (italic) runs use
/// the math family, whose glyphs are italic by design; roman/bold runs
/// switch to the upright text family so \text/\mathrm render upright instead
/// of in the math font's italic shapes. The text-italic styles are TEXT
/// italic, not math italic: they take the text family and declare
/// font-style italic. Italic math is encoded in the glyph itself, so its
/// face stays normal. Text slants use font-style instead.
const FontSpec = struct {
    family: []const u8,
    style: []const u8,
    /// css font-weight; empty string = normal
    weight: []const u8,
};

fn fontSpec(style: atom.CharStyle, opts: *const Options) FontSpec {
    return switch (style) {
        .italic => .{ .family = opts.font_family, .style = "normal", .weight = "" },
        .roman => .{ .family = opts.text_font_family, .style = "normal", .weight = "" },
        .bold => .{ .family = opts.text_font_family, .style = "normal", .weight = "bold" },
        // letter variants: LMMath carries blackboard/script/fraktur glyphs.
        .bb, .cal, .frak => .{ .family = opts.font_family, .style = "normal", .weight = "" },
        // Sans and mono are MATH ALPHABET faces: LMMath carries the styled
        // glyphs, so they resolve against the same math stack the CPU draws
        // them from rather than a hardcoded DejaVu family that would
        // substitute a different letterform (or nothing) at the same slot.
        .sans, .mono => .{ .family = opts.font_family, .style = "normal", .weight = "" },
        // text italic (TEXT slant on the upright family) and its bold
        // combination: nested \textbf/\textit reach bold_italic.
        .text_italic => .{ .family = opts.text_font_family, .style = "italic", .weight = "" },
        .bold_italic => .{ .family = opts.text_font_family, .style = "italic", .weight = "bold" },
    };
}

/// Allocation, option, coordinate, or font-decoding failures while serializing.
pub const Error = error{ OutOfMemory, NonFiniteCoordinate, InvalidArgument } || font.FontError;

/// Serialization, file creation, or file writing failures, including cancellation.
pub const WriteError = Error || std.Io.File.OpenError || std.Io.File.Writer.Error;

/// Serialize the list into independently owned SVG bytes; free them with `gpa`.
///
/// Borrows the list, its source bytes, and option slices/faces for this call.
/// The result retains none of them. Failure releases temporary document/font
/// allocations and returns no partial document; supplied font caches may grow.
/// A negative margin is `error.InvalidArgument`; non-finite geometry, including
/// padding, is `error.NonFiniteCoordinate`. Missing glyphs use escaped text
/// fallback; malformed available outlines return `font.FontError`.
///
/// Performs no I/O or cancellation. Independent calls may run concurrently
/// with thread-safe allocators and inputs; a shared font context needs a lock.
pub fn render(
    gpa: std.mem.Allocator,
    dl: *const draw.DrawList,
    opts: Options,
) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    // Checked before anything is built, so a bad margin costs no document.
    // A NaN margin is not negative (every comparison with it is false), so
    // it passes here and is named for what it is by checkFinite below.
    if (opts.padding < 0) return error.InvalidArgument;

    // The frame is the INK bounds, not the box bounds: boxes under-bind the
    // drawn glyphs (italic overhang past the advance, a display variant
    // taller than the box that sized it), so a frame built on them clips the
    // ink that is actually drawn.
    const ink = dl.bounds();

    const pad_x = opts.padding;
    const pad_top = opts.padding;
    const pad_bottom = opts.padding;
    const w = ink.width + 2 * pad_x;
    const h = ink.height + ink.depth + pad_top + pad_bottom;
    // The frame origin is its top-left corner, so the INK MINIMUM (which is
    // not the root reference point: a fraction's ink starts at its
    // 1.2pt-inset numerator) lands on the frame margin. Every primitive
    // takes the same offset, which keeps it inside the frame.
    const off_x = pad_x - ink.min_x;
    const off_y = pad_top - ink.min_y;
    try checkFinite(&.{ w, h, off_x, off_y });

    // Outer dimensions set the physical point size. The viewBox maps each
    // unitless inner coordinate to one point; inner `pt` would scale twice.
    try buf.print(
        gpa,
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}pt\" height=\"{d}pt\" viewBox=\"0 0 {d} {d}\">\n",
        .{ w, h, w, h },
    );
    if (opts.background) |bg| {
        try buf.print(gpa, "<rect width=\"{d}\" height=\"{d}\" fill=\"#{s}\"/>\n", .{ w, h, colorHex(bg) });
    }

    // The faces every outline comes from are built only when the draw list
    // actually has text to paint: a formula of rules and lines never parses
    // a font, and a caller that supplied its own context pays nothing at
    // all. One context serves the whole document and is released before
    // this returns.
    var own_fonts: OwnedFonts = .{};
    defer if (own_fonts.initialized) own_fonts.value.deinit();

    for (dl.items.items) |d| {
        switch (d) {
            .text => |t| {
                // Glyphs are painted as real outline geometry, the shapes
                // and advances the rasterizer fills (see `emitOutlines`).
                // The faces are built, or borrowed, on the first item that
                // names a codepoint and one context serves the document.
                if (requestOf(t)) |request| {
                    const faces = try facesFor(gpa, &own_fonts, opts);
                    const painted = try emitOutlines(gpa, &buf, faces, request, t, off_x, off_y);
                    // A run of blank glyphs advances the pen and paints
                    // nothing. It is not a missing glyph, so it is never
                    // named as text either.
                    if (painted.outcome == .blank) continue;
                    if (painted.outcome == .outlined) {
                        // Bytes no face could draw stay text, in ONE node
                        // that starts where the outline pass stopped: a
                        // painted byte is never named twice and no byte of
                        // the run is dropped.
                        if (painted.tail.len > 0) {
                            try emitText(
                                gpa,
                                &buf,
                                t,
                                painted.pen_x,
                                t.y + off_y,
                                painted.tail,
                                opts,
                            );
                        }
                        continue;
                    }
                }
                // A codepoint no face carries is the one case a text run
                // answers, and the whole run is that text.
                try emitText(gpa, &buf, t, t.x + off_x, t.y + off_y, t.bytes, opts);
            },
            .rect => |r| {
                try checkFinite(&.{ r.x + off_x, r.y + off_y, r.w, r.h });
                try buf.print(
                    gpa,
                    "<rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"#{s}\"/>\n",
                    .{ r.x + off_x, r.y + off_y, r.w, r.h, colorHex(r.color) },
                );
            },
            .line => |l| {
                try checkFinite(&.{
                    l.x0 + off_x, l.y0 + off_y, l.x1 + off_x, l.y1 + off_y, l.width,
                });
                // A filled band avoids browser hairline-stroke rounding at
                // subpixel widths. Its four corners are the exact butt-cap
                // geometry layout frames and the CPU rasterizer covers.
                const dx = l.x1 - l.x0;
                const dy = l.y1 - l.y0;
                const length = std.math.hypot(dx, dy);
                if (length == 0 or l.width <= 0) continue;
                const nx = -dy / length * (l.width / 2);
                const ny = dx / length * (l.width / 2);
                const x0 = l.x0 + off_x;
                const y0 = l.y0 + off_y;
                const x1 = l.x1 + off_x;
                const y1 = l.y1 + off_y;
                const points = [4][2]f32{
                    .{ x0 + nx, y0 + ny }, .{ x1 + nx, y1 + ny },
                    .{ x1 - nx, y1 - ny }, .{ x0 - nx, y0 - ny },
                };
                for (&points) |*point| try checkFinite(point);
                try buf.print(
                    gpa,
                    "<path d=\"M {d} {d} L {d} {d} L {d} {d} L {d} {d} Z\" fill=\"#{s}\"/>\n",
                    .{
                        points[0][0],      points[0][1], points[1][0], points[1][1],
                        points[2][0],      points[2][1], points[3][0], points[3][1],
                        colorHex(l.color),
                    },
                );
            },
        }
    }
    try buf.appendSlice(gpa, "</svg>\n");
    return buf.toOwnedSlice(gpa);
}

/// The MATH form one draw item asks for, forwarded verbatim: `ztex.glyph`
/// decides which glyph that is, from the face's own tables. Null when the
/// run names no codepoint at all, and then the run stays text.
fn requestOf(t: draw.Text) ?glyph.Request {
    return glyph.requestFor(t.bytes, .{
        .bigop_variant = t.bigop_form == .variant,
        .radical_form = t.radical_form,
        .delim_form = t.delim_form,
        .delim_fixed = t.delim_fixed,
        .delim_req = t.delim_req,
        .horizontal_req = t.horizontal_req,
    });
}

const OwnedFonts = struct {
    value: font.FontContext = undefined,
    initialized: bool = false,
};

/// The faces every outline in this document is resolved from: the caller's
/// context when it supplied one, and otherwise ztex's own embedded faces,
/// built on the first item that names a codepoint and reused for the rest
/// of the document. A draw list with no text in it never reaches here and
/// never parses a font.
fn facesFor(
    gpa: std.mem.Allocator,
    own: *OwnedFonts,
    opts: Options,
) !*font.FontContext {
    if (opts.fonts) |faces| return faces;
    if (!own.initialized) {
        own.value = try font.FontContext.init(gpa);
        own.initialized = true;
    }
    return &own.value;
}

/// An outline pass paints a resolved prefix (`outlined`), resolves only blank
/// glyphs (`blank`), or cannot paint any prefix before an unavailable glyph
/// (`unresolvable`). An outlined prefix can leave a tail for external text.
const Outcome = enum { outlined, blank, unresolvable };

/// What one run's outline pass made of it, and where it stopped: the run's
/// remaining BYTES are the ones no face could draw, and an empty `tail`
/// means every byte of the run was painted. `pen_x` is already in document
/// space.
const Painted = struct {
    outcome: Outcome,
    pen_x: f32,
    tail: []const u8,
};

/// Paint one run as real outline geometry and report what it could not.
///
/// A stretchy item paints the MATH form the layout boxed, one glyph or a
/// whole assembly; an ordinary run paints one outline per codepoint, each
/// at its face's own origin and advancing by that face's own hmtx advance
/// — the advance the CPU reserves for the same codepoint, so a
/// multi-codepoint run lands exactly where layout put it. A blank glyph (a
/// space) advances and paints nothing, exactly as the rasterizer leaves it.
/// The first codepoint is the one `requestFor` already decoded, so the
/// walk never decodes the same bytes twice.
///
/// The coordinates are ABSOLUTE, unitless and in the same space as every
/// other primitive, so the frame, the painter order and a consumer's
/// geometry check all read one coordinate system. Font units are Y-up and
/// the document is Y-down, so the rise is subtracted exactly once, here —
/// the same transform `raster.rasterize` applies to the same outline. One
/// path element carries the whole run, so its fill — the run's color, alpha
/// included — is applied once. `data-text`, `data-x`, `data-y` and
/// `font-size` are metadata: they say which run this is and where its
/// baseline sits, so an analysis tool can group and compare glyphs, and
/// none of them is geometry the renderer needs.
fn emitOutlines(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    faces: *font.FontContext,
    request: glyph.Request,
    t: draw.Text,
    off_x: f32,
    off_y: f32,
) !Painted {
    const base_x = t.x + off_x;
    const base_y = t.y + off_y;
    try checkFinite(&.{ base_x, base_y, t.size });

    const path_start = buf.items.len;
    try buf.appendSlice(gpa, "<path d=\"");
    var drawn: usize = 0;
    var complete = false;
    var pen_x = base_x;
    var painted: usize = 0;
    if (glyph.needsGeometry(request)) {
        // A stretchy item is a MATH construction whatever style it was typed
        // in: `\mathrm{\sqrt{x}}` still draws the math font's radical, which
        // is what XeTeX draws and what layout boxed. Resolving it against
        // the style's face would hand back that face's plain U+221A — a
        // short mark with a detached bar — or, on a face with no MATH table,
        // no variant at all.
        const face = faces.math;
        const scale = t.size / @as(f32, @floatFromInt(face.unitsPerEm()));
        if (try glyph.plan(gpa, face, request)) |built| {
            drawn = try appendPlan(gpa, buf, face, built, base_x, base_y, t.size, scale);
        }
        // The item names the one codepoint its construction is keyed under,
        // and the glyph painted is that codepoint's form of it, so the whole
        // item is resolved or none of it is. A construction this face has no
        // outline for at all stays the caller's text.
        painted = std.unicode.utf8ByteSequenceLength(t.bytes[0]) catch 0;
        complete = drawn > 0 and painted > 0;
    } else {
        var i: usize = 0;
        var cp = request.cp;
        while (true) {
            const width = std.unicode.utf8ByteSequenceLength(t.bytes[i]) catch break;
            if (i + width > t.bytes.len) break;
            // The style's own face when it carries the codepoint, the math
            // face when only that one does: the routing the rasterizer and
            // the layout metrics share, so a run is measured from the face
            // that draws it.
            const face = faces.faceForCodepoint(cp, t.style);
            const gid = font.resolvedGlyphId(face, cp, t.size) orelse break;
            const scale = t.size / @as(f32, @floatFromInt(face.unitsPerEm()));
            drawn += try appendGlyph(gpa, buf, face, gid, pen_x, base_y, scale);
            pen_x += face.advanceEm(gid) * t.size;
            i += width;
            cp = glyph.codepointOf(t.bytes[i..]) orelse break;
        }
        painted = i;
        // The walk consumed the run whole, or stopped at a codepoint no face
        // carries — the one thing only a text run can answer.
        complete = i == t.bytes.len;
    }
    if (drawn == 0) {
        // Blank or unavailable runs have no contours to close. Rewind the
        // empty path; an available prefix with ink is preserved below.
        buf.shrinkRetainingCapacity(path_start);
        return .{
            .outcome = if (complete) .blank else .unresolvable,
            .pen_x = base_x,
            .tail = t.bytes,
        };
    }
    if (t.radical_bar) |bar| {
        const x = base_x + bar.x;
        const y = base_y + bar.y;
        try checkFinite(&.{ x, y, bar.w, bar.h, x + bar.w, y + bar.h });
        if (bar.w > 0 and bar.h > 0) {
            // Match the outer font contour's winding after the Y inversion.
            try buf.print(gpa, "M {d} {d} V {d} H {d} V {d} Z", .{
                x, y, y + bar.h, x + bar.w, y,
            });
        }
    }
    try buf.print(
        gpa,
        "\" fill=\"#{s}\" font-size=\"{d}\" data-x=\"{d}\" data-y=\"{d}\" data-text=\"",
        .{ colorHex(t.color), t.size, base_x, base_y },
    );
    try escapeAppend(gpa, buf, t.bytes[0..painted]);
    try buf.appendSlice(gpa, "\"/>\n");
    return .{
        .outcome = .outlined,
        .pen_x = pen_x,
        .tail = t.bytes[painted..],
    };
}

/// Emit one run as an SVG text run at an already-offset position: the honest
/// answer for bytes no face carries, and the only place a family is named.
/// Both family options are caller-supplied (Options), so they are escaped
/// like text content: a `"` would otherwise break the attribute or allow
/// attribute injection. `bytes` is the part of the run this element paints,
/// which is the whole run unless its leading codepoints were drawn as
/// outlines first.
fn emitText(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    t: draw.Text,
    x: f32,
    y: f32,
    bytes: []const u8,
    opts: Options,
) !void {
    const fs = fontSpec(t.style, &opts);
    try checkFinite(&.{ x, y, t.size });
    try buf.print(
        gpa,
        "<text x=\"{d}\" y=\"{d}\" font-size=\"{d}\" font-family=\"",
        .{ x, y, t.size },
    );
    try escapeAppend(gpa, buf, fs.family);
    try buf.print(gpa, "\" font-style=\"{s}\"", .{fs.style});
    if (fs.weight.len > 0) {
        try buf.print(gpa, " font-weight=\"{s}\"", .{fs.weight});
    }
    try buf.print(gpa, " fill=\"#{s}\">", .{colorHex(t.color)});
    try escapeAppend(gpa, buf, bytes);
    try buf.append(gpa, '<');
    try buf.appendSlice(gpa, "/text>\n");
}

/// Append one placed glyph's contours to a path's `d`. A placement carries
/// its run along BOTH axes in em: `y_em` is the part's rise above the run's
/// baseline (a vertical stack) and `x_em` is its distance right of the item's
/// own origin (a horizontal one). Font units rise inside the glyph and the
/// document's y grows down, so the rise is subtracted exactly once here —
/// the same transform `raster.rasterize` applies to the same outline.
fn appendPlaced(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    face: *font.FontFace,
    part: glyph.Placed,
    base_x: f32,
    base_y: f32,
    size: f32,
    scale: f32,
) !usize {
    return appendGlyph(
        gpa,
        buf,
        face,
        part.glyph,
        base_x + part.x_em * size,
        base_y - part.y_em * size,
        scale,
    );
}

/// Append every placement a resolved plan carries, one part at a time, and
/// return how many contours were written.
fn appendPlan(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    face: *font.FontFace,
    built: glyph.Plan,
    base_x: f32,
    base_y: f32,
    size: f32,
    scale: f32,
) !usize {
    var drawn: usize = 0;
    switch (built) {
        .single => |part| {
            drawn = try appendPlaced(gpa, buf, face, part, base_x, base_y, size, scale);
        },
        .stack => |copy| {
            // One path for the whole stack, every part as its own contour
            // runs: a tall fence is one logical glyph however many pieces it
            // is built from.
            var stack = copy;
            while (stack.next()) |part| {
                drawn += try appendPlaced(gpa, buf, face, part, base_x, base_y, size, scale);
            }
        },
    }
    return drawn;
}

/// Append one glyph's contours to a path's `d`, with the glyph's own origin
/// at (x_base, y_base) in document space, and return how many contours were
/// written. Zero for a blank glyph: its outline is empty, so it paints
/// nothing and the run's advance carries on from where it stood.
fn appendGlyph(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    face: *font.FontFace,
    gid: u32,
    x_base: f32,
    y_base: f32,
    scale: f32,
) !usize {
    var outline = try face.glyphOutline(gpa, gid);
    defer outline.deinit();
    return appendContours(gpa, buf, outline.curves.items, x_base, y_base, scale);
}

/// Append one glyph's contours as `M … Q … Z` runs and return how many were
/// written. Contours are the maximal runs whose endpoint meets the next
/// curve's start point, the same boundary the rasterizer walks.
fn appendContours(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    curves: []const font.QuadCurve,
    x_base: f32,
    y_base: f32,
    scale: f32,
) !usize {
    var written: usize = 0;
    var run_start: usize = 0;
    var i: usize = 0;
    while (i < curves.len) : (i += 1) {
        const at_end = i + 1 == curves.len;
        const boundary = !at_end and (curves[i].p2[0] != curves[i + 1].p0[0] or
            curves[i].p2[1] != curves[i + 1].p0[1]);
        if (!at_end and !boundary) continue;
        try buf.append(gpa, 'M');
        try appendPoint(gpa, buf, curves[run_start].p0, x_base, y_base, scale);
        for (curves[run_start .. i + 1]) |c| {
            try buf.append(gpa, 'Q');
            try appendPoint(gpa, buf, c.p1, x_base, y_base, scale);
            try appendPoint(gpa, buf, c.p2, x_base, y_base, scale);
        }
        try buf.appendSlice(gpa, "Z");
        written += 1;
        run_start = i + 1;
    }
    return written;
}

fn appendPoint(
    gpa: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    point: [2]f32,
    x_base: f32,
    y_base: f32,
    scale: f32,
) !void {
    const x = x_base + point[0] * scale;
    const y = y_base - point[1] * scale;
    try checkFinite(&.{ x, y });
    try buf.print(gpa, " {d} {d}", .{ x, y });
}

/// Render, then create/truncate `path` relative to `dir` and write the SVG.
///
/// `io`, `dir`, and the platform-native path bytes are borrowed for this
/// blocking call and are not retained; the directory remains caller-owned.
/// Rendering failure leaves the file untouched. After creation, a write error
/// or cancellation can leave an empty file or a prefix; this is not an atomic
/// replacement. All temporary allocations and the opened file are released.
pub fn writeFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    dl: *const draw.DrawList,
    opts: Options,
) WriteError!void {
    const svg = try render(gpa, dl, opts);
    defer gpa.free(svg);
    var file = try std.Io.Dir.createFile(dir, io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, svg);
}

fn colorHex(c: draw.Color) [8]u8 {
    return .{
        hexDigit(c.r >> 4),
        hexDigit(c.r & 0x0f),
        hexDigit(c.g >> 4),
        hexDigit(c.g & 0x0f),
        hexDigit(c.b >> 4),
        hexDigit(c.b & 0x0f),
        hexDigit(c.a >> 4),
        hexDigit(c.a & 0x0f),
    };
}

fn hexDigit(value: u8) u8 {
    return "0123456789abcdef"[value & 0x0f];
}

/// Fail loudly (error) rather than emit `nan`/`inf` into the SVG. A
/// non-finite coordinate would otherwise be printed verbatim by `{d}` and
/// produce a broken/invisible document.
fn checkFinite(vals: []const f32) !void {
    for (vals) |v| {
        if (!std.math.isFinite(v)) return error.NonFiniteCoordinate;
    }
}

/// XML-escape text content: `& < > "`.
fn escapeAppend(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try buf.appendSlice(gpa, "&amp;"),
            '<' => try buf.appendSlice(gpa, "&lt;"),
            '>' => try buf.appendSlice(gpa, "&gt;"),
            '"' => try buf.appendSlice(gpa, "&quot;"),
            else => try buf.append(gpa, c),
        }
    }
}

// ── tests ────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

const black = draw.Color{ .r = 0, .g = 0, .b = 0 };

/// A draw list shaped like a laid-out `\frac{1}{2}` at 20pt: a numerator
/// run, the rule, a denominator run. Each run's ink is the one `addRun`
/// measures from the faces, so the frame is asked to hold the outlines the
/// document really carries. The ink origin is NOT the root reference
/// point: a fraction pads its parts by TeX's 1.2pt nulldelimiterspace, so
/// the leftmost ink starts at x = 1.2. The BOX bounds stay 0 — a box that
/// under-binds the drawn ink is exactly the case the frame must survive.
fn fractionDrawList(gpa: std.mem.Allocator, faces: *font.FontContext) !draw.DrawList {
    var dl = draw.DrawList.init(gpa);
    errdefer dl.deinit();
    try addRun(&dl, gpa, faces, .{
        .bytes = "1",
        .x = 1.2,
        .y = -13,
        .size = 20,
        .style = .italic,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    });
    try dl.add(.{ .rect = .{
        .x = 1.2,
        .y = -5,
        .w = 10,
        .h = 0.8,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    } });
    dl.accInk(1.2, -5, 11.2, -4.2);
    try addRun(&dl, gpa, faces, .{
        .bytes = "2",
        .x = 1.2,
        .y = 13,
        .size = 20,
        .style = .italic,
        .color = black,
        .src_start = 1,
        .src_end = 2,
    });
    return dl;
}

/// Add one text run together with the ink the draw list records for it:
/// every codepoint's advance box UNIONED with the outline the face draws for
/// it, which is what `flatten` accumulates. The advance is the one the same
/// face's hmtx carries, so a multi-codepoint run is framed over the width it
/// really occupies. A blank codepoint contributes its advance and no ink.
fn addRun(
    dl: *draw.DrawList,
    gpa: std.mem.Allocator,
    faces: *font.FontContext,
    t: draw.Text,
) !void {
    try dl.add(.{ .text = t });
    var pen = t.x;
    var i: usize = 0;
    while (i < t.bytes.len) {
        const width = std.unicode.utf8ByteSequenceLength(t.bytes[i]) catch return error.BadUtf8;
        const cp = glyph.codepointOf(t.bytes[i..]) orelse return error.BadUtf8;
        const face = faces.faceForCodepoint(cp, t.style);
        const gid = font.resolvedGlyphId(face, cp, t.size) orelse return error.MissingGlyph;
        const advance = face.advanceEm(gid) * t.size;
        const ink = try outlineBox(gpa, face, gid, t.size, pen, t.y);
        if (ink.x0 <= ink.x1) {
            dl.accInk(@min(ink.x0, pen), ink.y0, @max(ink.x1, pen + advance), ink.y1);
        } else {
            // A blank outline paints nothing; its advance is all there is.
            dl.accInk(pen, t.y, pen + advance, t.y);
        }
        pen += advance;
        i += width;
    }
}

/// The frame the primitives live in: the viewBox width/height. The root
/// element declares the same numbers in pt, so a mismatch would render the
/// document at other than its declared physical size.
const Frame = struct { w: f32, h: f32 };

fn frameOf(svg: []const u8) !Frame {
    const at = std.mem.indexOf(u8, svg, "viewBox=\"0 0 ") orelse return error.MissingAttribute;
    var i = at + "viewBox=\"0 0 ".len;
    const w = try scanNum(svg, &i);
    const h = try scanNum(svg, &i);
    try testing.expectApproxEqAbs(w, try attrNumber(svg, " width=\""), 0.001);
    try testing.expectApproxEqAbs(h, try attrNumber(svg, " height=\""), 0.001);
    return .{ .w = w, .h = h };
}

/// The shift every primitive takes from its draw-list coordinate: the
/// frame's own origin.
const Shift = struct { x: f32, y: f32 };

/// The frame invariant, for a whole document:
///   - every emitted primitive lies inside the frame, at a non-negative
///     coordinate;
///   - every primitive takes the SAME shift, and that shift puts the frame
///     origin on the INK minimum: the ink top lands on the top edge (the
///     vertical ink is exact) and the horizontal margin is caller padding.
/// Walks the emitted elements in painter order, zipped with the draw
/// list's primitives. Every primitive must be visited: an element `render`
/// emitted outside the draw list (the background rect) or not at all (the
/// root, the closing tag) carries no geometry and is skipped, so the zip
/// stays aligned. An item that paints nothing — a run of blank glyphs —
/// emits no element at all and breaks the zip, so a draw list carrying one
/// is not a candidate for this walk.
fn expectInsideFrame(svg: []const u8, dl: *const draw.DrawList, frame: Frame) !void {
    const ink = dl.bounds();
    var shift: ?Shift = null;

    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, svg, '\n');
    while (lines.next()) |line| {
        if (checked == dl.len()) break;
        const box = emittedBox(line) orelse continue;
        const d = dl.items.items[checked];
        try testing.expect(box.x0 >= 0);
        try testing.expect(box.y0 >= 0);
        try testing.expect(box.x1 <= frame.w);
        try testing.expect(box.y1 <= frame.h);
        checked += 1;
        // A glyph path's box is the INK of the outline, which starts at the
        // glyph's own left bearing, so it carries no anchor to compare: its
        // containment above is the whole invariant. Every other primitive is
        // anchored, and all of those must take the same shift.
        if (std.mem.startsWith(u8, line, "<path ")) continue;
        const one: Shift = switch (d) {
            .text => |t| .{ .x = box.x0 - t.x, .y = box.y0 - t.y },
            .rect => |r| .{ .x = box.x0 - r.x, .y = box.y0 - r.y },
            .line => |l| .{
                .x = box.x0 - @min(l.x0, l.x1),
                .y = box.y0 - @min(l.y0, l.y1),
            },
        };
        if (shift) |s| {
            try testing.expectApproxEqAbs(s.x, one.x, 0.001);
            try testing.expectApproxEqAbs(s.y, one.y, 0.001);
        } else {
            shift = one;
        }
    }
    try testing.expectEqual(dl.len(), checked);
    // A document of nothing but glyph paths carries no anchored primitive to
    // compare the shift against — a path's box is its ink, with no origin in
    // it — so containment above is the whole invariant there.
    const origin = shift orelse return;
    const padding = (frame.w - ink.width) / 2;
    try testing.expectApproxEqAbs(padding, ink.min_y + origin.y, 0.001);
    try testing.expectApproxEqAbs(padding, ink.min_x + origin.x, 0.001);
}

/// The bounding box of one emitted element, over every geometry attribute
/// it carries. A `<text>` run carries only its baseline anchor (its
/// advance is not emitted), so its box is a point; a `<path>` carries the
/// absolute outline it paints. Null for a line with no geometry (the root
/// element, the background rect, the closing tag).
fn emittedBox(line: []const u8) ?struct { x0: f32, y0: f32, x1: f32, y1: f32 } {
    var x0 = std.math.inf(f32);
    var x1 = -std.math.inf(f32);
    var y0 = std.math.inf(f32);
    var y1 = -std.math.inf(f32);
    var found = false;
    for ([_][]const u8{ " x=\"", " x1=\"", " x2=\"" }) |attr| {
        const v = attrNumber(line, attr) catch continue;
        x0 = @min(x0, v);
        x1 = @max(x1, v);
        found = true;
    }
    for ([_][]const u8{ " y=\"", " y1=\"", " y2=\"" }) |attr| {
        const v = attrNumber(line, attr) catch continue;
        y0 = @min(y0, v);
        y1 = @max(y1, v);
        found = true;
    }
    if (pathData(line)) |d| {
        var numbers = std.mem.tokenizeAny(u8, d, " MLQZ");
        var x_next = true;
        while (numbers.next()) |token| {
            const v = std.fmt.parseFloat(f32, token) catch break;
            if (x_next) {
                x0 = @min(x0, v);
                x1 = @max(x1, v);
            } else {
                y0 = @min(y0, v);
                y1 = @max(y1, v);
            }
            x_next = !x_next;
            found = true;
        }
    }
    if (!found) return null;
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

/// The `d` attribute's value when `line` is a path element, else null. The
/// path grammar is absolute only: `M x y`, `L x y`, `Q cx cy x y`, and `Z`,
/// so the coordinates alternate x, y with no other numbers.
fn pathData(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "<path ")) return null;
    const at = std.mem.indexOf(u8, line, " d=\"") orelse return null;
    const value_at = at + 4;
    const end = std.mem.indexOfPos(u8, line, value_at, "\"") orelse return null;
    return line[value_at..end];
}

/// Parse the number at `i` (after one separating space) and advance `i`
/// past it. Fails when no number follows.
fn scanNum(s: []const u8, i: *usize) !f32 {
    if (i.* < s.len and s[i.*] == ' ') i.* += 1;
    const start = i.*;
    while (i.* < s.len) : (i.* += 1) {
        const c = s[i.*];
        const is_num = (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e';
        if (!is_num) break;
    }
    if (i.* == start) return error.EmptyAttribute;
    return std.fmt.parseFloat(f32, s[start..i.*]);
}

/// Parse the number at the first occurrence of `attr` in an SVG attribute
/// value, stopping at the value's first non-numeric character (the `pt`
/// unit, the separating space, or the closing quote). Fails when `attr` is
/// absent.
fn attrNumber(hay: []const u8, attr: []const u8) !f32 {
    const at = std.mem.indexOf(u8, hay, attr) orelse return error.MissingAttribute;
    var i = at + attr.len;
    return scanNum(hay, &i);
}

test "svg: the frame is the ink bbox and every coordinate is non-negative" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    var dl = try fractionDrawList(testing.allocator, &faces);
    defer dl.deinit();
    const ink = dl.bounds();
    // the ink origin is NOT the root reference point: the fraction pads its
    // parts by 1.2pt, so the frame has to offset by it
    try testing.expect(ink.min_x > 0);

    const svg = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(svg);
    const frame = try frameOf(svg);
    try expectInsideFrame(svg, &dl, frame);
}

test "svg: a box that under-binds the ink cannot clip the frame" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    var dl = try fractionDrawList(testing.allocator, &faces);
    defer dl.deinit();
    const correct = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(correct);
    // The same draw list, now with box bounds that BOUND its ink, against
    // the under-binding zeros it carried above. The frame follows the ink
    // either way, so the document is byte-identical.
    const ink = dl.bounds();
    try testing.expect(ink.width > dl.width);
    try testing.expect(ink.height > dl.height);
    dl.width = 12;
    dl.height = 30;
    dl.depth = 20;
    const bounding = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(bounding);
    try testing.expectEqualStrings(correct, bounding);
    // ... and the frame still holds every primitive.
    try expectInsideFrame(bounding, &dl, try frameOf(bounding));
}

test "svg: escapes xml-special characters in a run no face can draw" {
    // `<` and `&` are ordinary glyphs the faces carry, so a run of them
    // is painted as outline geometry and never reaches the document as
    // text. A codepoint NO face carries has no outline, and that run is
    // text — so the escaping is what keeps the document well formed.
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    try testing.expect(!faces.math.hasGlyph(0x4E2D));
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "\u{4E2D}<b&c",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = black,
        .src_start = 0,
        .src_end = 8,
    } });
    dl.accInk(0, -7, 5, 2);
    const svg = try render(testing.allocator, &dl, .{ .fonts = &faces });
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "\u{4E2D}&lt;b&amp;c") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "<b&c") == null);
}

test "svg: background fills the viewBox" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    var dl = try fractionDrawList(testing.allocator, &faces);
    defer dl.deinit();
    const svg = try render(testing.allocator, &dl, .{ .background = .{ .r = 255, .g = 255, .b = 255 } });
    defer testing.allocator.free(svg);
    const frame = try frameOf(svg);
    // Background coordinates use the same viewBox units as the content.
    var want: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &want,
        "<rect width=\"{d}\" height=\"{d}\" fill=\"#ffffffff\"/>",
        .{ frame.w, frame.h },
    );
    try testing.expect(std.mem.indexOf(u8, svg, head) != null);
    // ... and the content primitives are still framed on top of it
    try expectInsideFrame(svg, &dl, frame);
}

test "svg: escapes quotes in the font-family attribute" {
    // The family stack is named by the runs that stay text, which are the
    // ones no face can draw; a bundled glyph is painted as geometry and
    // names no family at all.
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    try testing.expect(!faces.math.hasGlyph(0x4E2D));
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "\u{4E2D}",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = black,
        .src_start = 0,
        .src_end = 3,
    } });
    dl.accInk(0, -7, 5, 2);
    const svg = try render(testing.allocator, &dl, .{
        .fonts = &faces,
        .font_family = "Fake \"Injected\" Family",
    });
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Fake &quot;Injected&quot; Family\"") != null);
    // the raw quote must not survive into the attribute
    try testing.expect(std.mem.indexOf(u8, svg, "font-family=\"Fake \"Injected\" Family\"") == null);
}

test "svg: rejects non-finite coordinates" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    _ = try dl.add(.{ .text = .{
        .bytes = "x",
        .x = std.math.nan(f32),
        .y = 0,
        .size = 10,
        .style = .italic,
        .color = .{ .r = 0, .g = 0, .b = 0 },
        .src_start = 0,
        .src_end = 1,
    } });
    try testing.expectError(error.NonFiniteCoordinate, render(testing.allocator, &dl, .{}));
}

// A negative margin is not a small margin: it reaches back over the
// content, so the document that used to come back declared
// `width="-1988pt"` over a viewBox of "0 0 -1988 …" — a frame no viewer
// can draw, emitted as ZTEX_OK. The option is refused instead, and a
// non-finite one keeps the coordinate error it always had.
test "svg: a negative padding is refused, not framed as a negative size" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    var dl = try fractionDrawList(testing.allocator, &faces);
    defer dl.deinit();
    // Past the ink on both sides: the frame came out negative.
    try testing.expectError(
        error.InvalidArgument,
        render(testing.allocator, &dl, .{ .padding = -1000 }),
    );
    // Small enough that the frame would have stayed positive: still a bad
    // option, and refused the same way.
    try testing.expectError(
        error.InvalidArgument,
        render(testing.allocator, &dl, .{ .padding = -0.5 }),
    );
    // A non-finite margin is a coordinate, and keeps the coordinate's error.
    try testing.expectError(
        error.NonFiniteCoordinate,
        render(testing.allocator, &dl, .{ .padding = std.math.nan(f32) }),
    );
    // A margin of 0 or more still frames the content inside the frame.
    const svg = try render(testing.allocator, &dl, .{ .padding = 4 });
    defer testing.allocator.free(svg);
    try expectInsideFrame(svg, &dl, try frameOf(svg));
}

test "svg: a script-size prime run paints the face's unencoded composite" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const alt = faces.math.smallPrimeGid(0x2034) orelse return error.TestUnexpectedResult;
    const encoded = faces.math.glyphIndex(0x2034) orelse return error.TestUnexpectedResult;

    // The two items layout puts down for an 8pt `x'''`: the base, and the
    // whole prime run as ONE composite set at the 5.6pt script size.
    const base = draw.Text{
        .bytes = "\u{1D465}",
        .x = 0,
        .y = 7.0928,
        .size = 8,
        .style = .italic,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    };
    const mark = draw.Text{
        .bytes = "\u{2034}",
        .x = 4.576,
        .y = 4.1888,
        .size = 5.6,
        .style = .italic,
        .color = black,
        .src_start = 1,
        .src_end = 4,
    };
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    try addRun(&dl, testing.allocator, &faces, base);
    try addRun(&dl, testing.allocator, &faces, mark);
    const document = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(document);
    // Geometry, never a text run: every face carries this glyph.
    try testing.expect(std.mem.indexOf(u8, document, "<text") == null);
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 2), boxes.len);
    // ONE path carries the whole prime run, and the composite's three marks
    // are its three subpaths — a consumer never sees three separate glyphs.
    var paths: usize = 0;
    var marks: usize = 0;
    var lines = std.mem.splitScalar(u8, document, '\n');
    while (lines.next()) |line| {
        const d = pathData(line) orelse continue;
        if (paths == 1) marks = std.mem.count(u8, d, "M");
        paths += 1;
    }
    try testing.expectEqual(@as(usize, 2), paths);
    try testing.expectEqual(@as(usize, 3), marks);
    // Document coordinates carry the frame's own origin, so the expectation is
    // read against the SHIFT every primitive takes — not against the position
    // the document reports, which is an item's draw coordinate PLUS that
    // shift. The first element is the base, and the base's draw coordinate is
    // the test's own, so the difference is the shift itself. The outline it
    // compares against is the face's own for the ALTERNATE.
    const off_x = try attrNumber(document, " data-x=\"") - base.x;
    const off_y = try attrNumber(document, " data-y=\"") - base.y;
    const want = try outlineBox(
        testing.allocator,
        faces.math,
        alt,
        mark.size,
        mark.x + off_x,
        mark.y + off_y,
    );
    try testing.expectApproxEqAbs(want.x0, boxes[1].x0, 0.01);
    try testing.expectApproxEqAbs(want.y0, boxes[1].y0, 0.01);
    try testing.expectApproxEqAbs(want.x1, boxes[1].x1, 0.01);
    try testing.expectApproxEqAbs(want.y1, boxes[1].y1, 0.01);
    // The composite's ink is nearly half again as wide as the encoded
    // composite's at the same size, so the two cannot pass for one another.
    const stale = try outlineBox(
        testing.allocator,
        faces.math,
        encoded,
        mark.size,
        mark.x + off_x,
        mark.y + off_y,
    );
    try testing.expect(boxes[1].x1 - boxes[1].x0 > stale.x1 - stale.x0);
    // The frame is the union of each run's ink and its own advance box: the
    // base's 4.576pt plus the composite's 6.0984pt, and only the marks'
    // overhang past that advance can make it wider.
    const frame = try frameOf(document);
    const advance: f32 = 4.576 + 6.0984;
    try testing.expect(frame.w >= advance - 0.001);
    try testing.expect(frame.w <= @max(advance, boxes[1].x1) + 0.001);

    // A 20pt base sets its composite at 14pt, past the gate: the document is
    // the one it always was, down to the frame and the encoded outline.
    const base20 = draw.Text{
        .bytes = "\u{1D465}",
        .x = 0,
        .y = 17.732,
        .size = 20,
        .style = .italic,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    };
    const mark20 = draw.Text{
        .bytes = "\u{2034}",
        .x = 11.440001,
        .y = 10.472,
        .size = 14,
        .style = .italic,
        .color = black,
        .src_start = 1,
        .src_end = 4,
    };
    var big = draw.DrawList.init(testing.allocator);
    defer big.deinit();
    try addRun(&big, testing.allocator, &faces, base20);
    try addRun(&big, testing.allocator, &faces, mark20);
    const document20 = try render(testing.allocator, &big, .{});
    defer testing.allocator.free(document20);
    const frame20 = try frameOf(document20);
    try testing.expectApproxEqAbs(@as(f32, 21.394001), frame20.w, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 17.952), frame20.h, 0.001);
    const boxes20 = try pathBoxes(testing.allocator, document20);
    defer testing.allocator.free(boxes20);
    try testing.expectEqual(@as(usize, 2), boxes20.len);
    // The same SHIFT, from the same first element and this run's base origin.
    const off_x20 = try attrNumber(document20, " data-x=\"") - base20.x;
    const off_y20 = try attrNumber(document20, " data-y=\"") - base20.y;
    const want20 = try outlineBox(
        testing.allocator,
        faces.math,
        encoded,
        14,
        mark20.x + off_x20,
        mark20.y + off_y20,
    );
    try testing.expectApproxEqAbs(want20.x0, boxes20[1].x0, 0.01);
    try testing.expectApproxEqAbs(want20.x1, boxes20[1].x1, 0.01);
}

/// One box in document coordinates.
const Box = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// The ink box of every `<path>` element, in document order.
fn pathBoxes(gpa: std.mem.Allocator, svg: []const u8) ![]Box {
    var out: std.ArrayList(Box) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, svg, '\n');
    while (lines.next()) |line| {
        const d = pathData(line) orelse continue;
        var box: Box = .{
            .x0 = std.math.inf(f32),
            .y0 = std.math.inf(f32),
            .x1 = -std.math.inf(f32),
            .y1 = -std.math.inf(f32),
        };
        var numbers = std.mem.tokenizeAny(u8, d, " MLQZ");
        var x_next = true;
        while (numbers.next()) |token| {
            const v = try std.fmt.parseFloat(f32, token);
            if (x_next) {
                box.x0 = @min(box.x0, v);
                box.x1 = @max(box.x1, v);
            } else {
                box.y0 = @min(box.y0, v);
                box.y1 = @max(box.y1, v);
            }
            x_next = !x_next;
        }
        try out.append(gpa, box);
    }
    return out.toOwnedSlice(gpa);
}

/// The box a glyph's outline paints with its baseline at (base_x, base_y):
/// the outline's own control-point bounds, scaled by the run's size and
/// flipped into the document's y-down space. Read from the FACE, never from
/// the document, so it is an independent expectation of what the run should
/// have painted.
fn outlineBox(
    gpa: std.mem.Allocator,
    face: *font.FontFace,
    gid: u32,
    size: f32,
    base_x: f32,
    base_y: f32,
) !Box {
    var outline = try face.glyphOutline(gpa, gid);
    defer outline.deinit();
    const scale = size / @as(f32, @floatFromInt(face.unitsPerEm()));
    var box: Box = .{
        .x0 = std.math.inf(f32),
        .y0 = std.math.inf(f32),
        .x1 = -std.math.inf(f32),
        .y1 = -std.math.inf(f32),
    };
    for (outline.curves.items) |c| {
        for ([_][2]f32{ c.p0, c.p1, c.p2 }) |p| {
            const x = base_x + p[0] * scale;
            const y = base_y - p[1] * scale;
            box.x0 = @min(box.x0, x);
            box.x1 = @max(box.x1, x);
            box.y0 = @min(box.y0, y);
            box.y1 = @max(box.y1, y);
        }
    }
    return box;
}

/// One draw item inside a declared ink frame.
fn textList(gpa: std.mem.Allocator, t: draw.Text, ink_box: Box) !draw.DrawList {
    var dl = draw.DrawList.init(gpa);
    errdefer dl.deinit();
    try dl.add(.{ .text = t });
    dl.accInk(ink_box.x0, ink_box.y0, ink_box.x1, ink_box.y1);
    return dl;
}

// A \left( that outgrew its base glyph must reach the browser as GEOMETRY,
// not as a text run that says so: the document paints the ladder rung's own
// outline, at the rung's own height, wherever the frame put the baseline.
test "svg: a stretched fence paints the rung's own outline, not the base glyph" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const face = faces.math;
    const size: f32 = 20;

    const fence = draw.Text{
        .bytes = "(",
        .x = 3,
        .y = -10,
        .size = size,
        .style = .italic,
        .color = black,
        .delim_form = 6,
        .src_start = 0,
        .src_end = 1,
    };
    // A frame larger than any variant, so a path painted at the wrong place
    // would still fit inside it and only the geometry could catch it.
    var dl = try textList(testing.allocator, fence, .{ .x0 = 0, .y0 = -60, .x1 = 20, .y1 = 20 });
    defer dl.deinit();

    const document = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(document);
    try testing.expect(std.mem.indexOf(u8, document, "<text") == null);
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);

    const base_x = try attrNumber(document, " data-x=\"");
    const base_y = try attrNumber(document, " data-y=\"");
    // The resolver's own answer, read from the face rather than from the
    // document: what the run must paint is the rung layout boxed.
    const built = (try glyph.plan(testing.allocator, face, requestOf(fence) orelse
        return error.NoRequest)) orelse return error.MissingGlyph;
    try testing.expectEqual(.single, std.meta.activeTag(built));
    try testing.expectEqual(@as(f32, 0), built.single.x_em);
    try testing.expectEqual(@as(f32, 0), built.single.y_em);
    const want = try outlineBox(testing.allocator, face, built.single.glyph, size, base_x, base_y);

    // The base glyph would have been a much smaller mark; scaling it up
    // would thicken the stroke, which is what the ladder exists to avoid.
    const base = face.glyphIndex('(') orelse return error.MissingGlyph;
    const base_box = try outlineBox(testing.allocator, face, base, size, base_x, base_y);
    try testing.expect(want.y1 - want.y0 > (base_box.y1 - base_box.y0) * 2.0);
    try expectInsideFrame(document, &dl, try frameOf(document));
}

// A fence taller than its whole ladder is a STACK, and it stays ONE logical
// glyph: one path element carrying every part, painting the height layout
// asked for. A browser that saw one short variant — or three loose pieces —
// would put the parens nowhere near the last row they hold.
test "svg: a fence past the ladder paints one assembled path of the requested height" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const size: f32 = 20;
    const req_em: f32 = 4.5;

    const fence = draw.Text{
        .bytes = "(",
        .x = 0,
        .y = 0,
        .size = size,
        .style = .italic,
        .color = black,
        .delim_form = 7,
        .delim_req = req_em,
        .src_start = 0,
        .src_end = 1,
    };
    var dl = try textList(testing.allocator, fence, .{
        .x0 = -2,
        .y0 = -(req_em / 2 + 0.25) * size,
        .x1 = 20,
        .y1 = (req_em / 2 - 0.25) * size,
    });
    defer dl.deinit();

    const document = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(document);
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);
    // One path element, and it paints the whole height layout asked for:
    // no single part could account for that box, so every part is in it.
    try testing.expectApproxEqAbs(req_em * size, boxes[0].y1 - boxes[0].y0, 0.15 * size);
    try expectInsideFrame(document, &dl, try frameOf(document));
}

// An overbrace wider than the font's last rung is ASSEMBLED along x, and it
// stays ONE logical glyph: one path element whose `d` carries every part and
// whose painted box is exactly the geometry the resolver reports. A viewer
// that saw one short rung — or several loose pieces it spaced itself — would
// put the brace nowhere near the content it belongs over.
test "svg: a brace past its horizontal ladder paints one assembled path of the requested width" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const face = faces.math;
    const size: f32 = 20;
    const req_em: f32 = 5.0;

    const brace = draw.Text{
        .bytes = "\u{23DE}",
        .x = 0,
        .y = 0,
        .size = size,
        .style = .italic,
        .color = black,
        .horizontal_req = req_em,
        .src_start = 0,
        .src_end = 3,
    };
    // Framed by what the resolver says it paints, not by a guess: a frame
    // that did not hold the assembly would clip it silently.
    const request = requestOf(brace) orelse return error.NoRequest;
    const bounds = (try glyph.paintedBounds(testing.allocator, face, request)) orelse
        return error.MissingGlyph;
    var dl = try textList(testing.allocator, brace, .{
        .x0 = bounds.x_min * size - 1,
        .y0 = -bounds.y_max * size - 1,
        .x1 = bounds.x_max * size + 1,
        .y1 = -bounds.y_min * size + 1,
    });
    defer dl.deinit();

    const document = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(document);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, document, "<text"));
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);

    // The document paints the geometry the resolver reports, on both axes,
    // measured from the item's own origin.
    const base_x = try attrNumber(document, " data-x=\"");
    const base_y = try attrNumber(document, " data-y=\"");
    try testing.expectApproxEqAbs(bounds.x_min * size, boxes[0].x0 - base_x, 0.001);
    try testing.expectApproxEqAbs(bounds.x_max * size, boxes[0].x1 - base_x, 0.001);
    try testing.expectApproxEqAbs(-bounds.y_max * size, boxes[0].y0 - base_y, 0.001);
    try testing.expectApproxEqAbs(-bounds.y_min * size, boxes[0].y1 - base_y, 0.001);
    // ... and that geometry spans the width the content under it needed.
    try testing.expectApproxEqAbs(req_em, bounds.x_max, 0.2);

    // One path element carrying the whole assembled width, not one element
    // per part: the box above is the run's full extent.
    try expectInsideFrame(document, &dl, try frameOf(document));
}

// A wide hat is a size variant along x: the document paints the rung the font
// drew for that width. A scaled narrow hat would thicken its stroke and raise
// the kink that the ladder exists to remove.
test "svg: a wide accent paints the rung its own ladder designs" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const face = faces.math;
    const size: f32 = 20;
    const req_em: f32 = 1.0;

    const accent = draw.Text{
        .bytes = "\u{0302}",
        .x = 0,
        .y = 0,
        .size = size,
        .style = .italic,
        .color = black,
        .horizontal_req = req_em,
        .src_start = 0,
        .src_end = 2,
    };
    const request = requestOf(accent) orelse return error.NoRequest;
    const bounds = (try glyph.paintedBounds(testing.allocator, face, request)) orelse
        return error.MissingGlyph;
    var dl = try textList(testing.allocator, accent, .{
        .x0 = bounds.x_min * size - 1,
        .y0 = -bounds.y_max * size - 1,
        .x1 = bounds.x_max * size + 1,
        .y1 = -bounds.y_min * size + 1,
    });
    defer dl.deinit();

    const document = try render(testing.allocator, &dl, .{});
    defer testing.allocator.free(document);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, document, "<text"));
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);
    // The fitted native rung is wider than the narrow combining mark.
    const gid = face.glyphIndex(0x0302) orelse return error.MissingGlyph;
    const base = (try glyph.glyphBox(testing.allocator, face, gid)) orelse
        return error.MissingGlyph;
    try testing.expect(bounds.x_max > base.x_max);
    try expectInsideFrame(document, &dl, try frameOf(document));
}

test "svg: a construction without MATH data paints its own base outline" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const face = faces.roman;
    const original_math = faces.math;
    faces.math = face;
    defer faces.math = original_math;
    const fence = draw.Text{
        .bytes = "(",
        .x = 0,
        .y = 0,
        .size = 20,
        .style = .roman,
        .color = black,
        .delim_form = 6,
        .src_start = 0,
        .src_end = 1,
    };
    var dl = try textList(testing.allocator, fence, .{
        .x0 = -2,
        .y0 = -30,
        .x1 = 8,
        .y1 = 10,
    });
    defer dl.deinit();
    const document = try render(testing.allocator, &dl, .{ .fonts = &faces });
    defer testing.allocator.free(document);
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);
    const want = try outlineBox(
        testing.allocator,
        face,
        face.glyphIndex('(') orelse return error.MissingGlyph,
        fence.size,
        try attrNumber(document, " data-x=\""),
        try attrNumber(document, " data-y=\""),
    );
    try testing.expectApproxEqAbs(want.x0, boxes[0].x0, 0.001);
    try testing.expectApproxEqAbs(want.x1, boxes[0].x1, 0.001);
    try testing.expectApproxEqAbs(want.y0, boxes[0].y0, 0.001);
    try testing.expectApproxEqAbs(want.y1, boxes[0].y1, 0.001);
}

// An ordinary letter is geometry too: the document paints the outline the
// face draws, at the run's own origin, and the frame holds it. A run left as
// browser text is snapped to the device pixel grid instead, so the glyphs
// that crossed the frame edge were clipped by the root element.
test "svg: an ordinary run paints the face's own outline inside the frame" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const face = faces.faceForCodepoint('x', .italic);
    const size: f32 = 20;
    const run = draw.Text{
        .bytes = "x",
        .x = 2,
        .y = -3,
        .size = size,
        .style = .italic,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    };
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    try addRun(&dl, testing.allocator, &faces, run);

    const document = try render(testing.allocator, &dl, .{ .fonts = &faces });
    defer testing.allocator.free(document);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, document, "<text"));
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);

    // The path paints that outline and nothing else, at the baseline the
    // run was drawn at.
    const want = try outlineBox(
        testing.allocator,
        face,
        face.glyphIndex('x') orelse return error.MissingGlyph,
        size,
        try attrNumber(document, " data-x=\""),
        try attrNumber(document, " data-y=\""),
    );
    try testing.expectApproxEqAbs(want.x0, boxes[0].x0, 0.001);
    try testing.expectApproxEqAbs(want.x1, boxes[0].x1, 0.001);
    try testing.expectApproxEqAbs(want.y0, boxes[0].y0, 0.001);
    try testing.expectApproxEqAbs(want.y1, boxes[0].y1, 0.001);
    try expectInsideFrame(document, &dl, try frameOf(document));
}

// A run is every codepoint it names, not just the first one. Each outline
// lands at the advance its OWN face carries in hmtx — the advance the CPU
// reserves for that codepoint — and each codepoint is resolved against the
// face that carries it, so one run can cross from the upright face into the
// math one. A blank glyph takes its advance and paints nothing.
test "svg: a multi-codepoint run advances the way the CPU advances it" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    const size: f32 = 20;
    // A blank space from the upright face, then a two-byte alpha that face
    // does not carry: the math face draws it, one space advance along.
    const run = draw.Text{
        .bytes = " \u{03B1}",
        .x = 1,
        .y = -3,
        .size = size,
        .style = .roman,
        .color = black,
        .src_start = 0,
        .src_end = 3,
    };
    const space = faces.faceForCodepoint(' ', .roman);
    const alpha_face = faces.faceForCodepoint(0x03B1, .roman);
    try testing.expect(space == faces.roman);
    try testing.expect(space.glyphIndex(' ') != null);
    try testing.expect(alpha_face.hasGlyph(0x03B1));

    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    try addRun(&dl, testing.allocator, &faces, run);

    const document = try render(testing.allocator, &dl, .{ .fonts = &faces });
    defer testing.allocator.free(document);
    // One path for the run: the space is silence, the alpha is geometry, and
    // nothing of the run became a text node.
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, document, "<text"));
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);

    const base_x = try attrNumber(document, " data-x=\"");
    const want = try outlineBox(
        testing.allocator,
        alpha_face,
        alpha_face.glyphIndex(0x03B1) orelse return error.MissingGlyph,
        size,
        base_x + space.advanceEm(space.glyphIndex(' ') orelse return error.MissingGlyph) * size,
        try attrNumber(document, " data-y=\""),
    );
    try testing.expectApproxEqAbs(want.x0, boxes[0].x0, 0.001);
    try testing.expectApproxEqAbs(want.x1, boxes[0].x1, 0.001);
    try testing.expectApproxEqAbs(want.y0, boxes[0].y0, 0.001);
    try testing.expectApproxEqAbs(want.y1, boxes[0].y1, 0.001);
    try expectInsideFrame(document, &dl, try frameOf(document));
}

// A codepoint no face carries has no outline to draw, and dropping it would
// lose a byte the layout boxed: it stays an escaped text run, in the family
// the run's own style names. A blank glyph — which every face carries and
// every one of them draws as nothing — is not that case, and is never named
// as text.
test "svg: a glyph no face carries stays text, a blank one does not" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    try testing.expect(!faces.math.hasGlyph(0x4E2D));

    var missing = draw.DrawList.init(testing.allocator);
    defer missing.deinit();
    try missing.add(.{ .text = .{
        .bytes = "\u{4E2D}",
        .x = 0,
        .y = 0,
        .size = 20,
        .style = .roman,
        .color = black,
        .src_start = 0,
        .src_end = 3,
    } });
    missing.accInk(0, -7, 6, 0);
    const text_run = try render(testing.allocator, &missing, .{ .fonts = &faces });
    defer testing.allocator.free(text_run);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text_run, "<text"));
    try testing.expect(std.mem.indexOf(u8, text_run, "\u{4E2D}</text>") != null);
    // A blank glyph is not a missing one: the face carries the space, its
    // outline is empty, and the run paints NOTHING — no path, and no text
    // node naming a family, which would draw a visible box for it.
    var blank = draw.DrawList.init(testing.allocator);
    defer blank.deinit();
    try addRun(&blank, testing.allocator, &faces, .{
        .bytes = " ",
        .x = 0,
        .y = 0,
        .size = 20,
        .style = .roman,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    });
    const painted = try render(testing.allocator, &blank, .{ .fonts = &faces });
    defer testing.allocator.free(painted);
    try testing.expect(std.mem.indexOf(u8, painted, "<text") == null);
    try testing.expect(std.mem.indexOf(u8, painted, "<path") == null);
}

test "svg: an unavailable suffix leaves the resolved prefix outlined" {
    var faces = try font.FontContext.init(testing.allocator);
    defer faces.deinit();
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    try dl.add(.{ .text = .{
        .bytes = "A\u{4E2D}",
        .x = 0,
        .y = 0,
        .size = 10,
        .style = .roman,
        .color = black,
        .src_start = 0,
        .src_end = 4,
    } });
    dl.accInk(0, -8, 20, 2);
    const document = try render(testing.allocator, &dl, .{ .fonts = &faces });
    defer testing.allocator.free(document);
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);
    const face = faces.faceForCodepoint('A', .roman);
    const gid = face.glyphIndex('A') orelse return error.MissingGlyph;
    const advance = face.advanceEm(gid) * 10;
    try testing.expectApproxEqAbs(advance, try attrNumber(document, "<text x=\""), 0.001);
    try testing.expect(std.mem.indexOf(u8, document, ">\u{4E2D}</text>") != null);
    try testing.expect(std.mem.indexOf(u8, document, ">A\u{4E2D}</text>") == null);
}

test "svg: a diagonal line paints its exact butt-capped band" {
    var dl = draw.DrawList.init(testing.allocator);
    defer dl.deinit();
    try dl.add(.{ .line = .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 3,
        .y1 = 4,
        .width = 2,
        .color = black,
        .src_start = 0,
        .src_end = 1,
    } });
    dl.accInk(-0.8, -0.6, 3.8, 4.6);
    const document = try render(testing.allocator, &dl, .{ .padding = 0 });
    defer testing.allocator.free(document);
    const boxes = try pathBoxes(testing.allocator, document);
    defer testing.allocator.free(boxes);
    try testing.expectEqual(@as(usize, 1), boxes.len);
    try testing.expectApproxEqAbs(@as(f32, 0), boxes[0].x0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), boxes[0].y0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 4.6), boxes[0].x1, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 5.2), boxes[0].y1, 0.0001);
}
