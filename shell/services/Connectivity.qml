pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Networking

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

    function setWifiEnabled(on: bool): void {
        Networking.wifiEnabled = on;
    }
}
