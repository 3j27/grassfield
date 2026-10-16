#include "core/Theme.hpp"
#include "core/TitlebarLayout.hpp"

#include <gtest/gtest.h>

#include <cstdint>

using namespace gf::titlebar;

TEST(TitlebarLayout, DefaultMetricsMatchTheSpec) {
    const Metrics m;
    EXPECT_DOUBLE_EQ(m.height, 28.0);
    EXPECT_DOUBLE_EQ(m.diameter, 12.0);
    EXPECT_DOUBLE_EQ(m.spacing, 8.0);
    EXPECT_DOUBLE_EQ(m.insetLeft, 12.0);
}

TEST(TitlebarLayout, ButtonsAreLeftAlignedCloseMinimizeZoom) {
    EXPECT_EQ(buttonRect(Button::Close), (Rect{12, 8, 12, 12}));
    EXPECT_EQ(buttonRect(Button::Minimize), (Rect{32, 8, 12, 12}));
    EXPECT_EQ(buttonRect(Button::Zoom), (Rect{52, 8, 12, 12}));
    EXPECT_DOUBLE_EQ(buttonsRightEdge(), 64.0);
}

TEST(TitlebarLayout, ButtonsAreVerticallyCentered) {
    const Rect r = buttonRect(Button::Close);
    EXPECT_DOUBLE_EQ(r.y + (r.h / 2.0), 14.0);
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
    EXPECT_EQ(hitTest(18, 14, 400), HitTarget::Close);
    EXPECT_EQ(hitTest(38, 14, 400), HitTarget::Minimize);
    EXPECT_EQ(hitTest(58, 14, 400), HitTarget::Zoom);
}

TEST(TitlebarLayout, HitTestUsesCircleWithSlop) {
    // radius 6 + slop 2 = 8 from the close center (18, 14)
    EXPECT_EQ(hitTest(18 + 7.9, 14, 400), HitTarget::Close);
    EXPECT_EQ(hitTest(18, 14 - 7.9, 400), HitTarget::Close);
    // corner of the bounding square grown by the slop is outside the circle
    EXPECT_EQ(hitTest(18 + 7, 14 + 7, 400), HitTarget::DragArea);
}

TEST(TitlebarLayout, HitTestGapBetweenButtonsIsDragArea) {
    // Exactly between close (18) and minimize (38): 10 px from each center > 8.
    EXPECT_EQ(hitTest(28, 14, 400), HitTarget::DragArea);
}

TEST(TitlebarLayout, HitTestRestOfBarIsDragArea) {
    EXPECT_EQ(hitTest(200, 14, 400), HitTarget::DragArea);
    EXPECT_EQ(hitTest(399.5, 27.5, 400), HitTarget::DragArea);
    EXPECT_EQ(hitTest(0, 0, 400), HitTarget::DragArea);
}

TEST(TitlebarLayout, HitTestOutsideIsNone) {
    EXPECT_EQ(hitTest(-1, 14, 400), HitTarget::None);
    EXPECT_EQ(hitTest(400, 14, 400), HitTarget::None);
    EXPECT_EQ(hitTest(200, 28, 400), HitTarget::None);
    EXPECT_EQ(hitTest(200, -0.1, 400), HitTarget::None);
    EXPECT_EQ(hitTest(18, 14, 0), HitTarget::None);
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
    EXPECT_DOUBLE_EQ(p.maxWidth, 800 - (2 * (64 + 8)));
}

TEST(TitlebarLayout, LongTitleIsClampedClearOfTheButtons) {
    const auto p = placeTitle(300, 1000);
    ASSERT_TRUE(p.visible);
    EXPECT_DOUBLE_EQ(p.maxWidth, 300 - 144);
    EXPECT_DOUBLE_EQ(p.x, 72.0); // buttons end at 64, plus 8 px padding
    EXPECT_GE(p.x, buttonsRightEdge() + Metrics{}.titlePadding);
}

TEST(TitlebarLayout, TitleHiddenWhenNoRoom) {
    EXPECT_FALSE(placeTitle(144, 10).visible);
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
