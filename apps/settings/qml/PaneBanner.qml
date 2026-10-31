import QtQuick
import Grassfield.Ui

// The header card of a pane (macOS 27 Notifications, Accessibility; General's hub has PaneHero): the pane's tile on the
// left, its name and what it holds beside it, on a card with the group fill. Placed by baselines, as measured
// (docs/audits/settings-parity-2026-10-26.md § Notifications). The text wraps.
Rectangle {
    id: root

    property string icon: ""
    property string tileColor: "graphite"
    property string title: ""
    property string text: ""

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    implicitHeight: Math.round(body.y + body.baselineOffset + (body.lineCount - 1) * Tokens.settingsBannerTextLineHeight + Tokens.settingsBannerBottom)
    radius: Tokens.radiusGroup
    color: Appearance.colors.groupFill
    // Increase Contrast outlines the card, as it does the groups (SettingsGroup).
    border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
    border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    Accessible.role: Accessible.Grouping
    Accessible.name: root.title
    Accessible.description: root.text

    Rectangle {
        x: Tokens.settingsBannerTileX
        y: Tokens.settingsBannerTileTop
        width: Tokens.settingsBannerTileSize
        height: width
        radius: Math.round(width * Tokens.settingsNavTileRadius / Tokens.settingsNavTileSize)
        color: Tokens.colorAccentLight[root.tileColor] || Tokens.colorAccentLight.graphite

        Icon {
            anchors.centerIn: parent
            name: root.icon
            size: Math.round(Tokens.settingsBannerTileSize * Tokens.settingsNavGlyphSize / Tokens.settingsNavTileSize)
            color: Tokens.settingsSidebarTileGlyph
        }
    }

    Text {
        textFormat: Text.PlainText
        x: Tokens.settingsBannerTextX
        y: Tokens.settingsBannerTitleBaseline - baselineOffset
        width: root.width - x - Tokens.settingsRowInset
        text: root.title
        elide: Text.ElideRight
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Text {
        id: body
        textFormat: Text.PlainText
        x: Tokens.settingsBannerTextX
        y: Tokens.settingsBannerTextBaseline - baselineOffset
        width: root.width - x - Tokens.settingsRowInset
        text: root.text
        wrapMode: Text.Wrap
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.settingsBannerTextLineHeight
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.settingsCaptionDetailSize
    }
}
