import QtQuick
import QtTest
import "../../shell/platform/ShowDesktop.js" as SD

// Show Desktop record logic (GF-106, review of the shell UX batch): per Space, same Space and order back, persisted.
TestCase {
    name: "ShowDesktop"

    function win(address, workspace, x, y, extra) {
        return Object.assign({address: address, workspace: workspace, x: x, y: y, minimized: false, hidden: false}, extra || {});
    }

    readonly property var all: [win("0xa1", 1, 0, 0), win("0xb2", 1, 960, 0), win("0xc3", 2, 0, 0), win("0xd4", 1, 0, 500, {minimized: true}), win("0xe5", 1, 5, 5, {hidden: true})]

    function test_capturesOnlyTheWindowsOfThatSpace() {
        const r = SD.capture(all, "DP-1", 1, "0xb2", false);
        compare(r.workspace, 1);
        compare(r.screen, "DP-1");
        compare(r.windows.map(w => w.address), ["a1", "b2"]);
        compare(r.focus, "b2");
    }

    function test_twoSpacesKeepTheirOwnRecords() {
        // The reported bug: Space 1 hidden, Space 2 shown later must never take the windows of Space 1.
        const one = SD.capture(all, "DP-1", 1, "", false);
        const two = SD.capture(all, "DP-1", 2, "0xc3", false);
        compare(one.windows.length, 2);
        compare(two.windows.map(w => w.address), ["c3"]);
        compare(SD.survivors(one, ["a1", "b2", "c3"]), ["a1", "b2"]);
    }

    function test_nothingToHideStopsThere() {
        compare(SD.capture(all, "DP-1", 3, "", false), null);
        compare(SD.capture([win("0xd4", 1, 0, 0, {minimized: true})], "DP-1", 1, "", false), null);
        compare(SD.capture(all, "DP-1", "special:hidden", "", false), null);
        compare(SD.capture("x", "DP-1", 1, "", false), null);
    }

    function test_stagesOnIsANoOp() {
        compare(SD.capture(all, "DP-1", 1, "", true), null);
    }

    function test_focusOutsideTheRecordIsDropped() {
        compare(SD.capture(all, "DP-1", 1, "0xc3", false).focus, "");
    }

    function test_restoreOrderIsTopToBottomLeftToRight() {
        const r = SD.capture([win("0x1", 1, 960, 0), win("0x2", 1, 0, 540), win("0x3", 1, 0, 0)], "DP-1", 1, "", false);
        compare(SD.restoreOrder(r), ["3", "1", "2"]);
        compare(SD.restoreOrder(null), []);
    }

    function parkedWin(address, x, y) {
        return {address: address, workspace: -98, x: x, y: y, parked: true};
    }

    function test_toRestoreSendsBackTheParkedOnesInOrder() {
        const r = SD.capture(all, "DP-1", 1, "", false);
        compare(SD.toRestore(r, [parkedWin("0xa1", 0, 0), parkedWin("0xb2", 0, 0)]), ["a1", "b2"]);
        // closed: skipped; already home: not moved; no windows at all: nothing
        compare(SD.toRestore(r, [parkedWin("0xa1", 0, 0)]), ["a1"]);
        compare(SD.toRestore(r, [win("0xa1", 1, 0, 0), win("0xb2", 1, 0, 0)]), []);
        compare(SD.toRestore(r, []), []);
        compare(SD.toRestore(r, undefined), []);
        compare(SD.toRestore(null, [parkedWin("0xa1", 0, 0)]), []);
        verify(SD.sameAddress("0xA1", "a1"));
        verify(!SD.sameAddress("", ""));
    }

    // One rule everywhere: a window the user moved by hand out of the parking workspace stays where the user put it.
    function test_aWindowMovedByHandStaysWhereItIs() {
        const r = SD.capture([win("0xa1", 1, 0, 0), win("0xb2", 1, 9, 0)], "DP-1", 1, "", false);
        compare(SD.toRestore(r, [parkedWin("0xa1", 0, 0), win("0xb2", 5, 0, 0)]), ["a1"]);
        compare(SD.survivors(r, ["a1"]), ["a1"], "the verify applies the same rule");
    }

    function test_theFileNeverHoldsAWindowTwice() {
        const recs = SD.parse("{\"version\":1,\"records\":[{\"screen\":\"DP-1\",\"workspace\":1,\"focus\":\"\",\"windows\":[{\"address\":\"a1\"},{\"address\":\"0xA1\"},{\"address\":\"a1\"}]}]}");
        compare(recs[0].windows.length, 1);
    }

    // An app activating a parked window: not decided by the event alone, by who has the focus a moment later.
    function test_activationOfAParkedWindow() {
        for (const e of ["activewindowv2", "activewindow", "urgent", "activespecial", "activespecialv2"])
            verify(SD.checksActivation(e), e);
        for (const e of ["openwindow", "workspace", "movewindow", "configreloaded"])
            verify(!SD.checksActivation(e), e);
        const windows = [parkedWin("0xa1", 0, 0), win("0xc3", 2, 0, 0)];
        verify(SD.parkedHasFocus(windows, "0xa1"), "the focus reached a parked window");
        verify(SD.parkedHasFocus(windows, "A1"));
        verify(!SD.parkedHasFocus(windows, "0xc3"), "a visible window has it");
        verify(!SD.parkedHasFocus(windows, ""), "nothing has it (the state right after parking)");
        verify(!SD.parkedHasFocus(undefined, "0xa1"));
    }

    function test_survivorsSkipWindowsThatClosedOrMoved() {
        const r = SD.capture(all, "DP-1", 1, "", false);
        compare(SD.survivors(r, ["b2"]), ["b2"]);
        compare(SD.survivors(r, []), []);
        compare(SD.survivors(r, undefined), []);
    }

    readonly property var shown: [{name: "DP-1", workspace: 1}, {name: "DP-2", workspace: 4}]

    function test_everyDisplayIsClearedAtOnce() {
        const wins = [win("0xa1", 1, 0, 0), win("0xb2", 1, 9, 9), win("0xe5", 4, 0, 0), win("0xf6", 7, 0, 0)];
        const records = SD.captureAll(wins, shown, "0xe5", false);
        compare(records.length, 2);
        compare(records[0].screen, "DP-1");
        compare(records[0].windows.map(w => w.address), ["a1", "b2"]);
        compare(records[0].focus, "");
        compare(records[1].screen, "DP-2");
        compare(records[1].focus, "e5");
        compare(SD.captureAll(wins, shown, "", true), []);
        compare(SD.captureAll(wins, [{name: "DP-3", workspace: 9}], "", false), []);
        compare(SD.captureAll(wins, "x", "", false), []);
    }

    function test_aNewWindowEndsItButOurOwnParkedOnesDoNot() {
        const records = SD.captureAll(all, [{name: "DP-1", workspace: 1}], "", false);
        verify(SD.endsOn("openwindow", "c9,2,foot,foot", records));
        verify(!SD.endsOn("openwindow", "0xa1,1,foot,foot", records), "a window the record parked");
        verify(!SD.endsOn("openwindow", "c9,special:desktop,foot,foot", records));
        verify(!SD.endsOn("movewindow", "a1,special:desktop", records));
        verify(!SD.endsOn("activewindow", "foot,foot", records));
        verify(!SD.endsOn("workspace", "2", records), "a Space event only schedules a look");
        verify(!SD.endsOn("focusedmon", "DP-2,4", records));
    }

    function test_theseEventsTriggerALookAtTheSpaces() {
        for (const e of ["workspace", "workspacev2", "focusedmon", "focusedmonv2", "moveworkspace", "monitorremoved"])
            verify(SD.checksSpaces(e), e);
        for (const e of ["openwindow", "movewindow", "activewindow", "configreloaded"])
            verify(!SD.checksSpaces(e), e);
    }

    function test_twoDisplays() {
        const wins = [win("0xa1", 1, 0, 0), win("0xe5", 4, 0, 0)];
        const records = SD.captureAll(wins, [{name: "DP-1", workspace: 1}, {name: "DP-2", workspace: 4}], "0xe5", false);
        // The focus or the pointer moving to the other display: each display still shows its own Space.
        verify(!SD.spaceChanged(records, [{name: "DP-1", workspace: 1}, {name: "DP-2", workspace: 4}]));
        // A Space switch on either display ends it.
        verify(SD.spaceChanged(records, [{name: "DP-1", workspace: 2}, {name: "DP-2", workspace: 4}]));
        verify(SD.spaceChanged(records, [{name: "DP-1", workspace: 1}, {name: "DP-2", workspace: 5}]));
        // A display that went away ends it too.
        verify(SD.spaceChanged(records, [{name: "DP-1", workspace: 1}]));
        // A record without a display name is not compared; nothing to compare is no change.
        verify(!SD.spaceChanged([{screen: "", workspace: 1, focus: "", windows: []}], []));
        verify(!SD.spaceChanged([], [{name: "DP-1", workspace: 3}]));
        verify(!SD.spaceChanged(null, undefined));
    }

    function test_onlyThePressOnTheSameSpaceAsksForFocus() {
        const records = SD.captureAll(all, [{name: "DP-1", workspace: 1}, {name: "DP-2", workspace: 2}], "0xb2", false);
        compare(SD.focusTarget(records, [{name: "DP-1", workspace: 1}, {name: "DP-2", workspace: 2}]), "b2");
        compare(SD.focusTarget(records, [{name: "DP-1", workspace: 3}, {name: "DP-2", workspace: 2}]), "");
        compare(SD.focusTarget(records, []), "");
        compare(SD.focusTarget([], [{name: "DP-1", workspace: 1}]), "");
        compare(SD.focusTarget(SD.captureAll(all, [{name: "DP-1", workspace: 1}], "", false), [{name: "DP-1", workspace: 1}]), "");
    }

    function test_persistenceRoundTripAndDamage() {
        const records = SD.captureAll(all, [{name: "DP-1", workspace: 1}, {name: "DP-2", workspace: 2}], "0xa1", false);
        compare(SD.parse(SD.serialize(records)), records);
        compare(SD.serialize([]), "");
        compare(SD.parse(""), []);
        compare(SD.parse("not json"), []);
        compare(SD.parse("{\"version\":9,\"records\":[]}"), []);
        compare(SD.parse("{\"version\":1,\"records\":[{\"workspace\":1,\"windows\":[{\"address\":\"zz\"}]}]}"), []);
        compare(SD.parse("{\"version\":1,\"records\":[{\"workspace\":\"special:x\",\"windows\":[{\"address\":\"0xa1\"}]}]}"), []);
        // The first format (one record) still reads.
        compare(SD.parse("{\"version\":1,\"record\":{\"screen\":\"DP-1\",\"workspace\":2,\"focus\":\"\",\"windows\":[{\"address\":\"0xa1\",\"x\":0,\"y\":0}]}}").length, 1);
        const hostile = SD.parse("{\"version\":1,\"records\":[{\"workspace\":2,\"focus\":\"0xa1); os.execute(1\",\"windows\":[{\"address\":\"0xa1\",\"x\":\"q\"},{\"address\":\"0xa1); x\"}]}]}")[0];
        compare(hostile.windows.length, 1);
        compare(hostile.focus, "");
        compare(hostile.windows[0].x, 0);
    }
}
