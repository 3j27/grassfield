#pragma once

// Grassfield titlebar constants (S2 / M1 decorations).
//
// Single source of the plugin's visual values. The colours of the chrome come from the design tokens
// (ui/tokens/tokens.json groups "titlebar" and "window", generated into ThemeTokens.hpp, ADR-0003); the metrics below are
// still plain literals (tests/compositor/titlebar_geometry.sh reads them) and must equal the "window" tokens the apps
// draw their own lights with (ADR-0015 P7): checked at compile time below and in compositor/tests/ClientChromeTest.cpp.
// Grassfield's own values, not Apple's. No Hyprland includes: this header is used by the unit tests.

#include "ThemeTokens.hpp"

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

    // ---- Colors (design tokens "window": the apps' lights are the same) ----
    inline constexpr Rgba kCloseColor    = fromHex(tokens::kWindowCloseColor);
    inline constexpr Rgba kMinimizeColor = fromHex(tokens::kWindowMinimizeColor);
    inline constexpr Rgba kZoomColor     = fromHex(tokens::kWindowZoomColor);
    inline constexpr Rgba kGlyphColor    = Rgba{.r = 0.F, .g = 0.F, .b = 0.F, .a = static_cast<float>(tokens::kWindowGlyphOpacity)}; // darkens the light under it

    // ADR-0015 P7: the lights the plugin draws are the ones the apps draw (ui/tokens/tokens.json "window"). The metrics stay
    // literals for titlebar_geometry.sh; a token change that leaves them behind does not build.
    static_assert(kButtonDiameter == tokens::kWindowLightDiameter, "kButtonDiameter must equal window.lightDiameter");
    static_assert(kButtonSpacing == tokens::kWindowLightGap, "kButtonSpacing must equal window.lightGap");
    static_assert(kTitlebarHeight == tokens::kWindowTitlebarHeight, "kTitlebarHeight must equal window.titlebarHeight");
    static_assert(kButtonInsetLeft == tokens::kWindowTitlebarLightInset, "kButtonInsetLeft must equal window.titlebarLightInset");
    static_assert(kTitlePadding == tokens::kWindowTitleGap, "kTitlePadding must equal window.titleGap");
    static_assert(kGlyphRatio == tokens::kWindowGlyphRatio, "kGlyphRatio must equal window.glyphRatio");
    static_assert(kGlyphStroke == tokens::kWindowGlyphStroke, "kGlyphStroke must equal window.glyphStroke");
    static_assert(tokens::kWindowInactiveLightDark == tokens::kTitlebarInactiveButtonDark, "window.inactiveLightDark must equal titlebar.inactiveButtonDark");
    static_assert(tokens::kWindowInactiveLightLight == tokens::kTitlebarInactiveButtonLight, "window.inactiveLightLight must equal titlebar.inactiveButtonLight");

    enum class Appearance : uint8_t {
        Dark,
        Light,
    };

    // The colours of the compositor-drawn chrome, per appearance: design tokens (ui/tokens/tokens.json group "titlebar",
    // generated into ThemeTokens.hpp by ui/tools/gen-tokens.py).
    struct TitlebarPalette {
        Rgba background;
        Rgba title;
        // The three lights of an inactive window (macOS: grey; coloured again while the pointer is over them).
        Rgba inactiveLight;
        // Window-tiling preview (core/Tiling.hpp, FR48; owner decision D-8): the frame of the place a titlebar drag would
        // tile into, drawn under the dragged window as the blurred material (Hyprland's blur of what is behind it, under
        // this tint, as macOS's frosted pane), and its edge.
        Rgba previewTint;
        Rgba previewRim;
        // The hairline under the bar (ADR-0039 Q8, step 21): the apps' toolbar rule, the bar itself the window's own colour.
        Rgba rule;
    };

    constexpr TitlebarPalette titlebarPalette(Appearance appearance) {
        constexpr auto titleAlpha = static_cast<float>(tokens::kTitlebarTitleOpacity);
        constexpr auto tintAlpha  = static_cast<float>(tokens::kTitlebarPreviewTintAlpha);
        constexpr auto rimAlpha   = static_cast<float>(tokens::kTitlebarPreviewRimOpacity);
        switch (appearance) {
            case Appearance::Light:
                return TitlebarPalette{.background    = fromHex(tokens::kTitlebarBackgroundLight),
                                       .title         = fromHex(tokens::kTitlebarTitleLight, titleAlpha),
                                       .inactiveLight = fromHex(tokens::kTitlebarInactiveButtonLight),
                                       .previewTint   = fromHex(tokens::kTitlebarPreviewTintLight, tintAlpha),
                                       .previewRim    = fromHex(tokens::kTitlebarPreviewRimLight, rimAlpha),
                                       .rule          = fromHex(tokens::kTitlebarRuleLight, static_cast<float>(tokens::kTitlebarRuleOpacityLight))};
            case Appearance::Dark:
            default:
                return TitlebarPalette{.background    = fromHex(tokens::kTitlebarBackgroundDark),
                                       .title         = fromHex(tokens::kTitlebarTitleDark, titleAlpha),
                                       .inactiveLight = fromHex(tokens::kTitlebarInactiveButtonDark),
                                       .previewTint   = fromHex(tokens::kTitlebarPreviewTintDark, tintAlpha),
                                       .previewRim    = fromHex(tokens::kTitlebarPreviewRimDark, rimAlpha),
                                       .rule          = fromHex(tokens::kTitlebarRuleDark, static_cast<float>(tokens::kTitlebarRuleOpacityDark))};
        }
    }

    // The appearance until the shell says otherwise (hl.plugin.grassfield.config("appearance", "dark" | "light"), feature
    // "appearance"; Grassfield's default appearance is dark).
    inline constexpr Appearance kDefaultAppearance = Appearance::Dark;

    // The appearance the shell pushed, and whether it pushed one since this load (the dark rim waits for it, WindowRim.hpp).
    // Reset at unload: Hyprland 0.56.2 keeps an unloaded plugin's library mapped ("this library stays in memory"), so a
    // reload would otherwise find the previous load's appearance, and a session turned light meanwhile would get a dark rim
    // until the shell's next push.
    struct PushedAppearance {
        Appearance current = kDefaultAppearance;
        bool       known   = false;

        // The shell's push: true when the chrome must be drawn again (another value, or the first push since the load).
        bool push(Appearance pushed) {
            const bool changed = pushed != current || !known;
            current            = pushed;
            known              = true;
            return changed;
        }

        // Unload: as on a fresh load.
        void reset() {
            *this = PushedAppearance{};
        }
    };

    // The width of the hairline under the bar (one point, ADR-0039 D5).
    inline constexpr double kTitlebarRuleWidth = tokens::kTitlebarRuleWidth;

    // The width of the tiling preview's edge (logical px).
    inline constexpr double kTilePreviewRim = tokens::kTitlebarPreviewRimWidth;

} // namespace gf::theme
