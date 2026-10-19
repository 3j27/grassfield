pragma ComponentBehavior: Bound
import QtQuick

// A folder icon: a TintedIcon (icon appearance mode, unchanged) recoloured with the folder colour, plus an optional
// symbol or emoji on the body of the folder (macOS 26, Customize Folder). The folder colour is the folder's own
// (`folderColor`, "" = none) else the global `icons.folderColor`; "theme" keeps the theme's colour and then no layer or
// effect exists (no extra cost, no change for folders without a colour). The colour step runs after the mode step.
Item {
    id: root

    property url source: ""
    property int size: Tokens.dockIconSize
    property real oversample: 2
    // The folder's own colour setting ("theme", "accent", "#rrggbb"; "" = follow the global setting) and its symbol.
    property string folderColor: ""
    property string folderGlyph: ""
    // Overridable for previews; the global setting otherwise.
    property string globalColor: Appearance.folderColorSetting
    property color globalTint: Appearance.folderTint
    property alias status: icon.status
    property alias asynchronous: icon.asynchronous
    property alias mode: icon.mode
    property alias tint: icon.tint

    readonly property string setting: FolderStyle.effectiveColor(root.folderColor, root.globalColor)
    readonly property bool recolored: FolderStyle.recolors(root.setting)
    // The symbol as kept by the shared rule (one grapheme cluster, no control or bidi characters).
    readonly property string glyph: FolderStyle.normalizeGlyph(root.folderGlyph)
    readonly property bool hasGlyph: root.glyph !== ""
    readonly property bool glyphIsEmoji: FolderStyle.isEmoji(root.glyph)
    // The plate under the symbol, measured from this icon as drawn (FolderPlate: once per icon, size, mode and colour):
    // a plain symbol is shaded against it, and so is an emoji drawn without colour glyphs. undefined until measured, null
    // when it could not be (the estimate of FolderStyle serves).
    readonly property bool needsPlate: root.hasGlyph
    readonly property string plateKey: root.source + "|" + root.size + "|" + root.mode + "|" + (IconModes.normalizeMode(root.mode) === "tinted" ? String(root.tint) : "") + "|"
                                       + (root.recolored ? String(root.folderTint) : "theme")
    readonly property var plate: root.needsPlate ? FolderPlate.plateOf(root.plateKey) : undefined
    // No measure is possible (no icon): the symbol is drawn with the estimate instead of waiting.
    readonly property bool plateUnavailable: icon.status === Image.Null || icon.status === Image.Error
    // The engraved shade of the plate's colour (opaque).
    readonly property color glyphColor: FolderStyle.glyphShade(root.recolored, root.folderTint, root.mode, root.tint, Tokens, root.plate)
    // Its own hex colour, else the global colour (which is the accent for "accent").
    readonly property color folderTint: FolderStyle.colorOf(root.setting, Appearance.colors.accent)

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    // The icon alone (the symbol is not part of it): what the plate is measured on.
    Item {
        id: plateSource
        objectName: "plateSource"
        anchors.fill: parent

        TintedIcon {
            id: icon
            objectName: "icon"
            anchors.fill: parent
            source: root.source
            size: root.size
            oversample: root.oversample
            layer.enabled: root.recolored
            layer.smooth: true
            layer.effect: FolderEffect {
                tint: root.folderTint
            }
        }
    }

    // ---- Plate measure: one grab of the icon and one small pixel read per combination, by one icon at a time ----
    function measure() {
        if (!root.needsPlate || icon.status !== Image.Ready || root.width <= 0 || root.height <= 0 || !root.visible || probe.active)
            return;
        const key = root.plateKey;
        if (!FolderPlate.claim(key))
            return;
        probe.key = key;
        const ok = plateSource.grabToImage(result => {
            if (probe.key !== key) {
                FolderPlate.release(key);
                return;
            }
            probe.shot = result;
            probe.active = true;
        }, Qt.size(root.size, root.size));
        if (!ok) {
            probe.key = "";
            FolderPlate.store(key, null);
        }
    }

    function scheduleMeasure() {
        settle.restart();
    }

    // Changes arrive in bursts (key parts, status, window): look once after them.
    Timer {
        id: settle

        interval: 0
        onTriggered: root.measure()
    }

    onNeedsPlateChanged: root.scheduleMeasure()
    onPlateKeyChanged: root.scheduleMeasure()
    onVisibleChanged: root.scheduleMeasure()
    onWindowChanged: root.scheduleMeasure()
    Component.onCompleted: root.scheduleMeasure()
    Component.onDestruction: {
        if (probe.key !== "")
            FolderPlate.release(probe.key);
    }

    Connections {
        target: icon

        function onStatusChanged() {
            root.scheduleMeasure();
        }
    }

    // A claim released by another icon (it went away) or a plate stored: look again.
    Connections {
        target: FolderPlate

        function onRevisionChanged() {
            if (root.needsPlate && root.plate === undefined)
                root.scheduleMeasure();
        }
    }

    Loader {
        id: probe

        property string key: ""
        property var shot: null

        function finish(plate) {
            const k = probe.key;
            probe.key = "";
            probe.shot = null;
            probe.active = false;
            if (k !== "")
                FolderPlate.store(k, plate);
        }

        active: false

        sourceComponent: Canvas {
            id: canvas

            function read() {
                if (probe.shot === null)
                    return;
                const ctx = canvas.getContext("2d");
                ctx.clearRect(0, 0, canvas.width, canvas.height);
                ctx.drawImage(probe.shot.url, 0, 0);
                const data = ctx.getImageData(0, 0, Math.round(canvas.width), Math.round(canvas.height));
                const box = FolderStyle.glyphBox(root.size, Tokens);
                probe.finish(FolderStyle.plateFromPixels(data.data, data.width, data.height, box[0], box[1], box[2], box[3]));
            }

            width: root.size
            height: root.size
            opacity: 0
            renderTarget: Canvas.Image
            renderStrategy: Canvas.Immediate
            onImageLoaded: canvas.read()
            onAvailableChanged: {
                if (canvas.available && probe.shot !== null && canvas.isImageLoaded(probe.shot.url))
                    canvas.read();
            }
            Component.onCompleted: canvas.loadImage(probe.shot.url)

            Timer {
                interval: 3000
                running: true
                onTriggered: probe.finish(null)
            }
        }
    }

    // The symbol is drawn over the effect, clipped to the icon (a hostile value cannot draw outside it). Emoji keep their
    // own colours and are opaque (their colour glyphs ignore `color`; a text-presentation fallback uses the shade); a
    // plain symbol is an engraved shade of the plate's colour (A2: >= 3:1 against the measured plate) with a light edge
    // under it; it appears once the plate is known.
    Item {
        id: glyphBox

        objectName: "glyphBox"
        anchors.fill: parent
        clip: true
        visible: root.hasGlyph && (root.glyphIsEmoji || root.plate !== undefined || root.plateUnavailable)

        Text {
            objectName: "glyphHighlight"
            visible: !root.glyphIsEmoji
            x: glyphText.x
            y: glyphText.y + Math.max(1, Math.round(root.size * Tokens.folderIconGlyphHighlightOffset))
            width: glyphText.width
            horizontalAlignment: Text.AlignHCenter
            text: glyphText.text
            textFormat: Text.PlainText
            color: Tokens.folderIconGlyphHighlight
            font.pixelSize: glyphText.font.pixelSize
        }

        Text {
            id: glyphText

            objectName: "glyph"
            y: root.height * Tokens.folderIconGlyphCenterY - height / 2
            width: root.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            maximumLineCount: 1
            text: root.glyph
            textFormat: Text.PlainText
            color: root.glyphColor
            font.pixelSize: Math.max(1, Math.round(root.size * Tokens.folderIconGlyphScale))
        }
    }
}
