pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform

// Glance (`grassfield-preview --glance <files>`) for the surfaces of the shell. Lives in a singleton so the
// process outlives the surface that asked for it, and so Space can toggle it: a layer surface keeps the
// keyboard focus when a window maps, so Glance cannot always close itself from the desktop.
// toggle(paths): closes the running Glance when it shows the same files, otherwise shows these files.
// A missing binary is reported instead of failing silently. Dev: GRASSFIELD_PREVIEW_CMD points at the dev build.
Singleton {
    id: root

    // Emitted when grassfield-preview cannot be found.
    signal missing

    property string shownKey: ""
    property var queued: null

    // Glance is showing (or starting).
    property bool starting: false
    readonly property bool open: launcher.running || starting

    // Closes Glance (Esc on the desktop: the desktop keeps the keyboard when Glance maps, so Glance cannot close itself).
    function close(): void {
        root.queued = null;
        if (starting)
            cancelStart();
        if (launcher.running)
            launcher.signal(15);
    }

    // Drops a start that still waits for the scope detection (Esc or a second Space in that short window): its callback
    // finds a newer token and does nothing.
    property int startToken: 0
    function cancelStart(): void {
        root.startToken++;
        root.starting = false;
        root.shownKey = "";
    }

    function toggle(paths: var): void {
        if (!paths || paths.length === 0)
            return;
        // A second Space while the start is pending cancels it (like a second Space on a running Glance closes it).
        if (starting) {
            cancelStart();
            return;
        }
        const files = paths.slice(0, 50);
        const key = files.join("\n");
        if (launcher.running) {
            const same = key === root.shownKey;
            root.queued = same ? null : files;
            launcher.signal(15);
            return;
        }
        root.start(files);
    }

    function start(files: var): void {
        const cmd = (Quickshell.env("GRASSFIELD_PREVIEW_CMD") || "grassfield-preview").split(" ").filter(w => w !== "" && w !== "--glance");
        root.shownKey = files.join("\n");
        // "open" is true from here on (a second toggle while the scope detection is pending closes nothing twice).
        root.starting = true;
        const token = ++root.startToken;
        Apps.whenScopeKnown(() => {
            if (token !== root.startToken)
                return;
            // In a real session Glance gets a scope of its own (Apps.scoped). uwsm-app execs systemd-run --scope, so the
            // process the shell holds is the application: close() still signals it.
            launcher.command = ["sh", "-c", "command -v -- \"$1\" >/dev/null 2>&1 || { echo missing; exit 0; }; shift; exec \"$@\"", "sh", cmd[0]].concat(Apps.scoped(cmd.concat(["--glance", "--"], files)));
            // The pointer size and colour theme the user chose (Pointer.launchEnvironment), like every app the shell starts.
            launcher.environment = Pointer.launchEnvironment();
            root.starting = false;
            launcher.running = true;
        });
    }

    Process {
        id: launcher
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "missing")
                    return;
                console.warn("grassfield: Glance is not installed (grassfield-preview not found)");
                root.missing();
            }
        }
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            // qmllint enable signal-handler-parameters
            root.shownKey = "";
            const next = root.queued;
            root.queued = null;
            if (next)
                root.start(next);
        }
    }
}
