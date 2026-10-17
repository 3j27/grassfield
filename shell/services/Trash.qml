pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Trash state for the Dock, read-only: empty or not, from ~/.local/share/Trash/files.
// Event-driven: `gio monitor` reports changes; a check also runs at start and on demand.
// Nothing here ever modifies the trash.
Singleton {
    id: root

    readonly property string filesPath: {
        const xdg = Quickshell.env("XDG_DATA_HOME");
        return (xdg ? xdg : Quickshell.env("HOME") + "/.local/share") + "/Trash/files";
    }

    property bool empty: true

    function refresh(): void {
        check.running = true;
        if (!monitor.running)
            monitor.running = true;
    }

    // Open the trash in the default file manager (gio resolves trash:/// itself).
    function open(): void {
        Apps.openDetached(["gio", "open", "trash:///"]);
    }

    Component.onCompleted: refresh()

    Process {
        id: check
        command: ["find", root.filesPath, "-mindepth", "1", "-maxdepth", "1", "-print", "-quit"]
        stdout: StdioCollector {
            // A missing directory prints nothing on stdout: that is an empty trash.
            onStreamFinished: root.empty = text.trim() === ""
        }
    }

    Process {
        id: monitor
        // pdeathsig: the monitor dies with the shell even on SIGKILL.
        command: ["setpriv", "--pdeathsig", "KILL", "--", "gio", "monitor", root.filesPath]
        stdout: SplitParser {
            onRead: check.running = true
        }
    }
}
