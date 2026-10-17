import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/desktop/HotCornerActions.js" as Actions

// Hot corner dwell logic and action mapping.
TestCase {
    id: testCase
    name: "HotCorners"

    property var gate: null
    property int fires: 0

    function init() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../shell/desktop/DwellGate.qml"));
        compare(comp.status, Component.Ready, comp.errorString());
        gate = comp.createObject(testCase, {interval: 40});
        fires = 0;
        gate.triggered.connect(() => testCase.fires++);
    }

    function cleanup() {
        gate.destroy();
    }

    function test_dwellTokenIs150ms() {
        compare(Tokens.hotCornerDwellMs, 150);
    }

    function test_firesAfterDwell() {
        gate.hovering = true;
        compare(fires, 0);
        tryCompare(testCase, "fires", 1, 1000);
        verify(gate.latched);
    }

    function test_leavingBeforeDwellCancels() {
        gate.hovering = true;
        wait(10);
        gate.hovering = false;
        wait(120);
        compare(fires, 0);
    }

    function test_firesOncePerVisit() {
        gate.coverGraceMs = 0;
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        wait(120);
        compare(fires, 1);
        gate.hovering = false;
        verify(!gate.latched);
        gate.hovering = true;
        tryCompare(testCase, "fires", 2, 1000);
    }

    // Closing the surface the action opened: the covered window loses and regains hover with the
    // pointer still in the corner. Must not fire again.
    function test_coverExitAndReenterDoesNotRefire() {
        gate.coverGraceMs = 5000;
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        gate.hovering = false;
        verify(gate.latched);
        gate.hovering = true;
        gate.distance = 1;
        wait(150);
        compare(fires, 1);
    }

    function test_movingOutOfLatchZoneRearms() {
        gate.coverGraceMs = 5000;
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        gate.hovering = false;
        gate.hovering = true;
        gate.distance = 20;
        verify(!gate.latched);
        gate.hovering = false;
        gate.distance = 0;
        gate.hovering = true;
        tryCompare(testCase, "fires", 2, 1000);
    }

    function test_lateExitRearms() {
        gate.coverGraceMs = 30;
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        wait(60);
        gate.hovering = false;
        verify(!gate.latched);
    }

    function test_blockedNeverFires() {
        gate.blocked = true;
        gate.hovering = true;
        wait(150);
        compare(fires, 0);
        gate.blocked = false;
        gate.hovering = false;
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
    }

    function test_blockedWhileDwellingCancels() {
        gate.hovering = true;
        gate.blocked = true;
        wait(150);
        compare(fires, 0);
    }

    function test_notificationsIsDirect() {
        verify(Actions.isDirect("notifications"));
        verify(!Actions.isDirect("overview"));
        compare(Actions.command("notifications", 7), null);
    }

    function test_actionsClampToEnum() {
        compare(Actions.normalize("overview"), "overview");
        compare(Actions.normalize("rm -rf"), "none");
        compare(Actions.normalize(undefined), "none");
    }

    function test_commands() {
        compare(Actions.command("overview", 42).join(" "), "qs ipc --pid 42 call overview toggle");
        compare(Actions.command("lock", 7).join(" "), "qs ipc --pid 7 call lock lock");
        compare(Actions.command("none", 7), null);
        compare(Actions.command("bogus", 7), null);
    }

    function test_appsTargetDetection() {
        verify(Actions.hasTarget("target overview\n  function toggle(): void\ntarget apps\n  function toggle(): void\n", "apps"));
        verify(!Actions.hasTarget("target overview\n  function toggle(): void\n", "apps"));
        verify(!Actions.hasTarget("target appsx\n", "apps"));
    }
}
