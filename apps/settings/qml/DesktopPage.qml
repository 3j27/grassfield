import QtQuick
import Grassfield.Ui

SettingsPage {
    id: root

    required property var store

    title: qsTr("Desktop & Dock")

    readonly property var cornerActions: [
        {id: "none", text: qsTr("None")},
        {id: "overview", text: qsTr("Overview")},
        {id: "notifications", text: qsTr("Notifications")},
        {id: "apps", text: qsTr("Apps")},
        {id: "lock", text: qsTr("Lock Screen")}
    ]

    SettingsGroup {
        caption: qsTr("Dock")

        SettingsRow {
            title: qsTr("Size")
            subtitle: qsTr("The size of the icons in the Dock. You can also drag the divider in the Dock.")
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Small")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
            Slider {
                width: Tokens.controlSliderDefaultWidth
                accessibleName: qsTr("Size")
                from: Tokens.dockSizeMin
                to: Tokens.dockSizeMax
                stepSize: 1
                value: root.store.value("dock.size")
                onMoved: v => root.store.set("dock.size", Math.round(v))
            }
            Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Large")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }

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
            title: qsTr("Position on screen")
            subtitle: qsTr("The Dock goes to the edge you choose. With several displays it is on the one where the pointer last reached that edge.")
            Segmented {
                accessibleName: qsTr("Position on screen")
                model: [{id: "left", text: qsTr("Left")}, {id: "bottom", text: qsTr("Bottom")}, {id: "right", text: qsTr("Right")}]
                value: root.store.value("dock.position")
                onPicked: id => root.store.set("dock.position", id)
            }
        }

        SettingsRow {
            title: qsTr("Minimize animation")
            subtitle: qsTr("With Reduce Motion on, windows fade instead.")
            Picker {
                accessibleName: qsTr("Minimize animation")
                model: [{id: "funnel", text: qsTr("Funnel")}, {id: "shrink", text: qsTr("Shrink")}]
                value: root.store.value("dock.minimizeEffect")
                onPicked: id => root.store.set("dock.minimizeEffect", id)
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

        SettingsRow {
            title: qsTr("Show recent applications in the Dock")
            subtitle: qsTr("Apps you used recently that are not kept in the Dock appear in their own section before the Trash.")
            Toggle {
                accessibleName: qsTr("Show recent applications in the Dock")
                checked: root.store.value("dock.showRecents")
                onToggled: c => root.store.set("dock.showRecents", c)
            }
        }

        SettingsRow {
            title: qsTr("Minimize windows into application icon")
            subtitle: qsTr("Off: each minimized window gets its own tile next to the Trash.")
            Toggle {
                accessibleName: qsTr("Minimize windows into application icon")
                checked: root.store.value("dock.minimizeIntoApp")
                onToggled: c => root.store.set("dock.minimizeIntoApp", c)
            }
        }

        SettingsRow {
            title: qsTr("Animate opening applications")
            subtitle: qsTr("The icon bounces while an application opens.")
            Toggle {
                accessibleName: qsTr("Animate opening applications")
                checked: root.store.value("dock.animateOpening")
                onToggled: c => root.store.set("dock.animateOpening", c)
            }
        }

        SettingsRow {
            title: qsTr("Show indicators for open applications")
            subtitle: qsTr("A small dot under the icon of each open application.")
            Toggle {
                accessibleName: qsTr("Show indicators for open applications")
                checked: root.store.value("dock.showIndicators")
                onToggled: c => root.store.set("dock.showIndicators", c)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Menu Bar")

        SettingsRow {
            title: qsTr("Show menu bar background")
            subtitle: qsTr("Off: the wallpaper shows through the menu bar. On: the bar is drawn on the frosted material.")
            Toggle {
                accessibleName: qsTr("Show menu bar background")
                checked: root.store.value("menubar.showBackground")
                onToggled: c => root.store.set("menubar.showBackground", c)
            }
        }

        SettingsRow {
            title: qsTr("Automatically hide and show the menu bar")
            subtitle: qsTr("A hidden menu bar slides in over the window when the pointer reaches the top edge of the screen.")
            Picker {
                accessibleName: qsTr("Automatically hide and show the menu bar")
                model: [{id: "always", text: qsTr("Always")}, {id: "desktop", text: qsTr("On Desktop Only")}, {id: "fullscreen", text: qsTr("In Full Screen Only")}, {id: "never", text: qsTr("Never")}]
                value: root.store.value("menubar.autoHide")
                onPicked: id => root.store.set("menubar.autoHide", id)
            }
        }

        SettingsRow {
            title: qsTr("Show Now Playing in the menu bar")
            subtitle: qsTr("While a media player has a track, a button in the menu bar opens its controls.")
            Toggle {
                accessibleName: qsTr("Show Now Playing in the menu bar")
                checked: root.store.value("menubar.showNowPlaying")
                onToggled: c => root.store.set("menubar.showNowPlaying", c)
            }
        }

        SettingsRow {
            title: qsTr("Show Search in the menu bar")
            subtitle: qsTr("A magnifier button in the menu bar opens Search.")
            Toggle {
                accessibleName: qsTr("Show Search in the menu bar")
                checked: root.store.value("menubar.showSearch")
                onToggled: c => root.store.set("menubar.showSearch", c)
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

        SettingsRow {
            title: qsTr("Drag windows to screen edges to tile")
            subtitle: qsTr("A window dragged to the left or right edge fills that half, to a corner that quarter.")
            Toggle {
                accessibleName: qsTr("Drag windows to screen edges to tile")
                checked: root.store.value("windows.tilingEdges")
                onToggled: c => root.store.set("windows.tilingEdges", c)
            }
        }

        SettingsRow {
            title: qsTr("Drag windows to menu bar to fill screen")
            Toggle {
                accessibleName: qsTr("Drag windows to menu bar to fill screen")
                checked: root.store.value("windows.tilingMenuBar")
                onToggled: c => root.store.set("windows.tilingMenuBar", c)
            }
        }

        SettingsRow {
            title: qsTr("Tiled windows have margins")
            Toggle {
                accessibleName: qsTr("Tiled windows have margins")
                checked: root.store.value("windows.tilingMargins")
                onToggled: c => root.store.set("windows.tilingMargins", c)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Screen Corners")
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
