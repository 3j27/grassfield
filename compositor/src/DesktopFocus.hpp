#pragma once

// Desktop focus policy (feature "desktop-focus"): Hyprland glue for core/DesktopFocus.* (the decision logic). Observes
// pointer button presses on the event bus (never cancels them: cancelled button events break Hyprland's held-button
// state, FR13), the commits of the shell's desktop layer surfaces and the keyboard, window and workspace focus events
// (which drop a waiting desktop grant); moves the keyboard with Desktop::focusState(), through Hyprland's own focus rules
// only. Compositor thread only, nothing blocks. Contract: docs/specs/desktop.md "Compositor focus policy".

namespace gf::desktopFocus {

    // Registers the button and layer listeners and attaches to the desktop surfaces already mapped. False if anything
    // failed (then the feature is not advertised; stop() undoes what was registered).
    bool start();

    // Unload: listeners and any pending grant removed. The keyboard stays where it is.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

} // namespace gf::desktopFocus
