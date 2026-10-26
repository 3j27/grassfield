pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import "../../apps/files/qml"

// The global menu's Customize Folder item follows the selection (apps/files/qml/GlobalMenu.qml customizeEnabled): going
// from one file to one folder (the number of selected items stays 1) must enable it. The old binding depended on `count`
// and an untracked function and stayed stale. The tab and window items (docs/specs/files.md "Tabs and windows") follow
// the window, its tabs and the closed-tab stack; Sort By shows the shown folder's own arrangement.
TestCase {
    id: test
    name: "FilesGlobalMenu"
    when: windowShown

    QtObject {
        id: folder
        property int selectedCount: 0
        property var dirs: ({})
        property var rows: []
        signal selectionChanged
        function selectedRows(): var {
            return folder.rows;
        }
        function isDirAt(row: int): bool {
            return folder.dirs[row] === true;
        }
        function selectedUrls(): var {
            return folder.rows.map(r => "file:///sandbox/item" + r);
        }
        function nameAt(row: int): string {
            return "item" + row;
        }
        property bool isTrash: false
        property bool writable: true
        property bool isSearch: false
    }

    QtObject {
        id: fakeApp
        property int folderStyleRevision: 0
        property int tagRevision: 0
        // Everything the menu binds to, so that a real binding error is never hidden among fixture warnings (GF-073).
        property bool canUndo: false
        property bool canRedo: false
        property bool canPaste: false
        property bool galleryInfo: false
        property bool sortDescending: false
        property bool foldersFirst: true
        property bool showHidden: false
        property bool devSession: false
        property bool tabBarShown: false
        property url newWindowUrl: "file:///sandbox"
        property var places: ({trashEmpty: true})
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
        function tagsUnavailable(urls: var): string {
            return "";
        }
        function colorTagStates(urls: var): var {
            return [];
        }
        function applicationsFor(urls: var): var {
            return [];
        }
    }

    QtObject {
        id: fakeManager
        property var closedTabs: []
        property var windows: [fakeWin]
        property int reopened: 0
        property int merged: 0
        function reopenClosedTab(win: var): void {
            fakeManager.reopened++;
        }
        function mergeAllWindows(win: var): void {
            fakeManager.merged++;
        }
    }

    QtObject {
        id: fakeWin
        property var app: fakeApp
        property var manager: fakeManager
        property bool tabBarVisible: false
        property var tab: ({canBack: false, canForward: false, segments: [], sortKey: 2, sortDescending: true})
        property var folder: folder
        property var tabs: []
        property int currentIndex: 0
        property bool canEject: false
        property int ejected: 0
        function ejectVolume(): bool {
            fakeWin.ejected++;
            return true;
        }
    }

    Component {
        id: menuComponent

        GlobalMenu {
            win: fakeWin
        }
    }

    function select(rows, dirs) {
        // The model changes the rows first, then the count (NOTIFY), like FolderModel.
        folder.dirs = dirs;
        folder.rows = rows;
        folder.selectedCount = rows.length;
        folder.selectionChanged();
    }

    function test_customizeFollowsTheSelection() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        compare(bar.customizeEnabled, false, "nothing selected");
        select([0], {0: false});
        compare(bar.customizeEnabled, false, "one file");
        // One file -> one folder: selectedCount stays 1.
        folder.dirs = {1: true};
        folder.rows = [1];
        folder.selectedCount = 0;
        folder.selectedCount = 1;
        compare(bar.customizeEnabled, true, "one folder");
        select([2, 3], {2: true, 3: false});
        compare(bar.customizeEnabled, false, "a folder and a file");
        select([2, 4], {2: true, 4: true});
        compare(bar.customizeEnabled, true, "two folders");
        select([], {});
        compare(bar.customizeEnabled, false, "nothing again");
    }

    // File > Eject (Ctrl+E) follows the window's canEject and ejects through the window: the keyboard path to the sidebar's
    // eject button, which is out of the Tab chain.
    function test_fileMenuHasEject() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        let item = null;
        const file = bar.menus[0];
        for (let i = 0; i < file.items.length; i++) {
            if (file.items[i].text === "Eject")
                item = file.items[i];
        }
        verify(item !== null, "File has an Eject item");
        compare(item.shortcut.toString(), "Ctrl+E");
        compare(item.enabled, false, "nothing to eject");
        fakeWin.canEject = true;
        compare(item.enabled, true);
        item.triggered();
        compare(fakeWin.ejected, 1);
        fakeWin.canEject = false;
    }

    function item(menu: var, text: string): var {
        for (let i = 0; i < menu.items.length; i++) {
            if (menu.items[i].text === text)
                return menu.items[i];
        }
        return null;
    }

    function test_tabAndWindowItems() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        const file = bar.menus[0];
        const view = bar.menus[2];
        const reopen = test.item(file, "Reopen Closed Tab");
        verify(reopen !== null);
        compare(reopen.shortcut.toString(), "Ctrl+Alt+Shift+T");
        compare(reopen.enabled, false, "no closed tab");
        fakeManager.closedTabs = [{url: "file:///sandbox/a"}];
        compare(reopen.enabled, true);
        reopen.triggered();
        compare(fakeManager.reopened, 1);
        fakeManager.closedTabs = [];

        const bar1 = test.item(view, "Show Tab Bar");
        verify(bar1 !== null, "Show Tab Bar while the bar is hidden");
        compare(bar1.shortcut.toString(), "Ctrl+Shift+T");
        fakeWin.tabBarVisible = true;
        verify(test.item(view, "Hide Tab Bar") !== null, "Hide Tab Bar while it shows");
        fakeWin.tabBarVisible = false;

        const merge = test.item(view, "Merge All Windows");
        verify(merge !== null);
        compare(merge.enabled, false, "one window");
        fakeManager.windows = [fakeWin, fakeApp];
        compare(merge.enabled, true);
        merge.triggered();
        compare(fakeManager.merged, 1);
        fakeManager.windows = [fakeWin];
        compare(test.item(view, "Move Tab to New Window").enabled, false, "one tab");
        compare(test.item(file, "Close Window").visible, true, "one tab: Close Window is the Cmd-W item");
    }

    // Sort By checks the tab's arrangement (the shown folder's own), not a global setting.
    function test_sortByFollowsTheTab() {
        const bar = createTemporaryObject(menuComponent, test);
        verify(bar);
        const sort = bar.sortMenu;
        verify(sort !== null);
        let checked = [];
        for (let i = 0; i < sort.items.length; i++) {
            if (sort.items[i].checked)
                checked.push(sort.items[i].text);
        }
        compare(checked.indexOf("Date Modified") >= 0, true, "the tab sorts by date");
        compare(checked.indexOf("Descending") >= 0, true, "descending");
        compare(checked.indexOf("Name") >= 0, false);
    }
}
