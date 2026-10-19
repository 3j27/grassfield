pragma ComponentBehavior: Bound
import QtQuick

// An application or file icon drawn in the user's icon appearance mode (ADR-0014): default (as is), dark, clear or
// tinted. Never used for symbolic UI glyphs (those are `Icon`). In `default` mode no effect item exists at all: the
// image is drawn directly (no offscreen pass, no cost). Other modes add one IconEffect (a fragment shader) over the image
// texture, only while the icon is visible.
Item {
    id: root

    // Image URL: a theme icon path, image://icon/<name> or a file URL.
    property url source: ""
    property int size: Tokens.dockIconSize
    // Overridable per use (previews); the settings value otherwise.
    property string mode: Appearance.iconMode
    property color tint: Appearance.iconTint
    // Clear and Tinted draw differently on a light and a dark material.
    property bool darkAppearance: Appearance.dark
    // Drawn over the bare wallpaper (desktop icons) rather than a window material.
    property bool overWallpaper: false
    property alias status: image.status
    property alias asynchronous: image.asynchronous
    property alias paintedWidth: image.paintedWidth
    property alias paintedHeight: image.paintedHeight
    // Nominal edge: the image is decoded once at size x oversample, so a surface that scales the item (Dock
    // magnification) does not reload it. Decoded pixels per nominal pixel: hi-dpi and magnified tiles.
    // Decoded pixels per nominal pixel; 2 unless a call site decodes more for a larger magnification.
    readonly property real defaultOversample: 2
    property real oversample: root.defaultOversample
    // The compiled icon shader; if it fails to load the icon is drawn as it is (the default look), see effectFailed.
    property url shaderUrl: Qt.resolvedUrl("shaders/icon.frag.qsb")

    readonly property bool modeActive: IconModes.normalizeMode(root.mode) !== "default"
    // The effect item of an effect mode while the icon is shown, else null/false (tests, diagnostics).
    readonly property Item effectItem: effectLoader.item as Item
    readonly property bool effectActive: effectLoader.active
    // True while the plain image is what is drawn (default mode, or an effect mode whose shader failed).
    readonly property bool plainVisible: image.visible
    // The image only provides the effect's texture (at its decoded size) while an effect draws; when the shader failed it is
    // the icon itself again, at the item's size.
    readonly property bool textureOnly: root.modeActive && !root.effectFailed
    // The shader could not be loaded or compiled: the plain image is shown instead of an effect that draws nothing.
    readonly property bool effectFailed: effectLoader.item !== null && (effectLoader.item as IconEffect).status === ShaderEffect.Error

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    // Default mode: the image fills the item. Effect modes: the image keeps a fixed size (the decoded size) and only
    // provides the texture, so the effect's texture never changes size while a surface scales the item (Dock
    // magnification); the effect quad is scaled by the GPU.
    Image {
        id: image
        width: root.textureOnly ? root.size * root.oversample : root.width
        height: root.textureOnly ? root.size * root.oversample : root.height
        source: root.source
        sourceSize: Qt.size(root.size * root.oversample, root.size * root.oversample)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        // Hidden while the effect draws it: the image only provides the texture.
        visible: !root.modeActive || root.effectFailed
    }

    // Effect modes: one shader effect per icon that is shown. `root.visible` is the effective visibility, so an icon
    // hidden by its own `visible: false` or by a hidden ancestor (a type icon under a thumbnail, a closed panel)
    // creates no effect item and costs nothing.
    Loader {
        id: effectLoader
        anchors.fill: parent
        active: root.modeActive && root.visible
        sourceComponent: IconEffect {
            source: image
            mode: root.mode
            tint: root.tint
            darkAppearance: root.darkAppearance
            wallpaper: root.overWallpaper
            nominalSize: root.size
            shaderUrl: root.shaderUrl
        }
    }
}
