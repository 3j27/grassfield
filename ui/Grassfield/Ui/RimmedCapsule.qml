import QtQuick
import QtQuick.Window

// A glass capsule of an app window's chrome (macOS 27; Settings and the Store): the sidebar's search field and the
// toolbar's back / forward group. An almost clear fill, one device pixel of dark rim outside and one of light rim inside
// (docs/audits/settings-parity-2026-10-26.md § Window and sidebar).
Rectangle {
    id: root

    // The fill: the text colour at this opacity (the toolbar group is a step lighter than the field, macOS 27).
    property real fillOpacity: Tokens.toolbarFieldFillOpacity
    readonly property real hairline: 1 / Math.max(1, Screen.devicePixelRatio)

    radius: height / 2
    color: Appearance.withAlpha(Appearance.colors.text, root.fillOpacity)
    // Increase Contrast: the control outline of every shared control instead of the faint rim.
    border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : root.hairline
    border.color: Appearance.increaseContrast ? Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        : Appearance.withAlpha(Appearance.colors.shadow, Appearance.dark ? Tokens.toolbarRimOpacityDark : Tokens.toolbarRimOpacity)

    Rectangle {
        anchors.fill: parent
        anchors.margins: root.hairline
        radius: height / 2
        color: "transparent"
        border.width: root.hairline
        border.color: Appearance.withAlpha(Appearance.colors.knob, Appearance.dark ? Tokens.toolbarInnerRimOpacityDark : Tokens.toolbarInnerRimOpacity)
    }
}
