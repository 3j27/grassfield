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
