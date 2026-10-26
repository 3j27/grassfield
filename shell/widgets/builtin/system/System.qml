pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.widgets

// System widget: CPU load and memory use from /proc (small: CPU; medium: CPU and memory), sampled
// by the shared SystemSampler only while a System widget is visible (WidgetBase.active). The gauges jump to
// each new value (no animation): a periodic animation would repaint the surface every sample.
WidgetBase {
    id: root

    readonly property real cpu: SystemSampler.cpu
    readonly property real memory: SystemSampler.memory
    readonly property real memUsedGb: SystemSampler.memUsedGb
    readonly property real memTotalGb: SystemSampler.memTotalGb
    readonly property bool haveSample: SystemSampler.haveSample

    Accessible.role: Accessible.StaticText
    Accessible.name: haveSample ? qsTr("System, CPU %1%, memory %2%").arg(Math.round(cpu * 100)).arg(Math.round(memory * 100)) : qsTr("System")

    // Registers with the shared sampler while active (it stops with its last user).
    property bool registered: false
    function register(): void {
        const want = root.active;
        if (want === registered)
            return;
        registered = want;
        SystemSampler.users += want ? 1 : -1;
    }
    onActiveChanged: register()
    Component.onCompleted: register()
    Component.onDestruction: {
        if (registered)
            SystemSampler.users -= 1;
    }

    component Gauge: Item {
        id: gauge

        property string label: ""
        property real value: 0
        property string detail: ""

        implicitHeight: col.implicitHeight

        Column {
            id: col
            width: parent.width
            spacing: Tokens.spacingXs

            WidgetLabel {
                width: parent.width
                text: gauge.label
                color: Appearance.colors.textSecondary
            }

            WidgetLabel {
                width: parent.width
                text: root.haveSample ? qsTr("%1%").arg(Math.round(gauge.value * 100)) : qsTr("…")
                size: Tokens.widgetGlyphSize
                font.weight: Tokens.typographyMenuBoldWeight
            }

            Rectangle {
                width: parent.width
                height: Tokens.spacingSm
                radius: height / 2
                color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, gauge.value))
                    height: parent.height
                    radius: parent.radius
                    color: gauge.value > 0.9 ? Appearance.colors.danger : Appearance.colors.accent
                }
            }

            WidgetLabel {
                width: parent.width
                visible: gauge.detail !== ""
                text: gauge.detail
                color: Appearance.colors.textSecondary
                font.pixelSize: Tokens.typographyCaptionSize
            }
        }
    }

    Row {
        x: root.padding
        y: (root.height - height) / 2
        width: root.width - 2 * root.padding
        spacing: Tokens.spacingLg

        Gauge {
            width: root.isSmall ? parent.width : (parent.width - parent.spacing) / 2
            label: qsTr("CPU")
            value: root.cpu
        }

        Gauge {
            visible: !root.isSmall
            width: (parent.width - parent.spacing) / 2
            label: qsTr("Memory")
            value: root.memory
            detail: root.memTotalGb > 0 ? qsTr("%1 of %2 GB").arg(Qt.locale().toString(root.memUsedGb, "f", 1)).arg(Qt.locale().toString(root.memTotalGb, "f", 1)) : ""
        }
    }
}
