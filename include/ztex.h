/*
 * ztex — LaTeX math rendered to SVG or a pixel buffer, over a C ABI.
 *
 * Ownership. Every byte the library takes comes from YOUR allocator
 * (ztex_allocator): the context block ztex_context_create allocates, the
 * embedded Latin Modern faces and the glyph metric cache that block owns
 * until ztex_context_destroy, and the parse, layout, SVG and pixel working
 * set of every call. That per-call working set is released before the call
 * returns; ztex_context_destroy hands the context block itself back
 * through the same dealloc. Nothing comes back as a pointer you cannot
 * identify and free: ztex_render_svg and ztex_render_raster copy into a
 * buffer you own.
 *
 * Return values. ztex_context_create, ztex_render_svg, ztex_render_raster
 * and ztex_last_error return an int status, ZTEX_OK (0) for success. The
 * other two return what they describe: ztex_context_destroy returns void,
 * ztex_status_name a const char *. No Zig error union crosses this
 * boundary; ztex_last_error copies the text of the last failure on a
 * context into a buffer you provide.
 *
 * Strings. The LaTeX source is UTF-8 bytes plus an explicit byte count:
 * ztex reads exactly `latex_length` of them and never calls strlen, so the
 * source needs no NUL terminator. A byte that is not valid UTF-8 fails the
 * parse, and a source above 2 GiB - 1 bytes or nested deeper than 500
 * levels fails it too. Every OTHER string is NUL-terminated: both
 * font-family options you pass in, the SVG payload ztex writes into your
 * buffer, a status name, and any failure text. A NULL source is an empty
 * formula, and is only valid with latex_length 0.
 *
 * Lengths are 32-bit (ztex_u32 = unsigned int) so this header needs no
 * <stdint.h> — C89 has none — and the ABI is the same on every target. A
 * payload above 4 GiB - 2 bytes, or a raster frame whose width, height or
 * row stride has no 32-bit representation at all, fails with
 * ZTEX_OUTPUT_TOO_LARGE rather than truncating or wrapping. A failed render
 * writes nothing: out keeps its bytes, and out_length, out_width and
 * out_height keep the values you passed in.
 *
 * Threads. A ztex_context is NOT thread-safe: the first render fills a glyph
 * metric cache. Use one context per thread, or serialize access to a shared
 * one.
 *
 * Linking. `zig build static-lib` produces zig-out/lib/libztex.a (built
 * position-independent, so it also links into a shared object). Link it
 * with libm (-lm on glibc): the archive calls libm's roundf, plus the
 * exp/log pair behind the font decoder's std.math.pow.
 *
 * C++. This header is plain C89. A C++ host includes it from inside its own
 * extern "C" block.
 */

#ifndef ZTEX_H
#define ZTEX_H

/* 32-bit unsigned types, defined here so this header stays self-contained
   and C89-clean. `unsigned int` is 32 bits on every target ztex builds for. */
typedef unsigned char ztex_u8;
typedef unsigned int ztex_u32;

/* Status codes. Any other value is not a status this build knows. */
#define ZTEX_OK 0
/* Misuse of the call itself: a NULL context; a NULL out_length, out_width
   or out_height; an unknown style or pixel-format code; a size_pt, dpi or
   scale that is not positive and finite; a negative ztex_svg_options
   padding; a NULL latex with a non-zero latex_length; a ztex_last_error
   call with no buffer or no room for one.
   A NULL *output* buffer is not this: on a render it is the size query. */
#define ZTEX_INVALID_ARGUMENT 1
/* The LaTeX front end rejected the formula. ztex_last_error names the kind
   and the position, e.g. "parse error: Missing argument (MissingArgument)
   at line 1, col 8". */
#define ZTEX_PARSE_ERROR 2
/* The layout stage rejected the atom tree. */
#define ZTEX_INVALID_AST 3
/* Your alloc returned NULL, or the request did not fit the 32-bit length
   ABI. Reported by ztex_context_create, or by a render that ran out of
   working memory partway through. */
#define ZTEX_OUT_OF_MEMORY 4
/* A draw-list coordinate was not finite — the rasterizer's ink extents
   included — so no SVG or bitmap could be written. */
#define ZTEX_NON_FINITE_COORDINATE 5
/* The payload does not fit the buffer: out is NULL, or out_capacity is
   below the size needed. Nothing was written into out — not even a NUL —
   and out_length carries the size needed. */
#define ZTEX_BUFFER_TOO_SMALL 6
/* The output has no 32-bit size: a raster frame whose width, height or row
   stride cannot be expressed, or a payload above 4 GiB - 2 bytes. The
   frame is measured before the pixel block is requested, so a request this
   status answers never reaches your alloc. */
#define ZTEX_OUTPUT_TOO_LARGE 7
/* A font could not be read while rasterizing a glyph outline. */
#define ZTEX_FONT_ERROR 8

/* Math styles: display for a standalone equation, text for math set inline
   in prose. */
#define ZTEX_STYLE_DISPLAY 0
#define ZTEX_STYLE_TEXT 1
#define ZTEX_STYLE_SCRIPT 2
#define ZTEX_STYLE_SCRIPT_SCRIPT 3

/* Pixel formats for ztex_render_raster. */
#define ZTEX_PIXEL_RGBA32 0 /* 4 bytes per pixel, R, G, B, A */
/* 1 byte per pixel: coverage times the ink's alpha, 0 = transparent. The
   canvas is always transparent here, whatever `bg` says. */
#define ZTEX_PIXEL_ALPHA8 1

/* "No background" in a packed 0xRRGGBBAA color. Zero, so the background
   field of a zeroed ztex_svg_options asks for the default rendering; a
   zeroed ztex_raster_options does NOT, and is refused (see below). */
#define ZTEX_COLOR_NONE 0

/* Opaque render context. Create one with ztex_context_create, release it
   with ztex_context_destroy. */
typedef struct ztex_context ztex_context;

/*
 * The caller's allocator, and the ONLY source of memory the library has:
 * every parse, layout, SVG and pixel allocation of every call comes from it
 * as well. ztex_context_create COPIES this struct, so it may be a
 * temporary; `user`, `alloc` and `dealloc` must stay valid until the
 * matching ztex_context_destroy.
 *
 * `alloc` returns memory aligned for max_align_t (16 bytes on every target
 * ztex builds for), or NULL when it cannot. `dealloc` receives the exact
 * `len` its matching `alloc` call was given. The library grows a buffer by
 * allocating, copying and freeing, so an arena works and a size-tracking
 * free list stays exact. A NULL from `alloc`, or a request whose length
 * does not fit the 32-bit ABI, is an ordinary allocation failure, so a
 * render answers ZTEX_OUT_OF_MEMORY rather than failing some other way.
 */
typedef struct ztex_allocator {
    void *(*alloc)(void *user, ztex_u32 len);
    void (*dealloc)(void *user, void *ptr, ztex_u32 len);
    void *user;
} ztex_allocator;

/*
 * SVG rendering knobs. An all-zero struct is the default rendering: no
 * padding, no background rectangle, the built-in font stacks. `padding` is
 * a margin in points, on every side, and must be >= 0 and finite: a
 * negative margin is ZTEX_INVALID_ARGUMENT, a non-finite one
 * ZTEX_NON_FINITE_COORDINATE. `background` is a packed 0xRRGGBBAA color,
 * or ZTEX_COLOR_NONE for none. The two font stacks are NUL-terminated CSS
 * font-family lists for math (italic) runs and for upright (\text,
 * \mathrm, \mathbf) runs; NULL keeps ztex's own.
 */
typedef struct ztex_svg_options {
    float padding;
    ztex_u32 background;
    const char *math_font_family;
    const char *upright_font_family;
} ztex_svg_options;

/*
 * Raster rendering knobs. A NULL pointer means the defaults below (96 dpi,
 * 1x scale, RGBA), but a ZEROED struct is an error — dpi 0 is not a
 * resolution — and ztex says so. `dpi` and `scale` must be finite and > 0,
 * `format` one of ZTEX_PIXEL_*. `fg` is the ink color and `bg` the
 * background, both packed 0xRRGGBBAA, or ZTEX_COLOR_NONE for a transparent
 * buffer. `padding` is a margin in pixels, on both axes.
 *
 * These three size a 32-bit frame. A dpi, scale or padding that is
 * otherwise well formed but frames an image whose width, height or row
 * stride has no 32-bit representation is ZTEX_OUTPUT_TOO_LARGE, measured
 * before the pixel block is requested — a hostile option is never handed
 * to your alloc.
 *
 * ZTEX_PIXEL_ALPHA8 ignores most of both colors: a mask byte is the glyph
 * coverage times the ALPHA byte of the ink — `fg`'s alpha for ordinary ink,
 * the formula's own color alpha inside \color / \textcolor — so `fg`'s red,
 * green and blue never reach the mask. The canvas is always transparent in
 * that format, so `bg` is ignored entirely.
 */
typedef struct ztex_raster_options {
    float dpi;
    float scale;
    ztex_u32 padding;
    ztex_u32 format;
    ztex_u32 fg;
    ztex_u32 bg;
} ztex_raster_options;

/*
 * The name of a status code, as a NUL-terminated C string owned by the
 * library: one of a few string literals that live as long as the process
 * and must never be freed. Never NULL. A code this build does not know
 * reads "unknown status".
 */

const char *ztex_status_name(int status);

/*
 * Create a render context and write it to *out_context, which you then own
 * until ztex_context_destroy. The context block, and every byte the pipeline
 * takes after it, comes from `allocator`; ztex_context_destroy gives all of
 * them back through the same dealloc. Nothing is retained on failure:
 * *out_context is left untouched, a block already taken goes straight back
 * to `dealloc`, and the return value is not ZTEX_OK —
 * ZTEX_INVALID_ARGUMENT for a NULL allocator, out-parameter or callback,
 * ZTEX_OUT_OF_MEMORY when `alloc` answers NULL.
 */

int ztex_context_create(const ztex_allocator *allocator, ztex_context **out_context);

/*
 * Destroy a context: the embedded Latin Modern faces, the glyph metric cache
 * and the context block itself all go back to the dealloc the context was
 * created with. A NULL context is a no-op; destroying one twice is
 * undefined, exactly as calling free twice is.
 */
void ztex_context_destroy(ztex_context *context);

/*
 * Render one formula to SVG in your buffer.
 *
 * `latex` is counted UTF-8, read during the call only, and nothing is
 * retained: the SVG is copied into `out`, which you own. `style` is a
 * ZTEX_STYLE_* code and `size_pt` the base font size in points (positive
 * and finite). `options` may be NULL for the default rendering.
 *
 * A render that got as far as building the document gives *out_length the
 * payload size: on ZTEX_OK the number of bytes copied into `out`, on
 * ZTEX_BUFFER_TOO_SMALL the size needed. So `out = NULL, out_capacity = 0`
 * is a size query, and a buffer that cannot hold the whole payload comes
 * back UNWRITTEN rather than half filled — a render is never silently
 * partial. The payload needs `out_capacity >= *out_length + 1`: ztex always
 * terminates it with a NUL, and that NUL is the one byte *out_length does
 * not count.
 *
 * A FAILED render leaves *out_length and every byte of `out` untouched,
 * whatever the failure: ZTEX_INVALID_ARGUMENT (a negative options->padding
 * is caught before the document is built), ZTEX_PARSE_ERROR,
 * ZTEX_INVALID_AST, ZTEX_FONT_ERROR, ZTEX_NON_FINITE_COORDINATE,
 * ZTEX_OUT_OF_MEMORY, or ZTEX_OUTPUT_TOO_LARGE — a payload above
 * 4 GiB - 2 bytes, which no real render reaches. So a failed call is never
 * a size query: only ZTEX_BUFFER_TOO_SMALL reports a size.
 */
int ztex_render_svg(
    ztex_context *context,
    const char *latex,
    ztex_u32 latex_length,
    int style,
    float size_pt,
    const ztex_svg_options *options,
    ztex_u8 *out,
    ztex_u32 out_capacity,
    ztex_u32 *out_length
);

/*
 * Render one formula to a pixel buffer in your buffer. Ownership, the
 * counted `latex` source and the size-query protocol follow ztex_render_svg
 * exactly: the payload is width*height*4 bytes in ZTEX_PIXEL_RGBA32 and
 * width*height in ZTEX_PIXEL_ALPHA8, and it too needs
 * `out_capacity >= *out_length + 1`, for the NUL ztex writes one byte past
 * the last pixel.
 *
 * *out_width and *out_height receive the image size in pixels whenever the
 * render itself succeeded — including on the ZTEX_BUFFER_TOO_SMALL a size
 * query returns — and are untouched when it failed, as is *out_length (see
 * ztex_render_svg). Both must be non-NULL. A frame no 32-bit size can
 * describe is ZTEX_OUTPUT_TOO_LARGE, answered before the pixel block is
 * requested, so it reaches neither your alloc nor your out-parameters.
 */
int ztex_render_raster(
    ztex_context *context,
    const char *latex,
    ztex_u32 latex_length,
    int style,
    float size_pt,
    const ztex_raster_options *options,
    ztex_u8 *out,
    ztex_u32 out_capacity,
    ztex_u32 *out_length,
    ztex_u32 *out_width,
    ztex_u32 *out_height
);

/*
 * Copy the text of the last failure on `context` into `buffer`, always
 * NUL-terminating within `capacity`. Truncation is your call: *out_length
 * always receives the FULL text length, so *out_length >= capacity means
 * the tail was cut. The text is bounded at 255 bytes, so *out_length never
 * exceeds that. A NULL `buffer`, or a zero `capacity` with text to report,
 * answers ZTEX_INVALID_ARGUMENT — *out_length already carries the full
 * length, and the text stays readable for a second try. With no failure to
 * report the call answers ZTEX_OK, writes *out_length = 0 and touches no
 * byte of `buffer`.
 *
 * The text belongs to the context: every render clears it before it works,
 * so a successful render leaves it empty and a failed one replaces it.
 * ztex_last_error itself never changes it.
 */
int ztex_last_error(
    const ztex_context *context,
    char *buffer,
    ztex_u32 capacity,
    ztex_u32 *out_length
);

#endif /* ZTEX_H */