pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "CapabilityEvent.js" as CapabilityEvent
import "../services/DevGate.js" as DevGate

// Capability detection for grassfield-compositor (contract gfc/1).
// Sends the hello every helloRetryMs (the first ones can predate Quickshell's event socket, so
// the reply would be missed) and waits for a Hyprland raw event named `grassfield` whose
// data is JSON {"v":"gfc/1","type":"capabilities","features":[...]}. No reply within
// helloTimeoutMs means degraded mode (pluginPresent = false) for now: the hello keeps going every
// helloSlowRetryMs for helloGiveUpMs, so a reply that comes late (a loaded host at login, Quickshell's
// event socket connecting after the first hellos) still brings the shell out of degraded mode.
Singleton {
    id: root

    readonly property string protocol: "gfc/1"
    readonly property int helloTimeoutMs: 1500
    readonly property int helloRetryMs: 250
    readonly property int helloSlowRetryMs: 2000
    readonly property int helloGiveUpMs: 300000
    // A loaded plugin can answer seconds after the timeout at login (the late replies above): only this long without a
    // reply, or an unload, makes the extension known to be absent.
    readonly property int helloAbsentMs: 15000

    property bool pluginPresent: false
    // False until the hello reply arrived or the timeout elapsed.
    property bool settled: false
    // The extension is known to be absent: no reply within helloAbsentMs, or its unload. The degraded notice waits for
    // this, so that a late reply at login never shows it for a moment (degraded mode itself starts at the timeout).
    property bool absent: false
    property var features: []
    // A capabilities event of another protocol version was logged (once per shell run).
    property bool protocolWarned: false

    // Hello transport (ASSUMPTION until ADR-0007): Hyprland 0.56 is Lua-only, and Quickshell
    // wraps the request as `return hl.dispatch(<request>)`, so a Lua function is sent that
    // calls the plugin's `hello` when the plugin registered one. Without the plugin it is a
    // silent no-op, which then ends in degraded mode via the timeout.
    readonly property string helloRequest: "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.hello then p.hello() end end"

    function has(feature: string): bool {
        return pluginPresent && features.indexOf(feature) !== -1;
    }

    function handleEvent(data: string): void {
        const msg = CapabilityEvent.parse(data, root.protocol);
        if (!msg) {
            // Other gfc/1 events (overview, ...) share the channel: only a malformed capabilities event is a problem.
            if (CapabilityEvent.isMalformedCapabilities(data, root.protocol))
                console.warn("grassfield: ignoring malformed capabilities event");
            // A plugin speaking another protocol version stays "no plugin" (degraded mode); say why, once.
            const other = CapabilityEvent.otherProtocolCapabilities(data, root.protocol);
            if (other !== "" && !root.protocolWarned) {
                root.protocolWarned = true;
                console.warn("grassfield: unsupported plugin protocol", other, "(expected " + root.protocol + "), running without the plugin");
            }
            return;
        }
        features = msg.features;
        // An empty list is the plugin's unload: nothing is available any more, same as no plugin.
        pluginPresent = msg.present;
        absent = !msg.present;
        settled = true;
        timeout.stop();
        // No polling after an unload: a plugin loaded later announces itself.
        retry.stop();
        giveUp.stop();
        console.info("grassfield: compositor plugin", msg.present ? "present, features:" : "gone (empty capabilities)", features.join(","));
    }

    // Test hook (tests/visual waits on it before capturing): `qs ipc call capabilities status` is "pending" until the
    // hello reply arrived or timed out, then "ready present <features>" or "ready degraded". Dev session only (SEC-04).
    IpcHandler {
        target: "capabilities"

        function status(): string {
            if (!DevGate.allowed(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION")))
                return DevGate.REFUSED;
            if (!root.settled)
                return "pending";
            return root.pluginPresent ? "ready present " + root.features.join(",") : "ready degraded";
        }
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
            if (!root.pluginPresent) {
                console.info("grassfield: no compositor plugin reply yet, running in degraded mode (still asking)");
                retry.interval = root.helloSlowRetryMs;
                giveUp.start();
            } else {
                retry.stop();
            }
            root.settled = true;
        }
    }

    Timer {
        id: absentDelay
        interval: root.helloAbsentMs
        onTriggered: root.absent = !root.pluginPresent
    }

    // Stops the slow hellos: by then the plugin is not loaded, and one loaded later announces itself.
    Timer {
        id: giveUp
        interval: root.helloGiveUpMs
        onTriggered: retry.stop()
    }

    // Resends the hello until a reply arrives: every helloRetryMs until the timeout, then every
    // helloSlowRetryMs until giveUp. A plugin loaded later is still accepted: the capabilities event is
    // handled at any time.
    Timer {
        id: retry
        interval: root.helloRetryMs
        repeat: true
        onTriggered: Hyprland.dispatch(root.helloRequest)
    }

    Component.onCompleted: {
        timeout.start();
        absentDelay.start();
        retry.start();
        Hyprland.dispatch(root.helloRequest);
    }
}
