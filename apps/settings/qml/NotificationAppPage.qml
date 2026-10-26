pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Notifications > an app (macOS 27: the app's sub-pane, opened from its row; the toolbar's back button returns): its alert
// style and its previews. Writes notifications.appStyles and notifications.appPreviews through NotificationPrefs.
SettingsPage {
    id: root

    required property var store
    // The app's name, as the shell saw it (untrusted: plain text).
    property string app: ""

    title: root.app

    readonly property var styles: root.store.value("notifications.appStyles")
    readonly property var overrides: root.store.value("notifications.appPreviews")

    SettingsGroup {
        footnote: qsTr("Banners go away by themselves, Alerts stay until you dismiss them, None shows no banner: the notifications still collect in the Notifications panel. Default follows Show previews in Notifications.")

        SettingsRow {
            title: qsTr("Alert style")
            ComboBox {
                inline: true
                accessibleName: qsTr("Alert style for %1").arg(root.app)
                model: [{id: "banners", text: qsTr("Banners")}, {id: "alerts", text: qsTr("Alerts")}, {id: "none", text: qsTr("None")}]
                value: NotificationPrefs.styleFor(root.styles, root.app)
                onPicked: id => root.store.set("notifications.appStyles", NotificationPrefs.withStyle(root.styles, root.app, id))
            }
        }

        SettingsRow {
            title: qsTr("Show previews")
            ComboBox {
                inline: true
                accessibleName: qsTr("Show previews for %1").arg(root.app)
                model: [{id: "default", text: qsTr("Default")}, {id: "always", text: qsTr("Always")}, {id: "unlocked", text: qsTr("When Unlocked")}, {id: "never", text: qsTr("Never")}]
                value: NotificationPrefs.valueFor(root.overrides, root.app)
                onPicked: id => root.store.set("notifications.appPreviews", NotificationPrefs.withValue(root.overrides, root.app, id))
            }
        }
    }
}
