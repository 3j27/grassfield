import QtQuick
import QtQuick.Shapes
import Grassfield.Ui

// An operation in an app's button place (spec SR13, SR18; macOS 27's download ring): the track, and the accent arc of
// `value` (0 to 1), or a short arc that turns while the operation waits or has no count yet (still with Reduce Motion).
// `stop`: a square inside, for an operation that can still leave the queue.
Item {
    id: root

    property real value: 0
    property bool indeterminate: true
    property bool stop: false
    readonly property real stroke: Tokens.storeRingStroke

    implicitWidth: Tokens.storeRingSize
    implicitHeight: Tokens.storeRingSize

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            strokeWidth: root.stroke
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: (root.width - root.stroke) / 2
                radiusY: radiusX
                startAngle: 0
                sweepAngle: 360
            }
        }
    }

    Shape {
        id: arc
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        visible: root.indeterminate || root.value > 0

        ShapePath {
            fillColor: "transparent"
            strokeColor: Appearance.colors.accent
            strokeWidth: root.stroke
            capStyle: ShapePath.RoundCap

            PathAngleArc {
                centerX: root.width / 2
                centerY: root.height / 2
                radiusX: (root.width - root.stroke) / 2
                radiusY: radiusX
                startAngle: -90
                sweepAngle: root.indeterminate ? Tokens.storeRingSweep : 360 * Math.max(0, Math.min(1, root.value))
            }
        }

        RotationAnimation on rotation {
            running: root.indeterminate && root.visible && !Appearance.reduceMotion
            from: 0
            to: 360
            duration: Tokens.storeRingTurnMs
            loops: Animation.Infinite
        }
    }

    Rectangle {
        visible: root.stop
        anchors.centerIn: parent
        width: Tokens.storeRingStopSize
        height: Tokens.storeRingStopSize
        radius: Tokens.storeRingStopRadius
        color: Appearance.colors.accent
    }
}
