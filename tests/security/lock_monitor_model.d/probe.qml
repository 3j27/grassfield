pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.security.lock

// The REAL Lock singleton against the Hyprland of tests/security/lock_monitor_model.sh (LOCK_MONITOR_SCENARIO):
//   slow-status  a fake Hyprland answers Quickshell's first query late; its one monitor lists LOCK (a stranded session
//                lock): Quickshell's monitor model fills, the start-up check takes the stranded lock over, and an answer
//                about the monitor created after start reaches checkOwnership (the ownership watcher attached to it);
//   empty        Hyprland never answers (a fake that holds Quickshell's first query, or no socket at all): after the
//                start-up check's 20 ticks the model is still empty and the lock was neither taken nor released (unknown:
//                the crash recovery marker decides).
// Offscreen there is no compositor: a taken-over lock stays requested ("locking"). This probe never queries Hyprland while
// the model is empty (it would be the very request under test). Prints "lock-monitor-model: PASS <scenario>" or
// "lock-monitor-model: FAIL <scenario>: <checks>".
ShellRoot {
    id: root

    settings.watchFiles: false

    readonly property string scenario: Quickshell.env("LOCK_MONITOR_SCENARIO")
    // Starts the Lock singleton (its Hyprland IPC and its start-up check) with the shell, as shell.qml does.
    readonly property string lockState: Lock.lockState
    property int elapsed: 0
    property string phase: "fill"
    property int phaseAt: 0
    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function finish(): void {
        ticker.stop();
        if (failures.length === 0) {
            console.log("lock-monitor-model: PASS " + scenario);
            Qt.exit(0);
        } else {
            console.log("lock-monitor-model: FAIL " + scenario + ": " + failures.join(", ") + " (monitors " + Hyprland.monitors.values.length + ", lock " + Lock.lockState + ")");
            Qt.exit(1);
        }
    }

    function step(): void {
        const count = Hyprland.monitors.values.length;
        if (scenario === "empty") {
            // The start-up check runs 20 ticks of 500 ms after the singleton started.
            if (elapsed < 12000)
                return;
            check("model-still-empty", count === 0);
            check("no-takeover-no-release", Lock.lockState === "unlocked");
            finish();
        } else if (scenario !== "slow-status") {
            check("LOCK_MONITOR_SCENARIO-set", false);
            finish();
        } else if (phase === "fill") {
            if (count > 0) {
                phase = "takeover";
                phaseAt = elapsed;
            } else if (elapsed >= 8000) {
                check("model-filled", false);
                finish();
            }
        } else if (phase === "takeover") {
            if (Lock.lockState !== "unlocked") {
                // Not holding (nothing is confirmed offscreen): checkOwnership resets the count on any answer it gets.
                Lock.unlockedAnswers = 7;
                Hyprland.refreshMonitors();
                phase = "watch";
                phaseAt = elapsed;
            } else if (elapsed - phaseAt >= 3000) {
                check("stranded-lock-taken-over", false);
                finish();
            }
        } else if (phase === "watch") {
            if (Lock.unlockedAnswers === 0) {
                finish();
            } else if (elapsed - phaseAt >= 3000) {
                check("answer-reached-checkOwnership", false);
                finish();
            }
        }
    }

    Timer {
        id: ticker
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.elapsed += interval;
            root.step();
        }
    }
}
