import QtQuick
import QtQuick.Effects

// Themed symbolic icon: the branding SVGs are monochrome black and are recolored at runtime.
Item {
    id: root

    // File name without extension in branding/icons/symbolic, e.g. "wifi-3".
    property string name: ""
    property color color: Appearance.colors.text
    // The heavier variant (icons-bar/, stroke 2.4 against 1.75): the menu bar's status glyphs, which macOS draws solid.
    property bool heavy: false
    property int size: Tokens.menubarIconSize
    // Overridable so that an installed layout can point at its own icon directory.
    // `icons` is a symlink to branding/icons/symbolic in the repo and a real directory once installed.
    property url directory: Qt.resolvedUrl(root.heavy ? "icons-bar/" : "icons/")

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    Image {
        id: glyph
        anchors.fill: parent
        source: root.name !== "" ? root.directory + root.name + ".svg" : ""
        sourceSize: Qt.size(root.size * 2, root.size * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        visible: false
    }

    MultiEffect {
        anchors.fill: parent
        source: glyph
        autoPaddingEnabled: false
        // Black source: lift to white first, then tint with the token color (alpha is kept).
        brightness: 1.0
        colorization: 1.0
        colorizationColor: root.color
        // Dev-only glyph mask (Appearance.devGlyphMode, tests/visual): a hidden marker colour hides the icon (a
        // fully transparent colorization would otherwise leave the lifted white glyph). Never true in production.
        opacity: Appearance.devGlyphMode === "hidden" && Appearance.isGlyphMarker(root.color) ? 0 : 1
    }
}
