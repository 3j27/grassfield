import QtQuick
import QtQuick.Shapes
import Grassfield.Ui

// Line glyphs of the Preview toolbar and sidebar, drawn as vector paths on a 24 x 24 grid (stroke 1.75, round caps, the
// same style as the Grassfield symbolic icons; the design system has no zoom, rotate or info icons yet). Own drawing,
// no icon assets. `kind` picks the glyph.
Item {
    id: root

    property string kind: "info"
    property color color: Appearance.colors.text
    property int size: Tokens.previewToolbarIconSize

    // One or two SVG path strings per glyph (24 x 24 grid).
    readonly property var paths: ({
        "sidebar": ["M5 5h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z", "M9.5 5v14"],
        "zoomIn": ["M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 1 0 0-13z", "M15.5 15.5 21 21", "M8 10.5h5M10.5 8v5"],
        "zoomOut": ["M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 1 0 0-13z", "M15.5 15.5 21 21", "M8 10.5h5"],
        "fit": ["M4 9V5h4M16 5h4v4M20 15v4h-4M8 19H4v-4", "M9.5 9.5h5v5h-5z"],
        "rotateLeft": ["M5.07 8A8 8 0 1 1 4 12", "M5 3.5V8h4.5"],
        "rotateRight": ["M18.93 8A8 8 0 1 0 20 12", "M19 3.5V8h-4.5"],
        "info": ["M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z", "M12 11v5.5", "M12 7.75v.01"],
        "chevronLeft": ["M14.5 5.5 8 12l6.5 6.5"],
        "chevronRight": ["M9.5 5.5 16 12l-6.5 6.5"],
        "close": ["M7 7l10 10M17 7 7 17"],
        "play": ["M8.5 5.5v13l10-6.5z"],
        "pause": ["M9 5.5v13M15 5.5v13"],
        "search": ["M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 1 0 0-13z", "M15.5 15.5 21 21"]
    })
    readonly property var shapePaths: root.paths[root.kind] ?? []

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Graphic
    Accessible.ignored: true

    Shape {
        width: 24
        height: 24
        scale: root.size / 24
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer

        // A glyph has at most three strokes (an empty path draws nothing).
        ShapePath {
            strokeColor: root.color
            strokeWidth: 1.75
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg {
                path: root.shapePaths[0] ?? ""
            }
        }
        ShapePath {
            strokeColor: root.color
            strokeWidth: 1.75
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg {
                path: root.shapePaths[1] ?? ""
            }
        }
        ShapePath {
            strokeColor: root.color
            strokeWidth: 1.75
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg {
                path: root.shapePaths[2] ?? ""
            }
        }
    }
}
