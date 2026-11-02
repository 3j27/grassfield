import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// One service of the Network pane (macOS 27): a group of its own with the service's tile, its name, a status line (a coloured
// dot, the state in the secondary colour) and a chevron when it opens something. A click, Space or Return opens it (clicked).
// Placed as measured (docs/audits/settings-parity-2026-10-26.md § Network and VPN).
T.AbstractButton {
    id: root

    property string glyph: ""
    property string tileColor: "blue"
    property string status: ""
    property color dotColor: Appearance.windowSecondary
    // Whether it opens something (the chevron, and the button itself).
    property bool opens: true

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    implicitHeight: Tokens.settingsServiceRowHeight
    focusPolicy: root.opens ? Qt.StrongFocus : Qt.NoFocus
    hoverEnabled: true
    Accessible.role: root.opens ? Accessible.Button : Accessible.StaticText
    Accessible.name: root.text + ", " + root.status
    Accessible.onPressAction: if (root.visible && root.enabled && root.opens)
        root.clicked()

    Keys.onPressed: event => {
        if (!ActivationKeys.activation(event.key))
            return;
        if (root.visible && root.enabled && root.opens)
            root.clicked();
        event.accepted = true;
    }

    background: Rectangle {
        radius: Tokens.radiusGroup
        color: Appearance.colors.groupFill
        // Increase Contrast outlines the group, as SettingsGroup does.
        border.width: Appearance.increaseContrast ? Tokens.controlBorderWidth : 0
        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)

        // Held down: the group darkens, as macOS does while the pointer holds it.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
            visible: root.down && root.opens
        }

        // Keyboard focus only (never after a click).
        FocusRing {
            shapeRadius: Tokens.radiusGroup
            visible: root.visualFocus
        }
    }

    contentItem: Item {
        Rectangle {
            x: Tokens.settingsRowInset
            y: Tokens.settingsHeaderRowTileTop
            width: Tokens.settingsHeaderRowTileSize
            height: width
            radius: Math.round(Tokens.settingsHeaderRowTileSize * Tokens.settingsNavTileRadius / Tokens.settingsNavTileSize)
            color: Tokens.colorAccentLight[root.tileColor] || Tokens.colorAccentLight.graphite

            Icon {
                anchors.centerIn: parent
                name: root.glyph
                size: Math.round(Tokens.settingsHeaderRowTileSize * Tokens.settingsNavGlyphSize / Tokens.settingsNavTileSize)
                color: Tokens.settingsSidebarTileGlyph
            }
        }

        Text {
            textFormat: Text.PlainText
            x: Tokens.settingsHeaderRowTextInset
            y: Tokens.settingsHeaderRowTitleBaseline - baselineOffset
            width: chevron.x - Tokens.spacingSm - x
            elide: Text.ElideRight
            text: root.text
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Rectangle {
            x: Tokens.settingsServiceDotInset
            // Centred on the status text's capitals.
            y: statusText.y + statusText.baselineOffset - statusMetrics.capitalHeight / 2 - height / 2
            width: Tokens.settingsServiceDotSize
            height: width
            radius: width / 2
            color: root.dotColor
        }

        FontMetrics {
            id: statusMetrics
            font: statusText.font
        }

        Text {
            id: statusText
            textFormat: Text.PlainText
            x: Tokens.settingsServiceStatusInset
            y: Tokens.settingsServiceStatusBaseline - baselineOffset
            width: chevron.x - Tokens.spacingSm - x
            elide: Text.ElideRight
            text: root.status
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        Icon {
            id: chevron
            visible: root.opens
            x: root.width - width - Tokens.settingsNavChevronInset
            anchors.verticalCenter: parent.verticalCenter
            name: "chevron-right"
            size: Tokens.settingsNavChevronSize
            color: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsNavChevronOpacity)
        }
    }
}
