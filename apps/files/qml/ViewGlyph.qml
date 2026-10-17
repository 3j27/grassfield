pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Small glyphs drawn from rectangles (Grassfield's own, no icon assets): "icons" (2x2 grid),
// "list" (rows), "columns" (three panes), "more" (three dots), "plus".
Item {
    id: root

    property string kind: "icons"
    property color color: Appearance.colors.text
    property int size: Tokens.filesToolbarIconSize

    readonly property real stroke: Math.max(1, Math.round(root.size / 10))

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    // icons: four rounded squares
    Grid {
        visible: root.kind === "icons"
        anchors.centerIn: parent
        columns: 2
        spacing: root.stroke * 1.5
        Repeater {
            model: 4
            Rectangle {
                width: (root.size - root.stroke * 1.5) / 2 - root.stroke
                height: width
                radius: root.stroke
                color: "transparent"
                border.width: root.stroke
                border.color: root.color
            }
        }
    }

    // list: bullet + line per row
    Column {
        visible: root.kind === "list"
        anchors.centerIn: parent
        spacing: root.size / 5
        Repeater {
            model: 3
            Row {
                spacing: root.stroke * 1.5
                Rectangle {
                    width: root.stroke * 1.5
                    height: root.stroke * 1.5
                    radius: width / 2
                    color: root.color
                }
                Rectangle {
                    width: root.size * 0.7
                    height: root.stroke * 1.5
                    radius: height / 2
                    color: root.color
                }
            }
        }
    }

    // columns: outlined box split in three
    Rectangle {
        visible: root.kind === "columns"
        anchors.centerIn: parent
        width: root.size
        height: root.size * 0.75
        radius: root.stroke
        color: "transparent"
        border.width: root.stroke
        border.color: root.color
        Row {
            anchors.fill: parent
            Repeater {
                model: 3
                Item {
                    id: pane
                    required property int index
                    width: parent.width / 3
                    height: parent.height
                    Rectangle {
                        visible: pane.index > 0
                        width: root.stroke
                        height: parent.height
                        color: root.color
                    }
                }
            }
        }
    }

    // more: three dots
    Row {
        visible: root.kind === "more"
        anchors.centerIn: parent
        spacing: root.size / 6
        Repeater {
            model: 3
            Rectangle {
                width: root.size / 6
                height: width
                radius: width / 2
                color: root.color
            }
        }
    }

    // plus
    Item {
        visible: root.kind === "plus"
        anchors.fill: parent
        Rectangle {
            anchors.centerIn: parent
            width: root.size * 0.75
            height: root.stroke * 1.5
            radius: height / 2
            color: root.color
        }
        Rectangle {
            anchors.centerIn: parent
            width: root.stroke * 1.5
            height: root.size * 0.75
            radius: width / 2
            color: root.color
        }
    }
}
