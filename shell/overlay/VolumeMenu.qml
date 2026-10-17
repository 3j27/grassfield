pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services

// Sound menu: output volume slider with mute, and the list of output devices (PipeWire).
FocusScope {
    id: root

    readonly property var devices: Audio.sinks

    width: Tokens.panelStatusPopupWidth
    height: column.implicitHeight + 2 * Tokens.menuPadding
    Accessible.role: Accessible.Window
    Accessible.name: qsTr("Sound")

    Keys.onEscapePressed: Popups.close()

    Material {
        anchors.fill: parent
        radius: Tokens.radiusMenu
    }

    Column {
        id: column
        x: Tokens.menuPadding
        y: Tokens.menuPadding
        width: root.width - 2 * Tokens.menuPadding
        spacing: Tokens.spacingXs

        Text {
            textFormat: Text.PlainText
            x: Tokens.menuItemPadding
            text: qsTr("Sound")
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.weight: Tokens.typographyMenuBoldWeight
        }

        Row {
            x: Tokens.menuItemPadding
            width: parent.width - 2 * Tokens.menuItemPadding
            spacing: Tokens.spacingSm
            height: Tokens.controlSliderHeight

            Item {
                id: muteButton
                width: Tokens.menuIconSize + Tokens.spacingSm
                height: parent.height
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: Audio.muted ? qsTr("Unmute") : qsTr("Mute")
                Accessible.onPressAction: Audio.toggleMute()
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
                        Audio.toggleMute();
                        event.accepted = true;
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.radiusControl
                    color: "transparent"
                    border.width: muteButton.activeFocus ? Tokens.controlFocusRing : 0
                    border.color: Appearance.colors.accent
                }

                Icon {
                    anchors.centerIn: parent
                    size: Tokens.menuIconSize
                    name: Audio.iconName
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: Audio.toggleMute()
                }
            }

            Slider {
                id: slider
                width: parent.width - muteButton.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Output volume")
                value: Audio.volume
                focus: true
                onMoved: v => Audio.setVolume(v)
            }
        }

        MenuSeparator {
            width: parent.width
            visible: root.devices.length > 0
        }

        Text {
            textFormat: Text.PlainText
            x: Tokens.menuItemPadding
            visible: root.devices.length > 0
            text: qsTr("Output")
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            font.weight: Tokens.typographyMenuBoldWeight
        }

        Repeater {
            model: root.devices

            delegate: FocusScope {
                id: deviceRow

                required property var modelData

                width: column.width
                height: Tokens.menuItemHeight
                activeFocusOnTab: true
                Accessible.role: Accessible.RadioButton
                Accessible.name: Audio.describe(deviceRow.modelData)
                Accessible.checked: Audio.sink === deviceRow.modelData
                Accessible.onPressAction: Audio.select(deviceRow.modelData)
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
                        Audio.select(deviceRow.modelData);
                        event.accepted = true;
                    }
                }

                MenuItem {
                    anchors.fill: parent
                    text: Audio.describe(deviceRow.modelData)
                    checked: Audio.sink === deviceRow.modelData
                    highlighted: deviceRow.activeFocus || hover.hovered
                    onClicked: Audio.select(deviceRow.modelData)

                    HoverHandler {
                        id: hover
                    }
                }
            }
        }
    }
}
