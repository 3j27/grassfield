#pragma once

// The dark appearance's light inner rim (ADR-0024 note 2026-11-03, "The dark inner rim, drawn by the plugin"): macOS 27
// draws 1 pt of white at 0.10 (0.08 on a window that is not key) just inside every window's edge, over its content and
// continuous round the corner arcs. Hyprland 0.56.2 cannot (its inner glow has no window rule and is not drawn along the
// rounded corners), so the plugin draws it: after the window's surface (a decoration of Hyprland's OVER layer, under the
// window's popups), as one ring of Hyprland's own border shader inside the window's frame, which is the surface and, on a
// third-party window, the plugin's titlebar above it. No offscreen pass: Hyprland draws a border only where its ring and
// its corners are. Pure logic, no Hyprland includes: unit-tested in tests/WindowRimTest.cpp.

#include "Theme.hpp"

#include <optional>

namespace gf::rim {

    // A box: logical (layout) pixels for frameOf(), device pixels on the output for everything else.
    struct Box {
        double x = 0;
        double y = 0;
        double w = 0;
        double h = 0;
    };

    // The window's frame (logical): its surface, and above it the plugin's titlebar while that is shown (`bar`, its height;
    // 0 for client chrome, a window without a bar or a Split View member's). The rim runs along the frame, so it sits along
    // the TOP of a third-party window's bar, never under the bar's hairline.
    Box frameOf(const Box& surface, double bar);

    // The frame on the output as Hyprland 0.56.2 places a window's decorations: the logical box scaled, then hyprutils'
    // CBox::round() (read from libhyprutils.so.13: x and y rounded, then the width and the height to the rounded right and
    // bottom edges, round(x + w - round(x))). Hyprland's border is placed the same way, so the rim's outer edge is the
    // contact pixel's inner edge, on whole device pixels at any scale.
    Box snap(const Box& logical, double scale);

    // Whole device pixels of a line of `pt` points at `scale`, rounded as Hyprland 0.56.2's renderBorder rounds a border's
    // size ((int) roundf(pt * scale), read from the binary): 1 at 1 and 1.25, 2 at 1.5 and 2. 0 for pt <= 0.
    int widthPx(int pt, float scale);

    // The white per device pixel that keeps `perPt` per point over the snapped width (macOS 27's light per point, whatever
    // the rounding of the width): perPt * pt * scale / widthPx, within [0, 1]. 0.125 for 0.10 at 1.25, where one device pixel
    // is 0.8 pt; 0.10 at 1 and 2; 0.075 at 1.5 (two device pixels, 1.33 pt). 0 when there is no width.
    double pixelOpacity(double perPt, int pt, float scale);

    // One ring of Hyprland's border shader (CBorderPassElement, border.glsl): it draws `borderPt` points (`widthPx` device
    // pixels, rounded as widthPx()) OUTSIDE `inner`. Hyprland 0.56.2's renderBorder (read from the binary) grows `inner` by
    // that width on every side, takes `round` + width as the radius of the ring's corner centres and `outerRound` as its
    // outer arc's, so the inner arc has radius `round` and the outer one `outerRound`, both at the window's rounding power.
    // The rim is the frame's first widthPx device pixels: `inner` is the frame less widthPx on every side, `outerRound` the
    // frame's own corner radius (the outer arc is the surface's rounded corner, so the rim is continuous round it) and
    // `round` the concentric inner arc, outerRound - widthPx (at least 1 on a rounded frame: 0 turns the rounding off).
    struct Ring {
        Box  inner;
        int  borderPt   = 0;
        int  widthPx    = 0;
        int  round      = 0;
        int  outerRound = 0;
        bool valid      = false; // false: nothing to draw (no width, or a frame too small for the ring)
    };

    // The ring inside `frame` (device pixels, snap()), its corners of `roundingPx` device pixels (the window's rounding times
    // the scale, as Hyprland rounds the surface's corners), `pt` points wide at `scale`.
    Ring ring(const Box& frame, int roundingPx, int pt, float scale);

    // Whether a window gets the rim. The dark appearance only (macOS 27's light appearance has none: at most white 0.07 in
    // one device pixel, not drawn); never in full screen, where a window has no edge (macOS; Hyprland draws no decoration
    // there); only on a window whose edges Hyprland draws (not an X11 window that wants no border, not decorate = false).
    // Hyprland's maximized mode and the plugin's Fill keep it: they are ordinary windows with an edge (macOS's zoomed
    // window), and the rim never leaves the frame, so a filled window's margins stay the wallpaper.
    // The appearance counts only once the shell has said it (config "appearance"): a plugin loaded or reloaded in a light
    // session never flashes a dark rim before the shell's push (gate C2), and a plugin without the shell draws none.
    struct WindowState {
        theme::Appearance appearance      = theme::kDefaultAppearance;
        bool              appearanceKnown = true;  // the shell has pushed the appearance since the plugin loaded
        bool              active          = false; // the key window: 0.10 per point, else 0.08
        bool              fullscreen      = false; // Hyprland's full screen
        bool              edged           = true;  // Hyprland draws its border and shadow on it
    };

    // The rim's white per point (tokens window.rimDark{Active,Inactive}Opacity), or nothing when the window gets none.
    std::optional<double> opacityPerPt(const WindowState& state);

} // namespace gf::rim
