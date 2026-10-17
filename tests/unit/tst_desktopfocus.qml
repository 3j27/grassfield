import QtQuick
import QtTest
import "../../shell/desktop/KeyboardFocus.js" as Focus

// Keyboard SAFE MODE of the desktop icons surface (docs/specs/desktop.md, "Keyboard safe mode
// (2026-10-17)"): the pure state machine behind it. The desktop surface never holds the keyboard on its
// own (None), the context menu window holds it (Exclusive) while the menu is open, and a rename field
// takes it (Exclusive) until it ends. Nobody re-takes the keyboard afterwards: Hyprland decides.
// Test names state the user-visible rule.
TestCase {
    id: testCase
    name: "DesktopFocus"

    function run(events, from) {
        let s = from || Focus.initial();
        for (const e of events)
            s = Focus.next(s, e);
        return s;
    }

    // Events that carry no keyboard meaning in safe mode (pointer, windows, workspaces, keys lost).
    readonly property var noise: [
        {type: "hover"},
        {type: "press"},
        {type: "release", hasKeys: false},
        {type: "pointer", away: true},
        {type: "pointer", away: false},
        {type: "keys", hasKeys: false},
        {type: "keys", hasKeys: true},
        {type: "openWindow", address: "55d0c8a3b2f0", workspace: "1", focusedWorkspace: "1"},
        {type: "activeWindow", address: "55d0c8a3b2f0"},
        {type: "closeWindow", address: "55d0c8a3b2f0"},
        {type: "workspace"},
        {type: "escape", hasSelection: false, renaming: false},
        {type: "unknown"}
    ]

    // Somebody always holds the keyboard from the moment a rename starts from the menu: the menu
    // window (Exclusive) or the rename surface (Exclusive), so no keystroke can fall through.
    function holder(s) {
        return Focus.menuHoldsKeys(s) || Focus.interactivity(s) === "exclusive";
    }

    // ---- the desktop never holds the keyboard on its own -------------------------------------------

    function test_desktopStartsWithoutKeyboardAfterShellRestart() {
        const s = Focus.initial();
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.menuMapped(s));
        verify(!Focus.menuHoldsKeys(s));
    }

    function test_firstClickAfterShellRestartDoesNotGiveTheDesktopTheKeyboard() {
        // A press and a release on the desktop, the keyboard going to / from it: still nothing held.
        const s = run([{type: "press"}, {type: "release", hasKeys: false}, {type: "keys", hasKeys: false}]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.menuMapped(s));
    }

    function test_clickingTheDesktopOrHoveringItNeverTakesTheKeyboard() {
        compare(run(noise).mode, "idle");
        compare(Focus.interactivity(run(noise)), "none");
    }

    function test_windowsOpeningClosingOrChangingWorkspaceNeverMakeTheDesktopTakeTheKeyboard() {
        const s = run([
            {type: "openWindow", address: "55d0c8a3b2f0", workspace: "1", focusedWorkspace: "1"},
            {type: "activeWindow", address: "55d0c8a3b2f0"},
            {type: "closeWindow", address: "55d0c8a3b2f0"},
            {type: "workspace"}
        ]);
        compare(Focus.interactivity(s), "none");
        verify(!holder(s));
    }

    function test_pointerOnAnotherMonitorChangesNothingInAnyMode() {
        // The pointer leaving / entering the desktop's monitor is not a keyboard event: the menu keeps
        // the keyboard, the rename keeps it, the idle desktop stays without it.
        const pointer = [{type: "pointer", away: true}, {type: "hover"}, {type: "pointer", away: false}, {type: "pointer", away: true}];
        const menu = run([{type: "menuOpened"}]);
        compare(run(pointer, menu), menu);
        const renaming = run([{type: "renameOpened"}]);
        compare(run(pointer, renaming), renaming);
        compare(run(pointer).mode, "idle");
        compare(Focus.interactivity(run(pointer)), "none");
    }

    // ---- context menu -------------------------------------------------------------------------------

    function test_openMenuHoldsTheKeyboardInItsOwnWindowNotTheDesktop() {
        const s = run([{type: "menuOpened"}]);
        compare(s.mode, "menu");
        verify(Focus.menuMapped(s));
        verify(Focus.menuHoldsKeys(s));
        compare(Focus.interactivity(s), "none");
    }

    function test_escOnTheMenuReleasesTheKeyboardAndTheDesktopDoesNotTakeItBack() {
        const s = run([{type: "menuOpened"}, {type: "menuClosed"}]);
        compare(s.mode, "idle");
        verify(!Focus.menuMapped(s));
        verify(!Focus.menuHoldsKeys(s));
        compare(Focus.interactivity(s), "none");
        // Nothing afterwards (focus changes by Hyprland, keys events) gives it back to the desktop.
        compare(Focus.interactivity(run(noise, s)), "none");
        verify(!holder(run(noise, s)));
    }

    function test_choosingAnItemOtherThanRenameReleasesTheKeyboardWithoutTakingItBack() {
        // Open, Copy, Move to Trash, New Folder failing: the menu simply closes.
        const s = run([{type: "menuOpened"}, {type: "menuClosed"}, {type: "menuClosed"}]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.menuMapped(s));
    }

    function test_clickingOutsideTheMenuOnAnAppWindowLeavesTheKeyboardToHyprland() {
        // The click closes the menu; Hyprland's focus events for the app window (the one it counts as
        // active) do not make the desktop or the menu take the keyboard: the app window receives typing.
        const s = run([
            {type: "menuOpened"},
            {type: "menuClosed"},
            {type: "activeWindow", address: "55d0c8a3b2f0"},
            {type: "press"},
            {type: "release", hasKeys: false},
            {type: "pointer", away: true}
        ]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.menuMapped(s));
        verify(!Focus.menuHoldsKeys(s));
    }

    function test_menuWindowStaysAwayFromTheKeyboardOnceClosedEvenIfHyprlandReportsFocusMeanwhile() {
        const s = run([{type: "menuOpened"}, {type: "activeWindow", address: "55d0c8a3b2f0"}]);
        compare(s.mode, "menu");
        verify(Focus.menuHoldsKeys(s));
        compare(Focus.interactivity(s), "none");
    }

    // ---- menu -> Rename hand-off ----------------------------------------------------------------------

    function test_renameFromTheMenuTakesTheKeyboardBeforeTheMenuReleasesIt() {
        let s = run([{type: "menuOpened"}, {type: "renameOpened"}]);
        // The rename surface is Exclusive now and the menu window still holds the keyboard: the
        // hand-off has no gap.
        compare(s.mode, "rename");
        compare(Focus.interactivity(s), "exclusive");
        verify(Focus.menuHoldsKeys(s));
        verify(Focus.menuMapped(s));
        // The commit of the rename surface is out: the menu lets go but stays mapped.
        s = run([{type: "committed"}], s);
        verify(!Focus.menuHoldsKeys(s));
        verify(Focus.menuMapped(s));
        compare(Focus.interactivity(s), "exclusive");
        // The rename surface has the keyboard: the menu window unmaps.
        s = run([{type: "keys", hasKeys: true}], s);
        verify(!Focus.menuMapped(s));
        verify(!Focus.menuHoldsKeys(s));
        compare(Focus.interactivity(s), "exclusive");
    }

    function test_noKeystrokeCanFallThroughDuringTheMenuToRenameHandOff() {
        let s = Focus.initial();
        for (const e of [{type: "menuOpened"}, {type: "renameOpened"}, {type: "menuClosed"}, {type: "committed"}, {type: "keys", hasKeys: true}]) {
            s = Focus.next(s, e);
            if (e.type !== "menuOpened")
                verify(holder(s), e.type);
        }
    }

    function test_theMenuClosingAfterItHandedOverToRenameDoesNotEndTheRename() {
        // IconsView hands over to the rename first and then clears the menu: its menuClosed is a no-op.
        const s = run([{type: "menuOpened"}, {type: "renameOpened"}, {type: "menuClosed"}]);
        compare(s.mode, "rename");
        compare(Focus.interactivity(s), "exclusive");
        verify(Focus.menuHoldsKeys(s));
    }

    function test_theMenuWindowDoesNotStayMappedForeverIfTheKeyboardNeverArrives() {
        // A locked session, no keyboard: the grace period ends the hand-off and the menu window unmaps.
        const s = run([{type: "menuOpened"}, {type: "renameOpened"}, {type: "committed"}, {type: "settled"}]);
        verify(!Focus.menuMapped(s));
        compare(s.mode, "rename");
    }

    function test_newFolderKeepsTheMenuWindowHoldingTheKeyboardUntilItsRenameFieldOpens() {
        // New Folder: the menu stays "menu" while the folder is created, then the rename takes over.
        let s = run([{type: "menuOpened"}]);
        verify(Focus.menuHoldsKeys(s));
        s = run([{type: "renameOpened"}], s);
        compare(s.mode, "rename");
        verify(holder(s));
        verify(Focus.menuHoldsKeys(s));
    }

    function test_newFolderThatFailsReleasesTheKeyboardToHyprland() {
        const s = run([{type: "menuOpened"}, {type: "menuClosed"}]);
        compare(s.mode, "idle");
        verify(!Focus.menuMapped(s));
        compare(Focus.interactivity(s), "none");
    }

    // ---- rename field --------------------------------------------------------------------------------

    function test_renameOutsideTheMenuTakesTheKeyboardDirectlyWithoutAMenuWindow() {
        const s = run([{type: "renameOpened"}]);
        compare(s.mode, "rename");
        compare(Focus.interactivity(s), "exclusive");
        verify(!Focus.menuMapped(s));
        verify(!Focus.menuHoldsKeys(s));
    }

    function test_renameKeepsTheKeyboardUntilItEnds() {
        const s = run(noise, run([{type: "renameOpened"}]));
        compare(s.mode, "rename");
        compare(Focus.interactivity(s), "exclusive");
    }

    function test_returnCommitsTheRenameAndReleasesTheKeyboardToHyprland() {
        const s = run([{type: "renameOpened"}, {type: "renameClosed"}]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!holder(s));
    }

    function test_escCancelsTheRenameAndReleasesTheKeyboardToHyprland() {
        const s = run([{type: "menuOpened"}, {type: "renameOpened"}, {type: "committed"}, {type: "keys", hasKeys: true}, {type: "renameClosed"}]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.menuMapped(s));
    }

    function test_clickOutsideCancelsTheRenameAndTheDesktopDoesNotKeepTheKeyboard() {
        // The click ends the rename (press on the desktop) and then the keyboard events and the
        // pointer leaving give nothing back to the desktop.
        const s = run([{type: "renameOpened"}, {type: "renameClosed"}, {type: "press"}, {type: "release", hasKeys: false}, {type: "activeWindow", address: "55d0c8a3b2f0"}]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!holder(s));
    }

    function test_clickOutsideDuringTheHandOffCancelsTheRenameAndUnmapsTheMenuWindow() {
        const s = run([{type: "menuOpened"}, {type: "renameOpened"}, {type: "renameClosed"}]);
        compare(s.mode, "idle");
        verify(!Focus.menuMapped(s));
        verify(!holder(s));
    }

    function test_aRenameEndingTwiceOrWhileTheMenuIsOpenNeverTouchesTheMenu() {
        const s = run([{type: "menuOpened"}, {type: "renameClosed"}]);
        compare(s.mode, "menu");
        verify(Focus.menuHoldsKeys(s));
        compare(run([{type: "renameClosed"}, {type: "renameClosed"}]).mode, "idle");
    }

    function test_aRenameReopenedAfterAFileSystemFailureTakesTheKeyboardAgain() {
        const s = run([{type: "renameOpened"}, {type: "renameClosed"}, {type: "renameOpened"}]);
        compare(s.mode, "rename");
        compare(Focus.interactivity(s), "exclusive");
    }

    function test_aSecondMenuOpensWithTheKeyboardAndReleasesItLikeTheFirst() {
        const s = run([{type: "renameOpened"}, {type: "renameClosed"}, {type: "menuOpened"}, {type: "menuClosed"}]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.menuMapped(s));
    }
}
