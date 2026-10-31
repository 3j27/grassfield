pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// CPU Usage (macOS's Window > CPU Usage, spec AM71): one bar per logical processor, its current share lit in segments from
// the bottom, System then User. The window is as wide as its bars. Opened by Main.qml (View > CPU Usage, Ctrl+2).
Window {
    id: root

    required property var app
    // ADR-0015: the titlebar-only style, as Inspect.
    property string gfChromeRole: "info"
    readonly property var processors: root.app.performance.processors
    readonly property int count: Math.max(1, root.processors.length)
    // The tests read it.
    readonly property alias bars: bars

    title: qsTr("CPU Usage")
    width: Math.max(Tokens.activityCpuUsageMinWidth, 2 * Tokens.spacingMd + root.count * Tokens.activityCpuUsageBarWidth + (root.count - 1) * Tokens.activityCpuUsageGap)
    height: chrome.height + 2 * Tokens.spacingMd + Tokens.activityCpuUsageBarHeight
    minimumWidth: root.width
    maximumWidth: root.width
    minimumHeight: root.height
    maximumHeight: root.height
    color: Appearance.colors.windowBackground
    visible: true

    Component.onCompleted: root.app.watchAux(root, "cpuUsage")

    Shortcut {
        sequences: [StandardKey.Close]
        enabled: root.app.focusWindow === root
        onActivated: root.close()
        onActivatedAmbiguously: root.close()
    }

    UnifiedToolbar {
        id: chrome
        width: parent.width
        window: root
        style: "titlebar"
        title: root.title
        doubleClickAction: root.app.titlebarDoubleClick
        canMinimize: root.app.canMinimize
    }

    Row {
        id: bars
        objectName: "cpuBars"
        anchors.top: chrome.bottom
        anchors.topMargin: Tokens.spacingMd
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Tokens.activityCpuUsageGap
        Accessible.role: Accessible.Graphic
        Accessible.name: root.title

        // Repeated by count, not by model: the list is new at each sample and its bars stay (as the summary's blocks).
        Repeater {
            model: root.processors.length

            Column {
                id: bar
                required property int index
                readonly property var modelData: root.processors[bar.index] ?? ({busy: -1, user: -1, system: -1})
                // Segments lit from the bottom: System's first, then User's.
                readonly property int segments: Tokens.activityCpuUsageSegments
                readonly property int systemLit: bar.modelData.system > 0 ? Math.round(bar.modelData.system * bar.segments) : 0
                readonly property int lit: bar.modelData.busy > 0 ? Math.min(bar.segments, Math.max(bar.systemLit, Math.round(bar.modelData.busy * bar.segments))) : 0
                width: Tokens.activityCpuUsageBarWidth
                spacing: Tokens.dockTileGraphGap
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Processor %1: %2%").arg(bar.index + 1).arg(Math.round(Math.max(0, bar.modelData.busy) * 100))

                Repeater {
                    model: bar.segments

                    Rectangle {
                        id: segment
                        required property int index
                        // The top segment first.
                        readonly property int fromBottom: bar.segments - segment.index
                        width: bar.width
                        height: (Tokens.activityCpuUsageBarHeight - (bar.segments - 1) * bar.spacing) / bar.segments
                        radius: Tokens.appsBorderWidth
                        color: segment.fromBottom <= bar.systemLit ? Appearance.colors.activityGraphSystem
                             : segment.fromBottom <= bar.lit ? Appearance.colors.activityGraphUser
                             : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2)
                    }
                }
            }
        }
    }
}
