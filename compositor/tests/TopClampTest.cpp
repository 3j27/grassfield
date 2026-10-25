// A window's titlebar never goes under the menu bar (macOS; owner report from the 1.0.0-rc1 real session: Chromium dragged
// up until its tab strip was under the menu bar could not be grabbed again). Test names state the user-visible rule.

#include "core/TopClamp.hpp"

#include <gtest/gtest.h>

#include <array>
#include <cstddef>

namespace {
    using gf::topclamp::Output;
    using gf::topclamp::Rect;

    // Two outputs side by side, the left one 1920x1080 with a 32 px menu bar, the right one 2560x1440 at x 1920 with a
    // 24 px menu bar; and a third one under the left one (no menu bar of its own: a 0 px reserved area).
    constexpr std::array<Output, 3> kOutputs{
        Output{Rect{0, 0, 1920, 1080}, 32},
        Output{Rect{1920, 0, 2560, 1440}, 24},
        Output{Rect{0, 1080, 1920, 1080}, 1080},
    };
    constexpr size_t kNone = 99; // "no output" in the comparisons below

    constexpr double kBand = 32; // the plugin's titlebar above the surface
} // namespace

TEST(TopClamp, AWindowDraggedUnderTheMenuBarStopsJustBelowIt) {
    // The plugin's titlebar would start at y = 20 - 32 = -12: the frame starts at the menu bar's bottom instead.
    const Rect moved = gf::topclamp::afterMove(Rect{300, 20, 800, 600}, kBand, kOutputs[0]);
    EXPECT_DOUBLE_EQ(moved.y, 32 + kBand) << "the titlebar starts at the menu bar's bottom";
    EXPECT_DOUBLE_EQ(moved.x, 300) << "only the top is held";
    EXPECT_DOUBLE_EQ(moved.w, 800);
    EXPECT_DOUBLE_EQ(moved.h, 600) << "a move keeps the size";
}

TEST(TopClamp, AnAppThatDrawsItsOwnTitlebarIsHeldByItsSurfaceTop) {
    // Client chrome (Chromium's tab strip): no band, the surface top itself stays below the menu bar.
    const Rect moved = gf::topclamp::afterMove(Rect{300, 5, 1382, 798}, 0, kOutputs[0]);
    EXPECT_DOUBLE_EQ(moved.y, 32);
    const Rect above = gf::topclamp::afterMove(Rect{300, -200, 1382, 798}, 0, kOutputs[0]);
    EXPECT_DOUBLE_EQ(above.y, 32) << "dragged above the output too";
}

TEST(TopClamp, AWindowBelowTheMenuBarIsLeftAlone) {
    const Rect fine{300, 64, 800, 600};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(fine, kBand, kOutputs[0]), fine)) << "exactly at the menu bar";
    const Rect lower{300, 400, 800, 600};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(lower, kBand, kOutputs[0]), lower));
    const Rect offBottom{300, 900, 800, 600};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(offBottom, kBand, kOutputs[0]), offBottom)) << "a window may hang off the bottom";
    const Rect fraction{300, 63.6, 800, 600};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(fraction, kBand, kOutputs[0]), fraction)) << "rounding is not a move";
}

TEST(TopClamp, EachOutputHasItsOwnMenuBar) {
    // The output under the pointer decides: the right output's menu bar is 24 px high.
    const Rect frame{2000, -10, 900, 632};
    const size_t index = gf::topclamp::outputFor(2300, 5, frame, kOutputs).value_or(kNone);
    ASSERT_EQ(index, 1U);
    const Rect moved = gf::topclamp::afterMove(Rect{2000, 22, 900, 600}, kBand, kOutputs.at(index));
    EXPECT_DOUBLE_EQ(moved.y, 24 + kBand);
}

TEST(TopClamp, TheOutputUnderThePointerWinsSoAWindowCanCrossToAnotherOutput) {
    // A window dragged from the lower output up into the upper one: once the pointer is on the upper output, its menu bar
    // holds the window, not the lower output's top edge.
    const Rect frame{100, 1050, 800, 632};
    const size_t upper = gf::topclamp::outputFor(400, 1070, frame, kOutputs).value_or(kNone);
    ASSERT_EQ(upper, 0U);
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterMove(Rect{100, 1082, 800, 600}, kBand, kOutputs.at(upper)), Rect{100, 1082, 800, 600}));
    // Without a pointer on any output, the top centre of the frame decides.
    EXPECT_EQ(gf::topclamp::outputFor(-500, -500, Rect{2100, 10, 400, 300}, kOutputs).value_or(kNone), 1U);
    EXPECT_FALSE(gf::topclamp::outputFor(-500, -500, Rect{-900, -900, 100, 100}, kOutputs).has_value()) << "nowhere: no clamp";
}

TEST(TopClamp, AResizeStopsTheTopEdgeAtTheMenuBar) {
    // The top edge dragged up under the menu bar: it stops there, the bottom edge stays.
    const Rect resized = gf::topclamp::afterResize(Rect{300, 10, 800, 700}, kBand, kOutputs[0]);
    EXPECT_DOUBLE_EQ(resized.y, 64);
    EXPECT_DOUBLE_EQ(resized.y + resized.h, 710) << "the bottom edge does not move";
    EXPECT_DOUBLE_EQ(resized.x, 300);
    EXPECT_DOUBLE_EQ(resized.w, 800);
    const Rect tiny = gf::topclamp::afterResize(Rect{300, -400, 800, 420}, kBand, kOutputs[0]);
    EXPECT_GE(tiny.h, 1) << "never smaller than 1 px";
    const Rect fine{300, 100, 800, 700};
    EXPECT_FALSE(gf::topclamp::changed(gf::topclamp::afterResize(fine, kBand, kOutputs[0]), fine));
}

TEST(TopClamp, AnOutputWithoutAMenuBarHoldsAtItsTop) {
    // A reserved area of 0 px (no shell, or an output without the menu bar): the output's top edge.
    const Output bare{Rect{0, 0, 1920, 1080}, 0};
    const Rect moved = gf::topclamp::afterMove(Rect{300, 10, 800, 600}, kBand, bare);
    EXPECT_DOUBLE_EQ(moved.y, kBand);
}
