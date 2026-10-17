#pragma once

// Grassfield titlebar constants (S2 / M1 decorations).
//
// Single source of the plugin's visual values so they can be replaced by design tokens
// (ui/tokens/tokens.json, ADR-0003) without touching drawing code. Grassfield's own values,
// not Apple's. No Hyprland includes: this header is used by the unit tests.

#include <cstdint>

namespace gf::theme {

    // Straight (non-premultiplied) RGBA, each channel in [0, 1].
    struct Rgba {
        float r = 0.F;
        float g = 0.F;
        float b = 0.F;
        float a = 1.F;
    };

    constexpr Rgba fromRgb8(uint8_t r, uint8_t g, uint8_t b, float a = 1.F) {
        return Rgba{static_cast<float>(r) / 255.F, static_cast<float>(g) / 255.F, static_cast<float>(b) / 255.F, a};
    }

    constexpr Rgba fromHex(uint32_t rgb, float a = 1.F) {
        return fromRgb8(static_cast<uint8_t>((rgb >> 16) & 0xFF), static_cast<uint8_t>((rgb >> 8) & 0xFF), static_cast<uint8_t>(rgb & 0xFF), a);
    }

    // ---- Metrics (logical pixels at scale 1) ----
    inline constexpr double kTitlebarHeight  = 28.0;
    inline constexpr double kButtonDiameter  = 12.0;
    inline constexpr double kButtonSpacing   = 8.0;  // gap between adjacent button edges
    inline constexpr double kButtonInsetLeft = 12.0; // titlebar left edge -> first button edge
    inline constexpr double kButtonHitSlop   = 2.0;  // extra hit radius around each button
    inline constexpr double kTitlePadding    = 8.0;  // min gap between the buttons and the title

    // ---- Title text ----
    inline constexpr int         kTitleFontSizePt = 13;
    inline constexpr int         kTitleFontWeight = 600; // semibold
    inline constexpr const char* kTitleFontFamily = "";  // "" = Hyprland's default font family

    // ---- Interaction ----
    inline constexpr uint32_t kDoubleClickMs   = 400; // max delay between the two presses
    inline constexpr double   kDoubleClickSlop = 4.0; // max pointer travel between the two presses
    // Pointer travel from the press point before a titlebar press moves the window. Below it the press is
    // a click: the window geometry is never touched (a maximized window's box must not become its
    // floating geometry, which the zoom toggle restores).
    inline constexpr double kDragThreshold = 4.0;

    // ---- Colors ----
    inline constexpr Rgba kCloseColor    = fromHex(0xE5534B);
    inline constexpr Rgba kMinimizeColor = fromHex(0xD9A93B);
    inline constexpr Rgba kZoomColor     = fromHex(0x4FA64F);

    enum class Appearance : uint8_t {
        Dark,
        Light,
    };

    struct TitlebarPalette {
        Rgba background;
        Rgba title;
    };

    constexpr TitlebarPalette titlebarPalette(Appearance appearance) {
        switch (appearance) {
            case Appearance::Light: return TitlebarPalette{.background = fromRgb8(236, 236, 238), .title = fromRgb8(40, 40, 44, 0.85F)};
            case Appearance::Dark:
            default: return TitlebarPalette{.background = fromRgb8(40, 40, 44), .title = fromRgb8(236, 236, 238, 0.85F)};
        }
    }

    // S2: fixed appearance. Switching follows the shell's appearance setting later (tokens + IPC).
    inline constexpr Appearance kDefaultAppearance = Appearance::Dark;

} // namespace gf::theme
