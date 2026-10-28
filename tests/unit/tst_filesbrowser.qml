pragma ComponentBehavior: Bound
import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/files/qml"

// The real Files windows offscreen (Main.qml, BrowserWindow.qml, BrowserTab.qml, InfoWindow.qml, CustomizeFolderWindow.qml,
// GlobalMenu.qml) over a stand-in FilesApp.
// - The window the browser opens for itself (Get Info, Customize Folder) is the key window once it opens: Ctrl+W closes it
//   alone and the browser window stays with its tab (macOS: Cmd+W closes the key window only), with and without the
//   global menu, whose items carry the same keys. Meanwhile none of the browser's keys is live (BrowserWindow.childIsKey).
//   The other way round, the browser the key window with such a window open: its keys act on the browser only.
// - A tab keeps the view a drag started from until the drag has ended (BrowserTab.dragView): the view chosen meanwhile
//   applies once the drag's own handlers have returned.
TestCase {
    id: test
    name: "FilesBrowser"
    when: windowShown

    // FolderModel as the window, the tab and the icon view read it (an empty listing of `url`).
    Component {
        id: folderComponent
        ListModel {
            id: folder
            property url url
            property bool loading: false
            property string error: ""
            property real freeSpace: -1
            property bool isTrash: false
            property bool writable: true
            property bool isSearch: false
            property bool searchLimited: false
            property string filterText: ""
            property int groupBy: 0
            property var groups: []
            property int sortKey: 0
            property bool sortDescending: false
            property bool foldersFirst: true
            property bool showHidden: false
            property int previewSize: 0
            property int largePreviewSize: 0
            property int currentRow: -1
            property int selectedCount: 0
            signal redirected(url url)
            function selectedRows(): var {
                return [];
            }
            function selectedUrls(): var {
                return [];
            }
            function isSelected(row: int): bool {
                return false;
            }
            function select(row: int, modifiers: int): void {
            }
            function selectAll(): void {
            }
            function clearSelection(): void {
            }
            function selectUrls(urls: var): void {
            }
            function findPrefix(prefix: string, from: int): int {
                return -1;
            }
            function rowForUrl(target: url): int {
                return -1;
            }
            function isDirAt(row: int): bool {
                return false;
            }
            function nameAt(row: int): string {
                return "";
            }
            function urlAt(row: int): url {
                return folder.url;
            }
            function expect(target: url, rename: bool): void {
            }
            function reload(): void {
            }
            function requestPreview(row: int, large: bool): void {
            }
            function cancelPreview(target: url, large: bool): void {
            }
            // Get Info of the listed folder itself (row -1), as FolderModel.info() gives it.
            function info(row: int): var {
                return {
                    name: "sandbox", url: folder.url, isDir: true, kind: "Folder", sizeText: "", bytes: 0, where: "/", created: "",
                    modified: "", accessed: "", linkDest: "", owner: "", group: "", permissions: "", writable: true, readable: true,
                    iconName: "folder", thumbnail: ""
                };
            }
        }
    }

    ListModel {
        id: places
        property bool trashEmpty: true
        signal mounted(url url)
        function rowForUrl(target: url): int {
            return -1;
        }
        function eject(row: int): void {
        }
        function mount(row: int): void {
        }
    }

    // What Main.qml and the windows read of FilesApp.
    QtObject {
        id: fakeApp
        property bool dark: false
        property bool reduceMotion: false
        property string accentColor: "multicolor"
        property string shortcutStyle: "pc"
        property string iconMode: "default"
        property string iconTint: "accent"
        property string folderColor: "theme"
        property int windowWidth: 0
        property int windowHeight: 0
        property url newWindowUrl: "file:///sandbox"
        property var initialUrls: []
        property int processId: 4242
        property string viewMode: "icons"
        property int sortKey: 0
        property bool sortDescending: false
        property int recentsSortKey: 5
        property bool foldersFirst: true
        property bool showHidden: false
        property bool sidebarShown: true
        property bool tabBarShown: false
        property bool pathBarShown: false
        property bool statusBarShown: false
        property bool previewPane: false
        property bool galleryInfo: false
        property bool columnPreview: false
        property string titlebarDoubleClick: "zoom"
        property bool canMinimize: true
        property string activity: ""
        property int activityPercent: -1
        property bool canUndo: false
        property bool canRedo: false
        property bool canPaste: false
        property int clipboardCount: 0
        property bool devSession: true
        property int tagRevision: 0
        property int folderStyleRevision: 0
        property var colorTagNames: []
        property var hiddenTags: []
        property string homePath: "/sandbox"
        property var places: places
        property var prompts: fakePrompts
        // FilesApp.focusWindow is QGuiApplication::focusWindow(), which QML cannot read: the test sets it wherever it moves
        // the keyboard (test.giveKeys), as the compositor and Qt do in the app.
        property var focusWindow: null
        // The views each folder was given (FilesApp.setFolderView), by url.
        property var folderViews: ({})
        signal prefsChanged
        signal operationFailed(string message)
        // FilesApp's: a drag from another application left a window (Main.qml outsideDrags).
        signal outsideDragEnded(var window, bool dropped)
        function createFolderModel(owner: var): var {
            return folderComponent.createObject(owner);
        }
        function folderView(target: url): var {
            const stored = fakeApp.folderViews[String(target)];
            return stored ? stored : {};
        }
        function setFolderView(target: url, view: var): void {
            const all = Object.assign({}, fakeApp.folderViews);
            all[String(target)] = Object.assign({}, all[String(target)] || {}, view);
            fakeApp.folderViews = all;
        }
        function pathSegments(target: url): var {
            return [{label: "sandbox", url: target}];
        }
        function sameUrl(a: url, b: url): bool {
            return String(a) === String(b);
        }
        function isRecents(target: url): bool {
            return false;
        }
        function defaultDescending(key: int): bool {
            return false;
        }
        function isDirectChild(parent: url, child: url): bool {
            return false;
        }
        function formatSize(bytes: real): string {
            return String(bytes);
        }
        function rememberWindowSize(width: int, height: int): void {
        }
        function reparent(object: var, parent: var): void {
        }
        function tagsUnavailable(urls: var): string {
            return "";
        }
        function colorTagStates(urls: var): var {
            return [];
        }
        function tagNamesOf(target: url): var {
            return [];
        }
        function folderStyleOf(target: url): var {
            return {color: "", glyph: ""};
        }
        function folderStyleUnavailable(urls: var): string {
            return "";
        }
        function applyFolderStyle(urls: var, color: string, glyph: string): void {
        }
        function directorySize(target: url, done: var): void {
        }
        function applicationsFor(urls: var): var {
            return [];
        }
        function baseNameLength(name: string, isDir: bool): int {
            return name.length;
        }
        function uriList(urls: var): string {
            return "";
        }
    }

    // FilesApp.prompts (src/kioprompts.h): KIO's question on screen, and the replies.
    QtObject {
        id: fakePrompts
        property var current: ({})
        property var replies: []
        function reply(id: int, answer: var): void {
            fakePrompts.replies = fakePrompts.replies.concat([{
                    id: id,
                    button: answer.button
                }]);
            fakePrompts.current = ({});
        }
    }

    Component {
        id: filesComponent
        Main {
            app: fakeApp
        }
    }

    Component {
        id: signalSpy
        SignalSpy {}
    }

    // The one browser window Main opens at start, shown and active.
    function openFiles(globalMenu: bool): var {
        const files = createTemporaryObject(filesComponent, test, {globalMenu: globalMenu});
        verify(files !== null, "Main.qml");
        tryCompare(files.windows, "length", 1);
        const browser = files.windows[0];
        test.giveKeys(browser);
        compare(browser.tabs.length, 1);
        return files;
    }

    // Gives `w` the keyboard (offscreen Qt moves the focus window on requestActivate) and tells the stand-in FilesApp.
    // `active` alone proves nothing: Qt reports a window and its transient children active together.
    function giveKeys(w: var): void {
        w.requestActivate();
        tryVerify(() => w.active, 2000, "the window is active");
        wait(50);
        fakeApp.focusWindow = w;
    }

    // A key as a user types it, into the window that has the keyboard. Not keyClick: QTest sends a click's release to the
    // window its press went to, and a press that closes and deletes that window leaves the release a deleted target.
    function type(key: int, modifiers: int): void {
        keyPress(key, modifiers);
        keyRelease(key, modifiers);
    }

    // The window the browser opened last (Get Info, Customize Folder), once it is the key window.
    function newOwnWindow(browser: var, before: int): var {
        tryVerify(() => browser.ownWindows.length === before + 1, 2000, "the browser opened a window of its own");
        const w = browser.ownWindows[before];
        verify(w.transientParent === browser, "a transient child of the browser");
        // A new window takes the keyboard (the compositor gives it the focus).
        test.giveKeys(w);
        return w;
    }

    // The browser window's own Shortcuts.
    function browserShortcuts(browser: var): var {
        const list = [];
        for (let i = 0; i < browser.data.length; i++) {
            if (browser.data[i] instanceof Shortcut)
                list.push(browser.data[i]);
        }
        return list;
    }

    // The items of the browser's global menu (GlobalMenu.qml) that carry a key; [] without the global menu.
    function menuKeyItems(browser: var): var {
        const list = [];
        const walk = menu => {
            for (let i = 0; i < menu.items.length; i++) {
                const item = menu.items[i];
                if (item.subMenu)
                    walk(item.subMenu);
                else if (item.shortcut !== undefined && String(item.shortcut) !== "")
                    list.push(item);
            }
        };
        for (let i = 0; i < browser.data.length; i++) {
            const loader = browser.data[i];
            if (loader instanceof Loader && loader.item instanceof GlobalMenu) {
                for (let m = 0; m < loader.item.menus.length; m++)
                    walk(loader.item.menus[m]);
            }
        }
        return list;
    }

    // `on`: the browser's keys that depend on nothing else (Ctrl+N, Ctrl+T, Ctrl+W, Ctrl+F: Shortcuts and menu items) are
    // live; otherwise none of its keys is.
    function verifyBrowserKeys(browser: var, globalMenu: bool, on: bool, what: string): void {
        const shortcuts = test.browserShortcuts(browser);
        verify(shortcuts.length >= 40, what + ": the browser's Shortcuts are found (" + shortcuts.length + ")");
        const items = test.menuKeyItems(browser);
        if (globalMenu)
            verify(items.length >= 30, what + ": the global menu's keyed items are found (" + items.length + ")");
        else
            compare(items.length, 0, what + ": no global menu");
        if (on) {
            for (const key of ["Ctrl+N", "Ctrl+T", "Ctrl+W", "Ctrl+F"]) {
                const own = shortcuts.filter(s => s.sequence === key);
                compare(own.length, 1, what + ": the browser's " + key);
                verify(own[0].enabled, what + ": the browser's " + key + " is live");
                const item = items.filter(i => String(i.shortcut) === key);
                compare(item.length, globalMenu ? 1 : 0, what + ": the menu item of " + key);
                verify(item.every(i => i.enabled), what + ": the menu item of " + key + " is live");
            }
            return;
        }
        const live = shortcuts.filter(s => s.enabled).map(s => s.sequence !== "" ? s.sequence : String(s.sequences));
        compare(live, [], what + ": no Shortcut of the browser is live");
        const liveItems = items.filter(i => i.enabled).map(i => String(i.shortcut));
        compare(liveItems, [], what + ": no keyed item of the global menu is live");
    }

    function test_closeInfoKeepsTheBrowser_data() {
        return [
            {tag: "without the global menu, Ctrl+W", globalMenu: false, key: Qt.Key_W, modifiers: Qt.ControlModifier},
            {tag: "without the global menu, Escape", globalMenu: false, key: Qt.Key_Escape, modifiers: Qt.NoModifier},
            {tag: "with the global menu, Ctrl+W", globalMenu: true, key: Qt.Key_W, modifiers: Qt.ControlModifier},
            {tag: "with the global menu, Escape", globalMenu: true, key: Qt.Key_Escape, modifiers: Qt.NoModifier}
        ];
    }

    // Get Info opened with Ctrl+I (BrowserTab.getInfo -> BrowserWindow.showInfo) is the key window: Ctrl+W (or Escape)
    // closes it alone; the browser window stays open with its tab, and its keys are live again.
    function test_closeInfoKeepsTheBrowser(data) {
        const files = test.openFiles(data.globalMenu);
        const browser = files.windows[0];
        test.verifyBrowserKeys(browser, data.globalMenu, true, "the browser is the key window");
        test.type(Qt.Key_I, Qt.ControlModifier);
        const info = test.newOwnWindow(browser, 0);
        verify(info instanceof InfoWindow);
        verify(browser.childIsKey);
        test.verifyBrowserKeys(browser, data.globalMenu, false, "Get Info is the key window");
        const closed = signalSpy.createObject(test, {target: info, signalName: "closing"});
        test.type(data.key, data.modifiers);
        compare(closed.count, 1, "the key closes Get Info");
        tryCompare(browser.ownWindows, "length", 0);
        wait(50);
        compare(files.windows.length, 1, "the browser window is still open");
        verify(files.windows[0] === browser);
        verify(browser.visible, "and shown");
        compare(browser.tabs.length, 1, "with its tab");
        compare(files.closedTabs.length, 0, "no tab was closed");
        verify(!browser.childIsKey);
        test.verifyBrowserKeys(browser, data.globalMenu, true, "Get Info closed");
        // The browser's own Ctrl+W, once it has the keyboard again: its only tab closes the window. (Not with the global
        // menu: a Qt.labs.platform item with a key, destroyed with its window, can leave a dangling entry in Qt's shortcut
        // map that a later press of that key in this process reaches.)
        if (data.globalMenu)
            return;
        test.giveKeys(browser);
        test.type(Qt.Key_W, Qt.ControlModifier);
        tryCompare(files.windows, "length", 0, 2000, "the browser's Ctrl+W closes the browser");
    }

    function test_browserKeysWhileGetInfoIsOpen_data() {
        return [
            {tag: "without the global menu", globalMenu: false},
            {tag: "with the global menu", globalMenu: true}
        ];
    }

    // Get Info open, the browser the key window again: the browser's keys are its own (Qt reports Get Info active too, as a
    // transient child of the key window). Escape leaves Get Info open, Ctrl+T opens tabs, every Ctrl+W closes a browser
    // tab (none goes to Get Info), the menu items are live; back in Get Info, Ctrl+W closes it alone.
    function test_browserKeysWhileGetInfoIsOpen(data) {
        const files = test.openFiles(data.globalMenu);
        const browser = files.windows[0];
        test.type(Qt.Key_I, Qt.ControlModifier);
        const info = test.newOwnWindow(browser, 0);
        const closed = signalSpy.createObject(test, {target: info, signalName: "closing"});
        test.giveKeys(browser);
        verify(info.active, "Qt still reports Get Info active (its transient parent has the keyboard)");
        verify(!browser.childIsKey, "the browser is the key window");
        test.verifyBrowserKeys(browser, data.globalMenu, true, "the browser is the key window, Get Info open");
        test.type(Qt.Key_Escape, Qt.NoModifier);
        compare(closed.count, 0, "Escape typed in the browser leaves Get Info open");
        test.type(Qt.Key_T, Qt.ControlModifier);
        test.type(Qt.Key_T, Qt.ControlModifier);
        tryCompare(browser.tabs, "length", 3, 2000, "Ctrl+T opens a tab each time");
        test.type(Qt.Key_W, Qt.ControlModifier);
        test.type(Qt.Key_W, Qt.ControlModifier);
        tryCompare(browser.tabs, "length", 1, 2000, "each Ctrl+W closes a tab of the browser");
        compare(closed.count, 0, "Get Info is still open");
        compare(browser.ownWindows.length, 1);
        compare(files.windows.length, 1);
        // Back in Get Info: Ctrl+W closes it alone.
        test.giveKeys(info);
        verify(browser.childIsKey);
        test.type(Qt.Key_W, Qt.ControlModifier);
        compare(closed.count, 1, "Ctrl+W typed in Get Info closes it");
        compare(browser.tabs.length, 1, "the browser keeps its tab");
        compare(files.windows.length, 1);
    }

    // The same for Customize Folder: Ctrl+W typed in the browser closes a browser tab, typed in Customize Folder that window.
    function test_browserKeysWhileCustomizeIsOpen() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        browser.customizeFolders(["file:///sandbox/Folder"], "Folder", "folder");
        const customize = test.newOwnWindow(browser, 0);
        const closed = signalSpy.createObject(test, {target: customize, signalName: "closing"});
        test.giveKeys(browser);
        test.verifyBrowserKeys(browser, false, true, "the browser is the key window, Customize Folder open");
        test.type(Qt.Key_T, Qt.ControlModifier);
        test.type(Qt.Key_T, Qt.ControlModifier);
        tryCompare(browser.tabs, "length", 3, 2000, "Ctrl+T opens a tab each time");
        // Two presses: Qt hands an ambiguous key to each matching Shortcut in turn, so one live Shortcut of Customize Folder
        // would take every second press.
        test.type(Qt.Key_W, Qt.ControlModifier);
        test.type(Qt.Key_W, Qt.ControlModifier);
        tryCompare(browser.tabs, "length", 1, 2000, "each Ctrl+W closes a tab of the browser");
        compare(closed.count, 0, "Customize Folder is still open");
        test.giveKeys(customize);
        test.type(Qt.Key_W, Qt.ControlModifier);
        compare(closed.count, 1, "Ctrl+W typed in Customize Folder closes it");
        compare(browser.tabs.length, 1);
        compare(files.windows.length, 1);
    }

    // Customize Folder (a window of the browser too): Ctrl+W closes it alone.
    function test_closeCustomizeKeepsTheBrowser() {
        const files = test.openFiles(false);
        const browser = files.windows[0];
        browser.customizeFolders(["file:///sandbox/Folder"], "Folder", "folder");
        const customize = test.newOwnWindow(browser, 0);
        verify(customize instanceof CustomizeFolderWindow);
        test.verifyBrowserKeys(browser, false, false, "Customize Folder is the key window");
        const closed = signalSpy.createObject(test, {target: customize, signalName: "closing"});
        test.type(Qt.Key_W, Qt.ControlModifier);
        compare(closed.count, 1, "Ctrl+W closes Customize Folder");
        tryCompare(browser.ownWindows, "length", 0);
        wait(50);
        compare(files.windows.length, 1, "the browser window is still open");
        compare(browser.tabs.length, 1, "with its tab");
        test.verifyBrowserKeys(browser, false, true, "Customize Folder closed");
    }

    // The sheet of `browser`'s KioSheets (KIO's questions).
    function kioSheet(browser: var): var {
        const walk = item => {
            if (item instanceof KioSheets) {
                for (let i = 0; i < item.children.length; i++) {
                    if (item.children[i] instanceof Sheet)
                        return item.children[i];
                }
            }
            for (let i = 0; i < item.children.length; i++) {
                const found = walk(item.children[i]);
                if (found)
                    return found;
            }
            return null;
        };
        return walk(browser.contentItem);
    }

    // KIO's question (Main.qml placePrompt, KioSheets.qml) shows in the window the user last worked in, stays there when
    // another window becomes the key window, and moves to another window when its own closes; Return answers it there.
    function test_kioQuestionWindow() {
        fakePrompts.current = ({});
        fakePrompts.replies = [];
        const files = test.openFiles(false);
        const first = files.windows[0];
        const second = files.newWindow("file:///sandbox", null);
        tryCompare(files.windows, "length", 2);
        test.giveKeys(second);
        compare(files.lastActiveWindow, second);

        fakePrompts.current = {
            id: 5,
            kind: "notice",
            title: "“Tool” wasn’t opened.",
            text: "Files doesn’t run programs."
        };
        compare(files.promptWindow, second, "the window last worked in");
        tryVerify(() => test.kioSheet(second).visible, 1000, "its sheet shows the question");
        verify(!test.kioSheet(first).visible, "the other window shows nothing");
        compare(test.kioSheet(second).title, "“Tool” wasn’t opened.");

        test.giveKeys(first);
        compare(files.promptWindow, second, "the question stays where it is");
        verify(!test.kioSheet(first).visible);

        second.close();
        tryCompare(files.windows, "length", 1);
        compare(files.promptWindow, first, "its window closed: the question moves");
        tryVerify(() => test.kioSheet(first).visible, 1000);
        test.giveKeys(first);
        verify(waitForPolish(first, 1000));
        test.type(Qt.Key_Return, Qt.NoModifier);
        compare(fakePrompts.replies, [{id: 5, button: "ok"}]);
        verify(!test.kioSheet(first).visible);
        compare(files.promptWindow, null);
    }

    // BrowserTab.dragView: while a system drag started from the tab's view runs, that view stays (Qt Quick uses the item
    // that started the drag after QDrag::exec returns); a view chosen meanwhile applies once the drag has ended and its
    // own handlers have returned (Qt.callLater from dragFinished).
    function test_dragKeepsItsView() {
        const files = test.openFiles(false);
        const tab = files.windows[0].tab;
        compare(tab.viewMode, "icons");
        tryVerify(() => tab.view !== null && String(tab.view).startsWith("IconView"), 2000, "the icon view");
        const started = tab.view;
        tab.dragStarted();
        tab.setViewMode("list");
        compare(tab.viewMode, "list", "the tab's mode follows the choice");
        verify(tab.view === started, "the icon view stays while the drag runs");
        wait(50);
        verify(tab.view === started, "and after the event loop ran");
        tab.dragFinished(Qt.CopyAction);
        verify(tab.view === started, "the drag's own handler returns before the view goes");
        tryVerify(() => tab.view !== started && String(tab.view).startsWith("FileList"), 2000, "then the list view applies");
        // Without a drag, a choice applies at once.
        tab.setViewMode("icons");
        verify(String(tab.view).startsWith("IconView"), "no drag: the view follows at once");
    }
}
