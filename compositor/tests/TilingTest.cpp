#include <gtest/gtest.h>

#include "core/Tiling.hpp"

#include <array>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

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
        EXPECT_EQ(nameOf(p.value_or(Place::Center)), name);
    }
    for (const char* bad : {"", "Left", "left ", "topleft", "maximize", "fill\n"})
        EXPECT_FALSE(parsePlace(bad).has_value()) << bad;
    EXPECT_EQ(parseBool("true"), true);
    EXPECT_EQ(parseBool("false"), false);
    EXPECT_FALSE(parseBool("1").has_value());
    EXPECT_FALSE(parseBool("True").has_value());
}

// ---- ADR-0036 step 1: the geometry engine (docs/specs/tiling.md TL1-TL15) ----

namespace {
    // An output of `px` device pixels at `scale` (Hyprland keeps its logical size whole), at the layout origin, with a
    // 24-px menu bar and an 82-px Dock: the work area tiles use.
    Area areaFor(double pxW, double pxH, double scale, double margin) {
        const double w = pxW / scale, h = pxH / scale;
        return Area{Rect{0, 24, w, h - 24 - 82}, margin, Grid{0, 0, gridStep(scale)}};
    }

    bool whole(double v) {
        return std::abs(v - std::round(v)) < 1e-9;
    }

    Placement at(Place place) {
        Placement p;
        p.place = place;
        return p;
    }

    Placement inLayout(std::string_view layout, int zone) {
        Placement p;
        p.layout = std::string{layout};
        p.zone   = zone;
        return p;
    }

    std::vector<Rect> framesOf(std::string_view layoutId, const Area& area) {
        std::vector<Rect> out;
        for (const auto& z : layoutById(layoutId)->zones)
            out.push_back(zoneFrame(z, area));
        return out;
    }
}

TEST(TilingOutputs, AMovedWindowBelongsToTheOutputUnderItsMiddle) {
    // WAYLAND-1 (1440 wide) left of GF-REF (1920 wide), as in the nested session.
    const std::array<Rect, 2> outputs{Rect{0, 0, 1440, 900}, Rect{1440, 0, 1920, 1080}};
    EXPECT_EQ(outputUnder(Rect{1300, 100, 800, 500}, outputs), 1U) << "its middle (1700) is on GF-REF, its top-left is not";
    EXPECT_EQ(outputUnder(Rect{900, 100, 800, 500}, outputs), 0U) << "its middle (1300) is on WAYLAND-1";
    EXPECT_EQ(outputUnder(Rect{1040, 100, 800, 500}, outputs), 1U) << "a middle on the shared edge belongs to the right-hand output";
    EXPECT_FALSE(outputUnder(Rect{300, 900, 800, 400}, outputs).has_value()) << "its middle is below WAYLAND-1: it keeps its Desktop";
    EXPECT_FALSE(outputUnder(Rect{0, 0, 10, 10}, std::span<const Rect>{}).has_value());
}

TEST(TilingOutputs, AnUnmappedWindowIsNeverMoved) {
    // Gate C1: a window that closed or unmapped during a titlebar drag is still alive (its fade-out, or an app that only
    // unmapped it) but has no Desktop and its target no space: the plugin moves nothing (Hyprland would dereference null).
    const WindowFacts live{.mapped = true, .onDesktop = true, .inSpace = true, .floating = true};
    EXPECT_TRUE(movable(live));
    EXPECT_FALSE(movable(WindowFacts{.mapped = false, .onDesktop = true, .inSpace = true, .floating = true}));
    EXPECT_FALSE(movable(WindowFacts{.mapped = true, .onDesktop = false, .inSpace = true, .floating = true})) << "unmapping cleared its Desktop";
    EXPECT_FALSE(movable(WindowFacts{.mapped = true, .onDesktop = true, .inSpace = false, .floating = true})) << "its target left the space";
    EXPECT_TRUE(shouldFollow(live, 1, false));
    EXPECT_FALSE(shouldFollow(live, 1, true)) << "already on that Desktop";
    EXPECT_FALSE(shouldFollow(live, std::nullopt, false)) << "over no output: it keeps its Desktop";
    EXPECT_FALSE(shouldFollow(WindowFacts{.mapped = true, .onDesktop = true, .inSpace = true, .floating = false}, 1, false)) << "tiled by Hyprland's layout";
    EXPECT_FALSE(shouldFollow(WindowFacts{.mapped = false, .onDesktop = false, .inSpace = false, .floating = true}, 1, false)) << "closed during the drag";
}

TEST(TilingGrid, TheStepIsWholeInLogicalAndDevicePixels) {
    EXPECT_EQ(gridStep(1.0), 1);
    EXPECT_EQ(gridStep(2.0), 1);
    EXPECT_EQ(gridStep(1.5), 2);
    EXPECT_EQ(gridStep(2.5), 2);
    EXPECT_EQ(gridStep(160.0 / 120.0), 3);
    EXPECT_EQ(gridStep(1.25), 4);
    EXPECT_EQ(gridStep(1.75), 4);
    EXPECT_EQ(gridStep(1.2), 1) << "step 5: above kMaxGridStep, whole logical px only";
    EXPECT_EQ(gridStep(1.6), 1);
    EXPECT_EQ(gridStep(1.125), 1);
    EXPECT_EQ(gridStep(0.0), 1);
    EXPECT_EQ(gridStep(std::numeric_limits<double>::quiet_NaN()), 1);
    for (double scale : {1.0, 1.25, 160.0 / 120.0, 1.5, 1.75, 2.0}) {
        const int g = gridStep(scale);
        EXPECT_TRUE(whole(g * scale)) << scale;
    }
}

TEST(TilingGrid, NeighboursShareOneEdgeOnWholePixelsAtEveryScale) {
    // Hyprland truncates an xdg window's configured size to whole logical px (Window.cpp:1752-1753): every edge is whole,
    // so no slit opens between neighbours; where the scale has a grid, the edges are whole device px too.
    for (double scale : {1.0, 1.25, 160.0 / 120.0, 1.5, 1.6, 2.0}) {
        const Area a = areaFor(2560, 1440, scale, 0);
        for (std::string_view id : {"left-right", "thirds", "wide-center", "four-columns", "quarters", "stacked-thirds", "wide-left"}) {
            const auto frames = framesOf(id, a);
            for (const auto& f : frames) {
                EXPECT_TRUE(whole(f.x) && whole(f.y) && whole(f.w) && whole(f.h)) << id << " at " << scale;
                if (a.grid.step > 1) {
                    for (double e : {f.x, f.x + f.w}) {
                        if (std::abs(e - a.box.x) > 0.5 && std::abs(e - (a.box.x + a.box.w)) > 0.5) {
                            EXPECT_TRUE(whole(e * scale)) << id << " edge " << e << " at " << scale;
                        }
                    }
                }
            }
            // Without margins the zones meet exactly: the sum of a row's widths is the snapped span.
            for (size_t i = 0; i < frames.size(); ++i) {
                for (size_t j = 0; j < frames.size(); ++j) {
                    const auto& zi = layoutById(id)->zones[i];
                    const auto& zj = layoutById(id)->zones[j];
                    if (zi.x + zi.w == zj.x && zi.y < zj.y + zj.h && zj.y < zi.y + zi.h) {
                        EXPECT_DOUBLE_EQ(frames[i].x + frames[i].w, frames[j].x) << id << " at " << scale;
                    }
                    if (zi.y + zi.h == zj.y && zi.x < zj.x + zj.w && zj.x < zi.x + zi.w) {
                        EXPECT_DOUBLE_EQ(frames[i].y + frames[i].h, frames[j].y) << id << " at " << scale;
                    }
                }
            }
        }
    }
}

TEST(TilingGrid, MarginsAreExactWhenTheStepDividesThem) {
    for (double scale : {1.0, 1.25, 1.5, 2.0}) {
        const Area a      = areaFor(2560, 1440, scale, 8);
        const auto frames = framesOf("thirds", a);
        EXPECT_DOUBLE_EQ(frames[1].x - (frames[0].x + frames[0].w), 8) << scale;
        EXPECT_DOUBLE_EQ(frames[2].x - (frames[1].x + frames[1].w), 8) << scale;
        EXPECT_GE(frames[0].x - a.box.x, 8) << "outer margin " << scale;
        EXPECT_LT(frames[0].x - a.box.x, 8 + a.grid.step) << scale;
        EXPECT_GE(a.box.y + a.box.h - (frames[0].y + frames[0].h), 8) << scale;
        EXPECT_LT(a.box.y + a.box.h - (frames[0].y + frames[0].h), 8 + a.grid.step) << "the Dock ends off the grid at " << scale;
    }
    const Area third = areaFor(2560, 1440, 160.0 / 120.0, 8);
    const auto f     = framesOf("left-right", third);
    const double gap = f[1].x - (f[0].x + f[0].w);
    EXPECT_GE(gap, 8 - 3) << "within one step of the margin at step 3";
    EXPECT_LE(gap, 8 + 3);
}

TEST(TilingFit, AMinimumTakesRoomFromItsNeighbourAsFarAsItsMinimumAllows) {
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    const auto& zones  = layoutById("left-right")->zones;
    const auto  frames = framesOf("left-right", a);
    // The first window needs 1200: its neighbour (minimum 300) gives 240 and the shared edge moves for both.
    std::vector<Constraints> cons{Constraints{.minW = 1200}, Constraints{.minW = 300}};
    auto fit = fitFrames(zones, frames, cons, a);
    EXPECT_DOUBLE_EQ(fit[0].w, 1200);
    EXPECT_DOUBLE_EQ(fit[1].x, 1200);
    EXPECT_DOUBLE_EQ(fit[1].w, 720);
    // The neighbour can give only 60: the first window grows alone over it, from its edge on the border.
    cons[1].minW = 900;
    fit          = fitFrames(zones, frames, cons, a);
    EXPECT_DOUBLE_EQ(fit[1].x, 1020);
    EXPECT_DOUBLE_EQ(fit[1].w, 900);
    EXPECT_DOUBLE_EQ(fit[0].x, 0);
    EXPECT_DOUBLE_EQ(fit[0].w, 1200) << "it overlaps its neighbour";
    // A right-hand window that must grow alone grows leftwards and stays inside the work area.
    std::vector<Constraints> right{Constraints{.minW = 900}, Constraints{.minW = 1500}};
    fit = fitFrames(zones, frames, right, a);
    EXPECT_DOUBLE_EQ(fit[1].x + fit[1].w, 1920);
    EXPECT_DOUBLE_EQ(fit[1].w, 1500);
    // A minimum larger than the work area: the window starts at the work area's edge.
    const std::array<Zone, 1> fill{Zone{0, 0, 12, 12}};
    const std::array<Rect, 1> fillFrame{zoneFrame(fill[0], a)};
    const std::array<Constraints, 1> huge{Constraints{.minW = 2500, .minH = 400}};
    const auto big = fitFrames(fill, fillFrame, huge, a);
    EXPECT_DOUBLE_EQ(big[0].x, 0);
    EXPECT_DOUBLE_EQ(big[0].w, 2500);
}

TEST(TilingGrid, OuterEdgesSnapInsideTheWorkArea) {
    // A work area that starts and ends off the grid (step 4 from the output's origin): the outer edges go inside it.
    const Area a{Rect{1, 25, 1917, 973}, 0, Grid{0, 0, 4}};
    EXPECT_EQ(zoneFrame(Zone{}, a), (Rect{4, 28, 1912, 968}));
    const Area m{Rect{1, 25, 1917, 973}, 6, Grid{0, 0, 4}};
    EXPECT_EQ(zoneFrame(Zone{}, m), (Rect{8, 32, 1904, 960})) << "the margin first, then the grid line inside";
}

TEST(TilingGrid, InnerEdgesGoToTheNearestLine) {
    // Thirds of 1000 px: the boundaries 333.3 and 666.7 go to 333 and 667 (nearest, not down).
    const Area a{Rect{0, 0, 1000, 1000}, 0, Grid{0, 0, 1}};
    const auto thirds = framesOf("thirds", a);
    EXPECT_DOUBLE_EQ(thirds[1].x, 333);
    EXPECT_DOUBLE_EQ(thirds[2].x, 667);
    EXPECT_DOUBLE_EQ(thirds[0].w, 333);
    EXPECT_DOUBLE_EQ(thirds[2].w, 333);
}

TEST(TilingFit, ARightWindowTakesRoomFromItsLeftNeighbour) {
    // Left & Right, the right window needs 1200: the left one gives 240 across their shared edge (no overlap).
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    const auto& zones = layoutById("left-right")->zones;
    const std::vector<Constraints> cons{Constraints{}, Constraints{.minW = 1200}};
    const auto fit = fitFrames(zones, framesOf("left-right", a), cons, a);
    EXPECT_DOUBLE_EQ(fit[0].x, 0);
    EXPECT_DOUBLE_EQ(fit[0].w, 720);
    EXPECT_DOUBLE_EQ(fit[1].x, 720);
    EXPECT_DOUBLE_EQ(fit[1].w, 1200);
}

TEST(TilingFit, AWindowGrowingAloneStaysInsideTheWorkArea) {
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    // The middle third alone (no neighbour placed) needs 1800: it grows to the right, then moves back inside.
    const std::array<Zone, 1> middle{Zone{4, 0, 4, 12}};
    const std::array<Rect, 1> middleFrame{zoneFrame(middle[0], a)};
    const std::array<Constraints, 1> wide{Constraints{.minW = 1800}};
    const auto m = fitFrames(middle, middleFrame, wide, a);
    EXPECT_DOUBLE_EQ(m[0].x, 120);
    EXPECT_DOUBLE_EQ(m[0].x + m[0].w, 1920);
    // The right third alone with a minimum larger than the work area: aligned to its start.
    const std::array<Zone, 1> right{Zone{8, 0, 4, 12}};
    const std::array<Rect, 1> rightFrame{zoneFrame(right[0], a)};
    const std::array<Constraints, 1> huge{Constraints{.minW = 2000}};
    const auto r = fitFrames(right, rightFrame, huge, a);
    EXPECT_DOUBLE_EQ(r[0].x, 0);
    EXPECT_DOUBLE_EQ(r[0].w, 2000);
    // With margins: a right window that must grow alone keeps its margin to the work area's right edge.
    const Area margins{Rect{0, 0, 1920, 1000}, 8, Grid{0, 0, 1}};
    const auto& zones = layoutById("left-right")->zones;
    const std::vector<Constraints> cons{Constraints{.minW = 900}, Constraints{.minW = 1500}};
    const auto fit = fitFrames(zones, framesOf("left-right", margins), cons, margins);
    EXPECT_DOUBLE_EQ(fit[1].w, 1500);
    EXPECT_DOUBLE_EQ(fit[1].x + fit[1].w, 1912) << "the margin stays";
}

TEST(TilingFit, TheOtherQuarterFollowsTheSharedEdge) {
    // Left & Quarters, the top-right window needs 1200: the left half gives 240 and the bottom-right quarter follows the
    // shared edge, so no hole opens beside it (review of 3831dc0).
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    const auto& zones = layoutById("left-quarters")->zones;
    const std::vector<Constraints> cons{Constraints{}, Constraints{.minW = 1200}, Constraints{}};
    const auto fit = fitFrames(zones, framesOf("left-quarters", a), cons, a);
    EXPECT_DOUBLE_EQ(fit[0].w, 720);
    EXPECT_DOUBLE_EQ(fit[1].x, 720);
    EXPECT_DOUBLE_EQ(fit[1].w, 1200);
    EXPECT_DOUBLE_EQ(fit[2].x, 720) << "no hole between the left half and the bottom-right quarter";
    EXPECT_DOUBLE_EQ(fit[2].w, 1200);
    // Quarters: the top-left window's need moves only the top row's shared edge; the bottom row keeps its own.
    const auto& quarters = layoutById("quarters")->zones;
    const std::vector<Constraints> topLeft{Constraints{.minW = 1200}, Constraints{}, Constraints{}, Constraints{}};
    const auto q = fitFrames(quarters, framesOf("quarters", a), topLeft, a);
    EXPECT_DOUBLE_EQ(q[1].x, 1200);
    EXPECT_DOUBLE_EQ(q[2].w, 960);
    EXPECT_DOUBLE_EQ(q[3].x, 960);
}

TEST(TilingFit, AMaximumIsCentredOnTheGrid) {
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 2}};
    const auto& zones = layoutById("left-right")->zones;
    const std::vector<Constraints> cons{Constraints{.maxW = 901}, Constraints{}};
    const auto fit = fitFrames(zones, framesOf("left-right", a), cons, a);
    EXPECT_DOUBLE_EQ(fit[0].w, 901);
    EXPECT_DOUBLE_EQ(fit[0].x, 28) << "29.5 px to centre it, 28 on the grid";
}

TEST(TilingFit, MaximaCentreAndIncrementsRoundDown) {
    const Area a{Rect{0, 0, 1920, 1000}, 0, Grid{0, 0, 1}};
    const auto& zones  = layoutById("left-right")->zones;
    const auto  frames = framesOf("left-right", a);
    std::vector<Constraints> cons{Constraints{.maxW = 500, .maxH = 300, .band = 32}, Constraints{.incW = 10, .incH = 7, .baseW = 2, .baseH = 1, .band = 0}};
    const auto fit = fitFrames(zones, frames, cons, a);
    EXPECT_DOUBLE_EQ(fit[0].w, 500);
    EXPECT_DOUBLE_EQ(fit[0].x, 230) << "centred in its 960-px zone";
    EXPECT_DOUBLE_EQ(fit[0].h, 332) << "the band is added to the surface maximum";
    EXPECT_DOUBLE_EQ(fit[1].x, 960) << "top-left kept";
    EXPECT_DOUBLE_EQ(fit[1].w, 952) << "2 + 95 x 10";
    EXPECT_DOUBLE_EQ(fit[1].h, 995) << "1 + 142 x 7";
}

TEST(TilingNeighbour, AHalfBesideATiledWindowTakesTheRest) {
    const Area a{Rect{0, 24, 1920, 974}, 8, Grid{0, 0, 1}};
    // A window holding the right two thirds (full height): Left takes the rest, one margin before it.
    const Rect twoThirds = zoneFrame(zoneOf(Place::RightTwoThirds).value_or(Zone{}), a);
    const std::array<Rect, 1> neighbours{twoThirds};
    const auto left = halfBesideNeighbour(Place::Left, a, neighbours);
    ASSERT_TRUE(left.has_value());
    const Rect l = left.value_or(Rect{});
    EXPECT_DOUBLE_EQ(l.x, 8);
    EXPECT_DOUBLE_EQ(l.x + l.w + 8, twoThirds.x);
    EXPECT_DOUBLE_EQ(l.h, twoThirds.h);
    // Not full height, or leaving less than a quarter: an exact half.
    const std::array<Rect, 1> quarter{zoneFrame(zoneOf(Place::TopRight).value_or(Zone{}), a)};
    EXPECT_FALSE(halfBesideNeighbour(Place::Left, a, quarter).has_value());
    const std::array<Rect, 1> fill{zoneFrame(zoneOf(Place::Fill).value_or(Zone{}), a)};
    EXPECT_FALSE(halfBesideNeighbour(Place::Left, a, fill).has_value());
    const std::array<Rect, 1> wide{Rect{300, 32, 1612, 958}};
    EXPECT_FALSE(halfBesideNeighbour(Place::Left, a, wide).has_value()) << "it leaves less than a quarter: an exact half";
    // The other sides.
    const std::array<Rect, 1> leftThird{zoneFrame(zoneOf(Place::LeftThird).value_or(Zone{}), a)};
    const auto right = halfBesideNeighbour(Place::Right, a, leftThird);
    ASSERT_TRUE(right.has_value());
    EXPECT_DOUBLE_EQ(right.value_or(Rect{}).x, leftThird[0].x + leftThird[0].w + 8);
    const std::array<Rect, 1> bottom{zoneFrame(zoneOf(Place::Bottom).value_or(Zone{}), a)};
    const auto top = halfBesideNeighbour(Place::Top, a, bottom);
    ASSERT_TRUE(top.has_value());
    const Rect t = top.value_or(Rect{});
    EXPECT_DOUBLE_EQ(t.y + t.h + 8, bottom[0].y);
    EXPECT_FALSE(halfBesideNeighbour(Place::Fill, a, bottom).has_value()) << "halves only";
}

TEST(TilingNeighbour, TheNearestNeighbourWins) {
    const Area a{Rect{0, 24, 1920, 974}, 8, Grid{0, 0, 1}};
    // Two windows hold the right side, the nearer one first: Left stops one margin before the nearer one.
    const std::array<Rect, 2> right{Rect{1100, 32, 812, 958}, Rect{1300, 32, 612, 958}};
    const auto left = halfBesideNeighbour(Place::Left, a, right);
    ASSERT_TRUE(left.has_value());
    EXPECT_DOUBLE_EQ(left.value_or(Rect{}).x + left.value_or(Rect{}).w, 1092);
    const std::array<Rect, 2> leftSide{Rect{8, 32, 800, 958}, Rect{8, 32, 600, 958}};
    const auto rightHalf = halfBesideNeighbour(Place::Right, a, leftSide);
    ASSERT_TRUE(rightHalf.has_value());
    EXPECT_DOUBLE_EQ(rightHalf.value_or(Rect{}).x, 816);
    const std::array<Rect, 2> below{Rect{8, 600, 1904, 390}, Rect{8, 700, 1904, 290}};
    const auto top = halfBesideNeighbour(Place::Top, a, below);
    ASSERT_TRUE(top.has_value());
    EXPECT_DOUBLE_EQ(top.value_or(Rect{}).y + top.value_or(Rect{}).h, 592);
    const std::array<Rect, 2> above{Rect{8, 32, 1904, 400}, Rect{8, 32, 1904, 300}};
    const auto bottom = halfBesideNeighbour(Place::Bottom, a, above);
    ASSERT_TRUE(bottom.has_value());
    EXPECT_DOUBLE_EQ(bottom.value_or(Rect{}).y, 440);
}

TEST(TilingCenter, KeepsTheSizeOnTheGrid) {
    const Area a{Rect{0, 24, 2048, 1046}, 8, Grid{0, 0, 4}};
    const auto c = centerFrame(Rect{100, 100, 801, 500}, 32, a);
    EXPECT_DOUBLE_EQ(c.w, 801);
    EXPECT_DOUBLE_EQ(c.h, 532);
    EXPECT_EQ(static_cast<long>(c.x) % 4, 0);
    EXPECT_EQ(static_cast<long>(c.y) % 4, 0);
}

TEST(TilingCatalogue, ClassesNameLayoutsThatTileTheWholeArea) {
    EXPECT_EQ(classify(1920, 1080), OutputClass::Large);
    EXPECT_EQ(classify(1366, 768), OutputClass::Small);
    EXPECT_EQ(classify(1728, 1117), OutputClass::Small);
    EXPECT_EQ(classify(3440, 1440), OutputClass::UltraWide);
    EXPECT_EQ(classify(2560, 1080), OutputClass::UltraWide);
    EXPECT_EQ(classify(1080, 1920), OutputClass::Portrait);
    EXPECT_EQ(classify(0, 0), OutputClass::Small);
    // The ultra-wide boundary is the 21:9 aspect itself, whatever the width.
    EXPECT_EQ(classify(2520, 1080), OutputClass::UltraWide) << "exactly 21:9";
    EXPECT_EQ(classify(2510, 1080), OutputClass::Large) << "just under 21:9";
    EXPECT_EQ(classify(1800, 760), OutputClass::UltraWide) << "narrower than the large class, still 21:9";
    EXPECT_EQ(classify(1919, 1080), OutputClass::Small);
    EXPECT_EQ(classify(1000, 1000), OutputClass::Small) << "square is not portrait";
    for (OutputClass c : {OutputClass::Small, OutputClass::Large, OutputClass::UltraWide, OutputClass::Portrait}) {
        EXPECT_FALSE(layoutsFor(c).empty()) << nameOf(c);
        for (std::string_view id : layoutsFor(c))
            EXPECT_NE(layoutById(id), nullptr) << id;
    }
    for (const auto& l : catalogue()) {
        ASSERT_GE(l.zones.size(), 1U) << l.id;
        ASSERT_LE(l.zones.size(), kMaxZones) << l.id;
        int cells = 0;
        for (size_t i = 0; i < l.zones.size(); ++i) {
            const auto& z = l.zones[i];
            EXPECT_TRUE(z.x >= 0 && z.y >= 0 && z.w > 0 && z.h > 0 && z.x + z.w <= kZoneGrid && z.y + z.h <= kZoneGrid) << l.id;
            cells += z.w * z.h;
            for (size_t j = i + 1; j < l.zones.size(); ++j) {
                const auto& o = l.zones[j];
                EXPECT_FALSE(z.x < o.x + o.w && o.x < z.x + z.w && z.y < o.y + o.h && o.y < z.y + z.h) << l.id << " zones overlap";
            }
        }
        EXPECT_EQ(cells, kZoneGrid * kZoneGrid) << l.id << " leaves a hole";
    }
    EXPECT_EQ(layoutById("nope"), nullptr);
}

TEST(TilingNames, TheThirdsArePlaces) {
    for (const char* name : {"left-third", "middle-third", "right-third", "left-two-thirds", "right-two-thirds"}) {
        const auto p = parsePlace(name);
        ASSERT_TRUE(p.has_value()) << name;
        EXPECT_EQ(nameOf(p.value_or(Place::Center)), name);
        EXPECT_TRUE(zoneOf(p.value_or(Place::Center)).has_value());
    }
    EXPECT_EQ(zoneOf(Place::RightTwoThirds), (Zone{4, 0, 8, 12}));
    EXPECT_FALSE(zoneOf(Place::Center).has_value());
}

TEST(TilingRecord, TheStateMachineKeepsTheBoxFromBefore) {
    CTileBook book;
    const Rect before{100, 100, 800, 500}, half{0, 56, 960, 942}, quarter{0, 56, 960, 455};
    const auto g0 = book.generation();
    const auto& r = book.placed(1, before, half, 32, at(Place::Left), "A", 1, 0);
    EXPECT_EQ(r.state, TileState::Tiled);
    EXPECT_EQ(r.before, before);
    EXPECT_GT(book.generation(), g0);
    // A later tiling keeps the box from before the first.
    book.placed(1, half, quarter, 32, at(Place::TopLeft), "A", 1, 0);
    EXPECT_EQ(book.find(1)->before, before);
    EXPECT_TRUE(book.check(1, quarter));
    // A drag away: Moving with the box from before; a release elsewhere forgets it.
    EXPECT_EQ(book.beginMove(1), before);
    EXPECT_EQ(book.find(1)->state, TileState::Moving);
    EXPECT_TRUE(book.check(1, Rect{5, 5, 800, 500})) << "a moving window is not checked";
    book.endMove(1);
    EXPECT_EQ(book.find(1), nullptr);
    // A release in a zone after a move keeps the box from before.
    book.placed(2, before, half, 32, at(Place::Left), "A", 1, 0);
    book.beginMove(2);
    book.placed(2, Rect{300, 300, 800, 500}, quarter, 32, at(Place::TopLeft), "A", 1, 0);
    EXPECT_EQ(book.find(2)->before, before);
    EXPECT_EQ(book.find(2)->state, TileState::Tiled);
    // A user resize keeps the record and updates the box.
    EXPECT_TRUE(book.beginResize(2));
    EXPECT_TRUE(book.check(2, Rect{0, 0, 1, 1})) << "a resizing window is not checked";
    book.endResize(2, Rect{0, 56, 1000, 455});
    EXPECT_EQ(book.find(2)->state, TileState::Tiled);
    EXPECT_EQ(book.find(2)->before, before);
    EXPECT_TRUE(book.check(2, Rect{0.5, 56, 1000, 455})) << "1 px slack";
    // Something else moved it: Free.
    EXPECT_FALSE(book.check(2, Rect{50, 56, 1000, 455}));
    EXPECT_EQ(book.find(2), nullptr);
    EXPECT_FALSE(book.check(99, before)) << "no record";
    // Suspended windows keep their record; Return to Previous Size gives the box from before and frees it.
    book.placed(3, before, half, 32, at(Place::Left), "A", 1, 0);
    EXPECT_TRUE(book.suspend(3));
    EXPECT_TRUE(book.check(3, Rect{-5000, 0, 10, 10}));
    EXPECT_FALSE(book.suspend(3));
    ASSERT_NE(book.resume(3), nullptr);
    EXPECT_EQ(book.resume(3), nullptr) << "not Suspended any more";
    EXPECT_EQ(book.takeBefore(3), before);
    EXPECT_EQ(book.find(3), nullptr);
    EXPECT_FALSE(book.beginMove(42).has_value());
}

TEST(TilingRecord, GroupsAndFreeZones) {
    CTileBook book;
    const auto group = book.newGroup();
    const Rect left{8, 64, 948, 926}, right{964, 64, 948, 926};
    book.placed(1, Rect{0, 0, 10, 10}, left, 32, inLayout("left-right", 0), "A", 1, group);
    book.placed(2, Rect{0, 0, 10, 10}, right, 32, inLayout("left-right", 1), "A", 1, group);
    EXPECT_EQ(book.find(1)->group, group);
    EXPECT_EQ(book.find(2)->group, group);
    // A resize keeps both in the group; a drag away dissolves a group of one.
    book.beginResize(1);
    book.endResize(1, Rect{8, 64, 900, 926});
    EXPECT_EQ(book.find(2)->group, group);
    book.beginMove(1);
    EXPECT_EQ(book.find(1)->group, 0U);
    EXPECT_EQ(book.find(2)->group, 0U) << "a group of one dissolves";
    // Free zones: only Tiled and Resizing windows of that output and Desktop count, with more than 1 px of overlap.
    const Rect rightFrame = frameOf(right, 32);
    EXPECT_FALSE(book.zoneFree(rightFrame, "A", 1, 0));
    EXPECT_TRUE(book.zoneFree(rightFrame, "A", 1, 2)) << "itself excepted";
    EXPECT_TRUE(book.zoneFree(rightFrame, "B", 1, 0));
    EXPECT_TRUE(book.zoneFree(rightFrame, "A", 2, 0));
    EXPECT_TRUE(book.zoneFree(Rect{rightFrame.x + rightFrame.w - 1, rightFrame.y, 100, 100}, "A", 1, 0)) << "1 px is not an overlap";
    const std::array<uint64_t, 1> inStrip{2};
    EXPECT_TRUE(book.zoneFree(rightFrame, "A", 1, 0, inStrip)) << "an inactive stage's window does not hold its zone";
    book.suspend(2);
    EXPECT_TRUE(book.zoneFree(rightFrame, "A", 1, 0)) << "a suspended window does not hold its zone";
    book.clear();
    EXPECT_TRUE(book.records().empty());
}

TEST(TilingRecord, MoveToDesktopAndALostOutput) {
    CTileBook book;
    const Rect before{100, 100, 800, 500}, half{8, 64, 948, 926};
    book.placed(1, before, half, 32, at(Place::Left), "A", 1, 0);
    // Move to Desktop: the state and the box stay, the zone now counts on the new Desktop.
    const auto g = book.generation();
    book.setWorkspace(1, 4);
    EXPECT_GT(book.generation(), g);
    EXPECT_EQ(book.find(1)->workspace, 4);
    EXPECT_EQ(book.find(1)->state, TileState::Tiled);
    EXPECT_FALSE(book.zoneFree(frameOf(half, 32), "A", 4, 0));
    EXPECT_TRUE(book.zoneFree(frameOf(half, 32), "A", 1, 0));
    // Its output went away and Hyprland moved it: not checked until it is placed again.
    book.markRelayout(1, true);
    EXPECT_TRUE(book.check(1, Rect{2000, 64, 948, 926}));
    book.setBox(1, Rect{1928, 64, 948, 926}, "B");
    EXPECT_FALSE(book.find(1)->relayout);
    EXPECT_EQ(book.find(1)->output, "B");
    EXPECT_FALSE(book.check(1, Rect{2000, 64, 948, 926})) << "checked again once placed";
}

TEST(TilingRecord, ADeferredRecordIsStillChecked) {
    // The margins changed while the window could not be placed (an inactive stage): it waits to be placed again, but a
    // window the user moved meanwhile is Free (its box is still the one the plugin gave it).
    CTileBook  book;
    const Rect half{8, 64, 948, 926};
    book.placed(1, Rect{100, 100, 800, 500}, half, 32, at(Place::Left), "A", 1, 0);
    book.markDeferred(1, true);
    EXPECT_TRUE(book.find(1)->deferred);
    EXPECT_TRUE(book.check(1, half));
    book.setBox(1, Rect{0, 56, 960, 942}, "A");
    EXPECT_FALSE(book.find(1)->deferred) << "placed again";
    book.markDeferred(1, true);
    book.placed(1, half, half, 32, at(Place::Left), "A", 1, 0);
    EXPECT_FALSE(book.find(1)->deferred) << "tiled again";
    book.markDeferred(1, true);
    EXPECT_FALSE(book.check(1, Rect{300, 300, 948, 926})) << "moved by the user meanwhile: Free";
    EXPECT_EQ(book.find(1), nullptr);
}

TEST(TilingRecord, ASuspendedMemberKeepsItsGroupAlive) {
    CTileBook  book;
    const auto group = book.newGroup();
    const Rect any{0, 0, 10, 10};
    book.placed(1, any, any, 0, inLayout("thirds", 0), "A", 1, group);
    book.placed(2, any, any, 0, inLayout("thirds", 1), "A", 1, group);
    book.placed(3, any, any, 0, inLayout("thirds", 2), "A", 1, group);
    book.suspend(3);
    book.beginMove(1);
    EXPECT_EQ(book.find(2)->group, group) << "one Tiled and one Suspended member: the group lives";
    EXPECT_EQ(book.find(3)->group, group);
    book.forget(2);
    EXPECT_EQ(book.find(3)->group, 0U) << "a Suspended member alone: dissolved";
}

TEST(TilingArrange, TheSizeLimitIsExact) {
    const std::string body = R"("layout":"quarters","windows":["1"]})";
    const auto padded = [&body](size_t total) { return "{" + std::string(total - 1 - body.size(), ' ') + body; };
    ASSERT_EQ(padded(kMaxArrangeBytes).size(), kMaxArrangeBytes);
    EXPECT_TRUE(parseArrange(padded(kMaxArrangeBytes)).has_value());
    EXPECT_FALSE(parseArrange(padded(kMaxArrangeBytes + 1)).has_value());
}

TEST(TilingArrange, RequestsAreStrict) {
    const auto ok = parseArrange(R"({"layout":"left-quarters","windows":["0x1a2b","3c"],"output":"GF-REF"})");
    ASSERT_TRUE(ok.has_value()) << ok.error();
    EXPECT_EQ(ok->layout, "left-quarters");
    EXPECT_EQ(ok->windows, (std::vector<uint64_t>{0x1a2b, 0x3c}));
    EXPECT_TRUE(ok->fill);
    EXPECT_EQ(ok->output, "GF-REF");
    const auto zone = parseArrange(R"({"layout":"thirds","zone":2,"windows":["0x9"]})");
    ASSERT_TRUE(zone.has_value()) << zone.error();
    EXPECT_EQ(zone->zone, 2);
    EXPECT_FALSE(zone->fill);
    const auto noFill = parseArrange(R"({ "layout" : "quarters", "windows" : ["1"], "fill" : false, "unknown": {"a":[1]} })");
    ASSERT_TRUE(noFill.has_value()) << noFill.error();
    EXPECT_FALSE(noFill->fill);
    for (const char* bad : {
             "", "[]", "{}", R"({"layout":"nope","windows":["1"]})", R"({"layout":"left-right"})", R"({"layout":"left-right","windows":[]})",
             R"({"layout":"left-right","windows":["1","2","3"]})", R"({"layout":"quarters","windows":["1","1"]})", R"({"layout":"quarters","windows":["0"]})",
             R"({"layout":"quarters","windows":["xyz"]})", R"({"layout":"quarters","windows":["1","2","3","4","5"]})", R"({"layout":"thirds","zone":3,"windows":["1"]})",
             R"({"layout":"thirds","zone":1,"windows":["1","2"]})", R"({"layout":"thirds","zone":1,"fill":true,"windows":["1"]})", R"({"layout":"thirds","zone":1.5,"windows":["1"]})",
             R"({"layout":"thirds","zone":-1,"windows":["1"]})", R"({"layout":"thirds","windows":["1"],"output":"bad name"})", R"({"layout":"thirds","windows":["1"],"output":""})",
             R"({"layout":"thirds","windows":["1"]} x)", R"({"layout":"thirds","layout":"thirds","windows":["1"]})", R"({"layout":"thirds","windows":["1"],"fill":1})"}) {
        EXPECT_FALSE(parseArrange(bad).has_value()) << bad;
    }
    EXPECT_FALSE(parseArrange(std::string(kMaxArrangeBytes + 1, ' ')).has_value());
}

TEST(TilingJson, TheNoticeIsSmallAndTheStateIsAReply) {
    EXPECT_EQ(noticeJson(7, Reason::Placed), R"({"v":"gfc/1","type":"tiling","gen":7,"reason":"placed"})");
    EXPECT_EQ(noticeJson(0, Reason::None), R"({"v":"gfc/1","type":"tiling","gen":0})");
    CTileBook book;
    book.placed(0xabc, Rect{1, 2, 3, 4}, Rect{8, 64, 948, 926}, 32, at(Place::Left), "GF-REF", 2, 0);
    book.placed(0xdef, Rect{1, 2, 3, 4}, Rect{964, 64, 948, 926}, 0, inLayout("left-right", 1), "GF-REF", 2, 0);
    StateOutput o{.name = "GF-REF", .area = Rect{0, 24, 1920, 974}, .outputClass = OutputClass::Large, .grid = 1, .windows = {}};
    for (const auto& r : book.records())
        o.windows.push_back(&r);
    const std::array<StateOutput, 1> outputs{o};
    EXPECT_EQ(stateJson(3, outputs),
              R"({"v":"gfc/1","type":"tiling","gen":3,"outputs":[{"name":"GF-REF","area":{"x":0,"y":24,"w":1920,"h":974},"class":"large","grid":1,"windows":[)"
              R"({"address":"abc","state":"tiled","place":"left","layout":"","zone":-1,"sides":"","group":0,"x":8,"y":64,"w":948,"h":926},)"
              R"({"address":"def","state":"tiled","place":"","layout":"left-right","zone":1,"sides":"","group":0,"x":964,"y":64,"w":948,"h":926}]}]})");
    Placement edge;
    edge.sides = kSideTop | kSideLeft;
    CTileBook edges;
    edges.placed(0x1, Rect{1, 2, 3, 4}, Rect{8, 64, 400, 300}, 32, edge, "GF-REF", 2, 0);
    StateOutput e{.name = "GF-REF", .area = Rect{0, 24, 1920, 974}, .outputClass = OutputClass::Large, .grid = 1, .windows = {&edges.records().front()}};
    EXPECT_NE(stateJson(4, std::array<StateOutput, 1>{e}).find(R"("place":"","layout":"","zone":-1,"sides":"top-left","group":0)"), std::string::npos)
        << "an edge double-click's record names its sides";
    for (Reason r : {Reason::Placed, Reason::Moved, Reason::Resized, Reason::Suspended, Reason::Restored, Reason::Forgotten, Reason::Relaid, Reason::Invalid,
                     Reason::Locked, Reason::Unavailable})
        EXPECT_FALSE(reasonName(r).empty());
    EXPECT_EQ(noticeJson(9, Reason::Locked), R"({"v":"gfc/1","type":"tiling","gen":9,"reason":"locked"})");
    EXPECT_EQ(noticeJson(std::numeric_limits<uint64_t>::max(), Reason::Unavailable).size(), 79U) << "the bound ADR-0007 states";
}

// ---- step 2: drags (TL17, TL18, TL20) ----

TEST(TilingAltDrag, ThirdsOfTheWorkAreaGiveTheNearestTile) {
    // kArea: thirds at x 2080 and 2720, y 348.7 and 673.3; the middle at x 2400.
    EXPECT_EQ(placeForAltPointer(1500, 100, kArea), Place::TopLeft);
    EXPECT_EQ(placeForAltPointer(2400, 100, kArea), Place::Fill);
    EXPECT_EQ(placeForAltPointer(3300, 100, kArea), Place::TopRight);
    EXPECT_EQ(placeForAltPointer(1500, 500, kArea), Place::Left);
    EXPECT_EQ(placeForAltPointer(3300, 500, kArea), Place::Right);
    EXPECT_EQ(placeForAltPointer(2399, 500, kArea), Place::Left) << "the centre: the half on the pointer's side";
    EXPECT_EQ(placeForAltPointer(2400, 500, kArea), Place::Right);
    EXPECT_EQ(placeForAltPointer(1500, 900, kArea), Place::BottomLeft);
    EXPECT_EQ(placeForAltPointer(3300, 900, kArea), Place::BottomRight);
    EXPECT_EQ(placeForAltPointer(2399, 900, kArea), Place::Left) << "bottom middle: the half on the pointer's side";
    EXPECT_EQ(placeForAltPointer(2400, 900, kArea), Place::Right);
    EXPECT_EQ(placeForAltPointer(2079, 300, kArea), Place::TopLeft);
    EXPECT_EQ(placeForAltPointer(2080, 300, kArea), Place::Fill) << "the cell boundary belongs to the next cell";
    EXPECT_EQ(placeForAltPointer(2400, 348, kArea), Place::Fill);
    EXPECT_EQ(placeForAltPointer(2400, 349, kArea), Place::Right);
    EXPECT_EQ(placeForAltPointer(2400, 5, kArea), Place::Fill) << "on the menu bar, above the area: the top row";
    EXPECT_EQ(placeForAltPointer(1500, 1050, kArea), Place::BottomLeft) << "over the Dock, below the area: the bottom row";
}

TEST(TilingAltDrag, AltWinsOverTheEdgeSettingsAndNeedsItsOwnSetting) {
    EXPECT_EQ(dragPlace(2400, 500, kOutput, kArea, DragOptions{}, true), Place::Right);
    EXPECT_FALSE(dragPlace(2400, 500, kOutput, kArea, DragOptions{}, false).has_value()) << "without Alt: the edges only";
    EXPECT_EQ(dragPlace(3359, 540, kOutput, kArea, DragOptions{}, false), Place::Right);
    EXPECT_EQ(dragPlace(1500, 900, kOutput, kArea, DragOptions{false, false, true}, true), Place::BottomLeft) << "edges and menu bar off";
    EXPECT_FALSE(dragPlace(2400, 500, kOutput, kArea, DragOptions{true, true, false}, true).has_value()) << "the Alt drag setting off";
    EXPECT_EQ(dragPlace(3359, 540, kOutput, kArea, DragOptions{true, true, false}, true), Place::Right) << "then Alt changes nothing";
    EXPECT_FALSE(dragPlace(1439, 500, kOutput, kArea, DragOptions{}, true).has_value()) << "off the output";
    EXPECT_FALSE(dragPlace(2400, 500, kOutput, Rect{}, DragOptions{}, true).has_value()) << "no work area: the edges only";
}

TEST(TilingDwell, ThePreviewWaitsForTheDelayOnOnePlace) {
    ASSERT_GT(kPreviewDelay, 1U);
    CDwell d;
    EXPECT_FALSE(d.remaining(0).has_value()) << "no place";
    EXPECT_FALSE(d.update(Place::Left, "A", 1000, false));
    EXPECT_EQ(d.remaining(1000), kPreviewDelay);
    EXPECT_FALSE(d.update(Place::Left, "A", 1000 + kPreviewDelay - 1, false));
    EXPECT_EQ(d.remaining(1000 + kPreviewDelay - 1), 1U);
    EXPECT_FALSE(d.shown());
    EXPECT_TRUE(d.update(Place::Left, "A", 1000 + kPreviewDelay, false));
    EXPECT_TRUE(d.shown());
    EXPECT_FALSE(d.remaining(1000 + kPreviewDelay).has_value()) << "shown: nothing to wait for";
    EXPECT_TRUE(d.update(Place::Left, "A", 5000, false)) << "it stays shown while the pointer stays";
    EXPECT_FALSE(d.update(Place::Right, "A", 5001, false)) << "another place starts over";
    EXPECT_EQ(d.remaining(5001), kPreviewDelay);
    EXPECT_FALSE(d.update(Place::Right, "B", 5002 + kPreviewDelay, false)) << "the same place on another output starts over";
    EXPECT_EQ(d.remaining(5002 + kPreviewDelay), kPreviewDelay);
    EXPECT_FALSE(d.update(std::nullopt, "", 9000, true)) << "no place: hidden at once, even with Alt";
    EXPECT_FALSE(d.shown());
    EXPECT_FALSE(d.remaining(9000).has_value());
    EXPECT_FALSE(d.update(Place::Left, "A", 9001, false)) << "back on a place: the delay again";
    EXPECT_EQ(d.remaining(9010), kPreviewDelay - 9);
    EXPECT_EQ(d.remaining(9001 + 2 * kPreviewDelay), 0U) << "overdue: due now";
}

TEST(TilingDwell, AltShowsAtOnce) {
    CDwell d;
    EXPECT_TRUE(d.update(Place::Fill, "A", 100, true));
    EXPECT_FALSE(d.update(Place::Left, "A", 101, false));
    EXPECT_TRUE(d.update(Place::Left, "A", 102, true)) << "Alt pressed while waiting";
    EXPECT_TRUE(d.update(Place::Left, "A", 103, false)) << "released: still shown";
    d.reset();
    EXPECT_FALSE(d.shown());
    EXPECT_FALSE(d.remaining(104).has_value());
    EXPECT_FALSE(d.update(Place::Left, "A", 104, false)) << "after a reset, the same place waits again";
}

TEST(TilingSides, ABorderPressGripsTheSidesItIsBeyond) {
    const Rect s{2000, 300, 800, 500};
    EXPECT_EQ(sidesAt(1995, 500, s), kSideLeft);
    EXPECT_EQ(sidesAt(2805, 500, s), kSideRight);
    EXPECT_EQ(sidesAt(2800, 500, s), kSideRight) << "the box's right edge is outside it";
    EXPECT_EQ(sidesAt(2400, 295, s), kSideTop);
    EXPECT_EQ(sidesAt(2400, 805, s), kSideBottom);
    EXPECT_EQ(sidesAt(2400, 800, s), kSideBottom);
    EXPECT_EQ(sidesAt(1995, 295, s), kSideLeft | kSideTop);
    EXPECT_EQ(sidesAt(2805, 805, s), kSideRight | kSideBottom);
    EXPECT_EQ(sidesAt(2005, 305, s), kSideLeft | kSideTop) << "inside, in a rounded corner: its quadrant's corner";
    EXPECT_EQ(sidesAt(2795, 305, s), kSideRight | kSideTop);
    EXPECT_EQ(sidesAt(2005, 795, s), kSideLeft | kSideBottom);
    EXPECT_EQ(sidesAt(2795, 795, s), kSideRight | kSideBottom);
    EXPECT_EQ(sidesAt(2400, 550, s), kSideRight | kSideBottom) << "the middle belongs to the second halves";
}

TEST(TilingSides, AltAddsTheOppositeSides) {
    EXPECT_EQ(extendedSides(kSideLeft, false), kSideLeft);
    EXPECT_EQ(extendedSides(kSideLeft, true), kSideLeft | kSideRight);
    EXPECT_EQ(extendedSides(kSideRight, true), kSideLeft | kSideRight);
    EXPECT_EQ(extendedSides(kSideBottom, true), kSideTop | kSideBottom);
    EXPECT_EQ(extendedSides(kSideTop, true), kSideTop | kSideBottom);
    EXPECT_EQ(extendedSides(kSideTop | kSideLeft, false), kSideTop | kSideLeft);
    EXPECT_EQ(extendedSides(kSideTop | kSideLeft, true), kAllSides) << "Alt on a corner: the whole work area";
    EXPECT_EQ(extendedSides(0xF0, true), 0) << "only the four sides";
    EXPECT_EQ(sidesName(kSideTop | kSideLeft), "top-left");
    EXPECT_EQ(sidesName(kSideLeft | kSideRight), "left-right");
    EXPECT_EQ(sidesName(kSideBottom | kSideRight), "bottom-right");
    EXPECT_EQ(sidesName(kAllSides), "top-bottom-left-right");
    EXPECT_EQ(sidesName(0), "");
}

TEST(TilingExtend, EachSideGoesToTheWorkAreaEdgeInsideTheMargin) {
    const Area area{kArea, kMargin, Grid{1440, 0, 1}};
    const Rect full  = zoneFrame(Zone{}, area);
    ASSERT_EQ(full, (Rect{1448, 32, 1904, 958}));
    const Rect frame = frameOf(kWindow, kBar); // 2000, 268, 800 x 532
    const Constraints c{.band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideLeft, c, area), (Rect{1448, 268, 1352, 532}));
    EXPECT_EQ(extendFrame(frame, kSideRight, c, area), (Rect{2000, 268, 1352, 532}));
    EXPECT_EQ(extendFrame(frame, kSideTop, c, area), (Rect{2000, 32, 800, 768})) << "the titlebar's top reaches the area";
    EXPECT_EQ(extendFrame(frame, kSideBottom, c, area), (Rect{2000, 268, 800, 722}));
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideRight, c, area), (Rect{1448, 268, 1904, 532}));
    EXPECT_EQ(extendFrame(frame, kSideTop | kSideLeft, c, area), (Rect{1448, 32, 1352, 768}));
    EXPECT_EQ(extendFrame(frame, kAllSides, c, area), full);
    EXPECT_EQ(extendFrame(frame, 0, c, area), frame);
    const Area bare{kArea, 0, Grid{1440, 0, 1}};
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideBottom, c, bare), (Rect{1440, 268, 1360, 730})) << "no margins: the area's own edges";
}

TEST(TilingExtend, LimitsKeepTheSideThatDidNotMove) {
    const Area area{kArea, kMargin, Grid{1440, 0, 1}};
    const Rect frame = frameOf(kWindow, kBar);
    const Constraints maxW{.maxW = 1000, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideLeft, maxW, area), (Rect{1800, 268, 1000, 532})) << "the right side stays";
    EXPECT_EQ(extendFrame(frame, kSideRight, maxW, area), (Rect{2000, 268, 1000, 532}));
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideRight, maxW, area), (Rect{1900, 268, 1000, 532})) << "both moved: centred";
    const Constraints maxH{.maxH = 600, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideTop, maxH, area), (Rect{2000, 168, 800, 632})) << "the maximum counts the surface only";
    const Constraints incW{.incW = 10, .baseW = 0, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideLeft, incW, area), (Rect{1450, 268, 1350, 532})) << "increments round down, the right side stays";
    EXPECT_EQ(extendFrame(frame, kSideRight, incW, area), (Rect{2000, 268, 1350, 532}));
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideRight, incW, area), (Rect{1448, 268, 1900, 532})) << "both moved, no maximum: not centred";
    const Constraints incH{.incH = 20, .baseH = 4, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideBottom, incH, area), (Rect{2000, 268, 800, 716})) << "4 + 34 x 20 = 684 of surface";
    const Rect narrow{1460, 268, 100, 532};
    const Constraints minW{.minW = 300, .band = kBar};
    EXPECT_EQ(extendFrame(narrow, kSideLeft, minW, area), (Rect{1260, 268, 300, 532})) << "never smaller than its minimum";
    const Area grid{kArea, 0, Grid{1440, 0, 4}};
    const Constraints odd{.maxW = 1001, .band = kBar};
    EXPECT_EQ(extendFrame(frame, kSideLeft | kSideRight, odd, grid), (Rect{1896, 268, 1001, 532})) << "the centring offset on the grid";
}

TEST(TilingRecord, AnEdgePlacementIsItsOwnPlacement) {
    Placement edge;
    edge.sides = kSideLeft;
    Placement other = edge;
    other.sides     = kSideRight;
    EXPECT_NE(edge, other);
    EXPECT_NE(edge, Placement{});
    CTileBook book;
    const auto& r = book.placed(7, Rect{2000, 300, 800, 500}, Rect{1448, 300, 1352, 500}, 32, edge, "GF-REF", 1, 0);
    EXPECT_EQ(r.where.sides, kSideLeft);
    EXPECT_EQ(r.before, (Rect{2000, 300, 800, 500})) << "Return to Previous Size has a box to go back to";
    EXPECT_EQ(book.takeBefore(7), (Rect{2000, 300, 800, 500}));
}
