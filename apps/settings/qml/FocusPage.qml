import QtQuick

// Settings > Focus as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Focus): the focuses, each opening its
// sub-pane. Grassfield has one, Do Not Disturb (notifications.dnd); its row says whether it is on.
SettingsPage {
    id: root

    required property var store

    // Opens a sub-pane by its section id (Main.qml).
    signal open(string id)

    title: qsTr("Focus")

    SettingsGroup {
        footnote: qsTr("Do Not Disturb is also in Quick Settings and, while it is on, in the menu bar.")

        LargeRow {
            text: qsTr("Do Not Disturb")
            subtitle: root.store.value("notifications.dnd") ? qsTr("On") : ""
            glyph: "moon"
            tileColor: "purple"
            onClicked: root.open("dnd")
        }
    }
}
