pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import "CaptureFile.js" as CaptureFile

// The capture helper as the shell sees it (ADR-0045 OC-1; spec docs/specs/system-dialogs.md "Capture toolbar" and "Screen
// recording"): the helper's private state, watched (a countdown the capture toolbar's plate shows, a recording the menu bar's
// stop item shows), the helper run for the toolbar, and its stop: by the menu bar's item and when the session locks (a recording
// never goes on under the lock; a countdown captures nothing).
//
// The helper (packaging/bin/grassfield-capture) writes $XDG_RUNTIME_DIR/grassfield/capture-state.json by rename; its folder is
// made first (0700, as the helper makes it): a FileView sees no file in a missing folder. A dev session runs no helper unless it
// names one (GRASSFIELD_CAPTURE_HELPER, ADR-0019: a fake in the nested checks) and reads its state from the dev state
// (GRASSFIELD_STATE_HOME), never the real session's.
Singleton {
    id: root

    readonly property string tool: Mode.dev ? Mode.devValue("CAPTURE_HELPER") : "/usr/lib/grassfield/grassfield-capture"
    readonly property string path: CaptureFile.statePath(Mode.stateHome, Quickshell.env("XDG_RUNTIME_DIR"))
    readonly property string folder: root.path !== "" ? root.path.substring(0, root.path.lastIndexOf("/")) : ""

    // The state as read (CaptureFile.parse): phase idle | selecting | countdown | recording, and its fields.
    property var state: CaptureFile.parse("")
    readonly property string phase: root.state.phase
    readonly property bool recording: root.phase === "recording"
    // The clock of the countdown and of the elapsed time, a tick a quarter of a second while either shows.
    property real now: Date.now()
    readonly property int secondsLeft: root.phase === "countdown" ? CaptureFile.secondsLeft(root.now, root.state.until) : 0
    readonly property bool countingDown: root.secondsLeft > 0
    readonly property string elapsedText: CaptureFile.elapsed(root.now - root.state.started)
    // gpu-screen-recorder is installed (an Omarchy base package): asked when the toolbar opens, as it is used (OC-0 rule 3).
    property bool recorderAvailable: false

    // Runs the helper with `args`. In a real session it gets a scope of its own (uwsm-app, as the Dock starts apps): a recording
    // must not live in the shell's unit (its CPU and memory limits, its restarts). Nothing runs without a helper (a dev session).
    function run(args: var): void {
        if (root.tool === "") {
            console.info("grassfield: capture not run (dev session without GRASSFIELD_CAPTURE_HELPER): " + args.join(" "));
            return;
        }
        Apps.whenScopeKnown(() => Quickshell.execDetached(Apps.scoped([root.tool].concat(args))));
    }

    // Ends the recording, or the choice or countdown of a capture (the helper's `stop`, which signals only its own processes).
    function stop(): void {
        if (root.tool === "") {
            console.info("grassfield: capture stop not run (dev session without GRASSFIELD_CAPTURE_HELPER)");
            return;
        }
        Quickshell.execDetached([root.tool, "stop"]);
    }

    function probeRecorder(): void {
        if (!probe.running)
            probe.running = true;
    }

    // The session locks: a recording stops, a countdown captures nothing (macOS: nothing is recorded behind the lock).
    Connections {
        target: SessionState

        function onLockedChanged(): void {
            if (SessionState.locked && root.phase !== "idle")
                root.stop();
        }
    }

    Timer {
        interval: 250
        repeat: true
        triggeredOnStart: true
        running: root.phase === "countdown" || root.phase === "recording"
        onTriggered: root.now = Date.now()
    }

    Process {
        id: probe
        command: ["sh", "-c", "command -v gpu-screen-recorder"]
        stdout: StdioCollector {
            onStreamFinished: root.recorderAvailable = text.trim() !== ""
        }
    }

    Process {
        id: prepare
        running: root.folder !== ""
        command: ["sh", "-c", "umask 077; mkdir -p -m 700 -- \"$1\"", "sh", root.folder]
        onRunningChanged: {
            if (!running)
                stateFile.path = root.path;
        }
    }

    FileView {
        id: stateFile
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.state = CaptureFile.parse(stateFile.text())
        onLoadFailed: root.state = CaptureFile.parse("")
    }

    Component.onCompleted: root.probeRecorder()
}
