import QtQuick
import QtQuick.Effects
import QtQuick.Window

// The floating sidebar panel of an app window (macOS 26 System Settings and Finder; ADR-0024, amendment 2026-11-03): an
// inset rounded panel in the sidebar fill, lit by a white rim and lifted by a soft shadow, with the window behind it in the
// gutters. The host places it: `anchors.fill: slot; anchors.leftMargin / topMargin / bottomMargin:
// Tokens.windowSidebarPanelInset`, the content area running straight on from its right edge, and gives the slot a z above the
// content so the shadow falls on it. An app window is opaque, so the fill is opaque and the shadow a plain drop shadow:
// there is nothing behind the panel to blur, and nothing here fakes it.
Rectangle {
    id: root

    // The window's own ratio (what its surface is drawn at), the screen's where there is no window yet: on a fractional-scale
    // surface the two can differ.
    readonly property real pixelRatio: Math.max(1, root.Window.window ? root.Window.window.devicePixelRatio : Screen.devicePixelRatio)
    // The rim, a whole number of device pixels (1 pt: 1 px at 1.25), so it never splits between two pixels.
    readonly property real rimWidth: Math.max(1, Math.round(Tokens.windowSidebarPanelRimWidth * root.pixelRatio)) / root.pixelRatio

    // A circle concentric with the window's corner (16.7 pt circle-equivalent less the inset, ADR-0024 note 2026-11-04), on
    // whole device pixels as the inset is: 11 px at 1.25 (8.8 pt), so the panel's curve runs parallel to the window's.
    radius: Math.round(Tokens.windowSidebarPanelRadius * root.pixelRatio) / root.pixelRatio
    color: Appearance.colors.sidebarFill

    // Under the panel (z -1), reaching the content beside it.
    RectangularShadow {
        anchors.fill: parent
        z: -1
        radius: root.radius
        blur: Tokens.windowSidebarPanelShadowBlur
        offset: Qt.vector2d(0, Tokens.windowSidebarPanelShadowOffsetY)
        color: Appearance.withAlpha(Appearance.colors.shadow, Appearance.dark ? Tokens.windowSidebarPanelShadowOpacityDark : Tokens.windowSidebarPanelShadowOpacity)
    }

    // The rim lies inside the panel's bounds, its far edges snapped down to whole device pixels. Increase Contrast: the
    // control outline of every shared control instead.
    Rectangle {
        objectName: "panelRim"
        width: Math.floor(root.width * root.pixelRatio) / root.pixelRatio
        height: Math.floor(root.height * root.pixelRatio) / root.pixelRatio
        radius: root.radius
        color: "transparent"
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : root.rimWidth
        border.color: Appearance.increaseContrast ? Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
            : Appearance.withAlpha(Appearance.colors.knob, Appearance.dark ? Tokens.windowSidebarPanelRimOpacityDark : Tokens.windowSidebarPanelRimOpacity)
    }
}
