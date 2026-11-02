import QtQuick
import Grassfield.Ui

// What an empty list says inside its group (macOS 27: "No VPN configurations", "No paired devices"): centred, in the window's
// secondary colour, settings.emptyListHeight tall. One style for every empty list of Settings (ADR-0039 step 15; it was a plain
// row in some lists and centred text in others).
Item {
    id: root

    property string text: ""

    width: parent ? parent.width : implicitWidth
    implicitWidth: label.implicitWidth
    implicitHeight: Tokens.settingsEmptyListHeight
    Accessible.role: Accessible.StaticText
    Accessible.name: root.text

    Text {
        id: label
        textFormat: Text.PlainText
        anchors.centerIn: parent
        width: Math.min(implicitWidth, parent.width - 2 * Tokens.spacingMd)
        elide: Text.ElideRight
        text: root.text
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        Accessible.ignored: true
    }
}
