#include "TitlebarLayout.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace gf::titlebar {

    namespace {
        size_t indexOf(Button button) {
            for (size_t i = 0; i < kButtonOrder.size(); ++i) {
                if (kButtonOrder[i] == button)
                    return i;
            }
            return 0;
        }

        HitTarget hitFor(Button button) {
            switch (button) {
                case Button::Close: return HitTarget::Close;
                case Button::Minimize: return HitTarget::Minimize;
                case Button::Zoom: return HitTarget::Zoom;
            }
            return HitTarget::None;
        }
    } // namespace

    Rect buttonRect(Button button, const Metrics& m) {
        const double i = static_cast<double>(indexOf(button));
        return Rect{
            .x = m.insetLeft + (i * (m.diameter + m.spacing)),
            .y = (m.height - m.diameter) / 2.0,
            .w = m.diameter,
            .h = m.diameter,
        };
    }

    double buttonsRightEdge(const Metrics& m) {
        const Rect last = buttonRect(kButtonOrder.back(), m);
        return last.x + last.w;
    }

    HitTarget hitTest(double x, double y, double barWidth, const Metrics& m) {
        if (barWidth <= 0 || x < 0 || y < 0 || x >= barWidth || y >= m.height)
            return HitTarget::None;

        const double radius = (m.diameter / 2.0) + m.hitSlop;
        for (const Button button : kButtonOrder) {
            const Rect   r  = buttonRect(button, m);
            const double cx = r.x + (r.w / 2.0);
            const double cy = r.y + (r.h / 2.0);
            if (std::hypot(x - cx, y - cy) <= radius)
                return hitFor(button);
        }

        return HitTarget::DragArea;
    }

    std::optional<Button> buttonForHit(HitTarget hit) {
        switch (hit) {
            case HitTarget::Close: return Button::Close;
            case HitTarget::Minimize: return Button::Minimize;
            case HitTarget::Zoom: return Button::Zoom;
            case HitTarget::None:
            case HitTarget::DragArea: return std::nullopt;
        }
        return std::nullopt;
    }

    Rect buttonGroupRect(const Metrics& m) {
        const Rect first = buttonRect(kButtonOrder.front(), m);
        const Rect last  = buttonRect(kButtonOrder.back(), m);
        return Rect{
            .x = first.x - m.hitSlop,
            .y = first.y - m.hitSlop,
            .w = (last.x + last.w + m.hitSlop) - (first.x - m.hitSlop),
            .h = first.h + (2.0 * m.hitSlop),
        };
    }

    bool overButtonGroup(double x, double y, double barWidth, const Metrics& m) {
        if (barWidth <= 0 || x < 0 || y < 0 || x >= barWidth || y >= m.height)
            return false;
        return buttonGroupRect(m).contains(x, y);
    }

    int glyphSizePx(int buttonPx, double ratio) {
        if (buttonPx <= 0 || !(ratio > 0) || ratio > 1)
            return 0;
        // Of the two whole sizes around the target, the one with the light's parity: (buttonPx - size) / 2 is whole.
        const int lower = static_cast<int>(std::floor(buttonPx * ratio));
        const int size  = ((buttonPx - lower) % 2 == 0) ? lower : lower + 1;
        return std::clamp(size, 1, std::min(buttonPx, theme::kMaxGlyphPx));
    }

    namespace {
        struct Segment {
            double x0, y0, x1, y1;
        };

        double distanceToSegment(double px, double py, const Segment& s) {
            const double dx  = s.x1 - s.x0;
            const double dy  = s.y1 - s.y0;
            const double len = (dx * dx) + (dy * dy);
            const double t   = len > 0 ? std::clamp((((px - s.x0) * dx) + ((py - s.y0) * dy)) / len, 0.0, 1.0) : 0.0;
            return std::hypot(px - (s.x0 + (t * dx)), py - (s.y0 + (t * dy)));
        }
    } // namespace

    std::vector<uint8_t> glyphMask(Button button, int sizePx, double strokePx) {
        if (sizePx < 1 || sizePx > theme::kMaxGlyphPx || !(strokePx > 0))
            return {};
        const double n    = sizePx;
        const double half = std::min(strokePx, n) / 2.0;
        // Ends inset by half a stroke: the round caps stay inside the square.
        const double lo  = half;
        const double hi  = n - half;
        const double mid = n / 2.0;

        std::array<Segment, 2> segments{};
        size_t                 count = 0;
        switch (button) {
            case Button::Close:
                segments[count++] = Segment{lo, lo, hi, hi};
                segments[count++] = Segment{lo, hi, hi, lo};
                break;
            case Button::Minimize: segments[count++] = Segment{lo, mid, hi, mid}; break;
            case Button::Zoom:
                segments[count++] = Segment{lo, mid, hi, mid};
                segments[count++] = Segment{mid, lo, mid, hi};
                break;
        }

        std::vector<uint8_t> mask(static_cast<size_t>(sizePx) * static_cast<size_t>(sizePx), 0);
        for (int y = 0; y < sizePx; ++y) {
            for (int x = 0; x < sizePx; ++x) {
                double d = n; // farther than any stroke
                for (size_t i = 0; i < count; ++i)
                    d = std::min(d, distanceToSegment(x + 0.5, y + 0.5, segments[i]));
                const double coverage = std::clamp(half - d + 0.5, 0.0, 1.0); // one-pixel ramp across the stroke edge
                mask[(static_cast<size_t>(y) * static_cast<size_t>(sizePx)) + static_cast<size_t>(x)] = static_cast<uint8_t>(std::lround(coverage * 255.0));
            }
        }
        return mask;
    }

    std::vector<uint8_t> premultipliedBgra(const std::vector<uint8_t>& mask, const theme::Rgba& color) {
        const auto channel = [](float v) { return std::clamp(static_cast<double>(v), 0.0, 1.0); };
        const double r = channel(color.r);
        const double g = channel(color.g);
        const double b = channel(color.b);
        const double a = channel(color.a);
        std::vector<uint8_t> out(mask.size() * 4);
        for (size_t i = 0; i < mask.size(); ++i) {
            const double alpha = a * (mask[i] / 255.0);
            out[(i * 4) + 0]   = static_cast<uint8_t>(std::lround(b * alpha * 255.0));
            out[(i * 4) + 1]   = static_cast<uint8_t>(std::lround(g * alpha * 255.0));
            out[(i * 4) + 2]   = static_cast<uint8_t>(std::lround(r * alpha * 255.0));
            out[(i * 4) + 3]   = static_cast<uint8_t>(std::lround(alpha * 255.0));
        }
        return out;
    }

    double maxTitleWidth(double barWidth, const Metrics& m) {
        // Symmetric margins keep the title centered on the whole bar, like the reference layout.
        const double margin = buttonsRightEdge(m) + m.titlePadding;
        return std::max(0.0, barWidth - (2.0 * margin));
    }

    TitlePlacement placeTitle(double barWidth, double textWidth, const Metrics& m) {
        const double available = maxTitleWidth(barWidth, m);
        if (available <= 0 || textWidth <= 0)
            return TitlePlacement{};

        const double width = std::min(textWidth, available);
        return TitlePlacement{
            .visible  = true,
            .x        = (barWidth - width) / 2.0,
            .maxWidth = available,
        };
    }

    CClickTracker::CClickTracker(uint32_t thresholdMs, double slop) : m_thresholdMs(thresholdMs), m_slop(slop) {}

    bool exceedsDragThreshold(double dx, double dy, double threshold) {
        return std::hypot(dx, dy) > threshold;
    }

    Rect unzoomedDragBox(const Rect& zoomed, double restoredW, double restoredH, double pressX, double pressY, double pointerX, double pointerY) {
        const double fraction = zoomed.w > 0 ? std::clamp((pressX - zoomed.x) / zoomed.w, 0.0, 1.0) : 0.5;
        const double offsetY  = std::min(pressY - zoomed.y, std::max(0.0, restoredH)); // never below the restored window
        return Rect{pointerX - (fraction * restoredW), pointerY - offsetY, restoredW, restoredH};
    }

    bool CClickTracker::press(uint32_t timeMs, double x, double y) {
        if (m_hasPrevious) {
            const uint32_t elapsed = timeMs - m_prevTimeMs; // unsigned: correct across 32-bit wrap-around
            if (elapsed <= m_thresholdMs && std::hypot(x - m_prevX, y - m_prevY) <= m_slop) {
                reset();
                return true;
            }
        }

        m_hasPrevious = true;
        m_prevTimeMs  = timeMs;
        m_prevX       = x;
        m_prevY       = y;
        return false;
    }

    void CClickTracker::reset() {
        m_hasPrevious = false;
    }

} // namespace gf::titlebar
