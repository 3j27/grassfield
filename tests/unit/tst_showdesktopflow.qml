import QtQuick
import QtTest
import "../../shell/platform/ShowDesktopFlow.js" as Flow
import "../../shell/platform/ShowDesktop.js" as SD

// The Show Desktop event flow (shell/platform/ShowDesktopFlow.js, reviews 4 and 5 of the shell UX batch) driven the way
// Compositor.qml drives it, against a small model of Hyprland: the dispatches the flow returns are queued and applied in order,
// applying them posts the events the real compositor posts, the shell reads those events in order, and the timers the flow asks
// for fire on a manual clock. The event orders of an app activation are the two Hyprland produces (see tst_showdesktopreplay.qml
// for the same flow driven by sequences recorded from a nested Hyprland):
//  - a real activation (xdg-activation, focus_on_activate): activewindowv2 <A> BEFORE activespecial (CWindow::activate);
//  - the focus dispatcher (hl.dsp.focus): activespecial first, activewindowv2 <A> after it.
TestCase {
    name: "ShowDesktopFlow"

    readonly property var interval: ({activation: 120, check: 120, verify: 500, recover: 1500, refresh: 150})
    property var st: Flow.initial()
    property int clock: 1000
    property var deadlines: ({})
    property var wins: []
    property var queue: []
    property var events: []
    property var sent: []
    property bool special: false
    property string hfocus: ""
    property string plast: ""
    property var disk: []
    property int diskClears: 0
    property int desktopFocus: 0
    property var stuck: ({})
    property bool loadedList: true
    property var shownNow: [{name: "DP-1", workspace: 1}]
    property int currentWs: 1

    function win(address, workspace, x, extra) {
        return Object.assign({address: address, workspace: workspace, parked: false, x: x, y: 0, minimized: false, hidden: false}, extra || {});
    }

    function init() {
        st = Flow.initial();
        clock = 1000;
        deadlines = ({});
        wins = [win("a1", 1, 0), win("b2", 1, 960), win("c9", 1, 10, {minimized: true})];
        queue = [];
        events = [];
        sent = [];
        special = false;
        hfocus = "b2";
        plast = "";
        disk = [];
        diskClears = 0;
        desktopFocus = 0;
        stuck = ({});
        loadedList = true;
        shownNow = [{name: "DP-1", workspace: 1}];
        currentWs = 1;
    }

    // the parking workspace is never left shown over a screen: every test ends with it hidden (the reviewers' cleanup check)
    function cleanup() {
        advance(3000);
        verify(!special, "special:desktop is left shown over the screen");
    }

    // ---- the model ----------------------------------------------------------------------------------------------------------

    function ctx() {
        return {
            windows: wins.map(w => ({address: w.address, workspace: w.parked ? -98 : w.workspace, parked: w.parked, x: w.x, y: w.y, minimized: w.minimized, hidden: w.hidden})),
            shown: shownNow,
            currentWorkspace: currentWs,
            focused: hfocus,
            stages: false,
            loaded: loadedList,
            lookbackEvents: 2,
            maxVerify: 3,
            maxRecover: 10,
            maxActivationTries: 3
        };
    }

    function run(res) {
        st = res.state;
        for (const d of res.dispatches) {
            sent.push(d);
            queue.push(d);
        }
        if (res.persist) {
            disk = JSON.parse(JSON.stringify(st.records));
            if (st.records.length === 0)
                diskClears++;
        }
        for (const id of Object.keys(res.timers)) {
            if (res.timers[id] === "stop")
                delete deadlines[id];
            else
                deadlines[id] = clock + interval[id];
        }
        if (res.refresh)
            deadlines.refresh = clock + interval.refresh;
        if (res.focusDesktop)
            desktopFocus++;
        return res;
    }

    function post(name, data) { events.push({name: name, data: data}); }
    function showEvents() { post("activespecial", "special:desktop,DP-1"); post("activespecialv2", "-98,special:desktop,DP-1"); }
    function hideEvents() { post("activespecial", ",DP-1"); post("activespecialv2", ",,DP-1"); }

    // Hyprland applying one dispatch and posting what it posts
    function apply(req) {
        if (req === SD.hideParkingRequest()) {
            special = !special;
            if (special) {
                showEvents();
            } else {
                hideEvents();
                // setSpecialWorkspace(nullptr): the focus goes to the regular workspace's last window if there is one that is
                // not parked (recorded: no event otherwise, the focus comes with the first window that moves back)
                const last = wins.find(w => w.address === plast);
                if (last && !last.parked) {
                    hfocus = last.address;
                    post("activewindowv2", hfocus);
                }
            }
            return;
        }
        let m = /workspace = "([^"]+)".*address:0x([0-9a-f]+)/.exec(req);
        if (m) {
            for (const w of wins) {
                if (w.address !== m[2])
                    continue;
                if (m[1] === SD.PARKING) {
                    w.parked = true;
                } else if (!stuck[w.address]) {
                    w.parked = false;
                    w.workspace = parseInt(m[1]);
                }
                post("movewindowv2", w.address + "," + (w.parked ? -98 : w.workspace) + "," + m[1]);
                // recorded: a window that comes back takes the focus when the focused window is parked (or none)
                const focused = wins.find(x => x.address === hfocus);
                if (!w.parked && w.address !== hfocus && (!focused || focused.parked)) {
                    hfocus = w.address;
                    post("activewindowv2", w.address);
                }
            }
            return;
        }
        m = /focus\(\{ window = "address:0x([0-9a-f]+)"/.exec(req);
        if (m) {
            const w = wins.find(x => x.address === m[1]);
            if (w && w.parked && !special) {
                special = true;
                showEvents();
            }
            hfocus = m[1];
            post("activewindowv2", m[1]);
        }
    }

    function settle() {
        for (let i = 0; i < 200 && (events.length || queue.length); i++) {
            if (events.length) {
                const e = events.shift();
                clock += 1;
                run(Flow.onEvent(st, ctx(), e.name, e.data));
            } else {
                const q = queue;
                queue = [];
                q.forEach(apply);
            }
        }
    }

    function fire(id) {
        if (id === "refresh")
            run(Flow.onCapture(st, ctx()));
        else
            run(Flow.onTimer(st, ctx(), id));
    }

    function advance(ms) {
        const end = clock + ms;
        for (let guard = 0; guard < 500; guard++) {
            settle();
            let best = "";
            for (const id of Object.keys(deadlines)) {
                if (deadlines[id] <= end && (best === "" || deadlines[id] < deadlines[best]))
                    best = id;
            }
            if (best === "") {
                clock = end;
                break;
            }
            clock = Math.max(clock, deadlines[best]);
            delete deadlines[best];
            fire(best);
        }
        settle();
    }

    function press() { run(Flow.onPress(st, ctx())); settle(); }
    // a press that records and parks (the window list is read first: the refresh timer)
    function park() { press(); advance(interval.refresh + 10); }
    function parkedAddresses() { return wins.filter(w => w.parked).map(w => w.address).sort(); }
    function toggles() { return sent.filter(s => s.indexOf("toggle_special") >= 0).length; }
    function focusRequests() { return sent.filter(s => s.indexOf("hl.dsp.focus") >= 0); }
    function moveBack(address) { return sent.filter(s => s.indexOf("address:0x" + address) >= 0 && s.indexOf("workspace = \"1\"") >= 0).length; }

    // Hyprland activating parked A as CWindow::activate does (xdg-activation, focus_on_activate): the focus first, the special
    // workspace shown by it
    function realActivation(a) { special = true; hfocus = a; post("activewindowv2", a); showEvents(); }
    // as the dispatcher hl.dsp.focus (recorded): the workspace first, the window after
    function dispatcherActivation(a) { special = true; showEvents(); hfocus = a; post("activewindowv2", a); }

    // ---- an app activating a parked window, both real orders -------------------------------------------------------------------

    function test_realActivationOrderGivesTheFocusToTheActivatedWindow() {
        park();
        compare(parkedAddresses(), ["a1", "b2"]);
        sent = [];
        realActivation("a1");
        advance(300);
        compare(special, false, "the parking workspace is hidden again");
        compare(parkedAddresses(), []);
        compare(st.records.length, 0);
        verify(sent[0].indexOf("toggle_special") >= 0, "the hide is the first dispatch of the ending");
        compare(toggles(), 1);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xa1") >= 0, "A, the window that was activated, gets the focus");
        compare(hfocus, "a1");
    }

    function test_dispatcherOrderGivesTheFocusToTheActivatedWindow() {
        park();
        sent = [];
        dispatcherActivation("a1");
        advance(300);
        compare(special, false);
        compare(parkedAddresses(), []);
        verify(sent[0].indexOf("toggle_special") >= 0);
        compare(toggles(), 1);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xa1") >= 0);
        compare(hfocus, "a1");
    }

    // recorded from Hyprland: the first window that comes back takes the focus when the focused one is parked, which is an
    // activewindowv2 AFTER the hide that names a record window: it is not the activated one
    function test_theWindowThatComesBackFirstIsNotTheActivatedOneInTheRealOrder() {
        park();
        sent = [];
        realActivation("b2");   // a1 is the first to move back and takes the focus after the hide
        advance(300);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xb2") >= 0, "B, the activated one, and not A, the first back: " + JSON.stringify(focusRequests()));
        compare(hfocus, "b2");
    }

    function test_theWindowThatComesBackFirstIsNotTheActivatedOneInTheDispatcherOrder() {
        park();
        sent = [];
        dispatcherActivation("b2");
        advance(300);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xb2") >= 0, JSON.stringify(focusRequests()));
        compare(hfocus, "b2");
    }

    function test_theWindowAfterTheWorkspaceEventWinsOverAFocusJustBefore() {
        park();
        sent = [];
        post("activewindowv2", "b2");   // a record window had the focus a moment before (not an activation)
        settle();
        dispatcherActivation("a1");
        advance(300);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xa1") >= 0, JSON.stringify(focusRequests()));
    }

    function test_anOutsideWindowNamedBeforeTheActivationIsIgnored() {
        park();
        sent = [];
        post("activewindowv2", "a1");   // a record window...
        post("activewindowv2", "c9");   // ...then a window that is not parked and not ours: the last one named is the one
        settle();
        special = true;
        showEvents();
        advance(300);
        compare(focusRequests().length, 0, "a window that is neither parked nor sent back is never focused, and the older one is not taken instead");
    }

    function test_anOutsideWindowNamedAfterTheWorkspaceEventNeverTakesTheFocus() {
        park();
        sent = [];
        special = true;
        showEvents();
        post("activewindowv2", "c9");   // not in the records (minimized, left alone)
        hfocus = "a1";
        post("activewindowv2", "a1");
        advance(300);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xa1") >= 0, JSON.stringify(focusRequests()));
        // and when only the outside window is named: nothing at all
        park();
        advance(600);
        sent = [];
        special = true;
        showEvents();
        post("activewindowv2", "c9");
        advance(300);
        compare(focusRequests().length, 0);
    }

    function test_aWindowTheUserMovedOutByHandIsNotFocusedByTheActivation() {
        park();
        sent = [];
        wins[0].parked = false;     // the user moved A out of the parking workspace by hand
        wins[0].workspace = 3;
        realActivation("a1");       // an activation names it (it is on screen now)
        advance(300);
        compare(focusRequests().length, 0, "it did not go back with the others: it keeps the focus the app gave it, no request");
    }

    function test_theSecondPressEndsItWithStagesOnToo() {
        park();
        const c = ctx();
        c.stages = true;
        const second = Flow.onPress(st, c);
        compare(second.ended, true, "the second press always ends it");
        compare(second.state.records.length, 0);
        const first = Flow.onPress(Flow.initial(), c);
        compare(first.refresh, false, "with Stages on a first press does nothing");
        compare(first.state.records.length, 0);
    }

    function test_aPressWhileOneIsPendingIsIgnored() {
        const one = Flow.onPress(Flow.initial(), ctx());
        compare(one.refresh, true);
        const two = Flow.onPress(one.state, ctx());
        compare(two.refresh, false, "the window list is already being read");
        compare(two.ended, false);
    }

    function test_theVerifyBoundNeverDuplicatesAWindowOfALiveRecord() {
        park();
        stuck = ({b2: true});
        press();
        advance(100);
        // a live record already lists b2 (and a1) when the verify gives up on b2
        st.records = [{screen: "DP-1", workspace: 1, focus: "", windows: [{address: "a1", x: 0, y: 0}, {address: "b2", x: 960, y: 0}]}];
        wins[0].parked = true;
        advance(5000);
        const all = st.records.reduce((n, r) => n.concat(r.windows.map(w => w.address)), []);
        compare(all.filter(a => a === "b2").length, 1, "once");
        compare(st.records.length, 1, "and no empty or extra record");
    }

    // an ending handled first (its moves still queued), then a real activation: the activated window ends up in front
    function test_anEndingHandledFirstThenARealActivationFocusesTheActivatedWindow() {
        park();
        sent = [];
        post("openwindow", "d4,1,foot,x");
        realActivation("b2");
        advance(300);
        compare(special, false);
        compare(parkedAddresses(), []);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xb2") >= 0, JSON.stringify(focusRequests()));
        compare(hfocus, "b2");
    }

    function test_aSecondActivationRightAfterTheFirstIsHandledToo() {
        park();
        realActivation("a1");
        advance(40);            // well inside any echo window: it is a new activation, not an echo
        park();
        realActivation("b2");
        advance(400);
        compare(special, false, "the second activation is not swallowed");
        compare(parkedAddresses(), []);
        compare(st.records.length, 0);
    }

    function test_aShowOfTheOtherFormIsOnlyTheEchoOfTheOneJustHandled() {
        park();
        sent = [];
        const first = Flow.onEvent(st, ctx(), "activespecial", "special:desktop,DP-1");
        compare(first.dispatches[0], SD.hideParkingRequest());
        const twin = Flow.onEvent(first.state, ctx(), "activespecialv2", "-98,special:desktop,DP-1");
        compare(twin.dispatches.length, 0, "the echo is matched to the event, not to a time");
        compare(twin.state.parking, {}, "and it does not mark the workspace shown");
        // the hide came back: a new show is a new activation, however soon
        let r = Flow.onEvent(twin.state, ctx(), "activespecial", ",DP-1");
        r = Flow.onEvent(r.state, ctx(), "activespecialv2", ",,DP-1");
        const again = Flow.onEvent(r.state, ctx(), "activespecial", "special:desktop,DP-1");
        compare(again.state.activation.open, true, "a new activation");
        compare(again.dispatches[0], SD.hideParkingRequest(), "hidden again, not swallowed");
    }

    function test_twoEndingsBeforeTheHideEventNeverToggleTwice() {
        park();
        const first = Flow.onEvent(st, ctx(), "activespecial", "special:desktop,DP-1");
        compare(first.dispatches.filter(d => d.indexOf("toggle_special") >= 0).length, 1);
        // the records are back (a new Show Desktop), another ending comes before Hyprland's hide event: it must not toggle again
        const again = first.state;
        again.records = [{screen: "DP-1", workspace: 1, focus: "", windows: [{address: "a1", x: 0, y: 0}]}];
        const second = Flow.onEvent(again, ctx(), "openwindow", "d4,1,foot,x");
        compare(second.ended, true);
        compare(second.dispatches.filter(d => d.indexOf("toggle_special") >= 0).length, 0, "the workspace is known hidden: no toggle that would open it");
    }

    function test_aShowOfTheOtherFormAfterAHideIsANewActivation() {
        park();
        // only one form of each event arrives (a Hyprland that posts just the v1 events, then a v2-only show)
        let r = Flow.onEvent(st, ctx(), "activespecial", "special:desktop,DP-1");
        r = Flow.onEvent(r.state, ctx(), "activespecial", ",DP-1");
        r.state.records = [{screen: "DP-1", workspace: 1, focus: "", windows: [{address: "a1", x: 0, y: 0}]}];
        r.state.parking = ({});
        const show = Flow.onEvent(r.state, ctx(), "activespecialv2", "-98,special:desktop,DP-1");
        compare(show.dispatches[0], SD.hideParkingRequest(), "the hide cleared what was waiting for an echo: this is a new show, handled and hidden");
    }

    function test_theFirstWindowNamedAfterTheWorkspaceEventWins() {
        park();
        sent = [];
        special = true;
        showEvents();
        hfocus = "a1";
        post("activewindowv2", "a1");
        post("activewindowv2", "b2");   // a second one before the hide: the first stays
        advance(300);
        verify(focusRequests()[0].indexOf("0xa1") >= 0, JSON.stringify(focusRequests()));
    }

    // ---- a parked window no record owns (a corrupt or unwritable record file) ---------------------------------------------------------

    function test_aParkedWindowWithNoRecordComesBackWhenAnAppActivatesIt() {
        wins[0].parked = true;          // parked by an earlier run whose record was lost
        sent = [];
        realActivation("a1");
        advance(400);
        compare(special, false, "the workspace is hidden again");
        compare(wins[0].parked, false, "and the window is back on a Space");
        compare(wins[0].workspace, 1, "the Space the user is on");
        verify(sent[0].indexOf("toggle_special") >= 0, "hide first");
        const moveAt = sent.findIndex(x => x.indexOf("window.move") >= 0);
        const focusAt = sent.findIndex(x => x.indexOf("hl.dsp.focus") >= 0);
        verify(moveAt > 0 && focusAt > moveAt, "the move comes before the focus request: " + JSON.stringify(sent));
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xa1") >= 0);
        compare(hfocus, "a1", "in front");
    }

    function test_aParkedWindowWithNoRecordComesBackToTheCurrentSpace() {
        wins[0].parked = true;
        shownNow = [{name: "DP-1", workspace: 4}];
        currentWs = 4;
        sent = [];
        dispatcherActivation("a1");
        advance(400);
        compare(special, false);
        compare(wins[0].workspace, 4, "the Space shown now, not the one it came from");
        compare(wins[0].parked, false);
        compare(hfocus, "a1");
    }

    function test_anOrphanComesBackToTheSpaceOfTheFocusedDisplay() {
        twoDisplays();
        wins[0].parked = true;
        currentWs = 2;                  // the focused display shows Space 2
        realActivation("a1");
        advance(400);
        compare(wins[0].workspace, 2, "the Space of the focused display, not the first display's");
        compare(hfocus, "a1");
    }

    function test_anEndingThatMovedTheWindowsBackBeforeTheHideDoesNotMakeTheHideConsequenceTheActivation() {
        park();
        sent = [];
        post("openwindow", "d4,1,foot,x");   // an ending: its moves are applied before Hyprland shows the workspace
        settle();
        plast = "a1";                        // after the hide, Hyprland focuses the regular workspace's last window (a1, back on its Space)
        realActivation("b2");
        advance(300);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xb2") >= 0, "b2 was activated, a1 only took the focus when the workspace hid: " + JSON.stringify(focusRequests()));
    }

    function test_aWindowThatIsStillParkedIsLookedAtAFewTimesThenLeft() {
        park();
        stuck = ({a1: true});
        realActivation("a1");
        settle();
        let cur = st;
        const asked = [];
        for (let i = 0; i < 6; i++) {
            const res = Flow.onTimer(cur, ctx(), "activation");
            asked.push(res.timers.activation === "restart");
            compare(res.dispatches.filter(d => d.indexOf("hl.dsp.focus") >= 0).length, 0, "never a focus request for a window that is parked");
            cur = res.state;
        }
        compare(asked, [true, true, true, false, false, false], "three more looks, then it is left");
    }

    function test_aCorruptRecordFileLeavesNothingUnreachable() {
        wins[0].parked = true;
        wins[1].parked = true;
        // the file is damaged, or from a future version, or empty: nothing is recovered and the windows stay parked
        for (const text of ["{broken", "", "{\"version\": 99, \"records\": []}", "[]"]) {
            const loaded = Flow.onLoaded(st, ctx(), SD.parse(text));
            compare(loaded.state.records.length, 0, "nothing trusted: " + text);
            compare(loaded.timers.recover, undefined);
        }
        // the user activates one of them (the Dock, an app): it comes back and ends up in front
        realActivation("b2");
        advance(400);
        compare(special, false);
        compare(wins[1].parked, false);
        compare(hfocus, "b2");
        // and the other one the same way
        advance(600);
        dispatcherActivation("a1");
        advance(400);
        compare(wins[0].parked, false);
        compare(hfocus, "a1");
        compare(special, false);
    }

    function test_aWindowParkedByHandAfterAnEndingIsAnOrphanNotOneWeSentBack() {
        park();
        press();
        advance(1500);                  // the ending and its verify are long over
        compare(parkedAddresses(), []);
        wins[0].parked = true;          // parked again by something else, no record
        sent = [];
        realActivation("a1");
        advance(400);
        compare(wins[0].parked, false, "it comes back, it is not waited for as a window the flow is still moving");
        compare(hfocus, "a1");
        compare(special, false);
    }

    function test_aRecordFileThatCouldNotBeWrittenIsLostAtTheRestartButNotTheWindows() {
        park();
        // the shell restarts: the flow starts empty, the windows are still parked, no file to read
        st = Flow.initial();
        deadlines = ({});
        compare(parkedAddresses(), ["a1", "b2"]);
        realActivation("a1");
        advance(400);
        compare(wins[0].parked, false);
        compare(hfocus, "a1");
        compare(special, false);
    }

    function test_aWindowThatIsNeitherParkedNorOursIsLeftAlone() {
        sent = [];
        realActivation("c9");           // minimized, on a Space, not parked: an activation of an ordinary window
        advance(400);
        compare(focusRequests().length, 0);
        compare(sent.filter(s => s.indexOf("window.move") >= 0).length, 0);
    }

    function test_theFocusIsNeverAskedForAWindowThatIsStillParked() {
        park();
        stuck = ({a1: true});           // the move back does not happen
        sent = [];
        realActivation("a1");
        advance(2000);
        compare(focusRequests().length, 0, "it would show the parking workspace again");
        compare(special, false);
    }

    // ---- several Spaces ------------------------------------------------------------------------------------------------------------------

    function twoDisplays() {
        wins.push(win("d4", 2, 0));
        shownNow = [{name: "DP-1", workspace: 1}, {name: "DP-2", workspace: 2}];
    }

    function moveTargets(address) {
        return sent.filter(s => s.indexOf("window.move") >= 0 && s.indexOf("address:0x" + address) >= 0 && s.indexOf(SD.PARKING) < 0).map(s => /workspace = "([^"]+)"/.exec(s)[1]);
    }

    function test_everyWindowGoesBackToItsOwnSpace() {
        twoDisplays();
        park();
        compare(st.records.length, 2);
        sent = [];
        press();
        advance(300);
        compare(moveTargets("a1"), ["1"]);
        compare(moveTargets("d4"), ["2"]);
    }

    function test_aSpaceSwitchDoesNotDragTheWindowsAlong() {
        twoDisplays();
        park();
        sent = [];
        shownNow = [{name: "DP-1", workspace: 5}, {name: "DP-2", workspace: 2}];   // the user switched Space on the first display
        const t = Flow.onTimer(st, ctx(), "check");
        compare(t.ended, true);
        t.dispatches.forEach(d => sent.push(d));
        compare(moveTargets("a1"), ["1"], "back to the Space it was on, not the one shown now");
        compare(moveTargets("d4"), ["2"]);
    }

    function test_theVerifyAndTheStragglersUseTheOwnSpaceOfTheWindow() {
        twoDisplays();
        park();
        stuck = ({d4: true});
        press();
        advance(100);
        sent = [];
        shownNow = [{name: "DP-1", workspace: 5}, {name: "DP-2", workspace: 6}];
        advance(2000);
        compare(moveTargets("d4"), ["2", "2", "2"], "each verify try sends it to its own Space");
    }

    function test_theGrassfieldEventBetweenTheFocusAndTheWorkspaceIsNotCounted() {
        park();
        sent = [];
        // recorded: urgent, activewindow, activewindowv2 <X>, grassfield (a plugin event), activespecial
        post("urgent", "a1");
        post("activewindow", "gf-sd-act,gf-sd-act");
        post("activewindowv2", "a1");
        post("grassfield", "{\"v\":\"gfc/1\"}");
        for (let i = 0; i < 5; i++) {
            post("windowtitlev2", "a1,title " + i);   // noise is not counted: only events that move the focus or a workspace
            post("activelayout", "kbd,us");
        }
        special = true;
        showEvents();
        advance(300);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xa1") >= 0);
    }

    function test_theWindowBeforeTheLookbackIsNotTheActivatedOne() {
        park();
        sent = [];
        // a window of the record had the focus, then other things happened: no evidence of an activation
        post("activewindowv2", "a1");
        post("workspacev2", "1,1");
        post("workspacev2", "1,1");
        post("workspacev2", "1,1");
        settle();
        special = true; hfocus = "";
        showEvents();
        advance(300);
        compare(focusRequests().length, 0, "nothing names the activated window, nothing is focused");
        compare(special, false);
    }

    function test_noWindowOutsideTheRecordIsEverFocused() {
        park();
        sent = [];
        plast = "c9";   // the focus after the hide goes to a window that is not in the record (minimized, left alone)
        special = true; hfocus = "";
        showEvents();   // no activewindowv2 names a record window
        advance(300);
        compare(special, false);
        compare(focusRequests().length, 0, "the window the hide gave the focus to is not the activated one");
        // and when the hide's own event is the one that follows the workspace event
        advance(600);
        park();
        sent = [];
        plast = "c9";
        realActivation("a1");
        advance(300);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xa1") >= 0, "A and only A");
    }

    function test_anEndingHandledBeforeTheActivationStillHidesTheWorkspace() {
        park();
        sent = [];
        post("openwindow", "d4,1,foot,x");   // another ending is handled first; its moves are still queued
        realActivation("a1");               // Hyprland activated parked A before it applied them
        advance(300);
        compare(special, false, "hidden by state on this path too");
        compare(toggles(), 1);
        compare(parkedAddresses(), []);
    }

    function test_aSecondEndingAfterTheActivationNeverTogglesTwice() {
        park();
        sent = [];
        realActivation("a1");
        post("openwindow", "d4,1,foot,x");
        advance(300);
        compare(special, false);
        compare(toggles(), 1, "one hide, never a second toggle that would open the workspace");
    }

    function test_theEchoOfOurOwnHideIsNotAnotherActivation() {
        park();
        sent = [];
        realActivation("a1");
        advance(600);
        compare(toggles(), 1);
        compare(special, false);
        compare(st.parking, {}, "the parking workspace is tracked as hidden");
        // a later, unrelated ending must not toggle the hidden workspace (it would open it)
        park();
        press();
        advance(200);
        compare(special, false);
    }

    function test_noActivewindowv2IsBounded() {
        park();
        sent = [];
        special = true;
        showEvents();   // no activewindowv2 at all
        advance(300);
        compare(special, false);
        compare(focusRequests().length, 0);
        compare(st.activation.open, false);
    }

    // ---- the other endings ----------------------------------------------------------------------------------------------------

    function test_aNewWindowEndsItWithoutAnyFocusRequest() {
        park();
        sent = [];
        post("openwindow", "d4,1,foot,x");
        advance(200);
        compare(parkedAddresses(), []);
        compare(focusRequests().length, 0);
        compare(toggles(), 0, "the workspace was never shown: nothing to hide");
    }

    function test_ourOwnMovesDoNotEndIt() {
        park();
        advance(2000);
        compare(parkedAddresses(), ["a1", "b2"]);
        compare(st.records.length, 1);
    }

    function test_theSecondPressRefocusesTheWindowThatHadTheFocus() {
        park();
        sent = [];
        press();
        advance(200);
        compare(parkedAddresses(), []);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xb2") >= 0);
    }

    function test_threeQuickPressesKeepItOn() {
        park();
        advance(450);
        press();              // ends it: the verify of this ending is now running
        advance(250);
        press();              // the third press: the window list is read first
        advance(interval.refresh + 10);
        advance(3000);
        compare(parkedAddresses(), ["a1", "b2"], "the verify of the second ending must not send the third's windows back");
        compare(st.records.length, 1);
        press();
        advance(1000);
        compare(parkedAddresses(), []);
    }

    function test_aClosedWindowLeavesTheRecord() {
        park();
        post("closewindow", "a1");
        settle();
        compare(st.records[0].windows.map(w => w.address), ["b2"]);
        compare(disk.length, 1);
        compare(disk[0].windows.length, 1, "and the file");
        post("closewindow", "b2");
        settle();
        compare(st.records.length, 0, "no window left: Show Desktop is over");
        compare(disk.length, 0);
    }

    function test_aSpaceSwitchEndsItWithoutFocus() {
        park();
        sent = [];
        // the Space of the display changes: the check compares what each display shows
        const c = ctx();
        c.shown = [{name: "DP-1", workspace: 2}];
        const ev = Flow.onEvent(st, c, "workspacev2", "2,2");
        compare(ev.timers.check, "restart", "a workspace event only schedules a look at what each display shows");
        compare(ev.ended, false, "an event alone ends nothing");
        compare(ev.state.records.length, 1);
        const t = Flow.onTimer(st, c, "check");
        compare(t.ended, true);
        compare(t.dispatches.filter(d => d.indexOf("hl.dsp.focus") >= 0).length, 0);
        compare(t.timers.verify, "restart");
    }

    function test_aFocusMoveToAnotherDisplayEndsNothing() {
        park();
        // the same Spaces on both displays: the workspace event the focus move raises is not a Space switch
        const t = Flow.onTimer(st, ctx(), "check");
        compare(t.ended, false);
        compare(t.state.records.length, 1);
        compare(t.dispatches.length, 0);
    }

    function test_aDisplayGoingAwayEndsIt() {
        park();
        const c = ctx();
        c.shown = [];   // the display of the record is gone
        const scr = Flow.onScreensChanged(st, c);
        compare(scr.timers.check, "restart", "the screens changing schedules the look");
        const t = Flow.onTimer(st, c, "check");
        compare(t.ended, true);
        compare(Flow.onScreensChanged(Flow.initial(), c).timers.check, undefined, "nothing to look at when Show Desktop is off");
    }

    // ---- stragglers ---------------------------------------------------------------------------------------------------------------

    function test_aNewCaptureParksTheStragglersOfThePreviousEnding() {
        park();
        stuck = ({b2: true});
        press();            // ends: a1 goes back, b2 stays parked (a window that does not move)
        advance(100);
        compare(parkedAddresses(), ["b2"]);
        sent = [];
        press();            // a new Show Desktop while the verify of the ending runs
        advance(interval.refresh + 10);
        compare(parkedAddresses(), ["a1", "b2"]);
        compare(moveBack("b2"), 0, "the straggler is not moved back (it would be on screen during the new Show Desktop)");
        compare(st.records.length, 2, "it is part of the new records");
        stuck = ({});
        press();
        advance(1000);
        compare(parkedAddresses(), [], "and goes back with the others");
    }

    function test_theVerifyBoundGivesWhatIsStillParkedARecord() {
        park();
        stuck = ({b2: true});
        press();
        advance(5000);
        compare(parkedAddresses(), ["b2"]);
        compare(st.records.length, 1, "kept for the next press, never parked with no record");
        compare(st.records[0].windows.map(w => w.address), ["b2"]);
        compare(disk.length, 1, "and written");
        compare(st.verify.records.length, 0);
        stuck = ({});
        press();
        advance(1000);
        compare(parkedAddresses(), []);
    }

    function test_theVerifyBoundNeverReplacesARecordThatIsOn() {
        park();
        stuck = ({b2: true});
        press();
        advance(100);
        // a new capture is on (a1 parked) when the verify's bound arrives: both must be kept
        st.records = [{screen: "DP-1", workspace: 1, focus: "", windows: [{address: "a1", x: 0, y: 0}]}];
        wins[0].parked = true;
        advance(5000);
        compare(st.records.length, 2);
        compare(st.records.map(r => r.windows.map(w => w.address).join()).sort(), ["a1", "b2"]);
    }

    function test_theVerifyIsBounded() {
        park();
        stuck = ({b2: true});
        press();
        sent = [];
        advance(10000);
        compare(sent.filter(s => s.indexOf("window.move") >= 0 && s.indexOf("address:0xb2") >= 0).length, 3, "three tries, then it stops");
    }

    // ---- crash recovery -------------------------------------------------------------------------------------------------------------

    readonly property var diskRecord: ({screen: "DP-1", workspace: 1, focus: "", windows: [{address: "a1", x: 0, y: 0}, {address: "b2", x: 960, y: 0}]})

    function start(records) {
        wins[0].parked = true;
        wins[1].parked = true;
        disk = JSON.parse(JSON.stringify(records));
        run(Flow.onLoaded(st, ctx(), records));
    }

    function test_theRecoverySendsEveryWindowBackAndRemovesTheRecord() {
        start([diskRecord]);
        compare(st.records.length, 1);
        advance(interval.recover * 2 + 10);
        compare(parkedAddresses(), []);
        compare(st.records.length, 0);
        compare(disk.length, 0, "the file is emptied");
        compare(focusRequests().length, 0, "nothing is focused by the recovery");
        compare(toggles(), 0);
    }

    function test_theRecoverySendsEachWindowToTheSpaceOfItsRecord() {
        currentWs = 3;                  // the user is elsewhere when the shell starts
        shownNow = [{name: "DP-1", workspace: 3}];
        start([diskRecord]);
        advance(interval.recover * 2 + 10);
        compare(wins[0].workspace, 1, "its own Space, not the one shown now");
        compare(wins[1].workspace, 1);
        compare(parkedAddresses(), []);
    }

    function test_theRecoveryWaitsForTheWindowList() {
        loadedList = false;
        start([diskRecord]);
        advance(interval.recover * 3 + 100);
        compare(sent.length, 0, "nothing is decided before the window list has loaded");
        compare(st.records.length, 1);
        loadedList = true;
        advance(interval.recover * 2 + 100);
        compare(parkedAddresses(), []);
        compare(st.records.length, 0);
    }

    function test_theRecoveryRetriesAWindowThatDoesNotComeBack() {
        stuck = ({b2: true});
        start([diskRecord]);
        advance(interval.recover * 3 + 100);
        compare(parkedAddresses(), ["b2"]);
        compare(st.records.length, 1, "the record stays while a window is parked");
        stuck = ({});
        advance(interval.recover * 2 + 100);
        compare(parkedAddresses(), []);
        compare(st.records.length, 0);
    }

    function test_theRecoveryIsBoundedAndTheRecordStaysAtTheBound() {
        stuck = ({a1: true, b2: true});
        start([diskRecord]);
        advance(interval.recover * 30);
        compare(st.records.length, 1, "never cleared while a window is still parked");
        compare(diskClears, 0, "the file is not emptied either");
        compare(disk.length, 1);
        compare(deadlines.recover === undefined, true, "no retry left: bounded");
        compare(sent.filter(s => s.indexOf("address:0xa1") >= 0).length, 10, "one try per step, at most the token's");
        // the next press sends them back
        stuck = ({});
        press();
        advance(500);
        compare(parkedAddresses(), []);
    }

    function test_aListThatNeverLoadsEndsAtTheBoundWithoutARecord() {
        loadedList = false;
        start([diskRecord]);
        advance(interval.recover * 30);
        compare(st.records.length, 0);
        compare(sent.length, 0);
    }

    function test_aWindowMovedByHandStaysWhereTheUserPutIt() {
        start([diskRecord]);
        wins[1].parked = false;
        wins[1].workspace = 3;
        advance(interval.recover + 10);
        compare(wins[1].workspace, 3);
        compare(wins[0].parked, false);
    }
}
