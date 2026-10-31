#include "core/Theme.hpp"
#include "core/TitlebarLayout.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <utility>

using namespace gf::titlebar;

TEST(TitlebarLayout, DefaultMetricsMatchTheSpec) {
    // macOS 26 titlebar-only window (docs/testing/f1-reference-gaps.md, "Window chrome").
    const Metrics m;
    EXPECT_DOUBLE_EQ(m.height, 32.0);
    EXPECT_DOUBLE_EQ(m.diameter, 14.0);
    EXPECT_DOUBLE_EQ(m.spacing, 9.0);
    EXPECT_DOUBLE_EQ(m.insetLeft, 9.0);
    EXPECT_DOUBLE_EQ(m.hitSlop, 14.0 / 6.0);
}

TEST(TitlebarLayout, HitSlopScalesWithTheDiameter) {
    // 2 px around the former 12-px lights: the same share of the new diameter.
    EXPECT_DOUBLE_EQ(gf::theme::kButtonHitSlop / gf::theme::kButtonDiameter, 2.0 / 12.0);
}

TEST(TitlebarLayout, ButtonsAreLeftAlignedCloseMinimizeZoom) {
    EXPECT_EQ(buttonRect(Button::Close), (Rect{9, 9, 14, 14}));
    EXPECT_EQ(buttonRect(Button::Minimize), (Rect{32, 9, 14, 14}));
    EXPECT_EQ(buttonRect(Button::Zoom), (Rect{55, 9, 14, 14}));
    EXPECT_DOUBLE_EQ(buttonsRightEdge(), 69.0);
}

TEST(TitlebarLayout, ButtonsAreVerticallyCentered) {
    const Rect r = buttonRect(Button::Close);
    EXPECT_DOUBLE_EQ(r.y + (r.h / 2.0), 16.0);
}

TEST(TitlebarLayout, FirstLightAndPitchMatchTheReference) {
    // Reference: first centre (15.6, 15.6) +-1 from the window's top-left corner, centres 23 apart.
    const Rect close = buttonRect(Button::Close);
    const Rect min   = buttonRect(Button::Minimize);
    const Rect zoom  = buttonRect(Button::Zoom);
    EXPECT_NEAR(close.x + (close.w / 2.0), 15.6, 1.0);
    EXPECT_NEAR(close.y + (close.h / 2.0), 15.6, 1.0);
    EXPECT_DOUBLE_EQ(min.x - close.x, 23.0);
    EXPECT_DOUBLE_EQ(zoom.x - min.x, 23.0);
}

TEST(TitlebarLayout, CustomMetricsScaleTheLayout) {
    Metrics m;
    m.height    = 40;
    m.diameter  = 16;
    m.spacing   = 10;
    m.insetLeft = 20;
    EXPECT_EQ(buttonRect(Button::Zoom, m), (Rect{72, 12, 16, 16}));
}

TEST(TitlebarLayout, HitTestButtonCenters) {
    EXPECT_EQ(hitTest(16, 16, 400), HitTarget::Close);
    EXPECT_EQ(hitTest(39, 16, 400), HitTarget::Minimize);
    EXPECT_EQ(hitTest(62, 16, 400), HitTarget::Zoom);
}

TEST(TitlebarLayout, HitTestUsesCircleWithSlop) {
    // radius 7 + slop 2.33 = 9.33 around each centre: close (16, 16), minimize (39, 16), zoom (62, 16)
    for (const auto& [cx, target] : {std::pair{16.0, HitTarget::Close}, std::pair{39.0, HitTarget::Minimize}, std::pair{62.0, HitTarget::Zoom}}) {
        EXPECT_EQ(hitTest(cx + 9.3, 16, 400), target) << cx;
        EXPECT_EQ(hitTest(cx - 9.3, 16, 400), target) << cx;
        EXPECT_EQ(hitTest(cx, 16 - 9.3, 400), target) << cx;
        EXPECT_EQ(hitTest(cx, 16 + 9.3, 400), target) << cx;
        EXPECT_EQ(hitTest(cx + 6.5, 16 + 6.5, 400), target) << cx; // 9.19 from the centre: outside the drawn circle, inside the slop
        // just past the slop
        EXPECT_EQ(hitTest(cx, 16 - 9.4, 400), HitTarget::DragArea) << cx;
        EXPECT_EQ(hitTest(cx, 16 + 9.4, 400), HitTarget::DragArea) << cx;
        // corner of the bounding square grown by the slop is outside the circle
        EXPECT_EQ(hitTest(cx + 7, 16 + 7, 400), HitTarget::DragArea) << cx;
    }
    EXPECT_EQ(hitTest(16 - 9.4, 16, 400), HitTarget::DragArea);
    EXPECT_EQ(hitTest(62 + 9.4, 16, 400), HitTarget::DragArea);
}

TEST(TitlebarLayout, HitTestGapBetweenButtonsIsDragArea) {
    // Exactly between two centres: 11.5 px from each > 9.33.
    EXPECT_EQ(hitTest(27.5, 16, 400), HitTarget::DragArea);
    EXPECT_EQ(hitTest(50.5, 16, 400), HitTarget::DragArea);
    // The slops of neighbours never meet: about 2.17 px of drag area on each side of the middle.
    EXPECT_EQ(hitTest(16 + 9.4, 16, 400), HitTarget::DragArea);
    EXPECT_EQ(hitTest(39 - 9.4, 16, 400), HitTarget::DragArea);
}

TEST(TitlebarLayout, HitTestRestOfBarIsDragArea) {
    EXPECT_EQ(hitTest(200, 16, 400), HitTarget::DragArea);
    EXPECT_EQ(hitTest(399.5, 31.5, 400), HitTarget::DragArea);
    EXPECT_EQ(hitTest(0, 0, 400), HitTarget::DragArea);
    EXPECT_EQ(hitTest(16, 0.5, 400), HitTarget::DragArea);  // above the close button's slop
    EXPECT_EQ(hitTest(16, 31.5, 400), HitTarget::DragArea); // below it
}

TEST(TitlebarLayout, HitTestOutsideIsNone) {
    EXPECT_EQ(hitTest(-1, 16, 400), HitTarget::None);
    EXPECT_EQ(hitTest(400, 16, 400), HitTarget::None);
    EXPECT_EQ(hitTest(200, 32, 400), HitTarget::None);
    EXPECT_EQ(hitTest(200, -0.1, 400), HitTarget::None);
    EXPECT_EQ(hitTest(16, 16, 0), HitTarget::None);
}

TEST(TitlebarLayout, ButtonForHit) {
    EXPECT_EQ(buttonForHit(HitTarget::Close), Button::Close);
    EXPECT_EQ(buttonForHit(HitTarget::Minimize), Button::Minimize);
    EXPECT_EQ(buttonForHit(HitTarget::Zoom), Button::Zoom);
    EXPECT_FALSE(buttonForHit(HitTarget::DragArea).has_value());
    EXPECT_FALSE(buttonForHit(HitTarget::None).has_value());
}

TEST(TitlebarLayout, TitleIsCenteredOnTheWholeBar) {
    const auto p = placeTitle(800, 100);
    ASSERT_TRUE(p.visible);
    EXPECT_DOUBLE_EQ(p.x, 350.0);
    EXPECT_DOUBLE_EQ(p.maxWidth, 800 - (2 * (69 + 8)));
}

TEST(TitlebarLayout, LongTitleIsClampedClearOfTheButtons) {
    const auto p = placeTitle(300, 1000);
    ASSERT_TRUE(p.visible);
    EXPECT_DOUBLE_EQ(p.maxWidth, 300 - 154);
    EXPECT_DOUBLE_EQ(p.x, 77.0); // buttons end at 69, plus 8 px padding
    EXPECT_GE(p.x, buttonsRightEdge() + Metrics{}.titlePadding);
}

TEST(TitlebarLayout, TitleHiddenWhenNoRoom) {
    EXPECT_FALSE(placeTitle(154, 10).visible);
    EXPECT_FALSE(placeTitle(100, 10).visible);
    EXPECT_FALSE(placeTitle(800, 0).visible);
    EXPECT_DOUBLE_EQ(maxTitleWidth(100), 0.0);
}

// ---- hover glyphs ----

TEST(ButtonGroup, CoversTheThreeHitCirclesAndTheirGaps) {
    const Rect g = buttonGroupRect();
    const double slop = gf::theme::kButtonHitSlop;
    EXPECT_DOUBLE_EQ(g.x, 9 - slop);
    EXPECT_DOUBLE_EQ(g.y, 9 - slop);
    EXPECT_DOUBLE_EQ(g.x + g.w, 69 + slop);
    EXPECT_DOUBLE_EQ(g.y + g.h, 23 + slop);
    for (const double x : {16.0, 27.5, 39.0, 50.5, 62.0}) // centres and the gaps between the lights
        EXPECT_TRUE(overButtonGroup(x, 16, 400)) << x;
    // Every point that hits a button is over the group (half-pixel grid).
    for (int ix = 0; ix < 160; ++ix) {
        for (int iy = 0; iy < 64; ++iy) {
            const double x = ix / 2.0;
            const double y = iy / 2.0;
            if (buttonForHit(hitTest(x, y, 400))) {
                EXPECT_TRUE(overButtonGroup(x, y, 400)) << x << "," << y;
            }
        }
    }
}

TEST(ButtonGroup, ElsewhereOnTheBarIsNotOverTheGroup) {
    EXPECT_FALSE(overButtonGroup(69 + 2.5, 16, 400)); // right of the zoom button's slop
    EXPECT_FALSE(overButtonGroup(16, 3, 400));        // above the close button
    EXPECT_FALSE(overButtonGroup(16, 29, 400));       // below it
    EXPECT_FALSE(overButtonGroup(200, 16, 400));
    EXPECT_FALSE(overButtonGroup(16, 16, 0)); // no bar
    EXPECT_FALSE(overButtonGroup(16, 16, 12)); // bar narrower than the pointer's x
    EXPECT_FALSE(overButtonGroup(-1, 16, 400));
}

TEST(GlyphSize, AboutTheRatioWithTheLightsParity) {
    EXPECT_EQ(glyphSizePx(14), 8);  // 7.7 -> 8: (14 - 8) / 2 = 3 px each side
    EXPECT_EQ(glyphSizePx(28), 16); // scale 2: 15.4 -> 16
    EXPECT_EQ(glyphSizePx(21), 11); // scale 1.5: 11.55 -> 11, odd like 21
    EXPECT_EQ(glyphSizePx(1), 1);
    EXPECT_EQ(glyphSizePx(0), 0);
    EXPECT_EQ(glyphSizePx(-4), 0);
    EXPECT_EQ(glyphSizePx(14, 0), 0);
    EXPECT_EQ(glyphSizePx(14, 1.5), 0);
    EXPECT_LE(glyphSizePx(10000), gf::theme::kMaxGlyphPx);
}

namespace {
    uint8_t at(const std::vector<uint8_t>& mask, int n, int x, int y) {
        return mask[(static_cast<size_t>(y) * static_cast<size_t>(n)) + static_cast<size_t>(x)];
    }
} // namespace

TEST(GlyphMask, CloseIsASymmetricCross) {
    const int  n    = 16;
    const auto mask = glyphMask(Button::Close, n, 0.12 * 28);
    ASSERT_EQ(mask.size(), static_cast<size_t>(n * n));
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x) {
            EXPECT_EQ(at(mask, n, x, y), at(mask, n, y, x)) << "transpose " << x << "," << y;
            EXPECT_EQ(at(mask, n, x, y), at(mask, n, n - 1 - x, y)) << "mirror " << x << "," << y;
        }
    }
    EXPECT_EQ(at(mask, n, 7, 7), 255);  // the crossing
    EXPECT_GT(at(mask, n, 0, 0), 100);  // the arms reach the corners (round caps)
    EXPECT_EQ(at(mask, n, 7, 0), 0);    // nothing in the middle of an edge
    EXPECT_EQ(at(mask, n, 0, 7), 0);
}

TEST(GlyphMask, MinimizeIsOneHorizontalBar) {
    const int  n    = 8;
    const auto mask = glyphMask(Button::Minimize, n, 0.12 * 14);
    ASSERT_EQ(mask.size(), static_cast<size_t>(n * n));
    for (int x = 1; x < n - 1; ++x) {
        EXPECT_GT(at(mask, n, x, 3), 200) << x; // the two middle rows
        EXPECT_GT(at(mask, n, x, 4), 200) << x;
        EXPECT_EQ(at(mask, n, x, 0), 0) << x;
        EXPECT_EQ(at(mask, n, x, n - 1), 0) << x;
    }
    for (int y = 0; y < n; ++y)
        EXPECT_EQ(at(mask, n, 0, y), at(mask, n, n - 1, y)) << y;
}

TEST(GlyphMask, ZoomIsAPlus) {
    const int  n    = 8;
    const auto mask = glyphMask(Button::Zoom, n, 0.12 * 14);
    ASSERT_EQ(mask.size(), static_cast<size_t>(n * n));
    EXPECT_GT(at(mask, n, 3, 3), 200);
    EXPECT_GT(at(mask, n, 3, 0), 100); // vertical arm reaches the top
    EXPECT_GT(at(mask, n, 0, 4), 100); // horizontal arm reaches the left edge
    EXPECT_EQ(at(mask, n, 0, 0), 0);   // corners empty
    EXPECT_EQ(at(mask, n, n - 1, n - 1), 0);
    for (int y = 0; y < n; ++y) {
        for (int x = 0; x < n; ++x)
            EXPECT_EQ(at(mask, n, x, y), at(mask, n, y, x)) << x << "," << y;
    }
}

TEST(GlyphMask, RefusesInvalidSizes) {
    EXPECT_TRUE(glyphMask(Button::Close, 0, 2).empty());
    EXPECT_TRUE(glyphMask(Button::Close, -3, 2).empty());
    EXPECT_TRUE(glyphMask(Button::Close, gf::theme::kMaxGlyphPx + 1, 2).empty());
    EXPECT_TRUE(glyphMask(Button::Close, 8, 0).empty());
    EXPECT_TRUE(glyphMask(Button::Close, 8, -1).empty());
    EXPECT_EQ(glyphMask(Button::Zoom, 1, 50).size(), 1U); // stroke wider than the square: clamped
}

TEST(GlyphMask, PremultipliedPixels) {
    const std::vector<uint8_t> mask{0, 255, 128};
    const auto px = premultipliedBgra(mask, gf::theme::kGlyphColor);
    ASSERT_EQ(px.size(), 12U);
    EXPECT_EQ(px[3], 0);   // transparent where the mask is empty
    EXPECT_EQ(px[7], 128); // half-opaque black under full coverage (kGlyphColor alpha 0.5)
    EXPECT_EQ(px[4], 0);
    EXPECT_EQ(px[11], 64);
    const auto red = premultipliedBgra({255}, gf::theme::Rgba{.r = 1.F, .g = 0.F, .b = 0.F, .a = 0.5F});
    EXPECT_EQ(red[0], 0);   // B
    EXPECT_EQ(red[2], 128); // R premultiplied by alpha
    EXPECT_EQ(red[3], 128);
}

// ---- inactive lights ----

namespace {
    bool sameColor(const gf::theme::Rgba& a, const gf::theme::Rgba& b) {
        return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
    }
} // namespace

TEST(LightColor, ActiveWindowShowsTheColours) {
    using gf::theme::Appearance;
    EXPECT_TRUE(sameColor(lightColor(Button::Close, true, false, Appearance::Dark), gf::theme::kCloseColor));
    EXPECT_TRUE(sameColor(lightColor(Button::Minimize, true, false, Appearance::Dark), gf::theme::kMinimizeColor));
    EXPECT_TRUE(sameColor(lightColor(Button::Zoom, true, true, Appearance::Light), gf::theme::kZoomColor));
}

TEST(LightColor, InactiveWindowIsGreyUntilHovered) {
    using gf::theme::Appearance;
    for (const auto button : kButtonOrder) {
        EXPECT_TRUE(sameColor(lightColor(button, false, false, Appearance::Dark), gf::theme::titlebarPalette(Appearance::Dark).inactiveLight));
        EXPECT_TRUE(sameColor(lightColor(button, false, false, Appearance::Light), gf::theme::titlebarPalette(Appearance::Light).inactiveLight));
    }
    EXPECT_TRUE(sameColor(lightColor(Button::Close, false, true, Appearance::Dark), gf::theme::kCloseColor)); // hover: colours back
}

TEST(LightColor, InactiveGreyIsOneStepAboveItsBar) {
    using gf::theme::Appearance;
    const auto dark  = gf::theme::titlebarPalette(Appearance::Dark);
    const auto light = gf::theme::titlebarPalette(Appearance::Light);
    EXPECT_GT(dark.inactiveLight.r, dark.background.r);   // lighter than the dark bar
    EXPECT_LT(light.inactiveLight.r, light.background.r); // darker than the light bar
    EXPECT_NEAR(light.inactiveLight.r, 0xD4 / 255.F, 4 / 255.F); // reference sample about #D4D4D4
}

// ---- content corners under the bar ----

TEST(ContentCornerPatch, SquaresUnderBothEndsOfTheBar) {
    const Rect bar{100, 50, 700, 32};
    const Rect texture{100, 82, 700, 500}; // the surface right below the bar
    const auto p = contentCornerPatch(bar, 26, texture);
    ASSERT_TRUE(p.valid);
    EXPECT_EQ(p.left, (Rect{100, 82, 26, 26}));
    EXPECT_EQ(p.right, (Rect{774, 82, 26, 26}));
}

TEST(ContentCornerPatch, TextureWithClientShadowMargins) {
    // A client-side-decorated surface: its texture extends 20 px beyond the window geometry on every side.
    const auto p = contentCornerPatch(Rect{100, 50, 700, 32}, 12, Rect{80, 62, 740, 540});
    ASSERT_TRUE(p.valid);
    EXPECT_EQ(p.left, (Rect{100, 82, 12, 12}));
}

TEST(ContentCornerPatch, InvalidWhenTheMappingWouldBeAGuess) {
    const Rect bar{100, 50, 700, 32};
    EXPECT_FALSE(contentCornerPatch(bar, 0, Rect{100, 82, 700, 500}).valid);   // no rounding
    EXPECT_FALSE(contentCornerPatch(bar, -3, Rect{100, 82, 700, 500}).valid);
    EXPECT_FALSE(contentCornerPatch(Rect{100, 50, 40, 32}, 26, Rect{100, 82, 40, 500}).valid); // narrower than two squares
    EXPECT_FALSE(contentCornerPatch(bar, 26, Rect{100, 82, 600, 500}).valid);  // surface narrower than the bar (resizing)
    EXPECT_FALSE(contentCornerPatch(bar, 26, Rect{100, 90, 700, 500}).valid);  // surface below the bar's bottom edge
    EXPECT_FALSE(contentCornerPatch(bar, 26, Rect{100, 82, 700, 10}).valid);   // shorter than the square
    EXPECT_FALSE(contentCornerPatch(bar, 26, Rect{100, 82, 0, 0}).valid);
    EXPECT_TRUE(contentCornerPatch(bar, 26, Rect{100.4, 82.4, 699.6, 500}).valid); // sub-pixel rounding tolerated
}

TEST(ClickTracker, TwoQuickPressesAreADoubleClick) {
    CClickTracker t;
    EXPECT_FALSE(t.press(1000, 100, 10));
    EXPECT_TRUE(t.press(1000 + gf::theme::kDoubleClickMs, 102, 11));
}

TEST(ClickTracker, SlowSecondPressIsNotADoubleClick) {
    CClickTracker t(400, 4);
    EXPECT_FALSE(t.press(1000, 100, 10));
    EXPECT_FALSE(t.press(1401, 100, 10));
    // ...but it starts a new sequence
    EXPECT_TRUE(t.press(1500, 100, 10));
}

TEST(ClickTracker, MovedSecondPressIsNotADoubleClick) {
    CClickTracker t(400, 4);
    EXPECT_FALSE(t.press(1000, 100, 10));
    EXPECT_FALSE(t.press(1100, 105, 10));
}

TEST(ClickTracker, ThirdPressStartsANewSequence) {
    CClickTracker t(400, 4);
    EXPECT_FALSE(t.press(1000, 100, 10));
    EXPECT_TRUE(t.press(1100, 100, 10));
    EXPECT_FALSE(t.press(1200, 100, 10));
    EXPECT_TRUE(t.press(1300, 100, 10));
}

TEST(ClickTracker, HandlesTimestampWrapAround) {
    CClickTracker t(400, 4);
    EXPECT_FALSE(t.press(UINT32_MAX - 50, 100, 10));
    EXPECT_TRUE(t.press(100, 100, 10)); // 151 ms later across the wrap
}

TEST(ClickTracker, ResetForgetsThePreviousPress) {
    CClickTracker t(400, 4);
    EXPECT_FALSE(t.press(1000, 100, 10));
    t.reset();
    EXPECT_FALSE(t.press(1100, 100, 10));
}

TEST(DragThreshold, ClickJitterNeverMovesTheWindow) {
    // FR8 regression: the first click of a double-click on a maximized bar wrote the maximized box into
    // the floating geometry. A press that stays within the threshold is a click.
    EXPECT_FALSE(exceedsDragThreshold(0, 0));
    EXPECT_FALSE(exceedsDragThreshold(3, 0));
    EXPECT_FALSE(exceedsDragThreshold(0, -4));          // exactly the threshold: still a click
    EXPECT_FALSE(exceedsDragThreshold(2.8, 2.8));       // diagonal, distance 3.96
    // Any press-release that may still be the first half of a double-click stays a click.
    EXPECT_GE(gf::theme::kDragThreshold, gf::theme::kDoubleClickSlop);
}

TEST(DragThreshold, TravelBeyondTheThresholdIsADrag) {
    EXPECT_TRUE(exceedsDragThreshold(4.01, 0));
    EXPECT_TRUE(exceedsDragThreshold(-3, -3));          // distance 4.24
    EXPECT_TRUE(exceedsDragThreshold(0, 120));
    EXPECT_TRUE(exceedsDragThreshold(1, 1, 1.0));       // custom threshold
}

TEST(UnzoomedDragBox, KeepsThePointerOnTheTitlebarAtTheSameFraction) {
    // Maximized surface 1920x950 at (1440,53) (the titlebar is above it, 25..53); press on the bar at 25% of
    // the width, 14 px above the surface. Floating size 700x500.
    const Rect zoomed{1440, 53, 1920, 950};
    const Rect box = unzoomedDragBox(zoomed, 700, 500, 1440 + 480, 53 - 14, 2440, 400);
    EXPECT_DOUBLE_EQ(box.w, 700);
    EXPECT_DOUBLE_EQ(box.h, 500);
    EXPECT_DOUBLE_EQ(box.x, 2440 - (0.25 * 700)); // pointer still at 25% of the window width
    EXPECT_DOUBLE_EQ(box.y, 400 + 14);            // pointer still 14 px above the surface: on the titlebar
}

TEST(UnzoomedDragBox, ClampsDegenerateInput) {
    const Rect zoomed{0, 0, 1000, 800};
    // Press left of the box (should not happen): the fraction is clamped into the window.
    Rect box = unzoomedDragBox(zoomed, 400, 300, -50, -10, 100, 100);
    EXPECT_DOUBLE_EQ(box.x, 100);
    EXPECT_DOUBLE_EQ(box.y, 110);
    // Press below the restored height: the window never ends up above the pointer.
    box = unzoomedDragBox(zoomed, 400, 300, 5000, 2000, 100, 100);
    EXPECT_DOUBLE_EQ(box.x, 100 - 400);
    EXPECT_DOUBLE_EQ(box.y, 100 - 300);
    // Zero-width maximized box: centered under the pointer.
    box = unzoomedDragBox(Rect{0, 0, 0, 0}, 400, 300, 0, 0, 500, 500);
    EXPECT_DOUBLE_EQ(box.x, 300);
}

TEST(Theme, ColorsAreGrassfieldValues) {
    using namespace gf::theme;
    EXPECT_FLOAT_EQ(kCloseColor.r, 0xE5 / 255.F);
    EXPECT_FLOAT_EQ(kCloseColor.g, 0x53 / 255.F);
    EXPECT_FLOAT_EQ(kCloseColor.b, 0x4B / 255.F);
    EXPECT_FLOAT_EQ(kMinimizeColor.r, 0xD9 / 255.F);
    EXPECT_FLOAT_EQ(kZoomColor.g, 0xA6 / 255.F);
    // The window's own colours (ADR-0039 Q8, step 21), warm (ADR-0040): #2B2925 and #FDFCF9 (red above blue), where the bar
    // was a band of its own (#2A2824, #EFECE7).
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Dark).background.r, 43 / 255.F);
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Dark).background.b, 37 / 255.F);
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Light).background.r, 253 / 255.F);
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Light).background.b, 249 / 255.F);
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Light).background.a, 1.F);
}

// Audit UX-06 / D-8: both appearances come from the design tokens (ui/tokens/tokens.json "titlebar", ThemeTokens.hpp).
TEST(Theme, PaletteComesFromTheTokensForBothAppearances) {
    using namespace gf::theme;
    const auto same = [](const Rgba& a, const Rgba& b) { return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a; };
    const auto dark  = titlebarPalette(Appearance::Dark);
    const auto light = titlebarPalette(Appearance::Light);
    EXPECT_TRUE(same(dark.background, fromHex(tokens::kTitlebarBackgroundDark)));
    EXPECT_TRUE(same(light.background, fromHex(tokens::kTitlebarBackgroundLight)));
    EXPECT_TRUE(same(dark.title, fromHex(tokens::kTitlebarTitleDark, static_cast<float>(tokens::kTitlebarTitleOpacity))));
    EXPECT_TRUE(same(light.title, fromHex(tokens::kTitlebarTitleLight, static_cast<float>(tokens::kTitlebarTitleOpacity))));
    EXPECT_TRUE(same(dark.inactiveLight, fromHex(tokens::kTitlebarInactiveButtonDark)));
    EXPECT_TRUE(same(light.inactiveLight, fromHex(tokens::kTitlebarInactiveButtonLight)));
    EXPECT_TRUE(same(light.previewTint, fromHex(tokens::kTitlebarPreviewTintLight, static_cast<float>(tokens::kTitlebarPreviewTintAlpha))));
    EXPECT_TRUE(same(dark.previewRim, fromHex(tokens::kTitlebarPreviewRimDark, static_cast<float>(tokens::kTitlebarPreviewRimOpacity))));
    // The hairline under the bar: the apps' separator, black at 0.08 in the light appearance, white at 0.16 in the dark one
    // (ADR-0039 Q8, step 21), one point wide.
    EXPECT_TRUE(same(light.rule, fromHex(0x000000, 0.08F)));
    EXPECT_TRUE(same(dark.rule, fromHex(0xFFFFFF, 0.16F)));
    EXPECT_DOUBLE_EQ(kTitlebarRuleWidth, 1.0);
    // A light bar and dark text in the light appearance, the reverse in the dark one; the title readable on its bar.
    const auto luma = [](const Rgba& c) { return (0.2126F * c.r) + (0.7152F * c.g) + (0.0722F * c.b); };
    EXPECT_GT(luma(light.background), 0.8F);
    EXPECT_LT(luma(dark.background), 0.2F);
    EXPECT_GT(luma(light.background) - luma(light.title), 0.5F);
    EXPECT_GT(luma(dark.title) - luma(dark.background), 0.5F);
    // The preview is translucent (the blur behind it shows through) and has an edge of its own.
    EXPECT_GT(dark.previewTint.a, 0.F);
    EXPECT_LT(dark.previewTint.a, 1.F);
    EXPECT_GT(kTilePreviewRim, 0.0);
    EXPECT_EQ(kDefaultAppearance, Appearance::Dark) << "Grassfield's default until the shell pushes its appearance";
}

TEST(TitlebarLayout, AGrassfieldAppsZoomLightSitsInItsRow) {
    // The plugin's titlebar row: lights at x 9, 32, 55; the zoom light is the third.
    const Rect titlebar = appZoomLight(true);
    EXPECT_DOUBLE_EQ(titlebar.x, 55);
    EXPECT_DOUBLE_EQ(titlebar.y, 9);
    EXPECT_DOUBLE_EQ(titlebar.w, 14);
    EXPECT_DOUBLE_EQ(titlebar.h, 14);
    const Rect plugin = buttonRect(Button::Zoom);
    EXPECT_DOUBLE_EQ(titlebar.x, plugin.x) << "the titlebar row is the plugin's own";
    EXPECT_DOUBLE_EQ(titlebar.y, plugin.y);
    // The unified toolbar row: the first light's centre at (26, 26), pitch 23: the zoom light's centre at (72, 26).
    const Rect unified = appZoomLight(false);
    EXPECT_DOUBLE_EQ(unified.x + unified.w / 2, 72);
    EXPECT_DOUBLE_EQ(unified.y + unified.h / 2, 26);
    EXPECT_DOUBLE_EQ(unified.w, 14);
}
