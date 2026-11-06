pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.services
import qs.osd

// Body of tests/shell/audio_dev_guard.sh (named guard.qml so the plain tests/shell/*/shell.qml loop skips it) (run it through that script: it sets the environment and a wpctl shim).
// GF_EXPECT=dev: every audio action of the shell (slider, scroll, volume keys through Osd/IPC, mute, device
// switches) must leave the stand-in sink untouched, never write the backend (Audio.backendWrites) and never start wpctl.
// GF_EXPECT=real (control, proves the test can fail): the same actions do change the stand-in sink and run the wpctl shim.
ShellRoot {
    id: root

    readonly property bool dev: Quickshell.env("GF_EXPECT") === "dev"
    property var failures: []
    property int suppressed: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    QtObject {
        id: fakeSink
        property var audio: QtObject {
            property real volume: 0.5
            property bool muted: false
        }
    }

    Connections {
        target: Audio
        function onDevSuppressed(): void {
            root.suppressed++;
        }
    }

    // Sound effects (ADR-0047 B-7): nothing plays in a dev session.
    property int soundSuppressed: 0

    Connections {
        target: Sounds
        function onDevSuppressed(): void {
            root.soundSuppressed++;
        }
    }

    Timer {
        interval: 50
        running: true
        onTriggered: root.run()
    }

    Timer {
        id: settle
        interval: 600
        onTriggered: root.finish()
    }

    function run(): void {
        Audio.sinkOverride = fakeSink;
        check("devSession matches the environment", Audio.devSession === dev);
        check("fixture sink is ready", Audio.ready);

        // Slider drag and volume-menu slider, menu bar scroll.
        const r = [Audio.setVolume(0.9), Audio.setVolume(0.1), Audio.adjust(0.05), Audio.adjust(-0.05)];
        // Mute button, volume keys (IPC volume up|down|mute).
        r.push(Audio.toggleMute());
        Osd.volumeStep("up");
        Osd.volumeStep("down");
        Osd.volumeStep("mute");
        r.push(Audio.keyStep("up"), Audio.keyStep("down"), Audio.keyStep("mute"));
        if (dev) {
            // Device switches (a real device node is needed only when they would be written).
            Audio.select(fakeSink);
            Audio.selectSource(fakeSink);
        }
        // Other services: guarded before anything else, whatever the hardware.
        Connectivity.toggleWifi(false);
        Connectivity.setAirplane(true);
        BluetoothState.setEnabled(false);
        const b = [Brightness.adjust(0.05), Brightness.setLevel(0.9), Brightness.setKbdLevel(0.9)];
        // The alert and an interface sound: what the settings let play (the owner's grassfield.json may silence them).
        const events = ["alert", "trash-empty"];
        const playable = events.filter(e => SoundEffects.argvFor(e, Sounds.settings, [], "/t") !== null).length;
        const s = events.map(e => Sounds.play(e));
        // GNOME's sound keys (gsettings): never written from a dev session.
        Sounds.gnomeWritten = "";
        Sounds.syncGnome();

        if (dev) {
            check("every volume/mute/key action refused", r.every(v => v === false));
            check("volume untouched", fakeSink.audio.volume === 0.5);
            check("mute untouched", fakeSink.audio.muted === false);
            check("zero backend writes", Audio.backendWrites === 0);
            check("every refusal signalled (4 volume + mute + 3 keys + 2 devices + 3 Osd keys)", suppressed === 13);
            check("brightness refused", b.every(v => v === false));
            check("no sound played", s.every(v => v === false) && Sounds.started === 0);
            check("every sound refusal signalled", soundSuppressed === playable);
            check("GNOME's sound keys untouched", Sounds.gnomeWrites === 0);
        } else {
            check("sounds played as the settings allow", Sounds.started === playable && soundSuppressed === 0);
            check("GNOME's sound keys written", Sounds.gnomeWrites >= 2);
            check("volume written", fakeSink.audio.volume < 0.5 || fakeSink.audio.volume > 0.5 || Audio.backendWrites > 0);
            check("mute written", fakeSink.audio.muted === true);
            check("backend written", Audio.backendWrites >= 9);
            check("not signalled", suppressed === 0);
        }
        settle.start();
    }

    function finish(): void {
        const tag = dev ? "audio_dev_guard (dev)" : "audio_dev_guard (control, real)";
        if (failures.length === 0) {
            console.log("PASS: " + tag);
            Qt.exit(0);
        } else {
            console.log("FAIL: " + tag + " " + failures.join(", "));
            Qt.exit(1);
        }
    }
}
