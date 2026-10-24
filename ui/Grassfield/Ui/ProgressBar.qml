import QtQuick
import QtQuick.Templates as T

// Progress bar (QtQuick.Templates ProgressBar): a pill track with an accent fill, `progressHeight` thick. Determinate
// from `from` to `to`; `indeterminate` sweeps a short fill back and forth (a still half-width fill with Reduce Motion).
T.ProgressBar {
    id: root

    property string accessibleName: ""
    // The indeterminate sweep is running (it stops with Reduce Motion and while hidden).
    readonly property bool sweeping: root.indeterminate && root.visible && !Appearance.reduceMotion

    implicitWidth: Tokens.controlSliderDefaultWidth
    implicitHeight: Tokens.controlProgressHeight
    Accessible.role: Accessible.ProgressBar
    Accessible.name: root.accessibleName

    background: Rectangle {
        radius: height / 2
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
    }

    contentItem: Item {
        clip: true

        Rectangle {
            id: fill
            readonly property real sweep: root.width / 3
            width: root.indeterminate ? fill.sweep : root.visualPosition * parent.width
            height: parent.height
            radius: height / 2
            color: Appearance.colors.accent
            x: root.indeterminate && Appearance.reduceMotion ? (parent.width - width) / 2 : 0
            opacity: root.enabled ? 1 : Tokens.materialDisabledOpacity

            SequentialAnimation on x {
                running: root.sweeping
                loops: Animation.Infinite
                NumberAnimation {
                    from: 0
                    to: root.width - fill.sweep
                    duration: Appearance.duration(Tokens.motionSlow)
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    from: root.width - fill.sweep
                    to: 0
                    duration: Appearance.duration(Tokens.motionSlow)
                    easing.type: Easing.InOutQuad
                }
            }
        }
    }
}
