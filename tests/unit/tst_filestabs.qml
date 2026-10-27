pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"
import "../../apps/files/qml/TabsLogic.js" as TabsLogic

// grassfield-files tab logic (apps/files/qml/TabsLogic.js, docs/specs/files.md "Tabs and windows"): when the tab bar
// shows, where a dragged tab lands, how the other tabs make room, list moves, the closed-tab stack and the drag payload;
// and the tab bar's file drop (TabBar.qml), which tells the source app "copy" like every other drop point of Files.
TestCase {
    id: test
    name: "FilesTabs"
    when: windowShown

    QtObject {
        id: fakeApp
        property int processId: 4242
        property url newWindowUrl: "file:///sandbox"
        property var dropped: []
        function drop(urls: var, destination: url, folder: var): void {
            fakeApp.dropped = fakeApp.dropped.concat([String(destination)]);
        }
    }

    QtObject {
        id: fakeManager
        property int tabDragAreas: 0
        function moveTabToNewWindow(tab: var): void {
        }
        function dropTab(id: int, target: var, slot: int): void {
        }
    }

    QtObject {
        id: fakeWin
        property var app: fakeApp
        property var manager: fakeManager
        property var menuLayer: null
        property int currentIndex: 0
        property var tabs: [
            {title: "Documents", tabId: 1, folder: {url: "file:///sandbox/Documents", writable: true, isSearch: false}},
            {title: "Downloads", tabId: 2, folder: {url: "file:///sandbox/Downloads", writable: true, isSearch: false}}
        ]
        property var tab: fakeWin.tabs[0]
        function selectTab(index: int): void {
            fakeWin.currentIndex = index;
        }
        function closeTab(index: int): void {
        }
        function newTab(target: url, restore: var): void {
        }
    }

    Component {
        id: tabBarComponent
        TabBar {
            win: fakeWin
            width: 600
        }
    }

    // A file drop as another application makes it: it proposes a move (a file manager does on the same volume).
    function fileDrop(hasUrls: bool): var {
        return {
            hasUrls: hasUrls,
            urls: hasUrls ? ["file:///elsewhere/note.txt"] : [],
            proposedAction: Qt.MoveAction,
            answer: -1,
            accept: function (action) {
                this.answer = action;
            }
        };
    }

    // Files runs the copy or move itself (FilesApp.drop); a Move answered to the source would let it delete its files
    // while a copy to another volume is still running (Wayland), so the tab answers Copy, like the views and the sidebar.
    function test_fileDropOnATabAnswersCopy() {
        fakeApp.dropped = [];
        const bar = createTemporaryObject(tabBarComponent, test);
        verify(bar);
        const drop = test.fileDrop(true);
        bar.dropFiles(drop, fakeWin.tabs[1]);
        compare(drop.answer, Qt.CopyAction, "the source app is told the files were copied, whatever it proposed");
        compare(fakeApp.dropped, ["file:///sandbox/Downloads"], "the files go to the tab's folder");
        const empty = test.fileDrop(false);
        bar.dropFiles(empty, fakeWin.tabs[1]);
        compare(empty.answer, -1, "a drop without files is not taken");
        compare(fakeApp.dropped.length, 1);
    }

    // Every drop point of Files that takes files answers Copy (the views, the sidebar, the path bar, the tabs); only a
    // dragged tab's own drop areas answer Move (the tab moves between Files windows of this process). A new drop point is
    // held to the same rule here.
    function test_everyFileDropAnswersCopy() {
        const files = ["TabBar.qml", "BrowserWindow.qml", "FileList.qml", "IconView.qml", "GalleryView.qml", "ColumnView.qml", "PathBar.qml",
            "Sidebar.qml", "Main.qml", "BrowserTab.qml"];
        let checked = 0;
        for (const name of files) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl("../../apps/files/qml/" + name), false);
            xhr.send();
            const text = xhr.responseText;
            verify(text.length > 0, name + " read");
            const accept = /\.accept\(([^)]*)\)/g;
            let m;
            while ((m = accept.exec(text)) !== null) {
                const before = text.slice(0, m.index);
                const keys = before.lastIndexOf("keys:");
                const tabDrop = keys >= 0 && text.slice(keys, text.indexOf("\n", keys)).indexOf("TabsLogic.tabMimeType") >= 0;
                const line = before.split("\n").length;
                if (tabDrop)
                    compare(m[1], "Qt.MoveAction", name + ":" + line + " a tab drop");
                else
                    compare(m[1], "Qt.CopyAction", name + ":" + line + " a file drop answers Copy");
                checked++;
            }
        }
        verify(checked >= 10, "drop answers checked: " + checked);
    }

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
