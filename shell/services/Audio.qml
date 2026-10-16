pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

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

    function setVolume(value: real): void {
        if (ready)
            sink.audio.volume = Math.max(0, Math.min(1, value));
    }

    function adjust(delta: real): void {
        setVolume(volume + delta);
    }

    function toggleMute(): void {
        if (ready)
            sink.audio.muted = !sink.audio.muted;
    }

    function describe(node: var): string {
        return node.nickname !== "" ? node.nickname : (node.description !== "" ? node.description : node.name);
    }

    function select(node: var): void {
        Pipewire.preferredDefaultAudioSink = node;
    }

    // Nodes must be tracked to expose their audio properties.
    PwObjectTracker {
        objects: [root.sink].concat(root.sinks)
    }
}
