import QtQuick
import QtTest
import "../../shell/desktop/KeyboardFocus.js" as Focus

// Keyboard focus state machine of the desktop icons surface (docs/specs/desktop.md, "Keyboard focus"):
// every transition, the interactivity of each mode, the explicit focus of new windows and the Glance
// round trip, and the parsing/validation of Hyprland event data.
TestCase {
    id: testCase
    name: "DesktopFocus"

    readonly property string a1: "55d0c8a3b2f0"
    readonly property string a2: "55d0c8a3c400"

    function run(events, from) {
        let s = from || Focus.initial();
        let focus = [];
        for (const e of events) {
            const r = Focus.next(s, e);
            s = r.state;
            if (r.focus !== "")
                focus.push(r.focus);
        }
        return {state: s, focus: focus};
    }

    // A state with the pointer on the desktop unless `extra` says otherwise.
    function st(mode, extra) {
        return Object.assign({mode: mode, away: false, lent: "", lendNext: false, reclaim: false, menu: false, active: ""}, extra || {});
    }

    function openWin(address, ws, focused, returnsFocus) {
        return {type: "openWindow", address: address, workspace: ws, focusedWorkspace: focused, returnsFocus: returnsFocus === true};
    }

    // ---- defaults and interactivity --------------------------------------------------------------

    function test_initialIsNone() {
        const s = Focus.initial();
        compare(s.mode, "none");
        compare(s.away, true);
        compare(Focus.interactivity(s), "none");
        verify(!Focus.holdsKeys(s));
    }

    function test_interactivityPerMode() {
        compare(Focus.interactivity(st("none")), "none");
        compare(Focus.interactivity(st("hold")), "onDemand");
        compare(Focus.interactivity(st("take")), "exclusive");
        // The menu window holds the keyboard while the menu is open, never the desktop.
        compare(Focus.interactivity(st("menu")), "none");
        verify(Focus.holdsKeys(st("hold")));
        verify(Focus.holdsKeys(st("take")));
        verify(Focus.holdsKeys(st("menu")));
    }

    // ---- hover never takes the keyboard ----------------------------------------------------------

    function test_hoverNeverChanges() {
        for (const m of ["none", "hold", "take", "menu"])
            compare(Focus.next(st(m), {type: "hover"}).state.mode, m);
        compare(Focus.next(st("none"), {type: "unknown"}).state.mode, "none");
    }

    // ---- press / release / keys ------------------------------------------------------------------

    function test_pressHolds() {
        compare(run([{type: "press"}]).state.mode, "hold");
        compare(run([{type: "press"}], st("hold")).state.mode, "hold");
    }

    function test_pressKeepsMenuAndTake() {
        compare(run([{type: "press"}], st("menu")).state.mode, "menu");
        compare(run([{type: "press"}], st("take")).state.mode, "take");
    }

    function test_pressClearsLentAndLendNext() {
        const s = run([{type: "press"}], st("none", {lent: a1, lendNext: true})).state;
        compare(s.lent, "");
        compare(s.lendNext, false);
    }

    function test_releaseWithoutKeysTakes() {
        const s = run([{type: "press"}, {type: "release", hasKeys: false}]).state;
        compare(s.mode, "take");
        compare(Focus.interactivity(s), "exclusive");
        compare(s.reclaim, false);
    }

    function test_releaseWithKeysStaysHold() {
        compare(run([{type: "press"}, {type: "release", hasKeys: true}]).state.mode, "hold");
    }

    function test_releaseOutsideHoldIsIgnored() {
        compare(run([{type: "release", hasKeys: false}]).state.mode, "none");
        compare(run([{type: "release", hasKeys: false}], st("menu")).state.mode, "menu");
    }

    function test_takeEndsOnKeys() {
        compare(run([{type: "keys", hasKeys: true}], st("take")).state.mode, "hold");
    }

    function test_takeEndsOnCommitted() {
        compare(run([{type: "committed"}], st("take")).state.mode, "hold");
        compare(run([{type: "committed"}], st("none")).state.mode, "none");
        compare(run([{type: "committed"}], st("menu")).state.mode, "menu");
    }

    function test_takeIgnoresKeysLost() {
        compare(run([{type: "keys", hasKeys: false}], st("take")).state.mode, "take");
    }

    function test_holdReleasedWhenKeysLost() {
        compare(run([{type: "keys", hasKeys: false}], st("hold")).state.mode, "none");
        // Gaining keys outside "take" changes nothing.
        compare(run([{type: "keys", hasKeys: true}], st("none")).state.mode, "none");
        compare(run([{type: "keys", hasKeys: false}], st("menu")).state.mode, "menu");
    }

    // ---- pointer leaving the desktop ---------------------------------------------------------------

    function test_pointerAwayReleasesHold() {
        // Click the desktop, then the window Hyprland still counts as focused: the pointer leaves
        // the desktop on the way, which hands that window its keyboard back.
        const r = run([{type: "press"}, {type: "release", hasKeys: false}, {type: "keys", hasKeys: true}, {type: "pointer", away: true}]);
        compare(r.state.mode, "none");
        compare(r.state.away, true);
        compare(r.focus, []);
    }

    function test_pointerBackNeverTakes() {
        const s = run([{type: "pointer", away: false}]).state;
        compare(s.mode, "none");
        compare(s.away, false);
        compare(run([{type: "pointer", away: false}], st("hold", {away: true})).state.mode, "hold");
    }

    function test_pointerAwayOutsideHoldOnlyRecords() {
        for (const m of ["none", "take", "menu"]) {
            const s = run([{type: "pointer", away: true}], st(m)).state;
            compare(s.mode, m);
            compare(s.away, true);
        }
    }

    function test_takeOrMenuEndsReleasedWhenAway() {
        compare(run([{type: "keys", hasKeys: true}], st("take", {away: true})).state.mode, "none");
        compare(run([{type: "committed"}], st("take", {away: true})).state.mode, "none");
        compare(run([{type: "committed"}], run([{type: "menuClosed"}], st("menu", {away: true})).state).state.mode, "none");
    }

    function test_pressMeansThePointerIsBack() {
        compare(run([{type: "press"}], st("none", {away: true})).state.away, false);
    }

    // ---- menu and rename handoffs ----------------------------------------------------------------

    function test_menuOpenGivesTheKeyboardToTheMenuWindow() {
        // Hyprland routes the pointer only to an Exclusive layer: the desktop must not be one.
        const s = run([{type: "press"}, {type: "menuOpened"}]).state;
        compare(s.mode, "menu");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.menuLingers(s));
    }

    function test_menuCloseTakesTheKeyboardBackBeforeTheMenuUnmaps() {
        let s = run([{type: "press"}, {type: "menuOpened"}]).state;
        s = run([{type: "menuClosed"}], s).state;
        // The desktop is Exclusive while the menu window is still mapped.
        compare(s.mode, "take");
        compare(Focus.interactivity(s), "exclusive");
        verify(Focus.menuLingers(s));
        // Keyboard arrived (or the commit went out): the menu may unmap, the desktop holds.
        let a = run([{type: "keys", hasKeys: true}], s).state;
        compare(a.mode, "hold");
        verify(!Focus.menuLingers(a));
        a = run([{type: "committed"}], s).state;
        compare(a.mode, "hold");
        verify(!Focus.menuLingers(a));
        // A press meanwhile (on the lingering menu window) keeps the handoff.
        verify(Focus.menuLingers(run([{type: "press"}], s).state));
        // Pointer away: released once it is done.
        compare(run([{type: "pointer", away: true}, {type: "committed"}], s).state.mode, "none");
    }

    function test_menuCloseKeepsTheMenuMappedEvenWhenAway() {
        const s = run([{type: "menuClosed"}], st("menu", {away: true})).state;
        compare(s.mode, "take");
        verify(Focus.menuLingers(s));
        compare(run([{type: "committed"}], s).state.mode, "none");
    }

    function test_menuClosedOutsideMenuIsIgnored() {
        compare(run([{type: "menuClosed"}]).state.mode, "none");
        compare(run([{type: "menuClosed"}], st("hold")).state.mode, "hold");
    }

    function test_menuThenRenameKeepsTheKeyboard() {
        // Menu -> Rename: the rename opens while the desktop holds the keyboard.
        const s = run([{type: "press"}, {type: "menuOpened"}, {type: "menuClosed"}, {type: "renameOpened"}, {type: "keys", hasKeys: true}]).state;
        compare(s.mode, "hold");
    }

    function test_renameOpenedByUserTakesWhenReleased() {
        compare(run([{type: "renameOpened"}]).state.mode, "take");
        compare(run([{type: "renameOpened"}], st("hold")).state.mode, "hold");
    }

    // ---- releases ---------------------------------------------------------------------------------

    function test_itemOpenedReleasesBeforeTheWindowMaps() {
        // Released at once: Hyprland focuses the opened window itself (no explicit request, which
        // would also warp the pointer).
        let r = run([{type: "press"}, {type: "itemOpened"}]);
        compare(r.state.mode, "none");
        r = run([openWin(a1, "1", "1")], r.state);
        compare(r.focus, []);
        compare(r.state.lent, "");
    }

    function test_escapeWithNothingSelectedReleases() {
        compare(run([{type: "escape", hasSelection: false, renaming: false}], st("hold")).state.mode, "none");
    }

    function test_escapeWithSelectionOrRenameKeeps() {
        compare(run([{type: "escape", hasSelection: true, renaming: false}], st("hold")).state.mode, "hold");
        compare(run([{type: "escape", hasSelection: false, renaming: true}], st("hold")).state.mode, "hold");
        compare(run([{type: "escape", hasSelection: false, renaming: false}], st("menu")).state.mode, "menu");
    }

    function test_workspaceChangeReleases() {
        for (const m of ["hold", "take", "menu"]) {
            const s = run([{type: "workspace"}], st(m, {lent: a1, lendNext: true})).state;
            compare(s, st("none"));
        }
    }

    function test_activeWindowReleases() {
        for (const m of ["hold", "take", "menu"])
            compare(run([{type: "activeWindow", address: a1}], st(m)).state.mode, "none");
    }

    function test_activeWindowEmptyIsIgnored() {
        compare(run([{type: "activeWindow", address: ""}], st("hold")).state.mode, "hold");
        compare(run([{type: "activeWindow", address: "zz"}], st("hold")).state.mode, "hold");
    }

    function test_openWindowReleasesFromEveryMode() {
        for (const m of ["hold", "take", "menu"])
            compare(run([openWin(a1, "1", "1")], st(m)).state.mode, "none");
    }

    // ---- explicit focus of a new window ----------------------------------------------------------

    function test_openWindowWhileHoldingFocusesIt() {
        // Scenario A: foot1 focused, the desktop clicked, foot2 launched from the Dock.
        const r = run([{type: "press"}, {type: "release", hasKeys: false}, {type: "keys", hasKeys: true}, openWin("0x" + a2.toUpperCase(), "1", "1")]);
        compare(r.state.mode, "none");
        compare(r.focus, [a2]);
        // The activation that follows changes nothing.
        compare(run([{type: "activeWindow", address: a2}], r.state).focus, []);
    }

    function test_openWindowWhileReleasedLetsHyprlandChoose() {
        compare(run([openWin(a1, "1", "1")]).focus, []);
    }

    function test_openWindowOnAnotherWorkspaceIsNotFocused() {
        const r = run([openWin(a1, "2", "1")], st("hold"));
        compare(r.focus, []);
        compare(r.state.mode, "none");
        compare(run([openWin(a1, "special:minimized", "1")], st("hold")).focus, []);
        compare(run([openWin(a1, "1", "")], st("hold")).focus, []);
    }

    function test_openWindowWithInvalidAddressIsNotFocused() {
        compare(run([openWin("0xnothex", "1", "1")], st("hold")).focus, []);
        compare(run([openWin("1\") hl.exec_cmd(\"x", "1", "1")], st("hold")).focus, []);
        compare(run([openWin("", "1", "1")], st("hold")).focus, []);
    }

    // ---- close ------------------------------------------------------------------------------------

    function test_closeOfAnotherWindowKeepsTheDesktop() {
        // Scenario B: an unrelated window closes while the desktop holds the keyboard. Releasing would
        // make Hyprland hand the keyboard to the previously focused window.
        compare(run([{type: "closeWindow", address: a1}], st("hold")).state.mode, "hold");
        compare(run([{type: "closeWindow", address: a1}], st("none")).state.mode, "none");
        compare(run([{type: "closeWindow", address: ""}], st("hold", {lent: ""})).state.mode, "hold");
    }

    function test_activeWindowIsTracked() {
        compare(run([{type: "activeWindow", address: "0x" + a1.toUpperCase()}]).state.active, a1);
        compare(run([{type: "activeWindow", address: ""}], st("hold", {active: a1})).state.active, "");
        // Kept across the desktop's own transitions.
        compare(run([{type: "press"}, {type: "release", hasKeys: true}], st("none", {active: a1})).state.active, a1);
    }

    function test_activeWindowClosingWhileHoldingRetakesTheKeyboard() {
        // Scenario B2: foot1 is Hyprland's active window, the desktop is clicked, foot1 closes by itself.
        let r = run([{type: "activeWindow", address: a1}, {type: "press"}, {type: "release", hasKeys: true}]);
        compare(r.state.mode, "hold");
        r = run([{type: "closeWindow", address: a1}], r.state);
        compare(r.state.mode, "take");
        compare(r.state.reclaim, true);
        compare(r.focus, []);
        // Hyprland's fallback focus (foot2) does not release the desktop.
        r = run([{type: "activeWindow", address: a2}], r.state);
        compare(r.state.mode, "take");
        compare(r.state.active, a2);
        r = run([{type: "keys", hasKeys: true}], r.state);
        compare(r.state.mode, "hold");
        compare(r.state.active, a2);
        // And foot2 closing later does the same.
        compare(run([{type: "closeWindow", address: a2}], r.state).state.mode, "take");
    }

    function test_activeWindowClosingWhileAwayOrReleasedIsHyprlandsChoice() {
        compare(run([{type: "closeWindow", address: a1}], st("none", {active: a1})).state.mode, "none");
        compare(run([{type: "closeWindow", address: a1}], st("take", {active: a1, away: true})).state.reclaim, false);
        // Another window closing never retakes.
        compare(run([{type: "closeWindow", address: a2}], st("hold", {active: a1})).state.mode, "hold");
    }

    // ---- Glance round trip (scenario H) ----------------------------------------------------------

    function test_glanceGetsTheKeyboardAndGivesItBack() {
        // Space: the desktop lets go first; Hyprland's fallback activation keeps the pending lend.
        let r = run([{type: "press"}, {type: "release", hasKeys: true}, {type: "previewOpened"}, {type: "activeWindow", address: a2}]);
        compare(r.state.mode, "none");
        compare(r.state.lendNext, true);
        // Glance maps and Hyprland focuses it itself: no explicit request.
        r = run([openWin(a1, "1", "1", true)], r.state);
        compare(r.focus, []);
        compare(r.state.lent, a1);
        compare(r.state.lendNext, false);
        r = run([{type: "activeWindow", address: a1}], r.state);
        compare(r.state.lent, a1);
        // Glance closes itself (Space/Esc): the desktop takes the keyboard back.
        r = run([{type: "closeWindow", address: a1}], r.state);
        compare(r.state.mode, "take");
        compare(r.state.reclaim, true);
        compare(r.state.lent, "");
        // Hyprland's own fallback activation does not cancel it.
        r = run([{type: "activeWindow", address: a2}], r.state);
        compare(r.state.mode, "take");
        r = run([{type: "keys", hasKeys: true}], r.state);
        compare(r.state, st("hold", {active: a2}));
    }

    function test_glanceMappingWhileHoldingIsFocusedAndLent() {
        // Glance reopened for other files while the desktop holds the keyboard: explicit focus.
        const r = run([openWin(a1, "1", "1", true)], st("hold"));
        compare(r.focus, [a1]);
        compare(r.state.lent, a1);
    }

    function test_glanceLentOnlyFromTheDesktop() {
        // Opened while released without a pending lend, or on another workspace: not lent.
        compare(run([openWin(a1, "1", "1", true)]).state.lent, "");
        compare(run([openWin(a1, "2", "1", true)], st("hold")).state.lent, "");
        compare(run([openWin(a1, "2", "1", true)], st("none", {lendNext: true})).state.lent, "");
        // An ordinary window is never lent, and it consumes the pending lend.
        compare(run([openWin(a1, "1", "1", false)], st("hold")).state.lent, "");
        const s = run([openWin(a1, "1", "1", false)], st("none", {lendNext: true})).state;
        compare(s.lent, "");
        compare(s.lendNext, false);
    }

    function test_glanceClosedWhilePointerAwayIsNotReclaimed() {
        const s = run([{type: "closeWindow", address: a1}], st("none", {lent: a1, away: true})).state;
        compare(s.mode, "none");
        compare(s.lent, "");
        compare(s.reclaim, false);
    }

    function test_glanceForgottenWhenTheUserMovesOn() {
        const lent = st("none", {lent: a1});
        compare(run([{type: "activeWindow", address: a2}], lent).state.lent, "");
        compare(run([openWin(a2, "1", "1")], lent).state.lent, "");
        compare(run([{type: "press"}], lent).state.lent, "");
        compare(run([{type: "workspace"}], lent).state.lent, "");
        // Then closing it does not take the keyboard.
        const s = run([{type: "activeWindow", address: a2}, {type: "closeWindow", address: a1}], lent).state;
        compare(s.mode, "none");
    }

    function test_plainTakeIsCancelledByActivation() {
        // Not a reclaim: a window activated while taking wins.
        compare(run([{type: "activeWindow", address: a2}], st("take")).state.mode, "none");
    }

    // ---- event data ---------------------------------------------------------------------------------

    function test_normalizeAddress() {
        compare(Focus.normalizeAddress("0x55D0C8A3B2F0"), "55d0c8a3b2f0");
        compare(Focus.normalizeAddress("55d0c8a3b2f0"), "55d0c8a3b2f0");
        compare(Focus.normalizeAddress(""), "");
        compare(Focus.normalizeAddress("0x"), "");
        compare(Focus.normalizeAddress("12345678901234567"), "");
        compare(Focus.normalizeAddress("abc\""), "");
        compare(Focus.normalizeAddress(undefined), "");
    }

    function test_parseOpenWindow() {
        compare(Focus.parseOpenWindow("55d0c8a3b2f0,1,foot,a, b, c"), {address: "55d0c8a3b2f0", workspace: "1", appClass: "foot"});
        compare(Focus.parseOpenWindow("55d0c8a3b2f0,special:minimized,org.grassfield.Preview.Glance,"), {address: "55d0c8a3b2f0", workspace: "special:minimized", appClass: "org.grassfield.Preview.Glance"});
        compare(Focus.parseOpenWindow("nothex,1,foot,t"), null);
        compare(Focus.parseOpenWindow("55d0c8a3b2f0,,foot,t"), null);
        compare(Focus.parseOpenWindow("55d0c8a3b2f0"), null);
        compare(Focus.parseOpenWindow(""), null);
    }
}
