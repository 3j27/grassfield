pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform
import qs.services

// ADR-0035 D-3: the shell side of "not responding" under the real Quickshell (tests/shell/anr_ipc.sh drives it through
// `qs ipc` and the stand-in, against a fake Hyprland). Loads NotResponding (IPC target anr) and asks Hyprland's client list,
// then prints "anr-probe: ready <windows known>".
ShellRoot {
    id: root

    Component.onCompleted: Compositor.refreshToplevels()

    Timer {
        interval: 200
        repeat: true
        running: true
        property bool told: false
        onTriggered: {
            const known = Compositor.knownWindows().filter(w => w.pid > 0).length;
            if (!told && known >= 3) {
                told = true;
                console.log("anr-probe: ready " + known + " marks " + NotResponding.marks.length);
            }
        }
    }
}
