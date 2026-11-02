import QtQuick

// A menu's section title (macOS 27: small, bold, in the secondary label colour; a row tall, never selected), aligned with
// the leading edge of the rows below it: the plain inset, or after the check column when the section holds a checkable row.
// The one header of PopupMenu's `header` rows and of the shell's hand-built menus (the sound menu, the tiling popover), so
// that they cannot drift apart again (ADR-0039 step 8, G17).
Item {
    id: root

    property string text: ""
    // The rows below start after the check column (MenuItem.checkColumn).
    property bool checkColumn: false

    implicitWidth: Math.ceil(label.x + label.implicitWidth + Tokens.menuItemPadding)
    implicitHeight: Tokens.menuItemHeight
    Accessible.role: Accessible.Heading
    Accessible.name: root.text

    Text {
        id: label
        textFormat: Text.PlainText
        x: root.checkColumn ? Tokens.menuCheckInset : Tokens.menuItemPadding
        width: Math.max(0, root.width - x - Tokens.menuItemPadding)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: root.text
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        font.letterSpacing: Appearance.tracking(Tokens.typographyCaptionSize)
        font.weight: Tokens.typographyMenuBoldWeight
        Accessible.ignored: true
    }
}
