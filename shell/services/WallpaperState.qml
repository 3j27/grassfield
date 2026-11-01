pragma Singleton
import QtQuick
import Quickshell
import qs.lib
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

    readonly property bool dev: Mode.dev
    readonly property string repoRoot: dev ? WallpaperConfig.normalizePath(Quickshell.shellDir + "/..") : ""
    readonly property var environment: ({
            dev: root.dev,
            repoRoot: root.repoRoot,
            home: Quickshell.env("HOME"),
            xdgCache: Quickshell.env("XDG_CACHE_HOME"),
            picturesDir: Mode.devValue("PICTURES_DIR")
        })
    readonly property string tool: WallpaperConfig.toolPath(environment)
    // The helper runs with a UTF-8 locale even when the session has none (FINDINGS 5: Qt warned on every start).
    readonly property var toolEnv: WallpaperConfig.toolEnvironment({
            lcAll: Quickshell.env("LC_ALL") || "",
            lcCtype: Quickshell.env("LC_CTYPE") || "",
            lang: Quickshell.env("LANG") || ""
        })
    readonly property string cacheDir: WallpaperConfig.cacheRoot(environment)
    readonly property string preparedDir: cacheDir + "/prepared"
    // The transcoded video wallpapers, their posters and statistics (grassfield-wallpaper transcode).
    readonly property string videoDir: cacheDir + "/video"

    // GRASSFIELD_STATE_HOME wins; otherwise $XDG_STATE_HOME/grassfield.
    readonly property string stateDir: Mode.stateDir
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

    // {output name: true} for the outputs whose menu bar band is on because of the wallpaper under it.
    function barAssists(): var {
        return BarTone.forcedOutputs();
    }

    Connections {
        target: BarTone

        function onAssistsChanged(): void {
            if (!statusTimer.running)
                statusTimer.start();
        }
    }

    function reportOnline(info: var): void {
        online = info;
        if (!statusTimer.running)
            statusTimer.start();
    }

    // The shipped photographs (ADR-0040 step 2c): their list beside them (photos.json in the package's folder; a dev session's
    // .dev/photos, scripts/dev/photos.sh), read once at start as Settings reads it; [] without them.
    readonly property string photosDir: dev ? repoRoot + "/.dev/photos" : "/usr/share/grassfield/wallpapers/photos"
    property var photos: []

    // What the desktop's "About This Wallpaper" shows for an output: the online picture's attribution or the shown photograph's
    // ({title, author, sourceUrl, licenseShort, licenseUrl}; WallpaperConfig.aboutEntryOf); null when neither is on screen.
    function aboutEntry(output: string): var {
        return WallpaperConfig.aboutEntryOf(outputs[output], online, photos, Qt.locale().name);
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
    // The shell writes {path, at} to wallpaper.json BEFORE a video FIRST starts playing and clears it after
    // Tokens.wallpaperVideoStableMs of playback, or when that video is deliberately paused or released. Every output owns its marker
    // (`owner` = the output's name): one output's pause never clears another output's marker, and a later play of the same video
    // (after an unlock or an idle return) writes nothing. A marker found at start means the shell died while that video started:
    // the path is then blocked (the poster still shows, no retry, Settings explains once) until the wallpaper is changed to
    // something else.
    property var videoBlockedPaths: []
    // owner (output name) -> path of the video that output is starting.
    property var videoStartingBy: ({})

    function isVideoBlocked(path: string): bool {
        return WallpaperConfig.videoBlocked(videoBlockedPaths, path);
    }

    function markVideoStarting(owner: string, path: string): void {
        if (videoStartingBy[owner] === path)
            return;
        const next = Object.assign({}, videoStartingBy);
        next[owner] = path;
        videoStartingBy = next;
        writeNow();
    }

    // Clears the marker of `owner` only when it still names `path`: the two slots of one output share the owner, and the old slot's
    // pause or release must not clear the marker of the video that replaced it.
    function clearVideoStarting(owner: string, path: string): void {
        if (videoStartingBy[owner] === undefined || videoStartingBy[owner] !== path)
            return;
        const next = Object.assign({}, videoStartingBy);
        delete next[owner];
        videoStartingBy = next;
        writeNow();
    }

    // The block exists for the AUTOMATIC restart only (the shell starting again with the video that crashed it). A fresh choice of the
    // user is consent to try again (macOS model): the feed calls this when the wallpaper of an output changes after the shell started
    // (away from the video, or to it).
    function unblockVideo(path: string): void {
        if (!isVideoBlocked(path))
            return;
        videoBlockedPaths = videoBlockedPaths.filter(p => p !== path);
        writeNow();
    }

    // The carousel, the last wallpaper shown on each output (ADR-0040 ID-3, ID-7: the first frame of the next start, the
    // lock's backdrop), the video markers (WallpaperConfig.stateText).
    function stateJson(): string {
        return WallpaperConfig.stateText(saved, videoStartingBy, videoBlockedPaths, Date.now());
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

    // The prepared pictures on screen, for every output, and the stills of the next start (ADR-0040 ID-3: a still decoding
    // while the first prepare runs, or the lock's): the helper never prunes them from its cache.
    function currentFiles(): var {
        const out = [];
        for (const name of Object.keys(outputs)) {
            const f = outputs[name].file;
            if (typeof f === "string" && f !== "")
                out.push(f);
        }
        for (const name of Object.keys(saved.shown || {})) {
            const st = WallpaperConfig.stillOf(saved, name, preparedDir);
            if (st !== null && out.indexOf(st.file) < 0)
                out.push(st.file);
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
        saved = WallpaperConfig.withCarousel(saved, key, state);
        writeTimer.restart();
    }

    // ---- the first frame (ADR-0040 step 3, ID-3) and the lock's backdrop (step 4a, ID-7) ----
    // The last picture an output showed, for its first frame at the next start: {file, strip, image, mean} or null (validated:
    // one of the helper's own prepared pictures; WallpaperConfig.stillOf).
    function stillOf(output: string): var {
        return WallpaperConfig.stillOf(saved, output, preparedDir);
    }

    // What the lock draws on `output` (WallpaperConfig.lockBackdropOf): {kind, file, color, artwork, variant}, or null when
    // the output never showed a wallpaper. Read by shell/security/lock (which checks the file again).
    function lockBackdrop(output: string): var {
        return WallpaperConfig.lockBackdropOf(saved, output, preparedDir, videoDir);
    }

    // The output now shows `desc`; `art` ({artwork, variant}) is what it would draw instead. Written a short while after.
    function setShown(output: string, desc: var, art: var): void {
        const next = WallpaperConfig.withShown(saved, output, desc, art);
        // Unchanged record: nothing to write (the order of the outputs only decides which go past 16).
        if (JSON.stringify(next.shown[output]) === JSON.stringify((saved.shown || {})[output]))
            return;
        saved = next;
        writeTimer.restart();
    }

    // ---- the moving Grassfield artwork (ADR-0040 step 9, as the integrator decided in the review of e067f26f) ----
    // wallpaper.moving, and where its clouds rest on each output (ms of motion; WallpaperConfig.motionIn). The desktop draws
    // them still there; only the lock screen moves them, from there, and gives back where they came to rest
    // (shell/security/lock, through LockStills: display data only). Kept for the session, not stored: a new one starts at 0.
    readonly property bool moving: WallpaperConfig.normalize(Settings.wallpaper).moving
    property var motion: ({})
    function motionOf(output: string): real {
        return WallpaperConfig.motionIn(root.motion, output);
    }
    function setMotion(output: string, at: real): void {
        if (WallpaperConfig.motionIn(root.motion, output) !== at)
            root.motion = WallpaperConfig.withMotion(root.motion, output, at);
    }

    Timer {
        id: statusTimer
        interval: Tokens.wallpaperStateWriteMs
        // `bar`: {output: true} where the menu bar shows its band because of the wallpaper (BarTone.assists, ADR-0016 D1): Settings > Menu Bar says so.
        onTriggered: statusWriter.setText(JSON.stringify({outputs: root.outputs, online: root.online, bar: root.barAssists()}, null, 2) + "\n")
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
                root.saved = {displays: o && typeof o.displays === "object" && o.displays !== null ? o.displays : {}, shown: o && typeof o.shown === "object" && o.shown !== null && !Array.isArray(o.shown) ? o.shown : {}};
                // A marker left by the previous run: that video crashed the shell while it started. It becomes `videoBlocked`
                // (no retry) and the marker is gone, so the next start does not read it again.
                const markers = WallpaperConfig.videoMarkersOf(o && o.videoStarting !== undefined ? o.videoStarting : []);
                const blocked = WallpaperConfig.videoBlockedPaths(o ? o.videoBlocked : []);
                for (const m of markers) {
                    console.warn("wallpaper: the shell stopped while the video " + m.path + " started; its poster is shown and it is not played again");
                    if (blocked.indexOf(m.path) < 0)
                        blocked.push(m.path);
                }
                root.videoBlockedPaths = blocked.slice(0, 16);
                if (markers.length > 0) {
                    root.stateReady = true;
                    Qt.callLater(root.writeNow);
                }
            } catch (e) {
                root.saved = {displays: {}};
            }
            root.stateReady = true;
        }
        onLoadFailed: root.stateReady = true
    }

    FileView {
        id: photosReader
        path: root.photosDir + "/photos.json"
        printErrors: false
        onLoaded: root.photos = WallpaperConfig.parsePhotos(text(), root.photosDir)
        onLoadFailed: root.photos = []
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
