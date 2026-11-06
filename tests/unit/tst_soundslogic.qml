import QtQuick
import QtTest
import Grassfield.Ui

// ADR-0047 part B: which sound an event plays, how loud, where, and the pw-play argument vector (ui/Grassfield/Ui/SoundEffects.js).
TestCase {
    id: testCase
    name: "SoundEffects"

    readonly property var defaults: ({alert: "meadow", alertVolume: 0.75, effectsOutput: "", uiEffects: true, volumeFeedback: false})

    function settings(over) {
        return Object.assign({}, defaults, over || {});
    }

    function test_alertFilesExistInTheSoundSet() {
        // Every alert id has its file in branding/sounds (the generator's list), and the schema enum is the same list.
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/schema/grassfield.schema.json"), false);
        xhr.send();
        const schema = JSON.parse(xhr.responseText);
        compare(schema.properties.sound.properties.alert.enum, SoundEffects.ALERTS);
        compare(schema.properties.sound.properties.alert.default, SoundEffects.DEFAULT_ALERT);
        const files = SoundEffects.ALERTS.map(id => SoundEffects.alertFile(id));
        for (const name of Object.keys(SoundEffects.EVENTS))
            files.push(SoundEffects.fileFor(name, "meadow"));
        for (const f of files) {
            const r = new XMLHttpRequest();
            r.open("GET", Qt.resolvedUrl("../../branding/sounds/grassfield/stereo/" + f), false);
            r.send();
            verify(r.responseText.length > 44, f + " exists");
        }
    }

    function test_fileFor() {
        compare(SoundEffects.fileFor("alert", "reed"), "grassfield-alert-reed.wav");
        compare(SoundEffects.fileFor("alert", "Basso"), "grassfield-alert-meadow.wav", "an unknown alert is the default");
        compare(SoundEffects.fileFor("screen-capture", ""), "screen-capture.wav");
        compare(SoundEffects.fileFor("nope", ""), "");
    }

    function test_streamVolumeIsCubic() {
        compare(SoundEffects.streamVolume(1), "1.000");
        compare(SoundEffects.streamVolume(0.5), "0.125");
        compare(SoundEffects.streamVolume(0), "0.000");
        compare(SoundEffects.streamVolume(4), "1.000");
        compare(SoundEffects.streamVolume(-1), "0.000");
        compare(SoundEffects.streamVolume(NaN), "0.000");
        compare(SoundEffects.streamVolume("0.5"), "0.000");
    }

    function test_alertArgv() {
        compare(SoundEffects.argvFor("alert", settings({alert: "lantern"}), [], "/t"),
                ["pw-play", "--media-role", "Notification", "--volume", "0.422", "--", "/t/grassfield-alert-lantern.wav"]);
        // Default theme directory.
        compare(SoundEffects.argvFor("alert", settings(), [])[6], "/usr/share/sounds/grassfield/stereo/grassfield-alert-meadow.wav");
        // Alert volume 0: alert sounds off, the bell is silent.
        compare(SoundEffects.argvFor("alert", settings({alertVolume: 0}), []), null);
        // The alert plays even with interface sounds off.
        verify(SoundEffects.argvFor("alert", settings({uiEffects: false}), []) !== null);
    }

    function test_effectsOutputWhileConnected() {
        const s = settings({effectsOutput: "bluez_output.AA_BB_CC_DD_EE_FF.1"});
        const a = SoundEffects.argvFor("trash-empty", s, ["alsa_output.x", "bluez_output.AA_BB_CC_DD_EE_FF.1"], "/t");
        compare(a, ["pw-play", "--media-role", "Notification", "--volume", "0.422", "--target", "bluez_output.AA_BB_CC_DD_EE_FF.1", "--", "/t/trash-empty.wav"]);
        // Not connected: the selected (default) device.
        verify(SoundEffects.argvFor("trash-empty", s, ["alsa_output.x"], "/t").indexOf("--target") < 0);
        // A value that is not a node name is never passed.
        verify(SoundEffects.argvFor("alert", settings({effectsOutput: "-rf"}), ["-rf"], "/t").indexOf("--target") < 0);
        compare(SoundEffects.target("a b", ["a b"]), "");
    }

    function test_uiEffectsGate() {
        for (const ev of ["screen-capture", "trash-empty", "dock-remove", "power-plug"]) {
            verify(SoundEffects.argvFor(ev, settings(), []) !== null, ev);
            compare(SoundEffects.argvFor(ev, settings({uiEffects: false}), []), null, ev);
            compare(SoundEffects.argvFor(ev, settings({alertVolume: 0}), []), null, ev);
            // Only an exact true counts.
            compare(SoundEffects.argvFor(ev, settings({uiEffects: "true"}), []), null, ev);
        }
    }

    function test_volumeFeedback() {
        compare(SoundEffects.argvFor("volume-change", settings(), []), null, "off by default, as macOS");
        const a = SoundEffects.argvFor("volume-change", settings({volumeFeedback: true, effectsOutput: "x", alertVolume: 0.1}), ["x"], "/t");
        // Full stream volume, through the default output whatever the effects output.
        compare(a, ["pw-play", "--media-role", "Notification", "--volume", "1.000", "--", "/t/audio-volume-change.wav"]);
    }

    function test_unknownEventOrSettings() {
        compare(SoundEffects.argvFor("bogus", settings(), []), null);
        compare(SoundEffects.argvFor("alert", null, []), null);
    }

    function test_previewArgv() {
        compare(SoundEffects.previewArgv("ember", 1, ""), ["pw-play", "--media-role", "Notification", "--volume", "1.000", "--", "/usr/share/sounds/grassfield/stereo/grassfield-alert-ember.wav"]);
        compare(SoundEffects.previewArgv("ember", 0, "alsa_output.y")[6], "alsa_output.y");
        compare(SoundEffects.previewArgv("zzz", 0.5, undefined)[6], "/usr/share/sounds/grassfield/stereo/grassfield-alert-meadow.wav");
    }

    function test_playArgvRefusesOddFiles() {
        compare(SoundEffects.playArgv("/t", "../x.wav", 1, ""), null);
        compare(SoundEffects.playArgv("/t", "x.ogg", 1, ""), null);
        compare(SoundEffects.playArgv("/t", "", 1, ""), null);
    }

    function test_repeatGap() {
        const last = {};
        verify(SoundEffects.allowed(last, "alert", 1000));
        verify(!SoundEffects.allowed(last, "alert", 1000 + SoundEffects.REPEAT_GAP_MS - 1));
        verify(SoundEffects.allowed(last, "trash-empty", 1001), "another sound is independent");
        verify(SoundEffects.allowed(last, "alert", 1000 + SoundEffects.REPEAT_GAP_MS));
        // A clock that went back never blocks for good.
        verify(SoundEffects.allowed(last, "alert", 10));
    }

    function test_feedbackDebounce() {
        const st = {due: null};
        verify(!SoundEffects.feedbackDue(st, 0));
        compare(SoundEffects.feedbackStep(st, "up", 0), SoundEffects.FEEDBACK_QUIET_MS);
        // Held key: repeats every 25 ms after 250 ms keep pushing it.
        let t = 250;
        for (; t < 1250; t += 25) {
            verify(!SoundEffects.feedbackDue(st, t));
            SoundEffects.feedbackStep(st, "up", t);
        }
        const last = t - 25;
        verify(!SoundEffects.feedbackDue(st, last + SoundEffects.FEEDBACK_QUIET_MS - 1));
        verify(SoundEffects.feedbackDue(st, last + SoundEffects.FEEDBACK_QUIET_MS));
        verify(!SoundEffects.feedbackDue(st, last + 2 * SoundEffects.FEEDBACK_QUIET_MS), "plays once");
        // Mute cancels.
        SoundEffects.feedbackStep(st, "down", 5000);
        compare(SoundEffects.feedbackStep(st, "mute", 5010), null);
        verify(!SoundEffects.feedbackDue(st, 9000));
    }

    // GNOME's sound keys follow Grassfield's (review of ADR-0047 B, MINOR 4): libcanberra and GSound apps play theme sounds,
    // the error bell included, only while org.gnome.desktop.sound event-sounds is on.
    function test_gnomeKeysFollowTheSettings() {
        verify(SoundEffects.gnomeEventSounds(settings()));
        verify(!SoundEffects.gnomeEventSounds(settings({uiEffects: false})), "interface sounds off");
        verify(!SoundEffects.gnomeEventSounds(settings({alertVolume: 0})), "alert sounds off");
        verify(!SoundEffects.gnomeEventSounds(settings({uiEffects: "true"})), "only an exact true");
        verify(!SoundEffects.gnomeEventSounds(null));
        compare(SoundEffects.gnomeArgvs(settings()), [
            ["gsettings", "set", "org.gnome.desktop.sound", "event-sounds", "true"],
            ["gsettings", "set", "org.gnome.desktop.sound", "input-feedback-sounds", "false"]
        ]);
        compare(SoundEffects.gnomeArgvs(settings({alertVolume: 0}))[0][4], "false");
        // The packaged default (packaging/dconf) matches the defaults' mapping.
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../packaging/dconf/grassfield.d/30-sounds.conf"), false);
        xhr.send();
        verify(/^event-sounds=true$/m.test(xhr.responseText));
        verify(/^input-feedback-sounds=false$/m.test(xhr.responseText));
        verify(/^theme-name='grassfield'$/m.test(xhr.responseText));
    }

    function test_quietLongerThanKeyRepeatDelay() {
        // Grassfield's repeat delay (config/hypr/grassfield/omarchy.lua): a held key must not play at its start.
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../config/hypr/grassfield/omarchy.lua"), false);
        xhr.send();
        const m = /repeat_delay\s*=\s*(\d+)/.exec(xhr.responseText);
        verify(m !== null);
        verify(SoundEffects.FEEDBACK_QUIET_MS > parseInt(m[1], 10));
    }
}
