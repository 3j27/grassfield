import QtQuick
import Grassfield.Ui

SettingsPage {
    id: root

    required property var store

    title: qsTr("Notifications")

    SettingsGroup {
        SettingsRow {
            title: qsTr("Do Not Disturb")
            subtitle: qsTr("Silences banners except critical ones; notifications still collect in the Notifications panel.")
            Toggle {
                accessibleName: qsTr("Do Not Disturb")
                checked: root.store.value("notifications.dnd")
                onToggled: c => root.store.set("notifications.dnd", c)
            }
        }
    }

    SettingsGroup {
        footnote: qsTr("Never hides the text of notifications. Until the lock screen reports its state to the notification service, When Unlocked behaves like Always.")

        SettingsRow {
            title: qsTr("Show previews")
            Segmented {
                accessibleName: qsTr("Show previews")
                model: [{id: "always", text: qsTr("Always")}, {id: "unlocked", text: qsTr("When Unlocked")}, {id: "never", text: qsTr("Never")}]
                value: root.store.value("notifications.previews")
                onPicked: id => root.store.set("notifications.previews", id)
            }
        }
    }
}
