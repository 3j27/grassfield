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
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Dark).background.r, 40 / 255.F);
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Dark).background.b, 44 / 255.F);
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Light).background.r, 236 / 255.F);
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Light).background.b, 238 / 255.F);
    EXPECT_FLOAT_EQ(titlebarPalette(Appearance::Light).background.a, 1.F);
}
