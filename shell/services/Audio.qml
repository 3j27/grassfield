pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import qs.lib
import Quickshell.Io
import Quickshell.Services.Pipewire

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
}
