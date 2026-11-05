// SPDX-License-Identifier: MIT
// framepulse: a frame-time probe for the NESTED dev compositor (gate P3, docs/specs/overview.md "Measuring P3 and S4").
//
// A small xdg-toplevel that redraws on every frame callback and prints, for each callback, the time since the previous one
// (CLOCK_MONOTONIC, microseconds). A compositor that renders every output frame in time delivers one callback per refresh;
// a frame it drops or delays shows as an interval of two refreshes or more. Run it while the Overview opens and closes:
// the share of intervals that stay below the refresh period (plus a tolerance) is the smoothness the gate asks for.
//
//   framepulse SECONDS            prints "epoch_us interval_us" lines, then "# frames N" and "# seconds S"
//   WAYLAND_DISPLAY must name the nested compositor; scripts/dev refuses the owner's socket, this tool refuses it too.
//
// Build (done by tests/visual/overview-frames.sh): wayland-scanner client-header/private-code xdg-shell.xml, then
//   gcc -std=c11 -O1 -Wall -Wextra -I<dir> framepulse.c xdg-shell-protocol.c $(pkg-config --cflags --libs wayland-client)
#define _GNU_SOURCE
#include "xdg-shell-client-protocol.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#define W 64
#define H 64

static struct wl_compositor* compositor;
static struct wl_shm*        shm;
static struct xdg_wm_base*   wm;
static struct wl_surface*    surface;
static struct wl_buffer*     buffers[2];
static uint32_t*             pixels[2];
static int                   current;
static int                   configured;
static int64_t               last_us;
static int64_t               start_us;
static int64_t               limit_us;
static long                  frames;
static int                   done;

static int64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void ping(void* data, struct xdg_wm_base* base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}

static const struct xdg_wm_base_listener wm_listener = {ping};

static void registry_global(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    if (!strcmp(iface, wl_compositor_interface.name))
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, version < 4 ? version : 4);
    else if (!strcmp(iface, wl_shm_interface.name))
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (!strcmp(iface, xdg_wm_base_interface.name)) {
        wm = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    }
}

static void registry_remove(void* data, struct wl_registry* reg, uint32_t name) {
    (void)data;
    (void)reg;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {registry_global, registry_remove};

static void draw(void);

static void frame_done(void* data, struct wl_callback* cb, uint32_t time) {
    (void)data;
    (void)time;
    wl_callback_destroy(cb);
    int64_t t = now_us();
    if (last_us != 0) {
        struct timespec wall;
        clock_gettime(CLOCK_REALTIME, &wall);
        printf("%lld %lld\n", (long long)wall.tv_sec * 1000000 + wall.tv_nsec / 1000, (long long)(t - last_us));
        frames++;
    }
    last_us = t;
    if (t - start_us >= limit_us) {
        done = 1;
        return;
    }
    draw();
}

static const struct wl_callback_listener frame_listener = {frame_done};

static void draw(void) {
    // Alternate two buffers and change one pixel row per frame so every commit is real damage.
    current ^= 1;
    for (int i = 0; i < W * H; i++)
        pixels[current][i] = 0xFF000000u | (uint32_t)((frames * 7 + i) & 0xFF) << 8;
    struct wl_callback* cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    wl_surface_attach(surface, buffers[current], 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, W, H);
    wl_surface_commit(surface);
}

static void surface_configure(void* data, struct xdg_surface* xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    if (!configured) {
        configured = 1;
        start_us = now_us();
        draw();
    }
}

static const struct xdg_surface_listener surface_listener = {surface_configure};

static void toplevel_configure(void* d, struct xdg_toplevel* t, int32_t w, int32_t h, struct wl_array* s) {
    (void)d; (void)t; (void)w; (void)h; (void)s;
}

static void toplevel_close(void* d, struct xdg_toplevel* t) {
    (void)d;
    (void)t;
    done = 1;
}

static const struct xdg_toplevel_listener toplevel_listener = {toplevel_configure, toplevel_close, NULL, NULL};

int main(int argc, char** argv) {
    const char* display = getenv("WAYLAND_DISPLAY");
    if (argc != 2 || !display) {
        fprintf(stderr, "usage: WAYLAND_DISPLAY=<nested socket> framepulse SECONDS\n");
        return 2;
    }
    // The owner's session is wayland-1: never start a client there.
    if (!strcmp(display, "wayland-1") || !strcmp(display, "/run/user/1000/wayland-1")) {
        fprintf(stderr, "framepulse: refusing the owner's Wayland socket\n");
        return 2;
    }
    limit_us = (int64_t)(atof(argv[1]) * 1e6);
    if (limit_us <= 0)
        return 2;
    struct wl_display* dpy = wl_display_connect(NULL);
    if (!dpy) {
        fprintf(stderr, "framepulse: cannot connect to %s\n", display);
        return 1;
    }
    struct wl_registry* reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !shm || !wm) {
        fprintf(stderr, "framepulse: compositor, shm or xdg_wm_base missing\n");
        return 1;
    }
    const int stride = W * 4;
    const int size = stride * H;
    int fd = memfd_create("framepulse", 0);
    if (fd < 0 || ftruncate(fd, 2 * size) < 0) {
        perror("framepulse: shm");
        return 1;
    }
    void* map = mmap(NULL, 2 * size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        perror("framepulse: mmap");
        return 1;
    }
    struct wl_shm_pool* pool = wl_shm_create_pool(shm, fd, 2 * size);
    for (int i = 0; i < 2; i++) {
        pixels[i] = (uint32_t*)((char*)map + i * size);
        buffers[i] = wl_shm_pool_create_buffer(pool, i * size, W, H, stride, WL_SHM_FORMAT_XRGB8888);
    }
    wl_shm_pool_destroy(pool);
    close(fd);

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface* xs = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xs, &surface_listener, NULL);
    struct xdg_toplevel* top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_title(top, "framepulse");
    xdg_toplevel_set_app_id(top, "gf-framepulse");
    wl_surface_commit(surface);

    while (!done && wl_display_dispatch(dpy) != -1) {
    }
    printf("# frames %ld\n", frames);
    printf("# seconds %.3f\n", (now_us() - start_us) / 1e6);
    return 0;
}
