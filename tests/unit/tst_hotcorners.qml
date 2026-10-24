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
    // pointer still in the corner. Must not fire again (fire -> covered -> uncovered).
    function test_coverExitAndReenterDoesNotRefire() {
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        gate.covered = true;
        gate.hovering = false;
        verify(gate.latched);
        gate.pointerSeen(3);
        gate.hovering = true;
        wait(150);
        compare(fires, 1);
        verify(gate.latched);
    }

    // Moving away (reported by another surface) re-arms; coming back fires again.
    function test_movingAwayRearms() {
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        gate.covered = true;
        gate.hovering = false;
        gate.hovering = true;
        gate.pointerSeen(5);
        verify(gate.latched);
        gate.hovering = false;
        gate.pointerSeen(20);
        verify(!gate.latched);
        gate.covered = false;
        gate.hovering = true;
        tryCompare(testCase, "fires", 2, 1000);
    }

    // The pointer leaves onto a client window (nothing covers the corner) and jumps straight back: a true leave, the
    // corner fires again however quick (the old 800-ms grace swallowed it).
    function test_quickLeaveAndJumpBackFires() {
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        gate.hovering = false;
        verify(!gate.latched);
        gate.hovering = true;
        tryCompare(testCase, "fires", 2, 1000);
    }

    // Re-review (the latent risk): a panel slow to cover the corner (well past the old 800-ms grace) and then closed
    // with the pointer still resting there. A hover exit while a full-attention surface is up is a cover, whenever it
    // comes: the corner does not fire again until the pointer truly leaves.
    function test_aSlowCoverThenACloseWithThePointerRestingDoesNotRefire() {
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        gate.covered = true;   // the panel is open (FocusReturn) ...
        wait(900);             // ... and maps late
        gate.hovering = false; // the cover
        verify(gate.latched);
        gate.covered = false;  // closed
        gate.hovering = true;  // uncovered, the pointer never moved
        wait(150);
        compare(fires, 1);
        verify(gate.latched);
        gate.pointerSeen(30);  // the pointer really goes away ...
        gate.hovering = false;
        gate.hovering = true;  // ... and comes back
        tryCompare(testCase, "fires", 2, 1000);
    }

    // The session lock (the `lock` action) covers the corner too: after the unlock with the pointer resting, no new lock.
    function test_theSessionLockCountsAsACover() {
        gate.hovering = true;
        tryCompare(testCase, "fires", 1, 1000);
        gate.covered = true;
        gate.hovering = false;
        wait(1000);
        gate.covered = false;
        gate.hovering = true;
        wait(150);
        compare(fires, 1);
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
