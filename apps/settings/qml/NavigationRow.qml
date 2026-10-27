import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// One row of a hub pane that opens a sub-pane (macOS 27 General): a coloured tile, the sub-pane's name and a chevron; an
// optional value sits before the chevron. A click, Space or Return opens it (clicked). Inside a SettingsGroup, with the
// group's separators (docs/audits/settings-parity-2026-10-26.md § General). `compact` is the list hub's smaller row (macOS 27
// Accessibility: 42 tall, a 23-pt tile; § Accessibility).
T.AbstractButton {
    id: root

    property string glyph: ""
    property string tileColor: "graphite"
    property string value: ""
    property bool compact: false

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    // The separator above every row but the first adds its point: rows are 48 tall, 49 apart (macOS 27); compact, 42 and 43.
    readonly property int separator: root.Positioner.index > 0 ? 1 : 0
    readonly property int rowHeight: root.compact ? Tokens.settingsNavCompactRowHeight : Tokens.settingsNavRowHeight
    readonly property int tileSize: root.compact ? Tokens.settingsNavCompactTileSize : Tokens.settingsNavTileSize
    implicitHeight: root.rowHeight + root.separator
    focusPolicy: Qt.StrongFocus
    hoverEnabled: true
    Accessible.role: Accessible.Button
    Accessible.name: root.value !== "" ? root.text + ", " + root.value : root.text
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.clicked()

    Keys.onPressed: event => {
        if (!ActivationKeys.activation(event.key))
            return;
        if (root.visible && root.enabled)
            root.clicked();
        event.accepted = true;
    }

    background: Item {
        Rectangle {
            visible: root.Positioner.index > 0
            x: Tokens.settingsRowInset
            width: parent.width - 2 * Tokens.settingsRowInset
            height: 1
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        // Held down: the row darkens, as macOS does while the pointer holds it.
        Rectangle {
            anchors.fill: parent
            anchors.topMargin: root.separator + Tokens.spacingXs / 2
            anchors.leftMargin: Tokens.spacingXs / 2
            anchors.rightMargin: Tokens.spacingXs / 2
            anchors.bottomMargin: Tokens.spacingXs / 2
            radius: Tokens.settingsSidebarItemRadius
            color: Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)
            visible: root.down
        }

        // Keyboard focus only (never after a click): the ring inside the group's edge.
        Item {
            anchors.fill: parent
            anchors.margins: Tokens.controlFocusOutline
            anchors.topMargin: root.separator + Tokens.controlFocusOutline
            visible: root.visualFocus

            FocusRing {
                shapeRadius: Tokens.settingsSidebarItemRadius
            }
        }
    }

    contentItem: Item {
        Rectangle {
            id: tile
            x: root.compact ? Tokens.settingsNavCompactTileInset : Tokens.settingsNavTileInset
            y: root.separator + Math.round((root.rowHeight - height) / 2)
            width: root.tileSize
            height: width
            // The compact tile keeps the large one's proportions.
            radius: Math.round(root.tileSize * Tokens.settingsNavTileRadius / Tokens.settingsNavTileSize)
            color: Tokens.colorAccentLight[root.tileColor] || Tokens.colorAccentLight.graphite

            Icon {
                anchors.centerIn: parent
                name: root.glyph
                size: Math.round(root.tileSize * Tokens.settingsNavGlyphSize / Tokens.settingsNavTileSize)
                color: Tokens.settingsSidebarTileGlyph
            }
        }

        Text {
            textFormat: Text.PlainText
            anchors {
                left: parent.left
                leftMargin: root.compact ? Tokens.settingsNavCompactLabelInset : Tokens.settingsNavLabelInset
                right: valueLabel.left
                rightMargin: Tokens.spacingSm
                verticalCenter: parent.verticalCenter
                verticalCenterOffset: root.separator / 2
            }
            text: root.text
            elide: Text.ElideRight
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Text {
            id: valueLabel
            textFormat: Text.PlainText
            anchors {
                right: chevron.left
                rightMargin: root.value !== "" ? Tokens.settingsNavValueGap : 0
                verticalCenter: parent.verticalCenter
                verticalCenterOffset: root.separator / 2
            }
            // Its own width (none without a value).
            text: root.value
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Icon {
            id: chevron
            x: root.width - width - Tokens.settingsNavChevronInset
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: root.separator / 2
            name: "chevron-right"
            size: Tokens.settingsNavChevronSize
            color: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsNavChevronOpacity)
        }
    }
}
