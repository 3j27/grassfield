#pragma once

// Window tiling by dragging (macOS 15+ model, docs/specs/compositor.md FR47-FR50): a window dragged by its titlebar so
// that the pointer touches a free left or right edge of an output fills that half; near a corner of that edge, that
// quarter; the pointer on the menu bar fills the free area. A translucent preview shows the place before the release;
// dragging a tiled window away gives it back its size from before. The same places are offered by the Window menu
// (Move & Resize) through hl.plugin.grassfield.tile(address, place).
// Pure logic, no Hyprland includes: unit-tested in tests/TilingTest.cpp.

#include <cstdint>
#include <optional>
#include <string_view>

namespace gf::tiling {

    // Box in global logical (layout) coordinates.
    struct Rect {
        double x = 0;
        double y = 0;
        double w = 0;
        double h = 0;
    };

    enum class Place : uint8_t {
        Left,
        Right,
        Top,
        Bottom,
        TopLeft,
        TopRight,
        BottomLeft,
        BottomRight,
        Fill,
        Center,
    };

    // Drag geometry. The pointer is on an edge when it is within kEdge px of it (the pointer stops at an outer edge);
    // on a corner of a side edge when it is also within kCorner px of the output's top or bottom.
    inline constexpr double kEdge   = 4.0;
    inline constexpr double kCorner = 96.0;
    // Gap around and between tiled windows when margins are on (macOS "Tiled windows have margins", on by default).
    inline constexpr double kMargin = 8.0;
    // Centre: the window keeps its size, at most this fraction of the free area.
    inline constexpr double kCenterMaxFraction = 0.9;

    struct DragOptions {
        bool edges   = true; // "Drag windows to screen edges to tile"
        bool menuBar = true; // "Drag windows to menu bar to fill screen"
    };

    // The output the pointer is on: its full box, the bottom of the menu bar strip (the output's top reserved area), and
    // whether its left / right edges are free (no other output there: a shared edge is a way to the next output).
    struct Output {
        Rect   box;
        double menuBarBottom = 0;
        bool   leftFree      = true;
        bool   rightFree     = true;
    };

    // The place a drag would tile into with the pointer at (x, y), or none.
    std::optional<Place> placeForPointer(double x, double y, const Output& output, const DragOptions& options);

    // The window's surface box (its titlebar sits `titlebar` px above it) for `place` in the free area `area` (the output
    // minus the menu bar and the Dock). Halves and quarters split the area; Fill takes all of it; Center keeps `current`'s
    // size (at most kCenterMaxFraction of the area) in the middle. With margins, kMargin around and between the windows.
    // Sizes are whole pixels; never smaller than 1x1.
    Rect surfaceFor(Place place, const Rect& area, double titlebar, bool margins, const Rect& current);

    // The frame (titlebar included) of a surface box: what the preview draws.
    Rect frameOf(const Rect& surface, double titlebar);

    // "left", "right", "top", "bottom", "top-left", "top-right", "bottom-left", "bottom-right", "fill", "center".
    std::optional<Place> parsePlace(std::string_view name);
    std::string_view    nameOf(Place place);

    // hl.plugin.grassfield.config keys (values "true" | "false").
    inline constexpr std::string_view kConfigEdges   = "tilingEdges";
    inline constexpr std::string_view kConfigMenuBar = "tilingMenuBar";
    inline constexpr std::string_view kConfigMargins = "tilingMargins";
    std::optional<bool> parseBool(std::string_view value);

} // namespace gf::tiling
