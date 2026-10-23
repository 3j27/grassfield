pragma ComponentBehavior: Bound
import QtQuick

// Reads the shape of icon files ahead of time (IconShape, the own-tile rule of the icon appearance modes) so that a panel that
// shows many icons at once (Apps, Search) does not pay for it while it opens: the first opening of the Apps panel in an effect
// mode used to read about a hundred icon files on the GUI thread during the opening animation, and each icon then faded in when
// its read ended (audit PERF-01 / UX-13: Tinted 90 % of frames within 16 ms against 95 % in Default).
//
// One file at a time, `Tokens.iconModePrewarmGapMs` apart, only in an effect mode, only for a file nobody has read or claimed, and
// never before the host has a window (a Canvas needs one). The icon that appears later finds its answer in the cache
// (IconShape.sideOf), exactly as if it had measured the file itself; a file the prewarm did not reach is measured by the icon as
// before. Must sit in a window that stays mapped (the menu bar).
Item {
    id: root

    // Icon sources as the icons will ask for them (String(TintedIcon.source)), most wanted first.
    property var sources: []
    // An effect mode is on: Default draws no plate and reads nothing.
    readonly property bool wanted: IconModes.normalizeMode(Appearance.iconMode) !== "default" && !Appearance.iconShaderBroken
    // Files read so far in this list (diagnostics, tests).
    property int done: 0
    property int cursor: 0

    readonly property bool ready: root.wanted && root.sources.length > 0 && root.Window.window !== null

    width: 0
    height: 0
    visible: true
    Accessible.ignored: true

    onSourcesChanged: root.cursor = 0

    // The next file nobody has read or claimed; false when the list is done.
    function next(): bool {
        // The icons on screen have the places first; the prewarm waits (the cursor stays) rather than skipping a file.
        if (IconShape.busy >= Tokens.iconModeOwnTileConcurrency)
            return true;
        while (root.cursor < root.sources.length) {
            const key = String(root.sources[root.cursor++]);
            if (key === "" || IconShape.sideOf(key) !== undefined)
                continue;
            if (!IconShape.claim(key))
                continue;
            probe.key = key;
            probe.active = true;
            return true;
        }
        return false;
    }

    Timer {
        interval: Tokens.iconModePrewarmGapMs
        repeat: true
        running: root.ready && !probe.active && root.cursor < root.sources.length
        onTriggered: root.next()
    }

    Loader {
        id: probe

        property string key: ""

        function finish(side) {
            const k = probe.key;
            probe.key = "";
            probe.active = false;
            if (k !== "") {
                IconShape.store(k, side);
                root.done++;
            }
        }

        active: false

        sourceComponent: Canvas {
            id: canvas

            function read() {
                if (probe.key === "")
                    return;
                const n = Tokens.iconModeOwnTileProbeSize;
                const ctx = canvas.getContext("2d");
                ctx.clearRect(0, 0, n, n);
                ctx.drawImage(probe.key, 0, 0, n, n);
                const data = ctx.getImageData(0, 0, n, n);
                probe.finish(IconTile.measure(data.data, n, Tokens).side);
            }

            width: Tokens.iconModeOwnTileProbeSize
            height: Tokens.iconModeOwnTileProbeSize
            opacity: 0
            renderTarget: Canvas.Image
            renderStrategy: Canvas.Immediate
            onImageLoaded: canvas.read()
            onAvailableChanged: {
                if (canvas.available && probe.key !== "" && canvas.isImageLoaded(probe.key))
                    canvas.read();
            }
            Component.onCompleted: canvas.loadImage(probe.key)

            Timer {
                interval: Tokens.iconModeOwnTileTimeout
                running: true
                onTriggered: probe.finish(0)
            }
        }
    }
}
