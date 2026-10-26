pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// VPN as macOS 27 lays it out (docs/audits/settings-parity-2026-10-26.md § Network and VPN): the VPN and WireGuard profiles of
// NetworkManager, each with its state and a switch (`vpn.connect` through SystemService, so never in a dev session), or one
// group saying there are none. Creating or importing a configuration is not built. A VPN that needs a secret it does not store
// fails with NetworkManager's reason (Grassfield is no secret agent, ADR-0030).
SettingsPage {
    id: root

    required property var backend
    required property var system

    title: qsTr("VPN")

    property bool answered: false
    property bool available: false
    // The uuid being switched, until the action ends.
    property string pending: ""

    ListModel {
        id: vpnModel
    }

    function refresh(): void {
        root.system.queryBus("net.state", "vpn.state");
    }

    function statusText(link: string): string {
        return link === "connected" ? qsTr("Connected") : link === "connecting" ? qsTr("Connecting…") : qsTr("Not connected");
    }

    function toggle(uuid: string, on: bool): void {
        root.pending = uuid;
        if (!root.system.act("vpn " + (on ? "on" : "off"), System.vpnConnect(uuid, on), "vpn.act"))
            root.pending = "";
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "vpn.state") {
                const st = ok ? System.parseNetState(output) : null;
                root.available = st !== null;
                root.answered = true;
                System.syncModel(vpnModel, st ? st.vpns.map(v => ({uuid: v.uuid, name: v.name, kind: v.kind, link: v.state})) : [], "uuid");
            } else if (tag === "vpn.act") {
                root.pending = "";
                root.refresh();
            }
        }
    }

    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: root.refresh()

    SettingsGroup {
        visible: vpnModel.count > 0

        Repeater {
            model: vpnModel

            delegate: SettingsRow {
                id: vpn
                required property string uuid
                required property string name
                required property string kind
                required property string link
                title: vpn.name
                subtitle: (vpn.kind === "wireguard" ? qsTr("WireGuard") : qsTr("VPN")) + " · " + (root.pending === vpn.uuid ? qsTr("Changing…") : root.statusText(vpn.link))

                Toggle {
                    accessibleName: vpn.name
                    enabled: root.pending === ""
                    opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                    checked: vpn.link === "connected" || vpn.link === "connecting"
                    onToggled: c => root.toggle(vpn.uuid, c)
                }
            }
        }
    }

    SettingsGroup {
        visible: root.answered && vpnModel.count === 0
        footnote: !root.available ? qsTr("VPN is not available: NetworkManager did not answer.") : ""

        Item {
            width: parent.width
            height: Tokens.settingsEmptyListHeight
            Accessible.role: Accessible.StaticText
            Accessible.name: empty.text

            Text {
                id: empty
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: qsTr("No VPN configurations")
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "vpn.act"
    }

    DevNote {
        system: root.system
    }
}
