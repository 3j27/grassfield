import QtQuick

// Toolbar item group (macOS 26/27): toolbar buttons side by side in one floating capsule, `window.groupHeight` tall (Files'
// back and forward, its view switcher). The buttons are the children; give them `capsule: true` and the group's height so
// their hover and checked pills follow the capsule. White in light, a faint white in dark, with the material's hairline.
Rectangle {
    id: root

    default property alias items: row.data
    // What assistive technology reads for the group ("View").
    property string accessibleName: ""

    implicitWidth: row.implicitWidth + 2 * Tokens.windowGroupInset
    implicitHeight: Tokens.windowGroupHeight
    radius: height / 2
    color: Appearance.dark ? Appearance.withAlpha(Appearance.colors.fill, Tokens.windowGroupFillDark) : Appearance.withAlpha(Appearance.colors.knob, Tokens.windowGroupFillLight)
    border.width: 1
    border.color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
    Accessible.role: Accessible.Grouping
    Accessible.name: root.accessibleName

    Row {
        id: row
        anchors.centerIn: parent
    }
}
