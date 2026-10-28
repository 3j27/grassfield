#pragma once

// Hyprland glue for the gfc/1 protocol (JSON building lives in core/Protocol.*, event rate limits in
// core/EventThrottle.*).

#include "core/EventThrottle.hpp"

#include <cstdint>
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

    // Posts minimize-request for the window at `address` (FR6: the shell answers with hl.plugin.grassfield.minimize and
    // its Dock tile, or parks the window itself without the minimize feature). Coalesced per window (FR24): the titlebar's
    // minimize light and a client-chrome window's set_minimized (ADR-0015 P5) take this one path.
    void postMinimizeRequest(uint64_t address);

    // Unload: posts a capabilities event with no feature at once (not throttled), so that the shell goes back to its
    // fallbacks (desktop focus workarounds, minimize parking, T0 menus, thumbnails) as without the plugin.
    void postWithdrawn();

    // The minimize / restore entry points and the minimize render hooks are all registered.
    bool minimizeAvailable();

    // The appmenu global is advertised and hl.plugin.grassfield.appmenu is registered.
    bool appmenuAvailable();

    // The overview render hooks are registered and hl.plugin.grassfield.overview is registered.
    bool overviewAvailable();

    // The Stages listeners, hl.plugin.grassfield.stages and hl.plugin.grassfield.config are registered (whatever the flag).
    bool stagesAvailable();

    // hl.plugin.grassfield.cursor_refresh is registered and the refresh is ready (Hyprland's renderer exists).
    bool cursorRefreshAvailable();

    // hl.plugin.grassfield.overview_focus is registered and its listeners are (overview-focus).
    bool overviewFocusAvailable();

    // hl.plugin.grassfield.tile and hl.plugin.grassfield.config are registered (window-tiling).
    bool tilingAvailable();

    // Also hl.plugin.grassfield.arrange, `hyprctl grassfield-tiling` and the tiling listeners (tiling-arrange).
    bool tilingArrangeAvailable();

    // Also hl.plugin.grassfield.tile_popover and hl.plugin.grassfield.move_to (tile-hover: the zoom light's popover events).
    bool tileHoverAvailable();

    // Also hl.plugin.grassfield.group_front, with tiling-arrange (tiling-groups: the tile groups, TL29).
    bool tilingGroupsAvailable();

    // Registers the Lua function(s) (hl.plugin.grassfield.*) and the hyprctl command. Returns false if any failed.
    bool registerAll();

    // Removes everything registerAll() added. Safe to call more than once.
    void unregisterAll();

} // namespace gf::ipc
