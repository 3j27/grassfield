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
    // UUIDs of the saved Wi-Fi profiles, the SSID (hex) of each, and SSID hex -> UUID of the first profile with it.
    property var profiles: []
    property var profileSsids: ({})
    property var known: ({})
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

    // The rows of the list, keyed by SSID + security: a refresh updates, inserts and removes rows in place.
    ListModel {
        id: netModel
    }

    function setNetworks(list: var): void {
        root.networks = list;
        System.syncModel(netModel, list, "key");
    }

    function setProfiles(uuids: var): void {
        const ssids = {};
        for (const u of uuids) {
            if (root.profileSsids[u] !== undefined)
                ssids[u] = root.profileSsids[u];
            else
                root.system.query(System.wifiProfileSsidQuery(u), "wifi.ssid:" + u);
        }
        root.profiles = uuids;
        root.profileSsids = ssids;
        root.rebuildKnown();
    }

    function rebuildKnown(): void {
        const k = {};
        for (const u of root.profiles) {
            const hex = root.profileSsids[u];
            if (hex && k[hex] === undefined)
                k[hex] = u;
        }
        root.known = k;
    }

    // The row's fields as the plain network object the helpers take.
    function netOf(row: var): var {
        return {key: row.key, hex: row.hex, ssid: row.ssid, label: row.label, secured: row.secured, enterprise: row.enterprise, active: row.active, valid: row.valid};
    }

    function refresh(): void {
        root.system.query(System.QUERY.wifiRadio, "wifi.radio");
        root.system.query(System.QUERY.wifiList, "wifi.list");
        root.system.query(System.QUERY.wifiProfiles, "wifi.profiles");
        root.system.query(System.QUERY.wifiDevices, "wifi.devices");
    }

    function activate(net: var): void {
        const kind = System.wifiClickKind(net, root.known);
        if (kind === "current") {
            root.system.act("wifi disconnect", System.wifiDisconnect(root.device ? root.device.name : ""), "wifi.act");
        } else if (kind === "known" || kind === "open") {
            root.pending = net.key;
            const argv = kind === "known" ? System.wifiConnectKnown(root.known[net.hex]) : net.valid ? System.wifiConnectOpen(net.ssid) : null;
            if (!root.system.act("wifi connect", argv, "wifi.act"))
                root.pending = "";
        }
    }

    function subtitleOf(net: var): string {
        if (root.pending === net.key)
            return qsTr("Connecting…");
        if (net.active)
            return qsTr("Connected");
        switch (System.wifiClickKind(net, root.known)) {
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
            if (tag.startsWith("wifi.ssid:")) {
                const uuid = tag.slice("wifi.ssid:".length);
                if (root.profiles.indexOf(uuid) >= 0) {
                    const ssids = Object.assign({}, root.profileSsids);
                    ssids[uuid] = ok ? System.parseProfileSsid(output) : "";
                    root.profileSsids = ssids;
                    root.rebuildKnown();
                }
                return;
            }
            switch (tag) {
            case "wifi.radio":
                root.radio = ok ? System.parseWifiRadio(output) : null;
                root.answered = true;
                break;
            case "wifi.list":
                root.setNetworks(ok ? System.parseWifiList(output) : []);
                break;
            case "wifi.profiles":
                root.setProfiles(ok ? System.parseWifiProfiles(output) : []);
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
            subtitle: !root.available ? "" : !root.radio ? qsTr("Off") : root.current ? root.current.label : qsTr("Not connected")
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
            model: netModel

            delegate: DeviceRow {
                id: row

                required property string key
                required property string hex
                required property string ssid
                required property string label
                required property int strength
                required property bool secured
                required property bool enterprise
                required property bool active
                required property bool valid

                title: row.label
                subtitle: root.subtitleOf(root.netOf(row))
                leading: System.wifiGlyph(row.strength)
                trailing: row.secured ? "lock" : ""
                checked: row.active
                actionText: row.active ? qsTr("Disconnect") : ""
                Accessible.description: [row.subtitle, row.secured ? qsTr("Secured") : qsTr("Open"), qsTr("Signal %1 %").arg(row.strength)].filter(s => s !== "").join(", ")
                onActivated: root.activate(root.netOf(row))
            }
        }
    }

    ErrorNote {
        system: root.system
        tag: "wifi.act"
    }

    DevNote {
        system: root.system
    }
}
