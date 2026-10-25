pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// macOS Tahoe System Settings > Menu Bar: the bar's background and auto-hide, the clock options and the status items it
// shows. Every control writes one key of the `menubar` group; the shell reads them live (shell/menubar/MenuBar.qml).
SettingsPage {
    id: root

    required property var store

    title: qsTr("Menu Bar")

    signal clockOptionsRequested

    SettingsGroup {
        caption: qsTr("Menu Bar")

        SettingsRow {
            title: qsTr("Automatically hide and show the menu bar")
            subtitle: qsTr("A hidden menu bar slides in over the window when the pointer reaches the top edge of the screen.")
            ComboBox {
                accessibleName: qsTr("Automatically hide and show the menu bar")
                model: [{id: "always", text: qsTr("Always")}, {id: "desktop", text: qsTr("On Desktop Only")}, {id: "fullscreen", text: qsTr("In Full Screen Only")}, {id: "never", text: qsTr("Never")}]
                value: root.store.value("menubar.autoHide")
                onPicked: id => root.store.set("menubar.autoHide", id)
            }
        }

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
            title: qsTr("Recent documents and applications")
            subtitle: qsTr("The number of items the Recent Items menu lists. None hides the menu.")
            ComboBox {
                accessibleName: qsTr("Recent documents and applications")
                // macOS offers None, 5, 10, 15, 20, 30, 50; a stored value outside them (hand-edited file) is shown as it is.
                model: {
                    const steps = [0, 5, 10, 15, 20, 30, 50];
                    const now = Number(root.store.value("menubar.recentItems"));
                    if (Number.isFinite(now) && steps.indexOf(now) < 0)
                        steps.push(now);
                    steps.sort((a, b) => a - b);
                    return steps.map(n => ({id: String(n), text: n === 0 ? qsTr("None") : String(n)}));
                }
                value: String(root.store.value("menubar.recentItems"))
                onPicked: id => root.store.set("menubar.recentItems", parseInt(id))
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Clock")

        SettingsRow {
            subtitle: qsTr("Date, day of the week, 24-hour time, seconds.")
            Button {
                text: qsTr("Clock Options…")
                onClicked: root.clockOptionsRequested()
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Menu Bar Controls")

        SettingsRow {
            title: qsTr("Wi-Fi")
            subtitle: qsTr("The network status and its menu.")
            Toggle {
                accessibleName: qsTr("Show Wi-Fi in the menu bar")
                checked: root.store.value("menubar.showWifi")
                onToggled: c => root.store.set("menubar.showWifi", c)
            }
        }

        SettingsRow {
            title: qsTr("Sound")
            subtitle: qsTr("The volume and the output devices.")
            Toggle {
                accessibleName: qsTr("Show Sound in the menu bar")
                checked: root.store.value("menubar.showSound")
                onToggled: c => root.store.set("menubar.showSound", c)
            }
        }

        SettingsRow {
            title: qsTr("Battery")
            subtitle: qsTr("Shown on a computer that has a battery.")
            Toggle {
                accessibleName: qsTr("Show Battery in the menu bar")
                checked: root.store.value("menubar.showBattery")
                onToggled: c => root.store.set("menubar.showBattery", c)
            }
        }

        SettingsRow {
            title: qsTr("Show Percentage")
            subtitle: qsTr("The charge level beside the battery.")
            Toggle {
                enabled: root.store.value("menubar.showBattery")
                accessibleName: qsTr("Show the battery percentage in the menu bar")
                checked: root.store.value("menubar.showBatteryPercentage")
                onToggled: c => root.store.set("menubar.showBatteryPercentage", c)
            }
        }

        SettingsRow {
            title: qsTr("Focus")
            subtitle: qsTr("A moon in the menu bar while Do Not Disturb is on; a click turns it off.")
            Toggle {
                accessibleName: qsTr("Show Focus in the menu bar")
                checked: root.store.value("menubar.showFocus")
                onToggled: c => root.store.set("menubar.showFocus", c)
            }
        }

        SettingsRow {
            title: qsTr("Now Playing")
            subtitle: qsTr("While a media player has a track, a button in the menu bar opens its controls.")
            Toggle {
                accessibleName: qsTr("Show Now Playing in the menu bar")
                checked: root.store.value("menubar.showNowPlaying")
                onToggled: c => root.store.set("menubar.showNowPlaying", c)
            }
        }

        SettingsRow {
            title: qsTr("Search")
            subtitle: qsTr("A magnifier button in the menu bar opens Search.")
            Toggle {
                accessibleName: qsTr("Show Search in the menu bar")
                checked: root.store.value("menubar.showSearch")
                onToggled: c => root.store.set("menubar.showSearch", c)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Allow in the Menu Bar")
        footnote: qsTr("Choosing which application may show an item is not available: this switch covers all of them.")

        SettingsRow {
            title: qsTr("Items from applications")
            subtitle: qsTr("The status icons that applications such as chat and sync tools put in the menu bar.")
            Toggle {
                accessibleName: qsTr("Show status items of applications in the menu bar")
                checked: root.store.value("menubar.showTrayItems")
                onToggled: c => root.store.set("menubar.showTrayItems", c)
            }
        }
    }
}
