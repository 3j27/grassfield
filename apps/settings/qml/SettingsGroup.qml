import QtQuick
import Grassfield.Ui

// Rounded inset list: rows (SettingsRow, or any Item) are stacked with a separator between them.
// An optional caption sits above the list, a footnote below it.
Item {
    id: root

    property string caption: ""
    property string footnote: ""
    default property alias rows: column.data

    width: parent ? parent.width : implicitWidth
    implicitHeight: captionText.height + column.height + footnoteText.height
    implicitWidth: Tokens.settingsContentMaxWidth
    Accessible.role: Accessible.Grouping
    Accessible.name: root.caption

    Text {
        id: captionText
        textFormat: Text.PlainText
        visible: root.caption !== ""
        height: visible ? implicitHeight + Tokens.spacingSm : 0
        width: parent.width
        leftPadding: Tokens.spacingMd
        text: root.caption
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        font.weight: Tokens.typographyMenuBoldWeight
        wrapMode: Text.Wrap
    }

    Rectangle {
        anchors.fill: column
        radius: Tokens.radiusMenu
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
        border.width: 1
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Column {
        id: column
        y: captionText.height
        width: parent.width
    }

    Text {
        id: footnoteText
        textFormat: Text.PlainText
        visible: root.footnote !== ""
        y: captionText.height + column.height
        height: visible ? implicitHeight + Tokens.spacingSm : 0
        topPadding: Tokens.spacingXs
        width: parent.width
        leftPadding: Tokens.spacingMd
        rightPadding: Tokens.spacingMd
        text: root.footnote
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        wrapMode: Text.Wrap
    }
}
