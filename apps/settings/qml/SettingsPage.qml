import QtQuick
import Grassfield.Ui

// Scrolling detail pane: a large title, then groups stacked with groupGap.
Flickable {
    id: root

    property string title: ""
    default property alias groups: column.data

    contentWidth: width
    contentHeight: column.height + 2 * Tokens.spacingLg + Tokens.spacingLg
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    Accessible.role: Accessible.Pane
    Accessible.name: root.title

    Column {
        id: column
        x: Math.max(Tokens.spacingLg, (root.width - width) / 2)
        y: Tokens.spacingLg
        width: Math.min(Tokens.settingsContentMaxWidth, root.width - 2 * Tokens.spacingLg)
        spacing: Tokens.settingsGroupGap

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.settingsPageTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
            Accessible.role: Accessible.Heading
            Accessible.name: root.title
        }
    }
}
