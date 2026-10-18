pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import qs.overlay.controlcenter

// Appearance (Light/Dark) and Material (transparency, Reduce Transparency, Reduce Motion), CC8.
// Every change is applied live and persisted to grassfield.json through Settings.
Column {
    id: root

    component SwitchRow: Item {
        id: sw
        property string text: ""
        property alias checked: toggle.checked
        signal toggled(bool checked)
        width: parent.width
        height: Tokens.menuItemHeight

        Label {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - toggle.width - Tokens.spacingSm
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

    width: parent ? parent.width : implicitWidth
    spacing: Tokens.spacingSm

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

    Row {
        width: parent.width
        spacing: Tokens.spacingSm

        Label {
            id: transparencyLabel
            text: qsTr("Transparency")
            anchors.verticalCenter: parent.verticalCenter
        }

        Slider {
            trackHeight: Tokens.controlSliderTrackCompact
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
