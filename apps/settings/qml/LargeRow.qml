import QtQuick
import QtQuick.Templates as T
import Grassfield.Ui

// A row with a 28-pt picture (macOS 27 Notifications' apps, Focus's focuses; docs/audits/settings-parity-2026-10-26.md
// § Notifications, § Focus): 52 tall, the picture at `pictureX` (a coloured tile with `glyph`, or the app's `appIcon`), the
// name at `titleX` with an optional second line, and on the right a chevron (`chevron`: the row opens a sub-pane; a click,
// Space or Return emit clicked) or the controls declared inside. Inside a SettingsGroup, with the group's separators.
T.AbstractButton {
    id: root

    property string glyph: ""
    property string tileColor: "graphite"
    // An icon name (or "" for the apps glyph tile) instead of a tile with a glyph.
    property string appIcon: ""
    property bool useAppIcon: false
    property string subtitle: ""
    property real pictureX: Tokens.settingsFocusRowTileX
    property real titleX: Tokens.settingsFocusRowTitleX
    property bool chevron: true
    default property alias accessory: slot.data

    width: parent ? parent.width : implicitWidth
    implicitWidth: Tokens.settingsContentMaxWidth
    // The separator above every row but the first adds its point.
    readonly property int separator: root.Positioner.index > 0 ? 1 : 0
    implicitHeight: Tokens.settingsLargeRowHeight + root.separator
    focusPolicy: root.chevron ? Qt.StrongFocus : Qt.NoFocus
    hoverEnabled: root.chevron
    Accessible.role: root.chevron ? Accessible.Button : Accessible.Grouping
    Accessible.name: root.subtitle !== "" ? root.text + ", " + root.subtitle : root.text
    Accessible.onPressAction: if (root.chevron && root.visible && root.enabled)
        root.clicked()

    Keys.onPressed: event => {
        if (!root.chevron || !ActivationKeys.activation(event.key))
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
            visible: root.chevron && root.down
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
        // The row's own height, under its separator.
        readonly property real middle: root.separator + Tokens.settingsLargeRowHeight / 2

        Rectangle {
            visible: !root.useAppIcon
            x: root.pictureX
            y: parent.middle - height / 2
            width: Tokens.settingsLargeRowPictureSize
            height: width
            radius: Math.round(width * Tokens.settingsNavTileRadius / Tokens.settingsNavTileSize)
            color: Tokens.colorAccentLight[root.tileColor] || Tokens.colorAccentLight.graphite

            Icon {
                anchors.centerIn: parent
                name: root.glyph
                size: Math.round(Tokens.settingsLargeRowPictureSize * Tokens.settingsNavGlyphSize / Tokens.settingsNavTileSize)
                color: Tokens.settingsSidebarTileGlyph
            }
        }

        AppIcon {
            visible: root.useAppIcon
            x: root.pictureX
            y: parent.middle - height / 2
            width: Tokens.settingsLargeRowPictureSize
            height: width
            icon: root.appIcon
        }

        // One line: centred on the row; two: placed by their baselines.
        Text {
            id: titleText
            textFormat: Text.PlainText
            x: root.titleX
            y: root.subtitle !== "" ? root.separator + Tokens.settingsAppRowTitleBaseline - baselineOffset : parent.middle - height / 2
            width: (slot.width > 0 ? slot.x : chevronIcon.x) - x - Tokens.spacingSm
            text: root.text
            elide: Text.ElideRight
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Text {
            textFormat: Text.PlainText
            visible: root.subtitle !== ""
            x: root.titleX
            y: root.separator + Tokens.settingsAppRowSubtitleBaseline - baselineOffset
            width: titleText.width
            text: root.subtitle
            elide: Text.ElideRight
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.settingsCaptionDetailSize
        }

        Row {
            id: slot
            anchors.right: parent.right
            anchors.rightMargin: Tokens.settingsRowInset
            y: parent.middle - height / 2
        }

        Icon {
            id: chevronIcon
            visible: root.chevron
            x: root.width - width - Tokens.settingsNavChevronInset
            y: parent.middle - height / 2
            name: "chevron-right"
            size: Tokens.settingsNavChevronSize
            color: Appearance.withAlpha(Appearance.colors.text, Tokens.settingsNavChevronOpacity)
        }
    }
}
