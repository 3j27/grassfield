pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

SettingsPage {
    id: root

    required property var store
    // Settings Backend: reads notification-apps.json (the apps that have sent a notification, written by the shell).
    required property var backend

    title: qsTr("Notifications")

    // The senders the shell has seen (names only), refreshed when the shell rewrites the file.
    property var seenApps: []
    readonly property string appsFile: root.backend.configFile.replace(/[^/]*$/, "notification-apps.json")
    readonly property var overrides: root.store.value("notifications.appPreviews")
    // Seen apps and apps with an own setting, once each, by name.
    readonly property var apps: NotificationPrefs.appsToList(root.seenApps, root.overrides)
    readonly property var choices: [
        {id: "default", text: qsTr("Default")},
        {id: "always", text: qsTr("Always")},
        {id: "unlocked", text: qsTr("When Unlocked")},
        {id: "never", text: qsTr("Never")}
    ]

    function loadApps(): void {
        const f = root.backend.readText(root.appsFile);
        let names = [];
        if (f.exists && f.ok) {
            try {
                const parsed = JSON.parse(f.text);
                names = Array.isArray(parsed.apps) ? parsed.apps.filter(n => typeof n === "string") : [];
            } catch (e) {
                names = [];
            }
        }
        root.seenApps = names;
    }

    Component.onCompleted: {
        root.backend.watch(root.appsFile);
        root.loadApps();
    }

    Connections {
        target: root.backend

        function onFileChanged(p: string): void {
            if (p === root.appsFile)
                root.loadApps();
        }
    }

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
        footnote: qsTr("Never hides the text of notifications. When Unlocked hides it while the screen is locked. Each app below can use its own setting.")

        SettingsRow {
            title: qsTr("Show previews")
            SegmentedControl {
                accessibleName: qsTr("Show previews")
                model: [{id: "always", text: qsTr("Always")}, {id: "unlocked", text: qsTr("When Unlocked")}, {id: "never", text: qsTr("Never")}]
                value: root.store.value("notifications.previews")
                onPicked: id => root.store.set("notifications.previews", id)
            }
        }
    }

    SettingsGroup {
        id: perApp
        caption: qsTr("Application Notifications")
        footnote: root.apps.length === 0 ? qsTr("Apps appear here after they send a notification.") : qsTr("Default follows the Show previews setting above.")

        Repeater {
            model: root.apps

            delegate: SettingsRow {
                id: appRow

                required property string modelData

                title: modelData
                ComboBox {
                    accessibleName: qsTr("Show previews for %1").arg(appRow.modelData)
                    model: root.choices
                    value: NotificationPrefs.valueFor(root.overrides, appRow.modelData)
                    onPicked: id => root.store.set("notifications.appPreviews", NotificationPrefs.withValue(root.overrides, appRow.modelData, id))
                }
            }
        }
    }
}
