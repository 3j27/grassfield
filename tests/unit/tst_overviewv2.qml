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

    // ---- what a close without a chosen window focuses ----

    function test_restorePlanReturnsToThePreviouslyActiveWindow() {
        const plan = V2.restorePlan({address: "0xa", workspaceId: 3}, ["0xb", "0xa"], 0);
        compare(plan.kind, "window");
        compare(plan.address, "0xa");
        compare(plan.workspaceId, 3);
    }

    function test_restorePlanWindowGoneLeavesHyprlandsChoice() {
        compare(V2.restorePlan({address: "0xa", workspaceId: 3}, ["0xb"], 0).kind, "none");
        compare(V2.restorePlan({address: "0xa", workspaceId: 3}, [], 0).kind, "none");
        compare(V2.restorePlan({address: "0xa", workspaceId: 3}, null, 0).kind, "none");
    }

    function test_restorePlanNothingRememberedLeavesHyprlandsChoice() {
        compare(V2.restorePlan(null, ["0xa"], 0).kind, "none");
        compare(V2.restorePlan({address: "", workspaceId: 1}, ["0xa"], 0).kind, "none");
    }

    function test_restorePlanStaysOnADesktopCreatedWhileOpen() {
        const plan = V2.restorePlan({address: "0xa", workspaceId: 3}, ["0xa"], 7);
        compare(plan.kind, "space");
        compare(plan.id, 7);
    }
}
