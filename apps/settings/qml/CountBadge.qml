import QtQuick
import Grassfield.Ui

// The red count of available updates (docs/specs/updates.md U19, macOS: System Settings' sidebar and General's Software Update
// row): a capsule with the number in white, hidden at 0. `spoken` is what assistive technology reads after the row's name.
Rectangle {
    id: root

    property int count: 0
    readonly property string spoken: root.count === 1 ? qsTr("1 update") : qsTr("%1 updates").arg(root.count)

    visible: root.count > 0
    implicitHeight: Tokens.settingsCountBadgeSize
    implicitWidth: Math.max(implicitHeight, label.implicitWidth + Tokens.spacingSm)
    width: implicitWidth
    height: implicitHeight
    radius: height / 2
    color: Appearance.colors.destructive

    Text {
        id: label
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: root.count > 99 ? "99+" : String(root.count)
        color: Appearance.colors.destructiveText
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        font.weight: Tokens.typographyMenuBoldWeight
    }
}
