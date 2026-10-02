// cxx_consumer — include/ztex.h included the way a C++ host includes it.
//
// The header promises a C++ host can include it directly and needs no
// extern "C" block of its own. That promise is checkable and this file is
// the check: it includes the header at file scope with NO wrapper of its
// own, calls the surface from C++, and links the archive. Without the
// header's own extern "C" guard every name below would be C++-mangled, so
// the link would fail to find ztex_context_create — the guard is what this
// file proves, and a compile error alone would not.
//
// Deliberately plain: C headers only, no standard library types, so the
// executable needs nothing beyond the archive to run.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ztex.h"

static int failures = 0;

static void check(int ok, const char *what)
{
    if (!ok) {
        failures += 1;
        printf("cxx_consumer: FAILED %s\n", what);
    }
}

typedef struct {
    unsigned long live;
} host_state;

static void *host_alloc(void *user, ztex_u32 len)
{
    host_state *state = static_cast<host_state *>(user);
    void *block = malloc(static_cast<size_t>(len));
    if (block != NULL) {
        state->live += static_cast<unsigned long>(len);
    }
    return block;
}

static void host_dealloc(void *user, void *ptr, ztex_u32 len)
{
    host_state *state = static_cast<host_state *>(user);
    if (ptr == NULL) {
        return;
    }
    state->live -= static_cast<unsigned long>(len);
    free(ptr);
}

int main()
{
    host_state state;
    ztex_allocator desc;
    ztex_context *ctx = NULL;
    char *buf;
    ztex_u32 len = 0u;

    state.live = 0UL;
    desc.alloc = host_alloc;
    desc.dealloc = host_dealloc;
    desc.user = &state;

    // Every name below resolved with C linkage, or this would not link.
    if (ztex_context_create(&desc, &ctx) != ZTEX_OK) {
        printf("cxx_consumer: FAILED the context could not be created\n");
        return 1;
    }

    check(ztex_render_svg(ctx, "\\frac{1}{2}", 11u, ZTEX_STYLE_DISPLAY, 20.0f,
                          NULL, NULL, 0, &len) == ZTEX_BUFFER_TOO_SMALL,
          "a C++ host can run the size query");
    check(len > 0u, "the size query reports the payload size");

    buf = static_cast<char *>(malloc(static_cast<size_t>(len) + 1u));
    check(buf != NULL, "the caller can hold the payload");
    if (buf == NULL) {
        ztex_context_destroy(ctx);
        return 1;
    }
    check(ztex_render_svg(ctx, "\\frac{1}{2}", 11u, ZTEX_STYLE_DISPLAY, 20.0f,
                          NULL, reinterpret_cast<ztex_u8 *>(buf), len + 1u, &len) == ZTEX_OK,
          "a C++ host can render");
    check(buf[len] == '\0', "the payload is NUL-terminated");
    check(strncmp(buf, "<svg", 4) == 0, "the payload is an SVG document");
    check(strcmp(ztex_status_name(ZTEX_OK), "ok") == 0,
          "a C++ host can read a status name");
    free(buf);

    ztex_context_destroy(ctx);
    check(state.live == 0UL, "destroying the context gives every byte back");

    if (failures != 0) {
        printf("cxx_consumer: %d check(s) failed\n", failures);
        return 1;
    }
    printf("cxx_consumer: ok\n");
    return 0;
}