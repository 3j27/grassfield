// SPDX-License-Identifier: MIT
// xdgact: a window that activates ITSELF through xdg-activation-v1, for the NESTED dev compositor (tests/shell/show_desktop_nested.sh),
// and that unmaps itself without being destroyed (tests/compositor/tiling.sh, gate C1).
// Never run it against the owner's session: use tests/tools/xdgact/xdgact.sh, which targets only the verified nested socket.
//
// Usage: xdgact APP_ID
// Opens a small toplevel with the app id, prints "mapped" once it is shown, and waits. On SIGUSR1 it asks the compositor for an
// activation token and activates its own surface with it: what an app does to bring its window forward (a real client request,
// handled by Hyprland's CWindow::activate with misc.focus_on_activate), as opposed to the focus dispatcher. Prints "activated" when
// the request is sent. On SIGUSR2 it attaches a null buffer and commits: the toplevel unmaps while every object stays alive (what an
// app that closes to the tray does), and prints "unmapped". Ends on SIGTERM/SIGINT or when the window is closed.
#define _GNU_SOURCE
#include "xdg-activation-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#define WIDTH 240
#define HEIGHT 140

static struct wl_compositor*       compositor;
static struct wl_shm*              shm;
static struct xdg_wm_base*         wm_base;
static struct xdg_activation_v1*   activation;
static struct wl_surface*          surface;
static struct wl_display*          display;
static volatile sig_atomic_t       want_activate;
static volatile sig_atomic_t       want_unmap;
static volatile sig_atomic_t       want_exit;
static int                         closed;
static int                         mapped;

static void on_signal(int sig) {
    if (sig == SIGUSR1)
        want_activate = 1;
    else if (sig == SIGUSR2)
        want_unmap = 1;
    else
        want_exit = 1;
}

static void global_add(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(iface, wl_compositor_interface.name) == 0)
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (strcmp(iface, wl_shm_interface.name) == 0)
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(iface, xdg_wm_base_interface.name) == 0)
        wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
    else if (strcmp(iface, xdg_activation_v1_interface.name) == 0)
        activation = wl_registry_bind(reg, name, &xdg_activation_v1_interface, 1);
}
static void global_remove(void* data, struct wl_registry* reg, uint32_t name) {
    (void)data;
    (void)reg;
    (void)name;
}
static const struct wl_registry_listener registry_listener = {global_add, global_remove};

static void ping(void* data, struct xdg_wm_base* base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = {ping};

static struct wl_buffer* make_buffer(void) {
    const int stride = WIDTH * 4;
    const int size   = stride * HEIGHT;
    int       fd     = memfd_create("xdgact", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, size) < 0)
        return NULL;
    uint32_t* px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED)
        return NULL;
    for (int i = 0; i < WIDTH * HEIGHT; i++)
        px[i] = 0xff3a6ea5;
    munmap(px, size);
    struct wl_shm_pool* pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer*   buf  = wl_shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buf;
}

static void surface_configure(void* data, struct xdg_surface* xs, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(xs, serial);
    if (!mapped) {
        struct wl_buffer* buf = make_buffer();
        if (!buf)
            return;
        wl_surface_attach(surface, buf, 0, 0);
        wl_surface_commit(surface);
        mapped = 1;
        printf("mapped\n");
        fflush(stdout);
    }
}
static const struct xdg_surface_listener surface_listener = {surface_configure};

static void toplevel_configure(void* data, struct xdg_toplevel* t, int32_t w, int32_t h, struct wl_array* states) {
    (void)data;
    (void)t;
    (void)w;
    (void)h;
    (void)states;
}
static void toplevel_close(void* data, struct xdg_toplevel* t) {
    (void)data;
    (void)t;
    closed = 1;
}
static void toplevel_bounds(void* data, struct xdg_toplevel* t, int32_t w, int32_t h) {
    (void)data;
    (void)t;
    (void)w;
    (void)h;
}
static void toplevel_caps(void* data, struct xdg_toplevel* t, struct wl_array* caps) {
    (void)data;
    (void)t;
    (void)caps;
}
static const struct xdg_toplevel_listener toplevel_listener = {toplevel_configure, toplevel_close, toplevel_bounds, toplevel_caps};

static void token_done(void* data, struct xdg_activation_token_v1* token, const char* str) {
    (void)data;
    xdg_activation_v1_activate(activation, str, surface);
    xdg_activation_token_v1_destroy(token);
    printf("activated\n");
    fflush(stdout);
}
static const struct xdg_activation_token_v1_listener token_listener = {token_done};

static void request_activation(const char* app_id) {
    struct xdg_activation_token_v1* token = xdg_activation_v1_get_activation_token(activation);
    xdg_activation_token_v1_add_listener(token, &token_listener, NULL);
    xdg_activation_token_v1_set_app_id(token, app_id);
    xdg_activation_token_v1_set_surface(token, surface);
    xdg_activation_token_v1_commit(token);
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: xdgact APP_ID\n");
        return 2;
    }
    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "xdgact: no wayland display\n");
        return 1;
    }
    struct sigaction sa = {.sa_handler = on_signal};
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    struct wl_registry* reg = wl_display_get_registry(display);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !wm_base || !activation) {
        fprintf(stderr, "xdgact: the compositor lacks wl_compositor, wl_shm, xdg_wm_base or xdg_activation_v1\n");
        return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);
    surface                  = wl_compositor_create_surface(compositor);
    struct xdg_surface*  xs  = xdg_wm_base_get_xdg_surface(wm_base, surface);
    struct xdg_toplevel* top = xdg_surface_get_toplevel(xs);
    xdg_surface_add_listener(xs, &surface_listener, NULL);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_app_id(top, argv[1]);
    xdg_toplevel_set_title(top, argv[1]);
    wl_surface_commit(surface);

    while (!want_exit && !closed) {
        wl_display_flush(display);
        if (want_activate) {
            want_activate = 0;
            request_activation(argv[1]);
            continue;
        }
        if (want_unmap) {
            want_unmap = 0;
            wl_surface_attach(surface, NULL, 0, 0);
            wl_surface_commit(surface);
            printf("unmapped\n");
            fflush(stdout);
            continue;
        }
        struct pollfd pfd = {.fd = wl_display_get_fd(display), .events = POLLIN};
        while (wl_display_prepare_read(display) != 0) {
            if (wl_display_dispatch_pending(display) < 0)
                goto done;
        }
        if (wl_display_flush(display) < 0 && errno != EAGAIN) {
            wl_display_cancel_read(display);
            break;   // the compositor is gone
        }
        int n = poll(&pfd, 1, 50);
        if (n > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
            wl_display_cancel_read(display);
            break;   // the compositor hung up: end, do not spin
        }
        if (n > 0 && (pfd.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0 || wl_display_dispatch_pending(display) < 0)
                break;
        } else {
            wl_display_cancel_read(display);
        }
        if (n < 0 && errno != EINTR)
            break;
    }
done:
    wl_display_disconnect(display);
    return 0;
}
