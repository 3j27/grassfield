import QtQuick
import QtQuick.Effects

// The icon appearance effect of one mode over a texture source (an Image or a layered Item): one MultiEffect, no blur
// or shadow, so no intermediate pass beyond the effect itself. Used by TintedIcon and by the mode previews in Settings.
MultiEffect {
    id: root

    property string mode: "default"
    property color tint: Appearance.iconTint
    readonly property var params: IconModes.effect(root.mode, root.tint, Tokens)

    autoPaddingEnabled: false
    saturation: root.params.saturation
    brightness: root.params.brightness
    contrast: root.params.contrast
    colorization: root.params.colorization
    colorizationColor: root.params.colorizationColor
    opacity: root.params.opacity
}
