#pragma once

// org_kde_kwin_appmenu server (master-prompt §5.6 feature 3, D4, ADR-0008). Hyprland glue; validation and the
// per-surface registrations live in core/Appmenu.*.
//
// Hyprland 0.56.2 has no plugin API for Wayland protocols. The global is created with libwayland's
// wl_global_create on g_pCompositor->m_wlDisplay, and the request handlers come from server code that
// hyprwayland-scanner generates from compositor/protocols/appmenu.xml (version 2), compiled into the plugin
// (as Hyprland does for its own protocols). Every wl_resource created here points into this library (its
// wl_interface, request table and destroy listener), so none may outlive the library's code:
// - compositor shutdown (PLUGIN_EXIT while Hyprland is shutting down): every resource and the global are
//   destroyed before dlclose; clients are being disconnected anyway;
// - runtime unload with live client objects: the library pins itself in memory (dlopen RTLD_NOLOAD |
//   RTLD_NODELETE), removes the global (wl_global_remove: no new binds are advertised) and leaves the client
//   objects inert (requests ignored, destructors honored). Destroying them instead would make libwayland
//   disconnect the client at its next request on them (invalid object). A rebuilt plugin at the same path
//   is then only picked up after Hyprland restarts. Without live objects nothing is pinned.

#include <cstdint>

namespace gf::appmenuServer {

    // Creates the org_kde_kwin_appmenu_manager global (version 2) and the window listeners. False if anything
    // failed (everything registered so far is removed; appmenu is then not advertised).
    bool start();

    // Unload (see above). Safe to call more than once.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // hl.plugin.grassfield.appmenu(address): posts the appmenu event of a mapped window (its registration, or
    // empty service and path). False, and nothing posted, when the address is not a mapped window.
    bool announce(uint64_t windowAddress);

} // namespace gf::appmenuServer
