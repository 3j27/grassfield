pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Pdf
import Grassfield.Ui

// Page thumbnails of the open PDF; clicking one goes to that page. The current page sits on a rounded accent plate with
// its number (macOS Preview).
ListView {
    id: root

    property var document: null
    property var pdfView: null

    clip: true
    spacing: Tokens.spacingXs
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

        width: root.width
        height: thumb.height + label.height + 3 * Tokens.spacingSm
        Accessible.role: Accessible.ListItem
        Accessible.name: qsTr("Page %1").arg(cell.index + 1)
        Accessible.selected: cell.selected

        Rectangle {
            anchors.fill: parent
            radius: Tokens.radiusMenu
            color: cellMouse.containsMouse && !cell.selected ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
        }

        Rectangle {
            anchors.fill: thumb
            color: Tokens.previewPaper
        }

        PdfPageImage {
            id: thumb
            y: Tokens.spacingSm
            anchors.horizontalCenter: parent.horizontalCenter
            document: root.document
            currentFrame: cell.index
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            width: Math.min(Tokens.previewThumbnailWidth, root.width - 2 * Tokens.spacingSm)
            height: Math.max(1, Math.round(width * cell.pageSize.height / Math.max(1, cell.pageSize.width)))
            sourceSize.width: width
            sourceSize.height: height
        }

        // The current page: a ring in the accent colour around its thumbnail (macOS Preview), not a solid plate.
        Rectangle {
            anchors {
                fill: thumb
                margins: -Tokens.controlFocusOutline
            }
            visible: cell.selected
            color: "transparent"
            radius: Tokens.radiusControl
            border.width: Tokens.controlFocusOutline
            // The accent while the window is key, neutral while it is not (macOS 27; ADR-0039 step 17).
            border.color: root.Window.active ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.text, Appearance.inactiveTextOpacity)
        }

        Text {
            id: label
            anchors {
                top: thumb.bottom
                topMargin: Tokens.spacingXs
                horizontalCenter: parent.horizontalCenter
            }
            textFormat: Text.PlainText
            text: cell.index + 1
            color: cell.selected ? Appearance.colors.text : Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        MouseArea {
            id: cellMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: if (root.pdfView) root.pdfView.goToPage(cell.index)
        }
    }
}
