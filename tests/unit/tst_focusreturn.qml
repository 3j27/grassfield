import QtQuick
import QtTest
import "../../shell/platform/FocusReturn.js" as FR

// Returning the keyboard when an Exclusive surface closes (shell/platform/FocusReturn.*): the pure decisions. The C2 retry
// must never override a choice of the user, and nothing is requested after someone else focused a window.
TestCase {
    name: "FocusReturn"

    readonly property var goalA: ({address: "0xa"})

    function test_checkHoldsWhenTheGoalIsActive() {
        compare(FR.checkOutcome(goalA, {address: "0xb"}, {address: "0xa", workspaceId: 1}, 1, 10, 1000, false), "holds");
    }

    function test_retryWhileNothingChanged() {
        compare(FR.checkOutcome(goalA, {address: "0xb"}, {address: "0xb", workspaceId: 1}, 1, 10, 1000, false), "retry");
        compare(FR.checkOutcome(goalA, {address: ""}, null, 1, 10, 1000, false), "retry", "no window active yet");
    }

    function test_aThirdWindowIsTheUsersChoice() {
        compare(FR.checkOutcome(goalA, {address: "0xb"}, {address: "0xc", workspaceId: 1}, 1, 10, 1000, false), "user");
    }

    function test_aSurfaceOpeningEndsTheRetry() {
        compare(FR.checkOutcome(goalA, {address: "0xb"}, {address: "0xb", workspaceId: 1}, 1, 10, 1000, true), "surface");
    }

    function test_theBoundEndsTheRetry() {
        compare(FR.checkOutcome(goalA, {address: "0xb"}, {address: "0xb", workspaceId: 1}, 1, 1000, 1000, false), "bound");
        compare(FR.checkOutcome(goalA, {address: "0xb"}, {address: "0xb", workspaceId: 1}, 1, 999, 1000, false), "retry");
    }

    function test_holdsWinsOverTheOtherReasons() {
        compare(FR.checkOutcome(goalA, {address: "0xb"}, {address: "0xa"}, 1, 5000, 1000, true), "holds");
    }

    function test_aDesktopGoalFollowsTheFocusedDesktop() {
        const goal = {workspace: 2};
        compare(FR.checkOutcome(goal, {address: "", workspace: 1}, null, 2, 10, 1000, false), "holds");
        compare(FR.checkOutcome(goal, {address: "", workspace: 1}, null, 1, 10, 1000, false), "retry");
        compare(FR.checkOutcome(goal, {address: "", workspace: 1}, null, 3, 10, 1000, false), "user", "the user switched to another Desktop");
    }

    function test_noGoalNothingToDo() {
        verify(!FR.userActed(null, {address: "0xb"}, {address: "0xc"}, 1));
        compare(FR.checkOutcome(null, null, null, 1, 0, 1000, false), "holds");
    }

    function test_restoreTargetIsTheWindowActiveAtOpen() {
        compare(FR.restoreTarget({address: "0xa", workspaceId: 3}, {address: "0xa", workspaceId: 3}), {kind: "remembered", address: "0xa", workspace: 3});
        compare(FR.restoreTarget({address: "0xa", workspaceId: 0}, null), {kind: "remembered", address: "0xa"}, "no window reported now: still the one remembered");
    }

    function test_restoreTargetNothingWhenAnotherWindowWasFocused() {
        compare(FR.restoreTarget({address: "0xa", workspaceId: 3}, {address: "0xb", workspaceId: 3}), null);
    }

    function test_restoreTargetNothingWithoutAWindow() {
        compare(FR.restoreTarget(null, {address: "0xb"}), null);
        compare(FR.restoreTarget({address: "", workspaceId: 1}, null), null);
    }

    // ---- The frontmost changed while the surface was open (macOS: the key window is the frontmost one now) ----

    readonly property var opened: ({address: "a1", workspaceId: 3, gen: 4})

    function now(over) {
        return Object.assign({gen: 4, focusedWorkspaceId: 3, placement: {workspaceId: 3, parked: false}}, over || {});
    }

    function replay(events, remembered) {
        let gen = 0;
        for (const e of events)
            if (FR.changesFront(e[0], e[1], remembered))
                gen++;
        return gen;
    }

    function test_unchangedRestoresTheRememberedWindow() {
        compare(FR.restoreTarget(opened, null, now()), {kind: "remembered", address: "a1", workspace: 3});
    }

    function test_aStagesSwapMeanwhileRestoresNothing() {
        // Center open, the user clicks a strip tile: Hyprland has no active window under the layer, a stages event arrives.
        compare(replay([["activewindowv2", ""], ["stages", "{}"], ["activewindowv2", ""]], "a1"), 1);
        compare(FR.restoreTarget(opened, null, now({gen: 5})), null);
    }

    function test_aLayerClearingTheActiveWindowIsNotAChange() {
        compare(replay([["activewindowv2", ""], ["activewindowv2", "a1"], ["activewindowv2", "0xA1"]], "a1"), 0);
    }

    function test_anotherActiveWindowIsAChange() {
        compare(replay([["activewindowv2", "b2"]], "a1"), 1);
        compare(replay([["activewindowv2", "0xB2"]], "0xa1"), 1);
    }

    function test_eachTopologyEventIsAChange() {
        for (const name of ["openwindow", "closewindow", "movewindowv2", "workspacev2", "focusedmonv2", "activespecialv2", "stages"])
            compare(replay([[name, "x"]], "a1"), 1, name);
        for (const name of ["windowtitlev2", "openlayer", "closelayer", "fullscreen", ""])
            compare(replay([[name, "x"]], "a1"), 0, name);
    }

    function test_aDesktopSwitchMeansTheWindowIsNotOnTheFocusedDesktop() {
        compare(FR.restoreTarget(opened, null, now({focusedWorkspaceId: 4})), null);
    }

    function test_aWindowThatClosedMinimizedOrWentToASpecialWorkspaceIsNotPulledBack() {
        compare(FR.restoreTarget(opened, null, now({placement: null})), null, "closed");
        compare(FR.restoreTarget(opened, null, now({placement: {workspaceId: 3, parked: true}})), null, "minimized or hidden");
        compare(FR.restoreTarget(opened, null, now({placement: {workspaceId: -98, parked: false}})), null, "special:minimized, special:desktop");
        compare(FR.restoreTarget(opened, null, now({placement: {workspaceId: 0, parked: false}})), null, "no workspace");
    }

    function test_aWindowMovedToAnotherDesktopIsNotPulledBack() {
        compare(FR.restoreTarget(opened, null, now({placement: {workspaceId: 5, parked: false}, focusedWorkspaceId: 5})), null);
    }

    function test_aWindowWithoutAKnownDesktopAtOpenStillRestoresOnTheFocusedOne() {
        compare(FR.restoreTarget({address: "a1", workspaceId: 0, gen: 4}, null, now()), {kind: "remembered", address: "a1"});
    }
}
