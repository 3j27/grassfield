import QtQuick
import QtQuick.Shapes

// The chevron of a toolbar's Back and Forward (macOS 27: 8 x 14 pt, a 1.5-pt round stroke; ss-004-005). Drawn, not a symbolic
// glyph: the glyph set's chevron is 4.3 x 8.7 pt at toolbar size and thickens when scaled. `forward` points it right.
Item {
    id: root

    property bool forward: false
    property color color: Appearance.colors.text

    implicitWidth: Tokens.toolbarNavChevronWidth
    implicitHeight: Tokens.toolbarNavChevronHeight
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    Shape {
        id: shape
        anchors.fill: parent
        // The stroke is inset by half its width so the 8 x 14 box holds the whole mark.
        readonly property real inset: Tokens.toolbarNavChevronStroke / 2
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: root.color
            strokeWidth: Tokens.toolbarNavChevronStroke
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: root.forward ? shape.inset : root.width - shape.inset
            startY: shape.inset
            PathLine {
                x: root.forward ? root.width - shape.inset : shape.inset
                y: root.height / 2
            }
            PathLine {
                x: root.forward ? shape.inset : root.width - shape.inset
                y: root.height - shape.inset
            }
        }
    }
}
