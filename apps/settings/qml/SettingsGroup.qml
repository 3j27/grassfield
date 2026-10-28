import QtQuick
import Grassfield.Ui

// Rounded inset list: rows (SettingsRow, or any Item) are stacked with a separator between them, on a light group fill
// without a border (macOS 27). An optional caption (a bold section header) sits above the list, a footnote below it.
Item {
    id: root

    property string caption: ""
    // A line under the caption that says what the section is for (macOS 15 Login Items: "These items will open
    // automatically when you log in.").
    property string captionDetail: ""
    property string footnote: ""
    // Something of the section is under way (macOS 27 Wi-Fi > Other Networks while it scans): a spinner at the caption's right.
    property bool busy: false
    // No group fill: the rows are groups of their own (macOS 27 Network > Other Services).
    property bool plain: false
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

    Spinner {
        visible: captionText.visible && root.busy
        x: root.width - width - Tokens.settingsSpinnerInset
        // Centred on the caption's capitals.
        y: captionText.y + captionText.baselineOffset - captionMetrics.capitalHeight / 2 - height / 2
    }

    FontMetrics {
        id: captionMetrics
        font: captionText.font
    }

    Text {
        id: detailText
        textFormat: Text.PlainText
        visible: captionText.visible && root.captionDetail !== ""
        width: parent.width
        y: captionText.y + captionText.baselineOffset + (captionText.lineCount - 1) * captionText.contentHeight / Math.max(1, captionText.lineCount)
            + Tokens.settingsCaptionDetailGap - baselineOffset
        leftPadding: Tokens.settingsRowInset
        rightPadding: Tokens.settingsRowInset
        text: root.captionDetail
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.settingsCaptionDetailSize
        wrapMode: Text.Wrap
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.settingsCaptionDetailLineHeight
    }

    Rectangle {
        visible: !root.plain
        anchors.fill: column
        radius: Tokens.radiusMenu
        color: Appearance.colors.groupFill
        // Increase Contrast outlines the group; otherwise the fill alone separates it (macOS 27).
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Column {
        id: column
        // settingsCaptionToGroup below the baseline of the caption's last line (a long caption wraps), or of its explanation's.
        y: !captionText.visible ? 0 : detailText.visible
            ? Math.round(detailText.y + detailText.baselineOffset + (detailText.lineCount - 1) * detailText.contentHeight / Math.max(1, detailText.lineCount) + Tokens.settingsCaptionToGroup)
            : Math.round(root.captionBaseline + (captionText.lineCount - 1) * captionText.contentHeight / Math.max(1, captionText.lineCount) + Tokens.settingsCaptionToGroup)
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
