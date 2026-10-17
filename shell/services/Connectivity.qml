pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Networking
import "../overlay/controlcenter/Model.js" as Model

// Connectivity summary for the menu bar (NetworkManager through Quickshell.Networking).
Singleton {
    id: root

    readonly property bool available: Networking.backend === NetworkBackendType.NetworkManager
    readonly property var devices: Networking.devices ? Networking.devices.values : []
    readonly property bool wifiEnabled: Networking.wifiEnabled

    function deviceOfType(type: int): var {
        for (let i = 0; i < devices.length; i++) {
            if (devices[i].type === type)
                return devices[i];
        }
        return null;
    }

    readonly property var wifiDevice: deviceOfType(DeviceType.Wifi)
    readonly property var wiredDevice: deviceOfType(DeviceType.Wired)
    readonly property bool wiredConnected: wiredDevice !== null && wiredDevice.connected

    // The Wi-Fi network this machine is connected to, or null.
    readonly property var wifiConnected: {
        const nets = wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : [];
        for (let i = 0; i < nets.length; i++) {
            if (nets[i].connected)
                return nets[i];
        }
        return null;
    }

    readonly property string iconName: {
        if (wiredConnected)
            return "network-wired";
        if (!wifiEnabled || wifiDevice === null)
            return "wifi-off";
        if (wifiConnected === null)
            return "wifi-off";
        const s = wifiConnected.signalStrength;
        return s < 0.34 ? "wifi-1" : (s < 0.67 ? "wifi-2" : "wifi-3");
    }

    readonly property string description: {
        if (wiredConnected)
            return qsTr("Wired connection");
        if (!wifiEnabled)
            return qsTr("Wi-Fi is off");
        if (wifiConnected)
            return qsTr("Connected to %1").arg(wifiConnected.name);
        return qsTr("Not connected");
    }

    // Every radio change goes through the dev guard, whoever calls it (menu bar, Control Center).
    function setWifiEnabled(on: bool): void {
        if (guarded("wifi " + (on ? "on" : "off")))
            return;
        Networking.wifiEnabled = on;
    }

    // A GRASSFIELD_DEV session runs on the owner's machine: radio and connection changes are
    // never executed there (the Control Center shows a "dev: not applied" note instead).
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1"
    signal devSuppressed(string what)

    function guarded(what: string): bool {
        if (!devSession)
            return false;
        console.info("dev guard: " + what + " suppressed");
        devSuppressed(what);
        return true;
    }

    // Scan results as rows for the Control Center (sorted, deduplicated; see Model.sortNetworks).
    readonly property var networks: {
        const nets = wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : [];
        const rows = [];
        for (let i = 0; i < nets.length; i++) {
            const n = nets[i];
            const sec = n.security;
            rows.push({
                name: n.name,
                strength: n.signalStrength,
                secured: sec !== WifiSecurityType.Open && sec !== WifiSecurityType.Owe,
                enterprise: sec === WifiSecurityType.Wpa2Eap || sec === WifiSecurityType.WpaEap,
                connected: n.connected,
                known: n.known,
                connecting: n.state === ConnectionState.Connecting,
                net: n
            });
        }
        return Model.sortNetworks(rows);
    }

    // scannerEnabled lives on the shared WifiDevice: the Control Center sets it while Wi-Fi is expanded.
    function setScanning(on: bool): void {
        if (wifiDevice)
            wifiDevice.scannerEnabled = on;
    }

    function toggleWifi(on: bool): void {
        setWifiEnabled(on);
    }

    // row: an entry of `networks`. Returns the action (see Model.networkAction); "password" is left to the UI.
    function activate(row: var): string {
        const action = Model.networkAction(row);
        if (action === "disconnect") {
            if (!guarded("wifi disconnect"))
                row.net.disconnect();
        } else if (action === "connect") {
            if (!guarded("wifi connect"))
                row.net.connect();
        } else if (action === "editor") {
            if (!guarded("nm-connection-editor"))
                Quickshell.execDetached(["nm-connection-editor"]);
        }
        return action;
    }

    // Airplane mode: derived from the radios (Wi-Fi through NetworkManager, Bluetooth through BlueZ).
    // These are the services' power switches, not an rfkill soft block: the label says so.
    readonly property bool airplane: Model.airplaneOn(wifiDevice !== null, wifiEnabled, BluetoothState.available, BluetoothState.enabled)
    readonly property bool airplaneAvailable: wifiDevice !== null || BluetoothState.available

    function setAirplane(on: bool): void {
        const t = Model.airplaneTargets(wifiDevice !== null, BluetoothState.available, on);
        if (t.wifi !== null)
            toggleWifi(t.wifi);
        if (t.bluetooth !== null)
            BluetoothState.setEnabled(t.bluetooth);
    }

    function connectWithPassword(row: var, psk: string): void {
        if (!guarded("wifi connect (password)"))
            row.net.connectWithPsk(psk);
    }
}
