pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Performance (Windows 11's, spec AM66; ADR-0038 g): a sidebar with one row per resource (CPU, Memory, each physical disk,
// each network interface but lo, each GPU with clients), each with a small live graph and its value; the selected one's
// title, model, large graph and figures. CPU's pop-up shows one graph overall or one small graph per logical processor;
// Memory adds its composition bar. The backend builds all of it while the window is on screen. Opened by Main.qml as one of
// its own windows (View > Performance, Ctrl+5).
Window {
    id: root

    required property var app
    // ADR-0015: the titlebar-only style, as Inspect and Files' Get Info.
    property string gfChromeRole: "info"
    readonly property var performance: root.app.performance
    readonly property var detail: root.performance.detail
    // The tests read them.
    readonly property alias sidebar: sidebarItem
    readonly property alias cpuModePicker: cpuModePicker
    readonly property alias figures: figures

    // AM74: the size it had when it last closed.
    readonly property size savedSize: root.app.savedWindowSize("performance")

    title: qsTr("Performance")
    width: root.savedSize.width > 0 ? root.savedSize.width : Tokens.activityPerformanceWidth
    height: root.savedSize.height > 0 ? root.savedSize.height : Tokens.activityPerformanceHeight
    minimumWidth: Tokens.activityPerformanceMinWidth
    minimumHeight: Tokens.activityPerformanceMinHeight
    color: Appearance.colors.windowBackground
    visible: true

    Component.onCompleted: {
        root.performance.capacity = Tokens.activityHistorySamples;
        root.app.watchAux(root, "performance");
    }
    onClosing: root.app.saveWindowSize("performance", root.width, root.height)

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

    // The sidebar: the resources, the selected one highlighted; Up and Down move.
    ListView {
        id: sidebarItem
        objectName: "performanceSidebar"
        anchors.top: chrome.bottom
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingSm
        width: Tokens.activityPerformanceSidebarWidth
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        focus: true
        activeFocusOnTab: true
        // Rows by count, not by model: the list is new at each sample and its rows (and their graphs) stay.
        model: root.performance.resources.length
        Accessible.role: Accessible.List
        Accessible.name: qsTr("Resources")

        Keys.onUpPressed: root.step(-1)
        Keys.onDownPressed: root.step(1)

        delegate: Item {
            id: resource
            required property int index
            readonly property var modelData: root.performance.resources[resource.index] ?? ({key: "", title: "", subtitle: "", value: "", graph: ({})})
            readonly property var lines: [resource.modelData.title, resource.modelData.subtitle, resource.modelData.value]
            readonly property bool chosen: root.performance.selected === resource.modelData.key
            width: sidebarItem.width
            height: Tokens.activityPerformanceSidebarRowHeight
            Accessible.role: Accessible.ListItem
            Accessible.name: resource.modelData.title + ", " + resource.modelData.value
            Accessible.selected: resource.chosen

            Rectangle {
                anchors.fill: parent
                radius: Tokens.radiusControl
                color: resource.chosen ? (sidebarItem.activeFocus ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity * 2))
                     : mouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
            }

            Rectangle {
                id: thumb
                x: Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter
                width: Tokens.activityPerformanceSidebarGraphWidth
                height: parent.height - 2 * Tokens.spacingSm
                radius: Tokens.radiusControl / 2
                color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                border.width: Tokens.appsBorderWidth
                border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

                Graph {
                    anchors.fill: parent
                    anchors.margins: Tokens.appsBorderWidth
                    graph: resource.modelData.graph
                    capacity: root.performance.capacity
                }
            }

            Column {
                anchors.left: thumb.right
                anchors.leftMargin: Tokens.spacingSm
                anchors.right: parent.right
                anchors.rightMargin: Tokens.spacingSm
                anchors.verticalCenter: parent.verticalCenter

                Repeater {
                    model: 3

                    Text {
                        required property int index
                        readonly property string modelData: resource.lines[index] ?? ""
                        visible: modelData !== ""
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: modelData
                        color: resource.chosen && sidebarItem.activeFocus ? Appearance.colors.selectionText
                             : index === 0 ? Appearance.colors.text : Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: index === 0 ? Tokens.typographyBodySize : Tokens.typographyCaptionSize
                        font.weight: index === 0 ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
                    }
                }
            }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: {
                    sidebarItem.forceActiveFocus();
                    root.performance.selected = resource.modelData.key;
                }
            }
        }
    }

    function step(delta: int): void {
        const list = root.performance.resources;
        const at = list.findIndex(r => r.key === root.performance.selected);
        const next = Math.max(0, Math.min(list.length - 1, at + delta));
        if (next >= 0 && next < list.length)
            root.performance.selected = list[next].key;
        sidebarItem.positionViewAtIndex(next, ListView.Contain);
    }

    Rectangle {
        id: divider
        anchors.top: chrome.bottom
        anchors.bottom: parent.bottom
        anchors.left: sidebarItem.right
        anchors.leftMargin: Tokens.spacingSm
        width: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Flickable {
        id: pane
        anchors.top: chrome.bottom
        anchors.left: divider.right
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.spacingMd
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: content.implicitHeight

        Column {
            id: content
            width: pane.width
            spacing: Tokens.spacingMd

            // The title and the model's name; CPU's pop-up at the right.
            Item {
                width: parent.width
                height: Math.max(titleText.implicitHeight, cpuModePicker.visible ? cpuModePicker.implicitHeight : 0)

                Text {
                    id: titleText
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.detail.title || ""
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyTitleSize
                    font.weight: Tokens.typographyMenuBoldWeight
                }

                Text {
                    anchors.left: titleText.right
                    anchors.leftMargin: Tokens.spacingMd
                    anchors.right: cpuModePicker.visible ? cpuModePicker.left : parent.right
                    anchors.rightMargin: cpuModePicker.visible ? Tokens.spacingMd : 0
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: root.detail.subtitle || ""
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                ComboBox {
                    id: cpuModePicker
                    objectName: "cpuModePicker"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.detail.key === "cpu"
                    accessibleName: qsTr("CPU graph")
                    model: [{id: "overall", text: qsTr("Overall Utilization")}, {id: "logical", text: qsTr("Logical Processors")}]
                    value: root.performance.cpuMode
                    onPicked: id => root.performance.cpuMode = id
                }
            }

            // The large graphs (one, or Disk's two, or a GPU's engines); CPU's logical processors as small graphs.
            Repeater {
                model: root.detail.logical ? 0 : (root.detail.graphs || []).length

                Column {
                    id: big
                    required property int index
                    readonly property var modelData: (root.detail.graphs || [])[big.index] ?? ({title: "", graph: ({})})
                    width: content.width
                    spacing: Tokens.spacingXs

                    Text {
                        textFormat: Text.PlainText
                        text: big.modelData.title
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }

                    GraphFrame {
                        // Spec "Accessibility": the graph's name with the selected resource's value now.
                        Accessible.role: Accessible.Graphic
                        Accessible.name: big.modelData.title + ", " + ((root.performance.resources.find(r => r.key === root.performance.selected) || {}).value || "")
                        width: big.width
                        height: (root.detail.graphs || []).length > 1 ? Tokens.activityPerformanceGraphHeight / 2 : Tokens.activityPerformanceGraphHeight
                        graph: big.modelData.graph
                    }
                }
            }

            Grid {
                id: tiles
                visible: root.detail.logical === true
                width: content.width
                columns: Math.max(1, Math.floor((content.width + Tokens.spacingXs) / (Tokens.activityPerformanceTileMinWidth + Tokens.spacingXs)))
                spacing: Tokens.spacingXs

                Repeater {
                    model: tiles.visible ? root.performance.processors.length : 0

                    GraphFrame {
                        id: tile
                        required property int index
                        readonly property var processor: root.performance.processors[tile.index] ?? ({busy: -1})
                        Accessible.role: Accessible.Graphic
                        Accessible.name: qsTr("Processor %1: %2%").arg(tile.index + 1).arg(Math.round(Math.max(0, tile.processor.busy) * 100))
                        width: (tiles.width - (tiles.columns - 1) * tiles.spacing) / tiles.columns
                        height: Tokens.activityPerformanceTileHeight
                        graph: tile.processor.graph ?? ({})
                    }
                }
            }

            // Memory: In Use, Compressed, Cached and Free, side by side.
            Row {
                id: bar
                visible: (root.detail.bar || []).length > 0
                width: content.width
                height: Tokens.activityPerformanceBarHeight

                Repeater {
                    model: (root.detail.bar || []).length

                    Rectangle {
                        required property int index
                        readonly property var modelData: (root.detail.bar || [])[index] ?? ({label: "", fraction: 0, color: ""})
                        width: bar.width * Math.max(0, modelData.fraction)
                        height: bar.height
                        color: modelData.color !== "" && Appearance.colors[modelData.color] !== undefined ? Appearance.colors[modelData.color]
                             : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                        Accessible.role: Accessible.StaticText
                        Accessible.name: modelData.label
                    }
                }
            }

            Flow {
                id: figures
                objectName: "performanceFigures"
                // As many columns as fit, each at least the token's width.
                readonly property int columns: Math.max(1, Math.floor((width + spacing) / (Tokens.activityPerformanceFigureWidth + spacing)))
                width: content.width
                spacing: Tokens.spacingSm

                Repeater {
                    model: (root.detail.figures || []).length

                    Row {
                        id: pair
                        required property int index
                        readonly property var modelData: (root.detail.figures || [])[pair.index] ?? ({label: "", value: ""})
                        width: (figures.width - (figures.columns - 1) * figures.spacing) / figures.columns
                        spacing: Tokens.spacingSm
                        Accessible.role: Accessible.StaticText
                        Accessible.name: pair.modelData.label + " " + pair.modelData.value

                        Text {
                            width: pair.width * 0.45
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            text: pair.modelData.label
                            color: Appearance.windowSecondary
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                        }
                        Text {
                            width: pair.width * 0.55 - pair.spacing
                            textFormat: Text.PlainText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            text: pair.modelData.value
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyBodySize
                            font.features: {"tnum": 1}
                        }
                    }
                }
            }
        }
    }

    // A graph on its plate, as the summary's.
    component GraphFrame: Rectangle {
        id: frame
        property var graph: ({})
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: Tokens.appsBorderWidth
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

        Graph {
            anchors.fill: parent
            anchors.margins: Tokens.appsBorderWidth
            graph: frame.graph
            capacity: root.performance.capacity
        }
    }
}
