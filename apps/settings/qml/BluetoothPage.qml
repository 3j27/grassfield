pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Bluetooth through BlueZ over D-Bus (one read-only JSON state; power and connect only through SystemService, so never
// in a dev session; a failed action shows its reason under the list). Paired devices only: no discovery or pairing here (same scope as Quick Settings).
SettingsPage {
    id: root

    required property var backend
    required property var system

    title: qsTr("Bluetooth")

    property bool answered: false
    property var controller: ({present: false, powered: false})
    property var devices: []
    // MAC address being connected or disconnected, until the command ends.
    property string pending: ""

    // The rows of the list, keyed by MAC address: a refresh updates, inserts and removes rows in place.
    ListModel {
        id: deviceModel
    }

    onDevicesChanged: System.syncModel(deviceModel, root.devices, "mac")

    function refresh(): void {
        root.system.queryBus("bt.state", "bt.state");
    }

    function toggleDevice(dev: var): void {
        root.pending = dev.mac;
        if (!root.system.act("bluetooth " + (dev.connected ? "disconnect" : "connect"), System.btConnect(dev.mac, !dev.connected), "bt.act"))
            root.pending = "";
    }

    function subtitleOf(dev: var): string {
        if (root.pending === dev.mac)
            return dev.connected ? qsTr("Disconnecting…") : qsTr("Connecting…");
        return dev.connected ? qsTr("Connected") : qsTr("Not Connected");
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            switch (tag) {
            case "bt.state": {
                const state = ok ? System.parseBtState(output) : null;
                root.controller = state ? {present: state.present, powered: state.powered} : {present: false, powered: false};
                root.devices = state ? state.devices : [];
                root.answered = true;
                break;
            }
            case "bt.act":
                root.pending = "";
                root.refresh();
                break;
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
        footnote: root.answered && !root.controller.present ? qsTr("Bluetooth is not available: no adapter was found or the Bluetooth service is not running.") : ""

        SettingsRow {
            title: qsTr("Bluetooth")
            Toggle {
                accessibleName: qsTr("Bluetooth")
                enabled: root.controller.present
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                checked: root.controller.powered
                onToggled: c => root.system.act("bluetooth " + (c ? "on" : "off"), System.btPower(c), "bt.act")
            }
        }
    }

    SettingsGroup {
        visible: root.controller.present && root.controller.powered
        caption: qsTr("My Devices")
        footnote: root.devices.length === 0 ? qsTr("No paired devices. Pair a device with your system's Bluetooth tools.") : qsTr("Devices are paired outside Settings for now.")

        Repeater {
            model: deviceModel

            delegate: DeviceRow {
                id: row

                required property string mac
                required property string name
                required property bool connected

                title: row.name
                subtitle: root.subtitleOf({mac: row.mac, connected: row.connected})
                leading: "bluetooth"
                checked: row.connected
                actionText: row.connected ? qsTr("Disconnect") : qsTr("Connect")
                onActivated: root.toggleDevice({mac: row.mac, connected: row.connected})
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "bt.act"
    }

    DevNote {
        system: root.system
    }
}
