#include "core/OverviewFocus.hpp"
#include "core/Protocol.hpp"

#include <gtest/gtest.h>

#include <string>
#include <vector>

using namespace gf::overviewfocus;
namespace df = gf::deferredfocus;

// ---- requests ----

TEST(OverviewFocusRequest, TheFourTargets) {
    auto r = parseRequest(R"({"target":"window","address":"0x55aa01"})");
    ASSERT_TRUE(r.has_value()) << r.error();
    EXPECT_EQ(r->target, Target::Window);
    EXPECT_EQ(r->window, 0x55aa01U);
    EXPECT_EQ(r->workspace, 0);
    EXPECT_EQ(r->id, 0U);

    r = parseRequest(R"({"target":"workspace","workspace":3,"id":7})");
    ASSERT_TRUE(r.has_value()) << r.error();
    EXPECT_EQ(r->target, Target::Workspace);
    EXPECT_EQ(r->workspace, 3);
    EXPECT_EQ(r->id, 7U);

    r = parseRequest(R"( { "target" : "remembered" , "address" : "0xABC" , "workspace" : 2 } )");
    ASSERT_TRUE(r.has_value()) << r.error();
    EXPECT_EQ(r->target, Target::Remembered);
    EXPECT_EQ(r->window, 0xabcU);
    EXPECT_EQ(r->workspace, 2);

    r = parseRequest(R"({"target":"remembered","address":"0x1"})");
    ASSERT_TRUE(r.has_value()) << "the remembered Desktop is optional";
    EXPECT_EQ(r->workspace, 0);

    r = parseRequest(R"({"target":"none","id":4294967295})");
    ASSERT_TRUE(r.has_value()) << r.error();
    EXPECT_EQ(r->target, Target::None);
    EXPECT_EQ(r->id, 4294967295U);

    r = parseRequest(R"({"target":"none","later":{"field":[1,2]}})");
    EXPECT_TRUE(r.has_value()) << "unknown keys are skipped (additive gfc/1 fields)";
}

TEST(OverviewFocusRequest, InvalidPayloadsAreRefused) {
    const std::vector<std::string> invalid = {
        "",
        "[]",
        "{}",                                                          // target required
        R"({"target":"press","address":"0x1"})",                       // never requested
        R"({"target":"desktop"})",                                     // unknown target
        R"({"target":1})",                                             // not a string
        R"({"target":"window"})",                                      // address required
        R"({"target":"window","address":"0x"})",                       // no digits
        R"({"target":"window","address":"0x0"})",                      // no window has address 0
        R"({"target":"window","address":"0x11111111111111111"})",      // 17 digits
        R"({"target":"window","address":"0x1","workspace":2})",        // the window's own Desktop is used
        R"({"target":"workspace"})",                                   // workspace required
        R"({"target":"workspace","workspace":0})",                     // regular Desktops only
        R"({"target":"workspace","workspace":-98})",                   // special workspaces are never targets
        R"({"target":"workspace","workspace":2.5})",                   // integer
        R"({"target":"workspace","workspace":2147483648})",            // range
        R"({"target":"workspace","workspace":"2"})",                   // number
        R"({"target":"workspace","workspace":2,"address":"0x1"})",     // no address for a Desktop
        R"({"target":"remembered","workspace":2})",                    // address required (nothing remembered: none)
        R"({"target":"none","address":"0x1"})",                        // none takes nothing
        R"({"target":"none","workspace":1})",
        R"({"target":"none","id":-1})",
        R"({"target":"none","id":4294967296})",
        R"({"target":"none","target":"none"})",                        // twice
        R"({"target":"window","address":"0x1","address":"0x2"})",
        R"({"target":"none"} x)",                                      // trailing characters
        R"({"target":"none",})",
        R"({"target":"none","deep":[[[[[[[1]]]]]]]})",                 // nesting of skipped values bounded
    };
    for (const auto& json : invalid)
        EXPECT_FALSE(parseRequest(json).has_value()) << json;
    EXPECT_FALSE(parseRequest(std::string(kMaxPayloadBytes + 1, ' ')).has_value()) << "size limit";
}

// ---- when ----

TEST(OverviewFocusGate, WaitsForTheLastExclusiveLayerAndNeverFocusesUnderTheLock) {
    EXPECT_EQ(step({}), Step::Apply) << "Hyprland accepts window focus";
    EXPECT_EQ(step({.locked = false, .exclusive = true, .expired = false}), Step::Wait) << "a chrome or a dialog is still Exclusive";
    EXPECT_EQ(step({.locked = false, .exclusive = true, .expired = true}), Step::Timeout) << "a dialog stayed: give up, Hyprland's choice stands";
    EXPECT_EQ(step({.locked = false, .exclusive = false, .expired = true}), Step::Apply) << "the layer went just at the bound";
    EXPECT_EQ(step({.locked = true, .exclusive = false, .expired = false}), Step::Refuse) << "the lock: nothing focused";
    EXPECT_EQ(step({.locked = true, .exclusive = true, .expired = true}), Step::Refuse);
}

// ---- what ----

TEST(OverviewFocusTarget, TheNamedWindowMustStillBeShown) {
    EXPECT_EQ(judgeWindow({.exists = true, .hidden = false, .minimized = false, .shown = true}), WindowVerdict::Eligible);
    EXPECT_EQ(judgeWindow({}), WindowVerdict::Gone) << "closed meanwhile";
    EXPECT_EQ(judgeWindow({.exists = true, .hidden = true, .minimized = true, .shown = false}), WindowVerdict::Minimized) << "on special:minimized";
    EXPECT_EQ(judgeWindow({.exists = true, .hidden = true, .minimized = false, .shown = true}), WindowVerdict::Hidden);
    EXPECT_EQ(judgeWindow({.exists = true, .hidden = false, .minimized = false, .shown = false}), WindowVerdict::NotShown) << "dragged to another Desktop";
}

TEST(OverviewFocusTarget, PlanPerTarget) {
    const WorkspaceFacts none{};
    for (const auto target : {Target::Window, Target::Remembered, Target::Press}) {
        EXPECT_EQ(plan(target, WindowVerdict::Eligible, none).plan, Plan::FocusWindow);
        EXPECT_EQ(plan(target, WindowVerdict::Gone, none).plan, Plan::Fallback);
        EXPECT_EQ(plan(target, WindowVerdict::Gone, none).why, "gone");
        EXPECT_EQ(plan(target, WindowVerdict::Minimized, none).why, "minimized");
        EXPECT_EQ(plan(target, WindowVerdict::Hidden, none).why, "hidden");
        EXPECT_EQ(plan(target, WindowVerdict::NotShown, none).why, "not-shown");
    }
    EXPECT_EQ(plan(Target::Workspace, WindowVerdict::Gone, {.exists = true, .shown = true}).plan, Plan::Front) << "the current Desktop: its front window";
    EXPECT_EQ(plan(Target::Workspace, WindowVerdict::Gone, {.exists = true, .shown = false}).plan, Plan::SwitchThenFront) << "another Desktop";
    const auto missing = plan(Target::Workspace, WindowVerdict::Gone, {.exists = false, .shown = false});
    EXPECT_EQ(missing.plan, Plan::Fallback);
    EXPECT_EQ(missing.why, "no-workspace");
    const auto nothing = plan(Target::None, WindowVerdict::Gone, none);
    EXPECT_EQ(nothing.plan, Plan::Fallback) << "no target: the keyboard still goes somewhere sensible (review: nothing focused)";
    EXPECT_EQ(nothing.why, "none");
}

TEST(OverviewFocusTarget, FallbackDesktop) {
    EXPECT_EQ(fallbackSpace(Target::Remembered, true), FallbackSpace::Remembered) << "macOS: back to the Desktop you were on";
    EXPECT_EQ(fallbackSpace(Target::Remembered, false), FallbackSpace::FocusedMonitor);
    for (const auto target : {Target::Window, Target::Workspace, Target::None, Target::Press})
        EXPECT_EQ(fallbackSpace(target, true), FallbackSpace::FocusedMonitor);
}

TEST(OverviewFocusTarget, FrontWindowOrder) {
    auto c = [](WindowId id, bool on = true) { return Candidate{.id = id, .onWorkspace = on, .mapped = true, .hidden = false, .takesInput = true, .focusable = true}; };
    std::vector<Candidate> stack = {c(0x1), c(0x2), c(0x3, false), c(0x4)}; // bottom to top
    EXPECT_EQ(frontOrder(stack), (std::vector<WindowId>{0x4, 0x2, 0x1})) << "nothing focused since the load: top of the stack first, other Desktops skipped";
    stack[0].focusSeq = 7; // the most recently focused, at the bottom of the stack (Hyprland did not raise it)
    stack[1].focusSeq = 3;
    stack[2].focusSeq = 9; // on another Desktop
    EXPECT_EQ(frontOrder(stack), (std::vector<WindowId>{0x1, 0x2, 0x4})) << "the activation order first, then the stack";
    stack[3].takesInput = false; // a Stages strip window (input blocked)
    stack[1].hidden     = true;
    EXPECT_EQ(frontOrder(stack), (std::vector<WindowId>{0x1}));
    stack[0].focusable = false; // an X11 window that refuses focus
    EXPECT_TRUE(frontOrder(stack).empty()) << "nothing eligible: no window (the desktop)";
    stack[0].focusable = true;
    stack[0].mapped    = false;
    EXPECT_TRUE(frontOrder(stack).empty());
    EXPECT_TRUE(frontOrder({}).empty());
}

// ---- the user's input while a request waits ----

TEST(OverviewFocusInput, APressAfterTheRequestWins) {
    EXPECT_EQ(pressEffect(df::recordPress({.exclusive = true, .onExclusive = true, .under = 0x10})), PressEffect::None) << "into the chrome or a dialog";
    EXPECT_EQ(pressEffect(df::recordPress({.exclusive = true, .onExclusive = false, .under = 0})), PressEffect::None) << "beside the layers, on no window";
    const auto beside = df::recordPress({.exclusive = true, .onExclusive = false, .under = 0x10});
    EXPECT_EQ(pressEffect(beside), PressEffect::Retarget) << "beside every Exclusive layer, on a window: that window";
    EXPECT_EQ(beside.target, 0x10U);
    EXPECT_EQ(pressEffect(df::recordPress({.exclusive = false, .onExclusive = false, .under = 0})), PressEffect::Supersede) << "Hyprland's click focus decides";
    EXPECT_EQ(pressEffect(df::PressRecord{.scope = df::PressScope::UntilFocus, .target = 0}), PressEffect::None);
}

TEST(OverviewFocusInput, OnlyAUserChoiceOfAnotherWindowEndsTheRequest) {
    using O = df::FocusOrigin;
    EXPECT_TRUE(supersedes(O::UserChoice, false)) << "a key binding, a dispatch, an activation of another window";
    EXPECT_FALSE(supersedes(O::UserChoice, true)) << "the target itself: the attempt reports it focused";
    for (const auto origin : {O::Restore, O::CursorRefocus, O::AfterClose, O::Automatic})
        EXPECT_FALSE(supersedes(origin, false)) << "Hyprland's own pick: " << static_cast<int>(origin);
    EXPECT_EQ(df::focusOrigin(df::FocusCause::PointerFollow, true, false), O::Restore) << "refocusLastWindow after a layer";
    EXPECT_EQ(df::focusOrigin(df::FocusCause::Click, true, false), O::CursorRefocus) << "a refocus at the cursor without a press";
}

// ---- events ----

TEST(OverviewFocusEvents, Json) {
    EXPECT_EQ(eventJson({.outcome = Outcome::Pending, .target = Target::Window, .id = 3, .window = std::nullopt, .workspace = std::nullopt, .reason = ""}),
              R"({"v":"gfc/1","type":"overview-focus","outcome":"pending","target":"window","id":3})");
    EXPECT_EQ(eventJson({.outcome = Outcome::Focused, .target = Target::Remembered, .id = 0, .window = 0x55aa01, .workspace = 2, .reason = ""}),
              R"({"v":"gfc/1","type":"overview-focus","outcome":"focused","target":"remembered","id":0,"address":"55aa01","workspace":2})");
    EXPECT_EQ(eventJson({.outcome = Outcome::Fallback, .target = Target::Window, .id = 9, .window = std::nullopt, .workspace = 1, .reason = "minimized"}),
              R"({"v":"gfc/1","type":"overview-focus","outcome":"fallback","target":"window","id":9,"workspace":1,"reason":"minimized"})");
    EXPECT_EQ(eventJson({.outcome = Outcome::Timeout, .target = Target::Press, .id = 1, .window = std::nullopt, .workspace = std::nullopt, .reason = "exclusive-layer"}),
              R"({"v":"gfc/1","type":"overview-focus","outcome":"timeout","target":"press","id":1,"reason":"exclusive-layer"})");
    for (const auto outcome : {Outcome::Refused, Outcome::Superseded, Outcome::Unavailable, Outcome::Invalid})
        EXPECT_NE(eventJson({.outcome = outcome, .target = Target::None, .id = 0, .window = std::nullopt, .workspace = std::nullopt, .reason = ""}).find(outcomeName(outcome)),
                  std::string::npos);
}

TEST(OverviewFocusEvents, CapabilityIsAdvertisedLast) {
    using namespace gf::gfc;
    EXPECT_EQ(capabilitiesJson(features(false, false, false, false, false, false, false, false, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","overview-focus"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, false, true, true)),
              R"({"v":"gfc/1","type":"capabilities","features":["decorations","minimize","config","appmenu","overview","desktop-focus","desktop-focus-v2","stages-available","cursor-refresh","overview-focus"]})");
    EXPECT_EQ(capabilitiesJson(features(true, true, true, true, true, true, true, true, false)).find("overview-focus"), std::string::npos);
    EXPECT_EQ(luaDispatchRequest(kLuaOverviewFocus), "hl.plugin.grassfield.overview_focus()");
}
