pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.services

// On-screen display state (volume, brightness and keyboard backlight). Spec: docs/specs/osd.md.
//
// Shown when the default sink volume/mute or the backlight change (by any program), and by the
// IPC targets osd (tests), volume and brightness (real changes).
Singleton {
    id: root

    property string kind: "volume"
    property real level: 0
    property bool muted: false
    property bool shown: false

    readonly property string iconName: kind === "keyboard" ? "keyboard" : kind === "brightness" ? "sun" : (muted || level <= 0 ? "volume-mute" : level < 0.34 ? "volume-1" : level < 0.67 ? "volume-2" : "volume-3")

    // Changes before this are start-up noise (initial volume read), not user actions.
    property bool armed: false
    property bool kbdSeen: false

    function showValue(osdKind: string, osdLevel: real, osdMuted: bool): void {
        // NaN or infinite levels (bad IPC input, sensor glitch) are ignored; the rest is clamped.
        if (!isFinite(osdLevel))
            return;
        kind = osdKind === "brightness" || osdKind === "keyboard" ? osdKind : "volume";
        level = Math.max(0, Math.min(1, osdLevel));
        muted = osdMuted;
        shown = true;
        hideTimer.restart();
    }

    function showVolume(): void {
        if (Audio.ready)
            showValue("volume", Audio.volume, Audio.muted);
    }

    function showBrightness(): void {
        if (Brightness.available)
            showValue("brightness", Brightness.level, false);
    }

    function showKeyboard(): void {
        if (Brightness.kbdAvailable)
            showValue("keyboard", Brightness.kbdLevel, false);
    }

    function hide(): void {
        shown = false;
    }

    // Keyboard backlight keys (macOS: the keyboard brightness HUD). A step is 1/16 of the range, like the
    // 16 notches of the macOS keys, but at least one device step.
    function keyboardStep(direction: string): void {
        if (!Brightness.kbdAvailable) {
            console.info("osd: no keyboard backlight device; keyboard", direction, "ignored");
            return;
        }
        if (direction !== "up" && direction !== "down") {
            console.warn("osd: unknown keyboard command", direction);
            return;
        }
        const step = Math.max(1 / 16, 1 / Brightness.kbdMax);
        const target = Math.max(0, Math.min(1, Brightness.kbdLevel + (direction === "up" ? step : -step)));
        if (!Brightness.setKbdLevel(target))
            showKeyboard();
    }

    // Real volume change through wpctl (Audio.keyStep; refused in a dev session, nothing runs), then show.
    function volumeStep(direction: string): void {
        Audio.keyStep(direction);
    }

    function brightnessStep(direction: string): void {
        if (!Brightness.available) {
            console.info("osd: no backlight device; brightness", direction, "ignored");
            return;
        }
        if (direction !== "up" && direction !== "down") {
            console.warn("osd: unknown brightness command", direction);
            return;
        }
        // In a dev session adjust() only logs; the OSD still shows the current level.
        if (!Brightness.adjust(direction === "up" ? 0.05 : -0.05))
            showBrightness();
    }

    Timer {
        id: hideTimer
        interval: Tokens.osdHideDelay
        onTriggered: root.shown = false
    }

    Timer {
        id: arm
        interval: 1500
        onTriggered: root.armed = true
    }

    // wpctl returned; PipeWire reports the new state a moment later.
    Timer {
        id: settle
        interval: 120
        onTriggered: root.showVolume()
    }

    Connections {
        target: Audio

        function onKeyFinished(): void {
            settle.restart();
        }

        function onVolumeChanged(): void {
            if (root.armed)
                root.showVolume();
        }

        function onMutedChanged(): void {
            if (root.armed)
                root.showVolume();
        }

        // A new default output starts with its own volume: not a user change.
        function onSinkChanged(): void {
            root.armed = false;
            arm.restart();
        }
    }

    Connections {
        target: Brightness

        function onValueChanged(): void {
            if (Brightness.loaded && root.armed)
                root.showBrightness();
        }
    }

    Connections {
        target: Brightness

        // The first value is the initial read, not a user action.
        function onKbdValueChanged(): void {
            if (!root.kbdSeen)
                root.kbdSeen = true;
            else if (root.armed && Brightness.kbdAvailable)
                root.showKeyboard();
        }
    }

    Component.onCompleted: arm.start()

    IpcHandler {
        target: "osd"

        // Test hooks (dev session only, VisualFixtures.dev, SEC-04: no OSD spoofing by another process).
        // qs ipc call osd display <volume|brightness|keyboard> <0..1> <muted>
        function display(kind: string, level: real, muted: bool): void {
            if (VisualFixtures.dev)
                root.showValue(kind, level, muted);
        }

        function hide(): void {
            if (VisualFixtures.dev)
                root.hide();
        }
    }

    IpcHandler {
        target: "volume"

        function up(): void {
            root.volumeStep("up");
        }

        function down(): void {
            root.volumeStep("down");
        }

        function mute(): void {
            root.volumeStep("mute");
        }
    }

    IpcHandler {
        target: "brightness"

        function up(): void {
            root.brightnessStep("up");
        }

        function down(): void {
            root.brightnessStep("down");
        }
    }

    IpcHandler {
        target: "keyboard"

        function up(): void {
            root.keyboardStep("up");
        }

        function down(): void {
            root.keyboardStep("down");
        }
    }
}
