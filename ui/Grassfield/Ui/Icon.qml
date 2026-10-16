import QtQuick
import QtQuick.Effects

// Themed symbolic icon: the branding SVGs are monochrome black and are recolored at runtime.
Item {
    id: root

    // File name without extension in branding/icons/symbolic, e.g. "wifi-3".
    property string name: ""
    property color color: Appearance.colors.text
    property int size: Tokens.menubarIconSize
    // Overridable so that an installed layout can point at its own icon directory.
    property url directory: Qt.resolvedUrl("../../../branding/icons/symbolic/")

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
    }
}
