import QtQuick
import QtQuick.Window
import Grassfield.Ui

// A glass capsule of the Settings window chrome (macOS 27): the sidebar's search field and the toolbar's back / forward
// group. An almost clear fill, one device pixel of dark rim outside and one of light rim inside
// (docs/audits/settings-parity-2026-10-26.md § Window and sidebar).
Rectangle {
    id: root

    // The fill: the text colour at this opacity (the toolbar group is a step lighter than the field, macOS 27).
    property real fillOpacity: Tokens.settingsFieldFillOpacity
    readonly property real hairline: 1 / Math.max(1, Screen.devicePixelRatio)

    radius: height / 2
    color: Appearance.withAlpha(Appearance.colors.text, root.fillOpacity)
    border.width: root.hairline
    border.color: Appearance.withAlpha(Appearance.colors.shadow, Appearance.dark ? Tokens.settingsRimOpacityDark : Tokens.settingsRimOpacity)

    Rectangle {
        anchors.fill: parent
        anchors.margins: root.hairline
        radius: height / 2
        color: "transparent"
        border.width: root.hairline
        border.color: Appearance.withAlpha(Appearance.colors.knob, Appearance.dark ? Tokens.settingsInnerRimOpacityDark : Tokens.settingsInnerRimOpacity)
    }
}
