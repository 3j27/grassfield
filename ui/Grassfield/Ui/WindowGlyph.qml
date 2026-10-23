import QtQuick
import QtQuick.Shapes

// The glyph of a window light (WindowControls): x (close), - (minimize), + (zoom) or the full-screen arrows, drawn as
// strokes that darken the light under them. Sizes follow the window.* tokens (the compositor plugin's titlebar draws the
// same glyphs).
Item {
    id: root

    // "close", "minimize", "plus" or "arrows".
    property string kind: "close"
    readonly property real box: Tokens.windowLightDiameter * Tokens.windowGlyphRatio
    readonly property real stroke: Math.max(1, Tokens.windowLightDiameter * Tokens.windowGlyphStroke)
    readonly property color ink: Appearance.withAlpha(Qt.rgba(0, 0, 0, 1), Tokens.windowGlyphOpacity)

    width: root.box
    height: root.box

    // x
    Rectangle {
        visible: root.kind === "close"
        anchors.centerIn: parent
        width: root.box * Math.SQRT2
        height: root.stroke
        rotation: 45
        color: root.ink
    }
    Rectangle {
        visible: root.kind === "close"
        anchors.centerIn: parent
        width: root.box * Math.SQRT2
        height: root.stroke
        rotation: -45
        color: root.ink
    }

    // - and the horizontal bar of +
    Rectangle {
        visible: root.kind === "minimize" || root.kind === "plus"
        anchors.centerIn: parent
        width: root.box
        height: root.stroke
        color: root.ink
    }

    // The vertical bar of +
    Rectangle {
        visible: root.kind === "plus"
        anchors.centerIn: parent
        width: root.stroke
        height: root.box
        color: root.ink
    }

    // Full-screen arrows: two triangles pointing at opposite corners.
    Shape {
        visible: root.kind === "arrows"
        anchors.fill: parent
        ShapePath {
            fillColor: root.ink
            strokeColor: "transparent"
            startX: 0
            startY: root.box
            PathLine {
                x: 0
                y: root.box * 0.3
            }
            PathLine {
                x: root.box * 0.7
                y: root.box
            }
        }
        ShapePath {
            fillColor: root.ink
            strokeColor: "transparent"
            startX: root.box
            startY: 0
            PathLine {
                x: root.box
                y: root.box * 0.7
            }
            PathLine {
                x: root.box * 0.3
                y: 0
            }
        }
    }
}
