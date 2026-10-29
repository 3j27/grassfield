pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import Grassfield.Ui
import qs.platform
import qs.services

// Desktop wallpaper: the Grassfield artwork, a colour, a picture or a video (WallpaperFeed decides which) on the background
// layer of every screen.
Scope {
    id: root

    // The session is locked (set from shell.qml, as Overview and the switcher get it): a video wallpaper pauses.
    property bool locked: false

    // Dev-only wallpaper override for tests/visual (contrast on worst-case wallpapers): with
    // GRASSFIELD_DEV=1, GRASSFIELD_WALLPAPER_FILE (initial, trusted: set by the dev scripts) or
    // `qs ipc call wallpaper set <path>` covers the artwork with that image; an empty path restores the artwork.
    // The IPC path must be absolute, end in .png/.jpg/.jpeg and name an existing regular file of at most
    // maxBytes (checked with stat before it is used; `wallpaper status` reports the outcome in plain text).
    // Inert outside dev: every call is refused. The accepted path is kept in VisualFixtures (wallpaperOverride; read
    // back as wallpaperFile, "" outside dev), which the lock screen backdrop draws too.
    // The shell's one dev gate (GRASSFIELD_DEV=1 and no GRASSFIELD_SESSION=1, SEC-03/SEC-04).
    readonly property bool dev: VisualFixtures.dev
    readonly property real maxBytes: 64 * 1024 * 1024
    property string pendingFile: ""
    property string outcome: "idle"
    // Dev hook `qs ipc call wallpaper loadDelay <ms>`: the decode of every new picture starts that late (0 = off).
    property int loadDelayMs: 0
    // Dev hooks `qs ipc call wallpaper videoIdle 1|0|real` and `videoBattery 1|0|real`: the pause policy's idle and battery
    // inputs are forced (a nested test cannot make the compositor idle or unplug a laptop). "" = the real input.
    property string devIdle: ""
    property string devBattery: ""
    // Dev hook `qs ipc call wallpaper fadeLength <ms>`: the crossfade lasts that long (0 = the token), so that a capture lands in it.
    property int fadeLengthMs: 0

    // "" when the path is acceptable for a stat check, else the reason it is refused.
    function pathProblem(path: string): string {
        if (path.charAt(0) !== "/")
            return "path must be absolute";
        if (/[\u0000-\u001f]/.test(path))
            return "path contains control characters";
        if (!/\.(png|jpe?g)$/i.test(path))
            return "only .png, .jpg and .jpeg files are accepted";
        return "";
    }

    // stat output "<file type>|<size>": a regular file under the size cap, or the reason it is refused.
    function statProblem(out: string): string {
        const m = out.trim().match(/^(.*)\|(\d+)$/);
        if (!m)
            return "file not found";
        if (m[1] !== "regular file" && m[1] !== "regular empty file")
            return "not a regular file";
        if (parseInt(m[2]) > maxBytes)
            return "file larger than " + (maxBytes / (1024 * 1024)) + " MB";
        return "";
    }

    Process {
        id: stat
        stdout: StdioCollector {
            onStreamFinished: {
                const why = root.statProblem(text);
                if (why !== "") {
                    root.outcome = "refused: " + why;
                } else {
                    VisualFixtures.wallpaperOverride = root.pendingFile;
                    root.outcome = "applied";
                }
            }
        }
    }

    IpcHandler {
        target: "wallpaper"

        // Dev only: start the decode of every new picture this many ms late (0 = off).
        function loadDelay(ms: int): string {
            if (!root.dev)
                return "refused";
            root.loadDelayMs = Math.max(0, Math.min(5000, ms));
            return "ok";
        }

        // Dev only: the crossfade lasts this many ms (0 = the token).
        function fadeLength(ms: int): string {
            if (!root.dev)
                return "refused";
            root.fadeLengthMs = Math.max(0, Math.min(60000, ms));
            return "ok";
        }

        // Dev only: force the idle input of the video pause policy ("1", "0", or "real").
        function videoIdle(value: string): string {
            if (!root.dev)
                return "refused";
            root.devIdle = value === "1" || value === "0" ? value : "";
            return "ok";
        }

        // Dev only: force the battery input of the video pause policy ("1", "0", or "real").
        function videoBattery(value: string): string {
            if (!root.dev)
                return "refused";
            root.devBattery = value === "1" || value === "0" ? value : "";
            return "ok";
        }

        // Dev only: one line of JSON about the video of an output: the policy and why, whether a frame is decoding, whether the
        // player shows a frame, the video on screen.
        function videoStatus(output: string): string {
            if (!root.dev)
                return "refused";
            for (const w of variants.instances) {
                if (w.modelData && w.modelData.name === output) {
                    const inputs = WallpaperConfig.playbackInputs(root.locked, w.fullscreen, w.idle, w.onBattery, w.effective, Settings.reduceMotion, Settings.materialProfile);
                    return JSON.stringify({policy: w.videoPolicy, reason: WallpaperConfig.playbackState(inputs).reason, playing: w.shown.videoPlaying, shown: w.shown.videoShown, video: w.shown.video, locked: root.locked, fullscreen: w.fullscreen, idle: w.idle, onBattery: w.onBattery});
                }
            }
            return "unknown output";
        }

        // Dev only: where the crossfade of an output is, as the incoming slot's opacity (0 to 1; 0 also while a picture
        // still loads), or -1 when nothing is incoming. Lets a capture test know where its capture sits in the fade.
        function progress(output: string): string {
            if (!root.dev)
                return "refused";
            for (const w of variants.instances) {
                if (w.modelData && w.modelData.name === output)
                    return String(w.incoming !== null ? w.incoming.opacity : -1);
            }
            return "unknown output";
        }

        // Dev only, with the loopback test server (GRASSFIELD_ONLINE_BASE_URL): the online scheduler's clock runs this many hours ahead.
        function onlineClock(hours: int): string {
            return root.dev ? WallpaperOnline.devClock(hours) : "refused";
        }

        // Dev only: the online scheduler's state as JSON.
        function onlineStatus(): string {
            return root.dev ? WallpaperOnline.devStatus() : "refused";
        }

        function set(path: string): string {
            if (!root.dev)
                return "refused";
            if (path === "") {
                VisualFixtures.wallpaperOverride = "";
                root.outcome = "idle";
                return "ok";
            }
            const why = root.pathProblem(path);
            if (why !== "") {
                root.outcome = "refused: " + why;
                return root.outcome;
            }
            root.pendingFile = path;
            root.outcome = "validating";
            stat.command = ["stat", "-L", "-c", "%F|%s", "--", path];
            stat.running = false;
            stat.running = true;
            return "validating";
        }

        // idle | validating | applied | refused: <reason>
        function status(): string {
            return root.dev ? root.outcome : "refused";
        }
    }

    Variants {
        id: variants
        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            screen: modelData
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            focusable: false
            color: slotA.art.skyTop
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "grassfield-wallpaper"

            HoverHandler {
                onPointChanged: if (hovered)
                    PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
            }

            // The strip under this output's menu bar decides the bar's foreground (BarTone, per output): reported when a
            // wallpaper becomes dominant (reportTone: the artwork's known gradient, a colour's luminance, a picture's strip
            // statistics from the helper), never per frame. The dev image override (VisualFixtures.wallpaperFile) is grabbed
            // into a small canvas and averaged instead. Nothing is shown of the canvas (it sits under the wallpaper).
            readonly property string imageFile: VisualFixtures.wallpaperFile
            readonly property string imageUrl: imageFile !== "" ? "file://" + imageFile : ""
            function measure(): void {
                if (imageFile !== "") {
                    if (probe.isImageLoaded(imageUrl))
                        probe.requestPaint();
                    else
                        probe.loadImage(imageUrl);
                    return;
                }
                // The override is gone (or never was): the bar follows what is on screen.
                reportTone(toneDesc());
            }
            onImageFileChanged: Qt.callLater(measure)
            onHeightChanged: Qt.callLater(measure)
            Component.onCompleted: Qt.callLater(measure)

            // The whole image is drawn stretched onto a canvas scaled so that the bar's strip is toneSampleRows px tall; only
            // that top strip is read back.
            Canvas {
                id: probe
                z: -1
                width: Tokens.menubarToneSampleColumns
                height: Math.max(Tokens.menubarToneSampleRows, Math.round(win.height * Tokens.menubarToneSampleRows / Tokens.menubarHeight))
                renderTarget: Canvas.Image
                renderStrategy: Canvas.Immediate
                onImageLoaded: requestPaint()
                onPaint: {
                    const url = win.imageUrl;
                    if (url === "" || !isImageLoaded(url))
                        return;
                    const ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.drawImage(url, 0, 0, width, height);
                    const lum = BarTone.pixelsLuminance(ctx.getImageData(0, 0, width, Tokens.menubarToneSampleRows).data);
                    unloadImage(url);
                    // Not inside the paint: the bar's bindings must change outside the render sync.
                    Qt.callLater(() => BarTone.report(win.modelData.name, lum));
                }
            }

            // The luminance grid of what this output shows (ADR-0024 G-3 per surface: the backdrop under each glass surface,
            // GlassTint.gridRange): the shown slot is grabbed small and read back cell by cell when a wallpaper becomes dominant,
            // never per frame. None for a colour (its one luminance is exact), a video or the dev image override.
            property var gridGrab: null
            function measureGrid(desc: var): void {
                if (!win.modelData)
                    return;
                if (!desc || desc.kind === "color" || (desc.video !== undefined && desc.video !== "") || VisualFixtures.wallpaperFile !== "" || !win.shown || win.width <= 0) {
                    Backdrop.reportGrid(win.modelData.name, null);
                    return;
                }
                win.shown.grabToImage(result => {
                    win.gridGrab = result;
                    if (gridProbe.isImageLoaded(result.url))
                        gridProbe.requestPaint();
                    else
                        gridProbe.loadImage(result.url);
                }, Qt.size(gridProbe.width, gridProbe.height));
            }

            Canvas {
                id: gridProbe
                z: -1
                width: Tokens.glassGridColumns * Tokens.glassGridSample
                height: Tokens.glassGridRows * Tokens.glassGridSample
                renderTarget: Canvas.Image
                renderStrategy: Canvas.Immediate
                onImageLoaded: requestPaint()
                onPaint: {
                    const grab = win.gridGrab;
                    if (!grab || !isImageLoaded(grab.url))
                        return;
                    const ctx = getContext("2d");
                    ctx.clearRect(0, 0, width, height);
                    ctx.drawImage(grab.url, 0, 0, width, height);
                    const grid = GlassTint.gridOf(ctx.getImageData(0, 0, width, height).data, width, height, Tokens.glassGridColumns, Tokens.glassGridRows, win.width, win.height);
                    unloadImage(grab.url);
                    win.gridGrab = null;
                    // Not inside the paint: the glass bindings must change outside the render sync.
                    Qt.callLater(() => Backdrop.reportGrid(win.modelData.name, grid));
                }
            }

            // What the output is to show (the artwork, a colour, a prepared picture), decided from the settings.
            WallpaperFeed {
                id: feed
                screenInfo: win.modelData
                onDisplayChanged: win.show(feed.display)
            }

            // ---- ONE two-slot model for every kind of wallpaper (the artwork, a colour, a picture) ----
            // `shown` is the slot on screen, `incoming` the one being prepared. Rules, the same for every kind:
            //   - the incoming slot is on top (z 2), the shown one below (z 1) and fully visible until the fade completes;
            //   - the incoming slot becomes visible only when it is ready: the artwork and a colour at once, a picture once
            //     its Image is Ready (decoded off the GUI thread); a request replaces a pending one in the same slot;
            //   - it crossfades over the outgoing slot (one fixed length; a plain switch with Reduce Motion);
            //   - a failure (a picture that cannot be decoded, a file the helper refused) keeps whatever is on screen;
            //   - nothing else sets the opacity of a layer from the REQUESTED state: only the fade does.
            property WallpaperSlot shown: slotA
            property WallpaperSlot incoming: null
            property var shownDesc: ({kind: "art", color: "", url: "", strip: null, video: ""})

            // ---- the pause policy of a video wallpaper (ADR-0016 section 5), re-evaluated by every event ----
            // Nothing polls: the lock state, the compositor's full-screen state of this output, the idle monitor, UPower and the
            // settings each notify. The idle monitor only exists while a video is wanted, and it is NOT an inhibitor (a
            // wallpaper never creates one, so the idle lock still fires while a video plays); it ignores inhibitors because it
            // asks whether the user is away, not whether the session may sleep.
            readonly property bool videoWanted: shownDesc.video !== undefined && shownDesc.video !== ""
            readonly property bool fullscreen: win.modelData ? Compositor.fullscreenOn(win.modelData.name, Compositor.topologyRevision) : false
            readonly property var effective: feed.cfg
            readonly property bool idle: root.devIdle !== "" ? root.devIdle === "1" : idleMonitor.isIdle
            readonly property bool onBattery: root.devBattery !== "" ? root.devBattery === "1" : UPower.onBattery
            readonly property string videoPolicy: WallpaperConfig.playbackState(WallpaperConfig.playbackInputs(root.locked, fullscreen, idle, onBattery, feed.cfg, Settings.reduceMotion, Settings.materialProfile)).state

            IdleMonitor {
                id: idleMonitor
                enabled: win.videoWanted
                timeout: Tokens.wallpaperVideoIdleSeconds
                respectInhibitors: false
            }
            property var pendingDesc: null
            property bool fadePending: false

            WallpaperSlot {
                id: slotA
                z: 1
                opacity: 1
                pictureSize: Qt.size(feed.pixelWidth, feed.pixelHeight)
                onScreen: win.shown === slotA
                playPolicy: win.videoPolicy
                markerOwner: feed.outputName
                onPictureLoaded: win.slotLoaded(slotA)
                onPictureFailed: win.slotFailed(slotA)
                onVideoFailed: message => console.warn("wallpaper: " + feed.outputName + ": the video stopped: " + message)
            }

            WallpaperSlot {
                id: slotB
                z: 1
                pictureSize: Qt.size(feed.pixelWidth, feed.pixelHeight)
                onScreen: win.shown === slotB
                playPolicy: win.videoPolicy
                markerOwner: feed.outputName
                onPictureLoaded: win.slotLoaded(slotB)
                onPictureFailed: win.slotFailed(slotB)
                onVideoFailed: message => console.warn("wallpaper: " + feed.outputName + ": the video stopped: " + message)
            }

            function sameContent(a: var, b: var): bool {
                return a.kind === b.kind && (a.kind !== "color" || a.color === b.color) && (a.kind !== "picture" || (a.url === b.url && (a.video || "") === (b.video || "")));
            }

            function show(desc: var): void {
                // A fade in flight is complete at once: its content is ready (a fade only starts then).
                if (fadeIn.running)
                    finishFade();
                if (sameContent(desc, shownDesc)) {
                    cancelPending();
                    return;
                }
                if (incoming === null) {
                    incoming = shown === slotA ? slotB : slotA;
                    shown.z = 1;
                    incoming.z = 2;
                    incoming.opacity = 0;
                }
                // A newer request replaces the pending one in the same slot; what is on screen is not touched.
                pendingDesc = desc;
                fadePending = true;
                incoming.kind = desc.kind;
                if (desc.kind === "color")
                    incoming.color = desc.color;
                // A video wallpaper: the slot plays it once it is on screen (its poster is the picture that fades in).
                incoming.video = desc.video || "";
                incoming.videoFit = desc.fit || "fill";
                incoming.posterMs = desc.posterMs || 0;
                incoming.videoPath = desc.path || "";
                if (desc.kind === "picture") {
                    // Dev hook `wallpaper loadDelay <ms>`: the decode is started late, to test changes that arrive faster.
                    if (root.loadDelayMs > 0) {
                        console.info("wallpaper: decode of the next picture delayed by " + root.loadDelayMs + " ms (dev hook)");
                        loadTimer.restart();
                    } else {
                        startLoad();
                    }
                } else {
                    loadTimer.stop();
                    incoming.url = "";
                    beginFade();
                }
            }

            function startLoad(): void {
                if (incoming === null || pendingDesc === null || pendingDesc.kind !== "picture")
                    return;
                incoming.url = pendingDesc.url;
                if (incoming.pictureReady)
                    beginFade();
            }

            Timer {
                id: loadTimer
                interval: root.loadDelayMs
                onTriggered: win.startLoad()
            }

            // The pending request goes away (the screen already shows what is wanted): what is on screen stays as it is.
            function cancelPending(): void {
                loadTimer.stop();
                fadePending = false;
                pendingDesc = null;
                toneDone = false;
                if (incoming !== null) {
                    incoming.url = "";
                    incoming.video = "";
                    incoming.opacity = 0;
                    incoming = null;
                }
            }

            function slotLoaded(slot: WallpaperSlot): void {
                // Only the picture that is wanted NOW may start a fade: a decode that a newer request superseded (its slot
                // still holds the old url, or the dev hook has not started the new decode yet) never does.
                // (The signal itself says the Image is Ready for a non-empty url; the slot's own `pictureReady` binding may not
                // have been re-evaluated yet when the handler runs, so it is not read here.)
                if (slot === incoming && fadePending && pendingDesc !== null && pendingDesc.kind === "picture" && slot.url === pendingDesc.url)
                    beginFade();
            }

            function slotFailed(slot: WallpaperSlot): void {
                if (slot !== incoming || !fadePending)
                    return;
                // The previous wallpaper stays.
                console.warn("wallpaper: cannot load " + slot.url);
                cancelPending();
            }

            // The incoming slot is ready. One fixed crossfade (macOS: a crossfade of fixed length); Reduce Motion: a plain
            // switch. P3 for the fade is measured on real hardware with real frame timing (owner L2, docs/specs/desktop.md).
            function beginFade(): void {
                fadePending = false;
                // (The dev hook `wallpaper fadeLength <ms>` lengthens the fade so that a capture lands inside it.)
                const ms = Settings.reduceMotion ? 0 : (root.fadeLengthMs > 0 ? root.fadeLengthMs : Tokens.wallpaperCrossfadeMs);
                if (ms === 0) {
                    incoming.opacity = 1;
                    completeFade();
                    return;
                }
                // The bar's tone follows the new wallpaper once it dominates: from the fade's own progress (the incoming
                // slot's opacity reaching 60 %), not from a timer (a fade is frame-driven, a timer is not).
                toneDone = false;
                fadeIn.duration = ms;
                fadeIn.target = incoming;
                fadeIn.restart();
            }

            // A fade in flight is completed at once when the next change arrives.
            function finishFade(): void {
                fadeIn.stop();
                if (incoming !== null) {
                    incoming.opacity = 1;
                    completeFade();
                }
            }

            function completeFade(): void {
                const old = shown;
                shown = incoming;
                shownDesc = pendingDesc;
                incoming = null;
                pendingDesc = null;
                // The next pending picture has not dominated anything yet (toneDesc must not report it while it loads).
                toneDone = false;
                if (old !== shown) {
                    old.opacity = 0;
                    old.url = "";
                    old.video = "";
                }
                // The tone of the wallpaper that is on screen now.
                reportTone(shownDesc);
            }

            function reportTone(desc: var): void {
                if (!win.modelData)
                    return;
                // The backdrop of the adaptive glass (ADR-0024 G-3): the luminance range of what is on screen, when known.
                Backdrop.reportWallpaper(win.modelData.name, VisualFixtures.wallpaperFile !== "" ? null : Backdrop.rangeOf(desc, slotA.art));
                win.measureGrid(desc);
                if (VisualFixtures.wallpaperFile !== "")
                    return;
                // The tone comes from the pixels of what is on screen: a picture's or a video's own strip (the helper measured the
                // video's poster and sampled frames), never the artwork's gradient.
                const source = BarTone.toneSource(desc);
                if (source === "strip")
                    BarTone.reportStrip(win.modelData.name, desc.strip);
                else if (source === "color")
                    BarTone.reportColor(win.modelData.name, Qt.color(desc.color));
                else if (source === "none")
                    BarTone.reportUnmeasured(win.modelData.name);
                else if (height > 0)
                    BarTone.reportGradient(win.modelData.name, Qt.color(slotA.art.skyTop), Qt.color(slotA.art.skyMid), Tokens.menubarHeight / (0.55 * height));
            }

            NumberAnimation {
                id: fadeIn
                property: "opacity"
                from: 0
                to: 1
                onFinished: win.completeFade()
            }

            // The bar's tone switches when the incoming wallpaper dominates: 60 % of the crossfade's own progress.
            property bool toneDone: false
            Connections {
                target: win.incoming
                ignoreUnknownSignals: true

                function onOpacityChanged(): void {
                    if (!win.toneDone && win.incoming !== null && fadeIn.running && win.incoming.opacity >= 0.6 && win.pendingDesc !== null) {
                        win.toneDone = true;
                        win.reportTone(win.pendingDesc);
                    }
                }
            }

            // The wallpaper whose tone the bar should show: the incoming one once it dominates its fade, else the shown one.
            function toneDesc(): var {
                return incoming !== null && toneDone && pendingDesc !== null ? pendingDesc : shownDesc;
            }

            Image {
                anchors.fill: parent
                // On top of the two slots (z 1 and 2): the contrast run covers whatever the wallpaper shows.
                z: 10
                visible: VisualFixtures.wallpaperFile !== ""
                source: VisualFixtures.wallpaperFile !== "" ? "file://" + VisualFixtures.wallpaperFile : ""
                fillMode: Image.Stretch
                sourceSize: Qt.size(win.width, win.height)
                cache: false
                smooth: false
            }
        }
    }
}
