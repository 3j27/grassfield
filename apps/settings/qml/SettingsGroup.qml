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
    implicitWidth: Tokens.settingsContentMaxWidth
    Accessible.role: Accessible.Grouping
    Accessible.name: root.caption

    Text {
        id: captionText
        textFormat: Text.PlainText
        visible: root.caption !== ""
        width: parent.width
        leftPadding: Tokens.settingsRowInset
        // The gap below is padding, not a height bound to implicitHeight: that self-reference looped on rewraps
        // (real session 2026-10-22, "Binding loop detected for property height").
        bottomPadding: Tokens.spacingSm
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
        y: captionText.visible ? captionText.height : 0
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
