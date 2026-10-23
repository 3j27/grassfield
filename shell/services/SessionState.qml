pragma Singleton
import QtQuick

// What the rest of the shell may know about the session lock without importing the security module: `locked` mirrors
// shell/security/lock (set by a Binding in shell.qml), and `requestLock()` asks that module to lock (shell.qml calls
// `Lock.lock(reason)`, the same function as the `lock` IPC target and the System menu). Notifications read `locked` (previews
// "When Unlocked"); Search calls `requestLock` (Lock Screen command). Without the shell's wiring (a test harness) the
// session counts as unlocked and a lock request does nothing.
QtObject {
    id: root

    property bool locked: false
    signal lockRequested(string reason)

    function requestLock(reason: string): void {
        lockRequested(reason);
    }
}
