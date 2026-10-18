pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Trash state for the Dock, read-only: empty or not, from ~/.local/share/Trash/files (in a dev session the isolated
// trash under .dev/apps-home, where the shell's own trash actions put files; ADR-0011).
// Event-driven: `gio monitor` reports changes; a check also runs at start and on demand.
// Nothing here ever modifies the trash.
Singleton {
    id: root

    readonly property string filesPath: {
        if (Apps.devSession)
            return Apps.appsHome + "/data/Trash/files";
        const xdg = Quickshell.env("XDG_DATA_HOME");
        return (xdg ? xdg : Quickshell.env("HOME") + "/.local/share") + "/Trash/files";
    }

    property bool empty: true

    function refresh(): void {
        check.running = true;
        if (!monitor.running)
            monitor.running = true;
    }

    // Open the trash in the default file manager (gio resolves trash:/// itself). A dev session never opens
    // trash:///: it is served by the owner's session and would show (and empty) the real trash. It opens the
    // isolated trash folder as a plain directory instead, and the dev open policy starts Grassfield Files on it
    // (Apps.openDetached; never the default handler, ADR-0011).
    function open(): void {
        Apps.openDetached(["gio", "open", Apps.devSession ? root.filesPath : "trash:///"]);
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
