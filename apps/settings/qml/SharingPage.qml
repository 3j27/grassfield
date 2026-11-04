pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Setups.js" as Setups

// General > Sharing as macOS 15 lays it out (docs/specs/settings.md § macOS 27 parity inventory: the look from the 27 panes),
// with one service, Remote Login (ADR-0045 OC-7, OC-0.7, superseding the owner decision "no Sharing pane" for exactly that):
// its switch is systemd's sshd.service, enabled and started or stopped and disabled over D-Bus (systembus.h ssh.enable; systemd
// asks polkit, Grassfield's polkit sheet asks the password). The first time, Omarchy's own setup runs instead, in its
// terminal behind a sheet that says why (TerminalSetupSheet.qml): it installs OpenSSH, opens the firewall's SSH port (Omarchy's
// firewall denies incoming connections), authorizes a key and turns password logins off; its marker file says it ran
// (Setups.FILES.sshdHardening). The state is the unit file's, read from the disk (sharing.state), and read again when
// Settings is active again. When on: "To log in to this computer remotely, type “ssh user@host”." (Omarchy's own line).
SettingsPage {
    id: root

    required property var backend
    required property var system

    // Main.qml opens the terminal sheet (TerminalSetupSheet) for Omarchy's first setup.
    signal setupRequested(string id)

    title: qsTr("Sharing")

    property var sharing: null
    property bool answered: false
    property string host: ""
    property bool hardened: false
    // The switch's action under way.
    readonly property bool busy: (root.backend.pendingActions ?? {})["sharing.act"] !== undefined
    readonly property bool on: root.sharing !== null && root.sharing.enabled
    readonly property string sshLine: Setups.sshCommand(root.backend.userName, root.host)

    function refresh(): void {
        root.hardened = root.backend.readText(Setups.FILES.sshdHardening).exists === true;
        root.system.queryBus("sharing.state", "sharing.state");
        root.system.queryBus("host.state", "sharing.host");
    }

    function setRemoteLogin(on: bool): void {
        const route = Setups.remoteLoginRoute(root.sharing, root.hardened, on);
        if (route === "terminal")
            root.setupRequested("sshd-setup");
        else if (route === "native")
            root.system.act("remote login", {op: "ssh.enable", on: on}, "sharing.act");
    }

    Component.onCompleted: root.refresh()


    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "sharing.state") {
                root.answered = true;
                root.sharing = ok ? Setups.parseSharing(output) : null;
            } else if (tag === "sharing.host") {
                if (!ok)
                    return;
                try {
                    const h = JSON.parse(output);
                    root.host = typeof h.hostname === "string" ? h.hostname : "";
                } catch (e) {
                    root.host = "";
                }
            } else if (tag === "sharing.act") {
                root.refresh();
            }
        }
    }

    SettingsGroup {
        footnote: !root.answered ? ""
            : root.sharing === null ? qsTr("The state of Remote Login cannot be read.")
            : root.on && root.sshLine !== "" ? qsTr("To log in to this computer remotely, type “%1”.").arg(root.sshLine)
            : qsTr("Remote Login lets people log in to this computer over SSH with a key you authorized. The first time, Omarchy sets it up in a Terminal window.")

        SettingsRow {
            title: qsTr("Remote Login")
            glyph: "remote-desktop"
            subtitle: root.on && root.sharing.active === false ? qsTr("On, but the SSH server is not running.") : ""

            Toggle {
                accessibleName: qsTr("Remote Login")
                enabled: root.sharing !== null && !root.busy
                checked: root.on
                onToggled: c => root.setRemoteLogin(c)
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "sharing.act"
    }

    DevNote {
        system: root.system
    }

    // The terminal closed (or the polkit sheet answered): Settings is active again.
    ActiveAgain {
        onReturned: root.refresh()
    }
}
