pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import Quickshell.Services.Pipewire
import "AudioRoutingLogic.js" as Routing

// Default output (PipeWire through Quickshell). volume is 0..1 on the cubic scale of wpctl, pavucontrol and the volume
// keys: Quickshell's PwNodeAudio.volume already speaks it (measured nested 2026-10-24: raw channelVolumes 0.007994,
// `wpctl get-volume` 0.20, PwNodeAudio.volume 0.20), so the shell reads and writes it as is (tests/shell/cc_sliders_ipc.sh).
Singleton {
    id: root

    readonly property var sink: sinkOverride !== null ? sinkOverride : Pipewire.defaultAudioSink
    // Visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES): an output at 50 percent, not muted.
    readonly property bool ready: VisualFixtures.active || (sink !== null && sink.audio !== null)
    // The real default sink on the shown scale (0 without one), whatever the fixtures say: what `wpctl get-volume` prints.
    readonly property bool deviceReady: sink !== null && sink.audio !== null
    readonly property real deviceVolume: sink !== null && sink.audio !== null ? sink.audio.volume : 0
    readonly property real volume: VisualFixtures.active ? 0.5 : deviceVolume
    readonly property bool muted: VisualFixtures.active ? false : (ready ? sink.audio.muted : false)
    readonly property string iconName: !ready || muted || volume <= 0 ? "volume-mute"
        : volume < 0.34 ? "volume-1"
        : volume < 0.67 ? "volume-2"
        : "volume-3"

    // Output devices (not streams).
    readonly property var sinks: {
        const out = [];
        const all = Pipewire.nodes ? Pipewire.nodes.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].isSink && !all[i].isStream && all[i].audio)
                out.push(all[i]);
        }
        return out;
    }

    // Input devices (microphones, not monitors or streams).
    readonly property var sources: {
        const out = [];
        const all = Pipewire.nodes ? Pipewire.nodes.values : [];
        for (let i = 0; i < all.length; i++) {
            if (!all[i].isSink && !all[i].isStream && all[i].audio && !all[i].name.endsWith(".monitor"))
                out.push(all[i]);
        }
        return out;
    }
    readonly property var source: Pipewire.defaultAudioSource

    // GRASSFIELD_DEV: a nested session runs on the owner's machine, so NOTHING here may change the real audio
    // (volume, mute, default output or input, key steps). Every write to the backend goes through
    // backendWrite(), the single exit: in a dev session it logs, signals devSuppressed and returns false
    // before any backend object is touched (no exception path, whatever `ready` is). backendWrites counts the
    // writes that were really made (tests/shell/audio_dev_guard.sh proves it stays 0 in dev).
    readonly property bool devSession: Mode.dev
    property int backendWrites: 0
    signal devSuppressed(string what)

    // Test hook: a stand-in for the default sink (an object with audio.volume and audio.muted). Never set in the shell.
    property var sinkOverride: null

    function backendWrite(what: string, write: var): bool {
        if (devSession) {
            console.info("dev guard: audio " + what + " suppressed");
            devSuppressed(what);
            return false;
        }
        backendWrites++;
        write();
        return true;
    }

    // Returns true when the backend was written (false: refused by the dev guard).
    function setVolume(value: real): bool {
        return backendWrite("volume", () => {
            if (ready && !VisualFixtures.active)
                sink.audio.volume = value;
        });
    }

    function selectSource(node: var): void {
        backendWrite("input device", () => {
            Pipewire.preferredDefaultAudioSource = node;
        });
    }

    function adjust(delta: real): bool {
        return setVolume(volume + delta);
    }

    function toggleMute(): bool {
        return backendWrite("mute", () => {
            if (ready && !VisualFixtures.active)
                sink.audio.muted = !sink.audio.muted;
        });
    }

    // Volume keys (volume up|down|mute IPC): wpctl on the default sink, 5 percent steps, never above 100.
    function keyStep(direction: string): bool {
        let args;
        switch (direction) {
        case "up":
            args = ["set-volume", "-l", "1", "@DEFAULT_AUDIO_SINK@", "5%+"];
            break;
        case "down":
            args = ["set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"];
            break;
        case "mute":
            args = ["set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"];
            break;
        default:
            console.warn("audio: unknown volume command", direction);
            return false;
        }
        return backendWrite("key " + direction, () => {
            keyProcess.command = ["wpctl"].concat(args);
            keyProcess.running = true;
        });
    }

    signal keyFinished

    Process {
        id: keyProcess
        onRunningChanged: {
            if (!running)
                root.keyFinished();
        }
    }

    function describe(node: var): string {
        return node.nickname !== "" ? node.nickname : (node.description !== "" ? node.description : node.name);
    }

    function select(node: var): void {
        backendWrite("output device", () => {
            Pipewire.preferredDefaultAudioSink = node;
        });
    }

    // Nodes must be tracked to expose their audio properties.
    PwObjectTracker {
        objects: [root.sink, root.source].concat(root.sinks).concat(root.sources)
    }

    // ---- Automatic output routing (ADR-0047 part A) ---------------------------------------------------------------------
    // Headphones, headsets and Bluetooth audio the person connects take the sound; other outputs never do; a person's move
    // away from such a device is remembered per device. The rules are AudioRoutingLogic.js (a pure state machine fed here
    // with timestamps); this part feeds it the sinks once Quickshell has their properties, joins each node's device
    // properties (`pw-dump <device.id>`, read-only), runs one timer to its next deadline, logs its decisions and switches
    // through backendWrite(), the guarded write (a dev session logs and changes nothing). WirePlumber returns the sound to
    // the previous output when a device leaves: nothing is done here then.
    readonly property string routingFile: Mode.stateDir + "/audio-routing.json"
    property var routing: Routing.create(null)
    property bool routingMemoryReady: false
    property bool routingReadOnly: false
    property bool routingStarted: false
    // Node names fed to the router.
    property var routingFed: ({})
    // device.id -> the device's PipeWire properties (pw-dump), or {} when it gave none.
    property var routingDevices: ({})
    // Device ids waiting for pw-dump, the first one asked now.
    property var routingAsk: []

    function routingDeviceId(node: var): int {
        const id = parseInt(node.properties["device.id"], 10);
        return isFinite(id) && id >= 0 ? id : -1;
    }

    function routingDescribe(node: var): var {
        const id = root.routingDeviceId(node);
        return Routing.describe(node.properties, id >= 0 ? (root.routingDevices[id] ?? null) : null);
    }

    // The sinks whose properties Quickshell has read, by node name.
    function routingLive(): var {
        const live = {};
        for (const n of root.sinks) {
            if (n.ready && n.properties["node.name"] !== undefined)
                live[n.name] = n;
        }
        return live;
    }

    function routingApply(actions: var): void {
        for (const a of actions) {
            if (a.type === "note") {
                console.info(Routing.describeNote(a));
            } else if (a.type === "switch") {
                const node = root.sinks.find(n => n.name === a.node);
                // Refused (dev session) or gone: the next default change is not ours, nor is the configured default.
                if (!node || !root.backendWrite("output device", () => {
                        Pipewire.preferredDefaultAudioSink = node;
                    })) {
                    root.routing.expected = "";
                    root.routing.routed = "";
                }
            }
        }
        if (root.routing.dirty) {
            root.routing.dirty = false;
            if (!root.routingReadOnly) {
                routingWriter.command = ["sh", Quickshell.shellPath("services/write-private.sh"), Mode.stateDir, root.routingFile, Routing.serializeMemory(root.routing.memory)];
                routingWriter.running = true;
            }
        }
        const due = Routing.nextDeadline(root.routing);
        if (due === null) {
            routingTimer.stop();
        } else {
            routingTimer.interval = Math.max(1, due - Date.now());
            routingTimer.restart();
        }
    }

    function routingAskDevice(node: var): void {
        const id = root.routingDeviceId(node);
        if (id < 0 || root.routingDevices[id] !== undefined || root.routingAsk.indexOf(id) >= 0)
            return;
        root.routingAsk = root.routingAsk.concat([id]);
        root.routingNextAsk();
    }

    function routingNextAsk(): void {
        if (deviceDump.running || root.routingAsk.length === 0)
            return;
        deviceDump.deviceId = root.routingAsk[0];
        deviceDump.command = ["pw-dump", "--no-colors", String(deviceDump.deviceId)];
        deviceDump.running = true;
        dumpTimeout.restart();
    }

    function routingDeviceAnswer(id: int, props: var): void {
        if (root.routingAsk.indexOf(id) < 0)
            return;
        const devices = Object.assign({}, root.routingDevices);
        devices[id] = props ?? {};
        root.routingDevices = devices;
        root.routingAsk = root.routingAsk.filter(x => x !== id);
        if (root.routingStarted) {
            const now = Date.now();
            const live = root.routingLive();
            let actions = [];
            for (const name of Object.keys(root.routingFed)) {
                if (live[name] && root.routingDeviceId(live[name]) === id)
                    actions = actions.concat(Routing.updated(root.routing, root.routingDescribe(live[name]), now));
            }
            root.routingApply(actions);
        }
        root.routingNextAsk();
    }

    function syncRouting(): void {
        if (!root.routingMemoryReady || !Pipewire.ready)
            return;
        const now = Date.now();
        const live = root.routingLive();
        const fed = Object.assign({}, root.routingFed);
        let actions = [];
        if (!root.routingStarted) {
            const outputs = Object.keys(live).map(name => root.routingDescribe(live[name]));
            for (const name of Object.keys(live))
                fed[name] = true;
            actions = Routing.start(root.routing, outputs, Pipewire.defaultAudioSink ? Pipewire.defaultAudioSink.name : "", now);
            root.routingStarted = true;
        } else {
            for (const name of Object.keys(live)) {
                if (fed[name])
                    continue;
                fed[name] = true;
                actions = actions.concat(Routing.added(root.routing, root.routingDescribe(live[name]), now));
            }
            for (const name of Object.keys(fed)) {
                if (live[name])
                    continue;
                delete fed[name];
                // WirePlumber's configured default as Quickshell still resolves it (null once that node is gone: unknown).
                const configured = Pipewire.preferredDefaultAudioSink ? Pipewire.preferredDefaultAudioSink.name : "";
                actions = actions.concat(Routing.removed(root.routing, name, now, configured));
            }
        }
        root.routingFed = fed;
        for (const name of Object.keys(live))
            root.routingAskDevice(live[name]);
        root.routingApply(actions);
    }

    onSinksChanged: syncRouting()

    Connections {
        target: Pipewire

        function onReadyChanged(): void {
            root.syncRouting();
        }

        function onDefaultAudioSinkChanged(): void {
            // The default may be null for a moment while it changes: only real nodes are reported.
            if (!root.routingStarted || !Pipewire.defaultAudioSink)
                return;
            root.syncRouting();
            root.routingApply(Routing.defaultChanged(root.routing, Pipewire.defaultAudioSink.name, Date.now()));
        }
    }

    // A sink becomes known to the router once Quickshell has bound it and read its properties.
    Instantiator {
        model: root.sinks

        delegate: Connections {
            required property var modelData

            target: modelData

            function onReadyChanged(): void {
                root.syncRouting();
            }

            function onPropertiesChanged(): void {
                root.syncRouting();
            }
        }
    }

    Timer {
        id: routingTimer
        onTriggered: root.routingApply(Routing.tick(root.routing, Date.now()))
    }

    // The remembered choices (audio-routing.json, state class): read once; routing starts after it (or its absence).
    FileView {
        id: routingMemory
        path: root.routingFile
        printErrors: false

        function use(text: string): void {
            if (root.routingMemoryReady)
                return;
            const m = Routing.parseMemory(text);
            root.routingReadOnly = m.readOnly;
            root.routing = Routing.create({devices: m.devices});
            root.routingMemoryReady = true;
            root.syncRouting();
        }

        onLoaded: use(text())
        onLoadFailed: use("")
    }

    Process {
        id: routingWriter
        onExited: code => {
            if (code !== 0)
                console.warn("audio routing: could not write", root.routingFile);
        }
    }

    Process {
        id: deviceDump
        property int deviceId: -1
        stdout: StdioCollector {
            onStreamFinished: {
                dumpTimeout.stop();
                root.routingDeviceAnswer(deviceDump.deviceId, Routing.deviceProps(text, deviceDump.deviceId));
            }
        }
        onExited: code => {
            if (code !== 0) {
                dumpTimeout.stop();
                root.routingDeviceAnswer(deviceDump.deviceId, null);
            }
        }
    }

    // A pw-dump that does not answer: the node's own properties decide.
    Timer {
        id: dumpTimeout
        interval: 2000
        onTriggered: {
            deviceDump.running = false;
            root.routingDeviceAnswer(deviceDump.deviceId, null);
        }
    }
}
