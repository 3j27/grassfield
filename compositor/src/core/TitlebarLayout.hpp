#pragma once

// Titlebar geometry: button layout, hit-testing, title placement and double-click detection.
// Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/).
// All coordinates are logical pixels, relative to the titlebar's top-left corner.

#include "Theme.hpp"

#include <array>
#include <cstdint>
#include <optional>

namespace gf::titlebar {

    enum class Button : uint8_t {
        Close,
        Minimize,
        Zoom,
    };

    // Left-to-right order of the buttons.
    inline constexpr std::array<Button, 3> kButtonOrder = {Button::Close, Button::Minimize, Button::Zoom};

    enum class HitTarget : uint8_t {
        None,     // outside the titlebar
        Close,
        Minimize,
        Zoom,
        DragArea, // anywhere else on the titlebar: drag to move, double-click to zoom
    };

    struct Rect {
        double x = 0;
        double y = 0;
        double w = 0;
        double h = 0;

        bool   contains(double px, double py) const {
            return px >= x && px < x + w && py >= y && py < y + h;
        }

        bool operator==(const Rect&) const = default;
    };

    struct Metrics {
        double height       = theme::kTitlebarHeight;
        double diameter     = theme::kButtonDiameter;
        double spacing      = theme::kButtonSpacing;
        double insetLeft    = theme::kButtonInsetLeft;
        double hitSlop      = theme::kButtonHitSlop;
        double titlePadding = theme::kTitlePadding;
    };

    // Bounding square of a button (the drawn circle is inscribed in it).
    Rect buttonRect(Button button, const Metrics& m = {});

    // X coordinate of the right edge of the last button.
    double buttonsRightEdge(const Metrics& m = {});

    // What a pointer at (x, y) is over. Buttons are hit inside their circle grown by hitSlop.
    HitTarget hitTest(double x, double y, double barWidth, const Metrics& m = {});

    std::optional<Button> buttonForHit(HitTarget hit);

    struct TitlePlacement {
        bool   visible  = false;
        double x        = 0; // left edge of the text
        double maxWidth = 0; // width available to the text (longer titles must be clipped/ellipsized)
    };

    // Width available to a centered title that never overlaps the buttons.
    double maxTitleWidth(double barWidth, const Metrics& m = {});

    // Centers a title of width textWidth on the bar; keeps it clear of the buttons.
    TitlePlacement placeTitle(double barWidth, double textWidth, const Metrics& m = {});

    // True once a press on the drag area has travelled far enough (Euclidean distance strictly greater than
    // threshold) to move the window; until then it is a click.
    bool exceedsDragThreshold(double dx, double dy, double threshold = theme::kDragThreshold);

    // Detects a double-click from consecutive presses on the drag area.
    class CClickTracker {
      public:
        explicit CClickTracker(uint32_t thresholdMs = theme::kDoubleClickMs, double slop = theme::kDoubleClickSlop);

        // Registers a press; returns true when it completes a double-click.
        // A completed double-click is consumed: a third press starts a new sequence.
        bool press(uint32_t timeMs, double x, double y);
        void reset();

      private:
        uint32_t m_thresholdMs;
        double   m_slop;
        bool     m_hasPrevious = false;
        uint32_t m_prevTimeMs  = 0;
        double   m_prevX       = 0;
        double   m_prevY       = 0;
    };

} // namespace gf::titlebar
