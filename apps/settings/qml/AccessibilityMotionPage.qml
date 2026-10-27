import QtQuick
import Grassfield.Ui

// Accessibility > Motion (macOS 15 and later): Reduce motion, live in the shell (windows and Spaces included). The same key
// as in Appearance and Quick Settings. Not built: macOS's Auto-play animated images, Dim flashing lights and Prefer
// non-blinking cursor (no keys).
SettingsPage {
    id: root

    required property var store

    title: qsTr("Motion")

    SettingsGroup {
        SettingsRow {
            title: qsTr("Reduce motion")
            subtitle: qsTr("Animations are shortened to quick crossfades, windows and Spaces included.")
            Toggle {
                accessibleName: qsTr("Reduce motion")
                checked: root.store.value("accessibility.reduceMotion")
                onToggled: c => root.store.set("accessibility.reduceMotion", c)
            }
        }
    }
}
