#pragma once

// Overview v2: live window transforms for Mission Control (master-prompt §5.6 feature 4, docs/specs/overview.md
// "v2"). Hyprland glue; request parsing and animation math live in core/Overview.*.
//
// Mechanism (Hyprland 0.56.2, docs/specs/overview.md "v2 spike"): each transformed window gets a
// Render::IWindowTransformer (CWindow::m_transformers, the extension point Hyprland uses for its motion blur).
// Hyprland then renders the window's main pass (surfaces, subsurfaces, decorations) into a monitor-sized work buffer
// and hands it to transform(), which draws that buffer scaled and moved so the window's surface box lands on its
// layout rect, into a second work buffer that Hyprland composites in the window's place in the stack. The client is
// never resized or configured; its buffers are sampled live every frame. Hyprland's transformed-window pass element
// disables pass simplification, so the composite covers the whole frame damage; the plugin adds damage for the
// layout boxes (each animation tick, and in every frame the monitor has damage while the overview is open).

#include "core/Overview.hpp"

namespace gf::overviewer {

    // Registers the render, window, workspace, layer and monitor listeners. False if any failed (then the overview
    // feature is not advertised).
    bool start();

    // Unload: every window back to normal rendering at once (transformers removed before dlclose), a closed event
    // with reason "unavailable" if an overview was open, listeners and the watchdog timer removed.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // Entry point of hl.plugin.grassfield.overview after parsing: open or retarget (on) or close (off).
    void request(const gf::overview::Request& request);

    // A request that failed parsing: nothing changes; the current state is posted with reason "invalid".
    void refuse(gf::overview::Reason reason);

} // namespace gf::overviewer
