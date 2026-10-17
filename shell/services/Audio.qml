pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "../overlay/controlcenter/Model.js" as Model

// Default output (PipeWire through Quickshell). volume is 0..1 (values above 1 are not offered).
Singleton {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink !== null && sink.audio !== null
    readonly property real volume: ready ? sink.audio.volume : 0
    readonly property bool muted: ready ? sink.audio.muted : false
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

    // In a GRASSFIELD_DEV session the volume may only move within +-5 percent of where it was
    // (devBaseline, restored by devRestore()); the default device is never switched.
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1"
    property real devBaseline: -1
    signal devSuppressed(string what)

    function setVolume(value: real): void {
        if (!ready)
            return;
        let v = Math.max(0, Math.min(1, value));
        if (devSession) {
            if (devBaseline < 0)
                devBaseline = volume;
            v = Model.devVolume(devBaseline, v, 0.05);
        }
        sink.audio.volume = v;
        if (devSession)
            devRestoreTimer.restart();
    }

    // The +-5 percent clamp applies to every caller (Control Center, volume menu, menu bar scroll);
    // the volume goes back to the baseline when it has been left alone for a while, and when the
    // shell exits (best effort: a killed shell cannot restore, the drift is at most 5 percent).
    Timer {
        id: devRestoreTimer
        interval: 5000
        onTriggered: root.devRestore()
    }

    Component.onDestruction: devRestore()

    function devRestore(): void {
        if (devSession && devBaseline >= 0 && ready)
            sink.audio.volume = devBaseline;
        devBaseline = -1;
    }

    function selectSource(node: var): void {
        if (devSession) {
            console.info("dev guard: input device switch suppressed");
            devSuppressed("input device");
            return;
        }
        Pipewire.preferredDefaultAudioSource = node;
    }

    function adjust(delta: real): void {
        setVolume(volume + delta);
    }

    function toggleMute(): void {
        if (!ready)
            return;
        if (devSession) {
            console.info("dev guard: mute toggle suppressed");
            devSuppressed("mute");
            return;
        }
        sink.audio.muted = !sink.audio.muted;
    }

    function describe(node: var): string {
        return node.nickname !== "" ? node.nickname : (node.description !== "" ? node.description : node.name);
    }

    function select(node: var): void {
        if (devSession) {
            console.info("dev guard: output device switch suppressed");
            devSuppressed("output device");
            return;
        }
        Pipewire.preferredDefaultAudioSink = node;
    }

    // Nodes must be tracked to expose their audio properties.
    PwObjectTracker {
        objects: [root.sink, root.source].concat(root.sinks).concat(root.sources)
    }
}
