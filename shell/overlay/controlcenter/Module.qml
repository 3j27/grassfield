import QtQuick
import Grassfield.Ui

// One floating glass module of Quick Settings (macOS model: no shared panel, every module is its
// own frosted shape on a 4-column grid). cols x rows are grid spans (rows 0: the height follows
// `contentHeight`, used by the opened detail module). The host (ControlCenter) places the module and
// lists it in `surfaces`, which is how the Overlay window gives each one its own blur region.
// The material draws no shadow here: ten shadow layers cost more than they add on a transparent window.
Item {
    id: root

    property int cols: 1
    property int rows: 1
    property real radius: height <= Tokens.quicksettingsCell ? height / 2 : Tokens.quicksettingsRadiusTile
    property real contentHeight: 0

    readonly property real spanWidth: cols * Tokens.quicksettingsCell + (cols - 1) * Tokens.quicksettingsGap
    readonly property real spanHeight: rows * Tokens.quicksettingsCell + (rows - 1) * Tokens.quicksettingsGap

    default property alias body: slot.data

    width: spanWidth
    height: rows > 0 ? spanHeight : contentHeight

    Material {
        glassClass: "controls"
        anchors.fill: parent
        radius: root.radius
        shadowEnabled: false
    }

    Item {
        id: slot
        anchors.fill: parent
    }
}
