// SPDX-License-Identifier: MIT
// vpointer: scripted pointer for the NESTED dev compositor (wlr-virtual-pointer-v1 + xdg-output).
// Never run it against the owner's session: use scripts/dev/pointer.sh, which targets .dev/nested.wayland.
//
// Commands run in order on one virtual pointer:
//   output NAME    select an output; following coordinates are relative to its logical origin
//   abs X Y        absolute move to (X, Y)
//   drag X Y       absolute move to (X, Y) in 20 steps (use between down and up)
//   down | up      left button press / release
//   click          left press + release      rclick   right press + release
//   scroll DY      vertical wheel scroll by DY (positive = down), in 15-unit notches
//   sleep MS       wait
//   outputs        print the logical layout of all outputs
#define _POSIX_C_SOURCE 200809L
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"
#include "xdg-output-unstable-v1-client-protocol.h"

#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#define MAX_OUTPUTS 8

struct output {
    struct wl_output*            wl;
    struct zxdg_output_v1*       xdg;
    char                         name[64];
    int32_t                      x, y, w, h;
};

static struct zwlr_virtual_pointer_manager_v1* manager;
static struct zxdg_output_manager_v1*          xdg_manager;
static struct wl_seat*                         seat;
static struct output                           outputs[MAX_OUTPUTS];
static int                                     n_outputs;

static void xdg_position(void* data, struct zxdg_output_v1* o, int32_t x, int32_t y) {
    (void)o;
    struct output* out = data;
    out->x = x;
    out->y = y;
}
static void xdg_size(void* data, struct zxdg_output_v1* o, int32_t w, int32_t h) {
    (void)o;
    struct output* out = data;
    out->w = w;
    out->h = h;
}
static void xdg_done(void* data, struct zxdg_output_v1* o) {
    (void)data;
    (void)o;
}
static void xdg_name(void* data, struct zxdg_output_v1* o, const char* name) {
    (void)o;
    struct output* out = data;
    snprintf(out->name, sizeof out->name, "%s", name);
}
static void xdg_description(void* data, struct zxdg_output_v1* o, const char* d) {
    (void)data;
    (void)o;
    (void)d;
}
static const struct zxdg_output_v1_listener xdg_listener = {xdg_position, xdg_size, xdg_done, xdg_name, xdg_description};

static void global_add(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0)
        manager = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    else if (strcmp(iface, zxdg_output_manager_v1_interface.name) == 0)
        xdg_manager = wl_registry_bind(reg, name, &zxdg_output_manager_v1_interface, version < 3 ? version : 3);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && !seat)
        seat = wl_registry_bind(reg, name, &wl_seat_interface, version < 5 ? version : 5);
    else if (strcmp(iface, wl_output_interface.name) == 0 && n_outputs < MAX_OUTPUTS)
        outputs[n_outputs++].wl = wl_registry_bind(reg, name, &wl_output_interface, version < 4 ? version : 4);
}

static void global_remove(void* data, struct wl_registry* reg, uint32_t name) {
    (void)data;
    (void)reg;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {global_add, global_remove};

static uint32_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void sleep_ms(long ms) {
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}

static void button(struct wl_display* d, struct zwlr_virtual_pointer_v1* p, uint32_t code, int press) {
    zwlr_virtual_pointer_v1_button(p, now_ms(), code, press ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
    zwlr_virtual_pointer_v1_frame(p);
    wl_display_roundtrip(d);
}

int main(int argc, char** argv) {
    struct wl_display* display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "vpointer: cannot connect to WAYLAND_DISPLAY\n");
        return 1;
    }
    struct wl_registry* registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!manager || !xdg_manager) {
        fprintf(stderr, "vpointer: compositor lacks zwlr_virtual_pointer_manager_v1 or zxdg_output_manager_v1\n");
        return 1;
    }
    for (int i = 0; i < n_outputs; ++i) {
        outputs[i].xdg = zxdg_output_manager_v1_get_xdg_output(xdg_manager, outputs[i].wl);
        zxdg_output_v1_add_listener(outputs[i].xdg, &xdg_listener, &outputs[i]);
    }
    wl_display_roundtrip(display);
    wl_display_roundtrip(display);

    // Layout bounding box (motion_absolute is relative to an extent covering all outputs).
    int32_t minX = 0, minY = 0, maxX = 1, maxY = 1;
    for (int i = 0; i < n_outputs; ++i) {
        const struct output* o = &outputs[i];
        if (i == 0 || o->x < minX) minX = o->x;
        if (i == 0 || o->y < minY) minY = o->y;
        if (i == 0 || o->x + o->w > maxX) maxX = o->x + o->w;
        if (i == 0 || o->y + o->h > maxY) maxY = o->y + o->h;
    }
    const uint32_t extW = (uint32_t)(maxX - minX), extH = (uint32_t)(maxY - minY);

    struct zwlr_virtual_pointer_v1* ptr = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
    wl_display_roundtrip(display);

    int32_t originX = 0, originY = 0;
    double  curX = 0, curY = 0;

    for (int i = 1; i < argc; ++i) {
        const char* cmd = argv[i];
        if (strcmp(cmd, "outputs") == 0) {
            for (int k = 0; k < n_outputs; ++k)
                printf("%s %d,%d %dx%d\n", outputs[k].name, outputs[k].x, outputs[k].y, outputs[k].w, outputs[k].h);
        } else if (strcmp(cmd, "output") == 0 && i + 1 < argc) {
            const char* want = argv[++i];
            int found = 0;
            for (int k = 0; k < n_outputs; ++k) {
                if (strcmp(outputs[k].name, want) == 0) {
                    originX = outputs[k].x;
                    originY = outputs[k].y;
                    found = 1;
                }
            }
            if (!found) {
                fprintf(stderr, "vpointer: no output named %s\n", want);
                return 2;
            }
        } else if ((strcmp(cmd, "abs") == 0 || strcmp(cmd, "drag") == 0) && i + 2 < argc) {
            const double x = originX + atof(argv[++i]) - minX, y = originY + atof(argv[++i]) - minY;
            const int steps = strcmp(cmd, "drag") == 0 ? 20 : 1;
            for (int s = 1; s <= steps; ++s) {
                const double px = steps > 1 ? curX + ((x - curX) * s / steps) : x;
                const double py = steps > 1 ? curY + ((y - curY) * s / steps) : y;
                zwlr_virtual_pointer_v1_motion_absolute(ptr, now_ms(), (uint32_t)px, (uint32_t)py, extW, extH);
                zwlr_virtual_pointer_v1_frame(ptr);
                wl_display_roundtrip(display);
                if (steps > 1)
                    sleep_ms(15);
            }
            curX = x;
            curY = y;
        } else if (strcmp(cmd, "down") == 0) {
            button(display, ptr, BTN_LEFT, 1);
        } else if (strcmp(cmd, "up") == 0) {
            button(display, ptr, BTN_LEFT, 0);
        } else if (strcmp(cmd, "click") == 0 || strcmp(cmd, "rclick") == 0) {
            const uint32_t code = cmd[0] == 'r' ? BTN_RIGHT : BTN_LEFT;
            button(display, ptr, code, 1);
            sleep_ms(40);
            button(display, ptr, code, 0);
        } else if (strcmp(cmd, "scroll") == 0 && i + 1 < argc) {
            const int dy = atoi(argv[++i]);
            const int notches = abs(dy) / 15 > 0 ? abs(dy) / 15 : 1;
            for (int s = 0; s < notches; ++s) {
                zwlr_virtual_pointer_v1_axis_source(ptr, WL_POINTER_AXIS_SOURCE_WHEEL);
                zwlr_virtual_pointer_v1_axis_discrete(ptr, now_ms(), WL_POINTER_AXIS_VERTICAL_SCROLL,
                                                      wl_fixed_from_int(dy > 0 ? 15 : -15), dy > 0 ? 1 : -1);
                zwlr_virtual_pointer_v1_frame(ptr);
                wl_display_roundtrip(display);
                sleep_ms(20);
            }
        } else if (strcmp(cmd, "sleep") == 0 && i + 1 < argc) {
            sleep_ms(atol(argv[++i]));
        } else {
            fprintf(stderr, "vpointer: bad command '%s'\n", cmd);
            return 2;
        }
    }

    zwlr_virtual_pointer_v1_destroy(ptr);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
}
