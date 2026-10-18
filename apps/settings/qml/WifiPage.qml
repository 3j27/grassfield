pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Wi-Fi through NetworkManager's `nmcli` (read with -t, acted on only through SystemService, so never in a dev session).
SettingsPage {
    id: root

    required property var backend
    required property var system

    title: qsTr("Wi-Fi")

    // null: unknown or NetworkManager not answering.
    property var radio: null
    property bool answered: false
    property var networks: []
    property var profiles: []
    property var device: null
    // SSID being connected, until the command ends.
    property string pending: ""

    readonly property var current: {
        for (const n of root.networks) {
            if (n.active)
                return n;
        }
        return null;
    }
    readonly property bool available: root.radio !== null

    function refresh(): void {
        root.system.query(System.QUERY.wifiRadio, "wifi.radio");
        root.system.query(System.QUERY.wifiList, "wifi.list");
        root.system.query(System.QUERY.wifiProfiles, "wifi.profiles");
        root.system.query(System.QUERY.wifiDevices, "wifi.devices");
    }

    function activate(net: var): void {
        const kind = System.wifiClickKind(net, root.profiles);
        if (kind === "current") {
            root.system.act("wifi disconnect", System.wifiDisconnect(root.device ? root.device.name : ""), "wifi.act");
        } else if (kind === "known" || kind === "open") {
            root.pending = net.ssid;
            const argv = kind === "known" ? System.wifiConnectKnown(net.ssid) : System.wifiConnectOpen(net.ssid);
            if (!root.system.act("wifi connect", argv, "wifi.act"))
                root.pending = "";
        }
    }

    function subtitleOf(net: var): string {
        if (root.pending === net.ssid)
            return qsTr("Connecting…");
        if (net.active)
            return qsTr("Connected");
        switch (System.wifiClickKind(net, root.profiles)) {
        case "password":
            return net.enterprise ? qsTr("Needs a sign-in. Set it up in Quick Settings.") : qsTr("Needs a password. Join it from Quick Settings.");
        case "known":
            return qsTr("Known network");
        }
        return "";
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            switch (tag) {
            case "wifi.radio":
                root.radio = ok ? System.parseWifiRadio(output) : null;
                root.answered = true;
                break;
            case "wifi.list":
                root.networks = ok ? System.parseWifiList(output) : [];
                break;
            case "wifi.profiles":
                root.profiles = ok ? System.parseWifiProfiles(output) : [];
                break;
            case "wifi.devices":
                root.device = ok ? System.parseWifiDevice(output) : null;
                break;
            case "wifi.act":
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

    Component.onCompleted: {
        root.refresh();
        // NetworkManager scans on its own; ask for a fresh scan when the pane opens (never in a dev session).
        if (!root.system.dev)
            root.system.act("wifi scan", ["nmcli", "device", "wifi", "rescan"], "wifi.scan");
    }

    SettingsGroup {
        footnote: root.answered && !root.available ? qsTr("Wi-Fi is not available: NetworkManager did not answer.") : ""

        SettingsRow {
            title: qsTr("Wi-Fi")
            subtitle: !root.available ? "" : !root.radio ? qsTr("Off") : root.current ? root.current.ssid : qsTr("Not connected")
            Toggle {
                accessibleName: qsTr("Wi-Fi")
                enabled: root.available
                opacity: enabled ? 1 : Tokens.materialDisabledOpacity
                checked: root.radio === true
                onToggled: c => root.system.act("wifi " + (c ? "on" : "off"), System.wifiRadio(c), "wifi.act")
            }
        }
    }

    SettingsGroup {
        visible: root.available && root.radio === true
        caption: qsTr("Networks")
        footnote: root.networks.length === 0 ? qsTr("No networks found.") : ""

        Repeater {
            model: root.networks

            delegate: DeviceRow {
                id: row

                required property var modelData

                title: row.modelData.ssid
                subtitle: root.subtitleOf(row.modelData)
                leading: System.wifiGlyph(row.modelData.signal)
                trailing: row.modelData.secured ? "lock" : ""
                checked: row.modelData.active
                actionText: row.modelData.active ? qsTr("Disconnect") : ""
                Accessible.description: [row.subtitle, row.modelData.secured ? qsTr("Secured") : qsTr("Open"), qsTr("Signal %1 %").arg(row.modelData.signal)].filter(s => s !== "").join(", ")
                onActivated: root.activate(row.modelData)
            }
        }
    }

    DevNote {
        system: root.system
    }
}
