import QtQuick
import QtTest
import "../../shell/services/CaptureFile.js" as CaptureFile

// The capture helper's private state as the shell reads it (ADR-0045 OC-1, docs/specs/system-dialogs.md "Screen recording"
// SC16): its path in a session and in a dev session, its reading (every malformed field refused), the countdown's seconds,
// the recording's elapsed time and where the countdown plate goes.
TestCase {
    name: "CaptureFile"

    function test_path() {
        compare(CaptureFile.statePath("", "/run/user/1000"), "/run/user/1000/grassfield/capture-state.json");
        compare(CaptureFile.statePath("/repo/.dev/state", "/run/user/1000"), "/repo/.dev/state/capture-state.json",
            "a dev session reads its own state, never the real session's");
        compare(CaptureFile.statePath("", ""), "");
    }

    function test_recording() {
        const s = CaptureFile.parse(JSON.stringify({v: 1, phase: "recording", kind: "recording", pid: 12, start: 3, recorder: 13,
            recorderStart: 4, started: 1793800000000, rect: {x: 0, y: 0, w: 1920, h: 1080}, output: "HDMI-A-1"}));
        compare(s.phase, "recording");
        compare(s.kind, "recording");
        compare(s.started, 1793800000000);
        compare(s.rect, {x: 0, y: 0, w: 1920, h: 1080});
        compare(s.output, "HDMI-A-1");
    }

    function test_countdown() {
        const s = CaptureFile.parse('{"v": 1, "phase": "countdown", "kind": "shot", "until": 1793800005000, "rect": {"x": 10, "y": 20, "w": 300, "h": 200}, "output": ""}');
        compare(s.phase, "countdown");
        compare(s.until, 1793800005000);
        compare(s.rect.w, 300);
    }

    function test_malformed() {
        for (const text of ["", "{", "[]", "null", "1", '{"phase": "recording", "started": 5}', '{"v": 2, "phase": "idle"}',
                 '{"v": 1, "phase": "dancing"}', '{"v": 1, "phase": "countdown"}', '{"v": 1, "phase": "recording", "started": "now"}',
                 '{"v": 1, "phase": "recording", "started": -5}'])
            compare(CaptureFile.parse(text).phase, "idle", text);
        const s = CaptureFile.parse('{"v": 1, "phase": "countdown", "until": 9, "kind": "evil", "output": "../x", "rect": {"x": 0, "y": 0, "w": 0, "h": 5}}');
        compare(s.kind, "");
        compare(s.output, "", "an output name that is not a connector's is dropped");
        compare(s.rect, null, "an empty area is dropped");
        compare(CaptureFile.parse('{"v": 1, "phase": "countdown", "until": 9, "rect": [1, 2, 3, 4]}').rect, null);
        compare(CaptureFile.parse('{"v": 1, "phase": "countdown", "until": 9, "rect": {"x": "0", "y": 0, "w": 5, "h": 5}}').rect, null);
    }

    function test_secondsLeft() {
        compare(CaptureFile.secondsLeft(1000, 6000), 5);
        compare(CaptureFile.secondsLeft(1001, 6000), 5, "4.999 s left shows 5");
        compare(CaptureFile.secondsLeft(5001, 6000), 1);
        compare(CaptureFile.secondsLeft(6000, 6000), 0);
        compare(CaptureFile.secondsLeft(7000, 6000), 0);
        compare(CaptureFile.secondsLeft(NaN, 6000), 0);
    }

    function test_elapsed() {
        compare(CaptureFile.elapsed(0), "0:00");
        compare(CaptureFile.elapsed(12999), "0:12");
        compare(CaptureFile.elapsed(65000), "1:05");
        compare(CaptureFile.elapsed(3599000), "59:59");
        compare(CaptureFile.elapsed(3600000), "1:00:00");
        compare(CaptureFile.elapsed(3725000), "1:02:05");
        compare(CaptureFile.elapsed(-5000), "0:00", "a clock that went back");
        compare(CaptureFile.elapsed(undefined), "0:00");
    }

    function test_plate() {
        const screens = [{name: "DP-1", x: 0, y: 0, width: 2560, height: 1440}, {name: "HDMI-A-1", x: 2560, y: 0, width: 1920, height: 1080}];
        const onDp = {output: "", rect: {x: 100, y: 100, w: 400, h: 200}};
        compare(CaptureFile.plateScreen(onDp, screens), "DP-1");
        compare(CaptureFile.plateCentre(onDp, screens[0]), {x: 300, y: 200});
        const named = {output: "HDMI-A-1", rect: {x: 2560, y: 0, w: 1920, h: 1080}};
        compare(CaptureFile.plateScreen(named, screens), "HDMI-A-1");
        compare(CaptureFile.plateCentre(named, screens[1]), {x: 960, y: 540});
        compare(CaptureFile.plateScreen({output: "gone", rect: {x: 3000, y: 10, w: 20, h: 20}}, screens), "HDMI-A-1",
            "a display that went away: the one under the area");
        compare(CaptureFile.plateScreen({output: "", rect: null}, screens), "");
        compare(CaptureFile.plateCentre({output: "", rect: {x: 9000, y: 0, w: 10, h: 10}}, screens[0]), {x: 1280, y: 720},
            "an area off this display: its centre");
    }
}
