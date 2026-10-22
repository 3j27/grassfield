#include <gtest/gtest.h>

#include "core/Tiling.hpp"

using namespace gf::tiling;

namespace {
    // GF-REF in the nested layout: 1920x1080 at (1440, 0), menu bar 24, Dock 82; WAYLAND-1 sits on its left.
    const Output kOutput{Rect{1440, 0, 1920, 1080}, 24, false, true};
    const Rect   kArea{1440, 24, 1920, 974};
    const Rect   kWindow{2000, 300, 800, 500};
    constexpr double kBar = 32;

    std::optional<Place> at(double x, double y, Output o = kOutput, DragOptions opt = {}) {
        return placeForPointer(x, y, o, opt);
    }
}

TEST(TilingDrag, FreeSideEdgeIsAHalfAndItsCornersAreQuarters) {
    EXPECT_EQ(at(3359, 540), Place::Right);
    EXPECT_EQ(at(3356, 540), Place::Right) << "within kEdge of the edge";
    EXPECT_EQ(at(3359, 50), Place::TopRight);
    EXPECT_EQ(at(3359, 1070), Place::BottomRight);
    EXPECT_EQ(at(3359, 1080 - 1 - kCorner), Place::BottomRight);
    EXPECT_EQ(at(3359, 1080 - 2 - kCorner), Place::Right);
    EXPECT_FALSE(at(3350, 540).has_value()) << "not at the edge yet";
}

TEST(TilingDrag, ASharedEdgeLeadsToTheNextOutputAndNeverTiles) {
    EXPECT_FALSE(at(1440, 540).has_value());
    EXPECT_FALSE(at(1441, 1070).has_value());
    Output alone = kOutput;
    alone.leftFree = true;
    EXPECT_EQ(at(1440, 540, alone), Place::Left);
    EXPECT_EQ(at(1442, 10, alone), Place::TopLeft) << "a side corner wins over the menu bar";
}

TEST(TilingDrag, TheMenuBarFillsAndTheOptionsTurnEachOff) {
    EXPECT_EQ(at(2400, 0), Place::Fill);
    EXPECT_EQ(at(2400, 23), Place::Fill);
    EXPECT_FALSE(at(2400, 24).has_value());
    EXPECT_FALSE(at(2400, 0, kOutput, DragOptions{true, false}).has_value());
    EXPECT_EQ(at(3359, 540, kOutput, DragOptions{true, false}), Place::Right);
    EXPECT_FALSE(at(3359, 540, kOutput, DragOptions{false, true}).has_value());
    EXPECT_EQ(at(3359, 10, kOutput, DragOptions{false, true}), Place::Fill) << "edges off: the menu bar still fills";
    EXPECT_FALSE(at(1439, 540).has_value()) << "another output";
    EXPECT_FALSE(at(2400, 1080).has_value());
}

TEST(TilingPlace, HalvesAndQuartersSplitTheFreeAreaWithMargins) {
    const auto left  = surfaceFor(Place::Left, kArea, kBar, true, kWindow);
    const auto right = surfaceFor(Place::Right, kArea, kBar, true, kWindow);
    // Frames: margin 8 around and between: (1920 - 24) / 2 = 948 wide each.
    EXPECT_DOUBLE_EQ(left.x, 1448);
    EXPECT_DOUBLE_EQ(left.y, 24 + 8 + kBar);
    EXPECT_DOUBLE_EQ(left.w, 948);
    EXPECT_DOUBLE_EQ(left.h, 974 - 16 - kBar);
    EXPECT_DOUBLE_EQ(right.x, 1440 + 16 + 948);
    EXPECT_DOUBLE_EQ(right.x + right.w + 8, 1440 + 1920) << "the right margin";
    const auto tl = surfaceFor(Place::TopLeft, kArea, kBar, true, kWindow);
    const auto bl = surfaceFor(Place::BottomLeft, kArea, kBar, true, kWindow);
    const auto br = surfaceFor(Place::BottomRight, kArea, kBar, true, kWindow);
    EXPECT_DOUBLE_EQ(tl.x, bl.x);
    EXPECT_DOUBLE_EQ(bl.x + bl.w + 8, br.x) << "8 between the columns";
    EXPECT_DOUBLE_EQ(tl.y - kBar + (tl.h + kBar) + 8, bl.y - kBar) << "8 between the rows, titlebar included";
    EXPECT_DOUBLE_EQ(bl.y + bl.h + 8, 24 + 974) << "the bottom margin";
    const auto top    = surfaceFor(Place::Top, kArea, kBar, true, kWindow);
    const auto bottom = surfaceFor(Place::Bottom, kArea, kBar, true, kWindow);
    EXPECT_DOUBLE_EQ(top.w, 1920 - 16);
    EXPECT_DOUBLE_EQ(bottom.y, bl.y);
}

TEST(TilingPlace, FillAndNoMarginsUseEveryPixel) {
    const auto fill = surfaceFor(Place::Fill, kArea, kBar, false, kWindow);
    EXPECT_DOUBLE_EQ(fill.x, 1440);
    EXPECT_DOUBLE_EQ(fill.y, 24 + kBar) << "the titlebar starts right below the menu bar";
    EXPECT_DOUBLE_EQ(fill.w, 1920);
    EXPECT_DOUBLE_EQ(fill.h, 974 - kBar);
    const auto left  = surfaceFor(Place::Left, kArea, kBar, false, kWindow);
    const auto right = surfaceFor(Place::Right, kArea, kBar, false, kWindow);
    EXPECT_DOUBLE_EQ(left.w + right.w, 1920);
    EXPECT_DOUBLE_EQ(right.x, 1440 + 960);
    const auto frame = frameOf(fill, kBar);
    EXPECT_DOUBLE_EQ(frame.y, 24);
    EXPECT_DOUBLE_EQ(frame.h, 974);
}

TEST(TilingPlace, CenterKeepsTheSizeAndCapsIt) {
    const auto c = surfaceFor(Place::Center, kArea, kBar, true, kWindow);
    EXPECT_DOUBLE_EQ(c.w, 800);
    EXPECT_DOUBLE_EQ(c.h, 500);
    EXPECT_DOUBLE_EQ(c.x, 1440 + (1920 - 800) / 2.0);
    EXPECT_DOUBLE_EQ(c.y - kBar, 24 + (974 - 532) / 2.0);
    const auto big = surfaceFor(Place::Center, kArea, kBar, true, Rect{0, 0, 5000, 5000});
    EXPECT_LE(big.w, 1920 * kCenterMaxFraction);
    EXPECT_LE(big.h + kBar, 974 * kCenterMaxFraction + 1);
    const auto tiny = surfaceFor(Place::TopLeft, Rect{0, 0, 10, 10}, kBar, true, kWindow);
    EXPECT_GE(tiny.w, 1);
    EXPECT_GE(tiny.h, 1);
}

TEST(TilingNames, PlacesAndOptionsParseStrictly) {
    for (const char* name : {"left", "right", "top", "bottom", "top-left", "top-right", "bottom-left", "bottom-right", "fill", "center"}) {
        const auto p = parsePlace(name);
        ASSERT_TRUE(p.has_value()) << name;
        EXPECT_EQ(nameOf(*p), name);
    }
    for (const char* bad : {"", "Left", "left ", "topleft", "maximize", "fill\n"})
        EXPECT_FALSE(parsePlace(bad).has_value()) << bad;
    EXPECT_EQ(parseBool("true"), true);
    EXPECT_EQ(parseBool("false"), false);
    EXPECT_FALSE(parseBool("1").has_value());
    EXPECT_FALSE(parseBool("True").has_value());
}
