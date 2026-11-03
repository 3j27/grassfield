import QtQuick
import QtQuick.Window

// The floating sidebar panel of an app window (macOS 26 System Settings and Finder; ADR-0024, amendment 2026-11-03): an
// inset rounded panel in the sidebar fill, lit by a one-device-pixel white rim, with the window behind it in the gutters.
// The host places it: `anchors.fill: slot; anchors.leftMargin / bottomMargin: Tokens.windowSidebarPanelInset`, the content
// area running straight on from its right edge (the 8-pt gap of the first toolbar item is the toolbar's own inset).
// An app window is opaque, so the fill is opaque: there is nothing behind the panel to blur, and nothing here fakes it.
Rectangle {
    id: root

    readonly property real hairline: 1 / Math.max(1, Screen.devicePixelRatio)

    radius: Tokens.windowSidebarPanelRadius
    color: Appearance.colors.sidebarFill
    // The rim lies inside the panel's bounds. Increase Contrast: the control outline of every shared control instead.
    border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : root.hairline
    border.color: Appearance.increaseContrast ? Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
        : Appearance.withAlpha(Appearance.colors.knob, Appearance.dark ? Tokens.windowSidebarPanelRimOpacityDark : Tokens.windowSidebarPanelRimOpacity)
}
