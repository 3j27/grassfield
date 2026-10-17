pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Pdf
import Grassfield.Ui

// Page thumbnails of the open PDF; clicking one goes to that page.
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

    delegate: Item {
        id: cell

        required property int index
        readonly property size pageSize: root.document ? root.document.pagePointSize(cell.index) : Qt.size(1, 1)

        width: root.width
        height: thumb.height + label.height + Tokens.spacingSm
        Accessible.role: Accessible.ListItem
        Accessible.name: qsTr("Page %1").arg(cell.index + 1)
        Accessible.selected: cell.index === root.currentIndex

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: thumb.width + 2 * Tokens.controlFocusRing
            height: thumb.height + 2 * Tokens.controlFocusRing
            y: -Tokens.controlFocusRing
            radius: Tokens.radiusControl
            color: "transparent"
            border.width: Tokens.controlFocusRing
            border.color: cell.index === root.currentIndex ? Appearance.colors.accent : "transparent"
        }

        Rectangle {
            anchors.fill: thumb
            color: Tokens.previewPaper
        }

        PdfPageImage {
            id: thumb
            anchors.horizontalCenter: parent.horizontalCenter
            document: root.document
            currentFrame: cell.index
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            width: Tokens.previewThumbnailWidth
            height: Math.max(1, Math.round(width * cell.pageSize.height / Math.max(1, cell.pageSize.width)))
            sourceSize.width: width
            sourceSize.height: height
        }

        Text {
            id: label
            anchors {
                top: thumb.bottom
                horizontalCenter: parent.horizontalCenter
            }
            textFormat: Text.PlainText
            text: cell.index + 1
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        MouseArea {
            anchors.fill: parent
            onClicked: if (root.pdfView) root.pdfView.goToPage(cell.index)
        }
    }
}
