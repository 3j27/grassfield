pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// Where the wallpaper lives on disk, and what it reports (ADR-0016). Shared by the desktop wallpaper (one feed per
// output, shell/desktop/WallpaperFeed.qml) and, later, the lock screen's still.
//   - Paths: the helper, its cache, the state and status files. A dev session (GRASSFIELD_DEV=1) keeps everything under
//     <repo>/.dev and refuses sources outside it (WallpaperConfig.sourceProblem).
//   - The carousel position per display ($XDG_STATE_HOME/grassfield/wallpaper.json, runtime state, safe to delete):
//     {"displays": {<key>: {seed, index, last, avoid, changedAt}}}, written atomically a short while after a change.
//   - The status per output ($XDG_CONFIG_HOME/grassfield/wallpaper-state.json, read by the Settings app):
//     {"outputs": {<name>: {state, reason, source, path, name, files}}}; state is builtin | color | preparing | ready | error.
Singleton {
    id: root

    readonly property bool dev: Quickshell.env("GRASSFIELD_DEV") === "1" && Quickshell.env("GRASSFIELD_SESSION") !== "1"
    readonly property string repoRoot: dev ? WallpaperConfig.normalizePath(Quickshell.shellDir + "/..") : ""
    readonly property var environment: ({
            dev: root.dev,
            repoRoot: root.repoRoot,
            home: Quickshell.env("HOME"),
            xdgCache: Quickshell.env("XDG_CACHE_HOME"),
            picturesDir: Quickshell.env("GRASSFIELD_PICTURES_DIR")
        })
    readonly property string tool: WallpaperConfig.toolPath(environment)
    readonly property string cacheDir: WallpaperConfig.cacheRoot(environment)
    readonly property string preparedDir: cacheDir + "/prepared"

    // GRASSFIELD_STATE_HOME (dev) wins; otherwise $XDG_STATE_HOME/grassfield.
    readonly property string stateDir: {
        const dev = Quickshell.env("GRASSFIELD_STATE_HOME");
        if (dev)
            return dev;
        const xdg = Quickshell.env("XDG_STATE_HOME");
        return (xdg ? xdg : Quickshell.env("HOME") + "/.local/state") + "/grassfield";
    }
    readonly property string stateFile: stateDir + "/wallpaper.json"
    readonly property string statusFile: Settings.configDir + "/wallpaper-state.json"

    // {output name: {state, reason, source, path, name, files, file}} as reported by the feeds.
    property var outputs: ({})
    // The loaded carousel state: {displays: {...}}.
    property var saved: ({displays: {}})
    // The carousel state has been read (or does not exist yet): feeds wait for it before choosing a picture.
    property bool stateReady: false

    function report(output: string, info: var): void {
        const next = Object.assign({}, outputs);
        next[output] = info;
        outputs = next;
        statusTimer.restart();
    }

    // The prepared picture of an output (for the lock screen's still), "" when the artwork or a colour is shown.
    function lockStill(output: string): string {
        const o = outputs[output];
        return o && o.state === "ready" && o.file ? o.file : "";
    }

    function carousel(key: string): var {
        const d = saved.displays && saved.displays[key];
        return d && typeof d === "object" ? d : null;
    }

    function setCarousel(key: string, state: var): void {
        const all = Object.assign({}, saved.displays);
        all[key] = state;
        saved = {displays: all};
        writeTimer.restart();
    }

    Timer {
        id: statusTimer
        interval: Tokens.wallpaperStateWriteMs
        onTriggered: statusWriter.setText(JSON.stringify({outputs: root.outputs}, null, 2) + "\n")
    }

    Timer {
        id: writeTimer
        interval: Tokens.wallpaperStateWriteMs
        onTriggered: stateWriter.setText(JSON.stringify(root.saved, null, 2) + "\n")
    }

    // The helper is installed and executable (checked once; "Wallpapers can't be prepared: the helper is missing").
    property bool toolChecked: false
    property bool toolMissing: false

    Process {
        command: ["test", "-x", root.tool]
        running: true
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            root.toolMissing = exitCode !== 0;
            root.toolChecked = true;
        }
        // qmllint enable signal-handler-parameters
    }

    // The state directory may not exist yet.
    Process {
        id: mkdir
        command: ["mkdir", "-p", "-m", "700", root.stateDir]
        running: true
        onRunningChanged: if (!running)
            stateReader.path = root.stateFile
    }

    FileView {
        id: stateReader
        printErrors: false
        onLoaded: {
            try {
                const o = JSON.parse(text());
                root.saved = {displays: o && typeof o.displays === "object" && o.displays !== null ? o.displays : {}};
            } catch (e) {
                root.saved = {displays: {}};
            }
            root.stateReady = true;
        }
        onLoadFailed: root.stateReady = true
    }

    FileView {
        id: stateWriter
        path: stateReader.path
        printErrors: false
        atomicWrites: true
    }

    FileView {
        id: statusWriter
        path: root.statusFile
        printErrors: false
        atomicWrites: true
    }
}
