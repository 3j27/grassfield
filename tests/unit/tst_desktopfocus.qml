import QtQuick
import QtTest
import "../../shell/desktop/KeyboardFocus.js" as Focus

// Keyboard focus of the desktop icons surface, macOS model (docs/decisions/ADR-0012-desktop-focus-model.md,
// docs/specs/desktop.md "Keyboard focus"): the pure state machine. The surface is click-to-focus: None until a
// press, then OnDemand; back to None when it loses the keyboard, when the pointer leaves it or when the keyboard
// is not granted. The context menu is a PopupWindow with a grab (mode "menu"). Test names state the user-visible rule.
TestCase {
    id: testCase
    name: "DesktopFocus"

    function run(events, from) {
        let s = from || Focus.initial();
        for (const e of events)
            s = Focus.next(s, e);
        return s;
    }

    readonly property var press: ({type: "press"})
    readonly property var granted: ({type: "keys", hasKeys: true})
    readonly property var lost: ({type: "keys", hasKeys: false})
    readonly property var leave: ({type: "pointerLeft"})

    // Events with no keyboard meaning for the desktop (windows, workspaces, hover, other buttons).
    readonly property var noise: [
        {type: "hover"},
        {type: "openWindow", address: "55d0c8a3b2f0", workspace: "1", focusedWorkspace: "1"},
        {type: "activeWindow", address: "55d0c8a3b2f0"},
        {type: "closeWindow", address: "55d0c8a3b2f0"},
        {type: "workspace"},
        {type: "unknown"}
    ]

    // ---- hover never focuses, a press does ---------------------------------------------------------

    function test_desktopStartsWithoutKeyboardAfterShellRestart() {
        const s = Focus.initial();
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.keysActive(s));
        verify(!Focus.kicking(s));
    }

    function test_hoverAndWindowEventsNeverTakeTheKeyboard() {
        const s = run(noise);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
    }

    function test_pointerLeavingAnIdleDesktopChangesNothing() {
        compare(run([leave, leave]).mode, "idle");
    }

    function test_keyboardEventsOnAnIdleDesktopDoNotActivateIt() {
        // Hyprland cannot give the keyboard to a None surface: a stray event must not enable the actions.
        const s = run([granted, lost, granted]);
        compare(s.mode, "idle");
        verify(!Focus.keysActive(s));
    }

    function test_aPressAsksForTheKeyboardAndKicksHyprland() {
        const s = run([press]);
        compare(s.mode, "armed");
        compare(Focus.interactivity(s), "ondemand");
        verify(Focus.kicking(s));
        verify(!Focus.keysActive(s), "the actions wait for the keyboard to be granted");
    }

    function test_actionsAreActiveOnlyOnceTheDesktopHoldsTheKeyboard() {
        const s = run([press, granted]);
        compare(s.mode, "held");
        verify(Focus.keysActive(s));
        verify(!Focus.kicking(s));
        compare(Focus.interactivity(s), "ondemand");
    }

    function test_aSecondPressWhileHeldKeepsTheKeyboard() {
        const s = run([press, granted, press]);
        compare(s.mode, "held");
    }

    function test_keyboardNotGrantedInTimeGivesUpWithoutHoverFocusRisk() {
        // The pointer is over a window: Hyprland never grants it. Back to None, so hover cannot focus the desktop later.
        const s = run([press, {type: "armTimeout"}]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
    }

    function test_timeoutAfterTheKeyboardWasGrantedChangesNothing() {
        compare(run([press, granted, {type: "armTimeout"}]).mode, "held");
    }

    // ---- windows take the keyboard back --------------------------------------------------------------

    function test_clickOnAWindowReleasesTheDesktop() {
        // Hyprland focused another window: the surface loses the keyboard and goes back to None.
        const s = run([press, granted, lost]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(!Focus.keysActive(s));
    }

    function test_pointerLeavingToTheLastActiveWindowReleasesTheKeyboard() {
        // Hyprland ignores a click on the window that is already its active one, so the desktop drops to None on
        // leave: the keyboard returns to that window and the click works.
        const s = run([press, granted, leave]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
    }

    function test_pointerLeavingToAnotherOutputReleasesTheKeyboard() {
        compare(run([press, leave]).mode, "idle");
    }

    function test_pressAgainAfterLosingTheKeyboardRetakesIt() {
        compare(run([press, granted, lost, press]).mode, "armed");
    }

    // ---- context menu --------------------------------------------------------------------------------

    function test_menuHoldsTheKeyboardAndTheDesktopActionsAreOff() {
        const s = run([press, granted, {type: "menuOpened"}]);
        compare(s.mode, "menu");
        verify(!Focus.keysActive(s), "arrows and Return go to the menu, not to the desktop");
        compare(Focus.interactivity(s), "ondemand", "so that the keyboard is back on the desktop when it closes");
    }

    function test_menuFromAnIdleDesktopAlsoReturnsTheKeyboardToTheDesktop() {
        const s = run([{type: "menuOpened"}, {type: "menuClosed", how: "esc"}]);
        compare(s.mode, "held");
        verify(Focus.keysActive(s));
    }

    function test_pointerLeavingOntoTheMenuDoesNotReleaseIt() {
        // The pointer enters the popup surface: the desktop sees a leave, the menu stays.
        const s = run([press, granted, {type: "menuOpened"}, leave]);
        compare(s.mode, "menu");
    }

    function test_keyboardMovingToTheMenuIsNotALoss() {
        const s = run([press, granted, {type: "menuOpened"}, lost, granted, lost]);
        compare(s.mode, "menu");
    }

    function test_escOnTheMenuGivesTheKeyboardBackToTheDesktop() {
        const s = run([press, granted, {type: "menuOpened"}, {type: "menuClosed", how: "esc"}]);
        compare(s.mode, "held");
        verify(Focus.keysActive(s));
    }

    function test_chosenItemGivesTheKeyboardBackToTheDesktop() {
        const s = run([press, granted, {type: "menuOpened"}, {type: "menuClosed", how: "item"}]);
        compare(s.mode, "held");
    }

    function test_clickOutsideTheMenuDismissesItAndDropsTheDesktopToNone() {
        // The compositor swallowed the click: the keyboard went back to the desktop even when the pointer is over a
        // window. None, then ask again (rearmAfter): granted only when the pointer is on the bare desktop.
        const ev = {type: "menuClosed", how: "outside"};
        const s = run([press, granted, {type: "menuOpened"}, ev]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
        verify(Focus.rearmAfter(ev));
        compare(run([press], s).mode, "armed");
    }

    function test_onlyAnOutsideDismissalRearms() {
        verify(!Focus.rearmAfter({type: "menuClosed", how: "esc"}));
        verify(!Focus.rearmAfter({type: "menuClosed", how: "item"}));
        verify(!Focus.rearmAfter(press));
    }

    function test_menuCloseEventWithoutAnOpenMenuChangesNothing() {
        compare(run([press, granted, {type: "menuClosed", how: "outside"}]).mode, "held");
        compare(run([{type: "menuClosed", how: "esc"}]).mode, "idle");
    }

    function test_pressWhileTheMenuIsOpenIsIgnored() {
        compare(run([{type: "menuOpened"}, press, {type: "armTimeout"}]).mode, "menu");
    }

    // ---- compositor policy (capability desktop-focus) -----------------------------------------------
    // The plugin gives the keyboard to the clicked window or desktop; the desktop keeps it until another click.

    function runP(events, from) {
        let s = from || Focus.initial();
        for (const e of events)
            s = Focus.next(s, e, true);
        return s;
    }

    function test_policyKeepsTheKeyboardWhenThePointerLeaves() {
        const s = runP([press, granted, leave]);
        compare(s.mode, "held");
        verify(Focus.keysActive(s));
    }

    function test_policyKeepsTheKeyboardAfterLeavingToTheDockAndTheMenuBar() {
        compare(runP([press, granted, leave, leave, {type: "hover"}]).mode, "held");
    }

    function test_policyStillReleasesWhenTheCompositorMovesTheKeyboardToAWindow() {
        const s = runP([press, granted, lost]);
        compare(s.mode, "idle");
        compare(Focus.interactivity(s), "none");
    }

    function test_policyNeedsNoKicker() {
        const s = runP([press]);
        compare(s.mode, "armed");
        verify(!Focus.kicking(s, true));
        verify(Focus.kicking(s, false));
        verify(Focus.kicking(s), "no policy argument means no policy");
    }

    function test_policyStillGivesUpWhenTheKeyboardIsNotGranted() {
        compare(runP([press, {type: "armTimeout"}]).mode, "idle");
    }

    function test_policyOutsideDismissalKeepsTheDesktopAndNeverRearms() {
        const ev = {type: "menuClosed", how: "outside"};
        const s = runP([press, granted, {type: "menuOpened"}, ev]);
        compare(s.mode, "held");
        verify(!Focus.rearmAfter(ev, true));
        verify(Focus.rearmAfter(ev, false));
    }

    function test_fileKeysAreEnabledOnlyWithThePolicy() {
        verify(Focus.fileKeyActions(true));
        verify(!Focus.fileKeyActions(false));
        verify(!Focus.fileKeyActions(undefined));
        verify(!Focus.fileKeyActions());
    }

    function test_withdrawingThePolicyRestoresTheSafeBehaviourLive() {
        // Held under the policy, then the plugin unloads: the next leave drops to None again, no kicker on a new press.
        let s = runP([press, granted, leave]);
        compare(s.mode, "held");
        s = Focus.next(s, leave, false);
        compare(s.mode, "idle");
        verify(Focus.kicking(Focus.next(s, press, false), false));
    }

    function test_policyChangesNothingForTheMenuModes() {
        const s = runP([press, granted, {type: "menuOpened"}, leave]);
        compare(s.mode, "menu");
        verify(!Focus.keysActive(s));
    }

    // ---- no stale state ------------------------------------------------------------------------------

    function test_everyModeIsReachableAndConsistent() {
        for (const mode of ["idle", "armed", "held", "menu"]) {
            const s = {mode: mode};
            const i = Focus.interactivity(s);
            verify(i === "none" || i === "ondemand");
            compare(i === "none", mode === "idle", "only idle is None");
            compare(Focus.keysActive(s), mode === "held");
            compare(Focus.kicking(s), mode === "armed");
        }
    }
}
