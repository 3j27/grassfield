pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TagColors.js" as TagColors

// The colour tags of an item as small overlapping dots (at most Tokens.filesTagDotsMax), each ringed with the
// background colour so stacked dots stay apart. `colors`: palette indices (role tagColors).
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

        delegate: Rectangle {
            required property var modelData

            width: root.size
            height: root.size
            radius: root.size / 2
            color: TagColors.at(Tokens, modelData)
            border.width: Tokens.appsBorderWidth
            border.color: root.ringColor
        }
    }
}
