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
    // Left/Right on the mute button or a device row: the previous or next status menu (the slider keeps them for the volume).
    Keys.onLeftPressed: Popups.stepMenu(-1)
    Keys.onRightPressed: Popups.stepMenu(1)
    // The keyboard starts on the mute button so that Left/Right walk the status menus; Up/Down change the volume from anywhere
    // (the slider itself answers to all four arrows once it has the focus, Tab).
    Keys.onUpPressed: slider.nudge(1)
    Keys.onDownPressed: slider.nudge(-1)

    Material {
        glassClass: "menu"
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
                focus: true
                Accessible.role: Accessible.Button
                Accessible.name: Audio.muted ? qsTr("Unmute") : qsTr("Mute")
                Accessible.onPressAction: Audio.toggleMute()
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
                        Audio.toggleMute();
                        event.accepted = true;
                    }
                }

                // The shared ring outside the button, after a key only (ADR-0039 step 7).
                KeyFocus {
                    id: muteFocus
                }

                FocusRing {
                    visible: muteFocus.active
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
                knobless: true
                trackHeight: Tokens.controlSliderTrackCompact
                width: parent.width - muteButton.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Output volume")
                value: Audio.volume
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
                    // Every device row is checkable: all labels start after the check column (macOS).
                    checkColumn: true
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
