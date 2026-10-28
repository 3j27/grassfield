import QtQuick
import Grassfield.Ui

// A sheet that shows text to read or copy (spec SR19's Details: pacman's message and what to do; SR20's recovery of a
// lock pacman left): a title, a message, then the text in a read-only, selectable box that scrolls. One button, OK.
Sheet {
    id: root

    property string text: ""

    showCancel: false
    confirmText: qsTr("OK")

    function show(title: string, message: string, text: string): void {
        root.title = title;
        root.message = message;
        root.text = text;
        root.open();
    }

    Rectangle {
        width: parent.width
        visible: root.text !== ""
        height: Math.min(box.contentHeight + 2 * Tokens.spacingSm, Tokens.storeSheetListMaxRows * Tokens.storeSheetRowHeight)
        radius: Tokens.radiusControl
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

        Flickable {
            anchors.fill: parent
            anchors.margins: Tokens.spacingSm
            contentWidth: width
            contentHeight: box.contentHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar {}

            TextEdit {
                id: box
                width: parent.width
                readOnly: true
                selectByMouse: true
                textFormat: TextEdit.PlainText
                text: root.text
                wrapMode: TextEdit.WrapAnywhere
                color: Appearance.colors.text
                selectionColor: Appearance.highlight
                selectedTextColor: Appearance.highlightText
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.EditableText
                Accessible.name: root.title
                Accessible.readOnly: true
            }
        }
    }
}
