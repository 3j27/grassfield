import QtQuick
import Grassfield.Ui

// One row of a SettingsGroup: title (and optional subtitle) on the left, the control(s) on the right.
Item {
    id: root

    property string title: ""
    property string subtitle: ""
    // Read-only value shown instead of a control (About, Keyboard).
    property string valueText: ""
    // An optional coloured tile before the title (macOS 27 rows with an icon: About's software and displays, Storage).
    property string glyph: ""
    // A colour of color.accentLight ("graphite" for an unknown one), or "grassfield": the brand green of the appearance,
    // color.light.accent or color.dark.accent as the About window's mark (About's and Software Update's Grassfield rows,
    // ADR-0040 ID-11: not the pickable Green; the light-only brand green of 2026-10-30 stays in the light appearance).
    property string tileColor: "graphite"
    property real tileSize: Tokens.settingsNavTileSize
    // The labels' offset from the row's middle (macOS 27 slider rows set their title a little higher).
    property real labelsOffset: 0
    default property alias control: slot.data
    // The labels dim with the row's control, once (UI audit 2026-11-05 U18): when the row itself is disabled or a control in it
    // draws its own disabled look (Appearance.dimsDisabled), never again inside a pane that is dimmed as a whole (Settings'
    // blocked page). A row that places its control outside the slot (LevelRow) sets it.
    property bool dimmed: {
        if (Appearance.dimsDisabled(root))
            return true;
        for (let i = 0; i < slot.children.length; i++) {
            const c = slot.children[i];
            if (c.visible && Appearance.dimsDisabled(c))
                return true;
        }
        return false;
    }

    width: parent ? parent.width : implicitWidth
    // A control keeps the margin a push button has in a plain row (settings.rowHeight 38 for control.buttonHeight 24, macOS 27),
    // so a row with a pop-up button or a segmented control is 38 like the others (UI audit 2026-11-05 U19); the labels keep
    // spacingSm above and below.
    implicitHeight: Math.max(Tokens.settingsRowHeight, labels.implicitHeight + 2 * Tokens.spacingSm, slot.implicitHeight + Math.min(2 * Tokens.spacingSm, Tokens.settingsRowHeight - Tokens.controlButtonHeight))

    TextMetrics {
        id: valueMetrics
        font: valueLabel.font
        text: root.valueText
    }

    Accessible.role: root.valueText !== "" ? Accessible.StaticText : Accessible.Grouping
    Accessible.name: root.valueText !== "" ? root.title + ": " + root.valueText : root.title

    Rectangle {
        visible: root.Positioner.index > 0
        x: Tokens.settingsRowInset
        width: parent.width - 2 * Tokens.settingsRowInset
        height: Tokens.appsBorderWidth
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Rectangle {
        id: tile
        visible: root.glyph !== ""
        x: Tokens.settingsNavTileInset
        anchors.verticalCenter: parent.verticalCenter
        width: root.tileSize
        height: width
        radius: Math.round(root.tileSize * Tokens.settingsNavTileRadius / Tokens.settingsNavTileSize)
        // The brand green stays flat; the other tiles are the vivid gradient.
        color: Appearance.dark ? Tokens.colorDark.accent : Tokens.colorLight.accent
        gradient: root.tileColor === "grassfield" ? null : tileGradient

        TileGradient {
            id: tileGradient
            name: root.tileColor
        }

        Icon {
            anchors.centerIn: parent
            name: root.glyph
            size: Math.round(root.tileSize * Tokens.settingsNavGlyphSize / Tokens.settingsNavTileSize)
            color: Tokens.settingsSidebarTileGlyph
        }
    }

    Column {
        id: labels
        opacity: root.dimmed ? Tokens.materialDisabledOpacity : 1
        anchors {
            left: parent.left
            leftMargin: root.glyph !== "" ? 2 * Tokens.settingsNavTileInset + root.tileSize : Tokens.settingsRowInset
            right: slot.left
            rightMargin: Tokens.spacingLg
            verticalCenter: parent.verticalCenter
            verticalCenterOffset: root.labelsOffset
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.title
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
            wrapMode: Text.Wrap
        }

        Text {
            textFormat: Text.PlainText
            visible: root.subtitle !== ""
            width: parent.width
            text: root.subtitle
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            wrapMode: Text.Wrap
        }
    }

    Row {
        id: slot
        anchors {
            right: parent.right
            rightMargin: Tokens.settingsRowInset
            verticalCenter: parent.verticalCenter
        }
        spacing: Tokens.spacingSm

        Text {
            id: valueLabel
            textFormat: Text.PlainText
            // Centred on the row's control (Date & Time: the date beside its Set… button).
            anchors.verticalCenter: parent.verticalCenter
            visible: root.valueText !== ""
            opacity: root.dimmed ? Tokens.materialDisabledOpacity : 1
            // The natural width comes from TextMetrics, not from this Text's implicitWidth, which changes as the text
            // wraps and looped (real session 2026-10-22, "SettingsRow.qml:72: Binding loop detected for property width").
            width: visible ? Math.min(Math.ceil(valueMetrics.advanceWidth), root.width - Tokens.settingsGroupLabelWidth - 3 * Tokens.spacingLg) : 0
            text: root.valueText
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignRight
            color: Appearance.windowSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }
}
