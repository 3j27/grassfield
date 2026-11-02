// Pointer focus after a Grassfield layer maps or takes the keyboard (gfc/1 "layer-pointer", spec FR51-FR52): which
// namespaces count, one refresh per burst of events from the event loop, waiting for the release of a held button or for
// a pointer device, the press fallback, and the feature name.

#include "core/LayerPointer.hpp"
#include "core/Protocol.hpp"

#include <gtest/gtest.h>

#include <string>

using namespace gf::layerpointer;

namespace {
    constexpr bool kDevice   = true;
    constexpr bool kNoDevice = false;
    constexpr bool kHeld     = true;
    constexpr bool kFree     = false;
    constexpr bool kPress    = true;
    constexpr bool kRelease  = false;
} // namespace

TEST(LayerPointer, OnlyTheShellsOwnNamespacesCount) {
    EXPECT_TRUE(isGrassfieldNamespace("grassfield-overlay"));
    EXPECT_TRUE(isGrassfieldNamespace("grassfield-menubar"));
    EXPECT_TRUE(isGrassfieldNamespace("grassfield-desktop-icons"));
    EXPECT_FALSE(isGrassfieldNamespace("grassfield-")); // nothing after the prefix
    EXPECT_FALSE(isGrassfieldNamespace("grassfield"));
    EXPECT_FALSE(isGrassfieldNamespace(""));
    EXPECT_FALSE(isGrassfieldNamespace("Grassfield-overlay")); // exact, case-sensitive
    EXPECT_FALSE(isGrassfieldNamespace("xgrassfield-overlay"));
    EXPECT_FALSE(isGrassfieldNamespace("waybar"));
    EXPECT_FALSE(isGrassfieldNamespace("hyprpicker"));
    EXPECT_FALSE(isGrassfieldNamespace(std::string("grassfield\0-overlay", 19)));
}

TEST(LayerPointer, OtherLayersChangeNothing) {
    CRefreshState s;
    EXPECT_FALSE(s.onLayerEvent("waybar"));
    EXPECT_FALSE(s.owed());
    EXPECT_FALSE(s.scheduled());
    EXPECT_EQ(s.beforeButton(kPress, kDevice, kFree), Step::None);
    EXPECT_EQ(s.beforeButton(kRelease, kDevice, kFree), Step::None);
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::None);
    EXPECT_EQ(s.refreshes(), 0U);
}

// The menu overlay opened by IPC or a key under a still pointer: one refresh from the event loop.
TEST(LayerPointer, AShellLayerEventSchedulesOneRefreshAtTheCursor) {
    CRefreshState s;
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_TRUE(s.owed());
    EXPECT_TRUE(s.scheduled());
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::Refresh);
    EXPECT_FALSE(s.owed());
    EXPECT_FALSE(s.scheduled());
    EXPECT_EQ(s.refreshes(), 1U);
    // Nothing more: the next click is Hyprland's alone.
    EXPECT_EQ(s.beforeButton(kPress, kDevice, kFree), Step::None);
    EXPECT_EQ(s.beforeButton(kRelease, kDevice, kFree), Step::None);
    EXPECT_EQ(s.refreshes(), 1U);
}

// The overlay maps and then takes the keyboard (two events) before the attempt runs: one refresh.
TEST(LayerPointer, EventsBeforeTheAttemptJoinIt) {
    CRefreshState s;
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_FALSE(s.onLayerEvent("grassfield-overlay")); // keyboard: already scheduled
    EXPECT_FALSE(s.onLayerEvent("waybar"));
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::Refresh);
    EXPECT_EQ(s.refreshes(), 1U);
    // An event after the attempt schedules a new one (the overlay taking the keyboard a frame later).
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::Refresh);
    EXPECT_EQ(s.refreshes(), 2U);
}

// A menu opened by a press maps while the button is down: Hyprland keeps the pressed surface, so the refresh waits for the
// release and runs from the event loop after Hyprland handled it.
TEST(LayerPointer, AMapWhileAButtonIsHeldRefreshesAfterTheRelease) {
    CRefreshState s;
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_EQ(s.onAttempt(kDevice, kHeld), Step::Wait);
    EXPECT_TRUE(s.owed());
    EXPECT_FALSE(s.scheduled());
    EXPECT_EQ(s.beforeButton(kRelease, kDevice, kHeld), Step::Schedule);
    EXPECT_TRUE(s.scheduled());
    EXPECT_EQ(s.beforeButton(kRelease, kDevice, kHeld), Step::None); // already scheduled
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::Refresh);
    EXPECT_FALSE(s.owed());
    EXPECT_EQ(s.refreshes(), 1U);
}

// Two buttons down: the first release leaves one held, the attempt waits again, the last release refreshes.
TEST(LayerPointer, OnlyTheLastReleaseRefreshes) {
    CRefreshState s;
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_EQ(s.onAttempt(kDevice, kHeld), Step::Wait);
    EXPECT_EQ(s.beforeButton(kRelease, kDevice, kHeld), Step::Schedule);
    EXPECT_EQ(s.onAttempt(kDevice, kHeld), Step::Wait);
    EXPECT_EQ(s.beforeButton(kPress, kDevice, kHeld), Step::None); // another button still down
    EXPECT_EQ(s.beforeButton(kRelease, kDevice, kHeld), Step::Schedule);
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::Refresh);
    EXPECT_EQ(s.refreshes(), 1U);
}

// Hyprland refuses pointer focus changes while no pointer device exists: the refresh waits for the next press, made by a
// device that exists by then, and runs before Hyprland handles that press.
TEST(LayerPointer, WithoutAPointerDeviceTheNextPressRefreshes) {
    CRefreshState s;
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_EQ(s.onAttempt(kNoDevice, kFree), Step::Wait);
    EXPECT_TRUE(s.owed());
    EXPECT_FALSE(s.scheduled());
    EXPECT_EQ(s.beforeButton(kPress, kNoDevice, kFree), Step::None); // still no device
    EXPECT_TRUE(s.owed());
    EXPECT_EQ(s.beforeButton(kPress, kDevice, kFree), Step::Refresh);
    EXPECT_FALSE(s.owed());
    EXPECT_EQ(s.beforeButton(kPress, kDevice, kFree), Step::None);
    EXPECT_EQ(s.refreshes(), 1U);
}

// A press read in the same event loop pass as the map comes before the scheduled attempt: it refreshes at once, and the
// attempt then has nothing left to do.
TEST(LayerPointer, APressBeforeTheAttemptRefreshesOnce) {
    CRefreshState s;
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_EQ(s.beforeButton(kPress, kDevice, kFree), Step::Refresh);
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::None);
    EXPECT_EQ(s.refreshes(), 1U);
}

TEST(LayerPointer, ResetForgetsEverything) {
    CRefreshState s;
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_EQ(s.onAttempt(kNoDevice, kFree), Step::Wait);
    s.reset();
    EXPECT_FALSE(s.owed());
    EXPECT_FALSE(s.scheduled());
    EXPECT_EQ(s.refreshes(), 0U);
    EXPECT_EQ(s.beforeButton(kPress, kDevice, kFree), Step::None);
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay")); // schedules again after a reload
}

TEST(LayerPointer, FeatureIsAdvertisedOnlyWhenRegisteredAndLast) {
    using namespace gf::gfc;
    EXPECT_EQ(kFeatureLayerPointer, "layer-pointer");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","layer-pointer"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, false, true, true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2","stages-available","cursor-refresh","overview-focus","minimize-effect","window-tiling","zoom-fill","layer-pointer"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true, true, true, true, true, false)).find("layer-pointer"), std::string::npos);
}

// ---- the keyboard focus (regression of 2026-10-23: tests/compositor/stages.sh hung the compositor) ----
// A press on the desktop gave the keyboard to the desktop icons layer (on demand). Each refresh at the cursor made Hyprland
// set the keyboard focus on that same layer again, which counted as "a layer took the keyboard" and owed the next refresh:
// 10 million refreshes, the compositor stopped answering IPC.

TEST(LayerPointer, TheKeyboardMovingToAShellLayerOwesARefresh) {
    CRefreshState s;
    EXPECT_FALSE(s.onKeyboardFocus(0x10, ""));                        // a window
    EXPECT_TRUE(s.onKeyboardFocus(0x20, "grassfield-desktop-icons")); // moved to the desktop layer
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::Refresh);
    EXPECT_EQ(s.refreshes(), 1U);
}

TEST(LayerPointer, TheKeyboardSetAgainOnTheSameLayerOwesNothing) {
    CRefreshState s;
    EXPECT_TRUE(s.onKeyboardFocus(0x20, "grassfield-desktop-icons"));
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::Refresh);
    for (int i = 0; i < 1000; ++i)
        ASSERT_FALSE(s.onKeyboardFocus(0x20, "grassfield-desktop-icons")) << "set again on the surface that has it";
    EXPECT_FALSE(s.owed());
    EXPECT_EQ(s.onAttempt(kDevice, kFree), Step::None);
    EXPECT_EQ(s.refreshes(), 1U) << "no loop";
    // Away and back is a move again.
    EXPECT_FALSE(s.onKeyboardFocus(0x10, ""));
    EXPECT_TRUE(s.onKeyboardFocus(0x20, "grassfield-desktop-icons"));
}

TEST(LayerPointer, WhatARefreshCausesIsItsOwn) {
    CRefreshState s;
    EXPECT_FALSE(s.onKeyboardFocus(0x10, ""));
    s.beginRefresh();
    EXPECT_FALSE(s.onKeyboardFocus(0x20, "grassfield-desktop-icons")) << "the refresh moved the keyboard";
    EXPECT_FALSE(s.onLayerEvent("grassfield-overlay"));
    s.endRefresh();
    EXPECT_FALSE(s.owed());
    EXPECT_FALSE(s.onKeyboardFocus(0x20, "grassfield-desktop-icons")) << "still the same surface after the refresh";
    EXPECT_TRUE(s.onLayerEvent("grassfield-overlay")) << "a map after the refresh counts again";
}

TEST(LayerPointer, NoKeyboardOrAnotherClientsLayerOwesNothing) {
    CRefreshState s;
    EXPECT_FALSE(s.onKeyboardFocus(0, ""));
    EXPECT_FALSE(s.onKeyboardFocus(0x30, "waybar"));
    EXPECT_FALSE(s.onKeyboardFocus(0, "grassfield-overlay")) << "no surface";
    EXPECT_FALSE(s.owed());
}

TEST(LayerPointer, RefreshesAreBoundedPerSecond) {
    CRefreshState s;
    for (uint32_t i = 0; i < kMaxRefreshesPerSecond; ++i) {
        ASSERT_EQ(s.budgetWaitMs(1000 + i), 0U);
        s.spend(1000);
    }
    EXPECT_EQ(s.budgetWaitMs(1500), 500U) << "over the budget within one second: wait for its end";
    EXPECT_EQ(s.budgetWaitMs(1999), 1U);
    EXPECT_EQ(s.budgetWaitMs(2000), 0U) << "a new second";
    EXPECT_EQ(s.budgetWaitMs(500), 0U) << "a clock that went backwards starts a new window";
}

// Reviewer, 2026-10-23: the budget was checked after onAttempt had cleared the owed refresh, so a refresh over it was lost
// and the next press landed at a stale position (FR51). Over the budget, the refresh stays owed and runs later.
TEST(LayerPointer, AnAttemptOverTheBudgetIsDeferredNotDropped) {
    CRefreshState s;
    for (uint32_t i = 0; i < kMaxRefreshesPerSecond; ++i)
        s.spend(1000);
    ASSERT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_EQ(s.attemptAt(true, false, 1400), Step::Defer);
    EXPECT_TRUE(s.owed()) << "still owed";
    EXPECT_TRUE(s.scheduled()) << "the timer's attempt is the scheduled one";
    EXPECT_EQ(s.deferred(), 1U);
    EXPECT_FALSE(s.onLayerEvent("grassfield-menubar")) << "nothing more is scheduled meanwhile";
    EXPECT_EQ(s.attemptAt(true, false, 2000), Step::Refresh) << "the window is over: the refresh runs";
    EXPECT_FALSE(s.owed());
    EXPECT_FALSE(s.scheduled());
    s.reset();
    EXPECT_EQ(s.deferred(), 0U);
}

TEST(LayerPointer, APressIsNeverDeferred) {
    CRefreshState s;
    for (uint32_t i = 0; i < kMaxRefreshesPerSecond; ++i)
        s.spend(1000);
    ASSERT_TRUE(s.onLayerEvent("grassfield-overlay"));
    ASSERT_EQ(s.attemptAt(true, false, 1400), Step::Defer);
    EXPECT_EQ(s.beforeButton(true, true, false), Step::Refresh) << "the user's press refreshes at once, over the budget too";
    EXPECT_EQ(s.attemptAt(true, false, 2000), Step::None) << "the deferred attempt then finds nothing owed";
    EXPECT_FALSE(s.scheduled());
}

TEST(LayerPointer, AnAttemptThatWaitsForADeviceIsNotDeferred) {
    CRefreshState s;
    for (uint32_t i = 0; i < kMaxRefreshesPerSecond; ++i)
        s.spend(1000);
    ASSERT_TRUE(s.onLayerEvent("grassfield-overlay"));
    EXPECT_EQ(s.attemptAt(false, false, 1400), Step::Wait) << "no pointer device: the next press refreshes";
    EXPECT_EQ(s.attemptAt(true, true, 1400), Step::Wait) << "a button held: its release schedules";
    EXPECT_EQ(s.deferred(), 0U);
}
