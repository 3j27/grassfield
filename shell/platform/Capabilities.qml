pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland

// Capability detection for grassfield-compositor (contract gfc/1).
// Sends `grassfield:hello` once and waits for a Hyprland raw event named `grassfield` whose
// data is JSON {"v":"gfc/1","type":"capabilities","features":[...]}. No reply within
// helloTimeoutMs means degraded mode (pluginPresent = false).
Singleton {
    id: root

    readonly property string protocol: "gfc/1"
    readonly property int helloTimeoutMs: 1500

    property bool pluginPresent: false
    // False until the hello reply arrived or the timeout elapsed.
    property bool settled: false
    property var features: []

    // Hello transport (ASSUMPTION until ADR-0007): Hyprland 0.56 is Lua-only, and Quickshell
    // wraps the request as `return hl.dispatch(<request>)`, so a Lua function is sent that
    // calls the plugin's `hello` when the plugin registered one. Without the plugin it is a
    // silent no-op, which then ends in degraded mode via the timeout.
    readonly property string helloRequest: "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.hello then p.hello() end end"

    function has(feature: string): bool {
        return pluginPresent && features.indexOf(feature) !== -1;
    }

    function handleEvent(data: string): void {
        let msg = null;
        try {
            msg = JSON.parse(data);
        } catch (e) {
            console.warn("grassfield: ignoring malformed capabilities event");
            return;
        }
        if (!msg || msg.v !== root.protocol || msg.type !== "capabilities" || !Array.isArray(msg.features))
            return;
        features = msg.features;
        pluginPresent = true;
        settled = true;
        timeout.stop();
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "grassfield")
                root.handleEvent(event.data);
        }
    }

    Timer {
        id: timeout
        interval: root.helloTimeoutMs
        onTriggered: {
            if (!root.pluginPresent)
                console.info("grassfield: no compositor plugin reply, running in degraded mode");
            root.settled = true;
        }
    }

    Component.onCompleted: {
        timeout.start();
        Hyprland.dispatch(root.helloRequest);
    }
}
