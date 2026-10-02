/* c_consumer — the real include/ztex.h against the real libztex.a.
 *
 * This is the runtime half of the C ABI guard. src/tests/c_abi_check.zig
 * compares the translated header with src/ztex_c.zig at compile time; this
 * file compiles against the header as a C compiler sees it, links the
 * archive, and exercises every published entry point at run time: render,
 * size query, failure text, and who owns what.
 *
 * Written in C89 and compiled as C89, because the header promises C89: no
 * declaration after a statement, no `//`, no type from <stdint.h>, no
 * variadic macro. Every check below is a contract the header states.
 *
 * Exit status is 0 when every check passed and 1 otherwise.
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ztex.h"

static int failures = 0;

static void check(int ok, const char *what)
{
    if (!ok) {
        failures += 1;
        printf("c_consumer: FAILED %s\n", what);
    }
}

/* --- the caller's allocator ------------------------------------------
 *
 * malloc satisfies the alignment the header promises. The ledger is what
 * makes the ownership contract checkable: a running byte total would hide a
 * wrong length that cancelled out, a second free of the same pointer, or a
 * pointer ztex never held. A record per live block catches all three, and
 * `biggest` is the largest REQUEST, served or not.
 */

#define HOST_MAX_LIVE 4096

typedef struct {
    void *ptr;
    ztex_u32 len;
} host_record;

typedef struct {
    host_record records[HOST_MAX_LIVE];
    int live;
    int overflow;
    int mismatched;
    int unknown;
    unsigned long biggest;
} host_allocator;

static void *host_alloc(void *user, ztex_u32 len)
{
    host_allocator *state;
    void *block;

    state = (host_allocator *)user;
    if ((unsigned long)len > state->biggest) {
        state->biggest = (unsigned long)len;
    }
    block = malloc((size_t)len);
    if (block == NULL) {
        return NULL;
    }
    if (state->live >= HOST_MAX_LIVE) {
        /* Report rather than track: a ledger that cannot hold the caller's
           whole working set would make every later check meaningless. */
        state->overflow += 1;
        free(block);
        return NULL;
    }
    state->records[state->live].ptr = block;
    state->records[state->live].len = len;
    state->live += 1;
    return block;
}

static void host_dealloc(void *user, void *ptr, ztex_u32 len)
{
    host_allocator *state;
    int i;

    state = (host_allocator *)user;
    if (ptr == NULL) {
        return;
    }
    for (i = 0; i < state->live; i += 1) {
        if (state->records[i].ptr != ptr) {
            continue;
        }
        if (state->records[i].len != len) {
            state->mismatched += 1;
        }
        /* Move the last record down, so the ledger stays dense and a second
           free of this pointer finds nothing and is counted. */
        state->records[i] = state->records[state->live - 1];
        state->live -= 1;
        free(ptr);
        return;
    }
    /* Not freed here: this pointer was already returned or was never ours,
       and handing it to free() a second time would take the process down
       instead of reporting it. */
    state->unknown += 1;
}


static void host_allocator_init(host_allocator *state, ztex_allocator *desc)
{
    state->live = 0;
    state->overflow = 0;
    state->mismatched = 0;
    state->unknown = 0;
    state->biggest = 0UL;
    desc->alloc = host_alloc;
    desc->dealloc = host_dealloc;
    desc->user = state;
}

/* The header's ownership rules, asserted once over everything that ran. */
static void check_ledger(host_allocator *state)
{
    check(state->overflow == 0, "the ledger never overflowed");
    check(state->mismatched == 0, "every dealloc carried the length its alloc was given");
    check(state->unknown == 0, "no pointer was freed twice or that ztex never held");
}

/* --- entry points -------------------------------------------------- */

static void test_create_refusals(void)
{
    host_allocator state;
    ztex_allocator desc;
    ztex_context *ctx;

    ctx = NULL;
    host_allocator_init(&state, &desc);
    check(ztex_context_create(NULL, &ctx) == ZTEX_INVALID_ARGUMENT,
          "create with no allocator");
    check(ctx == NULL, "a refused create leaves the out-parameter alone");

    check(ztex_context_create(&desc, NULL) == ZTEX_INVALID_ARGUMENT,
          "create with no out-parameter");

    desc.alloc = NULL;
    check(ztex_context_create(&desc, &ctx) == ZTEX_INVALID_ARGUMENT,
          "create with a NULL alloc");

    host_allocator_init(&state, &desc);
    desc.dealloc = NULL;
    check(ztex_context_create(&desc, &ctx) == ZTEX_INVALID_ARGUMENT,
          "create with a NULL dealloc");
    check(state.live == 0, "a refused create allocates nothing");
}

static void test_status_names(void)
{
    check(strcmp(ztex_status_name(ZTEX_OK), "ok") == 0,
          "ZTEX_OK is named ok");
    check(strcmp(ztex_status_name(ZTEX_FONT_ERROR), "font_error") == 0,
          "ZTEX_FONT_ERROR is named font_error");
    check(strcmp(ztex_status_name(1234), "unknown status") == 0,
          "an unknown code reads unknown status");
}

static void test_svg(ztex_context *ctx)
{
    /* Two bytes of source of which one is the formula: the library reads
       exactly `latex_length` bytes, never looks at the one behind it, and
       never calls strlen on the pointer. */
    char src[2];
    char *buf;
    ztex_u32 len;
    char small[8];
    int i;
    int all_aa;

    src[0] = 'x';
    src[1] = (char)0xff;

    /* The size query: no buffer at all, just the size the caller must
       provide. */
    len = 0u;
    check(ztex_render_svg(ctx, src, (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                          NULL, NULL, 0, &len) == ZTEX_BUFFER_TOO_SMALL,
          "a null out buffer is the size query");
    check(len > 0u, "the size query reports the payload size");

    buf = (char *)malloc((size_t)len + 1u);
    check(buf != NULL, "the caller can hold the payload");
    if (buf == NULL) {
        return;
    }
    check(ztex_render_svg(ctx, src, (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                          NULL, (ztex_u8 *)buf, len + 1u, &len) == ZTEX_OK,
          "the SVG render succeeds");
    check(buf[len] == '\0', "the payload is NUL-terminated");
    check(strncmp(buf, "<svg", 4) == 0, "the payload is an SVG document");

    /* A buffer that cannot hold the whole payload comes back unwritten. */
    for (i = 0; i < 8; i += 1) {
        small[i] = (char)0xaa;
    }
    len = 0u;
    check(ztex_render_svg(ctx, src, (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                          NULL, (ztex_u8 *)small, (ztex_u32)8, &len) == ZTEX_BUFFER_TOO_SMALL,
          "a short buffer is refused");
    check(len > 8u, "the refusal reports the size needed");
    all_aa = 1;
    for (i = 0; i < 8; i += 1) {
        if (small[i] != (char)0xaa) {
            all_aa = 0;
        }
    }
    check(all_aa, "a refused render writes not one byte");
    free(buf);
}

static void test_failures_and_error_text(ztex_context *ctx)
{
    char buf[256];
    char text[256];
    ztex_u8 *success;
    ztex_u32 len;
    ztex_u32 text_len;

    /* A parse failure names the stage, the position and the error tag. */
    len = 123u;
    check(ztex_render_svg(ctx, "\\frac{1}", (ztex_u32)8, ZTEX_STYLE_DISPLAY,
                          20.0f, NULL, (ztex_u8 *)buf, (ztex_u32)256, &len) == ZTEX_PARSE_ERROR,
          "an incomplete formula is a parse error");
    check(len == 123u, "a failed render leaves out_length alone");
    text_len = 0u;
    check(ztex_last_error(ctx, text, (ztex_u32)256, &text_len) == ZTEX_OK,
          "the failure text reads back");
    check(text_len > 0u, "the failure text is not empty");
    check(strstr(text, "parse error") != NULL, "the failure text names the stage");
    check(strstr(text, "at line") != NULL, "the failure text names the position");

    /* A short caller buffer truncates the text and still reports its full
       length. */
    text_len = 0u;
    check(ztex_last_error(ctx, text, (ztex_u32)12, &text_len) == ZTEX_OK,
          "a short text buffer is answered");
    check(text_len > 12u, "the full text length is always reported");

    /* A NULL context is refused on every half of the surface. */
    check(ztex_last_error(NULL, text, (ztex_u32)256, &text_len) == ZTEX_INVALID_ARGUMENT,
          "last_error with no context");
    check(ztex_render_svg(NULL, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                          NULL, (ztex_u8 *)buf, (ztex_u32)256, &len) == ZTEX_INVALID_ARGUMENT,
          "render_svg with no context");

    check(ztex_render_svg(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                          NULL, NULL, 0, &len) == ZTEX_BUFFER_TOO_SMALL,
          "query the buffer required for a successful render");
    success = (ztex_u8 *)malloc((size_t)len + 1u);
    check(success != NULL, "the caller can hold the successful payload");
    if (success == NULL) {
        return;
    }
    /* A successful render clears the text, so nothing stale reads back. */
    check(ztex_render_svg(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                          NULL, success, len + 1u, &len) == ZTEX_OK,
          "a plain formula renders");
    free(success);
    text_len = 123u;
    check(ztex_last_error(ctx, text, (ztex_u32)256, &text_len) == ZTEX_OK,
          "the text read after a success succeeds");
    check(text_len == 0u, "a successful render clears the failure text");
}

static void test_raster(ztex_context *ctx)
{
    ztex_raster_options opts;
    ztex_u8 *buf;
    ztex_u32 len;
    ztex_u32 width;
    ztex_u32 height;

    /* NULL options are the defaults: 96 dpi, RGBA, opaque black ink. */
    len = 0u;
    width = 0u;
    height = 0u;
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             NULL, NULL, 0, &len, &width, &height) ==
              ZTEX_BUFFER_TOO_SMALL,
          "a raster size query");
    check(width > 0u && height > 0u, "the size query reports the frame");
    check(len == width * height * 4u, "RGBA is four bytes a pixel");

    buf = (ztex_u8 *)malloc((size_t)len + 1u);
    check(buf != NULL, "the caller can hold the frame");
    if (buf == NULL) {
        return;
    }
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             NULL, buf, len + 1u, &len, &width, &height) == ZTEX_OK,
          "the raster render succeeds");
    check(buf[len] == 0u, "the frame is NUL-terminated");
    free(buf);

    /* A caller-built struct has no defaults, so `fg` is assigned here: the
       alpha mask format keeps only its alpha byte, and an unassigned `fg`
       would be a transparent ink that paints nothing at all. */
    opts.dpi = 72.0f;
    opts.scale = 1.0f;
    opts.padding = 0u;
    opts.format = (ztex_u32)ZTEX_PIXEL_ALPHA8;
    opts.fg = 0x1a2b3cff;
    opts.bg = (ztex_u32)ZTEX_COLOR_NONE;
    len = 0u;
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             &opts, NULL, 0, &len, &width, &height) ==
              ZTEX_BUFFER_TOO_SMALL,
          "an alpha mask size query");
    check(len == width * height, "the alpha mask is one byte a pixel");

    /* A zeroed struct is refused, and the refusal names `dpi`. */
    memset(&opts, 0, sizeof(opts));
    len = 123u;
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             &opts, NULL, 0, &len, &width, &height) ==
              ZTEX_INVALID_ARGUMENT,
          "a zeroed raster options struct is refused");

    /* An unknown format code is refused rather than silently defaulted. */
    opts.dpi = 96.0f;
    opts.scale = 1.0f;
    opts.format = 7u;
    opts.fg = 0x000000ff;
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             &opts, NULL, 0, &len, &width, &height) ==
              ZTEX_INVALID_ARGUMENT,
          "an unknown pixel format is refused");

    /* The geometry out-parameters are required, like the length. */
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             NULL, NULL, 0, &len, NULL, &height) ==
              ZTEX_INVALID_ARGUMENT,
          "a NULL out_width is refused");
}

static void test_too_large_is_refused(host_allocator *state, ztex_context *ctx)
{
    ztex_raster_options opts;
    ztex_u8 out[64];
    ztex_u32 len;
    ztex_u32 width;
    ztex_u32 height;
    int i;
    int untouched;

    for (i = 0; i < 64; i += 1) {
        out[i] = (ztex_u8)0xaa;
    }

    /* A resolution that is finite, positive and enormous frames an image no
       32-bit width can describe. */
    opts.dpi = 1.0e30f;
    opts.scale = 1.0f;
    opts.padding = 0u;
    opts.format = (ztex_u32)ZTEX_PIXEL_RGBA32;
    opts.fg = 0x000000ff;
    opts.bg = (ztex_u32)ZTEX_COLOR_NONE;
    len = 123u;
    width = 123u;
    height = 123u;
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             &opts, out, (ztex_u32)64, &len, &width, &height) ==
              ZTEX_OUTPUT_TOO_LARGE,
          "an unrepresentable frame is refused as too large");
    check(len == 123u && width == 123u && height == 123u,
          "a refused frame reports no size at all");
    untouched = 1;
    for (i = 0; i < 64; i += 1) {
        if (out[i] != (ztex_u8)0xaa) {
            untouched = 0;
        }
    }
    check(untouched, "a refused frame writes not one byte");

    /* The same cap from the other end: this margin frames about 1.07e9 px
       square, so the frame has a 32-bit width and row stride while the whole
       payload is ~4.6e18 bytes — a size no ztex_u32 length can carry. It is
       a refusal of the SIZE, not an allocation that ran out. */
    opts.dpi = 96.0f;
    opts.padding = 536000000u;
    len = 123u;
    width = 123u;
    height = 123u;
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             &opts, out, (ztex_u32)64, &len, &width, &height) ==
              ZTEX_OUTPUT_TOO_LARGE,
          "a payload past the 32-bit length ABI is too large, not out of memory");
    check(len == 123u && width == 123u && height == 123u,
          "a payload refusal reports no size at all");

    /* Neither refusal asked for a frame-sized block. Not zero: parsing,
       laying out and glyph scratch still allocate, and that working set is
       small. What the header promises is that nothing on the scale of the
       payload reached alloc, and the payload here is ~4.6e18 bytes. */
    check(state->biggest < 4UL * 1024UL * 1024UL,
          "no refused frame asked alloc for anything near the payload");

    /* And the context still works, so the refusals above were the size and
       not a starving allocator. */
    len = 0u;
    check(ztex_render_raster(ctx, "x", (ztex_u32)1, ZTEX_STYLE_DISPLAY, 20.0f,
                             NULL, NULL, 0, &len, &width, &height) ==
              ZTEX_BUFFER_TOO_SMALL,
          "the context still renders after a refusal");
    check(width > 0u && height > 0u, "and still reports a frame");
}

int main(void)
{
    host_allocator state;
    ztex_allocator desc;
    ztex_context *ctx;

    test_create_refusals();
    test_status_names();

    host_allocator_init(&state, &desc);
    ctx = NULL;
    if (ztex_context_create(&desc, &ctx) != ZTEX_OK) {
        printf("c_consumer: FAILED the context could not be created\n");
        return 1;
    }
    check(state.live > 0, "the context owns memory taken from the caller");
    check_ledger(&state);

    test_svg(ctx);
    test_failures_and_error_text(ctx);
    test_raster(ctx);
    test_too_large_is_refused(&state, ctx);

    /* Exactly once: every block the context ever took goes back through the
       same dealloc, with the length its alloc was given, and no render
       retained anything. */
    ztex_context_destroy(ctx);
    check(state.live == 0, "destroying the context gives every block back");
    check_ledger(&state);

    ztex_context_destroy(NULL);
    check(state.live == 0, "destroying nothing is a no-op");
    check_ledger(&state);

    if (failures != 0) {
        printf("c_consumer: %d check(s) failed\n", failures);
        return 1;
    }
    printf("c_consumer: ok\n");
    return 0;
}