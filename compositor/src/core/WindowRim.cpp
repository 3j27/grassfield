#include "WindowRim.hpp"

#include <algorithm>
#include <cmath>

namespace gf::rim {

    Box frameOf(const Box& surface, double bar) {
        const double band = std::max(0.0, bar);
        return Box{.x = surface.x, .y = surface.y - band, .w = surface.w, .h = surface.h + band};
    }

    Box snap(const Box& logical, double scale) {
        const double x  = logical.x * scale;
        const double y  = logical.y * scale;
        const double w  = logical.w * scale;
        const double h  = logical.h * scale;
        const double rx = std::round(x);
        const double ry = std::round(y);
        return Box{.x = rx, .y = ry, .w = std::round(x + w - rx), .h = std::round(y + h - ry)};
    }

    int widthPx(int pt, float scale) {
        if (pt <= 0 || !(scale > 0.F))
            return 0;
        return static_cast<int>(std::roundf(static_cast<float>(pt) * scale));
    }

    double pixelOpacity(double perPt, int pt, float scale) {
        const int px = widthPx(pt, scale);
        if (px <= 0 || !(perPt > 0.0))
            return 0.0;
        return std::clamp(perPt * pt * static_cast<double>(scale) / px, 0.0, 1.0);
    }

    Ring ring(const Box& frame, int roundingPx, int pt, float scale) {
        Ring      r;
        const int t = widthPx(pt, scale);
        // Hyprland's renderBorder asserts on an empty box: a frame that is not finite or cannot hold the ring draws nothing.
        if (!std::isfinite(frame.x) || !std::isfinite(frame.y) || !std::isfinite(frame.w) || !std::isfinite(frame.h))
            return r;
        if (t <= 0 || frame.w <= 2.0 * t || frame.h <= 2.0 * t)
            return r;
        r.inner      = Box{.x = frame.x + t, .y = frame.y + t, .w = frame.w - (2.0 * t), .h = frame.h - (2.0 * t)};
        r.borderPt   = pt;
        r.widthPx    = t;
        r.outerRound = std::max(0, roundingPx);
        r.round      = r.outerRound > 0 ? std::max(1, r.outerRound - t) : 0;
        r.valid      = true;
        return r;
    }

    std::optional<double> opacityPerPt(const WindowState& state) {
        if (!state.appearanceKnown || state.appearance != theme::Appearance::Dark || state.fullscreen || !state.edged)
            return std::nullopt;
        return state.active ? theme::tokens::kWindowRimDarkActiveOpacity : theme::tokens::kWindowRimDarkInactiveOpacity;
    }

} // namespace gf::rim
