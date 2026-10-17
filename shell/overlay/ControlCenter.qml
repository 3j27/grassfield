pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.notifications
import qs.services

// Control Center, M1 subset: Appearance, Transparency, Reduce Transparency, Reduce Motion, Sound.
// Every change is applied live and persisted to grassfield.json through Settings.
FocusScope {
    id: root

    width: Tokens.panelControlCenterWidth
    height: column.implicitHeight + 2 * Tokens.spacingMd
    Accessible.role: Accessible.Window
    Accessible.name: qsTr("Control Center")

    Keys.onEscapePressed: Popups.close()

    component Card: Rectangle {
        default property alias body: inner.data
        width: parent.width
        height: inner.implicitHeight + 2 * Tokens.spacingMd
        radius: Tokens.radiusMenu
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity / 2)

        Column {
            id: inner
            x: Tokens.spacingMd
            y: Tokens.spacingMd
            width: parent.width - 2 * Tokens.spacingMd
            spacing: Tokens.spacingSm
        }
    }

    component Caption: Text {
        textFormat: Text.PlainText
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        font.weight: Tokens.typographyMenuBoldWeight
    }

    component Label: Text {
        textFormat: Text.PlainText
        color: Appearance.colors.text
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyBodySize
        font.weight: Tokens.typographyMenuWeight
    }

    component SwitchRow: Item {
        id: sw
        property string text: ""
        property alias checked: toggle.checked
        signal toggled(bool checked)
        width: parent.width
        height: Tokens.controlToggleHeight

        Label {
            anchors.verticalCenter: parent.verticalCenter
            text: sw.text
        }

        Toggle {
            id: toggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            accessibleName: sw.text
            onToggled: value => sw.toggled(value)
        }
    }

    Material {
        anchors.fill: parent
        radius: Tokens.radiusPanel
    }

    Column {
        id: column
        x: Tokens.spacingMd
        y: Tokens.spacingMd
        width: root.width - 2 * Tokens.spacingMd
        spacing: Tokens.spacingSm

        Label {
            text: qsTr("Control Center")
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.typographyMenuBoldWeight
        }

        Card {
            Caption {
                text: qsTr("Focus")
            }

            Row {
                width: parent.width
                spacing: Tokens.spacingSm
                height: Tokens.controlToggleHeight

                Icon {
                    id: focusIcon
                    anchors.verticalCenter: parent.verticalCenter
                    size: Tokens.menuIconSize
                    name: "moon"
                }

                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Do Not Disturb")
                    width: parent.width - focusIcon.width - dndToggle.width - 2 * parent.spacing
                }

                Toggle {
                    id: dndToggle
                    anchors.verticalCenter: parent.verticalCenter
                    accessibleName: qsTr("Do Not Disturb")
                    checked: Notifications.dnd
                    onToggled: value => Notifications.setDnd(value)
                }
            }
        }

        Card {
            Caption {
                text: qsTr("Appearance")
            }

            Row {
                width: parent.width
                spacing: Tokens.spacingSm

                Repeater {
                    model: [
                        {id: "light", text: qsTr("Light"), icon: "sun"},
                        {id: "dark", text: qsTr("Dark"), icon: "moon"}
                    ]

                    delegate: Item {
                        id: choice

                        required property var modelData
                        readonly property bool selected: Settings.appearance === modelData.id

                        width: (parent.width - Tokens.spacingSm) / 2
                        height: Tokens.panelTileHeight
                        activeFocusOnTab: true
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData.text
                        Accessible.checked: selected
                        Accessible.onPressAction: Settings.setAppearance(modelData.id)
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
                                Settings.setAppearance(modelData.id);
                                event.accepted = true;
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: Tokens.radiusControl
                            color: choice.selected ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                            border.width: choice.activeFocus ? Tokens.controlFocusRing : 0
                            border.color: Appearance.colors.text
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: Tokens.spacingXs

                            Icon {
                                anchors.horizontalCenter: parent.horizontalCenter
                                size: Tokens.menuIconSize + 4
                                name: choice.modelData.icon
                                color: choice.selected ? Appearance.colors.accentText : Appearance.colors.text
                            }

                            Label {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: choice.modelData.text
                                color: choice.selected ? Appearance.colors.accentText : Appearance.colors.text
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Settings.setAppearance(choice.modelData.id)
                        }
                    }
                }
            }
        }

        Card {
            Caption {
                text: qsTr("Material")
            }

            Row {
                width: parent.width
                spacing: Tokens.spacingSm

                Label {
                    id: transparencyLabel
                    text: qsTr("Transparency")
                    anchors.verticalCenter: parent.verticalCenter
                }

                Slider {
                    width: parent.width - transparencyLabel.width - percent.width - 2 * parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    accessibleName: qsTr("Transparency")
                    value: Settings.transparency
                    stepSize: 0.05
                    onMoved: v => Settings.setTransparency(v)
                }

                Label {
                    id: percent
                    width: Tokens.panelPercentWidth
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: qsTr("%1%").arg(Math.round(Settings.transparency * 100))
                }
            }

            SwitchRow {
                text: qsTr("Reduce Transparency")
                checked: Settings.reduceTransparency
                onToggled: value => Settings.setReduceTransparency(value)
            }

            SwitchRow {
                text: qsTr("Reduce Motion")
                checked: Settings.reduceMotion
                onToggled: value => Settings.setReduceMotion(value)
            }
        }

        Card {
            Caption {
                text: qsTr("Sound")
            }

            Row {
                width: parent.width
                spacing: Tokens.spacingSm
                height: Tokens.controlSliderHeight

                Icon {
                    id: soundIcon
                    anchors.verticalCenter: parent.verticalCenter
                    size: Tokens.menuIconSize
                    name: Audio.iconName
                }

                Slider {
                    width: parent.width - soundIcon.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    accessibleName: qsTr("Output volume")
                    value: Audio.volume
                    onMoved: v => Audio.setVolume(v)
                }
            }
        }
    }
}
