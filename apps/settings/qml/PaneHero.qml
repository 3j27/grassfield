import QtQuick
import Grassfield.Ui

// The header card of a hub pane (macOS 27 General): the pane's tile, its name in bold and what it holds, centred on a card
// with the group fill. Placed by baselines, as measured (docs/audits/settings-parity-2026-10-26.md § General).
Rectangle {
    id: root

    property string icon: ""
    property string tileColor: "graphite"
    property string title: ""
    property string text: ""

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    implicitHeight: Math.round(body.y + body.baselineOffset + (body.lineCount - 1) * Tokens.settingsHeroTextLineHeight + Tokens.settingsHeroBottom)
    radius: Tokens.radiusGroup
    color: Appearance.colors.groupFill
    // Increase Contrast outlines the card, as it does the groups (SettingsGroup).
    border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
    border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    Accessible.role: Accessible.Grouping
    Accessible.name: root.title
    Accessible.description: root.text

    Rectangle {
        id: tile
        x: Math.round((root.width - width) / 2)
        y: Tokens.settingsHeroIconTop
        width: Tokens.settingsHeroIconSize
        height: width
        radius: Tokens.settingsHeroIconRadius
        color: Tokens.colorAccentLight[root.tileColor] || Tokens.colorAccentLight.graphite

        Icon {
            anchors.centerIn: parent
            name: root.icon
            size: Tokens.settingsHeroGlyphSize
            color: Tokens.settingsSidebarTileGlyph
        }
    }

    Text {
        id: heading
        textFormat: Text.PlainText
        x: Tokens.settingsHeroTextInset
        y: Tokens.settingsHeroTitleBaseline - baselineOffset
        width: root.width - 2 * Tokens.settingsHeroTextInset
        horizontalAlignment: Text.AlignHCenter
        text: root.title
        elide: Text.ElideRight
        color: Appearance.colors.text
        font.family: Appearance.fontFamilyFor(Tokens.settingsHeroTitleSize)
        font.pixelSize: Tokens.settingsHeroTitleSize
        font.weight: Tokens.typographyMenuBoldWeight
        font.letterSpacing: Appearance.trackingFor(Tokens.settingsHeroTitleSize)
        Accessible.role: Accessible.Heading
        Accessible.name: root.title
    }

    Text {
        id: body
        textFormat: Text.PlainText
        x: Tokens.settingsHeroTextInset
        // The text's first baseline its measured gap under the title's, the gap growing with Text size as the text does
        // (ADR-0039 step 18); the tile and the title's baseline stay.
        y: Tokens.settingsHeroTitleBaseline + (Tokens.settingsHeroTextBaseline - Tokens.settingsHeroTitleBaseline) * Appearance.textScale - baselineOffset
        width: root.width - 2 * Tokens.settingsHeroTextInset
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        lineHeightMode: Text.FixedHeight
        lineHeight: Tokens.settingsHeroTextLineHeight
        text: root.text
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.settingsHeroTextSize
    }
}
