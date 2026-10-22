import QtQuick
import QtTest
import "../../shell/dock/Attention.js" as Attention

// Pure state of the Dock's attention requests (macOS: an app that needs attention bounces its icon until it is activated).
TestCase {
    name: "DockAttention"

    readonly property var groups: [{key: "foot", addresses: ["a1", "a2"]}, {key: "chromium", addresses: ["b1"]}]

    function test_requestMarksTheWindowAndItsTile() {
        const s = Attention.request({}, "a2", "b1");
        verify(s.a2 === true);
        compare(Attention.tileKeys(s, groups).join(","), "foot");
    }

    function test_focusedWindowNeverBounces() {
        const s = Attention.request({}, "a1", "a1");
        compare(Object.keys(s).length, 0);
        compare(Attention.tileKeys(s, groups).length, 0);
    }

    function test_invalidAddressIsIgnored() {
        compare(Object.keys(Attention.request({}, "", "b1")).length, 0);
        compare(Object.keys(Attention.request({}, undefined, "b1")).length, 0);
    }

    function test_requestDoesNotMutate() {
        const before = {};
        Attention.request(before, "a1", "");
        compare(Object.keys(before).length, 0);
    }

    function test_activatingTheAppStopsItsBounce() {
        let s = Attention.request({}, "a2", "b1");
        s = Attention.request(s, "b1", "a1");
        compare(Attention.tileKeys(s, groups).join(","), "foot,chromium");
        // Any window of the app being focused is the app being activated, not only the urgent one.
        s = Attention.settle(s, groups, "a1", ["a1", "a2", "b1"]);
        compare(Attention.tileKeys(s, groups).join(","), "chromium");
        verify(s.a2 === undefined);
    }

    function test_focusingAnotherAppKeepsTheBounce() {
        let s = Attention.request({}, "a2", "");
        s = Attention.settle(s, groups, "b1", ["a1", "a2", "b1"]);
        compare(Attention.tileKeys(s, groups).join(","), "foot");
    }

    function test_closedWindowsLeave() {
        let s = Attention.request({}, "a2", "");
        s = Attention.settle(s, groups, "", ["a1", "b1"]);
        compare(Attention.tileKeys(s, groups).length, 0);
        compare(Object.keys(s).length, 0);
    }

    function test_noFocusKeepsEverything() {
        let s = Attention.request({}, "a2", "");
        s = Attention.settle(s, groups, "", ["a1", "a2", "b1"]);
        compare(Attention.tileKeys(s, groups).join(","), "foot");
    }

    function test_addressesAreComparedNormalised() {
        compare(Attention.normalize("0xABC123"), "abc123");
        compare(Attention.normalize("abc123"), "abc123");
        compare(Attention.normalize("not hex"), "");
        const s = Attention.request({}, "0xA1", "");
        verify(s.a1 === true);
    }
}
