import QtQuick
import Grassfield.Ui

// The header row of a pane's first group (macOS 27 Wi-Fi, Bluetooth): the pane's tile, its name, a line or two on what it is
// for, and the large switch that turns the device on or off. Placed by baselines, as measured
// (docs/audits/settings-parity-2026-10-26.md § Wi-Fi). The host owns the value: `checked` in, toggled(bool) out.
Item {
    id: root

    property string glyph: ""
    property string tileColor: "blue"
    property string title: ""
    property string text: ""
    property bool checked: false
    property bool switchEnabled: true
    // The text's size, line pitch, first baseline and bottom margin: Wi-Fi's (11 pt) by default; Bluetooth's is 12 pt.
    property int textSize: Tokens.typographyCaptionSize
    property real textLineHeight: Tokens.settingsHeaderRowTextLineHeight
    property real textBaseline: Tokens.settingsHeaderRowTextBaseline
    property real textBottom: Tokens.settingsHeaderRowBottom

    signal toggled(bool checked)

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    implicitHeight: Math.round(body.y + body.baselineOffset + (body.lineCount - 1) * root.textLineHeight + root.textBottom)
    Accessible.role: Accessible.Grouping
    Accessible.name: root.title
    Accessible.description: root.text

    Rectangle {
        id: tile
        x: Tokens.settingsRowInset
        y: Tokens.settingsHeaderRowTileTop
        width: Tokens.settingsHeaderRowTileSize
        height: width
        radius: Math.round(Tokens.settingsHeaderRowTileSize * Tokens.settingsNavTileRadius / Tokens.settingsNavTileSize)
        gradient: TileGradient {
            name: root.tileColor
        }

        Icon {
            anchors.centerIn: parent
            name: root.glyph
            size: Math.round(Tokens.settingsHeaderRowTileSize * Tokens.settingsNavGlyphSize / Tokens.settingsNavTileSize)
            color: Tokens.settingsSidebarTileGlyph
        }
    }

    Text {
        id: heading
        textFormat: Text.PlainText
        x: Tokens.settingsHeaderRowTextInset
        y: Tokens.settingsHeaderRowTitleBaseline - baselineOffset
        width: toggle.x - Tokens.settingsHeaderRowTextGap - x
        elide: Text.ElideRight
        text: root.title
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
    }

    Text {
        id: body
        textFormat: Text.PlainText
        x: Tokens.settingsHeaderRowTextInset
        y: root.textBaseline - baselineOffset
        width: toggle.x - Tokens.settingsHeaderRowTextGap - x
        wrapMode: Text.Wrap
        lineHeightMode: Text.FixedHeight
        lineHeight: root.textLineHeight
        // A line never breaks inside a hyphenated word ("Wi-Fi"): its hyphens are non-breaking ones (U+2011).
        text: root.text.replace(/-/g, "\u2011")
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: root.textSize
    }

    Toggle {
        id: toggle
        large: true
        x: root.width - width - Tokens.settingsRowInset
        y: Tokens.settingsHeaderRowSwitchTop
        accessibleName: root.title
        enabled: root.switchEnabled
        checked: root.checked
        onToggled: c => root.toggled(c)
    }
}
