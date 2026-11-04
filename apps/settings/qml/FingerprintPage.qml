pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Fingerprint.js" as Fingerprint
import "Setups.js" as Setups

// Fingerprint & Security Key (ADR-0045 OC-6, OC-0.7), after Lock Screen, in the place of macOS 27's Touch ID & Password
// (superseding the owner decision that left it out, for exactly what this pane holds). Two parts:
//   Fingerprint, shown only where Omarchy's omarchy-hw-fingerprint finds a reader (macOS shows Touch ID only on a Mac that has
//   it). Before Omarchy's setup has run (fprintd missing, or none of the sign-in rules it edits uses it): Set Up…, Omarchy's
//   omarchy-setup-security-fingerprint in its terminal behind a sheet that says why (it installs the driver and edits the PAM
//   files). After it: the enrolled fingers as macOS lists them, each with Delete…, and Add Fingerprint… (fprintd over D-Bus,
//   FingerprintEnrollSheet.qml; fprintd asks polkit), then where the fingerprint is used, read from the files Omarchy's setup
//   edits: the lock screen (Grassfield's lock uses Omarchy's PAM service omarchy-lock-fingerprint when it exists),
//   administrator prompts (/etc/pam.d/polkit-1) and sudo (/etc/pam.d/sudo).
//   Security Key (FIDO2): Omarchy's omarchy-setup-security-fido2 and -remove in its terminal (no service registers a key); used
//   for administrator prompts and sudo, never for the lock screen. Its registration is /etc/fido2/fido2, one file for the
//   system (Omarchy's), read for its presence only.
// Everything is read-only here but the actions; the state is read again when Settings is active again (the terminal closed).
SettingsPage {
    id: root

    required property var backend
    required property var system

    // Main.qml opens the sheets: Omarchy's terminal (TerminalSetupSheet), the enrolment and the deletion's confirmation.
    signal setupRequested(string id)
    signal enrollRequested(string finger, int stages)
    signal deleteRequested(string finger)

    title: qsTr("Fingerprint & Security Key")

    // omarchy-hw-fingerprint's answer: true, false, or null while unknown (or without Omarchy's command: no reader shown).
    property var reader: null
    property bool fprintd: false
    property var fingerUse: ({lock: false, admin: false, sudo: false})
    property var keyUse: ({lock: false, admin: false, sudo: false})
    property bool keyTools: false
    property bool keyRegistered: false
    // fprint.state: null until it answered or when it failed (stateError says why).
    property var prints: null
    property string stateError: ""

    readonly property bool fingerprintSetUp: root.fprintd && Setups.anyUse(root.fingerUse)
    readonly property bool keySetUp: root.keyTools && root.keyRegistered && Setups.anyUse(root.keyUse)
    readonly property bool deleting: (root.backend.pendingActions ?? {})["fprint.act"] !== undefined

    function refresh(): void {
        const sudo = root.backend.readText(Setups.FILES.pamSudo).text;
        const polkit = root.backend.readText(Setups.FILES.pamPolkit).text;
        root.fingerUse = Setups.fingerprintUse(sudo, polkit, root.backend.readText(Setups.FILES.pamLockFingerprint).exists === true);
        root.keyUse = Setups.securityKeyUse(sudo, polkit);
        root.fprintd = root.backend.hasCommand("fprintd-enroll");
        root.keyTools = root.backend.hasCommand("pamu2fcfg");
        const keys = root.backend.readText(Setups.FILES.fido2Keys);
        root.keyRegistered = keys.exists === true && keys.text.trim() !== "";
        if (root.backend.hasCommand("omarchy-hw-fingerprint"))
            root.backend.readOnlyQuery(Setups.QUERY.fingerprintReader, "fprint.reader");
        else
            root.reader = false;
        if (root.fprintd)
            root.system.queryBus("fprint.state", "fprint.state");
    }

    // "Right index finger" (fprintd's name, translated).
    function fingerText(finger: string): string {
        return Fingerprint.NAMES[finger] !== undefined ? qsTranslate("Fingerprint", Fingerprint.NAMES[finger]) : finger;
    }

    function useText(on: bool): string {
        return on ? qsTr("On") : qsTr("Off");
    }

    Component.onCompleted: root.refresh()


    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "fprint.reader") {
                root.reader = ok;
            } else if (tag === "fprint.state") {
                root.prints = ok ? Fingerprint.parseState(output) : null;
                if (ok)
                    root.stateError = "";
            } else if (tag === "fprint.act") {
                root.refresh();
            }
        }

        function onFailed(tag: string, reason: string): void {
            if (tag === "fprint.state")
                root.stateError = reason !== "" ? reason : "-";
        }
    }

    PaneBanner {
        icon: "fingerprint"
        tileColor: "red"
        title: qsTr("Fingerprint & Security Key")
        text: qsTr("Use your fingerprint or a security key instead of your password to unlock this computer, approve administrator prompts and run sudo.")
    }

    // Before Omarchy's setup: one row with Set Up….
    SettingsGroup {
        visible: root.reader === true && !root.fingerprintSetUp

        SettingsRow {
            title: qsTr("Fingerprint")
            subtitle: qsTr("Not set up")
            Button {
                push: true
                text: qsTr("Set Up…")
                Accessible.name: qsTr("Set up fingerprint")
                onClicked: root.setupRequested("fingerprint-setup")
            }
        }
    }

    // The enrolled fingers (macOS lists each with its name), Add Fingerprint… and Delete….
    SettingsGroup {
        visible: root.reader === true && root.fingerprintSetUp
        caption: qsTr("Fingerprints")
        footnote: root.stateError !== "" ? (root.stateError === "-" ? qsTr("The fingerprint reader does not answer.") : qsTr("The fingerprint reader does not answer: %1.").arg(root.stateError))
            : root.prints !== null && !root.prints.present ? qsTr("fprintd finds no fingerprint reader.") : ""

        Repeater {
            model: root.prints !== null ? root.prints.fingers : []

            SettingsRow {
                id: fingerRow
                required property string modelData
                title: root.fingerText(fingerRow.modelData)
                glyph: "fingerprint"
                tileColor: "red"

                Button {
                    push: true
                    enabled: !root.deleting
                    text: qsTr("Delete…")
                    Accessible.name: qsTr("Delete the fingerprint %1").arg(fingerRow.title)
                    onClicked: root.deleteRequested(fingerRow.modelData)
                }
            }
        }

        SettingsRow {
            visible: root.prints !== null && root.prints.present && root.prints.fingers.length === 0
            title: qsTr("No fingerprint enrolled")
        }

        SettingsRow {
            implicitHeight: (Positioner.index > 0 ? 1 : 0) + Tokens.settingsPushRowHeight
            visible: root.prints !== null && root.prints.present && Fingerprint.nextFinger(root.prints.fingers) !== ""

            Button {
                push: true
                enabled: !root.deleting
                text: qsTr("Add Fingerprint…")
                onClicked: root.enrollRequested(Fingerprint.nextFinger(root.prints.fingers), root.prints.stages)
            }
        }
    }

    // Where Omarchy's setup turned the fingerprint on (read from the files it edits; Settings changes none of them).
    SettingsGroup {
        visible: root.reader === true && root.fingerprintSetUp
        caption: qsTr("Use fingerprint for")
        footnote: qsTr("Omarchy's setup turns these on together. When the reader is not available (the lid is closed), the password is asked instead.")

        SettingsRow {
            title: qsTr("Unlocking the lock screen")
            valueText: root.useText(root.fingerUse.lock)
        }
        SettingsRow {
            title: qsTr("Administrator prompts")
            valueText: root.useText(root.fingerUse.admin)
        }
        SettingsRow {
            title: qsTr("sudo in Terminal")
            valueText: root.useText(root.fingerUse.sudo)
        }
        SettingsRow {
            implicitHeight: (Positioner.index > 0 ? 1 : 0) + Tokens.settingsPushRowHeight

            Button {
                push: true
                text: qsTr("Remove Fingerprint Setup…")
                onClicked: root.setupRequested("fingerprint-remove")
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Security Key")
        captionDetail: qsTr("A FIDO2 security key that you plug in and touch. It is used for administrator prompts and sudo, not for the lock screen.")

        SettingsRow {
            title: qsTr("Security key")
            subtitle: !root.keySetUp ? qsTr("Not set up")
                : root.keyUse.admin && root.keyUse.sudo ? qsTr("Used for administrator prompts and sudo")
                : root.keyUse.admin ? qsTr("Used for administrator prompts")
                : qsTr("Used for sudo")
            glyph: "key"
            tileColor: "graphite"

            Button {
                push: true
                text: root.keySetUp ? qsTr("Remove…") : qsTr("Set Up…")
                Accessible.name: root.keySetUp ? qsTr("Remove the security key") : qsTr("Set up a security key")
                onClicked: root.setupRequested(root.keySetUp ? "fido2-remove" : "fido2-setup")
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "fprint.act"
    }

    DevNote {
        system: root.system
    }

    // The terminal closed (or the polkit sheet answered): Settings is active again.
    ActiveAgain {
        onReturned: root.refresh()
    }
}
