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
    const Rect twoThirds = zoneFrame(*zoneOf(Place::RightTwoThirds), a);
    const std::array<Rect, 1> neighbours{twoThirds};
    const auto left = halfBesideNeighbour(Place::Left, a, neighbours);
    ASSERT_TRUE(left.has_value());
    EXPECT_DOUBLE_EQ(left->x, 8);
    EXPECT_DOUBLE_EQ(left->x + left->w + 8, twoThirds.x);
    EXPECT_DOUBLE_EQ(left->h, twoThirds.h);
    // Not full height, or leaving less than a quarter: an exact half.
    const std::array<Rect, 1> quarter{zoneFrame(*zoneOf(Place::TopRight), a)};
    EXPECT_FALSE(halfBesideNeighbour(Place::Left, a, quarter).has_value());
    const std::array<Rect, 1> fill{zoneFrame(*zoneOf(Place::Fill), a)};
    EXPECT_FALSE(halfBesideNeighbour(Place::Left, a, fill).has_value());
    // The other sides.
    const std::array<Rect, 1> leftThird{zoneFrame(*zoneOf(Place::LeftThird), a)};
    const auto right = halfBesideNeighbour(Place::Right, a, leftThird);
    ASSERT_TRUE(right.has_value());
    EXPECT_DOUBLE_EQ(right->x, leftThird[0].x + leftThird[0].w + 8);
    const std::array<Rect, 1> bottom{zoneFrame(*zoneOf(Place::Bottom), a)};
    const auto top = halfBesideNeighbour(Place::Top, a, bottom);
    ASSERT_TRUE(top.has_value());
    EXPECT_DOUBLE_EQ(top->y + top->h + 8, bottom[0].y);
    EXPECT_FALSE(halfBesideNeighbour(Place::Fill, a, bottom).has_value()) << "halves only";
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
        EXPECT_EQ(nameOf(*p), name);
        EXPECT_TRUE(zoneOf(*p).has_value());
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
              R"({"address":"abc","state":"tiled","place":"left","layout":"","zone":-1,"group":0,"x":8,"y":64,"w":948,"h":926},)"
              R"({"address":"def","state":"tiled","place":"","layout":"left-right","zone":1,"group":0,"x":964,"y":64,"w":948,"h":926}]}]})");
    for (Reason r : {Reason::Placed, Reason::Moved, Reason::Resized, Reason::Suspended, Reason::Restored, Reason::Forgotten, Reason::Relaid, Reason::Invalid,
                     Reason::Locked, Reason::Unavailable})
        EXPECT_FALSE(reasonName(r).empty());
    EXPECT_EQ(noticeJson(9, Reason::Locked), R"({"v":"gfc/1","type":"tiling","gen":9,"reason":"locked"})");
}
