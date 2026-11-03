pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Pdf
import Grassfield.Ui

// Page thumbnails of the open PDF; clicking one goes to that page. The current page sits on a rounded accent plate with
// its number under it (macOS Preview).
ListView {
    id: root

    property var document: null
    property var pdfView: null

    clip: true
    spacing: Tokens.spacingSm
    model: root.document && root.document.status === PdfDocument.Ready ? root.document.pageCount : 0
    currentIndex: root.pdfView ? root.pdfView.currentPage : 0
    Accessible.role: Accessible.List
    Accessible.name: qsTr("Pages")

    onCurrentIndexChanged: root.positionViewAtIndex(root.currentIndex, ListView.Contain)

    // The overlay scroll bar every list of the apps shows (ADR-0039 step 16).
    ScrollBar.vertical: ScrollBar {}

    delegate: Item {
        id: cell

        required property int index
        readonly property size pageSize: root.document ? root.document.pagePointSize(cell.index) : Qt.size(1, 1)
        readonly property bool selected: cell.index === root.currentIndex
        // The accent plate while the window is key, a neutral one while it is not (macOS 27; ADR-0039 step 17).
        readonly property bool keyLook: Appearance.looksKey(root.Window.window, root.Window.active)

        width: root.width
        height: plate.height
        Accessible.role: Accessible.ListItem
        Accessible.name: qsTr("Page %1").arg(cell.index + 1)
        Accessible.selected: cell.selected

        // The plate (macOS Preview, gs-092-232): the page and its number on a rounded plate, filled in the selection colour for
        // the current page (the inactive selection while the window is not key), a light plate under the hovered one. Its size
        // is fixed by the tokens, not by the list's width: the list keeps its place when the sidebar is hidden and shown again.
        Rectangle {
            id: plate
            x: Tokens.spacingSm
            width: Tokens.previewThumbnailWidth + 2 * Tokens.previewPlatePad
            height: Tokens.previewPlatePad + thumb.height + Tokens.previewPlateCaption
            radius: Tokens.previewPlateRadius
            color: cell.selected ? (cell.keyLook ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.hover, Appearance.inactiveSelectionOpacity))
                : cellMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
        }

        // The page with its corners rounded (gs-092-232).
        Item {
            id: thumb
            x: plate.x + Tokens.previewPlatePad
            y: Tokens.previewPlatePad
            width: Tokens.previewThumbnailWidth
            height: Math.max(1, Math.round(width * cell.pageSize.height / Math.max(1, cell.pageSize.width)))
            layer.enabled: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: pageMask
            }

            Rectangle {
                id: pageMask
                anchors.fill: parent
                radius: Tokens.previewPageRadius
                visible: false
                layer.enabled: true
            }

            Rectangle {
                anchors.fill: parent
                color: Tokens.previewPaper
            }

            PdfPageImage {
                anchors.fill: parent
                document: root.document
                currentFrame: cell.index
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width
                sourceSize.height: height
            }
        }

        // The page number under the page, in the plate's strip: the selection text on the selection plate, the secondary
        // colour otherwise (the primary one on the hovered plate, which holds 4.5:1 there) (gs-092-232: 13-pt regular).
        Text {
            id: label
            anchors {
                top: thumb.bottom
                bottom: plate.bottom
                horizontalCenter: plate.horizontalCenter
            }
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: cell.index + 1
            color: cell.selected ? (cell.keyLook ? Appearance.colors.selectionText : Appearance.colors.text) : (cellMouse.containsMouse ? Appearance.colors.text : Appearance.windowSecondary)
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographySmallWeight
        }

        MouseArea {
            id: cellMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: if (root.pdfView) root.pdfView.goToPage(cell.index)
        }
    }
}
