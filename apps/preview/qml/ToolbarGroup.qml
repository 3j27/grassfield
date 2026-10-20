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

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 0
    }
}
