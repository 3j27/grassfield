import QtQuick
import Grassfield.Ui

// Back and forward of a Files toolbar: one 72 x 36 capsule (macOS). The browser window's and the Open and Save panels'
// (FilePanel.qml).
Rectangle {
    id: root

    // The BrowserTab it moves (null: both disabled).
    required property var tab

    width: navRow.width + Tokens.spacingXs
    height: Tokens.toolbarCapsule
    radius: height / 2
    color: Appearance.buttonFill
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Navigation")

    Row {
        id: navRow
        anchors.centerIn: parent

        ToolButton {
            capsule: true
            buttonSize: Tokens.toolbarGroupButton
            iconName: "chevron-right"
            iconRotation: 180
            enabled: root.tab !== null && root.tab.canBack
            accessibleName: qsTr("Back")
            onClicked: root.tab.back()
        }

        ToolButton {
            capsule: true
            buttonSize: Tokens.toolbarGroupButton
            iconName: "chevron-right"
            enabled: root.tab !== null && root.tab.canForward
            accessibleName: qsTr("Forward")
            onClicked: root.tab.forward()
        }
    }
}
