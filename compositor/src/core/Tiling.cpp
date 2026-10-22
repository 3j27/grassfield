#include "Tiling.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>

namespace gf::tiling {

    std::optional<Place> placeForPointer(double x, double y, const Output& output, const DragOptions& options) {
        const Rect& o = output.box;
        if (o.w <= 0 || o.h <= 0 || x < o.x || x >= o.x + o.w || y < o.y || y >= o.y + o.h)
            return std::nullopt;
        if (options.edges) {
            const bool left  = output.leftFree && x <= o.x + kEdge;
            const bool right = output.rightFree && x >= o.x + o.w - 1 - kEdge;
            if (left || right) {
                const bool top    = y <= o.y + kCorner;
                const bool bottom = y >= o.y + o.h - 1 - kCorner;
                if (top)
                    return left ? Place::TopLeft : Place::TopRight;
                if (bottom)
                    return left ? Place::BottomLeft : Place::BottomRight;
                return left ? Place::Left : Place::Right;
            }
        }
        // The menu bar: the pointer stops at the output's top edge; the strip is the output's top reserved area.
        if (options.menuBar && y < std::max(o.y + kEdge, output.menuBarBottom))
            return Place::Fill;
        return std::nullopt;
    }

    Rect surfaceFor(Place place, const Rect& area, double titlebar, bool margins, const Rect& current) {
        const double m = margins ? kMargin : 0.0;
        // The frame (titlebar included) in the area, then the surface below its titlebar.
        Rect frame{area.x + m, area.y + m, area.w - 2 * m, area.h - 2 * m};
        const double halfW = (area.w - 3 * m) / 2;
        const double halfH = (area.h - 3 * m) / 2;
        const double rightX  = area.x + 2 * m + halfW;
        const double bottomY = area.y + 2 * m + halfH;
        switch (place) {
            case Place::Fill: break;
            case Place::Left: frame.w = halfW; break;
            case Place::Right: frame = {rightX, frame.y, halfW, frame.h}; break;
            case Place::Top: frame.h = halfH; break;
            case Place::Bottom: frame = {frame.x, bottomY, frame.w, halfH}; break;
            case Place::TopLeft: frame = {frame.x, frame.y, halfW, halfH}; break;
            case Place::TopRight: frame = {rightX, frame.y, halfW, halfH}; break;
            case Place::BottomLeft: frame = {frame.x, bottomY, halfW, halfH}; break;
            case Place::BottomRight: frame = {rightX, bottomY, halfW, halfH}; break;
            case Place::Center: {
                const double w = std::min(current.w, area.w * kCenterMaxFraction);
                const double h = std::min(current.h + titlebar, area.h * kCenterMaxFraction);
                frame = {area.x + (area.w - w) / 2, area.y + (area.h - h) / 2, w, h};
                break;
            }
        }
        Rect surface{std::round(frame.x), std::round(frame.y + titlebar), std::floor(frame.w), std::floor(frame.h - titlebar)};
        surface.w = std::max(1.0, surface.w);
        surface.h = std::max(1.0, surface.h);
        return surface;
    }

    Rect frameOf(const Rect& surface, double titlebar) {
        return Rect{surface.x, surface.y - titlebar, surface.w, surface.h + titlebar};
    }

    namespace {
        constexpr std::array<std::pair<Place, std::string_view>, 10> kNames{{
            {Place::Left, "left"},
            {Place::Right, "right"},
            {Place::Top, "top"},
            {Place::Bottom, "bottom"},
            {Place::TopLeft, "top-left"},
            {Place::TopRight, "top-right"},
            {Place::BottomLeft, "bottom-left"},
            {Place::BottomRight, "bottom-right"},
            {Place::Fill, "fill"},
            {Place::Center, "center"},
        }};
    }

    std::optional<Place> parsePlace(std::string_view name) {
        for (const auto& [place, text] : kNames) {
            if (text == name)
                return place;
        }
        return std::nullopt;
    }

    std::string_view nameOf(Place place) {
        for (const auto& [p, text] : kNames) {
            if (p == place)
                return text;
        }
        return "";
    }

    std::optional<bool> parseBool(std::string_view value) {
        if (value == "true")
            return true;
        if (value == "false")
            return false;
        return std::nullopt;
    }

} // namespace gf::tiling
