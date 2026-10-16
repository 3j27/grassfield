import QtQuick

// Hairline divider of a PopupMenu.
Item {
    implicitWidth: 1
    implicitHeight: Tokens.menuSeparatorHeight
    Accessible.role: Accessible.Separator
    Accessible.ignored: true

    Rectangle {
        anchors {
            left: parent.left
            right: parent.right
            leftMargin: Tokens.menuItemPadding
            rightMargin: Tokens.menuItemPadding
            verticalCenter: parent.verticalCenter
        }
        height: 1
        color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
    }
}
