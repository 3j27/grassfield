pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TagColors.js" as TagColors

// The colour tags of an item as small overlapping dots (at most Tokens.filesTagDotsMax). Each dot has an edge in a
// darker shade of its colour (Tokens.filesTagDotOutlineDarker: yellow, orange and green alone are under 3:1 against the
// light window, the edge is not) and a ring in the background colour around it so stacked dots stay apart.
// `colors`: palette indices (role tagColors).
Row {
    id: root

    property var colors: []
    property int size: Tokens.filesTagDotSize
    // The colour behind the dots (window or selection), drawn as their ring.
    property color ringColor: Appearance.colors.materialTint

    readonly property var shown: (root.colors || []).slice(0, Tokens.filesTagDotsMax)

    visible: root.shown.length > 0
    spacing: -Tokens.filesTagDotOverlap
    Accessible.ignored: true

    Repeater {
        model: root.shown

        delegate: Item {
            id: dot
            required property var modelData
            readonly property color fill: TagColors.at(Tokens, dot.modelData)

            width: root.size
            height: root.size

            Rectangle {
                anchors.fill: parent
                anchors.margins: -Tokens.appsBorderWidth
                radius: width / 2
                color: root.ringColor
            }

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: dot.fill
                border.width: Tokens.appsBorderWidth
                border.color: Qt.darker(dot.fill, Tokens.filesTagDotOutlineDarker)
            }
        }
    }
}
