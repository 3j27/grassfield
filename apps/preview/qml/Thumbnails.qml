pragma ComponentBehavior: Bound
import QtQuick
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

        // The plate (macOS Preview, gs-092-232): the page and its number on a rounded plate, filled in the accent for the
        // current page, a light plate under the hovered one.
        Rectangle {
            id: plate
            x: Tokens.spacingSm
            width: root.width - 2 * Tokens.spacingSm
            height: Tokens.previewPlatePad + thumb.height + Tokens.previewPlateCaption
            radius: Tokens.previewPlateRadius
            color: cell.selected ? (cell.keyLook ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.filesSidebarSelectionOpacity))
                : cellMouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
        }

        Rectangle {
            anchors.fill: thumb
            color: Tokens.previewPaper
        }

        PdfPageImage {
            id: thumb
            y: Tokens.previewPlatePad
            anchors.horizontalCenter: parent.horizontalCenter
            document: root.document
            currentFrame: cell.index
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            width: Math.min(Tokens.previewThumbnailWidth, plate.width - 2 * Tokens.previewPlatePad)
            height: Math.max(1, Math.round(width * cell.pageSize.height / Math.max(1, cell.pageSize.width)))
            sourceSize.width: width
            sourceSize.height: height
        }

        // The page number under the page, in the plate's strip: white (the accent's text) on the accent plate, the secondary
        // colour otherwise (gs-092-232: 13-pt regular).
        Text {
            id: label
            anchors {
                top: thumb.bottom
                bottom: plate.bottom
                horizontalCenter: parent.horizontalCenter
            }
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: cell.index + 1
            color: cell.selected ? (cell.keyLook ? Appearance.colors.accentText : Appearance.colors.text) : Appearance.windowSecondary
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
