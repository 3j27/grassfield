pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Settings > Lock Screen as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Lock Screen): when the displays
// turn off without input (on battery, only with a battery, and on the power adapter), when the session asks for the password,
// then what the lock screen shows: the account's name and picture, and a message (Set… asks for it: messageRequested, Main
// opens LockMessageSheet). The shell follows the keys live (shell/security/idle, shell/security/lock; ADR-0010).
SettingsPage {
    id: root

    required property var store
    // The battery row is there on a computer with a battery only (Main reads it from the power state).
    property bool hasBattery: false

    signal messageRequested

    title: qsTr("Lock Screen")

    // A pop-up's choices for a number of minutes: `steps` with their names, and a hand-edited value outside them as it is.
    function minuteChoices(steps: var, now: int, name: var): var {
        const all = steps.slice();
        if (all.indexOf(now) < 0)
            all.push(now);
        all.sort((a, b) => a === 0 ? -1 : b === 0 ? 1 : a - b);
        return all.map(m => ({id: String(m), text: name(m)}));
    }

    // "For 2 minutes", "For 1 hour" (macOS's names for the display-off delays); 0 is Never.
    function forText(m: int): string {
        if (m === 0)
            return qsTr("Never");
        if (m % 60 === 0)
            return m === 60 ? qsTr("For 1 hour") : qsTr("For %1 hours").arg(m / 60);
        return m === 1 ? qsTr("For 1 minute") : qsTr("For %1 minutes").arg(m);
    }

    // "After 5 minutes", "After 1 hour"; 0 is Never.
    function afterText(m: int): string {
        if (m === 0)
            return qsTr("Never");
        if (m % 60 === 0)
            return m === 60 ? qsTr("After 1 hour") : qsTr("After %1 hours").arg(m / 60);
        return m === 1 ? qsTr("After 1 minute") : qsTr("After %1 minutes").arg(m);
    }

    readonly property var displayOffSteps: [0, 1, 2, 3, 5, 10, 20, 30, 60, 120, 180]

    // A display turns off before the session locks (on battery by default: 2 minutes against 5): a dark display is not a locked
    // one, so the note under the delays says when it comes back without the password (macOS notes the same in its Screen Saver
    // sheet). 0 is Never.
    readonly property int idleMinutes: root.store.value("lock.idleMinutes")
    readonly property bool offFirst: {
        const delays = [root.store.value("lock.displayOffPower")].concat(root.hasBattery ? [root.store.value("lock.displayOffBattery")] : []);
        return delays.some(m => m > 0 && (root.idleMinutes === 0 || m < root.idleMinutes));
    }
    // ADR-0040 IQ-T4 A: a display that turns off for inactivity locks the session, at once or after a delay, unless "Never".
    readonly property string requireAfter: root.store.value("lock.requirePasswordAfterDisplayOff")
    readonly property bool anyDisplayOff: [root.store.value("lock.displayOffPower")].concat(root.hasBattery ? [root.store.value("lock.displayOffBattery")] : []).some(m => m > 0)
    readonly property bool displayLocks: root.requireAfter !== "never" && root.anyDisplayOff
    readonly property string lockNote: root.displayLocks
        ? (root.idleMinutes === 0
            ? qsTr("The session locks when a display turns off for inactivity, as set below; otherwise it does not lock by itself.")
            : root.requireAfter === "immediately"
            ? qsTr("The session locks after this much time without keyboard or pointer input, or as soon as a display turns off.")
            : qsTr("The session locks after this much time without keyboard or pointer input, or once a display has been off for the time set below. Until then, any input turns it back on without the password."))
        : root.idleMinutes === 0
        ? qsTr("The session does not lock by itself: a display that turned off comes back on with any input, without the password.")
        : root.offFirst
        ? qsTr("The session locks after this much time without keyboard or pointer input. A display that turns off earlier is not locked: until the session locks, any input turns it back on without the password.")
        : qsTr("The session locks after this much time without keyboard or pointer input, whether the displays are on or off.")

    // macOS's Require password after the display is turned off.
    readonly property var requireAfterModel: [{id: "immediately", text: qsTr("Immediately")}, {id: "5s", text: qsTr("After 5 seconds")}, {id: "1m", text: qsTr("After 1 minute")}, {id: "5m", text: qsTr("After 5 minutes")}, {id: "15m", text: qsTr("After 15 minutes")}, {id: "1h", text: qsTr("After 1 hour")}, {id: "never", text: qsTr("Never")}]

    SettingsGroup {
        footnote: root.lockNote

        SettingsRow {
            visible: root.hasBattery
            title: qsTr("Turn display off on battery when inactive")
            ComboBox {
                inline: true
                accessibleName: qsTr("Turn display off on battery when inactive")
                model: root.minuteChoices(root.displayOffSteps, root.store.value("lock.displayOffBattery"), root.forText)
                value: String(root.store.value("lock.displayOffBattery"))
                onPicked: id => root.store.set("lock.displayOffBattery", Number(id))
            }
        }

        SettingsRow {
            // macOS names the power adapter only where there is a battery.
            title: root.hasBattery ? qsTr("Turn display off on power adapter when inactive") : qsTr("Turn display off when inactive")
            ComboBox {
                inline: true
                accessibleName: root.hasBattery ? qsTr("Turn display off on power adapter when inactive") : qsTr("Turn display off when inactive")
                model: root.minuteChoices(root.displayOffSteps, root.store.value("lock.displayOffPower"), root.forText)
                value: String(root.store.value("lock.displayOffPower"))
                onPicked: id => root.store.set("lock.displayOffPower", Number(id))
            }
        }

        // ADR-0040 IQ-T4 A: when a display that turned off locks the session.
        SettingsRow {
            title: qsTr("Require password after the display turns off")
            ComboBox {
                inline: true
                accessibleName: qsTr("Require password after the display turns off")
                model: root.requireAfterModel
                value: root.requireAfter
                onPicked: id => root.store.set("lock.requirePasswordAfterDisplayOff", id)
            }
        }

        // Grassfield locks after this much time without input, whether the displays are on or off (lock.idleMinutes).
        SettingsRow {
            title: qsTr("Require password after inactivity")
            ComboBox {
                inline: true
                accessibleName: qsTr("Require password after inactivity")
                model: root.minuteChoices([0, 1, 2, 5, 10, 15, 30, 60], root.store.value("lock.idleMinutes"), root.afterText)
                value: String(root.store.value("lock.idleMinutes"))
                onPicked: id => root.store.set("lock.idleMinutes", Number(id))
            }
        }
    }

    SettingsGroup {
        SettingsRow {
            title: qsTr("Show user name and photo")
            Toggle {
                accessibleName: qsTr("Show user name and photo")
                checked: root.store.value("lock.showUser")
                onToggled: c => root.store.set("lock.showUser", c)
            }
        }

        SettingsRow {
            title: qsTr("Show message when locked")
            Row {
                spacing: Tokens.settingsAccessoryGap

                Toggle {
                    anchors.verticalCenter: parent.verticalCenter
                    accessibleName: qsTr("Show message when locked")
                    checked: root.store.value("lock.showMessage")
                    onToggled: c => {
                        root.store.set("lock.showMessage", c);
                        // Turned on without a message yet: ask for one (macOS opens the same sheet from Set…).
                        if (c && root.store.value("lock.message") === "")
                            root.messageRequested();
                    }
                }

                Button {
                    anchors.verticalCenter: parent.verticalCenter
                    push: true
                    enabled: root.store.value("lock.showMessage")
                    text: qsTr("Set…")
                    Accessible.name: qsTr("Set the message")
                    onClicked: root.messageRequested()
                }
            }
        }
    }
}
