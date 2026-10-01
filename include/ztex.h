/*
 * ztex — LaTeX math rendered to SVG or a pixel buffer, over a C ABI.
 *
 * Ownership. A ztex_context is the only thing the library allocates: it
 * comes from YOUR allocator (ztex_allocator) and goes back to the same
 * dealloc through ztex_context_destroy. Rendered output is never handed back
 * as a pointer — ztex_render_svg and ztex_render_raster copy into a buffer
 * you own — so the library never hands out memory you cannot identify and
 * free.
 *
 * Errors. Every entry point returns an int status, ZTEX_OK (0) for success.
 * No Zig error union crosses this boundary. ztex_last_error copies the text
 * of the last failure on a context into a buffer you provide.
 *
 * Strings. Every string argument is NUL-terminated and in UTF-8. The LaTeX
 * source also carries an explicit byte length, and that length is what gets
 * rendered: ztex never calls strlen on it. A NULL source is an empty
 * formula, and is only valid with latex_length 0.
 *
 * Lengths are 32-bit (ztex_u32 = unsigned int) so this header needs no
 * <stdint.h> — C89 has none — and the ABI is the same on every target. A
 * render needing more than 4 GiB fails with ZTEX_OUTPUT_TOO_LARGE instead of
 * truncating.
 *
 * Threads. A ztex_context is NOT thread-safe: the first render fills a glyph
 * metric cache. Use one context per thread, or serialize access to a shared
 * one.
 *
 * Linking. `zig build static-lib` produces zig-out/lib/libztex.a (built
 * position-independent, so it also links into a shared object). Link it
 * with libm (-lm on glibc): the rasterizer's glyph placement uses libm's
 * roundf.
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
/* A NULL handle, buffer or out-parameter; an unknown style or pixel-format
   code; a size that is not a positive finite number. */
#define ZTEX_INVALID_ARGUMENT 1
/* The LaTeX front end rejected the formula. ztex_last_error names the kind
   and the position, e.g. "parse error: Missing argument (MissingArgument)
   at line 1, col 8". */
#define ZTEX_PARSE_ERROR 2
/* The layout stage rejected the atom tree. */
#define ZTEX_INVALID_AST 3
#define ZTEX_OUT_OF_MEMORY 4
/* A draw-list coordinate was not finite, so no SVG could be written. */
#define ZTEX_NON_FINITE_COORDINATE 5
/* The output buffer cannot hold the whole payload. Nothing was written and
   the out-parameter carries the size needed. */
#define ZTEX_BUFFER_TOO_SMALL 6
/* The output does not fit the 32-bit length ABI. */
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
#define ZTEX_PIXEL_ALPHA8 1 /* 1 byte per pixel: coverage, 0 = transparent */

/* "No background" in a packed 0xRRGGBBAA color. Zero, so an all-zero
   options struct asks for the default rendering. */
#define ZTEX_COLOR_NONE 0

/* Opaque render context. Create one with ztex_context_create, release it
   with ztex_context_destroy. */
typedef struct ztex_context ztex_context;

/*
 * The caller's allocator. ztex_context_create COPIES this struct, so it may
 * be a temporary; `user`, `alloc` and `dealloc` must stay valid until the
 * matching ztex_context_destroy.
 *
 * `alloc` returns memory aligned for max_align_t (16 bytes on every target
 * ztex builds for), or NULL when it cannot. `dealloc` receives the exact
 * `len` its matching `alloc` call was given. The library grows a buffer by
 * allocating, copying and freeing, so an arena works and a size-tracking
 * free list stays exact.
 */
typedef struct ztex_allocator {
    void *(*alloc)(void *user, ztex_u32 len);
    void (*dealloc)(void *user, void *ptr, ztex_u32 len);
    void *user;
} ztex_allocator;

/*
 * SVG rendering knobs. An all-zero struct is the default rendering: no
 * padding, no background rectangle, the built-in font stacks. `background`
 * is a packed 0xRRGGBBAA color, or ZTEX_COLOR_NONE for none. The two font
 * stacks are CSS font-family lists for math (italic) runs and for upright
 * (\text, \mathrm, \mathbf) runs; NULL keeps ztex's own.
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
 * `format` one of ZTEX_PIXEL_*. `fg` is the ink color (unused by the alpha
 * mask), `bg` the background, both packed 0xRRGGBBAA, or ZTEX_COLOR_NONE
 * for a transparent buffer. `padding` is a margin in pixels.
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
 * library: it lives as long as the process and must never be freed. A code
 * this build does not know reads "unknown status".
 */
const char *ztex_status_name(int status);

/*
 * Create a render context and write it to *out_context, which you then own
 * until ztex_context_destroy. The context block, and every byte the pipeline
 * takes after it, comes from `allocator`; ztex_context_destroy gives all of
 * them back through the same dealloc. On failure *out_context is left
 * untouched and the return value is not ZTEX_OK.
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
 * `latex` is read during the call only, and nothing is retained: the SVG is
 * copied into `out`, which you own. `style` is a ZTEX_STYLE_* code and
 * `size_pt` the base font size in points (positive and finite). `options`
 * may be NULL for the default rendering.
 *
 * *out_length always receives the payload size: on ZTEX_OK the number of
 * bytes copied into `out`, on ZTEX_BUFFER_TOO_SMALL the size needed. So
 * `out = NULL, out_capacity = 0` is a size query, and a buffer that cannot
 * hold the whole payload comes back UNWRITTEN rather than half filled — a
 * render is never silently partial. The payload needs
 * `out_capacity >= *out_length + 1`: ztex always terminates it with a NUL.
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
 * Render one formula to a pixel buffer in your buffer. Ownership, sizing and
 * the size-query protocol follow ztex_render_svg exactly; *out_width and
 * *out_height receive the image size in pixels whenever the render itself
 * succeeded, including on the ZTEX_BUFFER_TOO_SMALL a size query returns.
 * Both must be non-NULL.
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
 * NUL-terminating inside `capacity`. Truncation is your call: *out_length
 * always receives the FULL text length, so *out_length >= capacity means the
 * tail was cut. A NULL buffer, or a zero capacity with text to report,
 * answers ZTEX_INVALID_ARGUMENT and leaves that text intact. The text
 * belongs to the context and is overwritten by the next call on it; after a
 * successful call it is empty.
 */
int ztex_last_error(
    const ztex_context *context,
    char *buffer,
    ztex_u32 capacity,
    ztex_u32 *out_length
);

#endif /* ZTEX_H */