import QtQuick

// One row of a PopupMenu. Highlight is driven by the owning menu (hover and keyboard share it).
Item {
    id: root

    property string text: ""
    property string shortcut: ""
    property string iconName: ""
    property bool highlighted: false
    property bool checked: false
    // False: no icon / check slot (macOS: the text of a section without icons or checks starts at the plain inset).
    property bool reserveSlot: true
    property bool hasSubmenu: false
    property bool destructive: false

    signal clicked
    signal hovered

    readonly property color foreground: !enabled ? Appearance.withAlpha(Appearance.colors.text, Tokens.materialDisabledOpacity)
        : highlighted ? Appearance.colors.accentText
        : destructive ? Appearance.colors.danger
        : Appearance.colors.text

    // The shortcut and the chevron sit in their own right-aligned column (macOS model, docs/specs/ui.md); the
    // minimum gap to the label is unchanged, so menus keep their widths.
    implicitWidth: lead.implicitWidth + (trail.implicitWidth > 0 ? Tokens.menuShortcutGap + 2 * Tokens.spacingSm + trail.implicitWidth : 0) + 2 * Tokens.menuItemPadding
    implicitHeight: Tokens.menuItemHeight
    Accessible.role: Accessible.MenuItem
    Accessible.name: root.text
    Accessible.description: root.shortcut
    Accessible.checkable: root.checked
    Accessible.checked: root.checked
    Accessible.focusable: true
    // An assistive technology's press (AT-SPI) acts only like the pointer and the keys would: never hidden or disabled (R12).
    Accessible.onPressAction: if (root.visible && root.enabled)
        root.clicked()

    Rectangle {
        anchors.fill: parent
        radius: Tokens.radiusControl
        color: Appearance.colors.accent
        visible: root.highlighted && root.enabled
    }

    Row {
        id: lead
        anchors {
            left: parent.left
            leftMargin: Tokens.menuItemPadding
            verticalCenter: parent.verticalCenter
        }
        spacing: Tokens.spacingSm

        Item {
            visible: root.reserveSlot
            width: Tokens.menuIconSize
            height: Tokens.menuIconSize
            anchors.verticalCenter: parent.verticalCenter

            Icon {
                anchors.fill: parent
                size: Tokens.menuIconSize
                name: root.checked ? "checkmark" : root.iconName
                color: root.foreground
            }
        }

        Text {
            textFormat: Text.PlainText
            id: label
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.foreground
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
            font.weight: Tokens.typographySmallWeight
        }
    }

    Row {
        id: trail
        anchors {
            right: parent.right
            rightMargin: Tokens.menuItemPadding
            verticalCenter: parent.verticalCenter
        }
        spacing: Tokens.spacingSm

        Text {
            textFormat: Text.PlainText
            visible: root.shortcut !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.shortcut
            color: root.highlighted && root.enabled ? root.foreground : Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
            font.weight: Tokens.typographySmallWeight
        }

        Icon {
            visible: root.hasSubmenu
            anchors.verticalCenter: parent.verticalCenter
            size: Tokens.menuIconSize
            name: "chevron-right"
            color: root.foreground
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        enabled: root.enabled
        onEntered: root.hovered()
        onPositionChanged: root.hovered()
        onClicked: root.clicked()
    }
}
