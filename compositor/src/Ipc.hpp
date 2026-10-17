#pragma once

// Hyprland glue for the gfc/1 protocol (JSON building lives in core/Protocol.*, event rate limits in
// core/EventThrottle.*).

#include "core/EventThrottle.hpp"

#include <string>

namespace gf::ipc {

    // Posts a socket2 event "grassfield>><json>" through the event throttle (spec FR24): an event replaces a waiting
    // event of the same key, each key posts at most once per 100 ms, all keys together at most 32 at once and then
    // 50/s. A waiting event is never dropped: a Hyprland event loop timer posts it when it is due. Never blocks.
    void postEvent(events::Key key, std::string json);

    // Enables the throttle (PLUGIN_INIT, before anything posts).
    void startEvents();

    // Unload: posts every waiting event now and removes the timer (its callback is code of this library). Events
    // posted afterwards go out directly. Safe to call more than once.
    void stopEvents();

    // Posts the capabilities event (features computed from what registered: see gfc::features).
    void postCapabilities();

    // The minimize / restore entry points and the minimize render hooks are all registered.
    bool minimizeAvailable();

    // The appmenu global is advertised and hl.plugin.grassfield.appmenu is registered.
    bool appmenuAvailable();

    // The overview render hooks are registered and hl.plugin.grassfield.overview is registered.
    bool overviewAvailable();

    // Registers the Lua function(s) (hl.plugin.grassfield.*) and the hyprctl command. Returns false if any failed.
    bool registerAll();

    // Removes everything registerAll() added. Safe to call more than once.
    void unregisterAll();

} // namespace gf::ipc
