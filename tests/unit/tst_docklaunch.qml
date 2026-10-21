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
}
