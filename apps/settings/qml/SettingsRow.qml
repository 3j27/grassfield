import QtQuick
import Grassfield.Ui

// One row of a SettingsGroup: title (and optional subtitle) on the left, the control(s) on the right.
Item {
    id: root

    property string title: ""
    property string subtitle: ""
    // Read-only value shown instead of a control (About, Keyboard).
    property string valueText: ""
    default property alias control: slot.data

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(Tokens.settingsRowHeight, Math.max(labels.implicitHeight, slot.implicitHeight) + 2 * Tokens.spacingSm)

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
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Column {
        id: labels
        anchors {
            left: parent.left
            leftMargin: Tokens.settingsRowInset
            right: slot.left
            rightMargin: Tokens.spacingLg
            verticalCenter: parent.verticalCenter
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
            color: Appearance.colors.textSecondary
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
            visible: root.valueText !== ""
            // The natural width comes from TextMetrics, not from this Text's implicitWidth, which changes as the text
            // wraps and looped (real session 2026-10-22, "SettingsRow.qml:72: Binding loop detected for property width").
            width: visible ? Math.min(Math.ceil(valueMetrics.advanceWidth), root.width - Tokens.settingsGroupLabelWidth - 3 * Tokens.spacingLg) : 0
            text: root.valueText
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignRight
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }
}
