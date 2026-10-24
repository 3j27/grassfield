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

    function test_survivorsSkipWindowsThatClosedOrMoved() {
        const r = SD.capture(all, "DP-1", 1, "", false);
        compare(SD.survivors(r, ["b2"]), ["b2"]);
        compare(SD.survivors(r, []), []);
        compare(SD.survivors(r, undefined), []);
    }

    function test_onlySpaceSwitchesAndNewWindowsEndIt() {
        verify(SD.endsOn("workspace"));
        verify(SD.endsOn("workspacev2"));
        verify(SD.endsOn("openwindow"));
        verify(!SD.endsOn("movewindow"));
        verify(!SD.endsOn("activewindow"));
        verify(!SD.endsOn("configreloaded"));
    }

    function test_persistenceRoundTripAndDamage() {
        const r = SD.capture(all, "DP-1", 1, "0xa1", false);
        compare(SD.parse(SD.serialize(r)), r);
        compare(SD.serialize(null), "");
        compare(SD.parse(""), null);
        compare(SD.parse("not json"), null);
        compare(SD.parse("{\"version\":9,\"record\":{}}"), null);
        compare(SD.parse("{\"version\":1,\"record\":{\"workspace\":1,\"windows\":[{\"address\":\"zz\"}]}}"), null);
        compare(SD.parse("{\"version\":1,\"record\":{\"workspace\":\"special:x\",\"windows\":[{\"address\":\"0xa1\"}]}}"), null);
        const hostile = SD.parse("{\"version\":1,\"record\":{\"workspace\":2,\"focus\":\"0xa1); os.execute(1\",\"windows\":[{\"address\":\"0xa1\",\"x\":\"q\"},{\"address\":\"0xa1); x\"}]}}");
        compare(hostile.windows.length, 1);
        compare(hostile.focus, "");
        compare(hostile.windows[0].x, 0);
    }
}
