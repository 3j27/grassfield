pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform
import "ActivityLinkLogic.js" as Logic

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
            root.tileText = "";
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

    // AM62: the text of the graph the app gives its Dock tile, "" when none: read while the app's window is open, from this
    // display's folder only (a nested session's file never reaches the real Dock). The Dock checks it before it draws it
    // (shell/dock/TileGraph.js parse, against `tilePids`: the pids of the app's windows now).
    property string tileText: ""
    readonly property var tilePids: root.appOpen ? Compositor.toplevelsFor(Logic.APP_ID).map(t => Compositor.pidOf(t)) : []

    function readTile(): void {
        root.tileText = root.appOpen ? tileFile.text() : "";
    }

    FileView {
        id: tileFile
        path: root.appOpen ? root.folder + "/dock-tile.json" : ""
        watchChanges: true
        printErrors: false
        onFileChanged: tileFile.reload()
        onLoaded: root.readTile()
        onLoadFailed: root.tileText = ""
    }

    // The app replaces the file through a temporary name at each sample: read again at the slowest update frequency too,
    // in case a watch missed the rename.
    Timer {
        interval: 5000
        repeat: true
        running: root.appOpen
        onTriggered: tileFile.reload()
    }

    // A window opened or closed (the platform layer relays Hyprland's events): its list is read again (pid and class come
    // with it), then written.
    Connections {
        target: Compositor
        enabled: root.appOpen

        function onInterrupted(event: string): void {
            if (event === "openwindow" || event === "closewindow") {
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
            // Only the windows the shell can ask to close count: one without its protocol handle is no window here, so the
            // answer is then "no-windows" and the app sends SIGTERM itself.
            const tops = Compositor.knownToplevels();
            const plan = Logic.quitPlan(pid, Compositor.knownWindows().map((w, i) => tops[i] ? w.pid : 0));
            if (plan.answer === "ok") {
                plan.indexes.forEach(i => Compositor.close(tops[i]));
            } else if (plan.answer === "refused") {
                console.info("grassfield-shell: activity quit refused for pid", pid);
            }
            return plan.answer;
        }
    }
}
