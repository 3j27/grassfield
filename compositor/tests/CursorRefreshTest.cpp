// Cursor refresh (gfc/1 "cursor-refresh", spec FR39-FR40): verb and feature names, the decision over Hyprland's cursor
// state and the request rate limit. Time is passed in; no Hyprland needed.

#include "core/CursorRefresh.hpp"
#include "core/Protocol.hpp"

#include <gtest/gtest.h>

#include <chrono>
#include <cstddef>
#include <string>

using namespace gf::cursor;
using gf::events::TimePoint;
using std::chrono::milliseconds;

namespace {
    constexpr TimePoint T0 = TimePoint{} + std::chrono::seconds(1000);

    SCursorState shownNamed(std::string_view name) {
        return {.shown = true, .fromSurface = false, .outputs = true, .name = name};
    }
} // namespace

// What the shell sends (shell/platform/Minimized.js cursorRefreshCall, Pointer.qml): the verb is a Lua identifier and
// the capability it checks is "cursor-refresh"; both must match the plugin's names exactly.
TEST(CursorRefresh, VerbAndFeatureAreWhatTheShellUses) {
    using namespace gf::gfc;
    EXPECT_EQ(kLuaCursorRefresh, "cursor_refresh");
    EXPECT_EQ(kFeatureCursorRefresh, "cursor-refresh");
    EXPECT_EQ(luaDispatchRequest(kLuaCursorRefresh), "hl.plugin.grassfield.cursor_refresh()");
}

TEST(CursorRefresh, FeatureIsAdvertisedOnlyWhenRegisteredAndLast) {
    using namespace gf::gfc;
    EXPECT_EQ(capabilitiesJson(features(false, false, false)), R"({"v":"gfc/1","type":"capabilities","features":["decorations"]})");
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","cursor-refresh"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2","stages-available","cursor-refresh"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2","stages-available","stages","cursor-refresh"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true, false)).find("cursor-refresh"), std::string::npos);
}

// The named shape Hyprland shows is re-applied as it is: the arrow stays the arrow, the I-beam the I-beam.
TEST(CursorRefresh, AShownNamedShapeIsRedrawnUnchanged) {
    EXPECT_EQ(decide(shownNamed("default")), Outcome::Redraw);
    EXPECT_EQ(decide(shownNamed("left_ptr")), Outcome::Redraw);
    EXPECT_EQ(decide(shownNamed("text")), Outcome::Redraw);
    EXPECT_EQ(decide(shownNamed("ew-resize")), Outcome::Redraw);
}

// A forced setCursorFromName ignores Hyprland's hidden state (IHyprRenderer::setCursorFromName, 0.56.2): calling it while
// the pointer is hidden (keyboard, touch, timeout, or a client's null surface) would show it. Never.
TEST(CursorRefresh, AHiddenPointerIsNeverShown) {
    auto state  = shownNamed("default");
    state.shown = false;
    EXPECT_EQ(decide(state), Outcome::Hidden);
    state.fromSurface = true; // a client hid it with a null surface
    state.name        = "";
    EXPECT_EQ(decide(state), Outcome::Hidden);
}

// A client's own cursor surface carries its own image and size: nothing to redraw, and never replaced by a theme shape.
TEST(CursorRefresh, AClientSurfaceIsLeftAlone) {
    SCursorState state{.shown = true, .fromSurface = true, .outputs = true, .name = ""};
    EXPECT_EQ(decide(state), Outcome::ClientSurface);
    state.name = "default"; // even if a stale name were recorded next to it
    EXPECT_EQ(decide(state), Outcome::ClientSurface);
}

TEST(CursorRefresh, NoShapeOrNoOutputMeansNothing) {
    EXPECT_EQ(decide(shownNamed("")), Outcome::NoShape) << "no guessed default shape";
    auto state    = shownNamed("default");
    state.outputs = false;
    EXPECT_EQ(decide(state), Outcome::NoOutput);
    EXPECT_EQ(decide(SCursorState{}), Outcome::Hidden);
}

TEST(CursorRefresh, OutcomeNamesAreStableWords) {
    EXPECT_EQ(outcomeName(Outcome::Redraw), "redraw");
    EXPECT_EQ(outcomeName(Outcome::Hidden), "hidden");
    EXPECT_EQ(outcomeName(Outcome::ClientSurface), "client-surface");
    EXPECT_EQ(outcomeName(Outcome::NoShape), "no-shape");
    EXPECT_EQ(outcomeName(Outcome::NoOutput), "no-output");
}

TEST(CursorRefresh, LoggedNamesArePlain) {
    EXPECT_EQ(loggableName("default"), "default");
    EXPECT_EQ(loggableName("left_ptr"), "left_ptr");
    EXPECT_EQ(loggableName("nwse-resize"), "nwse-resize");
    EXPECT_EQ(loggableName(""), "<other>");
    EXPECT_EQ(loggableName("a\nb"), "<other>");
    EXPECT_EQ(loggableName("x y"), "<other>");
    EXPECT_EQ(loggableName("\xc3\xa9"), "<other>");
    EXPECT_EQ(loggableName(std::string(48, 'a')), std::string(48, 'a'));
    EXPECT_EQ(loggableName(std::string(49, 'a')), "<other>");
}

// The shell's rate (one size per pointerApplyMs while a slider is dragged, 10/s in the brief) never waits.
TEST(CursorRefresh, TenRequestsPerSecondAllRunAtOnce) {
    CRefreshGate gate;
    for (int i = 0; i < 50; ++i)
        EXPECT_EQ(gate.request(T0 + milliseconds(100) * i).action, GateAction::Now) << i;
    EXPECT_EQ(gate.runs(), 50U);
    EXPECT_EQ(gate.folded(), 0U);
    EXPECT_FALSE(gate.waiting());
}

// A request soon after a run is not lost: it runs once when the interval ends (the last size is always drawn).
TEST(CursorRefresh, ARequestWithinTheIntervalRunsAtItsEnd) {
    CRefreshGate gate(milliseconds(25));
    EXPECT_EQ(gate.request(T0).action, GateAction::Now);
    const auto d = gate.request(T0 + milliseconds(10));
    EXPECT_EQ(d.action, GateAction::Arm);
    EXPECT_EQ(d.delay, milliseconds(15));
    EXPECT_TRUE(gate.waiting());
    EXPECT_EQ(gate.request(T0 + milliseconds(20)).action, GateAction::Fold);
    EXPECT_TRUE(gate.fire(T0 + milliseconds(25)));
    EXPECT_FALSE(gate.fire(T0 + milliseconds(26))) << "one run per armed timer";
    EXPECT_EQ(gate.runs(), 2U);
    EXPECT_EQ(gate.folded(), 1U);
    // The interval counts from the trailing run.
    EXPECT_EQ(gate.request(T0 + milliseconds(30)).action, GateAction::Arm);
    EXPECT_TRUE(gate.fire(T0 + milliseconds(50)));
    EXPECT_EQ(gate.request(T0 + milliseconds(100)).action, GateAction::Now);
}

// A flood (any local client can call the verb through the hyprctl socket, 1000 times in one Lua dispatch) costs two runs.
TEST(CursorRefresh, AFloodCostsOneRunPerInterval) {
    CRefreshGate gate;
    size_t       now = 0, armed = 0, folded = 0;
    for (int i = 0; i < 1000; ++i) {
        switch (gate.request(T0).action) {
            case GateAction::Now: ++now; break;
            case GateAction::Arm: ++armed; break;
            case GateAction::Fold: ++folded; break;
        }
    }
    EXPECT_EQ(now, 1U);
    EXPECT_EQ(armed, 1U);
    EXPECT_EQ(folded, 998U);
    EXPECT_TRUE(gate.fire(T0 + CRefreshGate::kDefaultInterval));
    EXPECT_EQ(gate.runs(), 2U);
}

TEST(CursorRefresh, ResetForgetsTheWaitingRun) {
    CRefreshGate gate;
    gate.request(T0);
    EXPECT_EQ(gate.request(T0 + milliseconds(1)).action, GateAction::Arm);
    gate.reset(); // unload: the timer is removed with it
    EXPECT_FALSE(gate.waiting());
    EXPECT_FALSE(gate.fire(T0 + milliseconds(30)));
    EXPECT_EQ(gate.request(T0 + milliseconds(2)).action, GateAction::Now) << "a new load starts quiet";
}
