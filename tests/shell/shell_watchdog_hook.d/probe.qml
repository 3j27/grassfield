import QtQuick
import Quickshell
import qs.platform

// ADR-0041 step 6a: hosts the real Capabilities singleton, whose IPC target `capabilities` answers the liveness probe's
// question and carries its dev hook, for tests/shell/shell_watchdog_hook.sh, which asks it over IPC from outside.
// Prints "watchdog-hook: ready" once it runs.
ShellRoot {
    // Quickshell makes a singleton only when it is first used.
    readonly property bool settled: Capabilities.settled

    Component.onCompleted: console.log("watchdog-hook: ready")
}
