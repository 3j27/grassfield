pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Settings > Notifications as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Notifications): the header
// card, the Notifications panel (what it is, then how previews show and how long the panel keeps notifications), and the
// apps that have sent notifications, each opening its own sub-pane (appRequested; Main shows NotificationAppPage). Do Not
// Disturb is in Focus, as on macOS.
SettingsPage {
    id: root

    required property var store
    // Settings Backend: reads notification-apps.json (the apps that have sent a notification, written by the shell).
    required property var backend

    signal appRequested(string name)

    title: qsTr("Notifications")

    // The senders the shell has seen (names only), refreshed when the shell rewrites the file.
    property var seenApps: []
    readonly property string appsFile: root.backend.configFile.replace(/[^/]*$/, "notification-apps.json")
    readonly property var overrides: root.store.value("notifications.appPreviews")
    // Seen apps and apps with an own setting, once each, by name.
    readonly property var apps: NotificationPrefs.appsToList(root.seenApps, root.overrides)
    readonly property var styles: root.store.value("notifications.appStyles")

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

    // An app's icon in the icon theme, guessed from its name ("Thunderbird" -> thunderbird); a name that is not a plain icon
    // name (a path, other characters: the senders are untrusted) gets the apps tile.
    function iconFor(name: string): string {
        const id = String(name).trim().toLowerCase().replace(/\s+/g, "-");
        return /^[a-z0-9][a-z0-9._-]{0,127}$/.test(id) ? id : "";
    }

    function styleText(id: string): string {
        return id === "alerts" ? qsTr("Alerts") : id === "none" ? qsTr("None") : qsTr("Banners");
    }

    function previewText(id: string): string {
        return id === "always" ? qsTr("Always") : id === "unlocked" ? qsTr("When Unlocked") : qsTr("Never");
    }

    // What an app's notifications do, under its name (macOS: Badges, Sounds, Desktop): its alert style, and its previews
    // when it has its own setting.
    function summary(name: string): string {
        const style = root.styleText(NotificationPrefs.styleFor(root.styles, name));
        const previews = NotificationPrefs.valueFor(root.overrides, name);
        return previews === "default" ? style : qsTr("%1, previews: %2").arg(style).arg(root.previewText(previews));
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

    PaneBanner {
        icon: "bell"
        tileColor: "red"
        title: qsTr("Notifications")
        text: qsTr("Choose how notifications appear, how long they are kept, and how each app's notifications show.")
    }

    SettingsGroup {
        caption: qsTr("Notifications Panel")
        captionDetail: qsTr("The Notifications panel shows your notifications on the right of the screen. Click the clock in the menu bar to show or hide it.")

        SettingsRow {
            title: qsTr("Show previews")
            ComboBox {
                inline: true
                accessibleName: qsTr("Show previews")
                model: [{id: "always", text: qsTr("Always")}, {id: "unlocked", text: qsTr("When Unlocked")}, {id: "never", text: qsTr("Never")}]
                value: root.store.value("notifications.previews")
                onPicked: id => root.store.set("notifications.previews", id)
            }
        }

        // Grassfield's own: how long the panel keeps notifications after a restart (the text of an app whose previews are
        // Never is not kept).
        SettingsRow {
            title: qsTr("Keep history")
            ComboBox {
                inline: true
                accessibleName: qsTr("Keep history")
                model: [{id: "week", text: qsTr("1 Week")}, {id: "day", text: qsTr("1 Day")}, {id: "never", text: qsTr("Never")}]
                value: root.store.value("notifications.history")
                onPicked: id => root.store.set("notifications.history", id)
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Application Notifications")
        footnote: root.apps.length === 0 ? qsTr("Apps appear here after they send a notification.") : ""

        Repeater {
            model: root.apps

            delegate: LargeRow {
                required property string modelData

                text: modelData
                subtitle: root.summary(modelData)
                useAppIcon: true
                appIcon: root.iconFor(modelData)
                pictureX: Tokens.settingsAppRowIconX
                titleX: Tokens.settingsAppRowTitleX
                onClicked: root.appRequested(modelData)
            }
        }
    }
}
