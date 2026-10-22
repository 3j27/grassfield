import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/menubar/BarHide.js" as BarHide
import "../../shell/dock/AutoHide.js" as AutoHide

// Menu bar auto-hide, headless (offscreen, no compositor): the policy of the setting (BarHide.js) and the Dock's state
// machine driven the way MenuBar.qml drives it (one machine per output, the bar's own inhibitors and tokens).
TestCase {
    name: "BarHide"

    readonly property real frame: 16
    readonly property real barHeight: Tokens.menubarHeight
    readonly property var timing: ({
            hideGrace: Tokens.menubarHideGrace,
            hideDuration: Tokens.menubarHideDuration,
            revealDwell: Tokens.menubarRevealDwell,
            revealDuration: Tokens.menubarRevealDuration
        })
    readonly property var instant: ({
            hideGrace: Tokens.menubarHideGrace,
            hideDuration: 0,
            revealDwell: Tokens.menubarRevealDwell,
            revealDuration: 0
        })
    readonly property var none: ({})
    readonly property var edge: ({pointer: true})
    readonly property var menuOpen: ({popup: true})

    function advance(m, inh, ms, enabled, tm) {
        const times = Math.round(ms / frame);
        for (let i = 0; i < times; i++)
            m = AutoHide.step(m, inh, enabled === undefined ? true : enabled, tm === undefined ? timing : tm, frame);
        return m;
    }

    function hiddenBar() {
        const m = advance(AutoHide.create(), none, timing.hideGrace + timing.hideDuration + 5 * frame);
        compare(m.state, "hidden");
        return m;
    }

    // ---- policy of the setting ----

    function test_modesTable() {
        // mode, fullscreen -> hides
        const table = {
            always: [true, true],
            desktop: [true, false],
            fullscreen: [false, true],
            never: [false, false]
        };
        for (const mode in table) {
            compare(BarHide.hides(mode, false), table[mode][0], mode + " on the desktop");
            compare(BarHide.hides(mode, true), table[mode][1], mode + " in full screen");
        }
    }

    function test_unknownModeIsTheDefault() {
        compare(BarHide.DEFAULT_MODE, "fullscreen");
        const bad = ["", "Always", "full", "on", undefined, null, 3];
        for (let i = 0; i < bad.length; i++) {
            compare(BarHide.normalize(bad[i]), "fullscreen");
            compare(BarHide.hides(bad[i], false), false);
            compare(BarHide.hides(bad[i], true), true);
        }
        compare(BarHide.MODES.length, 4);
    }

    function test_onlyAnAlwaysVisibleBarReservesSpace() {
        // The reservation depends on the mode alone: the same value with and without a full-screen window, so a reveal or a
        // hide never moves a window.
        compare(BarHide.reservesSpace("never"), true);
        compare(BarHide.reservesSpace("fullscreen"), true);
        compare(BarHide.reservesSpace("always"), false);
        compare(BarHide.reservesSpace("desktop"), false);
        compare(BarHide.reservesSpace("nonsense"), true);
    }

    function test_overlayLayerOnlyOverAFullScreenWindow() {
        compare(BarHide.overlayLayer(true), true);
        compare(BarHide.overlayLayer(false), false);
    }

    function test_inputIsTheEdgeStripWhileAway() {
        compare(BarHide.inputHeight(barHeight, Tokens.menubarRevealZone, true), Tokens.menubarRevealZone);
        compare(BarHide.inputHeight(barHeight, Tokens.menubarRevealZone, false), barHeight);
        compare(BarHide.inputHeight(1, 5, true), 1);
        verify(Tokens.menubarRevealZone > 0 && Tokens.menubarRevealZone < barHeight);
    }

    function test_slideOffset() {
        compare(BarHide.slideOffset(barHeight, 1), 0);
        compare(BarHide.slideOffset(barHeight, 0), -barHeight);
        compare(BarHide.slideOffset(barHeight, 0.5), -barHeight / 2);
        compare(BarHide.slideOffset(barHeight, 7), 0);
        compare(BarHide.slideOffset(barHeight, -3), -barHeight);
    }

    // ---- the machine with the bar's inhibitors ----

    function test_staysInViewWhileDisabled() {
        // Mode never, or full screen left: the bar is simply shown, however long nothing happens.
        const m = advance(AutoHide.create(), none, 5000, false);
        compare(m.state, "shown");
        compare(m.visible, 1);
    }

    function test_hidesAfterTheGraceThenSlides() {
        let m = AutoHide.create();
        m = advance(m, none, timing.hideGrace - 2 * frame);
        compare(m.state, "shown");
        m = advance(m, none, 3 * frame);
        compare(m.state, "hiding");
        m = advance(m, none, timing.hideDuration / 2);
        verify(m.visible > 0 && m.visible < 1, "mid-slide " + m.visible);
        m = advance(m, none, timing.hideDuration);
        compare(m.state, "hidden");
        compare(m.visible, 0);
    }

    function test_openMenuKeepsTheBarInView() {
        let m = AutoHide.create();
        for (let t = 0; t < 5000; t += frame) {
            m = AutoHide.step(m, menuOpen, true, timing, frame);
            verify(m.state === "shown" && m.visible === 1, "hid under an open menu at " + t + " ms");
        }
        // Closing it starts the grace, not an instant hide.
        m = advance(m, none, timing.hideGrace - 2 * frame);
        compare(m.state, "shown");
    }

    function test_pointerOnTheBarKeepsItInView() {
        let m = AutoHide.create();
        m = advance(m, edge, 5000);
        compare(m.state, "shown");
        compare(m.visible, 1);
    }

    function test_theEdgeRevealsAfterTheDwell() {
        let m = hiddenBar();
        m = advance(m, edge, timing.revealDwell - 2 * frame);
        compare(m.state, "hidden");
        compare(m.visible, 0);
        m = advance(m, edge, 3 * frame);
        compare(m.state, "revealing");
        m = advance(m, edge, timing.revealDuration / 2);
        verify(m.visible > 0 && m.visible < 1, "mid-slide " + m.visible);
        m = advance(m, edge, timing.revealDuration);
        compare(m.state, "shown");
        compare(m.visible, 1);
    }

    function test_aPassingPointerDoesNotReveal() {
        let m = hiddenBar();
        m = advance(m, edge, timing.revealDwell - 3 * frame);
        m = advance(m, none, 5 * frame);
        m = advance(m, edge, timing.revealDwell - 3 * frame);
        compare(m.state, "hidden");
    }

    function test_aMenuOpenedFromAHiddenBarRevealsAtOnce() {
        // CTRL+F2 or the IPC hook: no dwell.
        let m = hiddenBar();
        m = advance(m, menuOpen, 2 * frame);
        compare(m.state, "revealing");
    }

    function test_leavingTheBarHidesItAgain() {
        let m = hiddenBar();
        m = advance(m, edge, timing.revealDwell + timing.revealDuration + 4 * frame);
        compare(m.state, "shown");
        m = advance(m, none, timing.hideGrace + timing.hideDuration + 4 * frame);
        compare(m.state, "hidden");
    }

    function test_reduceMotionShowsAtOnce() {
        let m = advance(AutoHide.create(), none, timing.hideGrace + 3 * frame, true, instant);
        m = advance(m, none, 2 * frame, true, instant);
        compare(m.state, "hidden");
        m = advance(m, edge, instant.revealDwell + 2 * frame, true, instant);
        // One more frame after the dwell: no slide, fully shown.
        m = advance(m, edge, 2 * frame, true, instant);
        compare(m.state, "shown");
        compare(m.visible, 1);
    }

    function test_noFrameLoopAtRest() {
        // Hidden and idle, or shown and held: the frame clock stops.
        compare(AutoHide.active(hiddenBar(), none, true), false);
        compare(AutoHide.active(AutoHide.create(), menuOpen, true), false);
        compare(AutoHide.active(AutoHide.create(), edge, true), false);
        // Disabled and shown (mode never, or the desktop in In Full Screen Only): nothing to do either.
        compare(AutoHide.active(AutoHide.create(), none, false), false);
        // Working: waiting for the grace, dwelling at the edge, sliding.
        compare(AutoHide.active(AutoHide.create(), none, true), true);
        compare(AutoHide.active(hiddenBar(), edge, true), true);
    }

    function test_leavingFullScreenShowsTheBarAtOnce() {
        // The machine goes disabled while hidden (full screen left, mode In Full Screen Only): shown, no animation.
        const m = AutoHide.step(hiddenBar(), none, false, timing, frame);
        compare(m.state, "shown");
        compare(m.visible, 1);
    }

    function test_timingTokensAreUsable() {
        verify(Tokens.menubarHideGrace > 0);
        verify(Tokens.menubarRevealDwell > 0);
        verify(Tokens.menubarHideDuration > 0);
        verify(Tokens.menubarRevealDuration > 0);
    }
}
