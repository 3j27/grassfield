#include "TopClamp.hpp"

#include <algorithm>
#include <cmath>

namespace gf::topclamp {

    namespace {
        bool contains(const Rect& r, double x, double y) {
            return r.w > 0 && r.h > 0 && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h;
        }

        // The highest surface top whose frame still starts below the menu bar (whole pixels, rounded up: never under it).
        double lowestAllowedTop(double band, const Output& output) {
            return std::ceil(output.menuBarBottom + band);
        }
    } // namespace

    std::optional<size_t> outputFor(double pointerX, double pointerY, const Rect& frame, std::span<const Output> outputs) {
        for (size_t i = 0; i < outputs.size(); ++i) {
            if (contains(outputs[i].box, pointerX, pointerY))
                return i;
        }
        const double topCentreX = frame.x + (frame.w / 2.0);
        for (size_t i = 0; i < outputs.size(); ++i) {
            if (contains(outputs[i].box, topCentreX, frame.y))
                return i;
        }
        return std::nullopt;
    }

    Rect afterMove(const Rect& surface, double band, const Output& output) {
        const double top = lowestAllowedTop(band, output);
        if (surface.y >= top - 0.5)
            return surface;
        Rect moved = surface;
        moved.y    = top;
        return moved;
    }

    Rect afterResize(const Rect& surface, double band, const Output& output) {
        const double top = lowestAllowedTop(band, output);
        if (surface.y >= top - 0.5)
            return surface;
        const double bottom = surface.y + surface.h;
        Rect trimmed        = surface;
        trimmed.y           = top;
        trimmed.h           = std::max(1.0, std::round(bottom - top));
        return trimmed;
    }

    bool changed(const Rect& a, const Rect& b) {
        return std::abs(a.x - b.x) > 0.5 || std::abs(a.y - b.y) > 0.5 || std::abs(a.w - b.w) > 0.5 || std::abs(a.h - b.h) > 0.5;
    }

} // namespace gf::topclamp
