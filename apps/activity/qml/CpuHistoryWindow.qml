pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// CPU History (macOS's Window > CPU History, spec AM72): one small graph per logical processor, System and User stacked over
// the samples kept; View > Clear CPU History (Ctrl+K) empties them. GPU History is the same with one graph per GPU
// (`gpu: true`). Opened by Main.qml (View > CPU History, Ctrl+3; View > GPU History, Ctrl+4).
Window {
    id: root

    required property var app
    // GPU History: one graph per GPU instead of one per processor.
    property bool gpu: false
    // ADR-0015: the titlebar-only style, as Inspect.
    property string gfChromeRole: "info"
    readonly property var graphs: root.gpu ? root.app.performance.gpus : root.app.performance.processors
    // The tests read it.
    readonly property alias tiles: tiles

    // AM74: the size it had when it last closed.
    readonly property string kind: root.gpu ? "gpuHistory" : "cpuHistory"
    readonly property size savedSize: root.app.savedWindowSize(root.kind)

    title: root.gpu ? qsTr("GPU History") : qsTr("CPU History")
    width: root.savedSize.width > 0 ? root.savedSize.width : root.gpu ? Tokens.activityGpuHistoryWidth : Tokens.activityCpuHistoryWidth
    height: root.savedSize.height > 0 ? root.savedSize.height : root.gpu ? Tokens.activityGpuHistoryHeight : Tokens.activityCpuHistoryHeight
    minimumWidth: Tokens.activityPerformanceTileMinWidth + 2 * Tokens.spacingMd
    minimumHeight: chrome.height + Tokens.activityPerformanceTileHeight + 2 * Tokens.spacingMd
    color: Appearance.colors.windowBackground
    visible: true

    // A graph's newest value, its series summed (a gap is 0).
    function lastValue(graph: var): real {
        let sum = 0;
        for (const s of (graph && graph.series) || []) {
            const v = s.values.length > 0 ? s.values[s.values.length - 1] : -1;
            if (v > 0)
                sum += v;
        }
        return sum;
    }

    Component.onCompleted: {
        root.app.performance.capacity = Tokens.activityHistorySamples;
        root.app.watchAux(root, root.kind);
    }
    onClosing: root.app.saveWindowSize(root.kind, root.width, root.height)

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

    // No GPU has a client yet: said, not an empty window.
    Text {
        anchors.centerIn: parent
        visible: root.gpu && root.graphs.length === 0
        textFormat: Text.PlainText
        text: qsTr("No app is using a GPU.")
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Flickable {
        id: pane
        anchors.top: chrome.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingMd
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: tiles.implicitHeight

        Grid {
            id: tiles
            objectName: "historyTiles"
            width: pane.width
            columns: root.gpu ? 1 : Math.max(1, Math.floor((pane.width + Tokens.spacingXs) / (Tokens.activityPerformanceTileMinWidth + Tokens.spacingXs)))
            spacing: Tokens.spacingXs

            // Repeated by count, not by model: the list is new at each sample and its graphs stay.
            Repeater {
                model: root.graphs.length

                Column {
                    id: tile
                    required property int index
                    readonly property var modelData: root.graphs[tile.index] ?? ({title: "", graph: ({})})
                    width: (tiles.width - (tiles.columns - 1) * tiles.spacing) / tiles.columns
                    spacing: Tokens.spacingXs
                    // Spec "Accessibility": a graph's name says its current value.
                    readonly property int percent: Math.round(Math.max(0, root.gpu ? root.lastValue(tile.modelData.graph) : (tile.modelData.busy ?? -1)) * 100)
                    Accessible.role: Accessible.Graphic
                    Accessible.name: root.gpu ? qsTr("%1: %2%").arg(tile.modelData.title).arg(tile.percent)
                                              : qsTr("Processor %1: %2%").arg(tile.index + 1).arg(tile.percent)

                    Text {
                        visible: root.gpu
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: root.gpu ? tile.modelData.title : ""
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }

                    Rectangle {
                        width: parent.width
                        height: root.gpu ? Tokens.activityPerformanceGraphHeight / 2 : Tokens.activityPerformanceTileHeight
                        radius: Tokens.radiusControl
                        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                        border.width: Tokens.appsBorderWidth
                        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

                        Graph {
                            anchors.fill: parent
                            anchors.margins: Tokens.appsBorderWidth
                            graph: tile.modelData.graph
                            capacity: root.app.performance.capacity
                        }
                    }
                }
            }
        }
    }
}
