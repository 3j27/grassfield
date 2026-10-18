#include "core/Stages.hpp"

#include <gtest/gtest.h>

#include <cstdint>
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
    const double s = std::min(180.0 / 700, 130.0 / 528);
    EXPECT_NEAR(r[0].w, 700 * s, 1e-9);
    EXPECT_NEAR(r[0].h, 500 * s, 1e-9);
    EXPECT_NEAR(r[0].y - (kTitlebarHeight * s), tile.y + ((130 - (528 * s)) / 2), 1e-9);
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
