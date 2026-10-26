import QtQuick
import Grassfield.Ui

// Rounded inset list: rows (SettingsRow, or any Item) are stacked with a separator between them, on a light group fill
// without a border (macOS 27). An optional caption (a bold section header) sits above the list, a footnote below it.
Item {
    id: root

    property string caption: ""
    property string footnote: ""
    default property alias rows: column.data

    width: parent ? parent.width : implicitWidth
    // A hidden Text keeps its implicit height, so only visible captions and footnotes count.
    implicitHeight: column.y + column.height + (footnoteText.visible ? footnoteText.height : 0)
    // The caption's baseline (macOS 27): 13 below the pane's content top for the first group, 43 below the previous group's end
    // otherwise (the page's column already puts settingsGroupGap between them); its group starts 13 below it.
    readonly property real captionBaseline: root.Positioner.index > 0 ? Tokens.settingsCaptionGap - Tokens.settingsGroupGap : Tokens.settingsCaptionFirstBaseline
    implicitWidth: Tokens.settingsContentMaxWidth
    Accessible.role: Accessible.Grouping
    Accessible.name: root.caption

    Text {
        id: captionText
        textFormat: Text.PlainText
        visible: root.caption !== ""
        width: parent.width
        y: root.captionBaseline - baselineOffset
        leftPadding: Tokens.settingsRowInset
        text: root.caption
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        font.weight: Tokens.typographyMenuBoldWeight
        wrapMode: Text.Wrap
    }

    Rectangle {
        anchors.fill: column
        radius: Tokens.radiusMenu
        color: Appearance.colors.groupFill
        // Increase Contrast outlines the group; otherwise the fill alone separates it (macOS 27).
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Column {
        id: column
        // settingsCaptionToGroup below the baseline of the caption's last line (a long caption wraps).
        y: captionText.visible ? Math.round(root.captionBaseline + (captionText.lineCount - 1) * captionText.contentHeight / Math.max(1, captionText.lineCount) + Tokens.settingsCaptionToGroup) : 0
        width: parent.width
    }

    Text {
        id: footnoteText
        textFormat: Text.PlainText
        visible: root.footnote !== ""
        y: column.y + column.height
        topPadding: Tokens.spacingXs
        bottomPadding: Tokens.spacingSm
        width: parent.width
        leftPadding: Tokens.settingsRowInset
        rightPadding: Tokens.settingsRowInset
        text: root.footnote
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        wrapMode: Text.Wrap
    }
}
