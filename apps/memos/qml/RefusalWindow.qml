import QtQuick
import Grassfield.Ui

// The store cannot be written by this build (ADR-0051 D-3): a newer schema, or an I/O error. No memo opens and nothing is
// written; this window says so and quits. It keeps the compositor's titlebar (no chrome role).
Window {
    id: win

    // "newer" or "unreadable" (MemosApp.refusal).
    required property string reason

    title: qsTr("Memos")
    width: Tokens.panelDialogWidth
    height: content.implicitHeight + 2 * Tokens.spacingLg
    minimumWidth: Tokens.panelDialogWidth
    minimumHeight: content.implicitHeight + 2 * Tokens.spacingLg
    color: Appearance.windowFill
    visible: true

    onClosing: Qt.quit()

    Column {
        id: content
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: Tokens.spacingLg
        }
        spacing: Tokens.spacingMd

        Text {
            width: parent.width
            text: win.reason === "newer" ? qsTr("Your memos were saved by a newer version of Memos.") : qsTr("Memos can't read your memos.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographyTitleWeight
        }

        Text {
            width: parent.width
            text: win.reason === "newer" ? qsTr("Nothing was changed. Open them with that version.")
                                         : qsTr("Nothing was changed. Check that the memos folder can be read, then open Memos again.")
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        Button {
            anchors.right: parent.right
            primary: true
            push: true
            text: qsTr("Quit")
            onClicked: Qt.quit()
        }
    }
}
