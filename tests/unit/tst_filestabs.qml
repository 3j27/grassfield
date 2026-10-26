import QtQuick
import QtTest
import "../../apps/files/qml/TabsLogic.js" as TabsLogic

// grassfield-files tab logic (apps/files/qml/TabsLogic.js, docs/specs/files.md "Tabs and windows"): when the tab bar
// shows, where a dragged tab lands, how the other tabs make room, list moves, the closed-tab stack and the drag payload.
TestCase {
    name: "FilesTabs"

    function test_barVisibility() {
        verify(!TabsLogic.barVisible(false, 1), "one tab: no bar");
        verify(TabsLogic.barVisible(false, 2), "two tabs: the bar");
        verify(TabsLogic.barVisible(true, 1), "Show Tab Bar: the bar with one tab");
        verify(!TabsLogic.barVisible(undefined, 0));
    }

    function test_indexAfterClose() {
        compare(TabsLogic.indexAfterClose(2, 2, 3), 1, "closing the current last tab: its left neighbour");
        compare(TabsLogic.indexAfterClose(0, 0, 3), 0, "closing the first current tab: the next one, now first");
        compare(TabsLogic.indexAfterClose(2, 0, 3), 1, "closing a tab before the current one keeps the current tab");
        compare(TabsLogic.indexAfterClose(0, 2, 3), 0, "closing a tab after the current one changes nothing");
        compare(TabsLogic.indexAfterClose(0, 0, 1), 0);
    }

    function test_slots() {
        compare(TabsLogic.tabWidth(600, 3), 200);
        compare(TabsLogic.tabWidth(600, 0), 600);
        compare(TabsLogic.slotAt(-5, 200, 3), 0);
        compare(TabsLogic.slotAt(199, 200, 3), 0);
        compare(TabsLogic.slotAt(200, 200, 3), 1);
        compare(TabsLogic.slotAt(900, 200, 3), 2);
        compare(TabsLogic.slotAt(10, 0, 3), 0);
    }

    // The tabs of a bar while one of its own tabs is dragged from slot 0 to slot 2.
    function test_visualSlotsWhileReordering() {
        compare([0, 1, 2, 3].map(i => TabsLogic.visualSlot(i, 0, 2)), [2, 0, 1, 3]);
        compare([0, 1, 2, 3].map(i => TabsLogic.visualSlot(i, 3, 1)), [0, 2, 3, 1]);
        compare([0, 1, 2].map(i => TabsLogic.visualSlot(i, 1, 1)), [0, 1, 2], "over its own slot: nothing moves");
        compare([0, 1, 2].map(i => TabsLogic.visualSlot(i, -1, -1)), [0, 1, 2], "no drag");
    }

    function test_visualSlotsForAnIncomingTab() {
        compare([0, 1, 2].map(i => TabsLogic.visualSlot(i, -1, 1)), [0, 2, 3], "a tab of another window opens slot 1");
        compare([0, 1].map(i => TabsLogic.visualSlot(i, -1, 2)), [0, 1], "past the last tab");
    }

    function test_visualSlotsForAnOutgoingTab() {
        compare([0, 1, 2].map(i => TabsLogic.visualSlot(i, 0, -1)), [0, 0, 1], "a tab dragged out leaves no gap");
        compare([0, 1, 2].map(i => TabsLogic.visualSlot(i, 2, -1)), [0, 1, 2]);
    }

    function test_moved() {
        compare(TabsLogic.moved(["a", "b", "c"], 0, 2), ["b", "c", "a"]);
        compare(TabsLogic.moved(["a", "b", "c"], 2, 0), ["c", "a", "b"]);
        compare(TabsLogic.moved(["a", "b", "c"], 1, 9), ["a", "c", "b"], "past the end: last");
        compare(TabsLogic.moved(["a", "b"], 5, 0), ["a", "b"], "an unknown index changes nothing");
    }

    function test_closedTabs() {
        let stack = [];
        for (let i = 0; i < TabsLogic.maxClosedTabs + 3; i++)
            stack = TabsLogic.pushClosed(stack, {url: "file:///t" + i});
        compare(stack.length, TabsLogic.maxClosedTabs);
        compare(stack[0].url, "file:///t" + (TabsLogic.maxClosedTabs + 2), "the newest first");
    }

    function test_dragPayload() {
        compare(TabsLogic.tabIdFrom("4242:7", 4242), 7);
        compare(TabsLogic.tabIdFrom("4243:7", 4242), -1, "a tab of another Files process is refused");
        compare(TabsLogic.tabIdFrom("4242:x", 4242), -1);
        compare(TabsLogic.tabIdFrom("", 4242), -1);
        compare(TabsLogic.tabIdFrom(" 4242:7", 4242), -1);
    }
}
