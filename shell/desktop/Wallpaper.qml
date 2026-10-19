pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Grassfield.Ui
import qs.services

// Desktop wallpaper: the Grassfield artwork (WallpaperArt) on the background layer of every screen.
Scope {
    id: root

    // Dev-only wallpaper override for tests/visual (contrast on worst-case wallpapers): with
    // GRASSFIELD_DEV=1, GRASSFIELD_WALLPAPER_FILE (initial, trusted: set by the dev scripts) or
    // `qs ipc call wallpaper set <path>` covers the artwork with that image; an empty path restores the artwork.
    // The IPC path must be absolute, end in .png/.jpg/.jpeg and name an existing regular file of at most
    // maxBytes (checked with stat before it is used; `wallpaper status` reports the outcome in plain text).
    // Inert outside dev: every call is refused. The accepted path is kept in VisualFixtures (wallpaperOverride; read
    // back as wallpaperFile, "" outside dev), which the lock screen backdrop draws too.
    readonly property bool dev: Quickshell.env("GRASSFIELD_DEV") === "1"
    readonly property real maxBytes: 64 * 1024 * 1024
    property string pendingFile: ""
    property string outcome: "idle"

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
            color: artwork.art.skyTop
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "grassfield-wallpaper"

            HoverHandler {
                onPointChanged: if (hovered)
                    PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
            }

            // The strip under this output's menu bar decides the bar's foreground (BarTone, per output): measured when the
            // wallpaper or the output changes, never per frame. The artwork's top is a known gradient (sky), an image is
            // grabbed into a small canvas and averaged. Nothing is shown of the canvas (it sits under the wallpaper).
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
                if (height > 0) {
                    // The Dock shelf sits over the foreground hills of the artwork.
                    BarTone.reportDock(win.modelData.name, BarTone.colorLuminance(Qt.color(artwork.art.hillFront)));
                    BarTone.reportGradient(win.modelData.name, Qt.color(artwork.art.skyTop), Qt.color(artwork.art.skyMid), Tokens.menubarHeight / (0.55 * height));
                }
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
                    // The strip under the Dock shelf: the bottom rows, the central part of the width.
                    const dockPx = Tokens.dockIconSize + 2 * Tokens.dockPadding + Tokens.dockIndicatorSize + Tokens.dockSpacing + Tokens.dockBottomMargin;
                    const dockRows = Math.max(1, Math.min(height, Math.round(dockPx * height / win.height)));
                    const dockLum = BarTone.dockLuminance(ctx.getImageData(0, height - dockRows, width, dockRows).data, width, 0, dockRows, Tokens.dockIndicatorSampleSpan);
                    unloadImage(url);
                    // Not inside the paint: the bar's bindings must change outside the render sync.
                    Qt.callLater(() => {
                        BarTone.report(win.modelData.name, lum);
                        BarTone.reportDock(win.modelData.name, dockLum);
                    });
                }
            }

            WallpaperArt {
                id: artwork
                anchors.fill: parent
            }

            Image {
                anchors.fill: parent
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
