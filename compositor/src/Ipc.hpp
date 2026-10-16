#pragma once

// Hyprland glue for the gfc/1 protocol (JSON building lives in core/Protocol.*).

#include <string>

namespace gf::ipc {

    // Posts a socket2 event "grassfield>><json>". Non-blocking: Hyprland queues it per client.
    void postEvent(const std::string& json);

    // Posts the capabilities event.
    void postCapabilities();

    // Registers the Lua function(s) (hl.plugin.grassfield.*) and the hyprctl command. Returns false if any failed.
    bool registerAll();

    // Removes everything registerAll() added. Safe to call more than once.
    void unregisterAll();

} // namespace gf::ipc
