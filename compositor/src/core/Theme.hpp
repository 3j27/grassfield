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
    // macOS 26 titlebar-only window (docs/testing/f1-reference-gaps.md, "Window chrome"): 14-pt lights on a 23-pt
    // pitch, the first centre (15.6, 15.6) +-1 from the window's top-left corner, a titlebar of about 32 pt.
    // Plain literals: tests/compositor/titlebar_geometry.sh reads the first four from this file.
    // Overview and Stages draw the same band: ui/tokens/tokens.json overview.windowTitlebarHeight follows
    // kTitlebarHeight, and core/Stages.hpp uses it directly.
    inline constexpr double kTitlebarHeight  = 32.0;
    inline constexpr double kButtonDiameter  = 14.0;
    inline constexpr double kButtonSpacing   = 9.0; // gap between adjacent button edges (pitch 23)
    inline constexpr double kButtonInsetLeft = 9.0; // titlebar left edge -> first button edge: first centre at (16, 16)
    // Extra hit radius around each button; it scales with the diameter (2 at the former 12) and leaves the gaps
    // between the buttons to the drag area (centres 23 apart, hit radius 7 + 2.33).
    inline constexpr double kButtonHitSlop = kButtonDiameter / 6.0;
    inline constexpr double kTitlePadding  = 8.0; // min gap between the buttons and the title

    // ---- Hover glyphs: x (close), - (minimize), + (zoom) on all three lights while the pointer is over them ----
    // Measured on the 2x reference (14-pt lights): glyph extents 0.50-0.57 of the diameter, strokes about 1.6 pt, the
    // glyph about half as bright as its light.
    inline constexpr double kGlyphRatio  = 0.55; // glyph box side / button diameter
    inline constexpr double kGlyphStroke = 0.12; // stroke width / button diameter
    inline constexpr int    kMaxGlyphPx  = 256;  // larger glyph textures are refused (device px)

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
    inline constexpr Rgba kGlyphColor    = Rgba{.r = 0.F, .g = 0.F, .b = 0.F, .a = 0.5F}; // darkens the light under it

    enum class Appearance : uint8_t {
        Dark,
        Light,
    };

    struct TitlebarPalette {
        Rgba background;
        Rgba title;
        // The three lights of an inactive window (macOS: grey; coloured again while the pointer is over them). Own values:
        // the light-appearance reference samples about #D4D4D4 on a white bar; the dark value keeps the same small step
        // above its bar.
        Rgba inactiveLight;
    };

    constexpr TitlebarPalette titlebarPalette(Appearance appearance) {
        switch (appearance) {
            case Appearance::Light:
                return TitlebarPalette{.background = fromRgb8(236, 236, 238), .title = fromRgb8(40, 40, 44, 0.85F), .inactiveLight = fromHex(0xD1D1D3)};
            case Appearance::Dark:
            default: return TitlebarPalette{.background = fromRgb8(40, 40, 44), .title = fromRgb8(236, 236, 238, 0.85F), .inactiveLight = fromHex(0x5A5A5E)};
        }
    }

    // S2: fixed appearance. Switching follows the shell's appearance setting later (tokens + IPC).
    inline constexpr Appearance kDefaultAppearance = Appearance::Dark;

} // namespace gf::theme
