import QtQuick
import QtTest
import "../../shell/overview/V2.js" as V2
import "../../shell/overview/Layout.js" as Layout

// Overview v2 shell side (docs/specs/overview.md "Shell contract"): plugin event parsing, what the shell does with
// each event, and the layout coordinates sent to the plugin.
TestCase {
    name: "OverviewV2"

    function ev(state, reason, windows) {
        return V2.parseEvent(JSON.stringify({v: "gfc/1", type: "overview", state: state, windows: windows === undefined ? 6 : windows, reason: reason}));
    }

    // ---- events ----

    function test_parseEvent() {
        const e = V2.parseEvent('{"v":"gfc/1","type":"overview","state":"opening","windows":6}');
        compare(e.state, "opening");
        compare(e.windows, 6);
        compare(e.reason, "");
        compare(ev("closed", "no-chrome", 0).reason, "no-chrome");
    }

    function test_parseEventRejectsForeignAndMalformedData() {
        compare(V2.parseEvent("not json"), null);
        compare(V2.parseEvent('{"v":"gfc/2","type":"overview","state":"open","windows":1}'), null);
        compare(V2.parseEvent('{"v":"gfc/1","type":"capabilities","features":[]}'), null);
        compare(V2.parseEvent('{"v":"gfc/1","type":"overview","state":"exploding","windows":1}'), null);
        compare(V2.parseEvent("null"), null);
        // An unknown reason or count is dropped, never trusted.
        compare(V2.parseEvent('{"v":"gfc/1","type":"overview","state":"open","windows":"x","reason":"rm -rf"}').reason, "");
        compare(V2.parseEvent('{"v":"gfc/1","type":"overview","state":"open","windows":-3}').windows, 0);
    }

    function test_plainStatesAreTrackedOnlyWhileTheShellIsOpen() {
        compare(V2.decide("idle", true, ev("opening")).phase, "opening");
        compare(V2.decide("opening", true, ev("open")).phase, "open");
        compare(V2.decide("open", true, ev("closing")).phase, "closing");
        compare(V2.decide("closing", true, ev("closed", "", 0)).phase, "idle");
        // The answer to the restart `on:false` while the shell is closed changes nothing.
        const r = V2.decide("idle", false, ev("closed", "", 0));
        compare(r.phase, "idle");
        verify(!r.fallback && !r.close && !r.retry);
    }

    function test_refusalsFallBackToThumbnailsForThisOpen() {
        for (const reason of ["invalid", "no-windows"]) {
            const r = V2.decide("idle", true, ev("closed", reason, 0));
            verify(r.fallback, reason);
            compare(r.phase, "idle");
        }
        // A refused retarget leaves the overview as it was: fall back, and the shell puts the windows back.
        const kept = V2.decide("open", true, ev("open", "no-windows", 6));
        verify(kept.fallback);
        compare(kept.phase, "open");
    }

    function test_pluginUnloadFallsBackAndForgetsTheState() {
        const r = V2.decide("open", true, ev("closed", "unavailable", 0));
        verify(r.fallback);
        compare(r.phase, "idle");
        verify(!V2.decide("idle", false, ev("closed", "unavailable", 0)).fallback, "nothing to fall back from when closed");
    }

    function test_noChromeIsRetriedBeforeFallingBack() {
        const r = V2.decide("idle", true, ev("closed", "no-chrome", 0));
        verify(r.retry);
        verify(!r.fallback);
    }

    function test_interruptedClosesTheChrome() {
        const r = V2.decide("open", true, ev("closed", "interrupted", 0));
        verify(r.close);
        compare(r.phase, "idle");
        verify(!V2.decide("idle", false, ev("closed", "interrupted", 0)).close);
    }

    function test_aWindowGoingFullScreenFallsBackToThumbnails() {
        const r = V2.decide("open", true, ev("open", "fullscreen", 5));
        verify(r.fallback);
        verify(!r.close && !r.retry);
        compare(r.phase, "open");
        verify(!V2.decide("idle", false, ev("closed", "fullscreen", 0)).fallback);
    }

    function test_nullEventChangesNothing() {
        const r = V2.decide("open", true, null);
        compare(r.phase, "open");
        verify(!r.fallback && !r.close && !r.retry);
    }

    // ---- layout coordinates ----

    function test_surfaceRectRemovesTheTitlebarBandAndMapsToLayoutCoordinates() {
        // Window 800x600 at (100, 200) on an output at (1440, 0), chrome below a 24 px menu bar, band 28.
        const input = V2.layoutInput("a", 100, 200, 800, 600, 28);
        compare(input.y, 172);
        compare(input.h, 628);
        const rect = {id: "a", x: 300, y: 100, w: 400, h: 314};   // scale 0.5: 628 * 0.5 = 314
        const s = V2.surfaceRect(rect, 800, 28, 1440, 0, 24);
        compare(s.x, 1740);
        compare(s.y, 24 + 100 + 14);
        compare(s.w, 400);
        compare(s.h, 300);
    }

    function test_theBandKeepsEveryLaidOutSurfaceInsideTheArea() {
        const area = {x: 32, y: 160, w: 1856, h: 800};
        const input = [];
        for (let i = 0; i < 6; i++)
            input.push(V2.layoutInput("w" + i, 200 + i * 40, 150 + i * 30, 700, 500, 28));
        const res = Layout.layout(input, area, {maxScale: 0.8, gap: 24});
        for (const r of res.rects) {
            const s = V2.surfaceRect(r, 700, 28, 0, 0, 0);
            verify(s.y - 28 * (r.w / 700) >= area.y - 1e-6, "titlebar band stays inside the area");
            verify(s.y + s.h <= area.y + area.h + 1e-6);
            verify(Math.abs(s.w / s.h - 700 / 500) < 1e-6, "aspect ratio of the window is kept");
        }
    }

    // ---- keyboard plan of the chromes ----

    function test_keyboardPlanEveryChromeExclusiveWhileOpen() {
        const plan = V2.keyboardPlan(["WAYLAND-1", "GF-REF"], "open");
        compare(plan["GF-REF"], "exclusive");
        compare(plan["WAYLAND-1"], "exclusive");
        compare(Object.keys(plan).length, 2);
    }

    function test_keyboardPlanEveryChromeNoneWhenReleasingAndClosed() {
        for (const phase of ["releasing", "closing", "closed"]) {
            const plan = V2.keyboardPlan(["a", "b", "c"], phase);
            for (const k of Object.keys(plan))
                compare(plan[k], "none", phase + " " + k);
        }
    }

    function test_keyboardPlanSingleOutputAndNoOutput() {
        compare(V2.keyboardPlan(["a"], "open").a, "exclusive");
        compare(Object.keys(V2.keyboardPlan([], "open")).length, 0);
        compare(Object.keys(V2.keyboardPlan(null, "open")).length, 0);
    }

    // The controller holds one stage value: open -> releasing -> closed. No stage after the release started may give an
    // exclusive plan (it would make every chrome take the keyboard back just before it goes away).
    function test_stageSequenceNeverExclusiveAfterReleaseStarts() {
        const seq = ["closed", "open", "releasing", "closed"];
        const exclusive = seq.map(st => V2.keyboardPlan(["a", "b"], st).a === "exclusive");
        compare(exclusive, [false, true, false, false]);
    }

    function test_keysEnabledOnlyWhileOpen() {
        compare(V2.keysEnabled("open"), true);
        compare(V2.keysEnabled("releasing"), false);
        compare(V2.keysEnabled("closed"), false);
        compare(V2.keysEnabled(undefined), false);
    }

    // ---- release sequencing ----

    // The holder is released last: first every other chrome None while the holder stays Exclusive, then all None.
    function test_keyboardPlanReleasesTheHolderLast() {
        const first = V2.keyboardPlan(["WAYLAND-1", "GF-REF"], "releasing", "GF-REF");
        compare(first["GF-REF"], "exclusive");
        compare(first["WAYLAND-1"], "none");
        const second = V2.keyboardPlan(["WAYLAND-1", "GF-REF"], "releasing", "");
        compare(second["GF-REF"], "none");
        compare(second["WAYLAND-1"], "none");
        // `keep` only matters while releasing.
        compare(V2.keyboardPlan(["a"], "closed", "a").a, "none");
        compare(V2.keyboardPlan(["a", "b"], "open", "a").b, "exclusive");
    }

    // Every chrome commits None on its own: the close completes only when no chrome reports the keyboard and the settle
    // pause since the last change has elapsed; the bound ends the wait whatever the reports say.
    function test_releaseDoneWaitsForEveryChromeAndTheSettlePause() {
        compare(V2.releaseDone(true, false, false), false, "keyboard still on a chrome");
        compare(V2.releaseDone(true, true, false), false, "settled but a chrome still reports the keyboard");
        compare(V2.releaseDone(false, false, false), false, "released but not settled (another chrome may still commit)");
        compare(V2.releaseDone(false, true, false), true);
    }

    function test_releaseDoneBoundEndsTheWait() {
        compare(V2.releaseDone(true, false, true), true);
        compare(V2.releaseDone(false, false, true), true);
        compare(V2.releaseDone(true, true, undefined), false, "forced must be exactly true");
    }

    // The holder commits first (Hyprland refuses to refocus), then the other chrome: replay the controller's timer rules.
    function test_releaseSequenceHolderFirstThenSettle() {
        let held = true;
        let settled = false;
        const log = [];
        log.push(V2.releaseDone(held, settled, false));
        held = false;   // the holder's chrome reports Window.active false: the settle restarts
        settled = false;
        log.push(V2.releaseDone(held, settled, false));
        settled = true; // the settle pause elapsed with no further change
        log.push(V2.releaseDone(held, settled, false));
        compare(log, [false, false, true]);
    }

    // ---- close target: one value for the plugin request and the shell fallback ----

    readonly property var prev: ({address: "0xa", workspaceId: 3})

    function test_closeTargetWindowChosen() {
        compare(V2.closeTarget({kind: "window", address: "0xb"}, prev, 0), {kind: "window", address: "0xb"});
        // A chosen window wins over the "+" Desktop and the remembered window.
        compare(V2.closeTarget({kind: "window", address: "0xb"}, prev, 7), {kind: "window", address: "0xb"});
    }

    function test_closeTargetDesktopChosen() {
        compare(V2.closeTarget({kind: "space", id: 2}, prev, 0), {kind: "workspace", workspace: 2});
        compare(V2.closeTarget({kind: "space", id: 0}, null, 0), {kind: "none"}, "an invalid Desktop is no choice");
    }

    function test_closeTargetNoChoiceReturnsToTheRememberedWindow() {
        compare(V2.closeTarget(null, prev, 0), {kind: "remembered", address: "0xa", workspace: 3});
        compare(V2.closeTarget(null, {address: "0xa", workspaceId: 0}, 0), {kind: "remembered", address: "0xa"});
    }

    function test_closeTargetNoChoiceNothingRememberedIsNone() {
        // The desktop held the keyboard at open, or no window did.
        compare(V2.closeTarget(null, null, 0), {kind: "none"});
        compare(V2.closeTarget(null, {address: "", workspaceId: 1}, 0), {kind: "none"});
    }

    function test_closeTargetStaysOnADesktopCreatedWhileOpen() {
        compare(V2.closeTarget(null, prev, 7), {kind: "workspace", workspace: 7});
    }

    function test_closeTargetEndedByThePluginIsNone() {
        compare(V2.closeTarget({kind: "none"}, prev, 7), {kind: "none", ended: true}, "interrupted: the plugin's fallback decides");
    }

    function test_closeTargetAnotherSurfaceSendsNothing() {
        compare(V2.closeTarget({kind: "other"}, prev, 0).kind, "skip");
        compare(V2.closeTarget({kind: "other"}, null, 7).kind, "skip");
    }

    // ---- without the plugin: what the shell focuses itself ----

    function test_fallbackPlanFocusesAWindowThatExists() {
        compare(V2.fallbackPlan({kind: "window", address: "0xb"}, ["0xa", "0xb"], []), {kind: "window", address: "0xb"});
        compare(V2.fallbackPlan({kind: "remembered", address: "0xa", workspace: 3}, ["0xa"], []), {kind: "window", address: "0xa"});
    }

    function test_fallbackPlanSkipsAGoneOrMinimizedWindow() {
        compare(V2.fallbackPlan({kind: "remembered", address: "0xa"}, ["0xb"], []).kind, "none", "closed");
        compare(V2.fallbackPlan({kind: "remembered", address: "0xa"}, ["0xa"], ["0xa"]).kind, "none", "minimized");
        compare(V2.fallbackPlan({kind: "window", address: "0xa"}, ["0xa"], ["0xa"]).kind, "none");
        compare(V2.fallbackPlan({kind: "window", address: "0xa"}, null, null).kind, "none");
    }

    function test_fallbackPlanDesktopAndNone() {
        compare(V2.fallbackPlan({kind: "workspace", workspace: 4}, [], []), {kind: "space", id: 4});
        compare(V2.fallbackPlan({kind: "none"}, ["0xa"], []).kind, "none");
        compare(V2.fallbackPlan({kind: "skip"}, ["0xa"], []).kind, "none");
        compare(V2.fallbackPlan(null, ["0xa"], []).kind, "none");
    }

    function test_fallbackPlanEndedByThePluginFocusesTheShownDesktop() {
        compare(V2.fallbackPlan({kind: "none", ended: true}, [], [], 5), {kind: "space", id: 5});
        compare(V2.fallbackPlan({kind: "none", ended: true}, [], [], 0).kind, "none");
        compare(V2.fallbackPlan({kind: "none"}, [], [], 5).kind, "none", "no remembered window: Hyprland's choice stands");
    }

    function test_focusHolds() {
        verify(V2.focusHolds({address: "0xa"}, {address: "0xa", workspaceId: 1}, 1));
        verify(!V2.focusHolds({address: "0xa"}, {address: "0xb", workspaceId: 1}, 1));
        verify(!V2.focusHolds({address: "0xa"}, null, 1));
        verify(V2.focusHolds({workspace: 2}, null, 2));
        verify(!V2.focusHolds({workspace: 2}, null, 1));
        verify(V2.focusHolds(null, null, 1), "no goal: nothing to hold");
    }

    function test_retryDelayDoublesAndIsBounded() {
        compare(V2.retryDelay(0, 60), 60);
        compare(V2.retryDelay(1, 60), 120);
        compare(V2.retryDelay(3, 60), 480);
        compare(V2.retryDelay(99, 60), 60 * 64);
        compare(V2.retryDelay(-1, 60), 60);
    }

    // ---- selection across outputs ----

    function test_startSelectionIsTheWindowActiveAtOpenOnAnyOutput() {
        const screens = [{name: "A", addresses: ["0x1", "0x2"]}, {name: "B", addresses: ["0x3"]}];
        compare(V2.startSelection({address: "0x3", workspaceId: 1}, screens), "0x3", "active on the second output");
        compare(V2.startSelection({address: "0x2", workspaceId: 1}, screens), "0x2");
    }

    function test_startSelectionFallsBackToTheFirstWindow() {
        const screens = [{name: "A", addresses: []}, {name: "B", addresses: ["0x3", "0x4"]}];
        compare(V2.startSelection(null, screens), "0x3");
        compare(V2.startSelection({address: "0xgone", workspaceId: 1}, screens), "0x3");
        compare(V2.startSelection(null, [{name: "A", addresses: []}]), "");
        compare(V2.startSelection(null, null), "");
    }

    readonly property var pair: [{name: "A", x: 0, y: 0, w: 1920, h: 1080}, {name: "B", x: 1920, y: 0, w: 1440, h: 900}]

    function test_adjacentScreenSideBySide() {
        compare(V2.adjacentScreen(pair, "A", "right"), "B");
        compare(V2.adjacentScreen(pair, "B", "left"), "A");
        compare(V2.adjacentScreen(pair, "A", "left"), "");
        compare(V2.adjacentScreen(pair, "A", "up"), "");
        compare(V2.adjacentScreen(pair, "A", "down"), "", "side by side: no output below");
        compare(V2.adjacentScreen(pair, "nope", "right"), "");
    }

    function test_adjacentScreenPicksTheNearestOnThatSide() {
        const three = [{name: "A", x: 0, y: 0, w: 1000, h: 800}, {name: "B", x: 1000, y: 0, w: 1000, h: 800}, {name: "C", x: 2000, y: 0, w: 1000, h: 800}, {name: "D", x: 0, y: 800, w: 1000, h: 800}];
        compare(V2.adjacentScreen(three, "A", "right"), "B");
        compare(V2.adjacentScreen(three, "C", "left"), "B");
        compare(V2.adjacentScreen(three, "A", "down"), "D");
        compare(V2.adjacentScreen(three, "D", "up"), "A");
    }

    function test_entryWindowArrivesAtTheNearEdgeNearestTheSameHeight() {
        const area = {w: 1000, h: 800};
        const rects = [{id: "tl", x: 0, y: 0, w: 300, h: 300}, {id: "tr", x: 600, y: 0, w: 300, h: 300}, {id: "bl", x: 0, y: 450, w: 300, h: 300}, {id: "br", x: 600, y: 450, w: 300, h: 300}];
        compare(V2.entryWindow(rects, "right", 0.2, area), "tl", "moving right arrives on the left edge, top row");
        compare(V2.entryWindow(rects, "right", 0.8, area), "bl", "bottom row");
        compare(V2.entryWindow(rects, "left", 0.2, area), "tr", "moving left arrives on the right edge");
        compare(V2.entryWindow(rects, "left", 0.8, area), "br");
        compare(V2.entryWindow(rects, "down", 0.2, area), "tl", "moving down arrives on the top row");
        compare(V2.entryWindow(rects, "up", 0.8, area), "br", "moving up arrives on the bottom row");
        compare(V2.entryWindow([], "right", 0.5, area), "");
    }

}
