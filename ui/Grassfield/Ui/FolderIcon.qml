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
    readonly property bool hasGlyph: root.folderGlyph !== ""
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

    // The symbol is drawn over the effect: emoji keep their colours.
    Text {
        objectName: "glyph"
        visible: root.hasGlyph
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height * Tokens.folderIconGlyphCenterY - height / 2
        width: root.width
        horizontalAlignment: Text.AlignHCenter
        text: root.folderGlyph
        textFormat: Text.PlainText
        color: Tokens.folderIconGlyphColor
        font.pixelSize: Math.max(1, Math.round(root.size * Tokens.folderIconGlyphScale))
    }
}
