pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// Regenerates the cursor theme for the pointer colours (Settings > Accessibility > Pointer, ADR-0014): runs
// branding/cursors/build.sh (installed as /usr/share/grassfield/cursors/build.sh; python3, rsvg-convert and
// hyprcursor-util are runtime dependencies of the package) with the outline and fill colours and writes
// grassfield-cursors-custom into the icons directory, atomically (build.sh builds into a temporary directory and renames
// it). It does not talk to the compositor: Pointer.qml switches to the theme when `ready`.
//   - Default colours (the packaged theme's own): nothing is built; removeTheme() deletes the custom theme.
//   - Off the UI thread: a Process, no shell, one argument vector (PointerColors.buildCommand).
//   - Debounced: a colour well dragged for a second makes one build, for the colour it stops on (the final pair is
//     always built). One build at a time: colours that change while a build runs terminate it (SIGTERM, SIGKILL after
//     settingsPointerBuildKillMs) and the newest pair is built next; a build that runs longer than
//     settingsPointerBuildTimeoutMs is killed.
//   - Failure path: `error` holds the reason (missing tool, no script, no directory), the pair counts as failed (not
//     retried until the colours change) and the pointer stays as it is. The state is also written to `statusPath` (JSON)
//     for the Settings app: {"state": "default|building|ready|failed", "outline", "fill", "reason"}.
// The dev session never writes outside .dev/: shell-run.sh sets GRASSFIELD_CURSORS_ICONS and GRASSFIELD_CURSORS_BUILD;
// a dev session without an icons directory refuses to build.
Scope {
    id: root

    property string outline: PointerColors.DEFAULT_OUTLINE
    property string fill: PointerColors.DEFAULT_FILL
    property string script: Quickshell.env("GRASSFIELD_CURSORS_BUILD") || "/usr/share/grassfield/cursors/build.sh"
    property string iconsDir: PointerColors.iconsDir(Quickshell.env("GRASSFIELD_CURSORS_ICONS"), Quickshell.env("XDG_DATA_HOME"), Quickshell.env("HOME"), Quickshell.env("GRASSFIELD_DEV") === "1")
    // File the state is written to ("" = not written).
    property string statusPath: ""
    property int debounceMs: Tokens.settingsPointerColorDebounceMs
    property int timeoutMs: Tokens.settingsPointerBuildTimeoutMs
    property int killMs: Tokens.settingsPointerBuildKillMs

    // Colour pair as a key ("" for the default pair).
    readonly property string wantedKey: PointerColors.key(root.outline, root.fill)
    // The theme on disk is the one of the wanted colours.
    readonly property bool ready: root.wantedKey !== "" && root.plan.built === root.wantedKey
    readonly property bool building: root.plan.running !== ""
    // Counts finished builds: a rebuilt theme under the same name has to be loaded again by the compositor.
    property int generation: 0
    property string error: ""
    // Observable by tests.
    property int started: 0
    property int cancelled: 0
    property int removals: 0
    property var lastCommand: []

    property var plan: PointerColors.initialState()
    property string buildErrors: ""
    property bool removing: false
    // A build ended with this exit code and its stderr is still being read (-1: no build ended / already handled).
    property int pendingExit: -1
    property bool errorsDone: true
    // A build was started since the shell started: a custom theme may be on disk (removeTheme deletes it).
    property bool dirty: false

    onWantedKeyChanged: {
        if (root.wantedKey === "") {
            // Back to the default pair: no wait, nothing to build.
            debounce.stop();
            root.settle();
        } else {
            debounce.restart();
        }
    }

    // The debounce is over (or the pair is the default one): the wanted pair is what the colours are now.
    function settle(): void {
        root.plan = PointerColors.want(root.plan, root.wantedKey);
        if (root.wantedKey === "")
            root.error = "";
        root.step();
        root.writeStatus();
    }

    function step(): void {
        if (root.removing)
            return;
        const action = PointerColors.decide(root.plan);
        if (action === "start") {
            root.startBuild();
        } else if (action === "terminate") {
            root.plan = PointerColors.terminating(root.plan);
            root.cancelled++;
            builder.signal(15);
            watchdog.interval = root.killMs;
            watchdog.restart();
        }
    }

    function startBuild(): void {
        const key = root.plan.wanted;
        const pair = key.split("|");
        const command = PointerColors.buildCommand(root.script, root.iconsDir, pair[0], pair[1]);
        root.plan = PointerColors.started(root.plan);
        if (command.length === 0) {
            root.finishBuild(false, "no folder for the custom cursor theme (dev session without GRASSFIELD_CURSORS_ICONS, or no home)");
            return;
        }
        root.started++;
        root.dirty = true;
        root.lastCommand = command;
        root.buildErrors = "";
        root.pendingExit = -1;
        root.errorsDone = false;
        root.error = "";
        builder.command = command;
        builder.running = true;
        watchdog.interval = root.timeoutMs;
        watchdog.restart();
        root.writeStatus();
    }

    // The process ended and its stderr is complete (the two events arrive in either order).
    function maybeFinish(): void {
        if (root.pendingExit < 0 || !root.errorsDone)
            return;
        const code = root.pendingExit;
        root.pendingExit = -1;
        root.finishBuild(code === 0, PointerColors.failureReason(code, root.buildErrors));
    }

    function finishBuild(ok: bool, reason: string): void {
        const wasCancelled = root.plan.terminating;
        watchdog.stop();
        // The generation first: whoever reacts to the new plan (Pointer.qml) sees the finished build's number.
        if (ok)
            root.generation++;
        root.plan = PointerColors.exited(root.plan, ok);
        if (ok) {
            root.error = "";
        } else if (!wasCancelled) {
            root.error = reason;
            console.info("grassfield-shell: pointer colours not applied: " + reason);
        }
        root.writeStatus();
        root.step();
    }

    // Reset Color: the custom theme is no longer needed (Pointer.qml calls this once the compositor uses the session's).
    function removeTheme(): void {
        if (root.wantedKey !== "" || root.building || root.removing || !root.dirty)
            return;
        const command = PointerColors.removeCommand(root.script, root.iconsDir);
        if (command.length === 0)
            return;
        root.removing = true;
        root.dirty = false;
        // The theme is about to be deleted: the same colours chosen again have to be built again.
        root.plan = PointerColors.forgetBuilt(root.plan);
        root.removals++;
        remover.command = command;
        remover.running = true;
    }

    function statusText(): string {
        const state = root.wantedKey === "" ? "default" : (root.building ? "building" : (root.ready ? "ready" : (root.error !== "" ? "failed" : "building")));
        return JSON.stringify({
            "state": state,
            "outline": PointerColors.normalizeOutline(root.outline),
            "fill": PointerColors.normalizeFill(root.fill),
            "reason": state === "failed" ? root.error : ""
        }) + "\n";
    }

    function writeStatus(): void {
        if (root.statusPath === "")
            return;
        const text = root.statusText();
        if (statusFile.path !== root.statusPath)
            statusFile.path = root.statusPath;
        statusFile.setText(text);
    }

    onStatusPathChanged: root.writeStatus()

    Timer {
        id: debounce
        interval: root.debounceMs
        onTriggered: root.settle()
    }

    // A build that does not stop: killed.
    Timer {
        id: watchdog
        onTriggered: {
            console.info("grassfield-shell: pointer theme build did not finish in time, killing it");
            builder.signal(9);
        }
    }

    Process {
        id: builder
        stderr: StdioCollector {
            onStreamFinished: {
                root.buildErrors = text;
                root.errorsDone = true;
                root.maybeFinish();
            }
        }
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            // qmllint enable signal-handler-parameters
            root.pendingExit = exitCode >= 0 ? exitCode : 255;
            root.maybeFinish();
        }
    }

    Process {
        id: remover
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            // qmllint enable signal-handler-parameters
            root.removing = false;
            root.step();
        }
    }

    FileView {
        id: statusFile
        printErrors: false
        atomicWrites: true
    }
}
