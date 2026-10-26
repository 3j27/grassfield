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
        height: Math.max(Tokens.menuItemHeight, label.implicitHeight + Tokens.spacingXs)

        // Wraps to a second line instead of ending in an ellipsis (GF-097).
        Label {
            id: label
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - toggle.width - Tokens.spacingSm
            text: sw.text
            wrapMode: Text.WordWrap
            maximumLineCount: 2
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
                {id: "light", text: qsTr("Light"), icons: ["sun"]},
                {id: "dark", text: qsTr("Dark"), icons: ["moon"]},
                // Auto (macOS): light by day, dark at night; drawn as both glyphs.
                {id: "auto", text: qsTr("Auto"), icons: ["sun", "moon"]}
            ]

            delegate: Item {
                id: choice

                required property var modelData
                readonly property bool selected: Settings.appearance === modelData.id

                width: (parent.width - 2 * Tokens.spacingSm) / 3
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
                    color: choice.selected ? Appearance.colors.selection : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                    border.width: choice.activeFocus ? Tokens.controlFocusOutline : 0
                    border.color: Appearance.focusRingColor
                }

                Column {
                    anchors.centerIn: parent
                    spacing: Tokens.spacingXs

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: Tokens.spacingXs

                        Repeater {
                            model: choice.modelData.icons

                            delegate: Icon {
                                required property string modelData
                                size: Tokens.menuIconSize + 4
                                name: modelData
                                color: choice.selected ? Appearance.colors.selectionText : Appearance.colors.text
                            }
                        }
                    }

                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: choice.modelData.text
                        color: choice.selected ? Appearance.colors.selectionText : Appearance.colors.text
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.ArrowCursor
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
