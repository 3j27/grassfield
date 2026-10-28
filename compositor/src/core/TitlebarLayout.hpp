#pragma once

// Titlebar geometry: button layout, hit-testing, title placement and double-click detection.
// Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/).
// All coordinates are logical pixels, relative to the titlebar's top-left corner.

#include "Theme.hpp"

#include <array>
#include <cstdint>
#include <optional>
#include <vector>

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

    // The zoom light a Grassfield app draws itself (ADR-0015 WindowControls, ui/Grassfield/Ui/WindowActions.js
    // lightGeometry), relative to its surface's top-left: in the 32-pt titlebar row (`titlebarRow`, the "info" role) as
    // the plugin's own titlebar, else in the unified toolbar row (52 pt, the first light's centre at 26, 26).
    Rect appZoomLight(bool titlebarRow);

    // X coordinate of the right edge of the last button.
    double buttonsRightEdge(const Metrics& m = {});

    // What a pointer at (x, y) is over. Buttons are hit inside their circle grown by hitSlop.
    HitTarget hitTest(double x, double y, double barWidth, const Metrics& m = {});

    std::optional<Button> buttonForHit(HitTarget hit);

    // ---- Hover glyphs (macOS: the three glyphs show together while the pointer is over the group of lights) ----

    // The group of lights: the box of the three hit circles (gaps between the lights included).
    Rect buttonGroupRect(const Metrics& m = {});

    // The pointer at (x, y) is over the group of lights of a bar barWidth wide (and on the bar).
    bool overButtonGroup(double x, double y, double barWidth, const Metrics& m = {});

    // Side in device px of the square a glyph is drawn in, for a light buttonPx device px across: about
    // ratio x buttonPx, with the parity of buttonPx so that the glyph is centred on whole pixels. 0 if invalid.
    int glyphSizePx(int buttonPx, double ratio = theme::kGlyphRatio);

    // Coverage mask of a button's glyph (x close, - minimize, + zoom): sizePx x sizePx bytes, row-major, 0..255. Strokes
    // strokePx wide with round caps, inside the square, anti-aliased over one pixel. Empty if sizePx is outside
    // [1, kMaxGlyphPx] or strokePx is not positive. fullScreenArrows (zoom only, Alt held: ADR-0015 P6): the full-screen
    // arrows instead of the +, two filled triangles pointing at the bottom-left and top-right corners, the shape the
    // apps' WindowGlyph.qml draws ("arrows": legs of 0.7 of the box along two edges).
    std::vector<uint8_t> glyphMask(Button button, int sizePx, double strokePx, bool fullScreenArrows = false);

    // The mask as premultiplied 32-bit pixels, bytes B, G, R, A (DRM_FORMAT_ARGB8888 on little-endian).
    std::vector<uint8_t> premultipliedBgra(const std::vector<uint8_t>& mask, const theme::Rgba& color);

    // Colour of a light (macOS): its own colour on the active window, and on any window while the pointer is over the group
    // of lights; the palette's inactive grey otherwise.
    theme::Rgba lightColor(Button button, bool windowActive, bool groupHovered, theme::Appearance appearance = theme::kDefaultAppearance);

    // ---- Content corners under the bar ----
    // Hyprland 0.56.2 rounds all four corners of a window's surface with one radius, so a rounded window shows a curve
    // where its content meets the bar; macOS joins them square. The two squares below the bar's ends, `rounding` wide,
    // are redrawn from the surface's own texture, unrounded. All rectangles share one coordinate space.
    struct CornerPatch {
        bool valid = false;
        Rect left;  // square under the bar's left end
        Rect right; // square under the bar's right end
    };

    // `bar`: the titlebar; `texture`: where the surface's whole texture is drawn (its top-left corner at the surface's
    // origin). Invalid when there is no rounding, the bar is narrower than two squares, or a square is not fully inside
    // the texture (the mapping would be a guess).
    CornerPatch contentCornerPatch(const Rect& bar, double rounding, const Rect& texture);

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

    // Dragging a maximized window un-zooms it under the pointer (macOS): the window gets back its floating
    // size (restoredW x restoredH) and is placed so that the pointer keeps its horizontal fraction of the
    // window and its vertical offset from the surface's top edge (negative on the titlebar, which sits above
    // the surface). `zoomed` is the maximized surface box (layout coordinates), (pressX, pressY) the press
    // point, (pointerX, pointerY) the pointer now. Returns the new surface box.
    Rect unzoomedDragBox(const Rect& zoomed, double restoredW, double restoredH, double pressX, double pressY, double pointerX, double pointerY);

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
