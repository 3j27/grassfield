// SPDX-License-Identifier: MIT
// vkbd: scripted keyboard for the NESTED dev compositor (zwp_virtual_keyboard_v1 with its own us keymap).
// Never run it against the owner's session: use tests/tools/vkbd/vkbd.sh, which targets only the verified nested socket.
//
// Commands run in order on one virtual keyboard (key names are xkb keysym names, any case: Super_L, Tab, q, grave, Escape):
//   down KEY | up KEY   press / release
//   tap KEY             press + release (40 ms apart)
//   sleep MS            wait
// Modifier state is tracked with xkbcommon and sent after every key, so SUPER+TAB is `down Super_L tap Tab up Super_L`.
// Every key still held when the commands end (or on error) is released, so the tool never leaves a key stuck.
#define _GNU_SOURCE
#include "virtual-keyboard-unstable-v1-client-protocol.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#define MAX_HELD 16

static struct zwp_virtual_keyboard_manager_v1* manager;
static struct wl_seat*                         seat;
static struct zwp_virtual_keyboard_v1*         kbd;
static struct wl_display*                      display;
static struct xkb_keymap*                      keymap;
static struct xkb_state*                       state;
static uint32_t                                held[MAX_HELD];
static int                                     n_held;

static void global_add(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0)
        manager = wl_registry_bind(reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    else if (strcmp(iface, wl_seat_interface.name) == 0 && !seat)
        seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
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

// evdev keycode of the key whose first level produces `sym`; 0 when the keymap has none.
static uint32_t keycode_for(xkb_keysym_t sym) {
    for (xkb_keycode_t kc = xkb_keymap_min_keycode(keymap); kc <= xkb_keymap_max_keycode(keymap); ++kc) {
        const xkb_keysym_t* syms;
        if (xkb_keymap_num_layouts_for_key(keymap, kc) < 1)
            continue;
        if (xkb_keymap_key_get_syms_by_level(keymap, kc, 0, 0, &syms) >= 1 && syms[0] == sym)
            return kc - 8;
    }
    return 0;
}

static void send_key(uint32_t code, int press) {
    zwp_virtual_keyboard_v1_key(kbd, now_ms(), code, press ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
    xkb_state_update_key(state, code + 8, press ? XKB_KEY_DOWN : XKB_KEY_UP);
    zwp_virtual_keyboard_v1_modifiers(kbd, xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
                                      xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
                                      xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
                                      xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
    wl_display_roundtrip(display);
    int i = 0;
    for (; i < n_held && held[i] != code; ++i)
        ;
    if (press && i == n_held && n_held < MAX_HELD)
        held[n_held++] = code;
    else if (!press && i < n_held)
        held[i] = held[--n_held];
}

static void release_all(void) {
    while (n_held > 0)
        send_key(held[n_held - 1], 0);
}

int main(int argc, char** argv) {
    display = wl_display_connect(NULL);
    if (!display) {
        fprintf(stderr, "vkbd: cannot connect to WAYLAND_DISPLAY\n");
        return 1;
    }
    struct wl_registry* registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!manager || !seat) {
        fprintf(stderr, "vkbd: compositor lacks zwp_virtual_keyboard_manager_v1\n");
        return 1;
    }

    struct xkb_context* ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    const struct xkb_rule_names names = {.rules = "evdev", .model = "pc105", .layout = "us", .variant = "", .options = ""};
    keymap = ctx ? xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS) : NULL;
    if (!keymap) {
        fprintf(stderr, "vkbd: cannot compile the us keymap\n");
        return 1;
    }
    state = xkb_state_new(keymap);
    char* text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    const size_t size = strlen(text) + 1;
    int fd = memfd_create("vkbd-keymap", 0);
    if (fd < 0 || ftruncate(fd, (off_t)size) != 0) {
        perror("vkbd: keymap file");
        return 1;
    }
    void* map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        perror("vkbd: mmap");
        return 1;
    }
    memcpy(map, text, size);
    munmap(map, size);
    free(text);

    kbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
    zwp_virtual_keyboard_v1_keymap(kbd, 1 /* xkb_v1 */, fd, (uint32_t)size);
    wl_display_roundtrip(display);

    int rc = 0;
    for (int i = 1; i < argc && rc == 0; ++i) {
        const char* cmd = argv[i];
        if (strcmp(cmd, "sleep") == 0 && i + 1 < argc) {
            sleep_ms(atol(argv[++i]));
        } else if ((strcmp(cmd, "down") == 0 || strcmp(cmd, "up") == 0 || strcmp(cmd, "tap") == 0) && i + 1 < argc) {
            const char*    key  = argv[++i];
            xkb_keysym_t   sym  = xkb_keysym_from_name(key, XKB_KEYSYM_CASE_INSENSITIVE);
            const uint32_t code = sym == XKB_KEY_NoSymbol ? 0 : keycode_for(sym);
            if (code == 0) {
                fprintf(stderr, "vkbd: unknown key '%s'\n", key);
                rc = 2;
                break;
            }
            if (cmd[0] == 'd') {
                send_key(code, 1);
            } else if (cmd[0] == 'u') {
                send_key(code, 0);
            } else {
                send_key(code, 1);
                sleep_ms(40);
                send_key(code, 0);
            }
        } else {
            fprintf(stderr, "vkbd: bad command '%s'\n", cmd);
            rc = 2;
        }
    }
    release_all();
    zwp_virtual_keyboard_v1_destroy(kbd);
    wl_display_roundtrip(display);
    return rc;
}
