import QtQuick
import Grassfield.Ui

// One row of a device or network list inside a SettingsGroup: leading glyph, title and caption, then an optional
// check mark, glyph (lock) and action label on the right. The whole row is the control (click, Space or Return).
Item {
    id: root

    property string title: ""
    property string subtitle: ""
    // Icon names of the shared set; "" shows nothing.
    property string leading: ""
    property string trailing: ""
    // The current choice (default device, connected network): a check mark before the trailing glyph.
    property bool checked: false
    // What activating the row does, shown on the right ("Connect", "Disconnect"); "" for a plain choice.
    property string actionText: ""

    signal activated

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(Tokens.settingsRowHeight, labels.implicitHeight + 2 * Tokens.spacingSm)
    activeFocusOnTab: enabled
    Accessible.role: Accessible.Button
    Accessible.name: root.title
    Accessible.description: root.subtitle !== "" ? root.subtitle : root.actionText
    Accessible.checkable: root.actionText === ""
    Accessible.checked: root.checked
    Accessible.focusable: true
    Accessible.onPressAction: root.activated()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activated();
            event.accepted = true;
        }
    }

    Rectangle {
        visible: root.Positioner.index > 0
        x: Tokens.spacingMd
        width: parent.width - 2 * Tokens.spacingMd
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Tokens.controlFocusOutline / 2
        radius: Tokens.radiusMenu
        color: mouse.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent"
        border.width: root.activeFocus ? Tokens.controlFocusOutline : 0
        border.color: Appearance.focusRingColor
    }

    Icon {
        id: lead
        visible: root.leading !== ""
        name: root.leading
        size: Tokens.settingsListIconSize
        color: Appearance.colors.text
        x: Tokens.spacingMd
        anchors.verticalCenter: parent.verticalCenter
    }

    Column {
        id: labels
        anchors {
            left: root.leading !== "" ? lead.right : parent.left
            leftMargin: root.leading !== "" ? Tokens.spacingSm : Tokens.spacingMd
            right: tail.left
            rightMargin: Tokens.spacingSm
            verticalCenter: parent.verticalCenter
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.title
            elide: Text.ElideRight
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyBodySize
        }

        Text {
            textFormat: Text.PlainText
            visible: root.subtitle !== ""
            width: parent.width
            text: root.subtitle
            elide: Text.ElideRight
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }
    }

    Row {
        id: tail
        anchors {
            right: parent.right
            rightMargin: Tokens.spacingMd
            verticalCenter: parent.verticalCenter
        }
        spacing: Tokens.spacingSm

        Text {
            textFormat: Text.PlainText
            visible: root.actionText !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.actionText
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }

        Icon {
            visible: root.checked
            name: "checkmark"
            size: Tokens.settingsListIconSize
            color: Appearance.colors.text
            anchors.verticalCenter: parent.verticalCenter
        }

        Icon {
            visible: root.trailing !== ""
            name: root.trailing
            size: Tokens.settingsListIconSize
            color: Appearance.colors.textSecondary
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.ArrowCursor
        onClicked: {
            root.forceActiveFocus();
            root.activated();
        }
    }
}
