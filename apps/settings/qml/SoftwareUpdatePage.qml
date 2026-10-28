pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// General > Software Update (macOS 27 panes; docs/specs/updates.md U8, U11-U14, U21, U22; ADR-0033). The first group holds
// Automatic Updates and Beta Updates, each with its value and an (i) sheet (Main.qml opens it: infoRequested). The status group
// says what the last check found (SoftwareUpdateState.view): the releases with More Info…, Omarchy's, the other updates, Update
// Now; or why there is nothing to show, with the one action that helps (Set Up…, Repair…, Turn Off Grassfield Updates…).
// After an update that needs it, a group above asks to log out or restart (Main.qml asks first: endSessionRequested). The pane
// checks when it opens unless a check finished less than a minute ago (U8).
SettingsPage {
    id: root

    // SoftwareUpdateState (one per window: the badge reads it too).
    required property var updates
    required property var store
    required property var system

    // "automatic", "beta", "notes" (Grassfield's release notes) or "others" (the other updates).
    signal infoRequested(string topic)
    // "logout" or "restart".
    signal endSessionRequested(string action)

    title: qsTr("Software Update")

    readonly property var view: root.updates.view
    readonly property bool waiting: root.updates.waitingForPermission
    // The releases found by the last success, kept through a failure, an update and `blocking` (ADR-0033 d.6).
    readonly property bool hasReleases: root.view.grassfield !== null || root.view.omarchy !== null || root.view.others > 0

    // A time as the pane says it: "Today, 10:42", or the date and time.
    function when(ms: double): string {
        if (ms <= 0)
            return "";
        const d = new Date(ms);
        const today = new Date();
        const time = d.toLocaleTimeString(Qt.locale(), Locale.ShortFormat);
        if (d.toDateString() === today.toDateString())
            return qsTr("Today, %1").arg(time);
        return d.toLocaleDateString(Qt.locale(), Locale.ShortFormat) + " " + time;
    }

    // The status's headline and the line under it.
    readonly property string headline: {
        switch (root.view.kind) {
        case "checking":
            return qsTr("Checking for updates…");
        case "update-running":
            return qsTr("An update is running in Omarchy's terminal");
        case "up-to-date":
            return qsTr("This computer is up to date");
        case "available":
            return root.hasReleases ? qsTr("Updates are available") : qsTr("This computer is up to date");
        case "failed":
            return qsTr("Software Update could not check for updates");
        case "blocking":
            return qsTr("Grassfield's package repository cannot be used");
        case "repair":
            return qsTr("Grassfield updates need to be repaired");
        case "not-set-up":
            return root.updates.buildReady ? qsTr("Grassfield updates are not set up") : qsTr("Software Update is not available in this build");
        }
        return root.updates.channel === "custom" ? qsTr("Grassfield updates need to be repaired") : qsTr("Software Update has not checked for updates yet");
    }

    readonly property string detail: {
        const installed = root.view.installed;
        switch (root.view.kind) {
        case "update-running":
            return qsTr("Software Update checks again when it has finished.");
        case "up-to-date":
        case "available":
            if (root.hasReleases)
                return "";
            return installed.grassfield !== "" && installed.omarchy !== ""
                ? qsTr("Grassfield %1, Omarchy %2").arg(SoftwareUpdateLogic.displayVersion(installed.grassfield)).arg(SoftwareUpdateLogic.displayVersion(installed.omarchy))
                : "";
        case "failed":
            if (root.view.error === "offline")
                return qsTr("This computer is offline.");
            return root.view.message !== "" ? qsTr("The checker said: %1").arg(root.view.message) : qsTr("The package servers did not answer.");
        case "blocking":
            return qsTr("Until it works again, every system update stops, security fixes included. Turn Grassfield updates off to update the system now; you can set them up again later.");
        case "repair":
            return qsTr("Omarchy rewrote the system's package configuration, or it was changed by hand. Repair puts Grassfield's repository back; it asks for an administrator's password.");
        case "not-set-up":
            return root.updates.buildReady ? qsTr("Set Up adds Grassfield's package repository to the system; it asks for an administrator's password.")
                : qsTr("This build has no package repository or signing key yet.");
        }
        return root.view.repair ? qsTr("The system's package configuration points Grassfield updates elsewhere. Repair puts Grassfield's repository back; it asks for an administrator's password.") : "";
    }

    // The one action of the status (U13, U22): "setup", "repair", "off" or "".
    readonly property string fix: {
        if (root.view.kind === "not-set-up")
            return root.updates.buildReady ? "setup" : "";
        if (root.view.kind === "blocking")
            return "off";
        if (root.view.kind === "repair" || (root.view.repair && root.view.kind !== "checking" && root.view.kind !== "update-running"))
            return "repair";
        return "";
    }

    function runFix(): void {
        if (root.fix === "setup")
            root.updates.setChannel("stable", "setup");
        else if (root.fix === "repair")
            root.updates.setChannel("repair", "repair");
        else if (root.fix === "off")
            root.updates.setChannel("off", "off");
    }

    // One line when a channel change failed (U12: "Beta updates were not changed: not allowed"); the tool's reason, its
    // "not allowed" in the UI language.
    function failure(action: string): string {
        const raw = root.updates.channelError;
        if (raw === "" || root.updates.lastAction !== action)
            return "";
        const reason = raw === "-" ? qsTr("the change failed") : raw.replace(/^grassfield-channel-set:\s*/, "").indexOf("not allowed") === 0 ? qsTr("not allowed")
            : raw.replace(/^grassfield-channel-set:\s*/, "");
        switch (action) {
        case "beta":
            return qsTr("Beta updates were not changed: %1").arg(reason);
        case "setup":
            return qsTr("Grassfield updates were not set up: %1").arg(reason);
        case "repair":
            return qsTr("Grassfield updates were not repaired: %1").arg(reason);
        }
        return qsTr("Grassfield updates were not turned off: %1").arg(reason);
    }

    Component.onCompleted: {
        root.updates.readRestart();
        root.updates.checkIfStale(Date.now());
    }

    // U14: after an update, what finishes it. A restart covers a log out.
    SettingsGroup {
        visible: root.updates.restartNeeded || root.updates.logoutPending

        SettingsRow {
            title: root.updates.restartNeeded ? qsTr("Restart to finish updating") : qsTr("Log out to finish updating Grassfield")
            subtitle: root.updates.restartNeeded ? qsTr("Part of the update is used only after the computer restarts.")
                : qsTr("The new version of Grassfield starts when you log in again.")

            Button {
                push: true
                text: root.updates.restartNeeded ? qsTr("Restart…") : qsTr("Log Out…")
                onClicked: root.endSessionRequested(root.updates.restartNeeded ? "restart" : "logout")
            }
        }
    }

    SettingsGroup {
        footnote: root.failure("beta")

        SettingsRow {
            title: qsTr("Automatic Updates")
            valueText: root.store.value("updates.automaticCheck") ? qsTr("Check for updates") : qsTr("Off")

            InfoButton {
                accessibleName: qsTr("Automatic Updates details")
                onClicked: root.infoRequested("automatic")
            }
        }
        SettingsRow {
            title: qsTr("Beta Updates")
            valueText: root.waiting && root.updates.lastAction === "beta" ? qsTr("Waiting for permission…")
                : root.updates.channel === "beta" ? qsTr("Grassfield Beta") : qsTr("Off")

            InfoButton {
                accessibleName: qsTr("Beta Updates details")
                onClicked: root.infoRequested("beta")
            }
        }
    }

    SettingsGroup {
        footnote: root.failure("setup") || root.failure("repair") || root.failure("off")

        SettingsRow {
            title: root.headline
            subtitle: root.waiting && root.updates.lastAction !== "beta" ? qsTr("Waiting for permission…") : root.detail

            Spinner {
                visible: root.view.kind === "checking" || root.view.kind === "update-running"
                running: visible
            }

            Button {
                visible: root.fix !== ""
                enabled: !root.waiting
                push: true
                destructive: root.fix === "off"
                text: root.fix === "setup" ? qsTr("Set Up…") : root.fix === "repair" ? qsTr("Repair…") : qsTr("Turn Off Grassfield Updates…")
                onClicked: root.runFix()
            }
        }

        // The releases (U21): Grassfield's with its notes, Omarchy's, the other packages.
        SettingsRow {
            visible: root.view.grassfield !== null
            glyph: "grassfield-logo"
            tileColor: "green"
            title: root.view.grassfield ? qsTr("Grassfield %1").arg(SoftwareUpdateLogic.releaseName(root.view.grassfield.available, root.view.grassfield.installed)) : ""
            subtitle: root.view.grassfield ? qsTr("Installed: %1").arg(SoftwareUpdateLogic.displayVersion(root.view.grassfield.installed)) : ""

            LinkText {
                text: qsTr("More Info…")
                onActivated: root.infoRequested("notes")
            }
        }
        SettingsRow {
            visible: root.view.omarchy !== null
            glyph: "laptop"
            title: root.view.omarchy ? qsTr("Omarchy %1").arg(SoftwareUpdateLogic.displayVersion(root.view.omarchy.available)) : ""
            subtitle: qsTr("Omarchy's release notes are on its project page.")
        }
        SettingsRow {
            visible: root.view.others > 0
            glyph: "grid"
            title: root.view.others === 1 ? qsTr("1 other update") : qsTr("%1 other updates").arg(root.view.others)
            subtitle: qsTr("System packages, updated with Omarchy's update.")

            InfoButton {
                accessibleName: qsTr("Other updates")
                onClicked: root.infoRequested("others")
            }
        }
        // While `blocking`, every Omarchy update fails at its first sync (U22): Update Now waits for Turn Off… or the repository.
        SettingsRow {
            visible: root.hasReleases && root.view.kind !== "checking"
            title: !root.updates.canUpdate ? qsTr("Update Now needs Omarchy's update command, which this system does not have.")
                : root.view.kind === "blocking" ? qsTr("Omarchy's update cannot run while Grassfield's repository cannot be used.")
                : qsTr("Omarchy's update installs everything listed here.")
            subtitle: root.updates.canUpdate && root.view.kind !== "blocking" ? qsTr("It runs in Omarchy's terminal and asks before it starts.") : ""

            Button {
                primary: true
                push: true
                text: qsTr("Update Now")
                enabled: root.updates.canUpdate && !root.updates.updateRunning && root.view.kind !== "blocking"
                onClicked: root.updates.updateNow()
            }
        }

        // When the last check ran, and Check Now (U8).
        SettingsRow {
            title: root.view.checkedAt > 0 ? qsTr("Last checked: %1").arg(root.when(root.view.checkedAt)) : qsTr("Not checked yet")
            subtitle: root.view.kind === "failed" && root.view.lastSuccessAt > 0 ? qsTr("Last successful check: %1").arg(root.when(root.view.lastSuccessAt)) : ""

            Button {
                push: true
                text: qsTr("Check Now")
                enabled: !root.updates.checking && !root.updates.updateRunning
                onClicked: root.updates.check()
            }
        }
    }

    DevNote {
        system: root.system
    }
}
