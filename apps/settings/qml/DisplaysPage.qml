pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Displays, read-only: the outputs the compositor reports to this client (Qt screens, no Hyprland IPC), their size,
// refresh rate and scale, and the arrangement. Changing them is deferred (see docs/specs/settings.md).
SettingsPage {
    id: root

    required property var backend

    title: qsTr("Displays")

    property var screens: root.backend.screens()

    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: true
        repeat: true
        onTriggered: root.screens = root.backend.screens()
    }

    SettingsGroup {
        visible: root.screens.length === 0
        footnote: qsTr("No display information is available.")
    }

    SettingsGroup {
        visible: root.screens.length > 1
        caption: qsTr("Arrangement")

        Item {
            id: preview

            readonly property var rects: System.arrangement(root.screens, width, height, Tokens.spacingLg, Tokens.settingsDisplayMinSide)

            width: parent ? parent.width : implicitWidth
            height: Tokens.settingsDisplayPreviewHeight
            Accessible.role: Accessible.Graphic
            Accessible.name: qsTr("Display arrangement")
            Accessible.description: root.screens.map(s => s.name).join(", ")

            Repeater {
                model: preview.rects

                delegate: Rectangle {
                    id: tile

                    required property var modelData

                    x: tile.modelData.x
                    y: tile.modelData.y
                    width: tile.modelData.w
                    height: tile.modelData.h
                    radius: Tokens.settingsDisplayRadius
                    color: Appearance.withAlpha(Appearance.colors.accent, Tokens.materialFillOpacity)
                    border.width: 1
                    border.color: Appearance.colors.separator

                    Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, parent.width - Tokens.spacingSm)
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                        text: tile.modelData.name
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                    }
                }
            }
        }
    }

    Repeater {
        model: root.screens

        delegate: SettingsGroup {
            id: group

            required property var modelData
            required property int index

            caption: group.modelData.model !== "" ? qsTr("%1 (%2)").arg(group.modelData.name).arg(group.modelData.model) : group.modelData.name
            footnote: group.index === root.screens.length - 1 ? qsTr("Resolution, scale and arrangement cannot be changed from Settings yet. They come from your Hyprland monitor configuration.") : ""

            SettingsRow {
                title: qsTr("Resolution")
                valueText: System.resolutionText(group.modelData)
            }
            SettingsRow {
                title: qsTr("Refresh Rate")
                visible: System.refreshHz(group.modelData) !== ""
                height: visible ? implicitHeight : 0
                valueText: qsTr("%1 Hz").arg(System.refreshHz(group.modelData))
            }
            SettingsRow {
                title: qsTr("Scale")
                valueText: qsTr("%1%").arg(System.scalePercent(group.modelData))
            }
        }
    }
}
