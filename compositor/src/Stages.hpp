#pragma once

// Stages (Grassfield's stage manager, M5, behind the feature flag config stagesEnabled): Hyprland 0.56.2 glue for
// core/Stages.* (model, validation, geometry). The windows of inactive stages stay mapped on their workspace, at their
// real places, live: a Render::IWindowTransformer draws each one into the shell's strip tile, and a plugin-owned input
// block reason (CWindow::setInputBlocked) keeps pointer and keyboard away from their real places. Nothing is ever moved,
// resized or configured, so turning Stages off or unloading the plugin only detaches transformers and lifts the blocks.
// Compositor thread only, nothing blocks. Spec: docs/specs/stages.md; decision: docs/decisions/ADR-0013-stages.md.

#include "core/Stages.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>

namespace gf::stager {

    // Registers the listeners (nothing is managed until the flag is on and the shell sends op "on"). False if anything
    // failed (then neither stages-available nor stages is advertised; stop() undoes what was registered).
    bool start();

    // Unload: every window back to normal rendering with its input unblocked, pending callbacks and the watchdog removed,
    // {"on":false,"reason":"unavailable"} posted while the event throttle still runs.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // Called from the plugin's first pointer button listener, before anything else of the plugin and before Hyprland
    // delivers the button: a pointer focus left on a window Stages blocks (no motion since the block) is refreshed to the
    // surface under the cursor, or the event reaches no surface. Never cancels the event. No-op unless ready().
    void beforePointerButton(bool pressed);

    // The feature flag (config stagesEnabled, off by default). Turning it off ends Stages at once (no animation).
    bool enabled();
    void setEnabled(bool on);

    // A validated hl.plugin.grassfield.stages(json) request.
    void request(const gf::stages::Request& request);

    // A refused request: posts the current state with `reason` (nothing changes).
    void refuse(gf::stages::Reason reason);

} // namespace gf::stager
