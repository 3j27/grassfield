pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.services

// What one output's wallpaper shows, decided from the settings (ADR-0016). Not a surface: Wallpaper.qml draws `imageUrl`.
//   - source builtin / color: no picture (`imageUrl` ""), the artwork or the colour is drawn.
//   - source file: grassfield-wallpaper prepares the picture at this output's physical size and fit (the shell decodes only
//     the helper's own output), `imageUrl` names the prepared file, `strip` holds the menu bar strip statistics.
//   - source folder: the helper lists the folder, WallpaperConfig.advance picks the next picture (sorted or shuffled without
//     repeat, position kept in WallpaperState), the interval timer asks for the next one. A file that fails is skipped for the
//     session; with every file failing the current picture stays and `reason` says why.
// One job at a time per output: a newer request supersedes (the running process gets SIGTERM, its answer is ignored); a job
// that runs too long is killed. On any failure the previous wallpaper stays (never a blank frame) and `status` is "error".
Scope {
    id: root

    required property var screenInfo

    readonly property real scale: screenInfo.devicePixelRatio > 0 ? screenInfo.devicePixelRatio : 1
    readonly property int pixelWidth: Math.max(1, Math.round(screenInfo.width * scale))
    readonly property int pixelHeight: Math.max(1, Math.round(screenInfo.height * scale))
    readonly property var display: ({
            name: screenInfo.name,
            model: screenInfo.model,
            serial: screenInfo.serialNumber
        })
    readonly property string displayKey: WallpaperConfig.displayKey(display)
    // Effective settings of this output.
    readonly property var cfg: WallpaperConfig.resolve(Settings.wallpaper, display)
    readonly property string cfgKey: JSON.stringify([cfg, pixelWidth, pixelHeight])

    // builtin | color | preparing | ready | error
    property string status: "builtin"
    // Failure id (WallpaperConfig.reasonOf ids, plus folder-unavailable, folder-empty, all-failed, outside-dev, invalid-path,
    // helper-missing, timeout): translated by the Settings app.
    property string reason: ""
    // file: URL of the prepared picture, "" for the artwork or a colour.
    property string imageUrl: ""
    property string currentFile: ""
    // Strip statistics of the prepared picture ({rows, all, left, right}), null without a picture.
    property var strip: null
    // File name of the picture shown (Settings caption).
    property string label: ""
    property var files: []
    property var bad: ({})
    property int generation: 0
    // Observable by tests.
    property int started: 0
    property int cancelled: 0

    property string identity: ""
    property string currentSrc: ""
    property bool advanceRequested: false
    property bool completed: false

    readonly property bool ready: WallpaperState.stateReady && WallpaperState.toolChecked

    onCfgKeyChanged: schedule()
    onReadyChanged: schedule()
    Component.onCompleted: {
        completed = true;
        schedule();
    }

    function schedule(): void {
        if (completed && ready)
            debounce.restart();
    }

    Timer {
        id: debounce
        interval: Tokens.wallpaperChangeDebounceMs
        onTriggered: root.apply()
    }

    // The carousel clock: only a folder with a timed interval.
    Timer {
        interval: Math.max(1000, WallpaperConfig.intervalMs(root.cfg.interval))
        repeat: true
        running: root.ready && root.cfg.source === "folder" && WallpaperConfig.intervalMs(root.cfg.interval) > 0 && root.files.length > 1
        onTriggered: root.requestAdvance()
    }

    // ---- jobs: one WallpaperJob (one Process) per request ----
    Component {
        id: jobFactory
        WallpaperJob {}
    }

    property var activeJob: null

    function startJob(kind: string, args: var, timeoutMs: int): void {
        if (!args) {
            fail("invalid-path");
            return;
        }
        const job = jobFactory.createObject(root, {
            token: generation,
            kind: kind,
            timeoutMs: timeoutMs,
            command: args,
            callback: root.jobFinished
        }) as WallpaperJob;
        activeJob = job;
        started++;
        job.start();
    }

    // A newer request: the running job is told to stop and its answer will be ignored (the token no longer matches).
    function supersede(): void {
        generation++;
        if (activeJob && activeJob.running) {
            cancelled++;
            activeJob.stop(15);
        }
        activeJob = null;
    }

    // ---- states ----
    function publish(): void {
        WallpaperState.report(screenInfo.name, {
            state: status,
            reason: reason,
            source: cfg.source,
            path: cfg.path,
            name: label,
            files: files.length,
            file: status === "ready" || (status === "error" && currentFile !== "") ? currentFile : ""
        });
    }

    function showNone(state: string): void {
        status = state;
        reason = "";
        imageUrl = "";
        currentFile = "";
        strip = null;
        label = "";
        files = [];
        identity = "";
        currentSrc = "";
        publish();
    }

    function fail(why: string): void {
        status = "error";
        reason = why;
        publish();
    }

    // ---- the request ----
    function apply(): void {
        supersede();
        advanceRequested = false;
        const c = cfg;
        if (c.source === "builtin" || c.source === "video") {
            // Video wallpapers are not played yet: the artwork shows (ADR-0016 W7).
            showNone("builtin");
            if (c.source === "video")
                fail("video-unavailable");
            return;
        }
        if (c.source === "color") {
            showNone("color");
            return;
        }
        const why = WallpaperConfig.sourceProblem(c.path, WallpaperState.dev, WallpaperState.repoRoot);
        if (why !== "") {
            fail(why === "outside-dev" ? "outside-dev" : "invalid-path");
            return;
        }
        if (WallpaperState.toolMissing) {
            fail("helper-missing");
            return;
        }
        if (c.source === "file") {
            files = [];
            label = fileName(c.path);
            startPrepare(c.path);
        } else {
            startList();
        }
    }

    function fileName(path: string): string {
        return path.substring(path.lastIndexOf("/") + 1);
    }

    function startPrepare(path: string): void {
        currentSrc = path;
        status = imageUrl === "" ? "preparing" : status;
        reason = "";
        publish();
        startJob("prepare", WallpaperConfig.prepareArgs(WallpaperState.tool, path, pixelWidth, pixelHeight, cfg.fit, cfg.color, WallpaperState.preparedDir, Tokens.menubarHeight * scale, Tokens.wallpaperCacheMaxBytes), Tokens.wallpaperToolTimeoutMs);
    }

    function startList(): void {
        startJob("list", WallpaperConfig.listArgs(WallpaperState.tool, cfg.path, Tokens.wallpaperMaxListEntries), Tokens.wallpaperListTimeoutMs);
    }

    // The interval elapsed: list again (the folder may have changed) and show the next picture.
    function requestAdvance(): void {
        if (activeJob && activeJob.running)
            return;
        advanceRequested = true;
        generation++;
        startList();
    }

    function jobFinished(token: int, kind: string, code: int, out: string, timedOut: bool): void {
        if (token !== generation)
            return;
        activeJob = null;
        let o = null;
        try {
            o = JSON.parse(out);
        } catch (e) {
            o = null;
        }
        if (kind === "list")
            listed(o, code, timedOut);
        else
            prepared(o, code, timedOut);
    }

    function failureId(o: var, code: int, timedOut: bool): string {
        if (timedOut)
            return "timeout";
        if (o && typeof o.code === "number")
            return WallpaperConfig.reasonOf(o.code);
        // No answer: the helper could not run at all (missing, not executable) or crashed.
        return code === 127 || code === -1 || code === -2 ? "helper-missing" : "failed";
    }

    function listed(o: var, code: int, timedOut: bool): void {
        if (!o || o.ok !== true) {
            const id = failureId(o, code, timedOut);
            // A folder that cannot be read keeps the current picture and is tried again at the next change.
            fail(id === "not-found" || id === "not-regular" || id === "unreadable" || id === "timeout" ? "folder-unavailable" : id);
            return;
        }
        files = o.files;
        if (files.length === 0) {
            fail("folder-empty");
            return;
        }
        pick();
    }

    // Chooses the picture: the one kept in the state while its interval has not elapsed, else the next of the carousel.
    function pick(): void {
        const key = displayKey;
        const folder = cfg.path;
        let state = WallpaperState.carousel(key);
        const sameFolder = state !== null && state.folder === folder;
        if (!sameFolder)
            state = {seed: Math.floor(Math.random() * 2147483647), index: 0, last: "", avoid: "", folder: folder, changedAt: 0};
        const sameSession = identity === folder && currentSrc !== "" && files.indexOf(currentSrc) >= 0;
        const interval = WallpaperConfig.intervalMs(cfg.interval);
        let keep = "";
        if (!advanceRequested) {
            if (sameSession) {
                keep = currentSrc;
            } else if (sameFolder && typeof state.last === "string" && files.indexOf(state.last) >= 0 && !bad[state.last] && interval > 0 && Date.now() - (state.changedAt || 0) < interval) {
                keep = state.last;
            }
        }
        advanceRequested = false;
        identity = folder;
        if (keep !== "") {
            startPrepare(keep);
            return;
        }
        advanceFrom(state);
    }

    function advanceFrom(state: var): void {
        const r = WallpaperConfig.advance(files, cfg.shuffle, state, bad);
        if (r.file === "") {
            fail("all-failed");
            return;
        }
        const next = r.state;
        next.folder = cfg.path;
        next.changedAt = Date.now();
        WallpaperState.setCarousel(displayKey, next);
        label = fileName(r.file);
        startPrepare(r.file);
    }

    function prepared(o: var, code: int, timedOut: bool): void {
        if (o && o.ok === true && typeof o.file === "string") {
            // Dev guard on the resolved path too: a symlink under .dev must not lead out of it.
            const why = typeof o.real === "string" ? WallpaperConfig.sourceProblem(o.real, WallpaperState.dev, WallpaperState.repoRoot) : "";
            if (why === "" && WallpaperConfig.isUnder(o.file, WallpaperState.preparedDir)) {
                currentFile = o.file;
                strip = o.strip || null;
                imageUrl = "file://" + o.file;
                status = "ready";
                reason = "";
                publish();
                return;
            }
            fail("outside-dev");
            return;
        }
        const id = failureId(o, code, timedOut);
        if (cfg.source === "folder" && files.length > 0 && id !== "helper-missing" && id !== "timeout") {
            // One bad file in a folder: journal only, then the next picture.
            console.warn("wallpaper: skipping " + currentSrc + " (" + id + ")");
            const b = Object.assign({}, bad);
            b[currentSrc] = true;
            bad = b;
            advanceFrom(WallpaperState.carousel(displayKey) || {seed: 1, index: 0, last: "", avoid: ""});
            return;
        }
        fail(id);
    }
}
