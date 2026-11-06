pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.lib
import qs.platform

// Grassfield's sound effects (ADR-0047 part B): the alert on the compositor's bell (GTK 4 apps ring it through
// xdg-system-bell; Hyprland posts `bell`), the interface sounds (Empty Trash, an item poofed off the Dock, power connected)
// and the volume feedback once the volume keys rest. What plays, how loud and where is SoundEffects.js (Grassfield.Ui), from
// the sound.* settings; this service only runs `pw-play` with that argument vector (never a shell). Do Not Disturb changes
// nothing (macOS keeps these sounds with a Focus on).
// GRASSFIELD_DEV: a nested session runs on the owner's machine, so nothing plays: play() logs, signals devSuppressed and
// returns false (tests/shell/audio_dev_guard.sh counts it); lastArgv still shows what would have run.
Singleton {
    id: root

    readonly property bool devSession: Mode.dev
    // The installed theme in a real session; the repository's own files in a dev session (never played there).
    readonly property string themeDir: devSession ? Quickshell.shellDir + "/../branding/sounds/grassfield/stereo" : SoundEffects.THEME_DIR
    readonly property var settings: ({
            alert: Settings.soundAlert,
            alertVolume: Settings.soundAlertVolume,
            effectsOutput: Settings.soundEffectsOutput,
            uiEffects: Settings.soundUiEffects,
            volumeFeedback: Settings.soundVolumeFeedback
        })
    // Test hooks: the last argument vector built (also when the dev guard refused it) and the sounds really started.
    property var lastArgv: null
    property int started: 0
    signal devSuppressed(string what)

    // event -> when it last started (SoundEffects.allowed); the volume feedback's due time (SoundEffects.feedbackStep).
    property var last: ({})
    property var feedback: ({due: null})

    // Plays an event of SoundEffects.EVENTS when its settings allow it. Returns true when a sound was started.
    function play(event: string): bool {
        const argv = SoundEffects.argvFor(event, root.settings, Audio.sinks.map(n => n.name), root.themeDir);
        if (argv === null || !SoundEffects.allowed(root.last, event, Date.now()))
            return false;
        root.lastArgv = argv;
        if (root.devSession) {
            console.info("dev guard: sound " + event + " suppressed");
            root.devSuppressed(event);
            return false;
        }
        root.started++;
        Quickshell.execDetached(argv);
        return true;
    }

    // A volume key (Osd.volumeStep): up and down (re)arm the feedback, mute cancels it.
    function volumeKey(direction: string): void {
        const due = SoundEffects.feedbackStep(root.feedback, direction, Date.now());
        if (due === null) {
            feedbackTimer.stop();
        } else {
            feedbackTimer.interval = Math.max(1, due - Date.now());
            feedbackTimer.restart();
        }
    }

    Timer {
        id: feedbackTimer
        onTriggered: {
            if (SoundEffects.feedbackDue(root.feedback, Date.now()))
                root.play("volume-change");
        }
    }

    Connections {
        target: Compositor

        function onBell(address: string): void {
            root.play("alert");
        }
    }

    // GNOME's sound keys in step with these settings (SoundEffects.gnomeArgvs: libcanberra and GSound applications, their
    // error bell included, play only while event-sounds is on), written at start and after each change once the settings have
    // rested (the store reads its file after the shell starts). A dev session writes nothing: the owner's dconf is not ours.
    // gnomeWrites counts the gsettings commands really started (a test hook).
    readonly property var gnomeArgvs: SoundEffects.gnomeArgvs(root.settings)
    property string gnomeWritten: ""
    property int gnomeWrites: 0
    onGnomeArgvsChanged: gnomeSync.restart()

    function syncGnome(): void {
        const key = JSON.stringify(root.gnomeArgvs);
        if (key === root.gnomeWritten)
            return;
        root.gnomeWritten = key;
        if (root.devSession) {
            console.info("dev guard: sound gnome settings suppressed");
            return;
        }
        for (const argv of root.gnomeArgvs) {
            root.gnomeWrites++;
            Quickshell.execDetached(argv);
        }
    }

    Timer {
        id: gnomeSync
        interval: 1000
        running: true
        onTriggered: root.syncGnome()
    }

    // Power connected: on battery, then on the adapter, once the shell has settled (not at start).
    property bool powerArmed: false
    property bool wasOnBattery: false

    Connections {
        target: Battery

        function onOnBatteryChanged(): void {
            if (root.powerArmed && root.wasOnBattery && !Battery.onBattery)
                root.play("power-plug");
            root.wasOnBattery = Battery.onBattery;
        }
    }

    Timer {
        interval: 3000
        running: true
        onTriggered: {
            root.wasOnBattery = Battery.onBattery;
            root.powerArmed = true;
        }
    }
}
