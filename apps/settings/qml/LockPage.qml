import QtQuick

SettingsPage {
    id: root

    required property var store

    title: qsTr("Lock Screen")

    readonly property int idleMinutes: root.store.value("lock.idleMinutes")
    readonly property var idleChoices: {
        const minutes = [0, 1, 2, 5, 10, 15, 30, 60];
        // A hand-edited value outside the list stays selectable.
        if (minutes.indexOf(root.idleMinutes) < 0)
            minutes.push(root.idleMinutes);
        minutes.sort((a, b) => a === 0 ? -1 : b === 0 ? 1 : a - b);
        return minutes.map(m => ({id: String(m), text: m === 0 ? qsTr("Never") : qsTr("%n minute(s)", "", m)}));
    }

    SettingsGroup {
        footnote: qsTr("The screen locks after this much time without keyboard or pointer input.")

        SettingsRow {
            title: qsTr("Lock screen after inactivity")
            Picker {
                accessibleName: qsTr("Lock screen after inactivity")
                model: root.idleChoices
                value: String(root.idleMinutes)
                onPicked: id => root.store.set("lock.idleMinutes", Number(id))
            }
        }
    }
}
