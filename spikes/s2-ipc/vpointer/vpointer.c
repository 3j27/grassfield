// S2 spike (throwaway): scripted pointer for the NESTED compositor via wlr-virtual-pointer-v1.
// Build + usage: see build.sh. Commands run in order on one virtual pointer:
//   extent W H     layout size used for absolute motion (required before abs/drag)
//   abs X Y        absolute move to layout coordinates (X, Y)
//   drag X Y       absolute move to (X, Y) in 20 steps (use between down and up)
//   down | up      left button press / release
//   click          down + up
//   sleep MS       wait
#define _POSIX_C_SOURCE 200809L
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

static struct zwlr_virtual_pointer_manager_v1* manager;
static struct wl_seat*                         seat;

static void global_add(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0)
        manager = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && !seat)
        seat = wl_registry_bind(reg, name, &wl_seat_interface, version < 5 ? version : 5);
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

int main(int argc, char** argv) {
    struct wl_display* display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "vpointer: cannot connect to WAYLAND_DISPLAY\n");
        return 1;
    }
    struct wl_registry* registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!manager) {
        fprintf(stderr, "vpointer: compositor has no zwlr_virtual_pointer_manager_v1\n");
        return 1;
    }

    struct zwlr_virtual_pointer_v1* ptr = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, seat);
    wl_display_roundtrip(display);

    uint32_t extW = 0, extH = 0;
    double   curX = 0, curY = 0;

    for (int i = 1; i < argc; ++i) {
        const char* cmd = argv[i];
        if (strcmp(cmd, "extent") == 0 && i + 2 < argc) {
            extW = (uint32_t)atoi(argv[++i]);
            extH = (uint32_t)atoi(argv[++i]);
        } else if ((strcmp(cmd, "abs") == 0 || strcmp(cmd, "drag") == 0) && i + 2 < argc) {
            const double x = atof(argv[++i]), y = atof(argv[++i]);
            if (!extW || !extH) {
                fprintf(stderr, "vpointer: extent required before %s\n", cmd);
                return 2;
            }
            const int steps = strcmp(cmd, "drag") == 0 ? 20 : 1;
            for (int s = 1; s <= steps; ++s) {
                const double px = curX + ((x - curX) * s / steps), py = curY + ((y - curY) * s / steps);
                zwlr_virtual_pointer_v1_motion_absolute(ptr, now_ms(), (uint32_t)px, (uint32_t)py, extW, extH);
                zwlr_virtual_pointer_v1_frame(ptr);
                wl_display_roundtrip(display);
                if (steps > 1)
                    sleep_ms(15);
            }
            curX = x;
            curY = y;
        } else if (strcmp(cmd, "down") == 0 || strcmp(cmd, "up") == 0 || strcmp(cmd, "click") == 0) {
            if (strcmp(cmd, "up") != 0) {
                zwlr_virtual_pointer_v1_button(ptr, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
                zwlr_virtual_pointer_v1_frame(ptr);
                wl_display_roundtrip(display);
            }
            if (strcmp(cmd, "click") == 0)
                sleep_ms(40);
            if (strcmp(cmd, "down") != 0) {
                zwlr_virtual_pointer_v1_button(ptr, now_ms(), BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
                zwlr_virtual_pointer_v1_frame(ptr);
                wl_display_roundtrip(display);
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
