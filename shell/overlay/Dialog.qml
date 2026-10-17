import QtQuick
import Grassfield.Ui

// Dialog frame on the material: title, optional message, custom content, button row.
// Esc emits rejected(). Hosts focus the preferred button themselves.
FocusScope {
    id: root

    property string title: ""
    property string message: ""
    property int panelWidth: Tokens.panelDialogWidth
    property alias content: contentColumn.data
    property alias buttons: buttonRow.data

    signal rejected

    readonly property real cornerRadius: Tokens.radiusDialog
    readonly property Item surface: material

    width: panelWidth
    height: column.implicitHeight + 2 * Tokens.spacingLg
    Accessible.role: Accessible.Dialog
    Accessible.name: root.title
    Accessible.description: root.message

    Keys.onEscapePressed: root.rejected()

    Material {
        id: material
        anchors.fill: parent
        radius: root.cornerRadius
    }

    Column {
        id: column
        x: Tokens.spacingLg
        y: Tokens.spacingLg
        width: root.width - 2 * Tokens.spacingLg
        spacing: Tokens.spacingMd

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.title
            visible: text !== ""
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
            wrapMode: Text.WordWrap
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.message
            visible: text !== ""
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            font.weight: Tokens.typographySmallWeight
            wrapMode: Text.WordWrap
        }

        Column {
            id: contentColumn
            width: parent.width
            spacing: Tokens.spacingSm
        }

        Row {
            id: buttonRow
            anchors.right: parent.right
            spacing: Tokens.spacingSm
        }
    }
}
