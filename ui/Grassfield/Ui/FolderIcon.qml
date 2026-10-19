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
    // The engraved shade of the folder colour (opaque).
    readonly property color glyphColor: FolderStyle.glyphShade(root.recolored, root.folderTint, root.mode, Tokens)
    // Its own hex colour, else the global colour (which is the accent for "accent").
    readonly property color folderTint: FolderStyle.colorOf(root.setting, Appearance.colors.accent)

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

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

    // The symbol is drawn over the effect, clipped to the icon (a hostile value cannot draw outside it). Emoji keep their
    // own colours and are opaque (their colour glyphs ignore `color`; a text-presentation fallback uses the shade); a
    // plain symbol is an engraved shade of the folder's colour (A2: >= 3:1 against the plate) with a light edge under it.
    Item {
        id: glyphBox
        objectName: "glyphBox"
        anchors.fill: parent
        clip: true
        visible: root.hasGlyph

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
