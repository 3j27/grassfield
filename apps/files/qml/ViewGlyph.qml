pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Grassfield.Ui

// Small glyphs drawn from rectangles (Grassfield's own, no icon assets): the view glyphs "icons" (2x2 grid), "list" (rows),
// "columns" (three panes) and "gallery" (a frame over a strip), at the sizes measured on Finder-Home; "more" (three dots), "plus",
// "group" (two groups: a rule over three small squares each; the Group By button, measured on Finder-Home), "tag" (a tag
// outline turned 45 degrees with its hole; the Tags button, measured on Finder-Search: 18 pt).
Item {
    id: root

    property string kind: "icons"
    property color color: Appearance.glyphTint(root)
    property int size: Tokens.filesToolbarIconSize

    readonly property real stroke: Math.max(1, Math.round(root.size / 10))

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    // icons: four outlined rounded squares (the view glyphs are measured on Finder-Home: Tokens.filesView*)
    Grid {
        visible: root.kind === "icons"
        anchors.centerIn: parent
        columns: 2
        spacing: Tokens.filesViewIconsGap
        Repeater {
            model: 4
            Rectangle {
                width: Tokens.filesViewIconsSquare
                height: width
                radius: Tokens.filesViewGlyphRadius
                color: "transparent"
                border.width: Tokens.filesViewGlyphStroke
                border.color: root.color
            }
        }
    }

    // list: a bullet and a line per row
    Column {
        visible: root.kind === "list"
        anchors.centerIn: parent
        spacing: Tokens.filesViewListPitch - Tokens.filesViewListBullet
        Repeater {
            model: 3
            Row {
                spacing: Tokens.filesViewListGap
                Rectangle {
                    width: Tokens.filesViewListBullet
                    height: width
                    radius: width / 2
                    color: root.color
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Tokens.filesViewListLine
                    height: Tokens.filesViewListThickness
                    radius: height / 2
                    color: root.color
                }
            }
        }
    }

    // columns: an outlined frame in three panes
    Rectangle {
        id: columnsBox
        visible: root.kind === "columns"
        anchors.centerIn: parent
        width: Tokens.filesViewColumnsWidth
        height: Tokens.filesViewColumnsHeight
        radius: Tokens.filesViewGlyphFrameRadius
        color: "transparent"
        border.width: Tokens.filesViewGlyphStroke
        border.color: root.color
        Repeater {
            model: 2
            Rectangle {
                required property int index
                // The dividers split the inside of the frame in three.
                x: Tokens.filesViewGlyphStroke + (columnsBox.width - 2 * Tokens.filesViewGlyphStroke) * (index + 1) / 3 - width / 2
                // Inside the frame's outline: the parts never overlap, so a translucent glyph colour never draws darker.
                y: Tokens.filesViewGlyphStroke
                width: Tokens.filesViewGlyphStroke
                height: columnsBox.height - 2 * Tokens.filesViewGlyphStroke
                color: root.color
            }
        }
    }

    // gallery: an outlined frame over a strip of small cells
    Column {
        visible: root.kind === "gallery"
        anchors.centerIn: parent
        spacing: Tokens.filesViewGalleryGap
        Rectangle {
            width: Tokens.filesViewGalleryWidth
            height: Tokens.filesViewGalleryFrameHeight
            radius: Tokens.filesViewGlyphFrameRadius
            color: "transparent"
            border.width: Tokens.filesViewGlyphStroke
            border.color: root.color
        }
        Row {
            spacing: (Tokens.filesViewGalleryWidth - Tokens.filesViewGalleryCells * Tokens.filesViewGalleryCellWidth) / (Tokens.filesViewGalleryCells - 1)
            Repeater {
                model: Tokens.filesViewGalleryCells
                Rectangle {
                    width: Tokens.filesViewGalleryCellWidth
                    height: Tokens.filesViewGalleryCellHeight
                    color: root.color
                }
            }
        }
    }

    // group: rule, three squares, rule, three squares
    Column {
        visible: root.kind === "group"
        anchors.centerIn: parent
        spacing: Tokens.filesGroupGlyphGap

        Repeater {
            model: 2

            Column {
                spacing: Tokens.filesGroupGlyphGap

                Rectangle {
                    width: Tokens.filesGroupGlyphWidth
                    height: Tokens.filesGroupGlyphRule
                    radius: height / 2
                    color: root.color
                }

                Row {
                    spacing: (Tokens.filesGroupGlyphWidth - 3 * Tokens.filesGroupGlyphSquare) / 2

                    Repeater {
                        model: 3

                        Rectangle {
                            width: Tokens.filesGroupGlyphSquare
                            height: width
                            radius: Tokens.filesGroupGlyphStroke
                            color: "transparent"
                            border.width: Tokens.filesGroupGlyphStroke
                            border.color: root.color
                        }
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

    // plus: one outline (a cross with round ends), so the arms never overlap and a translucent glyph colour never draws darker.
    Shape {
        id: plusShape
        visible: root.kind === "plus"
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        readonly property real h: root.stroke * 0.75
        readonly property real a: root.size * 0.375
        readonly property real cx: width / 2
        readonly property real cy: height / 2

        ShapePath {
            fillColor: root.color
            strokeWidth: -1
            startX: plusShape.cx - plusShape.h
            startY: plusShape.cy - plusShape.h
            PathLine { x: plusShape.cx - plusShape.h; y: plusShape.cy - plusShape.a + plusShape.h }
            PathArc { x: plusShape.cx + plusShape.h; y: plusShape.cy - plusShape.a + plusShape.h; radiusX: plusShape.h; radiusY: plusShape.h }
            PathLine { x: plusShape.cx + plusShape.h; y: plusShape.cy - plusShape.h }
            PathLine { x: plusShape.cx + plusShape.a - plusShape.h; y: plusShape.cy - plusShape.h }
            PathArc { x: plusShape.cx + plusShape.a - plusShape.h; y: plusShape.cy + plusShape.h; radiusX: plusShape.h; radiusY: plusShape.h }
            PathLine { x: plusShape.cx + plusShape.h; y: plusShape.cy + plusShape.h }
            PathLine { x: plusShape.cx + plusShape.h; y: plusShape.cy + plusShape.a - plusShape.h }
            PathArc { x: plusShape.cx - plusShape.h; y: plusShape.cy + plusShape.a - plusShape.h; radiusX: plusShape.h; radiusY: plusShape.h }
            PathLine { x: plusShape.cx - plusShape.h; y: plusShape.cy + plusShape.h }
            PathLine { x: plusShape.cx - plusShape.a + plusShape.h; y: plusShape.cy + plusShape.h }
            PathArc { x: plusShape.cx - plusShape.a + plusShape.h; y: plusShape.cy - plusShape.h; radiusX: plusShape.h; radiusY: plusShape.h }
            PathLine { x: plusShape.cx - plusShape.h; y: plusShape.cy - plusShape.h }
        }
    }

    // tag: a tag lying along the diagonal, its chamfered head up and to the right, the hole near the head.
    Shape {
        visible: root.kind === "tag"
        anchors.centerIn: parent
        width: root.size
        height: root.size
        rotation: -45
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: root.color
            strokeWidth: Tokens.filesViewGlyphStroke
            fillColor: "transparent"
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.RoundCap
            startX: 0.16 * root.size
            startY: 0.29 * root.size
            PathLine { x: 0.70 * root.size; y: 0.29 * root.size }
            PathLine { x: 0.94 * root.size; y: 0.43 * root.size }
            PathLine { x: 0.94 * root.size; y: 0.57 * root.size }
            PathLine { x: 0.70 * root.size; y: 0.71 * root.size }
            PathLine { x: 0.16 * root.size; y: 0.71 * root.size }
            PathArc { x: 0.06 * root.size; y: 0.61 * root.size; radiusX: 0.1 * root.size; radiusY: 0.1 * root.size }
            PathLine { x: 0.06 * root.size; y: 0.39 * root.size }
            PathArc { x: 0.16 * root.size; y: 0.29 * root.size; radiusX: 0.1 * root.size; radiusY: 0.1 * root.size }
        }

        Rectangle {
            x: 0.74 * root.size - width / 2
            y: 0.5 * root.size - height / 2
            width: Tokens.filesViewGlyphStroke * 1.5
            height: width
            radius: width / 2
            color: root.color
        }
    }
}
