pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Small glyphs drawn from rectangles (Grassfield's own, no icon assets): the view glyphs "icons" (2x2 grid), "list" (rows),
// "columns" (three panes) and "gallery" (a frame over a strip), at the sizes measured on Finder-Home; "more" (three dots), "plus",
// "group" (two groups: a rule over three small squares each; the Group By button, measured on Finder-Home).
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
                width: Tokens.filesViewGlyphStroke
                height: columnsBox.height
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
