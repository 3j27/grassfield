pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Plain text and code, read only. The text is always PlainText (never interpreted as markup).
Item {
    id: root

    property var info: ({})
    property int fileIndex: 0

    readonly property bool canZoom: true
    readonly property bool canRotate: false
    readonly property bool canSearch: false
    readonly property string zoomLabel: Math.round(root.factor * 100) + "%"
    readonly property int pageCount: 1
    property int currentPage: 0
    property real factor: 1
    // Edit menu (GlobalMenu.qml): the selection of the text.
    readonly property bool canCopy: edit.selectedText !== ""
    readonly property bool canSelectAll: edit.length > 0

    Accessible.role: Accessible.Document
    Accessible.name: qsTr("Text %1").arg(root.info.name ?? "")

    function copy(): void {
        edit.copy();
    }
    function selectAll(): void {
        edit.selectAll();
    }

    function zoomIn(): void {
        root.factor = Math.min(Tokens.previewZoomMax, root.factor * Tokens.previewZoomStep);
    }
    function zoomOut(): void {
        root.factor = Math.max(Tokens.previewZoomMin, root.factor / Tokens.previewZoomStep);
    }
    function fit(): void {
        root.factor = 1;
    }
    function actualSize(): void {
        root.factor = 1;
    }
    function rotate(direction: int): void {
    }
    function goToPage(page: int): void {
    }

    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: edit.height + 2 * Tokens.spacingMd
        flickableDirection: Flickable.VerticalFlick
        focus: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                const step = (event.key === Qt.Key_Down ? 1 : -1) * Tokens.previewCodeFontSize * 3;
                flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + step));
                event.accepted = true;
            } else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp) {
                const page = (event.key === Qt.Key_PageDown ? 1 : -1) * flick.height * 0.9;
                flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, flick.contentY + page));
                event.accepted = true;
            }
        }

        TextEdit {
            id: edit
            x: Tokens.spacingMd
            y: Tokens.spacingMd
            width: flick.width - 2 * Tokens.spacingMd
            readOnly: true
            selectByMouse: true
            // The selection survives the global menu taking the keyboard (Edit > Copy acts on it).
            persistentSelection: true
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
            text: root.info.text ?? ""
            color: Appearance.colors.text
            selectedTextColor: Appearance.colors.accentText
            selectionColor: Appearance.colors.accent
            font.family: Tokens.typographyMonoFamily
            font.pixelSize: Tokens.previewCodeFontSize * root.factor
        }
    }
}
