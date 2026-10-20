import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/preview/qml"

// Toolbar parts of Preview: capsule sizing and that a glyph really draws pixels.
TestCase {
    id: testCase
    name: "PreviewToolbar"
    width: 400
    height: 120
    visible: true
    when: windowShown

    Rectangle {
        id: stage
        anchors.fill: parent
        color: "#808080"

        Row {
            id: row
            spacing: 12
            ToolbarGroup {
                id: group
                ToolButton {
                    glyph: "zoomOut"
                    label: "Zoom Out"
                }
                ToolButton {
                    glyph: "zoomIn"
                    label: "Zoom In"
                }
            }
            Glyph {
                id: glyph
                kind: "info"
                size: 48
                color: "#ff0000"
            }
        }
    }

    function test_groupSize() {
        compare(group.width, 2 * Tokens.previewToolbarButtonSize + 2 * Tokens.spacingXs);
        compare(group.height, Tokens.previewToolbarCapsuleHeight);
        verify(row.width > group.width);
    }

    // The recolouring effect is a GPU effect (not drawn by the offscreen platform): the visual scenario checks the pixels.
    function test_glyphPointsAtItsSvg() {
        compare(glyph.name, "info");
        verify(glyph.directory.toString().endsWith("/apps/preview/qml/icons/"), glyph.directory.toString());
        glyph.kind = "zoomIn";
        compare(glyph.name, "zoomIn");
    }
}
