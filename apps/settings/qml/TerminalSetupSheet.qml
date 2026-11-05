import QtQuick
import Grassfield.Ui
import "Setups.js" as Setups

// The sheet before a setup that only Omarchy's terminal can do (ADR-0045 OC-0.4, OC-0.7: installing a package, editing the
// system's sign-in rules, the FIDO2 key's registration, the hibernation swap file and start-up files): what Omarchy's command
// will do, and why a Terminal window opens, as macOS says what an installer will do before it asks for the password. Open
// Terminal starts the exact command (Setups.launchArgv, systemguard.cpp isLaunch) through SystemService, so never in a dev
// session; the pane reads its state again when Settings is active again (the terminal closed).
Sheet {
    id: root

    required property var system
    required property var backend
    property string setupId: ""

    // The setup started (the pane may say that it waits for the terminal).
    signal launched(string setupId)

    readonly property var texts: ({
            "fingerprint-setup": {title: qsTr("Set Up Fingerprint"),
                message: qsTr("Omarchy installs the fingerprint reader's driver, enrols your right index finger and turns fingerprint on for the lock screen, administrator prompts and sudo. It runs in a Terminal window because it installs software and changes how this computer checks who you are; it asks for your password there.")},
            "fingerprint-remove": {title: qsTr("Remove Fingerprint Setup"),
                message: qsTr("Omarchy turns fingerprint off for the lock screen, administrator prompts and sudo, and removes the reader's driver. It runs in a Terminal window and asks for your password there.")},
            "fido2-setup": {title: qsTr("Set Up Security Key"),
                message: qsTr("Omarchy installs the security key tools, registers the key you plug in and touch, and turns it on for administrator prompts and sudo. It runs in a Terminal window because it installs software and changes how this computer checks who you are; it asks for your password there.")},
            "fido2-remove": {title: qsTr("Remove Security Key"),
                message: qsTr("Omarchy turns the security key off for administrator prompts and sudo, deletes its registration and removes the security key tools. It runs in a Terminal window and asks for your password there.")},
            "sshd-setup": {title: qsTr("Set Up Remote Login"),
                message: qsTr("Omarchy installs the SSH server if needed and starts it, opens the firewall's SSH port, adds your public key (from GitHub or pasted) and turns password logins off. It runs in a Terminal window because it asks for your key there. Afterwards the switch turns Remote Login on and off here.")},
            "drive-password": {title: qsTr("Change Disk Password"),
                message: qsTr("The disk service does not answer, so Omarchy changes the start-up disk's password in a Terminal window: it asks for the new password twice, then for the current one.")},
            "hibernation-setup": {title: qsTr("Set Up Hibernation"),
                message: qsTr("Omarchy makes a swap file as large as the memory on the start-up disk, adds it to the start-up settings and rebuilds the start-up files. It runs in a Terminal window, asks before it starts and offers to restart at the end.")},
            "hibernation-remove": {title: qsTr("Remove Hibernation"),
                message: qsTr("Omarchy removes the swap file and the hibernation settings, then rebuilds the start-up files. It runs in a Terminal window and asks before it starts.")},
            "dictation-setup": {title: qsTr("Set Up Dictation"),
                message: qsTr("Omarchy installs Voxtype and its speech model, about 150 MB, in a Terminal window. Speech is recognised on this computer: nothing is sent elsewhere.")},
            "dictation-model": {title: qsTr("Choose a Speech Model"),
                message: qsTr("Voxtype lists its speech models in a Terminal window: larger ones recognise more and are slower. The one you choose is downloaded and used from then on.")},
            "dictation-remove": {title: qsTr("Remove Dictation"),
                message: qsTr("Omarchy stops Voxtype and removes it with its speech models and settings, in a Terminal window.")}
        })

    // The Omarchy command (or Omarchy's launcher) that is not installed, "" when all are (ADR-0045 OC-0.3: looked for when the
    // sheet opens; the sheet then says what is missing and starts nothing).
    property string missing: ""

    title: root.texts[root.setupId] ? root.texts[root.setupId].title : ""
    message: root.missing !== "" ? qsTr("This needs Omarchy's “%1”, which is not installed on this computer.").arg(root.missing)
        : root.texts[root.setupId] ? root.texts[root.setupId].message : ""
    confirmText: qsTr("Open Terminal")
    confirmEnabled: root.missing === ""

    function openFor(id: string): void {
        const argv = Setups.launchArgv(id, c => root.backend.hasCommand(c));
        if (argv === null || root.texts[id] === undefined)
            return;
        root.setupId = id;
        root.missing = argv.find(c => !root.backend.hasCommand(c)) ?? "";
        root.open();
    }

    onAccepted: {
        const argv = Setups.launchArgv(root.setupId, c => root.backend.hasCommand(c));
        if (argv !== null && root.system.launch(root.setupId, argv))
            root.launched(root.setupId);
    }
}
