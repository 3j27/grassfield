import QtQuick
import Grassfield.Ui

// Centered notice in place of a view (nothing to show, file too large, unsupported, error).
Item {
    id: root

    property string title: ""
    property string text: ""

    Accessible.role: Accessible.StaticText
    Accessible.name: root.title !== "" ? root.title + ". " + root.text : root.text

    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 2 * Tokens.spacingLg, Tokens.panelDialogWidth)
        spacing: Tokens.spacingSm

        Text {
            width: parent.width
            visible: root.title !== ""
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: root.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
        }

        Text {
            width: parent.width
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: root.text
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }
}
