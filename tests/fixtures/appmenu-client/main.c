// SPDX-License-Identifier: MIT
// appmenu-client: protocol edge cases against grassfield-compositor's org_kde_kwin_appmenu server. TEST FIXTURE.
// Run it only against the NESTED compositor (WAYLAND_DISPLAY=<nested socket>), see tests/compositor/appmenu.sh.
//
// Qt 6.11 and Chromium 152 both bind the manager at version 1 and only send well-formed requests, so this client
// covers the rest: invalid service names and object paths (must be ignored without disconnecting the client),
// two appmenu objects on one surface, a surface without a role (never a window: no event), the version 2
// manager `release`, and leaving with live objects (the plugin's destroy path). It prints what it did and exits
// 0 when the connection never got a protocol error.
//
// --spam N [--hold MS]: a hostile client. It maps a real xdg_toplevel window (shm buffer), links it to one appmenu
// object, then sends N set_address requests on that object in one burst, alternating "/MenuBar/1" and "/MenuBar/2";
// the last one is "/MenuBar/final" (the registration the shell must end up with). It then keeps the window for MS
// milliseconds (default 1500, answering pings) and exits. Every request is valid, so without coalescing each one
// would become a socket2 event.
//
// Build: tests/fixtures/build.sh (wayland-scanner client code from compositor/protocols/appmenu.xml and
// xdg-shell.xml).

#define _GNU_SOURCE

#include "appmenu-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

static struct wl_compositor*                compositor;
static struct wl_shm*                       shm;
static struct xdg_wm_base*                  wmBase;
static struct org_kde_kwin_appmenu_manager* manager;
static uint32_t                             managerAdvertised;

static void onGlobal(void* data, struct wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, wl_compositor_interface.name) == 0)
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (strcmp(interface, wl_shm_interface.name) == 0)
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (strcmp(interface, xdg_wm_base_interface.name) == 0)
        wmBase = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
    else if (strcmp(interface, org_kde_kwin_appmenu_manager_interface.name) == 0) {
        managerAdvertised = version;
        manager           = wl_registry_bind(registry, name, &org_kde_kwin_appmenu_manager_interface, version < 2 ? version : 2);
    }
}

static void onGlobalRemove(void* data, struct wl_registry* registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registryListener = {.global = onGlobal, .global_remove = onGlobalRemove};

static int check(struct wl_display* display, const char* step) {
    if (wl_display_roundtrip(display) < 0 || wl_display_get_error(display) != 0) {
        printf("appmenu-client: FAIL protocol error after %s (error %d)\n", step, wl_display_get_error(display));
        return 0;
    }
    printf("appmenu-client: ok %s\n", step);
    return 1;
}

// ---- --spam ---------------------------------------------------------------------------------------------------

static int configured;

static void onPing(void* data, struct xdg_wm_base* base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener wmBaseListener = {.ping = onPing};

static void onSurfaceConfigure(void* data, struct xdg_surface* surface, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(surface, serial);
    configured = 1;
}

static const struct xdg_surface_listener xdgSurfaceListener = {.configure = onSurfaceConfigure};

static void onToplevelConfigure(void* data, struct xdg_toplevel* toplevel, int32_t width, int32_t height, struct wl_array* states) {
    (void)data;
    (void)toplevel;
    (void)width;
    (void)height;
    (void)states;
}

static void onToplevelClose(void* data, struct xdg_toplevel* toplevel) {
    (void)data;
    (void)toplevel;
}

// xdg_wm_base is bound at version 1: configure_bounds and wm_capabilities are never sent.
static const struct xdg_toplevel_listener toplevelListener = {.configure = onToplevelConfigure, .close = onToplevelClose};

static long elapsedMs(const struct timespec* start) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - start->tv_sec) * 1000 + (now.tv_nsec - start->tv_nsec) / 1000000;
}

// Writes everything queued, waiting while the socket is full.
static int flushAll(struct wl_display* display) {
    while (wl_display_flush(display) < 0) {
        if (errno != EAGAIN)
            return 0;
        struct pollfd p = {.fd = wl_display_get_fd(display), .events = POLLOUT};
        if (poll(&p, 1, 2000) <= 0)
            return 0;
    }
    return 1;
}

// Dispatches events (pings) for `ms` milliseconds.
static int holdFor(struct wl_display* display, long ms) {
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        const long elapsed = elapsedMs(&start);
        if (elapsed >= ms)
            return 1;
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0)
                return 0;
        }
        if (!flushAll(display)) {
            wl_display_cancel_read(display);
            return 0;
        }
        struct pollfd p = {.fd = wl_display_get_fd(display), .events = POLLIN};
        if (poll(&p, 1, (int)(ms - elapsed)) > 0) {
            if (wl_display_read_events(display) < 0)
                return 0;
        } else
            wl_display_cancel_read(display);
        if (wl_display_dispatch_pending(display) < 0)
            return 0;
    }
}

static struct wl_buffer* makeBuffer(int width, int height) {
    const int stride = width * 4;
    const int size   = stride * height;
    const int fd     = memfd_create("appmenu-client", MFD_CLOEXEC);
    if (fd < 0)
        return NULL;
    if (ftruncate(fd, size) < 0) {
        close(fd);
        return NULL;
    }
    uint32_t* pixels = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    for (int i = 0; i < width * height; ++i)
        pixels[i] = 0xff2f6fb0;
    munmap(pixels, (size_t)size);
    struct wl_shm_pool* pool   = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer*   buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buffer;
}

static int spam(struct wl_display* display, long count, long holdMs) {
    if (!shm || !wmBase) {
        printf("appmenu-client: no wl_shm or xdg_wm_base global\n");
        return 2;
    }
    xdg_wm_base_add_listener(wmBase, &wmBaseListener, NULL);
    struct wl_surface*   surface  = wl_compositor_create_surface(compositor);
    struct xdg_surface*  xsurface = xdg_wm_base_get_xdg_surface(wmBase, surface);
    struct xdg_toplevel* toplevel = xdg_surface_get_toplevel(xsurface);
    xdg_surface_add_listener(xsurface, &xdgSurfaceListener, NULL);
    xdg_toplevel_add_listener(toplevel, &toplevelListener, NULL);
    xdg_toplevel_set_title(toplevel, "appmenu-client spam");
    xdg_toplevel_set_app_id(toplevel, "gf-appmenu-spam");
    wl_surface_commit(surface);
    while (!configured) {
        if (wl_display_dispatch(display) < 0) {
            printf("appmenu-client: FAIL connection lost before the first configure\n");
            return 1;
        }
    }
    struct wl_buffer* buffer = makeBuffer(320, 200);
    if (!buffer) {
        printf("appmenu-client: cannot create a shm buffer\n");
        return 2;
    }
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, 320, 200);
    wl_surface_commit(surface);
    struct org_kde_kwin_appmenu* menu = org_kde_kwin_appmenu_manager_create(manager, surface);
    if (!check(display, "window mapped with an appmenu object"))
        return 1;
    fflush(stdout);
    // Let the map and focus events go out first: the burst below is then the only appmenu traffic.
    if (!holdFor(display, 700))
        return 1;

    const char*     service = ":1.999";
    const char*     final   = "/MenuBar/final";
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (long i = 0; i < count; ++i) {
        org_kde_kwin_appmenu_set_address(menu, service, i == count - 1 ? final : (i % 2 ? "/MenuBar/2" : "/MenuBar/1"));
        if (i % 512 == 511 && !flushAll(display)) {
            printf("appmenu-client: FAIL write error after %ld requests\n", i + 1);
            return 1;
        }
    }
    if (!flushAll(display))
        return 1;
    char step[128];
    snprintf(step, sizeof(step), "%ld set_address requests sent in %ld ms", count, elapsedMs(&start));
    if (!check(display, step))
        return 1;
    printf("appmenu-client: final set_address %s %s\n", service, final);
    fflush(stdout);
    const int held = holdFor(display, holdMs) && check(display, "window kept, connection alive");

    org_kde_kwin_appmenu_release(menu);
    xdg_toplevel_destroy(toplevel);
    xdg_surface_destroy(xsurface);
    wl_surface_destroy(surface);
    wl_buffer_destroy(buffer);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    printf("appmenu-client: %s\n", held ? "PASS" : "FAIL");
    return held ? 0 : 1;
}

int main(int argc, char** argv) {
    long spamCount = 0;
    long holdMs    = 1500;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--spam") == 0 && i + 1 < argc)
            spamCount = strtol(argv[++i], NULL, 10);
        else if (strcmp(argv[i], "--hold") == 0 && i + 1 < argc)
            holdMs = strtol(argv[++i], NULL, 10);
        else {
            printf("usage: appmenu-client [--spam N [--hold MS]]\n");
            return 2;
        }
    }
    if (argc > 1 && (spamCount < 1 || spamCount > 10000000 || holdMs < 0)) {
        printf("appmenu-client: --spam needs 1..10000000 requests, --hold a duration >= 0\n");
        return 2;
    }

    struct wl_display* display = wl_display_connect(NULL);
    if (!display) {
        printf("appmenu-client: cannot connect to WAYLAND_DISPLAY\n");
        return 2;
    }
    struct wl_registry* registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registryListener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !manager) {
        printf("appmenu-client: no org_kde_kwin_appmenu_manager global\n");
        return 2;
    }
    printf("appmenu-client: manager advertised version %u, bound version %u\n", managerAdvertised, org_kde_kwin_appmenu_manager_get_version(manager));
    if (spamCount > 0)
        return spam(display, spamCount, holdMs);

    struct wl_surface*           surface = wl_compositor_create_surface(compositor);
    struct org_kde_kwin_appmenu* menu    = org_kde_kwin_appmenu_manager_create(manager, surface);

    char longName[300];
    memset(longName, 'a', sizeof(longName) - 1);
    longName[1]                   = '.';
    longName[sizeof(longName) - 1] = '\0';
    char longPath[300];
    memset(longPath, 'p', sizeof(longPath) - 1);
    longPath[0]                   = '/';
    longPath[sizeof(longPath) - 1] = '\0';
    const char* invalid[][2] = {
        {"", ""},                         {"org.kde.Foo", ""},           {"", "/MenuBar/1"},      {"bad name", "/MenuBar/1"},
        {"org..foo", "/MenuBar/1"},       {"1org.foo", "/MenuBar/1"},    {":1", "/MenuBar/1"},    {"org.f\xe9" "e.Bar", "/MenuBar/1"},
        {"org.kde.Foo", "MenuBar/1"},     {"org.kde.Foo", "/a//b"},      {"org.kde.Foo", "/a/"},  {"org.kde.Foo", "/a-b"},
        {"x\",\"type\":\"evil", "/MenuBar/1"}, {longName, "/MenuBar/1"}, {"org.kde.Foo", longPath},
    };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i)
        org_kde_kwin_appmenu_set_address(menu, invalid[i][0], invalid[i][1]);
    int ok = check(display, "15 invalid set_address requests (ignored, still connected)");

    org_kde_kwin_appmenu_set_address(menu, ":1.999", "/MenuBar/1");
    ok = ok && check(display, "valid set_address on a surface without a role");

    struct org_kde_kwin_appmenu* second = org_kde_kwin_appmenu_manager_create(manager, surface);
    org_kde_kwin_appmenu_set_address(second, "org.example.Second", "/MenuBar/2");
    org_kde_kwin_appmenu_release(second);
    ok = ok && check(display, "second appmenu object on the same surface, released");

    org_kde_kwin_appmenu_release(menu);
    ok = ok && check(display, "appmenu release");

    // A live object at exit: the plugin's destroy path (client disconnect) runs for it.
    struct org_kde_kwin_appmenu* left = org_kde_kwin_appmenu_manager_create(manager, surface);
    org_kde_kwin_appmenu_set_address(left, ":1.999", "/MenuBar/3");
    ok = ok && check(display, "object left alive for the disconnect path");

    if (org_kde_kwin_appmenu_manager_get_version(manager) >= 2) {
        org_kde_kwin_appmenu_manager_release(manager);
        ok = ok && check(display, "manager release (version 2)");
    }

    wl_display_disconnect(display);
    printf("appmenu-client: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
