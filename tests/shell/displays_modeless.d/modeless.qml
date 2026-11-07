pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform

// A display on without a mode (the owner's rc6 report: external displays black after sleep until unplugged and plugged back),
// on the real Displays singleton (tests/shell/displays_modeless.sh runs it against a fake Hyprland whose `monitors` answer lists
// DP-1 enabled at 0x0 until it has received two reloads, then with a mode, and which sends `configreloaded` after each reload,
// as Hyprland does). The shell sees the display without a mode, reads the configuration again after
// DisplaysFile.recoveryDelayMs(0) (3 s), again after recoveryDelayMs(1) (6 s more), then sees the mode and stops: no third
// reload follows. Prints "displays-modeless: PASS" or the failing check.
ShellRoot {
    id: root

    // Starts the singletons the way the shell does (Displays publishes at start; SessionConfig asks for the reloads).
    readonly property var described: Displays.described
    property int ticks: 0
    property int seenAttempts: 0
    property bool sawBlank: false
    property bool sawRecovered: false
    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            root.failures.push(name + " (attempts " + Displays.recoveryAttempts + ", modeless " + JSON.stringify(Displays.modelessNames) + ", reloads " + SessionConfig.reloads + ")");
    }

    // A reload never waits for a pacman lock here (a real one could be held by an update while the test runs).
    Component.onCompleted: SessionConfig.pacmanLockPath = ""

    Connections {
        target: Displays

        function onRecoveryAttemptsChanged(): void {
            root.seenAttempts = Math.max(root.seenAttempts, Displays.recoveryAttempts);
        }

        function onModelessNamesChanged(): void {
            if (JSON.stringify(Displays.modelessNames) === '["DP-1"]')
                root.sawBlank = true;
            if (root.sawBlank && root.seenAttempts >= 2 && Displays.modelessNames.length === 0)
                root.sawRecovered = true;
        }
    }

    Timer {
        interval: 200
        repeat: true
        running: true
        onTriggered: {
            root.ticks++;
            // 2 s before the first reload is due: none yet.
            if (root.ticks === 10)
                root.check("the display without a mode is seen and nothing is reloaded before 3 s", root.sawBlank && SessionConfig.reloads === 0);
            // 5 s: the first reload went 3 s after the first answer; the second waits 6 s more.
            if (root.ticks === 25)
                root.check("one reload after 3 s", SessionConfig.reloads === 1 && Displays.modelessNames.length === 1);
            // 8 s: still one (the back-off doubled).
            if (root.ticks === 40)
                root.check("no second reload before 9 s", SessionConfig.reloads === 1);
            // 16 s: the second reload went at about 9 s, the display then had a mode, and nothing more was asked.
            if (root.ticks === 80) {
                root.check("a second reload after 6 s more, then the display has a mode", root.sawRecovered && Displays.modelessNames.length === 0);
                root.check("no reload once every display has a mode", SessionConfig.reloads === 2 && Displays.recoveryAttempts === 0);
                console.log(root.failures.length === 0 ? "displays-modeless: PASS (" + SessionConfig.reloads + " reloads)" : "displays-modeless: FAIL " + root.failures.join("; "));
                Qt.quit();
            }
        }
    }
}
