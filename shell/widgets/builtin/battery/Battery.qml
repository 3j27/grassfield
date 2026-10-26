pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Quickshell.Services.UPower
import Grassfield.Ui
import qs.widgets

// Battery widget: charge ring and state from UPower (small: ring; medium: ring, state and time).
// Honest when the machine has no battery: "No Battery".
WidgetBase {
    id: root

    readonly property var device: UPower.displayDevice
    readonly property bool present: device !== null && device.isPresent && device.isLaptopBattery
    readonly property real fraction: present ? Math.max(0, Math.min(1, device.percentage)) : 0
    readonly property int percent: Math.round(fraction * 100)
    readonly property bool charging: present && device.state === UPowerDeviceState.Charging
    readonly property bool full: present && device.state === UPowerDeviceState.FullyCharged
    readonly property real seconds: present ? (charging ? device.timeToFull : device.timeToEmpty) : 0
    readonly property string stateText: {
        if (!present)
            return qsTr("No Battery");
        if (full)
            return qsTr("Fully Charged");
        if (charging)
            return qsTr("Charging");
        return qsTr("On Battery");
    }
    readonly property string timeText: {
        if (!present || full || seconds <= 0)
            return "";
        const minutes = Math.round(seconds / 60);
        const h = Math.floor(minutes / 60);
        const m = String(minutes % 60).padStart(2, "0");
        return charging ? qsTr("%1:%2 until full").arg(h).arg(m) : qsTr("%1:%2 remaining").arg(h).arg(m);
    }

    Accessible.role: Accessible.StaticText
    Accessible.name: present ? qsTr("Battery %1%, %2").arg(percent).arg(stateText) : qsTr("No Battery")

    Item {
        id: ring

        visible: root.present || !root.isSmall
        readonly property real edge: root.isSmall ? Math.min(root.width, root.height) - 2 * root.padding : root.height - 2 * root.padding
        readonly property real stroke: Tokens.spacingSm

        x: root.isSmall ? (root.width - width) / 2 : root.padding
        y: root.padding
        width: edge
        height: edge

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                fillColor: "transparent"
                strokeColor: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                strokeWidth: ring.stroke
                capStyle: ShapePath.RoundCap

                PathAngleArc {
                    centerX: ring.width / 2
                    centerY: ring.height / 2
                    radiusX: (ring.width - ring.stroke) / 2
                    radiusY: radiusX
                    startAngle: 0
                    sweepAngle: 360
                }
            }

            ShapePath {
                fillColor: "transparent"
                strokeColor: root.charging || root.full ? Appearance.colors.accent : (root.percent <= 20 ? Appearance.colors.danger : Appearance.colors.text)
                strokeWidth: ring.stroke
                capStyle: ShapePath.RoundCap

                PathAngleArc {
                    centerX: ring.width / 2
                    centerY: ring.height / 2
                    radiusX: (ring.width - ring.stroke) / 2
                    radiusY: radiusX
                    startAngle: -90
                    sweepAngle: 360 * root.fraction
                }
            }
        }

        WidgetLabel {
            anchors.centerIn: parent
            width: parent.width - 2 * ring.stroke - Tokens.spacingSm
            horizontalAlignment: Text.AlignHCenter
            text: root.present ? qsTr("%1%").arg(root.percent) : "-"
            size: Tokens.widgetGlyphSize / 1.5
            font.weight: Tokens.typographyMenuBoldWeight
            fontSizeMode: Text.Fit
            minimumPixelSize: Tokens.typographyCaptionSize
        }
    }

    WidgetLabel {
        anchors.centerIn: parent
        width: parent.width - 2 * root.padding
        horizontalAlignment: Text.AlignHCenter
        visible: root.isSmall && !root.present
        text: root.stateText
        color: Appearance.colors.textSecondary
    }

    Column {
        visible: !root.isSmall
        x: ring.x + ring.width + root.padding
        y: (root.height - height) / 2
        width: root.width - x - root.padding
        spacing: Tokens.spacingXs

        WidgetLabel {
            width: parent.width
            text: Registry.title("battery")
            color: Appearance.colors.textSecondary
        }

        WidgetLabel {
            width: parent.width
            text: root.stateText
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
        }

        WidgetLabel {
            width: parent.width
            visible: root.timeText !== ""
            text: root.timeText
            color: Appearance.colors.textSecondary
        }
    }
}
