pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Bluetooth through BlueZ's `bluetoothctl` (read-only queries; power and connect only through SystemService, so never
// in a dev session). Paired devices only: no discovery or pairing here (same scope as Quick Settings).
SettingsPage {
    id: root

    required property var backend
    required property var system

    title: qsTr("Bluetooth")

    property bool answered: false
    property var controller: ({present: false, powered: false})
    property var paired: []
    property var connected: []
    // MAC address being connected or disconnected, until the command ends.
    property string pending: ""

    readonly property var devices: System.bluetoothDevices(root.paired, root.connected)

    function refresh(): void {
        root.system.query(System.QUERY.btShow, "bt.show");
        root.system.query(System.QUERY.btPaired, "bt.paired");
        root.system.query(System.QUERY.btConnected, "bt.connected");
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
            case "bt.show":
                root.controller = ok ? System.parseBtShow(output) : {present: false, powered: false};
                root.answered = true;
                break;
            case "bt.paired":
                root.paired = ok ? System.parseBtDevices(output) : [];
                break;
            case "bt.connected":
                root.connected = ok ? System.parseBtDevices(output) : [];
                break;
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
            model: root.devices

            delegate: DeviceRow {
                id: row

                required property var modelData

                title: row.modelData.name
                subtitle: root.subtitleOf(row.modelData)
                leading: "bluetooth"
                checked: row.modelData.connected
                actionText: row.modelData.connected ? qsTr("Disconnect") : qsTr("Connect")
                onActivated: root.toggleDevice(row.modelData)
            }
        }
    }

    DevNote {
        system: root.system
    }
}
