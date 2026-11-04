pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// macOS 27 Battery > Options…: a sheet over the Settings window. Grassfield has the one option it can back: Prevent automatic
// sleeping on power adapter when the display is off (energy.preventSleep; the shell's idle module, shell/security/idle). Wake
// for network access, Slightly dim the display on battery and Optimize video streaming have no counterpart here. The switch
// writes at once; Done closes the sheet.
Sheet {
    id: root

    required property var store

    title: qsTr("Options")
    confirmText: qsTr("Done")
    showCancel: false

    SettingsGroup {
        footnote: qsTr("On battery the computer sleeps once the display has been off for a minute. The display turns off and the session locks as set in Lock Screen.")

        SettingsRow {
            title: qsTr("Prevent automatic sleeping on power adapter when the display is off")
            Toggle {
                accessibleName: qsTr("Prevent automatic sleeping on power adapter when the display is off")
                checked: root.store.value("energy.preventSleep")
                onToggled: c => root.store.set("energy.preventSleep", c)
            }
        }
    }
}
