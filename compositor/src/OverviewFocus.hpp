#pragma once

// Overview close focus (feature "overview-focus", owner decision 2026-10-19 batch 5): Hyprland 0.56.2 glue for
// core/OverviewFocus.* on top of the deferred focus shared with Stages (DeferredFocus.*). The shell calls
// hl.plugin.grassfield.overview_focus(json) when it starts closing the Overview, naming what gets the keyboard; the plugin
// waits until Hyprland accepts window focus again (no Exclusive layer surface left, event driven: layer surface commits,
// unmaps and keyboard focus changes, before a key, bounded by kBound), checks the target again then (the session lock, the
// window or Desktop still there and shown) and focuses it through Hyprland's own focus path; a press after the request wins.
// Compositor thread only, nothing blocks. Contract: docs/specs/overview.md "Close focus".

#include "core/OverviewFocus.hpp"

namespace gf::overviewFocus {

    // Registers the listeners. False if anything failed (then overview-focus is not advertised; stop() undoes it).
    bool start();

    // Unload: a waiting request ends with outcome "unavailable" (posted while the event throttle still runs); listeners,
    // the commit watches, the pending event-loop callback and the bound timer removed (their code is in this library).
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // A validated hl.plugin.grassfield.overview_focus(json) request: it replaces a waiting one.
    void request(const gf::overviewfocus::Request& request);

    // A request that failed validation: outcome "invalid" (a waiting request keeps waiting).
    void refuse();

    // Called from the plugin's first pointer button listener, before Hyprland handles the button: a press after the
    // request is the user's (it wins over the named target). Never cancels the event. No-op unless a request waits.
    void beforePointerButton(bool pressed);

} // namespace gf::overviewFocus
