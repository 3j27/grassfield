import QtQuick
import QtTest
import "../../shell/platform/DisplaysFile.js" as DisplaysFile

// ADR-0031: the runtime files between the shell and Settings > Displays. Paths of a real and of a dev session, the state the
// shell publishes (only typed fields, monitors without a name left out), the trial file's first line, and what the shell does
// with it: apply a new trial, keep or take back the one it runs, take back any trial it finds when it starts or past its
// deadline, and ignore what is not its trial.
TestCase {
    name: "DisplaysFile"

    function test_paths() {
        compare(DisplaysFile.statePath(false, "/dev/state", "/run/user/1000"), "/run/user/1000/grassfield-displays.json");
        compare(DisplaysFile.trialPath(false, "/dev/state", "/run/user/1000"), "/run/user/1000/grassfield-display-trial.conf");
        compare(DisplaysFile.statePath(true, "/dev/state", "/run/user/1000"), "/dev/state/displays.json");
        compare(DisplaysFile.trialPath(true, "/dev/state", "/run/user/1000"), "/dev/state/display-trial.conf");
        // A dev session without its state directory never falls back to the real runtime directory.
        compare(DisplaysFile.trialPath(true, "", "/run/user/1000"), "");
        compare(DisplaysFile.statePath(false, "", ""), "");
    }

    function test_same() {
        const a = DisplaysFile.payload([{name: "eDP-1"}], null, null);
        verify(!DisplaysFile.same("", a), "nothing written yet: write");
        verify(!DisplaysFile.same(undefined, a));
        verify(DisplaysFile.same(a, DisplaysFile.payload([{name: "eDP-1"}], null, null)), "the same description is not written again");
        verify(!DisplaysFile.same(a, DisplaysFile.payload([{name: "eDP-1"}, {name: "DP-2"}], null, null)), "a new monitor is");
        verify(!DisplaysFile.same(a, DisplaysFile.payload([{name: "eDP-1"}], null, {id: "a1", state: "applying"})), "a trial state is");
    }

    function test_payload() {
        const ipc = {name: "eDP-1", description: "BOE 0x0BCA", make: "BOE", model: "0x0BCA", serial: "", width: 2880, height: 1800,
            physicalWidth: 300, physicalHeight: 190, refreshRate: 120.0, x: 0, y: 0, scale: 1.6, transform: 0, disabled: false, focused: true,
            availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz", 42]};
        const j = JSON.parse(DisplaysFile.payload([ipc, null, {width: 10}], {device: "intel_backlight", level: 1.7}, {id: "a1b2", state: "applied"}));
        compare(j.v, 1);
        compare(j.monitors.length, 1);
        compare(j.monitors[0], {name: "eDP-1", description: "BOE 0x0BCA", make: "BOE", model: "0x0BCA", serial: "", width: 2880, height: 1800,
            physicalWidth: 300, physicalHeight: 190, refreshRate: 120, x: 0, y: 0, scale: 1.6, transform: 0, disabled: false,
            availableModes: ["2880x1800@120.00Hz", "2880x1800@60.00Hz"]});
        compare(j.backlight, {device: "intel_backlight", level: 1});
        compare(j.trial, {id: "a1b2", state: "applied"});
        const none = JSON.parse(DisplaysFile.payload(undefined, {device: ""}, {id: "a b", state: "applied"}));
        compare(none.monitors, []);
        compare(none.backlight, null);
        compare(none.trial, null);
    }

    function test_parseTrial() {
        compare(DisplaysFile.parseTrial("trial a1b2 until 1793022747\nv1\t..."), {state: "trial", id: "a1b2", until: 1793022747});
        compare(DisplaysFile.parseTrial("kept a1b2\n"), {state: "kept", id: "a1b2"});
        compare(DisplaysFile.parseTrial("revert a1b2"), {state: "revert", id: "a1b2"});
        for (const bad of ["", "trial a1b2", "trial a-b until 1", "trial a1b2 until soon", "keep a1b2", " kept a1b2", "kept", "trial " + "x".repeat(33) + " until 1"])
            compare(DisplaysFile.parseTrial(bad), null, bad);
    }

    function test_action() {
        const now = 1000;
        const trial = (id, until) => ({state: "trial", id: id, until: until});
        // A new trial is applied; the one already running is left alone; at start or past its deadline it is taken back.
        compare(DisplaysFile.action(trial("a", 1015), "", false, now), "apply");
        compare(DisplaysFile.action(trial("b", 1015), "a", false, now), "apply");
        compare(DisplaysFile.action(trial("a", 1015), "a", false, now), "");
        compare(DisplaysFile.action(trial("a", 1015), "", true, now), "revert");
        compare(DisplaysFile.action(trial("a", 1000), "", false, now), "revert");
        // Keep and Revert count only for the trial the shell runs.
        compare(DisplaysFile.action({state: "kept", id: "a"}, "a", false, now), "keep");
        compare(DisplaysFile.action({state: "revert", id: "a"}, "a", false, now), "revert");
        compare(DisplaysFile.action({state: "kept", id: "a"}, "b", false, now), "");
        compare(DisplaysFile.action({state: "revert", id: "a"}, "", false, now), "");
        // An empty or unreadable file: nothing, unless a trial runs (its rules are gone from the file: read the config again).
        compare(DisplaysFile.action(null, "", false, now), "");
        compare(DisplaysFile.action(null, "", true, now), "");
        compare(DisplaysFile.action(null, "a", false, now), "revert");
        // A deadline further ahead than the longest trial Settings writes (60 s) is taken back, as displays.lua refuses it.
        compare(DisplaysFile.MAX_TRIAL_SECONDS, 60);
        compare(DisplaysFile.action(trial("a", now + 60), "", false, now), "apply");
        compare(DisplaysFile.action(trial("a", now + 61), "", false, now), "revert");
        compare(DisplaysFile.action(trial("a", 999999999999), "a", false, now), "revert");
    }

    function test_countdown() {
        // The deadline Timer's interval: the time left, never below 0, never above 60 s (a far deadline cannot overflow its int).
        compare(DisplaysFile.countdownMs(1015, 1000000), 15000);
        compare(DisplaysFile.countdownMs(1000, 1000500), 0);
        compare(DisplaysFile.countdownMs(999999999999, 1000000), 60000);
        verify(DisplaysFile.countdownMs(999999999999, 1000000) <= 2147483647);
    }

    function test_answered() {
        // Hyprland answered "ok" to the reload that applies the trial being run: it is applied.
        const applying = {id: "a", state: "applying"};
        compare(DisplaysFile.answered(applying, "a", 2, 2, true), {id: "a", state: "applied"});
        // The answer to another reload (one asked for earlier: the previous trial taken back, the input files), a refusal, or
        // an answer that comes after the trial ended changes nothing.
        verify(DisplaysFile.answered(applying, "a", 2, 1, true) === applying);
        verify(DisplaysFile.answered(applying, "a", 2, 2, false) === applying);
        verify(DisplaysFile.answered(applying, "a", 0, 0, true) === applying);
        verify(DisplaysFile.answered(applying, "", 2, 2, true) === applying);
        verify(DisplaysFile.answered(applying, "b", 2, 2, true) === applying);
        for (const t of [null, {id: "a", state: "applied"}, {id: "a", state: "kept"}, {id: "a", state: "reverted"}])
            verify(DisplaysFile.answered(t, "a", 2, 2, true) === t, JSON.stringify(t));
    }
}
