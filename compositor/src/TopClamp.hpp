#pragma once

// A window's titlebar never goes under the menu bar (macOS): Hyprland 0.56.2 glue; the rule is in core/TopClamp.*.
// Floating windows only (not full screen or zoomed), every output (its own menu bar strip: the output's top reserved
// area), with the plugin's titlebar or with the app's own (client chrome, ADR-0015).
//
// Two ways a window is dragged:
//   - by the plugin's titlebar: the plugin moves the window itself (Titlebar.cpp updateMove), which asks heldMove() at
//     every step, so the window stops at the menu bar while the pointer goes on, and follows it again on the way down;
//   - by Hyprland's own interactive move or resize (an app's xdg_toplevel.move or resize, as Chromium's tab strip asks,
//     or a mouse binding): Hyprland has no hook during it, so the release of the button that ends it (main.cpp, before
//     Hyprland handles it) schedules one callback after Hyprland ended the drag, which moves the window down (a move) or
//     stops its top edge (a resize that moved it) at the menu bar. Hyprland's drag itself is left alone.
// The menu bar is the one of the output the frame's top edge is on (core/TopClamp outputFor), not the output under the
// pointer: a SUPER+drag or a resize grips the window anywhere. Keyboard moves and resizes never reach the clamp.
// Without the plugin nothing holds the top: a window can still go under the menu bar (Hyprland's own behaviour).
// Compositor thread only, nothing blocks.

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprutils/math/Box.hpp>
#include <hyprutils/math/Vector2D.hpp>

namespace gf::topClamp {

    using Hyprutils::Math::CBox;
    using Hyprutils::Math::Vector2D;

    // Enables the clamp (always succeeds: the plugin's own move and the button listener are the plugin's).
    bool start();

    // Unload: drops the pending clamp and its scheduled callback (its code is in this library). Safe more than once.
    void stop();

    // The surface box `surface` of the floating window `w`, moved by the plugin's titlebar with the pointer at `pointer`,
    // held below the menu bar (core/TopClamp heldMove); `surface` unchanged otherwise (or when not running).
    CBox heldMove(const PHLWINDOW& w, const CBox& surface, const Vector2D& pointer);

    // From the plugin's pointer motion listener: the first motion of one of Hyprland's moves or resizes records the
    // window's box (a resize that did not move the top edge is never clamped); a motion outside a drag forgets it.
    void beforePointerMotion();

    // From the plugin's first pointer button listener, before Hyprland handles the button: a press outside a drag
    // forgets the recorded box; a release that ends one of Hyprland's own moves or resizes schedules the clamp after
    // Hyprland ended it.
    void beforePointerButton(bool pressed);

} // namespace gf::topClamp
