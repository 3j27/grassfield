import QtQuick
import Quickshell
import qs.services

// Apps.qml when `sh` cannot start (run by tests/shell/apps_start_fail.sh with GRASSFIELD_SESSION=1 and an empty PATH):
// Quickshell sends no `exited` for a failed start, so a launch queued behind the uwsm-app probe must be released by
// running going back to false. Prints "apps-start-fail: PASS" or FAIL.
ShellRoot {
    property bool ran: false
    property bool queuedWas: false

    Component.onCompleted: {
        // Queued: the probe has not answered yet.
        queuedWas = !Apps.scopeKnown;
        Apps.whenScopeKnown(() => ran = true);
    }

    Timer {
        interval: 3000
        running: true
        onTriggered: {
            const ok = queuedWas && ran && Apps.scopeKnown && !Apps.scopedLaunch;
            console.log(ok ? "apps-start-fail: PASS" : "apps-start-fail: FAIL queued=" + queuedWas + " ran=" + ran + " known=" + Apps.scopeKnown);
            Qt.quit();
        }
    }
}
