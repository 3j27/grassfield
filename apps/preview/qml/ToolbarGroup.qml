import QtQuick
import Grassfield.Ui

// A capsule of toolbar buttons floating over the window (macOS 26 toolbar groups): the shared restrained-glass material
// (opaque in an app window: tint, rim highlight, border and shadow) around a row of buttons.
Item {
    id: root

    default property alias buttons: row.data

    implicitWidth: row.implicitWidth + 2 * Tokens.spacingXs
    implicitHeight: Tokens.previewToolbarCapsuleHeight
    width: implicitWidth
    height: implicitHeight

    Material {
        anchors.fill: parent
        radius: height / 2
    }
    // Lifted off the window: a light plate in the light appearance, a lighter tint in the dark one.
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity) : Appearance.withAlpha(Appearance.colors.knob, 1 - Tokens.materialFillOpacity)
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 0
    }
}
