pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Wi-Fi through NetworkManager over D-Bus (read as one JSON state, acted on only through SystemService, so never in a dev
// session). A failed action shows its reason under the list (ErrorNote); a NetworkManager that does not answer shows the footnote.
SettingsPage {
    id: root

    required property var backend
    required property var system

    title: qsTr("Wi-Fi")

    // null: unknown or NetworkManager not answering.
    property var radio: null
    property bool answered: false
    property var networks: []
    // SSID hex -> UUID of the first saved profile with that SSID.
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

    function setState(state: var): void {
        root.radio = state ? state.radio : null;
        root.device = state ? state.device : null;
        root.known = state ? state.known : {};
        root.setNetworks(state ? state.networks : []);
        root.answered = true;
    }

    // The row's fields as the plain network object the helpers take.
    function netOf(row: var): var {
        return {key: row.key, hex: row.hex, ssid: row.ssid, label: row.label, secured: row.secured, enterprise: row.enterprise, active: row.active, valid: row.valid};
    }

    function refresh(): void {
        root.system.queryBus("wifi.state", "wifi.state");
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
            switch (tag) {
            case "wifi.state":
                root.setState(ok ? System.parseWifiState(output) : null);
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
            root.system.act("wifi scan", System.wifiScan(), "wifi.scan");
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
