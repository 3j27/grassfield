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
//     {"outputs": {<name>: {state, reason, source, path, name, files}}, "online": {...}}; state is builtin | color | preparing |
//     ready | error | waiting (the online source with nothing cached yet).
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
    // The transcoded video wallpapers, their posters and statistics (grassfield-wallpaper transcode).
    readonly property string videoDir: cacheDir + "/video"

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
    // The online daily picture (WallpaperOnline): {phase, provider, failure, entry: {date, title, author, credit, caption,
    // licenseShort, licenseUrl, sourceUrl, fetchedAt, file} | null}; {} before it reports. Written with the outputs for Settings.
    property var online: ({})
    // The loaded carousel state: {displays: {...}}.
    property var saved: ({displays: {}})
    // The carousel state has been read (or does not exist yet): feeds wait for it before choosing a picture.
    property bool stateReady: false

    function report(output: string, info: var): void {
        const next = Object.assign({}, outputs);
        next[output] = info;
        outputs = next;
        // Coalesced: the file is written once, a short while after the first change (a transcode reports its progress
        // every percent; a restart on every report would never write until it ended).
        if (!statusTimer.running)
            statusTimer.start();
    }

    function reportOnline(info: var): void {
        online = info;
        if (!statusTimer.running)
            statusTimer.start();
    }

    // True while the picture of an output is the online daily one (the desktop menu's "About This Wallpaper").
    function onlineShown(output: string): bool {
        const o = outputs[output];
        return !!o && o.source === "online" && o.state === "ready" && !!online.entry;
    }

    // The still of an output for the lock screen (ADR-0016 section 6; read only, the lock calls it and nothing else here):
    // the prepared picture, or the poster frame of a video wallpaper, both Grassfield's own JPEG or PNG in the 0700 cache folder
    // (prepared/ or video/). "" when the artwork or a colour is shown, when nothing is ready, or when the path is not under
    // the cache: the lock then keeps the artwork.
    function lockStill(output: string): string {
        const o = outputs[output];
        if (!o || o.state !== "ready" || typeof o.file !== "string" || o.file === "")
            return "";
        const f = o.file;
        return WallpaperConfig.isUnder(f, preparedDir) || WallpaperConfig.isUnder(f, videoDir) ? f : "";
    }

    // ---- video crash marker (ADR-0016 section 5) ----
    // The shell writes {path, at} to wallpaper.json BEFORE a video starts playing and clears it after Tokens.wallpaperVideoStableMs
    // of playback. A marker found at start means the shell died while that video started: the path is then `videoBlocked` (the
    // poster still shows, no retry, Settings explains once) until the wallpaper is changed to something else.
    property string videoBlocked: ""
    property string videoStarting: ""

    function markVideoStarting(path: string): void {
        if (videoStarting === path)
            return;
        videoStarting = path;
        writeNow();
    }

    function clearVideoStarting(): void {
        if (videoStarting === "")
            return;
        videoStarting = "";
        writeNow();
    }

    // A video is no longer the wallpaper of any output: it may play again the next time it is chosen.
    function releaseVideo(): void {
        if (videoBlocked === "")
            return;
        for (const name of Object.keys(outputs)) {
            const o = outputs[name];
            if (o.source === "video" && o.path === videoBlocked)
                return;
        }
        videoBlocked = "";
        writeNow();
    }

    function stateJson(): string {
        const o = {displays: saved.displays};
        if (videoStarting !== "")
            o.videoStarting = {path: videoStarting, at: Date.now()};
        if (videoBlocked !== "")
            o.videoBlocked = videoBlocked;
        return JSON.stringify(o, null, 2) + "\n";
    }

    // Written at once (the marker must be on disk before the video starts), atomically.
    function writeNow(): void {
        if (!stateReady)
            return;
        writeTimer.stop();
        stateWriter.setText(stateJson());
    }

    // Names the running login: the compositor instance (a restart of the shell within it is not a new login), else the
    // login session; "" when neither is known (every start counts as a login).
    readonly property string loginKey: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || Quickshell.env("XDG_SESSION_ID") || ""

    // The prepared pictures on screen, for every output: the helper never prunes them from its cache.
    function currentFiles(): var {
        const out = [];
        for (const name of Object.keys(outputs)) {
            const f = outputs[name].file;
            if (typeof f === "string" && f !== "")
                out.push(f);
        }
        return out;
    }

    // The transcoded files and posters on screen: the helper never prunes them from the video cache.
    function currentVideoFiles(): var {
        const out = [];
        for (const name of Object.keys(outputs)) {
            const o = outputs[name];
            if (typeof o.video === "string" && o.video !== "")
                out.push(o.video);
            if (typeof o.file === "string" && o.file !== "" && WallpaperConfig.isUnder(o.file, videoDir))
                out.push(o.file);
        }
        return out;
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
        onTriggered: statusWriter.setText(JSON.stringify({outputs: root.outputs, online: root.online}, null, 2) + "\n")
    }

    Timer {
        id: writeTimer
        interval: Tokens.wallpaperStateWriteMs
        onTriggered: stateWriter.setText(root.stateJson())
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
                // A marker left by the previous run: that video crashed the shell while it started. It becomes `videoBlocked`
                // (no retry) and the marker is gone, so the next start does not read it again.
                const marker = WallpaperConfig.videoMarkerOf(o ? o.videoStarting : null);
                if (marker) {
                    root.videoBlocked = marker.path;
                    console.warn("wallpaper: the shell stopped while the video " + marker.path + " started; its poster is shown and it is not played again");
                    root.stateReady = true;
                    Qt.callLater(root.writeNow);
                } else if (o && typeof o.videoBlocked === "string" && WallpaperConfig.pathProblem(o.videoBlocked) === "") {
                    root.videoBlocked = o.videoBlocked;
                }
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
