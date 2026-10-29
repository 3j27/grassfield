pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// The summary at the bottom of the window (spec AM5; ADR-0038 step 2b): the tab's figures and graphs, left to right as the
// backend lists them, under the same sample as the table. A figure that a graph draws has a square of the graph's colour
// before its label (the text keeps its 4.5:1). The Disk and Network graphs carry a pop-up above them (IO or Data, Packets or
// Data, remembered). Blocks and rows are repeated by count, not by model: a new sample changes their texts and shapes in
// place, so an open pop-up stays open.
Item {
    id: root

    required property var backend
    readonly property var summary: root.backend.summary
    readonly property var blocks: root.summary.blocks
    readonly property int graphCount: root.blocks.filter(b => b.kind === "graph").length
    readonly property int figureCount: root.blocks.length - root.graphCount
    readonly property real slotWidth: root.figureCount > 0
        ? Math.max(0, (root.width - 2 * Tokens.spacingLg - root.graphCount * Tokens.activityGraphWidth - (root.blocks.length - 1) * Tokens.spacingLg) / root.figureCount)
        : 0

    implicitHeight: Tokens.activitySummaryHeight

    Binding {
        target: root.summary
        property: "capacity"
        value: Tokens.activityHistorySamples
    }

    Rectangle {
        width: parent.width
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Row {
        x: Tokens.spacingLg
        y: Tokens.spacingMd
        height: parent.height - 2 * Tokens.spacingMd
        spacing: Tokens.spacingLg

        Repeater {
            model: root.blocks.length

            delegate: Item {
                id: slot
                required property int index
                readonly property var block: slot.index < root.blocks.length ? root.blocks[slot.index] : ({})
                readonly property bool isGraph: slot.block.kind === "graph"

                width: slot.isGraph ? Tokens.activityGraphWidth : root.slotWidth
                height: parent.height

                // Figures: a label on the left, its value on the right, at most figureWidth wide, centred in the slot.
                Column {
                    visible: !slot.isGraph
                    width: Math.min(slot.width, Tokens.activityFigureWidth)
                    anchors.centerIn: parent
                    spacing: Tokens.spacingXs

                    Repeater {
                        model: slot.isGraph ? 0 : (slot.block.rows || []).length

                        delegate: Item {
                            id: row
                            required property int index
                            readonly property var figure: (slot.block.rows || [])[row.index] || ({})

                            width: parent.width
                            height: label.implicitHeight
                            Accessible.role: Accessible.StaticText
                            Accessible.name: (row.figure.label || "") + " " + (row.figure.value || "")

                            Rectangle {
                                id: swatch
                                visible: !!row.figure.swatch
                                width: Tokens.activitySwatchSize
                                height: Tokens.activitySwatchSize
                                radius: Tokens.appsBorderWidth
                                anchors.verticalCenter: parent.verticalCenter
                                color: row.figure.swatch && Appearance.colors[row.figure.swatch] !== undefined ? Appearance.colors[row.figure.swatch] : "transparent"
                            }
                            Text {
                                id: label
                                anchors.left: parent.left
                                anchors.leftMargin: Tokens.activitySwatchSize + Tokens.spacingXs
                                anchors.right: value.left
                                anchors.rightMargin: Tokens.spacingSm
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                text: row.figure.label || ""
                                color: Appearance.windowSecondary
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyCaptionSize
                            }
                            Text {
                                id: value
                                anchors.right: parent.right
                                textFormat: Text.PlainText
                                text: row.figure.value || ""
                                color: Appearance.colors.text
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyCaptionSize
                                font.features: {"tnum": 1}
                            }
                        }
                    }
                }

                // A graph under its title, or under its pop-up when it has modes.
                Item {
                    visible: slot.isGraph
                    anchors.fill: parent

                    Text {
                        id: title
                        visible: !slot.block.modes
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: slot.block.title || ""
                        color: Appearance.windowSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                        font.capitalization: Font.AllUppercase
                        Accessible.ignored: true
                    }
                    ComboBox {
                        id: modes
                        objectName: "graphMode-" + (slot.block.key || "")
                        visible: !!slot.block.modes
                        inline: true
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: title.verticalCenter
                        model: (slot.block.modes || []).map(m => ({id: m.key, text: m.title}))
                        value: slot.block.mode || ""
                        accessibleName: qsTr("Graph")
                        onPicked: id => root.backend.setGraphMode(slot.block.key, id)
                    }

                    Rectangle {
                        id: well
                        anchors.top: title.bottom
                        anchors.topMargin: Tokens.spacingXs
                        anchors.bottom: parent.bottom
                        width: parent.width
                        radius: Tokens.radiusControl
                        color: Appearance.colors.groupFill
                        border.width: Tokens.appsBorderWidth
                        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                        Accessible.role: Accessible.Graphic
                        Accessible.name: slot.block.title || ""

                        Graph {
                            anchors.fill: parent
                            anchors.margins: Tokens.appsBorderWidth
                            graph: slot.isGraph ? slot.block : ({})
                            capacity: root.summary.capacity
                        }
                    }
                }
            }
        }
    }
}
