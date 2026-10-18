#include "core/DesktopFocus.hpp"

#include <gtest/gtest.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <optional>

using namespace gf::desktopfocus;

namespace {
    Seat keyboardOn(SurfaceKind kind) {
        Seat seat;
        seat.keyboard = kind;
        return seat;
    }

    Press onWindow(bool primary = true) {
        Press p;
        p.target          = SurfaceKind::Window;
        p.primary         = primary;
        p.windowFocusable = true;
        return p;
    }

    Press onDesktop(Interactivity interactivity, bool primary = true) {
        Press p;
        p.target        = SurfaceKind::Desktop;
        p.interactivity = interactivity;
        p.primary       = primary;
        return p;
    }

    Press on(SurfaceKind kind) {
        Press p;
        p.target  = kind;
        p.primary = true;
        return p;
    }

    constexpr std::array ALL_KINDS = {SurfaceKind::None,       SurfaceKind::Desktop,    SurfaceKind::DesktopPopup, SurfaceKind::Window,
                                      SurfaceKind::WindowPopup, SurfaceKind::ShellLayer, SurfaceKind::OtherLayer,   SurfaceKind::Other};
} // namespace

// (1) of the review: the desktop holds the keyboard, a click on a window (also Hyprland's last window) gives it the keys.
TEST(DesktopFocusPolicy, PressOnWindowWhileDesktopHoldsKeyboardFocusesTheWindow) {
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Desktop), onWindow()), Action::FocusWindow);
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Desktop), onWindow(false)), Action::FocusWindow) << "any button, as Hyprland's click-to-focus";
}

TEST(DesktopFocusPolicy, PressOnWindowOtherwiseIsHyprlandsBusiness) {
    for (const auto holder : ALL_KINDS) {
        if (holder == SurfaceKind::Desktop)
            continue;
        EXPECT_EQ(onPress(keyboardOn(holder), onWindow()), Action::None) << kindName(holder);
    }
}

TEST(DesktopFocusPolicy, WindowThatCannotTakeFocusOrAlreadyHasItIsLeftAlone) {
    Press p           = onWindow();
    p.windowFocusable = false;
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Desktop), p), Action::None);
    p                   = onWindow();
    p.targetHasKeyboard = true;
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Desktop), p), Action::None);
}

// (2) of the review: a left press on the desktop gives it the keyboard without any pointer motion.
TEST(DesktopFocusPolicy, LeftPressOnOnDemandDesktopFocusesItNow) {
    for (const auto holder : ALL_KINDS) {
        if (holder == SurfaceKind::DesktopPopup)
            continue; // a popup holding the keyboard means a grab in practice; see PopupGrabIsUntouched
        EXPECT_EQ(onPress(keyboardOn(holder), onDesktop(Interactivity::OnDemand)), Action::FocusDesktop) << kindName(holder);
    }
}

TEST(DesktopFocusPolicy, LeftPressOnDesktopNotYetOnDemandWaitsForItsCommit) {
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Window), onDesktop(Interactivity::None)), Action::AwaitOnDemand);
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::None), onDesktop(Interactivity::None)), Action::AwaitOnDemand);
}

TEST(DesktopFocusPolicy, OtherPressesOnTheDesktopChangeNothing) {
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Window), onDesktop(Interactivity::OnDemand, false)), Action::None) << "right press: the menu";
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Window), onDesktop(Interactivity::None, false)), Action::None);
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Window), onDesktop(Interactivity::Exclusive)), Action::None) << "Hyprland focuses Exclusive itself";
    Press held             = onDesktop(Interactivity::OnDemand);
    held.targetHasKeyboard = true;
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Desktop), held), Action::None) << "already holds the keyboard";
}

// (3) of the review: the Dock, the menu bar, widgets and popups never take the keyboard from the desktop.
TEST(DesktopFocusPolicy, PressesOnShellLayersAndPopupsNeverMoveTheKeyboard) {
    for (const auto target : {SurfaceKind::None, SurfaceKind::DesktopPopup, SurfaceKind::WindowPopup, SurfaceKind::ShellLayer, SurfaceKind::OtherLayer, SurfaceKind::Other}) {
        for (const auto holder : ALL_KINDS)
            EXPECT_EQ(onPress(keyboardOn(holder), on(target)), Action::None) << kindName(holder) << " / " << kindName(target);
    }
}

TEST(DesktopFocusPolicy, PopupGrabIsUntouched) {
    // The desktop's menu holds the keyboard with a grab: an outside click is the grab's (dismissed and swallowed).
    Seat seat         = keyboardOn(SurfaceKind::DesktopPopup);
    seat.keyboardGrab = true;
    EXPECT_EQ(onPress(seat, onWindow()), Action::None);
    EXPECT_EQ(onPress(seat, onDesktop(Interactivity::OnDemand)), Action::None);
    EXPECT_EQ(onPress(seat, onDesktop(Interactivity::None)), Action::None);
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::DesktopPopup), onWindow()), Action::None);
}

TEST(DesktopFocusPolicy, LockGrabAndExclusiveLayersBlockEverything) {
    for (int flag = 0; flag < 3; ++flag) {
        Seat seat           = keyboardOn(SurfaceKind::Desktop);
        seat.locked         = flag == 0;
        seat.keyboardGrab   = flag == 1;
        seat.exclusiveLayer = flag == 2;
        EXPECT_EQ(onPress(seat, onWindow()), Action::None) << flag;
        EXPECT_EQ(onPress(seat, onDesktop(Interactivity::OnDemand)), Action::None) << flag;
        EXPECT_EQ(onPress(seat, onDesktop(Interactivity::None)), Action::None) << flag;
        EXPECT_FALSE(mayGrantDesktop(seat, false)) << flag;
    }
    EXPECT_TRUE(mayGrantDesktop(keyboardOn(SurfaceKind::Window), false));
    EXPECT_FALSE(mayGrantDesktop(keyboardOn(SurfaceKind::Desktop), true)) << "already has it";
}

TEST(DesktopFocusLayers, ClassifiesByNamespace) {
    EXPECT_EQ(classifyLayer("grassfield-desktop-icons", false), SurfaceKind::Desktop);
    EXPECT_EQ(classifyLayer("grassfield-desktop-icons", true), SurfaceKind::DesktopPopup);
    for (const auto ns : {"grassfield-dock", "grassfield-menubar", "grassfield-widgets", "grassfield-widgets-menu", "grassfield-desktop-kicker", "grassfield-overview"}) {
        EXPECT_EQ(classifyLayer(ns, false), SurfaceKind::ShellLayer) << ns;
        EXPECT_EQ(classifyLayer(ns, true), SurfaceKind::ShellLayer) << ns;
    }
    for (const auto ns : {"", "waybar", "grassfield", "Grassfield-desktop-icons", "grassfield-desktop-icons2", "xgrassfield-dock"}) {
        const auto kind = classifyLayer(ns, false);
        EXPECT_NE(kind, SurfaceKind::Desktop) << ns;
        EXPECT_NE(kind, SurfaceKind::DesktopPopup) << ns;
    }
    EXPECT_EQ(classifyLayer("waybar", false), SurfaceKind::OtherLayer);
    EXPECT_EQ(classifyLayer("grassfield-desktop-icons2", false), SurfaceKind::ShellLayer);
}

TEST(DesktopFocusLayers, InteractivityValuesOfTheProtocol) {
    EXPECT_EQ(interactivityFromProtocol(0), Interactivity::None);
    EXPECT_EQ(interactivityFromProtocol(1), Interactivity::Exclusive);
    EXPECT_EQ(interactivityFromProtocol(2), Interactivity::OnDemand);
    EXPECT_EQ(interactivityFromProtocol(3), Interactivity::None);
    EXPECT_EQ(interactivityFromProtocol(0xFFFFFFFF), Interactivity::None);
}

TEST(DesktopFocusGrant, OnDemandCommitAfterThePressGrantsOnce) {
    CPendingGrant g;
    const auto    t0 = Clock::now();
    g.arm(7, t0);
    EXPECT_TRUE(g.armed(t0));
    EXPECT_FALSE(g.onCommit(7, Interactivity::None, t0 + std::chrono::milliseconds(5))) << "a commit without on_demand keeps waiting";
    EXPECT_FALSE(g.onCommit(8, Interactivity::OnDemand, t0 + std::chrono::milliseconds(10))) << "another surface";
    EXPECT_TRUE(g.onCommit(7, Interactivity::OnDemand, t0 + std::chrono::milliseconds(30)));
    EXPECT_FALSE(g.armed(t0 + std::chrono::milliseconds(30)));
    EXPECT_FALSE(g.onCommit(7, Interactivity::OnDemand, t0 + std::chrono::milliseconds(40))) << "consumed";
}

TEST(DesktopFocusGrant, ExpiresAfterTheGrantWindow) {
    CPendingGrant g;
    const auto    t0 = Clock::now();
    g.arm(7, t0);
    EXPECT_TRUE(g.armed(t0 + kGrantWindow));
    EXPECT_FALSE(g.armed(t0 + kGrantWindow + std::chrono::milliseconds(1)));
    EXPECT_FALSE(g.onCommit(7, Interactivity::OnDemand, t0 + kGrantWindow + std::chrono::milliseconds(1)));
    EXPECT_FALSE(g.surface().has_value()) << "an expired grant is dropped";
}

TEST(DesktopFocusGrant, CancelAndRearm) {
    CPendingGrant g;
    const auto    t0 = Clock::now();
    EXPECT_FALSE(g.onCommit(7, Interactivity::OnDemand, t0)) << "nothing armed";
    g.arm(7, t0);
    g.cancel();
    EXPECT_FALSE(g.onCommit(7, Interactivity::OnDemand, t0));
    g.arm(7, t0);
    g.arm(9, t0 + std::chrono::milliseconds(100)); // a later press on another output's desktop
    EXPECT_EQ(g.surface(), 9U);
    EXPECT_FALSE(g.onCommit(7, Interactivity::OnDemand, t0 + std::chrono::milliseconds(120)));
    EXPECT_TRUE(g.onCommit(9, Interactivity::OnDemand, t0 + std::chrono::milliseconds(130)));
}

// Shell integration (main 9e76bd7): menu open, pointer moved onto a foot, Esc, click without motion. The pointer focus is
// the closed popup's surface (destroyed: none; unmapped: stale); the press must count as a press on the foot under the cursor.
TEST(DesktopFocusTarget, LivePointerFocusIsWhereThePressGoes) {
    EXPECT_EQ(pressTargetSource(PointerFocus::Live), TargetSource::PointerFocus);
    EXPECT_EQ(pressTargetKind(PointerFocus::Live, SurfaceKind::WindowPopup, SurfaceKind::Window), SurfaceKind::WindowPopup);
    EXPECT_EQ(pressTargetKind(PointerFocus::Live, SurfaceKind::Desktop, SurfaceKind::Window), SurfaceKind::Desktop);
}

TEST(DesktopFocusTarget, MissingOrStalePointerFocusFallsBackToTheSurfaceUnderTheCursor) {
    for (const auto focus : {PointerFocus::None, PointerFocus::Stale}) {
        EXPECT_EQ(pressTargetSource(focus), TargetSource::UnderCursor);
        EXPECT_EQ(pressTargetKind(focus, SurfaceKind::DesktopPopup, SurfaceKind::Window), SurfaceKind::Window);
        EXPECT_EQ(pressTargetKind(focus, SurfaceKind::None, SurfaceKind::Desktop), SurfaceKind::Desktop);
        EXPECT_EQ(pressTargetKind(focus, SurfaceKind::Other, SurfaceKind::None), SurfaceKind::None) << "nothing under the cursor either";
    }
}

// R13 review of 46b3e9b: after a Stages swap without pointer motion, Hyprland's pointer focus is still the surface of a
// window that went to the strip (input blocked). It must not count as live: the press target is what lies under the cursor.
TEST(DesktopFocusTarget, PointerFocusOnABlockedWindowIsStale) {
    EXPECT_EQ(classifyPointerFocus(true, true, true, true), PointerFocus::Live);
    EXPECT_EQ(classifyPointerFocus(true, true, true, false), PointerFocus::Stale) << "a strip window (input blocked)";
    EXPECT_EQ(classifyPointerFocus(true, true, false, true), PointerFocus::Stale) << "an unmapped or hidden view";
    EXPECT_EQ(classifyPointerFocus(true, false, true, true), PointerFocus::Stale) << "a surface of no window or layer";
    EXPECT_EQ(classifyPointerFocus(false, true, true, true), PointerFocus::None);
    EXPECT_EQ(pressTargetSource(classifyPointerFocus(true, true, true, false)), TargetSource::UnderCursor);
}

TEST(DesktopFocusTarget, TheFallbackFeedsTheSameDecisionTable) {
    // The repro: the desktop holds the keyboard, the closed menu's popup is the stale pointer focus, a foot is under the cursor.
    Press p           = onWindow();
    p.target          = pressTargetKind(PointerFocus::Stale, SurfaceKind::DesktopPopup, SurfaceKind::Window);
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Desktop), p), Action::FocusWindow);
    // Without the fallback the stale popup would have been the target, and nothing would have moved the keyboard.
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Desktop), on(SurfaceKind::DesktopPopup)), Action::None);
    EXPECT_EQ(onPress(keyboardOn(SurfaceKind::Desktop), on(SurfaceKind::None)), Action::None);
}

// R13 review of 5706cbd: a key binding, a new window or a workspace switch within the grant window must win over the
// desktop's late on_demand commit.
TEST(DesktopFocusGrant, KeyboardMovedElsewhereCancelsTheGrant) {
    using namespace std::chrono_literals;
    const auto t0 = Clock::now();
    for (const auto holder : {std::optional<uint64_t>{}, std::optional<uint64_t>{9}}) { // a window / nothing, or another layer
        CPendingGrant g;
        g.arm(7, t0);
        EXPECT_EQ(g.onFocusEvent(FocusEvent::KeyboardFocus, holder, t0 + 20ms), GrantUpdate::Cancelled);
        EXPECT_FALSE(g.armed(t0 + 20ms));
        EXPECT_FALSE(g.onCommit(7, Interactivity::OnDemand, t0 + 30ms)) << "the late on_demand commit does not take the keyboard back";
    }
}

TEST(DesktopFocusGrant, WindowWorkspaceAndActivationChangesCancelTheGrant) {
    using namespace std::chrono_literals;
    const auto t0 = Clock::now();
    for (const auto event : {FocusEvent::WindowActivated, FocusEvent::WindowOpened, FocusEvent::WorkspaceChanged}) {
        CPendingGrant g;
        g.arm(7, t0);
        // Even with the armed desktop named: only a keyboard move onto it fulfils the grant.
        EXPECT_EQ(g.onFocusEvent(event, std::optional<uint64_t>{7}, t0 + 500ms), GrantUpdate::Cancelled) << focusEventName(event);
        EXPECT_FALSE(g.onCommit(7, Interactivity::OnDemand, t0 + 510ms)) << focusEventName(event);
    }
}

TEST(DesktopFocusGrant, KeyboardReachingTheArmedDesktopFulfilsTheGrant) {
    using namespace std::chrono_literals;
    const auto    t0 = Clock::now();
    CPendingGrant g;
    g.arm(7, t0);
    EXPECT_EQ(g.onFocusEvent(FocusEvent::KeyboardFocus, std::optional<uint64_t>{7}, t0 + 10ms), GrantUpdate::Fulfilled);
    EXPECT_FALSE(g.surface().has_value()) << "nothing left to do";
    EXPECT_FALSE(g.onCommit(7, Interactivity::OnDemand, t0 + 20ms));
}

TEST(DesktopFocusGrant, FocusEventsWithoutAWaitingGrantChangeNothing) {
    using namespace std::chrono_literals;
    const auto    t0 = Clock::now();
    CPendingGrant g;
    EXPECT_EQ(g.onFocusEvent(FocusEvent::KeyboardFocus, std::nullopt, t0), GrantUpdate::NotArmed);
    g.arm(7, t0);
    EXPECT_TRUE(g.onCommit(7, Interactivity::OnDemand, t0 + 16ms)); // granted (consumed) ...
    EXPECT_EQ(g.onFocusEvent(FocusEvent::KeyboardFocus, std::optional<uint64_t>{7}, t0 + 17ms), GrantUpdate::NotArmed)
        << "... and the keyboard event of that grant itself finds nothing waiting";
    g.arm(7, t0);
    EXPECT_EQ(g.onFocusEvent(FocusEvent::WindowOpened, std::nullopt, t0 + kGrantWindow + 1ms), GrantUpdate::NotArmed) << "expired: dropped silently";
    EXPECT_FALSE(g.surface().has_value());
}

TEST(DesktopFocusGrant, ANewPressAfterACancelArmsAgain) {
    using namespace std::chrono_literals;
    const auto    t0 = Clock::now();
    CPendingGrant g;
    g.arm(7, t0);
    EXPECT_EQ(g.onFocusEvent(FocusEvent::WorkspaceChanged, std::nullopt, t0 + 5ms), GrantUpdate::Cancelled);
    g.arm(7, t0 + 100ms);
    EXPECT_TRUE(g.onCommit(7, Interactivity::OnDemand, t0 + 116ms));
}

TEST(DesktopFocusNames, AreStable) {
    EXPECT_EQ(grantUpdateName(GrantUpdate::Cancelled), "cancelled");
    EXPECT_EQ(grantUpdateName(GrantUpdate::Fulfilled), "fulfilled");
    EXPECT_EQ(grantUpdateName(GrantUpdate::NotArmed), "not-armed");
    EXPECT_EQ(focusEventName(FocusEvent::WorkspaceChanged), "workspace changed");
    EXPECT_EQ(actionName(Action::FocusWindow), "focus-window");
    EXPECT_EQ(actionName(Action::FocusDesktop), "focus-desktop");
    EXPECT_EQ(actionName(Action::AwaitOnDemand), "await-on-demand");
    EXPECT_EQ(actionName(Action::None), "none");
    EXPECT_EQ(kindName(SurfaceKind::Desktop), "desktop");
    EXPECT_EQ(kindName(SurfaceKind::ShellLayer), "shell-layer");
    EXPECT_EQ(kDesktopNamespace, "grassfield-desktop-icons");
}
