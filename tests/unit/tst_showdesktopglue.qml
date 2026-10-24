import QtQuick
import QtTest
import "../../shell/platform/ShowDesktop.js" as SD

// The glue between Hyprland and the Show Desktop flow: the REAL shell/platform/showdesktop/ShowDesktopController.qml (the object the Compositor
// singleton holds, which listens to the events, reads the context, runs the dispatches, the record file and the timers) loaded
// offscreen with a fake event source and a fake dispatcher, in front of a small model of Hyprland. The rules are tested in
// tst_showdesktopflow.qml; this file kills what only the glue can get wrong: an event that is not forwarded, dispatches in
// the wrong order, a context that does not name the focused window, the record file not written, a window list built for every
// event, a timer that is not started.
TestCase {
    name: "ShowDesktopGlue"
    when: windowShown

    QtObject {
        id: hypr
        signal rawEvent(var event)
    }

    property var ctl: null
    property var wins: []
    property var queue: []
    property var sent: []
    property var written: []
    property int windowReads: 0
    property int desktopFocus: 0
    property bool special: false
    property string hfocus: ""
    property string focusedNow: ""
    property bool stagesOn: false
    property var shownNow: [{name: "DP-1", workspace: 1}]
    property var stuckSet: ({})
    property int refreshCalls: 0

    function win(address, workspace, x) {
        return {address: address, workspace: workspace, parked: false, x: x, y: 0, minimized: false, hidden: false};
    }

    function init() {
        wins = [win("a1", 1, 0), win("b2", 1, 960)];
        queue = [];
        sent = [];
        written = [];
        windowReads = 0;
        desktopFocus = 0;
        special = false;
        hfocus = "b2";
        focusedNow = "b2";
        stagesOn = false;
        shownNow = [{name: "DP-1", workspace: 1}];
        stuckSet = ({});
        refreshCalls = 0;
        const comp = Qt.createComponent(Qt.resolvedUrl("../../shell/platform/showdesktop/ShowDesktopController.qml"));
        if (comp.status !== 1)
            fail("the controller does not load: " + comp.errorString());
        ctl = comp.createObject(testCase, {
            eventSource: hypr,
            readWindows: () => {
                windowReads++;
                return wins.map(w => ({address: w.address, workspace: w.parked ? -98 : w.workspace, parked: w.parked, x: w.x, y: w.y, minimized: false, hidden: false}));
            },
            readShown: () => shownNow,
            readFocused: () => focusedNow,
            readCurrentWorkspace: () => 1,
            dispatch: request => { sent.push(request); queue.push(request); },
            refreshWindows: () => refreshCalls++,
            checkMs: 10,
            verifyMs: 30,
            refreshMs: 10,
            recoverMs: 20,
            recoverTries: 4
        });
        ctl.persistRequested.connect(text => written.push(text));
        ctl.focusDesktopRequested.connect(() => desktopFocus++);
    }

    function cleanup() {
        if (ctl)
            ctl.destroy();
        ctl = null;
    }

    id: testCase

    function emit(name, data) { hypr.rawEvent({name: name, data: data}); }
    function showEvents() { special = true; emit("activespecial", "special:desktop,DP-1"); emit("activespecialv2", "-98,special:desktop,DP-1"); }

    // Hyprland applying what the shell dispatched, posting its events
    function pump() {
        for (let i = 0; i < 20 && queue.length > 0; i++) {
            const q = queue;
            queue = [];
            for (const req of q) {
                if (req === SD.hideParkingRequest()) {
                    special = !special;
                    emit("activespecial", special ? "special:desktop,DP-1" : ",DP-1");
                    emit("activespecialv2", special ? "-98,special:desktop,DP-1" : ",,DP-1");
                    continue;
                }
                let m = /workspace = "([^"]+)".*address:0x([0-9a-f]+)/.exec(req);
                if (m) {
                    const w = wins.find(x => x.address === m[2]);
                    if (w) {
                        if (m[1] === SD.PARKING) {
                            w.parked = true;
                        } else if (!stuckSet[w.address]) {
                            w.parked = false;
                            w.workspace = parseInt(m[1]);
                        }
                        emit("movewindowv2", w.address + "," + (w.parked ? -98 : w.workspace) + "," + m[1]);
                    }
                    continue;
                }
                m = /focus\(\{ window = "address:0x([0-9a-f]+)"/.exec(req);
                if (m) {
                    hfocus = m[1];
                    emit("activewindowv2", m[1]);
                }
            }
        }
    }

    // lets the timers of the controller fire (they are a few milliseconds here) and the model answer
    function settle(ms) {
        const end = Date.now() + ms;
        while (Date.now() < end) {
            wait(5);
            pump();
        }
    }

    function park() { ctl.press(); settle(60); }
    function parked() { return wins.filter(w => w.parked).map(w => w.address).sort(); }
    function toggles() { return sent.filter(s => s.indexOf("toggle_special") >= 0).length; }
    function focusRequests() { return sent.filter(s => s.indexOf("hl.dsp.focus") >= 0); }

    function test_aPressParksTheWindowsAndHandsTheKeyboardToTheDesktop() {
        park();
        compare(parked(), ["a1", "b2"]);
        compare(ctl.records.length, 1);
        compare(desktopFocus, 1, "the icons get the keyboard");
        verify(written.length >= 1 && written[written.length - 1].indexOf("\"a1\"") >= 0, "the record file is written: " + JSON.stringify(written));
    }

    function test_theSecondPressRefocusesTheWindowTheShellNamedAsFocused() {
        focusedNow = "b2";
        park();
        sent = [];
        ctl.press();
        settle(60);
        compare(parked(), []);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xb2") >= 0, "the context names the focused window: " + JSON.stringify(focusRequests()));
    }

    function test_theFirstPressReadsTheWindowListAgainAndTheSecondDoesNot() {
        ctl.press();
        compare(refreshCalls, 1, "the window list is read again before the positions are recorded");
        settle(60);
        ctl.press();
        compare(refreshCalls, 1, "the second press ends it at once");
    }

    function test_aNewPressStopsTheVerifyOfTheEndingBeforeIt() {
        park();
        ctl.press();            // ends it: the verify of this ending is running
        pump();
        ctl.press();            // a new Show Desktop right behind it
        settle(250);
        compare(parked(), ["a1", "b2"], "the verify of the earlier ending must not send the new windows back");
        compare(ctl.records.length, 1);
    }

    function test_theHideIsTheFirstDispatchOfAnActivationEnding() {
        park();
        sent = [];
        emit("activewindowv2", "a1");
        showEvents();
        settle(120);
        verify(sent.length > 1);
        compare(sent[0], SD.hideParkingRequest(), "hide first, in the order the flow returned");
        compare(toggles(), 1);
        compare(special, false);
        compare(parked(), []);
        compare(focusRequests().length, 1);
        verify(focusRequests()[0].indexOf("0xa1") >= 0, "the activewindowv2 event reached the flow: " + JSON.stringify(focusRequests()));
    }

    function test_theMovesAreDispatchedInTheFlowsOrder() {
        park();
        sent = [];
        ctl.press();
        const moves = sent.filter(s => s.indexOf("window.move") >= 0);
        compare(moves.length, 2);
        verify(moves[0].indexOf("address:0xa1") >= 0, "top to bottom, left to right: a1 (x 0) before b2 (x 960)");
        verify(sent[sent.length - 1].indexOf("hl.dsp.focus") >= 0, "the focus request comes last");
    }

    function test_aClosedWindowReachesTheFlowAndTheRecordFile() {
        park();
        written = [];
        emit("closewindow", "a1");
        compare(ctl.records[0].windows.length, 1);
        verify(written.length === 1 && written[0].indexOf("\"a1\"") < 0 && written[0].indexOf("\"b2\"") >= 0, JSON.stringify(written));
    }

    function test_aNewWindowEndsItThroughTheEventSource() {
        park();
        emit("openwindow", "c3,1,foot,x");
        pump();
        compare(ctl.records.length, 0);
        compare(parked().length, 0);
    }

    function test_theWindowListIsOnlyBuiltWhenTheFlowNeedsIt() {
        for (let i = 0; i < 20; i++) {
            emit("windowtitlev2", "a1,title " + i);
            emit("activelayout", "kbd,us");
            emit("configreloaded", "");
        }
        compare(windowReads, 0, "Show Desktop is off: no event builds the window list");
        park();
        const afterPark = windowReads;
        emit("workspacev2", "1,1");
        verify(windowReads > afterPark, "with Show Desktop on it is built");
    }

    function test_aStagesFirstPressDoesNothingButTheSecondPressStillEnds() {
        stagesOn = true;
        ctl.stages = true;
        ctl.press();
        settle(60);
        compare(parked(), []);
        compare(ctl.records.length, 0);
        ctl.stages = false;
        park();
        ctl.stages = true;
        ctl.press();
        settle(60);
        compare(parked(), [], "the second press ends it with Stages on too");
    }

    function test_aDisplayGoingAwayEndsItThroughTheCheckTimer() {
        park();
        shownNow = [];
        ctl.screensChanged();
        settle(80);
        compare(ctl.records.length, 0);
        compare(parked(), []);
    }

    function test_aSpaceSwitchEndsItThroughTheCheckTimer() {
        park();
        shownNow = [{name: "DP-1", workspace: 3}];
        emit("workspacev2", "3,3");
        settle(80);
        compare(ctl.records.length, 0);
        compare(parked(), []);
    }

    function test_aShellActivationEndsItFirst() {
        park();
        sent = [];
        compare(ctl.endForActivation(), true);
        settle(60);
        compare(parked(), []);
        compare(ctl.endForActivation(), false, "nothing to end the second time");
    }

    function test_theRecordOfAnEarlierRunIsRecoveredAtStart() {
        wins[0].parked = true;
        wins[1].parked = true;
        ctl.recordsLoaded(JSON.stringify({version: 1, records: [{screen: "DP-1", workspace: 1, focus: "", windows: [{address: "a1", x: 0, y: 0}, {address: "b2", x: 960, y: 0}]}]}));
        settle(200);
        compare(parked(), [], "the recover timer ran");
        compare(ctl.records.length, 0);
        compare(focusRequests().length, 0, "no focus request");
    }

    function test_aCorruptRecordFileIsIgnored() {
        wins[0].parked = true;
        ctl.recordsLoaded("{not json");
        settle(100);
        compare(ctl.records.length, 0);
        compare(parked(), ["a1"], "nothing to recover from: it stays until the user activates it");
        emit("activewindowv2", "a1");
        showEvents();
        settle(150);
        compare(parked(), [], "and then it comes back");
        compare(special, false);
        compare(hfocus, "a1");
    }

    function test_theRecoveryWaitsUntilTheWindowListHasLoaded() {
        wins[0].parked = true;
        let loaded = false;
        ctl.readLoaded = () => loaded;
        ctl.recoverTries = 100;
        ctl.recordsLoaded(JSON.stringify({version: 1, records: [{screen: "DP-1", workspace: 1, focus: "", windows: [{address: "a1", x: 0, y: 0}]}]}));
        settle(100);
        compare(sent.length, 0, "nothing is decided before the list has loaded");
        compare(ctl.records.length, 1);
        loaded = true;
        settle(150);
        compare(parked(), []);
        compare(ctl.records.length, 0);
    }

    function test_aFocusFromBeforeIsNotTheActivatedWindow() {
        park();
        sent = [];
        emit("activewindowv2", "a1");
        emit("workspacev2", "1,1");
        emit("workspacev2", "1,1");
        emit("workspacev2", "1,1");
        showEvents();
        settle(150);
        compare(focusRequests().length, 0, "too many events since: no evidence of an activation");
        compare(special, false);
    }

    function test_theRecoveryIsBoundedByTheControllersStep() {
        wins[0].parked = true;
        stuckSet = ({a1: true});
        ctl.recordsLoaded(JSON.stringify({version: 1, records: [{screen: "DP-1", workspace: 1, focus: "", windows: [{address: "a1", x: 0, y: 0}]}]}));
        settle(400);
        compare(sent.filter(s => s.indexOf("window.move") >= 0).length, 4, "one try per step, at most recoverTries");
        compare(ctl.records.length, 1, "the record stays at the bound");
    }

    function test_theLookAtAStillParkedWindowIsBounded() {
        park();
        stuckSet = ({a1: true});
        emit("activewindowv2", "a1");
        showEvents();
        settle(46);                     // the controller looked three times (10 ms apart), a1 did not move: it gave up
        stuckSet = ({});
        sent = [];
        settle(120);                    // the verify (60 ms) brings a1 back now; nobody may ask for its focus any more
        compare(parked(), []);
        compare(focusRequests().length, 0, "a window the controller gave up on is not focused later");
    }

    function test_theVerifyIsBoundedByTheControllersStep() {
        park();
        stuckSet = ({a1: true});
        sent = [];
        ctl.press();
        settle(400);
        compare(sent.filter(s => s.indexOf("window.move") >= 0 && s.indexOf("address:0xa1") >= 0).length, 4, "the ending's move and three tries, no more");
    }

    function test_anOrphanActivatedInTheDispatcherOrderComesBack() {
        wins[0].parked = true;          // parked with no record
        emit("activespecial", "special:desktop,DP-1");   // the workspace first
        special = true;
        emit("activespecialv2", "-98,special:desktop,DP-1");
        hfocus = "a1";
        emit("activewindowv2", "a1");   // then the window: the flow needs the window list for it, with no record on
        settle(150);
        compare(parked(), [], "the orphan is back");
        compare(special, false);
        compare(hfocus, "a1");
    }

    function test_theVerifyTimerBringsBackAWindowThatDidNotMove() {
        park();
        sent = [];
        ctl.press();
        wins[1].parked = true;           // b2 did not leave the parking workspace
        pump();
        wins[1].parked = true;
        settle(120);
        verify(sent.filter(s => s.indexOf("address:0xb2") >= 0 && s.indexOf("window.move") >= 0).length >= 2, "the verify timer ran: " + JSON.stringify(sent));
    }
}
