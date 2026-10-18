import QtQuick
import Grassfield.Ui

SettingsPage {
    id: root

    required property var store

    title: qsTr("Desktop & Dock")

    readonly property var cornerActions: [
        {id: "none", text: qsTr("None")},
        {id: "overview", text: qsTr("Overview")},
        {id: "notifications", text: qsTr("Notification Center")},
        {id: "apps", text: qsTr("Apps")},
        {id: "lock", text: qsTr("Lock Screen")}
    ]

    SettingsGroup {
        caption: qsTr("Dock")

        SettingsRow {
            title: qsTr("Magnification")
            subtitle: qsTr("Icons grow under the pointer.")
            Toggle {
                accessibleName: qsTr("Magnification")
                checked: root.store.value("dock.magnificationEnabled")
                onToggled: c => root.store.set("dock.magnificationEnabled", c)
            }
        }

        SettingsRow {
            title: qsTr("Magnification size")
            Slider {
                width: Tokens.controlSliderDefaultWidth
                accessibleName: qsTr("Magnification size")
                enabled: root.store.value("dock.magnificationEnabled")
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                from: 1
                to: 2.5
                stepSize: 0.05
                value: root.store.value("dock.magnification")
                onMoved: v => root.store.set("dock.magnification", Math.round(v * 100) / 100)
            }
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                width: Tokens.settingsShortcutKeyMinWidth + Tokens.spacingSm
                horizontalAlignment: Text.AlignRight
                text: qsTr("%1x").arg(root.store.value("dock.magnification").toFixed(2))
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }

        SettingsRow {
            title: qsTr("Automatically hide the Dock")
            Toggle {
                accessibleName: qsTr("Automatically hide the Dock")
                checked: root.store.value("dock.autohide")
                onToggled: c => root.store.set("dock.autohide", c)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Desktop")

        SettingsRow {
            title: qsTr("Show items on the desktop")
            subtitle: qsTr("Files and folders of the Desktop folder appear on the wallpaper.")
            Toggle {
                accessibleName: qsTr("Show items on the desktop")
                checked: root.store.value("desktop.showIcons")
                onToggled: c => root.store.set("desktop.showIcons", c)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Windows")

        SettingsRow {
            title: qsTr("Double-click a window's title bar to")
            Picker {
                accessibleName: qsTr("Double-click a window's title bar to")
                model: [{id: "zoom", text: qsTr("Zoom")}, {id: "minimize", text: qsTr("Minimize")}, {id: "none", text: qsTr("Do Nothing")}]
                value: root.store.value("windows.titlebarDoubleClick")
                onPicked: id => root.store.set("windows.titlebarDoubleClick", id)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Hot Corners")
        footnote: qsTr("Move the pointer into a screen corner to run the action.")

        SettingsRow {
            title: qsTr("Top left")
            Picker {
                accessibleName: qsTr("Top left corner")
                model: root.cornerActions
                value: root.store.value("hotCorners.topLeft")
                onPicked: id => root.store.set("hotCorners.topLeft", id)
            }
        }

        SettingsRow {
            title: qsTr("Top right")
            Picker {
                accessibleName: qsTr("Top right corner")
                model: root.cornerActions
                value: root.store.value("hotCorners.topRight")
                onPicked: id => root.store.set("hotCorners.topRight", id)
            }
        }

        SettingsRow {
            title: qsTr("Bottom left")
            Picker {
                accessibleName: qsTr("Bottom left corner")
                model: root.cornerActions
                value: root.store.value("hotCorners.bottomLeft")
                onPicked: id => root.store.set("hotCorners.bottomLeft", id)
            }
        }

        SettingsRow {
            title: qsTr("Bottom right")
            Picker {
                accessibleName: qsTr("Bottom right corner")
                model: root.cornerActions
                value: root.store.value("hotCorners.bottomRight")
                onPicked: id => root.store.set("hotCorners.bottomRight", id)
            }
        }
    }
}
