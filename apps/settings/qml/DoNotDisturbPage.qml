import QtQuick
import Grassfield.Ui

// Focus > Do Not Disturb (macOS 27: the focus's sub-pane, its switch beside its tile and name; the toolbar's back button
// returns): notifications.dnd.
SettingsPage {
    id: root

    required property var store

    title: qsTr("Do Not Disturb")

    SettingsGroup {
        footnote: qsTr("Silences banners except critical ones; notifications still collect in the Notifications panel.")

        LargeRow {
            text: qsTr("Do Not Disturb")
            glyph: "moon"
            tileColor: "purple"
            chevron: false

            Toggle {
                accessibleName: qsTr("Do Not Disturb")
                checked: root.store.value("notifications.dnd")
                onToggled: c => root.store.set("notifications.dnd", c)
            }
        }
    }
}
