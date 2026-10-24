#include "core/Stages.hpp"

#include <gtest/gtest.h>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <optional>
#include <string>
#include <vector>

using namespace gf::stages;

namespace {
    std::vector<WindowId> ids(const Stage& s) {
        return s.windows;
    }

    std::vector<StageId> order(const CWorkspaceStages& ws) {
        std::vector<StageId> out;
        for (const auto& s : ws.stages())
            out.push_back(s.id);
        return out;
    }

    // Three apps, three windows each, stacked back to front a1 b1 c1 a2 b2 c2 a3 b3 c3 (c3 on top).
    std::vector<WindowInfo> nineWindows() {
        std::vector<WindowInfo> out;
        for (int round = 1; round <= 3; ++round) {
            for (const char* app : {"a", "b", "c"})
                out.push_back(WindowInfo{.id = static_cast<WindowId>((app[0] - 'a' + 1) * 0x10 + round), .app = app});
        }
        return out;
    }
} // namespace

// ---- model ----

TEST(StagesModel, ResetGroupsByAppMostRecentFirst) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(nineWindows(), std::nullopt, next);
    ASSERT_EQ(ws.stages().size(), 3U);
    EXPECT_EQ(ws.windowCount(), 9U);
    // The stage of the front window (c3) is active, then b (b3), then a (a3).
    EXPECT_EQ(ids(ws.stages()[0]), (std::vector<WindowId>{0x31, 0x32, 0x33}));
    EXPECT_EQ(ids(ws.stages()[1]), (std::vector<WindowId>{0x21, 0x22, 0x23}));
    EXPECT_EQ(ids(ws.stages()[2]), (std::vector<WindowId>{0x11, 0x12, 0x13}));
    EXPECT_TRUE(ws.isActive(0x32));
    EXPECT_FALSE(ws.isActive(0x12));
}

TEST(StagesModel, ResetMakesTheFocusedWindowsStageActive) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(nineWindows(), WindowId{0x12}, next);
    EXPECT_TRUE(ws.isActive(0x11));
    EXPECT_EQ(ids(ws.stages()[1]), (std::vector<WindowId>{0x31, 0x32, 0x33})) << "the previous front stage leads the strip";
}

TEST(StagesModel, NewWindowOfAnotherAppOpensANewActiveStage) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(nineWindows(), std::nullopt, next);
    const auto before = order(ws);
    EXPECT_TRUE(ws.add(WindowInfo{.id = 0x41, .app = "d"}, next));
    ASSERT_EQ(ws.stages().size(), 4U);
    EXPECT_TRUE(ws.isActive(0x41));
    EXPECT_EQ(order(ws)[1], before[0]) << "the previous active stage goes to the front of the strip";
    EXPECT_FALSE(ws.add(WindowInfo{.id = 0x41, .app = "d"}, next)) << "known";
}

TEST(StagesModel, NewWindowOfAKnownAppJoinsItsStageWhichComesForward) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(nineWindows(), std::nullopt, next);
    const StageId a = ws.stageOf(0x11).value_or(0);
    EXPECT_TRUE(ws.add(WindowInfo{.id = 0x14, .app = "a"}, next));
    EXPECT_EQ(ws.active(), a);
    EXPECT_EQ(ws.stages()[0].windows.back(), 0x14U) << "on top of its stage";
}

TEST(StagesModel, ClosingTheLastActiveWindowActivatesTheMostRecentStripStage) {
    CWorkspaceStages ws;
    StageId          next = 1;
    std::vector<WindowInfo> w{{.id = 1, .app = "a"}, {.id = 2, .app = "b"}, {.id = 3, .app = "c"}};
    ws.reset(w, std::nullopt, next);
    const StageId b = ws.stageOf(2).value_or(0);
    EXPECT_TRUE(ws.remove(3));
    EXPECT_EQ(ws.active(), b);
    EXPECT_EQ(ws.stages().size(), 2U);
    EXPECT_FALSE(ws.remove(3)) << "unknown";
    EXPECT_TRUE(ws.remove(2));
    EXPECT_TRUE(ws.remove(1));
    EXPECT_EQ(ws.active(), 0U);
}

TEST(StagesModel, ActivateSwapsWithTheCurrentStage) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(nineWindows(), std::nullopt, next);
    const auto o = order(ws); // c, b, a
    EXPECT_TRUE(ws.activate(o[2]));
    EXPECT_EQ(order(ws), (std::vector<StageId>{o[2], o[0], o[1]}));
    EXPECT_FALSE(ws.activate(o[2])) << "already active";
    EXPECT_FALSE(ws.activate(999)) << "unknown";
}

TEST(StagesModel, MoveIntoAnotherStageAndOutIntoANewOne) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(nineWindows(), std::nullopt, next);
    const auto o = order(ws); // c (active), b, a
    // Drag a thumbnail of b onto the stage: it joins the active stage.
    EXPECT_TRUE(ws.moveWindow(0x22, o[0], next));
    EXPECT_TRUE(ws.isActive(0x22));
    EXPECT_EQ(ws.stages()[0].windows.back(), 0x22U);
    // Drag a window of the stage out to the strip: a new stage at the front of the strip.
    EXPECT_TRUE(ws.moveWindow(0x31, std::nullopt, next));
    EXPECT_EQ(ws.stages().size(), 4U);
    EXPECT_EQ(ids(ws.stages()[1]), (std::vector<WindowId>{0x31}));
    EXPECT_FALSE(ws.moveWindow(0x31, std::nullopt, next)) << "alone already";
    EXPECT_FALSE(ws.moveWindow(0x31, ws.stageOf(0x31), next)) << "its own stage";
    EXPECT_FALSE(ws.moveWindow(0x99, o[0], next)) << "unknown window";
    EXPECT_FALSE(ws.moveWindow(0x32, 999, next)) << "unknown stage";
}

TEST(StagesModel, MovingTheLastWindowOutOfAStageRemovesIt) {
    CWorkspaceStages ws;
    StageId          next = 1;
    std::vector<WindowInfo> w{{.id = 1, .app = "a"}, {.id = 2, .app = "b"}};
    ws.reset(w, std::nullopt, next); // b active, a in the strip
    const StageId a = ws.stageOf(1).value_or(0), b = ws.stageOf(2).value_or(0);
    EXPECT_TRUE(ws.moveWindow(1, b, next));
    EXPECT_EQ(ws.stages().size(), 1U);
    EXPECT_FALSE(ws.stageOf(1) == a);
}

TEST(StagesModel, MergeGroupsAStripStageIntoTheActiveOne) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(nineWindows(), std::nullopt, next);
    const auto o = order(ws);
    EXPECT_TRUE(ws.merge(o[2]));
    EXPECT_EQ(ws.stages().size(), 2U);
    EXPECT_EQ(ws.stages()[0].windows.size(), 6U);
    EXPECT_TRUE(ws.isActive(0x13));
    EXPECT_FALSE(ws.merge(o[0])) << "the active stage";
    EXPECT_FALSE(ws.merge(o[2])) << "gone";
}

TEST(StagesModel, RaiseWithinAStage) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(nineWindows(), std::nullopt, next);
    EXPECT_TRUE(ws.raise(0x31));
    EXPECT_EQ(ids(ws.stages()[0]), (std::vector<WindowId>{0x32, 0x33, 0x31}));
    EXPECT_FALSE(ws.raise(0x31));
    EXPECT_FALSE(ws.raise(0x99));
}

TEST(StagesModel, AFullWorkspaceLeavesFurtherWindowsUnmanaged) {
    CWorkspaceStages        ws;
    StageId                 next = 1;
    std::vector<WindowInfo> many;
    for (WindowId i = 1; i <= kMaxWindowsPerWorkspace + 3; ++i)
        many.push_back(WindowInfo{.id = i, .app = "x"});
    ws.reset(many, std::nullopt, next);
    EXPECT_EQ(ws.windowCount(), kMaxWindowsPerWorkspace);
    EXPECT_FALSE(ws.add(WindowInfo{.id = 1000, .app = "y"}, next));
    EXPECT_FALSE(ws.contains(1000));
}

TEST(StagesModel, StageIdsAreNeverZeroAndNotReused) {
    CWorkspaceStages ws;
    StageId          next = 0; // wrapped
    ws.add(WindowInfo{.id = 1, .app = "a"}, next);
    ws.add(WindowInfo{.id = 2, .app = "b"}, next);
    EXPECT_NE(ws.stageOf(1).value_or(0), 0U);
    EXPECT_NE(ws.stageOf(1).value_or(0), ws.stageOf(2).value_or(0));
    const StageId first = ws.stageOf(1).value_or(0);
    ws.remove(1);
    ws.add(WindowInfo{.id = 3, .app = "c"}, next);
    EXPECT_NE(ws.stageOf(3).value_or(0), first);
}

// ---- requests ----

TEST(StagesRequest, OnWithStrips) {
    const auto r = parseRequest(
        R"({"op":"on","durationMs":350,"curve":[0.2,0,0,1],"strips":[{"monitor":"GF-REF","hidden":false,"tiles":[{"x":16,"y":120,"w":180,"h":130},{"x":16,"y":270,"w":180,"h":130}]}],"future":{"x":[1,2]}})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_EQ(r->op, Op::On);
    EXPECT_EQ(r->durationMs, 350);
    ASSERT_EQ(r->strips.size(), 1U);
    EXPECT_EQ(r->strips[0].monitor, "GF-REF");
    ASSERT_EQ(r->strips[0].tiles.size(), 2U);
    EXPECT_EQ(r->strips[0].tiles[1], (Box{16, 270, 180, 130}));
}

TEST(StagesRequest, OtherOps) {
    auto r = parseRequest(R"({"op":"off"})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_EQ(r->op, Op::Off);
    r = parseRequest(R"({"op":"activate","stage":7})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_EQ(r->op, Op::Activate);
    EXPECT_EQ(r->stage, 7U);
    r = parseRequest(R"({"op":"merge","stage":4294967295})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_EQ(r->stage, 4294967295U);
    r = parseRequest(R"({"op":"move","address":"0x5f3a","stage":"new"})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_TRUE(r->newStage);
    EXPECT_EQ(r->window, 0x5f3aU);
    r = parseRequest(R"({"op":"move","address":"5f3a","stage":3})");
    ASSERT_TRUE(r) << r.error();
    EXPECT_EQ(r->stage, 3U);
}

TEST(StagesRequest, RefusesMalformedAndOutOfRange) {
    const char* bad[] = {
        "",
        "not json",
        "[]",
        R"({})",
        R"({"op":"dance"})",
        R"({"op":1})",
        R"({"op":"on","durationMs":350})",                                     // no strips
        R"({"op":"on","durationMs":350,"strips":[]})",                         // empty
        R"({"op":"on","strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":100,"h":100}]}]})", // no duration
        R"({"op":"on","durationMs":99999,"strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":100,"h":100}]}]})",
        R"({"op":"on","durationMs":1.5,"strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":100,"h":100}]}]})",
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A B","tiles":[{"x":0,"y":0,"w":100,"h":100}]}]})", // bad name
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[]}]})",
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":10,"h":100}]}]})",   // too small
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":900,"h":100}]}]})",  // too large
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":1e999,"y":0,"w":100,"h":100}]}]})",
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":100,"h":100},{"x":50,"y":50,"w":100,"h":100}]}]})", // overlap
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":100,"h":100}]},{"monitor":"A","tiles":[{"x":0,"y":0,"w":100,"h":100}]}]})", // twice
        R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":0,"y":0,"w":100,"h":100}]}],"stage":3})", // not with on
        R"({"op":"activate"})",
        R"({"op":"activate","stage":0})",
        R"({"op":"activate","stage":-1})",
        R"({"op":"activate","stage":2.5})",
        R"({"op":"activate","stage":4294967296})",
        R"({"op":"activate","stage":"new"})",
        R"({"op":"activate","stage":1,"address":"0x1"})",
        R"({"op":"move","stage":1})",
        R"({"op":"move","address":"0xzz","stage":1})",
        R"({"op":"move","address":"0x1","stage":"old"})",
        R"({"op":"off","durationMs":0,"op":"off"})", // key twice
        R"({"op":"off"} trailing)",
        R"({"op":"off","x":)",
    };
    for (const char* json : bad)
        EXPECT_FALSE(parseRequest(json)) << json;
}

TEST(StagesRequest, PayloadAndCountLimits) {
    std::string big = R"({"op":"off","pad":")" + std::string(kMaxPayloadBytes, 'x') + R"("})";
    EXPECT_FALSE(parseRequest(big));
    std::string tiles;
    for (size_t i = 0; i <= kMaxTiles; ++i)
        tiles += std::string(i ? "," : "") + R"({"x":0,"y":)" + std::to_string(i * 120) + R"(,"w":100,"h":100})";
    EXPECT_FALSE(parseRequest(R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[)" + tiles + "]}]}")) << "more than kMaxTiles";
}

// ---- geometry ----

TEST(StagesGeometry, SingleWindowFitsWithItsTitlebarAndIsCentred) {
    const Box  tile{16, 120, 180, 130};
    const auto r = thumbRects(tile, std::vector<Box>{{500, 300, 700, 500}});
    ASSERT_EQ(r.size(), 1U);
    const double withBar = 500 + kTitlebarHeight; // the surface and the plugin's titlebar above it
    const double s       = std::min(180.0 / 700, 130.0 / withBar);
    EXPECT_NEAR(r[0].w, 700 * s, 1e-9);
    EXPECT_NEAR(r[0].h, 500 * s, 1e-9);
    EXPECT_NEAR(r[0].y - (kTitlebarHeight * s), tile.y + ((130 - (withBar * s)) / 2), 1e-9);
    EXPECT_NEAR(r[0].x + (r[0].w / 2), tile.x + 90, 1e-9) << "centred";
    EXPECT_NEAR(r[0].w / r[0].h, 700.0 / 500.0, 1e-9) << "never distorted";
}

TEST(StagesGeometry, StackedWindowsStepUpLeftAndStayInTheTile) {
    const Box        tile{0, 0, 200, 150};
    std::vector<Box> four(4, Box{0, 0, 700, 500});
    const auto       r = thumbRects(tile, four);
    ASSERT_EQ(r.size(), 4U);
    EXPECT_NEAR(r[3].x - r[2].x, kStackStep, 1e-9) << "the front window is bottom-right";
    EXPECT_NEAR(r[2].x - r[1].x, kStackStep, 1e-9);
    EXPECT_EQ(r[0], r[1]) << "windows further back share the backmost position";
    for (const auto& b : r) {
        EXPECT_GE(b.x, tile.x - 1e-9);
        EXPECT_GE(b.y - (kTitlebarHeight * b.w / 700), tile.y - 1e-9);
        EXPECT_LE(b.x + b.w, tile.x + tile.w + 1e-9);
        EXPECT_LE(b.y + b.h, tile.y + tile.h + 1e-9);
    }
}

TEST(StagesGeometry, SmallWindowsAreNotEnlarged) {
    const auto r = thumbRects(Box{0, 0, 400, 400}, std::vector<Box>{{0, 0, 100, 50}});
    ASSERT_EQ(r.size(), 1U);
    EXPECT_NEAR(r[0].w, 100, 1e-9);
    EXPECT_NEAR(r[0].h, 50, 1e-9);
}

TEST(StagesGeometry, DegenerateSurfacesGetTheSlot) {
    const auto r = thumbRects(Box{0, 0, 100, 100}, std::vector<Box>{{0, 0, 0, 0}});
    ASSERT_EQ(r.size(), 1U);
    EXPECT_EQ(r[0], (Box{0, 0, 100, 100}));
    EXPECT_TRUE(thumbRects(Box{0, 0, 100, 100}, std::vector<Box>{}).empty());
}

TEST(StagesGeometry, HiddenShiftPutsTheStripLeftOfTheMonitor) {
    const std::vector<Box> tiles{{1936, 120, 180, 130}, {1936, 270, 180, 130}};
    const Box              monitor{1920, 0, 1920, 1080};
    const double           dx = hiddenShift(tiles, monitor);
    EXPECT_NEAR(1936 + 180 + dx, 1920 - kHiddenMargin, 1e-9);
    EXPECT_EQ(hiddenShift(std::vector<Box>{}, monitor), 0);
}

TEST(StagesGeometry, TilesMustLieInsideTheStripSurfaceAndTheMonitor) {
    const Box              monitor{0, 0, 1920, 1080};
    const Box              surface{0, 100, 220, 800};
    const std::vector<Box> ok{{16, 120, 180, 130}, {16, 270, 180, 130}};
    EXPECT_TRUE(tilesCovered(ok, surface, monitor));
    EXPECT_FALSE(tilesCovered(std::vector<Box>{{16, 50, 180, 130}}, surface, monitor)) << "above the surface";
    EXPECT_FALSE(tilesCovered(std::vector<Box>{{100, 120, 180, 130}}, surface, monitor)) << "wider than the surface";
    EXPECT_FALSE(tilesCovered(std::vector<Box>{{-50, 120, 180, 130}}, Box{-100, 0, 400, 1000}, monitor)) << "outside the monitor";
    EXPECT_FALSE(tilesCovered(std::vector<Box>{}, surface, monitor));
}

TEST(StagesGeometry, StripBand) {
    const std::vector<Box> tiles{{16, 120, 180, 130}, {16, 270, 180, 130}};
    EXPECT_EQ(stripBand(tiles, 10), (Box{6, 110, 200, 300}));
    EXPECT_EQ(stripBand(std::vector<Box>{}, 10), (Box{}));
}

// ---- the shell's work items (stages.md "Shell side", 2026-10-23) ----

// Work item 3: an op:on update with fewer tiles retargets every strip window; the glue animates each one from where it is
// drawn now (retarget: `from = rect`), so only the targets change, and they are these.
TEST(StagesShellItems, FewerTilesRetargetTheStagesBeyondTheTilesOffTheMonitor) {
    const Box              monitor{0, 0, 1920, 1080};
    const std::vector<Box> three{{16, 200, 160, 120}, {16, 344, 160, 120}, {16, 488, 160, 120}};
    const std::vector<Box> two{{16, 272, 160, 120}, {16, 416, 160, 120}}; // re-centred by the shell
    const std::vector<Box> window{{600, 300, 800, 500}};
    const auto inside = [](const Box& r, const Box& t) { return r.x >= t.x - 1e-9 && r.y >= t.y - 1e-9 && r.x + r.w <= t.x + t.w + 1e-9 && r.y + r.h <= t.y + t.h + 1e-9; };
    // Three tiles: the stage in slot 2 is drawn in the third tile.
    auto t = stripTargets(2, three, false, false, monitor, window);
    ASSERT_EQ(t.size(), 1U);
    EXPECT_TRUE(inside(t[0].to, three[2]));
    ASSERT_TRUE(t[0].thumb.has_value());
    // Two tiles: slot 1 follows its tile to its new place; slot 2 has no tile any more and slides off the monitor.
    t = stripTargets(1, two, false, false, monitor, window);
    ASSERT_EQ(t.size(), 1U);
    EXPECT_TRUE(inside(t[0].to, two[1]));
    EXPECT_EQ(t[0].to, thumbRects(two[1], window)[0]) << "shown strip: no shift";
    t = stripTargets(2, two, false, false, monitor, window);
    ASSERT_EQ(t.size(), 1U);
    EXPECT_LT(t[0].to.x + t[0].to.w, monitor.x) << "beyond the tiles: off the monitor";
    EXPECT_FALSE(t[0].thumb.has_value()) << "no tile: no thumbnail in the event";
    // Hidden strip, or a full-screen window shown: every slot slides off, the thumbnail (its shown place) stays known.
    for (const bool hidden : {true, false}) {
        t = stripTargets(0, two, hidden, !hidden, monitor, window);
        ASSERT_EQ(t.size(), 1U);
        EXPECT_LT(t[0].to.x + t[0].to.w, monitor.x);
        ASSERT_TRUE(t[0].thumb.has_value());
        EXPECT_TRUE(inside(t[0].thumb.value_or(Box{}), two[0]));
    }
    EXPECT_TRUE(stripTargets(0, std::vector<Box>{}, false, false, monitor, window).empty()) << "no tiles: nothing (op:on always has 1..8)";
    EXPECT_EQ(stripTargets(0, two, false, false, monitor, std::vector<Box>{{0, 0, 300, 200}, {10, 10, 300, 200}}).size(), 2U) << "one per window";
}

// Work item 2: op:on with hidden:true while the strip surface keeps only its reveal zone as input region is accepted (only
// the layer is checked); a shown strip still needs its box and input region over every tile.
TEST(StagesShellItems, AHiddenStripNeedsItsLayerAndItsTilesOnTheMonitor) {
    // stripAccepted(hidden, layerOk, tilesInside, boxCovers, inputCovers)
    EXPECT_TRUE(stripAccepted(true, true, true, false, false)) << "hidden, reveal zone only";
    EXPECT_TRUE(stripAccepted(true, true, true, true, true));
    EXPECT_FALSE(stripAccepted(true, false, true, true, true)) << "the layer is always checked";
    EXPECT_FALSE(stripAccepted(true, true, false, false, false)) << "hidden or not, the tiles lie on the monitor";
    EXPECT_TRUE(stripAccepted(false, true, true, true, true));
    EXPECT_FALSE(stripAccepted(false, true, true, true, false)) << "shown: input over every tile";
    EXPECT_FALSE(stripAccepted(false, true, true, false, true)) << "shown: the surface over every tile";
    EXPECT_FALSE(stripAccepted(false, true, false, true, true));
}

// Second review (2026-10-23): a hidden strip skipped every tile check, so tiles at x = +-1.7e308 reached the hidden shift
// (-inf) and the interpolation (NaN), and a tile at x = 100000 made the whole monitor a drop zone.
TEST(StagesShellItems, TilesAreBoundedWhateverTheStripState) {
    const Box monitor{0, 0, 1920, 1080};
    EXPECT_TRUE(tilesInMonitor(std::vector<Box>{{16, 272, 160, 120}}, monitor));
    EXPECT_FALSE(tilesInMonitor(std::vector<Box>{{100000, 272, 160, 120}}, monitor)) << "off the monitor";
    EXPECT_FALSE(tilesInMonitor(std::vector<Box>{{-1.7e308, 272, 160, 120}}, monitor));
    EXPECT_FALSE(tilesInMonitor(std::vector<Box>{{std::nan(""), 272, 160, 120}}, monitor));
    EXPECT_FALSE(tilesInMonitor(std::vector<Box>{}, monitor));
    for (const char* x : {"1.7e308", "-1.7e308", "1000001", "-1000001"}) {
        const std::string json = std::string{R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","hidden":true,"tiles":[{"x":)"} + x + R"(,"y":10,"w":160,"h":120}]}]})";
        EXPECT_FALSE(parseRequest(json).has_value()) << "x = " << x;
        const std::string jsonY = std::string{R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":10,"y":)"} + x + R"(,"w":160,"h":120}]}]})";
        EXPECT_FALSE(parseRequest(jsonY).has_value()) << "y = " << x;
    }
    EXPECT_TRUE(parseRequest(R"({"op":"on","durationMs":0,"strips":[{"monitor":"A","tiles":[{"x":-5000,"y":2160,"w":160,"h":120}]}]})").has_value())
        << "a monitor left of or below the origin is fine";
    // A strip that passes the checks gives finite targets and a bounded drop zone.
    const std::vector<Box> tiles{{16, 272, 160, 120}};
    ASSERT_TRUE(tilesInMonitor(tiles, monitor));
    const auto t = stripTargets(0, tiles, true, false, monitor, std::vector<Box>{{600, 300, 800, 500}});
    ASSERT_EQ(t.size(), 1U);
    EXPECT_TRUE(std::isfinite(t[0].to.x) && std::isfinite(t[0].to.w));
    EXPECT_FALSE(inDropZone(1800, 500, tiles, monitor));
}

// Work item 1: a titlebar drag released on the strip makes the window a stage of its own (macOS).
TEST(StagesShellItems, ADragReleasedOnTheStripIsOnItsOwnStage) {
    const Box              monitor{1920, 0, 1920, 1080}; // the second output
    const std::vector<Box> tiles{{1936, 272, 160, 120}, {1936, 416, 160, 120}};
    EXPECT_TRUE(inDropZone(1925, 50, tiles, monitor)) << "the strip is the left side, the whole height";
    EXPECT_TRUE(inDropZone(1936 + 160 + kStripDropMargin, 900, tiles, monitor)) << "up to the tiles' right edge plus the margin";
    EXPECT_FALSE(inDropZone(1936 + 160 + kStripDropMargin + 1, 400, tiles, monitor));
    EXPECT_FALSE(inDropZone(1900, 400, tiles, monitor)) << "on the other output";
    EXPECT_FALSE(inDropZone(1925, 1080, tiles, monitor)) << "below the output";
    EXPECT_FALSE(inDropZone(1925, 400, std::vector<Box>{}, monitor)) << "no strip";
    EXPECT_FALSE(inDropZone(std::nan(""), 400, tiles, monitor));

    const DropFacts drop{.on = true, .hasStrip = true, .hidden = false, .inZone = true, .managed = true, .active = true, .alone = false, .tiling = false};
    EXPECT_EQ(dropAction(drop), DropAction::NewStage);
    auto f   = drop;
    f.hidden = true;
    EXPECT_EQ(dropAction(f), DropAction::None) << "a hidden strip is no drop target (the shell reveals it at the edge first)";
    f    = drop;
    f.on = false;
    EXPECT_EQ(dropAction(f), DropAction::None) << "Stages off";
    f          = drop;
    f.hasStrip = false;
    EXPECT_EQ(dropAction(f), DropAction::None) << "no strip on that output";
    f        = drop;
    f.inZone = false;
    EXPECT_EQ(dropAction(f), DropAction::None) << "released elsewhere: a normal drag";
    f         = drop;
    f.managed = false;
    EXPECT_EQ(dropAction(f), DropAction::None) << "a window Stages does not manage, or on another output's Desktop";
    f        = drop;
    f.active = false;
    EXPECT_EQ(dropAction(f), DropAction::None);
    f       = drop;
    f.alone = true;
    EXPECT_EQ(dropAction(f), DropAction::None) << "already a stage of its own (moveWindow refuses it too)";
    f        = drop;
    f.tiling = true;
    EXPECT_EQ(dropAction(f), DropAction::None) << "window tiling at the screen edge wins";
}

TEST(StagesShellItems, TheModelMovesTheDroppedWindowToTheFrontOfTheStrip) {
    CWorkspaceStages ws;
    StageId          next = 1;
    ws.reset(std::vector<WindowInfo>{{.id = 1, .app = "foot"}, {.id = 2, .app = "foot"}, {.id = 3, .app = "files"}}, 2, next);
    const auto active = ws.active();
    ASSERT_TRUE(ws.isActive(2));
    ASSERT_TRUE(ws.moveWindow(2, std::nullopt, next)) << "what dropOnStrip asks";
    EXPECT_EQ(ws.active(), active) << "the stage it left stays active";
    EXPECT_FALSE(ws.isActive(2));
    ASSERT_GE(ws.stages().size(), 2U);
    EXPECT_EQ(ws.stages()[1].windows, std::vector<WindowId>{2}) << "a stage of its own, first in the strip";
}

// ---- events and flag ----

TEST(StagesEvents, Json) {
    std::vector<EventMonitor> monitors(1);
    monitors[0].monitor   = "GF-REF";
    monitors[0].workspace = 2;
    monitors[0].active    = 5;
    monitors[0].overlap   = true;
    monitors[0].stages    = {EventStage{.id = 5, .slot = -1, .windows = {EventWindow{.id = 0xab, .thumb = std::nullopt}}},
                             EventStage{.id = 7, .slot = 0, .windows = {EventWindow{.id = 0xcd, .thumb = Box{16.04, 120.26, 180, 128.5}}}}};
    EXPECT_EQ(eventJson(true, monitors),
              R"({"v":"gfc/1","type":"stages","on":true,"monitors":[{"monitor":"GF-REF","workspace":2,"active":5,"hidden":false,"overlap":true,"stages":[)"
              R"({"id":5,"slot":-1,"windows":[{"address":"ab"}]},{"id":7,"slot":0,"windows":[{"address":"cd","x":16,"y":120.3,"w":180,"h":128.5}]}]}]})");
    EXPECT_EQ(eventJson(false, {}, Reason::Unavailable), R"({"v":"gfc/1","type":"stages","on":false,"reason":"unavailable","monitors":[]})");
}

// R13 counter-review #4 of 0.6.3-stages: while an Exclusive layer holds the keyboard after a swap Hyprland has no active
// window; the event names the active stage's front window and app, so that the menu bar keeps naming the front app.
TEST(StagesEvents, TheFrontWindowAndItsApp) {
    std::vector<EventMonitor> monitors(1);
    monitors[0].monitor   = "GF-REF";
    monitors[0].workspace = 2;
    monitors[0].active    = 5;
    monitors[0].front     = EventFront{.id = 0xab, .app = "org.example \"Q\"\n"};
    monitors[0].stages    = {EventStage{.id = 5, .slot = -1, .windows = {EventWindow{.id = 0xab, .thumb = std::nullopt}}}};
    EXPECT_EQ(eventJson(true, monitors),
              R"({"v":"gfc/1","type":"stages","on":true,"monitors":[{"monitor":"GF-REF","workspace":2,"active":5,"hidden":false,"overlap":false,)"
              R"("front":{"address":"ab","app":"org.example \"Q\"\n"},"stages":[{"id":5,"slot":-1,"windows":[{"address":"ab"}]}]}]})");
}

// The app name is client text: valid UTF-8 is kept, invalid bytes become U+FFFD, and it is cut at a character boundary.
TEST(StagesEvents, ClientTextIsSanitized) {
    EXPECT_EQ(sanitizedText("foot", 256), "foot");
    EXPECT_EQ(sanitizedText("caf\xC3\xA9", 256), "caf\xC3\xA9");
    EXPECT_EQ(sanitizedText("\xF0\x9F\x98\x80", 256), "\xF0\x9F\x98\x80") << "4-byte sequence";
    EXPECT_EQ(sanitizedText("a\xFF" "b", 256), "a\xEF\xBF\xBD" "b") << "invalid byte";
    EXPECT_EQ(sanitizedText("\xC0\xAF", 256), "\xEF\xBF\xBD\xEF\xBF\xBD") << "overlong form";
    EXPECT_EQ(sanitizedText("\xED\xA0\x80", 256), "\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD") << "UTF-16 surrogate";
    EXPECT_EQ(sanitizedText("\xE2\x82", 256), "\xEF\xBF\xBD\xEF\xBF\xBD") << "truncated sequence";
    EXPECT_EQ(sanitizedText("ab\xC3\xA9", 3), "ab") << "never cut inside a character";
    EXPECT_EQ(sanitizedText(std::string(1000, 'x'), kMaxAppBytes).size(), kMaxAppBytes);
}

TEST(StagesEvents, ReasonNames) {
    EXPECT_EQ(reasonName(Reason::Invalid), "invalid");
    EXPECT_EQ(reasonName(Reason::Disabled), "disabled");
    EXPECT_EQ(reasonName(Reason::NoStrip), "no-strip");
    EXPECT_EQ(reasonName(Reason::Unknown), "unknown");
    EXPECT_EQ(reasonName(Reason::Unavailable), "unavailable");
    EXPECT_EQ(reasonName(Reason::Interrupted), "interrupted");
    EXPECT_EQ(reasonName(Reason::None), "");
}

TEST(StagesFlag, ConfigAllowlist) {
    EXPECT_EQ(parseStagesEnabled("stagesEnabled", "true"), std::optional<bool>{true});
    EXPECT_EQ(parseStagesEnabled("stagesEnabled", "false"), std::optional<bool>{false});
    EXPECT_FALSE(parseStagesEnabled("stagesEnabled", "TRUE"));
    EXPECT_FALSE(parseStagesEnabled("stagesEnabled", "1"));
    EXPECT_FALSE(parseStagesEnabled("stagesenabled", "true"));
    EXPECT_FALSE(parseStagesEnabled("titlebarDoubleClick", "true"));
}

// R13 review of 46b3e9b, HIGH 2 and the Exclusive-layer minor: only a user choice brings a strip stage forward; Hyprland's
// own successor after a close and its restore of the last window (an Exclusive layer released the keyboard) do not, so a
// swap made under an Exclusive layer is kept.
TEST(StagesInput, OnlyAUserChoiceBringsAStripStageForward) {
    EXPECT_TRUE(stripFocusBringsStage(FocusOrigin::UserChoice));
    EXPECT_FALSE(stripFocusBringsStage(FocusOrigin::AfterClose));
    EXPECT_FALSE(stripFocusBringsStage(FocusOrigin::Restore));
    EXPECT_FALSE(stripFocusBringsStage(FocusOrigin::Automatic));
}

// R13 counter-review of 17208af, minor: every reason Hyprland 0.56.2 uses for its own picks (a Desktop switch, a new
// window, a special workspace closing, a group change, plugins) counted as a user choice. Only a key binding, a focus
// dispatch, an activation request (Dock, xdg-activation), a click or a window switch dispatcher is one.
TEST(StagesInput, OnlyRealUserFocusIsAChoice) {
    for (const auto cause : {FocusCause::KeyBinding, FocusCause::FocusDispatch, FocusCause::GroupDispatch, FocusCause::Activation, FocusCause::SwitchSoft,
                             FocusCause::SwitchHard}) {
        for (const bool pressed : {false, true}) {
            EXPECT_EQ(focusOrigin(cause, false, pressed), FocusOrigin::UserChoice) << static_cast<int>(cause);
            EXPECT_EQ(focusOrigin(cause, true, pressed), FocusOrigin::UserChoice) << static_cast<int>(cause);
        }
    }
    EXPECT_EQ(focusOrigin(FocusCause::Click, false, true), FocusOrigin::UserChoice) << "a click: a real press";
    for (const auto cause : {FocusCause::UnmapTiling, FocusCause::UnmapFloating, FocusCause::UnmapGrouped})
        EXPECT_EQ(focusOrigin(cause, false, true), FocusOrigin::AfterClose) << static_cast<int>(cause);
    EXPECT_EQ(focusOrigin(FocusCause::PointerFollow, false, true), FocusOrigin::Restore) << "an Exclusive layer released the keyboard, a popup grab ended";
    EXPECT_EQ(focusOrigin(FocusCause::ToggleSpecialWorkspace, false, false), FocusOrigin::Restore);
    for (const auto cause : {FocusCause::NewWindow, FocusCause::GroupCurrentChange, FocusCause::Other, FocusCause::Unknown, FocusCause::Ghosts}) {
        EXPECT_EQ(focusOrigin(cause, false, false), FocusOrigin::Automatic) << static_cast<int>(cause);
        EXPECT_FALSE(stripFocusBringsStage(focusOrigin(cause, true, true))) << static_cast<int>(cause);
    }
}

// R13 counter-review #4 of 0.6.3-stages, MAJOR: when an Exclusive layer closed after a swap made under it, Hyprland
// refocused at the cursor (CInputManager::refocus, reason CLICK) and the window under the pointer (an unrelated window, or
// the swapped-in stage's back window) took the keyboard from the swap's front window, as if the user had clicked it. CLICK
// is a choice only when a real press caused it.
TEST(StagesInput, ARefocusAtTheCursorWithoutAPressIsNotAClick) {
    EXPECT_EQ(focusOrigin(FocusCause::Click, false, false), FocusOrigin::CursorRefocus);
    EXPECT_EQ(focusOrigin(FocusCause::Click, true, false), FocusOrigin::CursorRefocus);
    EXPECT_FALSE(stripFocusBringsStage(FocusOrigin::CursorRefocus));
    EXPECT_FALSE(clickFromPress(PressRecord{}, 0x10)) << "no press recorded";
}

// A press with no Exclusive layer: Hyprland refocuses at the cursor while it handles the press, so a CLICK focus during it
// (whatever window it picks) is the press. The glue ends it from the event loop, after Hyprland handled the press.
TEST(StagesInput, APressIsAClickWhileHyprlandHandlesIt) {
    const auto press = recordPress({.exclusive = false, .onExclusive = false, .under = 0x10});
    EXPECT_EQ(press.scope, PressScope::ThisPress);
    EXPECT_TRUE(clickFromPress(press, 0x10));
    EXPECT_TRUE(clickFromPress(press, 0x20)) << "Hyprland's own hit test decides which window the press focuses";
    EXPECT_EQ(recordPress({.exclusive = false, .onExclusive = false, .under = 0}).scope, PressScope::ThisPress) << "a press on the desktop or a layer";
}

// While an Exclusive layer is mapped Hyprland gives every press to it and refuses window focus. A press into the layer (a
// dialog's button, Search) chooses no window; a press beside it on a window is the user's click on that window: when the
// layer is gone, Hyprland's refocus at the cursor focuses it, and that click wins over a deferred focus; any other window
// Hyprland refocuses there is not the click.
TEST(StagesInput, APressBesideAnExclusiveLayerChoosesTheWindowPressed) {
    EXPECT_EQ(recordPress({.exclusive = true, .onExclusive = true, .under = 0x10}).scope, PressScope::None) << "a press into the layer";
    EXPECT_EQ(recordPress({.exclusive = true, .onExclusive = false, .under = 0}).scope, PressScope::None) << "beside the layer, on no window";
    const auto press = recordPress({.exclusive = true, .onExclusive = false, .under = 0x10});
    EXPECT_EQ(press.scope, PressScope::UntilFocus);
    EXPECT_TRUE(clickFromPress(press, 0x10)) << "the refocus after the layer finds the window pressed";
    EXPECT_FALSE(clickFromPress(press, 0x20)) << "the pointer moved to another window before the layer went away";
}

// R13 counter-review of 17208af, MAJOR: a swap made while an Exclusive layer held the keyboard left Hyprland's active window
// on the outgoing window, hidden in the strip, and hl.dsp.window.close() closed it.
TEST(StagesInput, HyprlandsActiveWindowNeverStaysOnAStripWindow) {
    using A = ActiveWindowAction;
    EXPECT_EQ(activeWindowAction({.hidden = false, .locked = false, .layerKeyboard = true, .exclusive = true, .hasFront = true}), A::None) << "not a strip window";
    EXPECT_EQ(activeWindowAction({.hidden = true, .locked = false, .layerKeyboard = false, .exclusive = false, .hasFront = true}), A::FocusFront)
        << "no layer holds the keyboard: the front window takes it, as after a swap";
    EXPECT_EQ(activeWindowAction({.hidden = true, .locked = false, .layerKeyboard = true, .exclusive = false, .hasFront = true}), A::FocusFront)
        << "an on_demand layer (the desktop): Hyprland accepts the focus, the front window takes the keyboard as on any focus";
    EXPECT_EQ(activeWindowAction({.hidden = true, .locked = false, .layerKeyboard = false, .exclusive = false, .hasFront = false}), A::Unfocus)
        << "a no_focus front window: nothing focused, as Hyprland does when its focused window gets blocked";
    EXPECT_EQ(activeWindowAction({.hidden = true, .locked = false, .layerKeyboard = true, .exclusive = false, .hasFront = false}), A::Clear)
        << "the desktop keeps the keyboard, no active window";
    EXPECT_EQ(activeWindowAction({.hidden = true, .locked = true, .layerKeyboard = true, .exclusive = true, .hasFront = true}), A::None) << "the session lock is never touched";
}

// R13 counter-review #3 of e9ebc7f, HIGH: the plugin set Hyprland's Exclusive-layer list aside to make the incoming front
// window active behind the layer; Hyprland's side paths (a special workspace closing, a switch to a Desktop not shown) then
// gave that window the keyboard: keys typed into an Exclusive layer (the polkit dialog) reached an app window. Under an
// Exclusive layer the plugin now never focuses a window: a strip window that is Hyprland's active window is cleared, the
// keyboard holder untouched.
TEST(StagesInput, UnderAnExclusiveLayerTheActiveStripWindowIsOnlyCleared) {
    using A = ActiveWindowAction;
    for (const bool layerKeyboard : {true, false}) {
        for (const bool hasFront : {true, false}) {
            EXPECT_EQ(activeWindowAction({.hidden = true, .locked = false, .layerKeyboard = layerKeyboard, .exclusive = true, .hasFront = hasFront}), A::Clear)
                << "layer keyboard " << layerKeyboard << ", front " << hasFront << ": never a focus while Hyprland refuses window focus";
        }
    }
    EXPECT_EQ(activeWindowAction({.hidden = false, .locked = false, .layerKeyboard = true, .exclusive = true, .hasFront = true}), A::None)
        << "a window that is not in the strip (a special workspace's window) stays Hyprland's active window";
}

// The front window the plugin could not focus under an Exclusive layer (or the lock) takes the focus only once Hyprland
// accepts window focus again, and only if its Desktop is shown and not covered.
TEST(StagesInput, ADeferredFocusWaitsForTheLayerAndIsCheckedAgain) {
    using P                         = PendingFocusAction;
    const PendingFocusState settled = {.remembered = true, .hasFront = true, .shown = true, .locked = false, .exclusive = false, .holderKeeps = false, .focused = false};
    EXPECT_EQ(pendingFocusAction(settled), P::Focus) << "the layer is gone: the swap's front window takes the keyboard (ST23)";

    auto s      = settled;
    s.exclusive = true;
    EXPECT_EQ(pendingFocusAction(s), P::Wait) << "an Exclusive layer (this one or another) is still mapped";
    s             = settled;
    s.holderKeeps = true;
    EXPECT_EQ(pendingFocusAction(s), P::Wait) << "the layer dropped its exclusivity but keeps the keyboard (on_demand)";
    s        = settled;
    s.locked = true;
    EXPECT_EQ(pendingFocusAction(s), P::Wait) << "the session lock: nothing until the unlock";

    s       = settled;
    s.shown = false;
    EXPECT_EQ(pendingFocusAction(s), P::Drop) << "its Desktop is not shown or a special workspace covers it: nothing is switched or closed after the fact";
    s         = settled;
    s.focused = true;
    EXPECT_EQ(pendingFocusAction(s), P::Drop) << "Hyprland's restore already gave it the keyboard";
}

// R13 counter-review #4 of 0.6.3-stages, minor: when the remembered window closed while the layer was up and the pointer was
// over empty space, the keyboard ended on nothing. macOS: the frontmost app's key window gets the keyboard back; here the
// front window of that Desktop's active stage (another stage may have come forward when the window closed).
TEST(StagesInput, ADeferredFocusFallsBackToTheFrontWindowNow) {
    using P                    = PendingFocusAction;
    const PendingFocusState gone = {.remembered = false, .hasFront = true, .shown = true, .locked = false, .exclusive = false, .holderKeeps = false, .focused = false};
    EXPECT_EQ(pendingFocusAction(gone), P::FocusFront) << "closed, minimized or moved away, or another stage came forward";
    auto s      = gone;
    s.exclusive = true;
    EXPECT_EQ(pendingFocusAction(s), P::Wait) << "still under the layer";
    s         = gone;
    s.focused = true;
    EXPECT_EQ(pendingFocusAction(s), P::Drop) << "the front window already holds the keyboard";
    s          = gone;
    s.hasFront = false;
    s.locked   = true;
    EXPECT_EQ(pendingFocusAction(s), P::Drop) << "no stage left on that Desktop: Hyprland's choice stands";
}

// HIGH 2: minimizing the only window of the active stage left the keyboard on it (special:minimized).
TEST(StagesInput, TheKeyboardNeverStaysOnAnIneligibleWindow) {
    EXPECT_EQ(keyboardAfterLeave({.present = true, .eligible = true}, true), KeyboardTarget::Keep) << "Hyprland picked a usable window";
    EXPECT_EQ(keyboardAfterLeave({.present = true, .eligible = true}, false), KeyboardTarget::Keep);
    EXPECT_EQ(keyboardAfterLeave({.present = true, .eligible = false}, true), KeyboardTarget::FrontOfActive) << "minimized or strip window";
    EXPECT_EQ(keyboardAfterLeave({.present = false, .eligible = false}, true), KeyboardTarget::FrontOfActive) << "nothing focused";
    EXPECT_EQ(keyboardAfterLeave({.present = true, .eligible = false}, false), KeyboardTarget::Nothing) << "no stage left: nothing";
    EXPECT_EQ(keyboardAfterLeave({.present = false, .eligible = false}, false), KeyboardTarget::Nothing);
}

// HIGH 1: a click without motion after a swap went to the hidden strip window that was still Hyprland's pointer focus.
TEST(StagesInput, APressOnAStaleBlockedFocusRefreshesItFirst) {
    EXPECT_EQ(beforePointerEvent(PointerEvent::Press, {.onBlocked = true, .hasFocus = true, .parked = false}), PointerAction::Refresh);
    EXPECT_EQ(beforePointerEvent(PointerEvent::Press, {.onBlocked = false, .hasFocus = true, .parked = false}), PointerAction::None);
    EXPECT_EQ(beforePointerEvent(PointerEvent::Press, {.onBlocked = false, .hasFocus = false, .parked = false}), PointerAction::None)
        << "no focus and not parked: Hyprland's own case (nothing under the pointer)";
    EXPECT_EQ(beforePointerEvent(PointerEvent::Press, {.onBlocked = false, .hasFocus = false, .parked = true}), PointerAction::Refresh)
        << "the first press after the plugin parked the pointer";
    EXPECT_EQ(beforePointerEvent(PointerEvent::Press, {.onBlocked = false, .hasFocus = true, .parked = true}), PointerAction::None)
        << "a motion already found a surface";
}

TEST(StagesInput, AReleaseOnABlockedFocusIsDroppedNeverCancelled) {
    EXPECT_EQ(beforePointerEvent(PointerEvent::Release, {.onBlocked = true, .hasFocus = true, .parked = false}), PointerAction::Park);
    EXPECT_EQ(beforePointerEvent(PointerEvent::Release, {.onBlocked = false, .hasFocus = true, .parked = false}), PointerAction::None);
    EXPECT_EQ(beforePointerEvent(PointerEvent::Release, {.onBlocked = false, .hasFocus = false, .parked = true}), PointerAction::None)
        << "already parked: the release reaches no surface";
}

TEST(StagesInput, AScrollOnABlockedFocusRefreshesIt) {
    EXPECT_EQ(beforePointerEvent(PointerEvent::Axis, {.onBlocked = true, .hasFocus = true, .parked = false}), PointerAction::Refresh);
    EXPECT_EQ(beforePointerEvent(PointerEvent::Axis, {.onBlocked = false, .hasFocus = true, .parked = false}), PointerAction::None);
}

// Integrator decision 2026-10-24 (macOS: a modal system prompt always gets the keyboard, and there is always a key window;
// wlr-layer-shell: an Exclusive Top or Overlay surface gets every key). One test per condition.
namespace {
    using gf::stages::KeyFocusAction;
    using gf::stages::KeyFocusFacts;
    using gf::stages::keyFocusAction;
    using gf::stages::replacesFrontmost;

    // An Overlay dialog with Exclusive keyboard interactivity is up, the seat's keyboard is elsewhere.
    KeyFocusFacts dialogUp() {
        return {.locked = false, .inputMethodGrab = false, .exclusive = true, .frontmostLevel = 3, .seatOnFrontmost = false, .grabRejectsLayer = false,
                .seatFocusNone = true, .activeWindow = false, .grabRejectsWindow = false};
    }
    // No Exclusive layer, the seat's keyboard on nothing, Hyprland has an active window that may take it.
    KeyFocusFacts windowLeftWithoutKeys() {
        return {.locked = false, .inputMethodGrab = false, .exclusive = false, .frontmostLevel = 0, .seatOnFrontmost = false, .grabRejectsLayer = false,
                .seatFocusNone = true, .activeWindow = true, .grabRejectsWindow = false};
    }
} // namespace

TEST(StagesKeyFocus, TheFrontmostExclusiveTopOrOverlayLayerGetsTheKeys) {
    EXPECT_EQ(keyFocusAction(dialogUp()), KeyFocusAction::ToLayer) << "seat on nothing";
    auto f          = dialogUp();
    f.seatFocusNone = false; // on a window or another surface
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::ToLayer) << "seat elsewhere";
    f.frontmostLevel = 2;
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::ToLayer) << "a Top layer counts as an Overlay one";
    f.seatOnFrontmost = true;
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::None) << "the seat is already on it (or one of its popups)";
}

TEST(StagesKeyFocus, NothingWhileLocked) {
    auto f   = dialogUp();
    f.locked = true;
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::None);
    auto w   = windowLeftWithoutKeys();
    w.locked = true;
    EXPECT_EQ(keyFocusAction(w), KeyFocusAction::None);
}

TEST(StagesKeyFocus, AnUnknownLockStateCountsAsLocked) {
    KeyFocusFacts f{.exclusive = true, .frontmostLevel = 3, .seatFocusNone = true};
    EXPECT_TRUE(f.locked) << "the default: a missing lock manager is reported as locked";
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::None);
    EXPECT_EQ(keyFocusAction(KeyFocusFacts{.seatFocusNone = true, .activeWindow = true}), KeyFocusAction::None);
}

TEST(StagesKeyFocus, NeverAgainstASeatGrabThatRejectsTheSurface) {
    auto f             = dialogUp();
    f.grabRejectsLayer = true;
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::None) << "Hyprland would refuse and log a line per key";
    auto w              = windowLeftWithoutKeys();
    w.grabRejectsWindow = true;
    EXPECT_EQ(keyFocusAction(w), KeyFocusAction::None);
}

TEST(StagesKeyFocus, AnInputMethodGrabIsLeftAlone) {
    auto f            = dialogUp();
    f.inputMethodGrab = true;
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::None);
    auto w            = windowLeftWithoutKeys();
    w.inputMethodGrab = true;
    EXPECT_EQ(keyFocusAction(w), KeyFocusAction::None);
}

TEST(StagesKeyFocus, ABottomOrBackgroundExclusiveLayerChangesNothing) {
    for (const uint32_t level : {0U, 1U}) {
        auto f           = dialogUp();
        f.frontmostLevel = level;
        EXPECT_EQ(keyFocusAction(f), KeyFocusAction::None) << "level " << level << ": the normal focus stays";
        f.activeWindow = true; // and no window is given the keyboard either while an Exclusive layer is mapped
        EXPECT_EQ(keyFocusAction(f), KeyFocusAction::None) << "level " << level;
    }
}

TEST(StagesKeyFocus, OfTwoExclusiveLayersTheFrontmostWins) {
    // Walk Hyprland's list in order, as frontmostExclusiveLayer does: {level, order}.
    const auto frontmost = [](std::initializer_list<uint32_t> levels) {
        std::optional<uint32_t> best;
        size_t                  index = 0, picked = 0;
        for (const auto level : levels) {
            if (replacesFrontmost(level, best)) {
                best   = level;
                picked = index;
            }
            ++index;
        }
        return picked;
    };
    EXPECT_EQ(frontmost({3, 2}), 0U) << "an Overlay dialog stays in front of a later Top one";
    EXPECT_EQ(frontmost({2, 3}), 1U) << "a later Overlay one is in front";
    EXPECT_EQ(frontmost({3, 3}), 1U) << "the latest among equals";
    EXPECT_EQ(frontmost({1, 2, 0}), 1U);
    // The seat on the other (older or lower) Exclusive layer: the keys go to the frontmost.
    auto f            = dialogUp();
    f.seatFocusNone   = false;
    f.seatOnFrontmost = false;
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::ToLayer);
}

TEST(StagesKeyFocus, NoLayerANullFocusAndAnActiveWindowGiveItTheKeys) {
    EXPECT_EQ(keyFocusAction(windowLeftWithoutKeys()), KeyFocusAction::ToWindow);
    auto w          = windowLeftWithoutKeys();
    w.seatFocusNone = false; // the seat's keyboard on a surface: Hyprland's choice stands (the desktop, a layer, a window)
    EXPECT_EQ(keyFocusAction(w), KeyFocusAction::None);
    w           = windowLeftWithoutKeys();
    w.exclusive = true; // an Exclusive layer is up: no window gets the keyboard
    w.frontmostLevel = 3;
    w.seatOnFrontmost = true;
    EXPECT_EQ(keyFocusAction(w), KeyFocusAction::None);
}

TEST(StagesKeyFocus, FromTheEventLoopOnlyTheLayerIsKept) {
    auto f        = dialogUp();
    f.keyArriving = false;
    EXPECT_EQ(keyFocusAction(f), KeyFocusAction::ToLayer) << "a banner that took the keyboard over the dialog: moved back before the next key";
    auto w        = windowLeftWithoutKeys();
    w.keyArriving = false;
    EXPECT_EQ(keyFocusAction(w), KeyFocusAction::None) << "the overview's no-key-window and a deferred focus may still decide";
}

TEST(StagesKeyFocus, ANewKeyboardDeviceAnnouncesTheFocusAgainOnlyWhenNothingElseDecides) {
    using gf::stages::ReannounceFacts;
    using gf::stages::reannounceFocus;
    const ReannounceFacts base{.replaced = true, .locked = false, .inputMethodGrab = false, .seatGrab = false, .focus = true};
    EXPECT_TRUE(reannounceFocus(base));
    auto f     = base;
    f.replaced = false;
    EXPECT_FALSE(reannounceFocus(f)) << "the same device as the previous key";
    f        = base;
    f.locked = true;
    EXPECT_FALSE(reannounceFocus(f)) << "locked";
    EXPECT_FALSE(reannounceFocus(ReannounceFacts{.replaced = true, .focus = true})) << "the lock state not known: locked";
    f                 = base;
    f.inputMethodGrab = true;
    EXPECT_FALSE(reannounceFocus(f)) << "an input method grabs the keyboard";
    f          = base;
    f.seatGrab = true;
    EXPECT_FALSE(reannounceFocus(f)) << "a menu's grab";
    f       = base;
    f.focus = false;
    EXPECT_FALSE(reannounceFocus(f)) << "the keyboard on nothing";
}

TEST(StagesKeyFocus, NoLayerAndNoWindowLeaveTheKeyboardOnNothing) {
    auto w         = windowLeftWithoutKeys();
    w.activeWindow = false; // no active window, or one that may not take the keyboard (hidden, a strip window, input blocked)
    EXPECT_EQ(keyFocusAction(w), KeyFocusAction::None);
}
