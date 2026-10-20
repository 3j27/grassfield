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
}
