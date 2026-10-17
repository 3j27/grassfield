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
    implicitHeight: Math.max(Tokens.settingsRowHeight, labels.implicitHeight + 2 * Tokens.spacingSm)

    Accessible.role: root.valueText !== "" ? Accessible.StaticText : Accessible.Grouping
    Accessible.name: root.valueText !== "" ? root.title + ": " + root.valueText : root.title

    Rectangle {
        visible: root.Positioner.index > 0
        x: Tokens.spacingMd
        width: parent.width - 2 * Tokens.spacingMd
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
    }

    Column {
        id: labels
        anchors {
            left: parent.left
            leftMargin: Tokens.spacingMd
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
            rightMargin: Tokens.spacingMd
            verticalCenter: parent.verticalCenter
        }
        spacing: Tokens.spacingSm

        Text {
            textFormat: Text.PlainText
            visible: root.valueText !== ""
            width: visible ? Math.min(implicitWidth, root.width - Tokens.settingsGroupLabelWidth - 3 * Tokens.spacingLg) : 0
            text: root.valueText
            elide: Text.ElideRight
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }
    }
}
