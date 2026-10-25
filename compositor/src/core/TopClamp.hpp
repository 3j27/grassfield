#pragma once

// A window's titlebar never goes under the menu bar (macOS): a drag that would leave the top of a floating window under
// it, or above the output, keeps it just below the menu bar, so the window can always be grabbed again. The titlebar is
// the plugin's (a band above the surface) or the app's own (no band: client chrome, ADR-0015, e.g. Chromium's tab
// strip, which is how the owner lost a window under the menu bar). Only the top is held: a window may still hang off
// the sides or the bottom of an output. Pure logic, no Hyprland includes: unit-tested in tests/TopClampTest.cpp.

#include "Tiling.hpp"

#include <cstddef>
#include <optional>
#include <span>

namespace gf::topclamp {

    using Rect = gf::tiling::Rect; // global logical (layout) coordinates

    // An output: its box and the bottom of its menu bar strip (the output's top reserved area; its top without one).
    struct Output {
        Rect   box;
        double menuBarBottom = 0;
    };

    // The output whose menu bar holds a dragged window: the one under the pointer (the grab point is on the titlebar,
    // so the titlebar crosses to another output with it); else the one under the top centre of the window's frame;
    // none when neither is on an output.
    std::optional<size_t> outputFor(double pointerX, double pointerY, const Rect& frame, std::span<const Output> outputs);

    // A move: the surface box (its titlebar `band` px above it) moved down so that the frame starts at the menu bar's
    // bottom when it would start higher; unchanged otherwise. Whole pixels.
    Rect afterMove(const Rect& surface, double band, const Output& output);

    // A resize: the top edge stops at the menu bar's bottom (the bottom edge stays, the height shrinks, never below
    // 1 px); unchanged when the frame already starts below it. Whole pixels.
    Rect afterResize(const Rect& surface, double band, const Output& output);

    // Whether two boxes differ by more than rounding (half a pixel on any side).
    bool changed(const Rect& a, const Rect& b);

} // namespace gf::topclamp
