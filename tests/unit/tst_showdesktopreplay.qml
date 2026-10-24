import QtQuick
import QtTest
import "../../shell/platform/ShowDesktopFlow.js" as Flow
import "../../shell/platform/ShowDesktop.js" as SD

// The Show Desktop flow replayed on event sequences RECORDED from a nested Hyprland 0.56.2 (tests/shell/show_desktop_record.sh,
// tests/unit/fixtures/showdesktop/*.json): an app activating a parked window comes in two orders and the flow must give the
// focus to the window that was activated in both.
//  - dispatcher.json: the focus dispatcher (hl.dsp.focus) on a parked window: activespecial first, then activewindowv2 <A>;
//  - xdgact.json: a real xdg-activation request by a client (tests/tools/xdgact): urgent, activewindowv2 <X> BEFORE activespecial;
//    what follows the hide (the first window that comes back takes the focus) is a consequence of the ending, not the activation.
// The recorded events include what the running shell caused (the hide, the moves, its own focus request): they are replayed as
// they are, and the dispatches the flow returns are checked (the replay does not apply them: Hyprland already did, in the file).
TestCase {
    name: "ShowDesktopReplay"

    readonly property int checkMs: 120
    readonly property int verifyMs: 500
    property var out: []
    property var st: Flow.initial()
    property int clock: 0
    property var wins: []
    property var deadlines: ({})
    property var hyprlandShows: ({})

    function load(name) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("fixtures/showdesktop/" + name + ".json"), false);
        xhr.send();
        return JSON.parse(xhr.responseText);
    }

    function ctx(focused) {
        return {
            windows: wins.map(w => ({address: w.address, workspace: w.parked ? -98 : w.workspace, parked: w.parked, x: w.x, y: w.y, minimized: false, hidden: false})),
            shown: [{name: "GF-REF", workspace: wins.length > 0 ? wins[0].workspace : 1}],
            focused: focused || "",
            stages: false,
            loaded: true,
            currentWorkspace: wins.length > 0 ? wins[0].workspace : 0,
            lookbackEvents: 2,
            maxVerify: 3,
            maxRecover: 10,
            maxActivationTries: 3
        };
    }

    function run(res) {
        st = res.state;
        for (const d of res.dispatches)
            out.push(d);
        for (const id of Object.keys(res.timers)) {
            if (res.timers[id] === "stop")
                delete deadlines[id];
            else
                deadlines[id] = clock + (id === "verify" ? verifyMs : checkMs);
        }
    }

    function fireDue(upTo) {
        for (let guard = 0; guard < 50; guard++) {
            let best = "";
            for (const id of Object.keys(deadlines)) {
                if (deadlines[id] <= upTo && (best === "" || deadlines[id] < deadlines[best]))
                    best = id;
            }
            if (best === "")
                return;
            clock = Math.max(clock, deadlines[best]);
            delete deadlines[best];
            run(Flow.onTimer(st, ctx(""), best));
        }
    }

    // Show Desktop is on (the windows of the fixture parked), then the recorded events arrive.
    function replay(fx) {
        out = [];
        hyprlandShows = ({});
        st = Flow.initial();
        clock = 10000;
        deadlines = ({});
        wins = fx.windows.map(w => ({address: w.address, workspace: w.workspace, parked: false, x: w.x, y: w.y}));
        run(Flow.onPress(st, ctx(fx.focusBefore)));
        run(Flow.onCapture(st, ctx(fx.focusBefore)));
        wins.forEach(w => { w.parked = true; });
        out = [];
        compare(st.records.length, 1, "Show Desktop is on for the fixture's windows");
        const t0 = clock + 1000;
        for (const e of fx.events) {
            fireDue(t0 + e.t);
            clock = t0 + e.t;
            if (e.name === "movewindowv2") {
                const w = wins.find(x => SD.sameAddress(x.address, e.data.split(",")[0]));
                if (w)
                    w.parked = e.data.split(",")[2] === SD.PARKING;
            }
            // what Hyprland says about the parking workspace (the recorded events are its truth, our hide included)
            if (e.name.startsWith("activespecial"))
                hyprlandShows = SD.parkingShownAfter(hyprlandShows, e.name, e.data);
            run(Flow.onEvent(st, ctx(""), e.name, e.data));
        }
        fireDue(t0 + 2000);
    }

    // special:desktop is never left shown over a screen: the recorded events end with it hidden
    function cleanup() {
        verify(!SD.parkingVisible(hyprlandShows), "special:desktop is left shown over the screen");
    }

    function focusRequests() { return out.filter(d => d.indexOf("hl.dsp.focus") >= 0); }
    function toggles() { return out.filter(d => d.indexOf("toggle_special") >= 0).length; }
    function moves() { return out.filter(d => d.indexOf("window.move") >= 0); }

    function check(fx) {
        verify(out.length > 0 && out[0] === SD.hideParkingRequest(), "the hide is the first dispatch: " + JSON.stringify(out));
        compare(toggles(), 1, "one hide only");
        compare(moves().length, fx.windows.length, "every window goes back");
        for (const w of fx.windows)
            verify(moves().some(m => m.indexOf("address:0x" + SD.address(w.address)) >= 0), "window " + w.address + " goes back");
        compare(st.records.length, 0, "Show Desktop is over");
        const wanted = focusRequests();
        compare(wanted.length, 1, "exactly one focus request: " + JSON.stringify(wanted));
        verify(wanted[0].indexOf("address:0x" + SD.address(fx.window)) >= 0, "for the window that was activated (" + fx.window + "): " + wanted[0]);
    }

    function test_theFocusDispatcherOrderRecordedFromHyprland() {
        const fx = load("dispatcher");
        verify(fx.events.length > 3);
        // the order is the one the review expected for this path: the workspace, then the window
        const names = fx.events.map(e => e.name);
        verify(names.indexOf("activespecial") < names.indexOf("activewindowv2"));
        replay(fx);
        check(fx);
    }

    function test_aRealXdgActivationOrderRecordedFromHyprland() {
        const fx = load("xdgact");
        verify(fx.events.length > 3);
        // the order the review found in Hyprland's source: the window first, the workspace it shows after
        const names = fx.events.map(e => e.name);
        verify(names.indexOf("activewindowv2") < names.indexOf("activespecial"));
        replay(fx);
        check(fx);
    }

    function test_theRecordedXdgActivationHasAConsequenceThatNamesAnotherWindow() {
        // the fixture's own proof that the naive "first activewindowv2 after the workspace event" is wrong: after the hide, an
        // activewindowv2 names a window that is not the activated one
        const fx = load("xdgact");
        const names = fx.events.map(e => e.name + ":" + e.data.split(",")[0]);
        const after = fx.events.slice(fx.events.findIndex(e => e.name === "activespecial")).filter(e => e.name === "activewindowv2");
        verify(after.some(e => SD.address(e.data) !== SD.address(fx.window)), "recorded: " + JSON.stringify(names));
    }
}
