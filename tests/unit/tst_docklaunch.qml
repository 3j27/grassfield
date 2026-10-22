import QtQuick
import QtTest
import "../../shell/dock/Launch.js" as Launch

TestCase {
    name: "DockLaunch"

    readonly property int timeout: 12000

    function test_idleLaunchingRunning() {
        compare(Launch.stateOf({}, "foot", 0, 1000, timeout), "idle");
        compare(Launch.stateOf({foot: 1000}, "foot", 0, 1500, timeout), "launching");
        // The first window ends the launch, whatever the map says.
        compare(Launch.stateOf({foot: 1000}, "foot", 1, 1500, timeout), "running");
        compare(Launch.stateOf({}, "foot", 2, 1500, timeout), "running");
    }

    function test_timeoutEndsLaunching() {
        compare(Launch.stateOf({foot: 1000}, "foot", 0, 1000 + timeout, timeout), "launching");
        compare(Launch.stateOf({foot: 1000}, "foot", 0, 1001 + timeout, timeout), "idle");
    }

    function test_clickStartsOnce() {
        const first = Launch.click({}, "foot", 1000, timeout);
        verify(first.start);
        compare(first.launching.foot, 1000);
        // Double click: the second click does nothing and keeps the first start time.
        const second = Launch.click(first.launching, "foot", 1150, timeout);
        verify(!second.start);
        compare(second.launching.foot, 1000);
    }

    function test_clickAfterTimeoutStartsAgain() {
        const again = Launch.click({foot: 1000}, "foot", 1000 + timeout + 1, timeout);
        verify(again.start);
        compare(again.launching.foot, 1000 + timeout + 1);
    }

    function test_otherTilesAreIndependent() {
        const a = Launch.click({}, "foot", 1000, timeout);
        const b = Launch.click(a.launching, "chromium", 1100, timeout);
        verify(b.start);
        compare(Object.keys(b.launching).length, 2);
    }

    function test_clickDoesNotMutateTheMap() {
        const before = {};
        Launch.click(before, "foot", 1, timeout);
        compare(Object.keys(before).length, 0);
    }

    function w(ref, stamp, minimized, here) {
        return {ref: ref, stamp: stamp, minimized: minimized, here: here};
    }

    function test_planAllWindowsHereMostRecentLast() {
        const plan = Launch.activationPlan([w("a", 5, false, true), w("b", 9, false, true), w("c", 1, false, true)]);
        compare(plan.join(","), "c,a,b");
    }

    function test_planOtherDesktopSwitchesToTheMostRecent() {
        const plan = Launch.activationPlan([w("a", 5, false, false), w("b", 9, false, false)]);
        compare(plan.join(","), "b");
    }

    function test_planLeavesWindowsOfOtherDesktopsAlone() {
        const plan = Launch.activationPlan([w("a", 5, false, false), w("b", 2, false, true)]);
        compare(plan.join(","), "b");
    }

    function test_planAllMinimizedRestoresTheMostRecentOnly() {
        const plan = Launch.activationPlan([w("a", 5, true, true), w("b", 9, true, true)]);
        compare(plan.join(","), "b");
    }

    function test_planMinimizedAreNotRaisedWithVisibleOnes() {
        const plan = Launch.activationPlan([w("a", 5, true, true), w("b", 2, false, true)]);
        compare(plan.join(","), "b");
    }

    function test_planWithoutWindows() {
        compare(Launch.activationPlan([]).length, 0);
        compare(Launch.activationPlan(null).length, 0);
    }

    function wi(ref, title, stamp, minimized) {
        return {ref: ref, title: title, stamp: stamp, minimized: minimized};
    }

    // Window list at the top of an app's Dock menu (macOS): most recent first, a check on the most recent visible window.
    function test_menuWindowsRecentFirstWithCheck() {
        const rows = Launch.menuWindows([wi("a", "Old", 1, false), wi("b", "New", 9, false), wi("c", "Mid", 5, false)], 40, "App");
        compare(rows.map(r => r.ref).join(","), "b,c,a");
        compare(rows.map(r => r.checked).join(","), "true,false,false");
    }

    function test_menuWindowsMinimizedIsMarkedAndNeverChecked() {
        const rows = Launch.menuWindows([wi("a", "Visible", 1, false), wi("b", "Hidden away", 9, true)], 40, "App");
        compare(rows[0].ref, "b");
        verify(rows[0].minimized);
        verify(!rows[0].checked);
        verify(rows[1].checked);
    }

    function test_menuWindowsAllMinimizedNoCheck() {
        const rows = Launch.menuWindows([wi("a", "A", 1, true), wi("b", "B", 2, true)], 40, "App");
        compare(rows.filter(r => r.checked).length, 0);
    }

    function test_menuWindowsTitleElidedAndNormalised() {
        const rows = Launch.menuWindows([wi("a", "x".repeat(60), 1, false), wi("b", "  two\n  lines  ", 0, false), wi("c", "", 0, false)], 40, "App");
        compare(rows[0].title.length, 40);
        verify(rows[0].title.endsWith("…"));
        compare(rows[1].title, "two lines");
        // An empty title falls back to the app name, as the Window menu does.
        compare(rows[2].title, "App");
    }

    function test_forceQuitPidsAreDistinctAndPlain() {
        compare(Launch.forceQuitPids([4242, 4242, 4300]).join(","), "4242,4300");
        // Unknown (0), init (1), negative and fractional PIDs are never targets.
        compare(Launch.forceQuitPids([0, 1, -5, 2.5, 77]).join(","), "77");
        compare(Launch.forceQuitPids([]).length, 0);
        compare(Launch.forceQuitPids(null).length, 0);
    }

    function test_menuWindowsEmpty() {
        compare(Launch.menuWindows([], 40, "App").length, 0);
        compare(Launch.menuWindows(null, 40, "App").length, 0);
    }
}
