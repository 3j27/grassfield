pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services

// Sound menu: output volume slider with mute, and the list of output devices (PipeWire). On PopupMenu's metrics (ADR-0039
// step 8, G17): rows a row tall with no gap between them, the Output section titled by the menus' MenuHeader after the check
// column, and one highlight, the pointer's and the keyboard's.
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

        // The menu's own title (macOS: the status menu's name, bold, in the label colour), a row tall.
        Text {
            textFormat: Text.PlainText
            x: Tokens.menuItemPadding
            height: Tokens.menuItemHeight
            verticalAlignment: Text.AlignVCenter
            text: qsTr("Sound")
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.letterSpacing: Appearance.tracking(Tokens.typographyMenuSize)
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

                // The shared ring outside the button, after a key only (ADR-0039 step 7); the focus it has on open is the
                // pointer's when a click opened the menu (step 8).
                KeyFocus {
                    id: muteFocus
                    pointer: Popups.openedByPointer
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

        // Every device row is checkable: the title starts after the check column, with their labels.
        MenuHeader {
            width: parent.width
            visible: root.devices.length > 0
            text: qsTr("Output")
            checkColumn: true
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

                // Whether the pointer gave the row its focus: such a row goes dark when the pointer leaves it, as a menu's row
                // does (the review of #88); a row the keyboard chose stays lit.
                property bool pointerFocus: false
                onActiveFocusChanged: if (!deviceRow.activeFocus)
                    deviceRow.pointerFocus = false

                HoverHandler {
                    id: rowHover
                }

                MenuItem {
                    anchors.fill: parent
                    text: Audio.describe(deviceRow.modelData)
                    checked: Audio.sink === deviceRow.modelData
                    // Every device row is checkable: all labels start after the check column (macOS).
                    checkColumn: true
                    // One highlight: the pointer moving onto a row gives it the focus (a menu's hover and keys share one
                    // current row), so a focused row and a hovered one are never both lit.
                    highlighted: deviceRow.activeFocus && (!deviceRow.pointerFocus || rowHover.hovered)
                    onClicked: Audio.select(deviceRow.modelData)
                    onHovered: if (!deviceRow.activeFocus) {
                        deviceRow.pointerFocus = true;
                        deviceRow.forceActiveFocus(Qt.MouseFocusReason);
                    }
                }
            }
        }
    }
}
