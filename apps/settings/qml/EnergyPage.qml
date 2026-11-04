pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Power.js" as Power

// Energy, in place of Battery on a computer without a battery (macOS 27): Energy Mode and Prevent automatic sleeping when the
// display is off. Energy Mode is power-profiles-daemon's profile for the power adapter, through Omarchy's own command as
// Battery's Low Power Mode (omarchy-powerprofiles-set ac <profile>: applied at once and remembered; read back from Omarchy's
// state file), only the modes the daemon offers. The switch is energy.preventSleep in grassfield.json, which the shell's idle
// module reads (shell/security/idle: sleep only, never the lock). Wake for network access and Start up automatically after
// a power failure have no counterpart here. Every profile change goes through SystemService, so never in a dev session.
SettingsPage {
    id: root

    required property var backend
    required property var system
    required property var store

    title: qsTr("Energy")

    // The profiles power-profiles-daemon offers (null until it answered), and the one Omarchy remembers for the power adapter.
    property var profiles: null
    property string acProfile: ""
    // The mode being set (shown at once), "" otherwise.
    property string pendingMode: ""

    readonly property var modes: Power.energyModes(root.profiles ?? [])
    readonly property string mode: root.pendingMode !== "" ? root.pendingMode : Power.energyMode(root.acProfile, root.profiles ?? [])
    readonly property var modeNames: ({automatic: qsTr("Automatic"), low: qsTr("Low Power"), high: qsTr("High Power")})

    function readProfile(): void {
        root.acProfile = root.backend.readText(root.backend.stateDir + "/omarchy/powerprofiles/ac").text.trim();
    }

    function setMode(mode: string): void {
        if (mode === root.mode || root.pendingMode !== "")
            return;
        const command = Power.energyCommand(mode, root.profiles ?? []);
        if (command === null)
            return;
        root.pendingMode = mode;
        if (!root.system.act("energy mode", command, "energy.act"))
            root.pendingMode = "";
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            switch (tag) {
            case "energy.profiles":
                root.profiles = ok ? Power.parseProfiles(output) : [];
                break;
            case "energy.act":
                root.pendingMode = "";
                root.readProfile();
                break;
            }
        }
    }

    Component.onCompleted: {
        root.readProfile();
        root.system.query(["omarchy-powerprofiles-list"], "energy.profiles");
    }

    SettingsGroup {
        footnote: root.profiles !== null && root.modes.length === 0
            ? qsTr("Energy modes are not available: power-profiles-daemon is not running.")
            : qsTr("The display turns off and the session locks as set in Lock Screen, whether or not the computer sleeps.")

        SettingsRow {
            title: qsTr("Energy Mode")

            ComboBox {
                inline: true
                enabled: root.pendingMode === "" && root.modes.length > 0
                accessibleName: qsTr("Energy Mode")
                model: root.modes.map(id => ({id: id, text: root.modeNames[id]}))
                value: root.mode
                onPicked: id => root.setMode(id)
            }
        }

        SettingsRow {
            title: qsTr("Prevent automatic sleeping when the display is off")

            Toggle {
                accessibleName: qsTr("Prevent automatic sleeping when the display is off")
                checked: root.store.value("energy.preventSleep")
                onToggled: c => root.store.set("energy.preventSleep", c)
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "energy.act"
    }

    DevNote {
        system: root.system
    }
}
