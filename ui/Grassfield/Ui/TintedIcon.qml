pragma ComponentBehavior: Bound
import QtQuick

// An application or file icon drawn in the user's icon appearance mode (ADR-0014): default (as is), dark, clear or
// tinted. Never used for symbolic UI glyphs (those are `Icon`). In `default` mode no effect item exists at all: the
// image is drawn directly (no offscreen pass, no cost). Other modes add one MultiEffect over the image texture.
Item {
    id: root

    // Image URL: a theme icon path, image://icon/<name> or a file URL.
    property url source: ""
    property int size: Tokens.dockIconSize
    // Overridable per use (previews); the settings value otherwise.
    property string mode: Appearance.iconMode
    property color tint: Appearance.iconTint
    property alias status: image.status
    property alias asynchronous: image.asynchronous
    property alias paintedWidth: image.paintedWidth
    property alias paintedHeight: image.paintedHeight
    // Nominal edge: the image is decoded once at size x oversample, so a surface that scales the item (Dock
    // magnification) does not reload it. Decoded pixels per nominal pixel: hi-dpi and magnified tiles.
    property real oversample: 2

    readonly property bool modeActive: IconModes.normalizeMode(root.mode) !== "default"

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    // Default mode: the image fills the item. Effect modes: the image keeps a fixed size (the decoded size) and only
    // provides the texture, so the effect's texture never changes size while a surface scales the item (Dock
    // magnification); the effect quad is scaled by the GPU.
    Image {
        id: image
        width: root.modeActive ? root.size * root.oversample : root.width
        height: root.modeActive ? root.size * root.oversample : root.height
        source: root.source
        sourceSize: Qt.size(root.size * root.oversample, root.size * root.oversample)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        // Hidden while the effect draws it: the image only provides the texture.
        visible: !root.modeActive
    }

    Loader {
        anchors.fill: parent
        active: root.modeActive
        sourceComponent: IconEffect {
            source: image
            mode: root.mode
            tint: root.tint
        }
    }
}
