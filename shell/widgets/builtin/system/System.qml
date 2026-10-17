pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import Grassfield.Ui
import qs.widgets
import "../../SystemStats.js" as Stats

// System widget: CPU load and memory use from /proc (small: CPU; medium: CPU and memory), sampled
// every Tokens.widgetSampleMs only while the widget is visible (WidgetBase.active).
WidgetBase {
    id: root

    property real cpu: 0
    property real memory: 0
    property real memUsedGb: 0
    property real memTotalGb: 0
    property bool haveSample: false
    // Previous /proc/stat totals {idle, total}.
    property var lastCpu: null

    Accessible.role: Accessible.StaticText
    Accessible.name: haveSample ? qsTr("System, CPU %1%, memory %2%").arg(Math.round(cpu * 100)).arg(Math.round(memory * 100)) : qsTr("System")

    function sample(): void {
        statFile.reload();
        memFile.reload();
    }

    Timer {
        interval: Tokens.widgetSampleMs
        running: root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: root.sample()
    }

    // Sampling stops with the widget; the next visit starts a fresh delta.
    onActiveChanged: if (!active)
        lastCpu = null

    FileView {
        id: statFile
        path: "/proc/stat"
        printErrors: false
        onLoaded: {
            const now = Stats.parseCpu(statFile.text());
            if (now === null)
                return;
            if (root.lastCpu !== null) {
                root.cpu = Stats.cpuLoad(root.lastCpu, now);
                root.haveSample = true;
            }
            root.lastCpu = now;
        }
    }

    FileView {
        id: memFile
        path: "/proc/meminfo"
        printErrors: false
        onLoaded: {
            const m = Stats.parseMemory(memFile.text());
            if (m === null)
                return;
            root.memory = m.used / m.total;
            root.memUsedGb = m.used / 1048576;
            root.memTotalGb = m.total / 1048576;
        }
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
                text: root.haveSample ? qsTr("%1%").arg(Math.round(gauge.value * 100)) : qsTr("...")
                font.pixelSize: Tokens.widgetGlyphSize
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

                    Behavior on width {
                        enabled: !root.reduceMotion
                        NumberAnimation {
                            duration: Appearance.duration(Tokens.motionNormal)
                        }
                    }
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
            detail: root.memTotalGb > 0 ? qsTr("%1 of %2 GB").arg(root.memUsedGb.toFixed(1)).arg(root.memTotalGb.toFixed(1)) : ""
        }
    }
}
