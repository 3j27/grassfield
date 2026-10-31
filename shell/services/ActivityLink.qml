pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.platform
import "ActivityLinkLogic.js" as Logic
import "../dock/TileGraph.js" as TileGraph

// Activity Monitor's links with the shell (ADR-0038 f, AD29; docs/specs/activity.md AM60, AM61). While a window of the app is
// open on this display, the shell writes the projection `windows.json` in the display's runtime folder: the windows' client
// pids and app ids and the pids NotResponding marks (never a title), read again when a window opens or closes, coalesced over
// 250 ms; it is removed when the app's last window closes. The app reads it to name windowed processes, mark those that do
// not respond and quit through the shell. IPC `activity quit <pid>` closes that process's windows as the Dock's Quit does;
// it never kills.
Singleton {
    id: root

    readonly property string folder: Logic.runtimeDir(Quickshell.env("XDG_RUNTIME_DIR"), Quickshell.env("WAYLAND_DISPLAY"))
    // A window of Activity Monitor is open on this display.
    readonly property bool appOpen: root.folder !== "" && Compositor.toplevelsFor(Logic.APP_ID).length > 0
    // The body last written ("" when none is), and a write asked for while one runs.
    property string written: ""
    property bool again: false

    function schedule(): void {
        if (root.appOpen)
            coalesce.restart();
    }

    function write(): void {
        if (!root.appOpen)
            return;
        const body = Logic.projection(Compositor.knownWindows(), NotResponding.marks);
        if (body === root.written)
            return;
        if (writer.running) {
            root.again = true;
            return;
        }
        root.written = body;
        writer.command = ["sh", Quickshell.shellPath("services/activity-projection.sh"), root.folder, body];
        writer.running = true;
    }

    onAppOpenChanged: {
        if (root.appOpen) {
            Compositor.refreshToplevels();
            root.schedule();
        } else if (root.folder !== "") {
            coalesce.stop();
            root.written = "";
            root.tileGraph = null;
            remover.command = ["sh", Quickshell.shellPath("services/activity-projection.sh"), root.folder, "--remove"];
            remover.running = true;
        }
    }

    Timer {
        id: coalesce
        interval: 250
        onTriggered: root.write()
    }

    Process {
        id: writer
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            if (code !== 0) {
                console.warn("grassfield-shell: Activity Monitor's projection not written, exit", code);
                root.written = "";
            }
            if (root.again) {
                root.again = false;
                root.write();
            }
        }
    }

    Process {
        id: remover
    }

    // AM62: the graph the app gives its Dock tile ({kind, samples}), or null: read while the app's window is open, from this
    // display's folder only (a nested session's file never reaches the real Dock), checked before the Dock draws it.
    property var tileGraph: null

    function readTile(): void {
        root.tileGraph = root.appOpen ? TileGraph.parse(tileFile.text(), Compositor.toplevelsFor(Logic.APP_ID).map(t => Compositor.pidOf(t))) : null;
    }

    FileView {
        id: tileFile
        path: root.appOpen ? root.folder + "/dock-tile.json" : ""
        watchChanges: true
        printErrors: false
        onFileChanged: tileFile.reload()
        onLoaded: root.readTile()
        onLoadFailed: root.tileGraph = null
    }

    // The app replaces the file through a temporary name at each sample: read again at the slowest update frequency too,
    // in case a watch missed the rename.
    Timer {
        interval: 5000
        repeat: true
        running: root.appOpen
        onTriggered: tileFile.reload()
    }

    // A window opened or closed: Hyprland's list is read again (pid and class come with it), then written.
    Connections {
        target: Hyprland
        enabled: root.appOpen

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "openwindow" || event.name === "closewindow") {
                Compositor.refreshToplevels();
                root.schedule();
            }
        }
    }

    Connections {
        target: NotResponding
        enabled: root.appOpen

        function onMarksChanged(): void {
            root.schedule();
        }
    }

    // Hyprland's list read again delivers the pids: the next write sees them.
    Connections {
        target: Compositor.toplevels
        enabled: root.appOpen

        function onValuesChanged(): void {
            root.schedule();
        }
    }

    IpcHandler {
        target: "activity"

        // AM61 (security.md "IPC surface": an action of grassfield-activity, through apps/runmode.h shellIpcArgs). Closes every
        // window whose client is `pid`, as the Dock's Quit (an xdg close request: the app may ask to save), and answers "ok",
        // "no-windows" (the app then sends SIGTERM itself) or "refused" (a pid of 1 or below). Never kills, never reads a
        // title. The shell closes only its own compositor's windows: a nested session's shell reaches the nested
        // session's alone.
        function quit(pid: int): string {
            const plan = Logic.quitPlan(pid, Compositor.knownWindows().map(w => w.pid));
            if (plan.answer === "ok") {
                const tops = Compositor.knownToplevels();
                plan.indexes.forEach(i => Compositor.close(tops[i]));
            } else if (plan.answer === "refused") {
                console.info("grassfield-shell: activity quit refused for pid", pid);
            }
            return plan.answer;
        }
    }
}
