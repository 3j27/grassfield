#pragma once

// Windows that draw their own chrome (ADR-0015; docs/specs/compositor.md "Plugin work item: client chrome"): Hyprland glue.
// The rules are pure, in core/ClientChrome.*.
//   P1  isClientChrome(): the window carries the Hyprland tag grassfield-client-chrome (session rule gf-client-chrome);
//       the titlebar is not shown for it (CGrassfieldTitlebar::shouldShow), re-evaluated on window.updateRules.
//   P3  band(): no titlebar band above such a window (Stages thumbnails, the tiling and restore frames).
//   P4  the app's xdg_toplevel.move on a zoomed window: the window leaves the zoom at its floating size, under the pointer
//       at the same place in its toolbar row, then follows the pointer (Hyprland's interactive move, restarted there).
//   P5  the app's xdg_toplevel.set_minimized: the minimize path of the titlebar's own light (minimize-request, FR6).
//   P8  such a window is told the minimize capability (xdg_toplevel.wm_capabilities, then a configure): GTK4 greys a
//       minimize button the compositor does not offer, and Hyprland offers only fullscreen and maximize; its unmap and
//       the unload tell it Hyprland's own capabilities again; a window that cannot be told (older than v5) is not
//       walked again (GF-056 part 2).
// Per-window listeners on each xdg toplevel (stateChanged, requestMove), added when a window opens, dropped when it
// closes or at unload; each handler checks the tag when it runs (the tag may come or go with a rule change).

#include <hyprland/src/desktop/DesktopTypes.hpp>

namespace gf::chrome {

    // P1: the window carries the client-chrome tag. False for a null window or one without rules.
    bool isClientChrome(const PHLWINDOW& w);

    // P3: the band the plugin reserves above `w`'s surface (core band(isClientChrome(w))).
    double bandOf(const PHLWINDOW& w);

    // Listeners on every mapped xdg window and on window open / close. False if any failed (then client-chrome is not
    // advertised: the titlebar still steps aside, which needs no listener, but the bridges P4 and P5 would be missing).
    bool start();

    // Unload: removes every listener (their callbacks are code of this library).
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // Global pointer button listener, before Hyprland handles the button (main.cpp): a press on a zoomed client-chrome
    // window is recorded (P4); a release forgets it.
    void beforePointerButton(bool pressed);

} // namespace gf::chrome
