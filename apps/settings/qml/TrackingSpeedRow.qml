pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "MouseTrackpad.js" as MT

// Mouse and Trackpad > Tracking speed (macOS 27, docs/audits/settings-parity-2026-10-26.md § Mouse and Trackpad): a slider of 10
// stops (MouseTrackpad.TRACKING, Hyprland's input:sensitivity) with Slow and Fast under its ends. `picked` hands back the
// sensitivity of the stop moved to.
GestureRow {
    id: root

    property real sensitivity: 0

    signal picked(real sensitivity)

    title: qsTr("Tracking speed")
    rowHeight: Tokens.settingsTrackingRowHeight

    Item {
        width: root.width - Tokens.settingsTrackingSliderX - Tokens.settingsRowInset
        height: root.rowHeight

        Slider {
            id: slider
            y: Tokens.settingsTrackingSliderCenter - height / 2
            width: parent.width
            accessibleName: root.title
            from: 0
            to: MT.TRACKING.length - 1
            stops: MT.TRACKING.length
            value: MT.trackingIndex(root.sensitivity)
            onMoved: v => root.picked(MT.TRACKING[Math.round(v)])
        }

        Repeater {
            model: [{text: qsTr("Slow"), left: true}, {text: qsTr("Fast"), left: false}]

            delegate: Text {
                required property var modelData

                textFormat: Text.PlainText
                x: modelData.left ? 0 : slider.width - width
                y: Tokens.settingsTrackingLabelBaseline - baselineOffset
                text: modelData.text
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.ignored: true
            }
        }
    }
}
