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
// Build: tests/fixtures/build.sh (wayland-scanner client code from compositor/protocols/appmenu.xml).

#include "appmenu-client-protocol.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

static struct wl_compositor*                compositor;
static struct org_kde_kwin_appmenu_manager* manager;
static uint32_t                             managerAdvertised;

static void onGlobal(void* data, struct wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
    (void)data;
    if (strcmp(interface, wl_compositor_interface.name) == 0)
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
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

int main(void) {
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
