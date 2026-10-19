import QtQuick
import QtQuick.Effects

// The folder colour step: one MultiEffect mapping the luminance of a folder icon (its shape and shading) onto a colour,
// alpha kept. Used as the layer effect of FolderIcon; nothing to do with the icon appearance modes.
MultiEffect {
    id: root

    property color tint: Appearance.folderTint
    readonly property var params: FolderStyle.effect(root.tint, Tokens)

    autoPaddingEnabled: false
    saturation: root.params.saturation
    brightness: root.params.brightness
    contrast: root.params.contrast
    colorization: root.params.colorization
    colorizationColor: root.params.colorizationColor
}
