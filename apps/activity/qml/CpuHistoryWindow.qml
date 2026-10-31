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

    title: root.gpu ? qsTr("GPU History") : qsTr("CPU History")
    width: root.gpu ? Tokens.activityGpuHistoryWidth : Tokens.activityCpuHistoryWidth
    height: root.gpu ? Tokens.activityGpuHistoryHeight : Tokens.activityCpuHistoryHeight
    minimumWidth: Tokens.activityPerformanceTileMinWidth + 2 * Tokens.spacingMd
    minimumHeight: chrome.height + Tokens.activityPerformanceTileHeight + 2 * Tokens.spacingMd
    color: Appearance.colors.windowBackground
    visible: true

    Component.onCompleted: {
        root.app.performance.capacity = Tokens.activityHistorySamples;
        root.app.watchAux(root, root.gpu ? "gpuHistory" : "cpuHistory");
    }

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
        color: Appearance.colors.textSecondary
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

            Repeater {
                model: root.graphs

                Column {
                    id: tile
                    required property var modelData
                    required property int index
                    width: (tiles.width - (tiles.columns - 1) * tiles.spacing) / tiles.columns
                    spacing: Tokens.spacingXs
                    Accessible.role: Accessible.Graphic
                    Accessible.name: root.gpu ? tile.modelData.title : qsTr("Processor %1").arg(tile.index + 1)

                    Text {
                        visible: root.gpu
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: root.gpu ? tile.modelData.title : ""
                        color: Appearance.colors.textSecondary
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
