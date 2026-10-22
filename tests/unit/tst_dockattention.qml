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

    // ADR-0018: an app sets or clears urgent itself (LauncherEntry): the same state, for every window of its tile.
    function test_appUrgentBouncesItsTile() {
        const s = Attention.requestApp({}, groups, "FOOT", "b1");
        compare(Attention.tileKeys(s, groups).join(","), "foot");
        verify(s.a1 === true && s.a2 === true);
        compare(Attention.tileKeys(Attention.requestApp({}, groups, "nobody", ""), groups).length, 0);
    }

    function test_appUrgentSkipsTheFocusedWindow() {
        const s = Attention.requestApp({}, groups, "foot", "a1");
        verify(s.a1 === undefined);
        verify(s.a2 === true);
        compare(Object.keys(Attention.requestApp({}, groups, "chromium", "b1")).length, 0);
    }

    function test_appUrgentFalseClearsOnlyThatApp() {
        let s = Attention.requestApp({}, groups, "foot", "");
        s = Attention.requestApp(s, groups, "chromium", "");
        const cleared = Attention.clearApp(s, groups, "foot");
        compare(Attention.tileKeys(cleared, groups).join(","), "chromium");
        verify(cleared !== s);
        verify(s.a1 === true, "the argument is not changed");
        verify(Attention.clearApp(cleared, groups, "foot") === cleared, "nothing to clear: the same state");
    }

    function test_appUrgentIsSatisfiedByActivation() {
        let s = Attention.requestApp({}, groups, "foot", "b1");
        s = Attention.settle(s, groups, "a2", ["a1", "a2", "b1"]);
        compare(Attention.tileKeys(s, groups).length, 0);
    }

    function test_addressesAreComparedNormalised() {
        compare(Attention.normalize("0xABC123"), "abc123");
        compare(Attention.normalize("abc123"), "abc123");
        compare(Attention.normalize("not hex"), "");
        const s = Attention.request({}, "0xA1", "");
        verify(s.a1 === true);
    }
}
