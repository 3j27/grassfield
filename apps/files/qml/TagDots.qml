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
    property color ringColor: Appearance.windowFill

    readonly property var shown: root.firstColors(root.colors)

    // The first Tokens.filesTagDotsMax palette indices of a list. A JS array from the model, or a ListModel (a QML model
    // hands a list role back as one) or nothing: never a TypeError (GF-073).
    function firstColors(list: var): var {
        const out = [];
        if (list === undefined || list === null)
            return out;
        const n = Array.isArray(list) ? list.length : (typeof list.count === "number" ? list.count : (typeof list.length === "number" ? list.length : 0));
        for (let i = 0; i < n && out.length < Tokens.filesTagDotsMax; i++) {
            const v = Array.isArray(list) ? list[i] : (typeof list.get === "function" ? list.get(i) : list[i]);
            const idx = typeof v === "object" && v !== null ? v.modelData ?? v.color ?? v.index ?? v : v;
            // Palette indices only (the delegate takes an int): anything else a role could hold is skipped, not a TypeError.
            if (typeof idx === "number" && Number.isInteger(idx))
                out.push(idx);
        }
        return out;
    }

    visible: root.shown.length > 0
    spacing: -Tokens.filesTagDotOverlap
    Accessible.ignored: true

    Repeater {
        model: root.shown

        delegate: Item {
            id: dot
            required property int modelData
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
