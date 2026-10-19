pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Bluetooth
import "../overlay/controlcenter/Model.js" as Model

// Bluetooth through Quickshell.Bluetooth (BlueZ). Absent without an adapter.
// In a GRASSFIELD_DEV session nothing is changed (the nested shell shares the owner's radios).
Singleton {
    id: root

    // Quickshell.Bluetooth's qmldir does not declare its Quickshell dependency, so qmllint cannot
    // resolve its model types (the runtime can).
    // qmllint disable unresolved-type
    readonly property var adapter: Bluetooth.defaultAdapter
    // Visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES): adapter on, no devices.
    readonly property bool available: VisualFixtures.active || adapter !== null
    readonly property bool enabled: VisualFixtures.active || (available && adapter.enabled)
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1"
    signal devSuppressed(string what)

    // Paired devices as rows {name, paired, connected, battery, dev}.
    readonly property var devices: {
        if (VisualFixtures.active)
            return [];
        const all = Bluetooth.devices ? Bluetooth.devices.values : [];
        const rows = [];
        for (let i = 0; i < all.length; i++) {
            const d = all[i];
            rows.push({
                name: d.name !== "" ? d.name : d.address,
                paired: d.paired,
                connected: d.connected,
                battery: d.batteryAvailable ? d.battery : -1,
                dev: d
            });
        }
        return Model.sortDevices(rows);
    }
    // qmllint enable unresolved-type
    readonly property int connectedCount: devices.filter(d => d.connected).length

    readonly property string description: {
        if (!available)
            return qsTr("No adapter");
        if (!enabled)
            return qsTr("Off");
        if (connectedCount === 1)
            return devices.find(d => d.connected).name;
        return connectedCount > 1 ? qsTr("%1 devices").arg(connectedCount) : qsTr("On");
    }

    function guarded(what: string): bool {
        if (!devSession)
            return false;
        console.info("dev guard: " + what + " suppressed");
        devSuppressed(what);
        return true;
    }

    function setEnabled(on: bool): void {
        if (guarded("bluetooth toggle"))
            return;
        if (available)
            adapter.enabled = on;
    }

    function toggleDevice(row: var): void {
        if (guarded(row.connected ? "bluetooth disconnect" : "bluetooth connect"))
            return;
        if (row.connected)
            row.dev.disconnect();
        else
            row.dev.connect();
    }
}
