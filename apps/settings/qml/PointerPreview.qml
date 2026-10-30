import QtQuick
import QtQuick.Shapes
import Grassfield.Ui

// The pointer arrow of the Grassfield cursor theme (branding/cursors/src/arrow.svg.in, 32 unit grid) in the chosen
// outline and fill colours: a live preview next to the colour wells. The outline is the arrow stroked 3 units wide with
// round joins in the outline colour, the fill is the arrow itself on top, as in the SVG.
Item {
    id: root

    property string outlineColor: PointerColors.DEFAULT_OUTLINE
    property string fillColor: PointerColors.DEFAULT_FILL
    // Edge of the 32 unit grid of the cursor sources.
    readonly property real grid: 32
    readonly property string arrow: "M5 3 L5 24.2 L10.1 19.6 L13.5 27.2 L17.3 25.6 L13.9 18.1 L20.6 18.1 Z"

    implicitWidth: Tokens.settingsPointerPreviewSize
    implicitHeight: Tokens.settingsPointerPreviewSize
    Accessible.role: Accessible.Graphic
    Accessible.name: qsTr("Pointer preview")
    Accessible.description: qsTr("Outline %1, fill %2").arg(root.outlineColor).arg(root.fillColor)

    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
    }

    Shape {
        width: root.grid
        height: root.grid
        scale: root.width / root.grid
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: root.outlineColor
            strokeColor: root.outlineColor
            strokeWidth: 3 // literal-ok geometry: the cursor source's own stroke, in its 32-unit grid (arrow.svg.in)
            joinStyle: ShapePath.RoundJoin
            PathSvg {
                path: root.arrow
            }
        }

        ShapePath {
            fillColor: root.fillColor
            strokeColor: "transparent"
            strokeWidth: -1
            PathSvg {
                path: root.arrow
            }
        }
    }
}
