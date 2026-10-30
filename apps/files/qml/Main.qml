pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TabsLogic.js" as TabsLogic

// Grassfield Files: owns the browser windows (Ctrl+N opens another) and feeds the shared appearance.
// The app quits when its last window closes.
QtObject {
    id: root

    // Set by the launcher (src/main.cpp): a FilesApp.
    required property var app
    // The registrar is there (kept up to date by src/main.cpp): each window exports its menus to the global menu bar.
    required property bool globalMenu
    // --info: only the Get Info window of each location (the desktop's Get Info), no browser window.
    property bool infoOnly: false
    // --info requests still waiting for their listing, and Get Info windows opened: with none opened at the end the app
    // quits by itself (it has no window that could close).
    property int infoPending: 0
    property int infoShown: 0
    // The browser window that was active last (operation errors show there).
    property var lastActiveWindow: null
    // Open browser windows, oldest first (Merge All Windows takes their tabs in this order).
    property var windows: []
    // Tabs closed in this session, newest first: snapshots for File > Reopen Closed Tab (TabsLogic.pushClosed).
    property var closedTabs: []
    // The drop areas of Files windows that a dragged tab is over (a drop outside all of them makes it a window: TabBar).
    // A count, not a flag: Qt may enter the next area before it leaves the previous one.
    property int tabDragAreas: 0
    property int lastTabId: 0
    // The tab being dragged (TabBar), null when none. The platform drag runs a nested event loop inside the source tab's
    // mouse handler, and the drop is delivered inside that loop: moving the tab then would rebuild the source bar's tabs
    // and, for a window's only tab, close and destroy the window, under the running drag. A drop is therefore only
    // recorded here, and applied once the drag has ended and its handlers have returned (tabDragFinished).
    property var draggedTab: null
    property var pendingTabDrop: null

    // Appearance follows grassfield.json through FilesApp (shared with the Open and Save panels, FilePanels.qml).
    property FilesAppearance appearance: FilesAppearance {
        app: root.app
    }

    property Component windowComponent: Component {
        BrowserWindow {}
    }

    // Tabs are made here, not in their window: a tab outlives the window it was opened in when it moves to another one
    // (a QML object's functions belong to the context it was created in, which dies with that window).
    property Component tabComponent: Component {
        BrowserTab {}
    }

    // A browser window at `url`, or holding `tab` (a tab of another window) when given. It opens at the size of the
    // last window resized or closed (ADR-0026 part 1).
    function newWindow(url: url, tab: var): var {
        const props = {app: root.app, manager: root, startUrl: url, adoptTab: tab ? tab : null};
        if (root.app.windowWidth > 0 && root.app.windowHeight > 0) {
            props.width = Math.max(root.app.windowWidth, Tokens.filesWindowMinWidth);
            props.height = Math.max(root.app.windowHeight, Tokens.filesWindowMinHeight);
        }
        const w = root.windowComponent.createObject(root, props);
        if (!w)
            console.warn("grassfield-files: cannot create a window:", root.windowComponent.errorString());
        return w;
    }

    // Tabs a drag spring-loaded into a folder (BrowserTab.springHover): when a drag Files started ends, they stay where
    // the drop happened or, without a drop, go back (Finder). A drag from another application has no end Files hears of
    // by itself: the window it leaves or is dropped on reports it (FilesApp.outsideDragEnded).
    property var springTabs: []

    property Connections outsideDrags: Connections {
        target: root.app
        function onOutsideDragEnded(window: var, dropped: bool): void {
            const tabs = root.springTabs;
            root.springTabs = tabs.filter(tab => !tab || tab.win !== window);
            for (let i = 0; i < tabs.length; i++) {
                if (tabs[i] && tabs[i].win === window && tabs[i].springEnd)
                    tabs[i].springEnd(dropped);
            }
        }
    }

    // The window that shows KIO's question on screen (KioSheets.qml): the one the user last worked in when it was asked. It
    // stays there until it is answered, and moves to another window if that one closes. With no browser window (--info)
    // the question is answered "stop", which gives every kind its safe answer (src/kioprompts.cpp).
    property var promptWindow: null
    property int promptId: -1
    property Connections promptPlacement: Connections {
        target: root.app.prompts ?? null
        function onCurrentChanged(): void {
            root.placePrompt();
        }
    }

    function placePrompt(): void {
        const current = root.app.prompts ? root.app.prompts.current : null;
        const id = current && current.id !== undefined ? current.id : -1;
        if (id < 0) {
            root.promptId = -1;
            root.promptWindow = null;
            return;
        }
        if (id === root.promptId && root.promptWindow)
            return;
        root.promptId = id;
        root.promptWindow = root.lastActiveWindow ?? (root.windows.length > 0 ? root.windows[root.windows.length - 1] : null);
        if (!root.promptWindow)
            root.app.prompts.reply(id, {
                button: "stop"
            });
    }

    // Files' Choose Application panels (ADR-0035 D-5, step 5c): Open With > Other… and KIO's question when a document's type
    // has no application (FilesApp.applicationChooser, src/applicationchooser.h). Each is grassfield-portal's panel
    // (FilePanel.qml, kind "application"), modal to the browser window the user worked in: {panel, over} by request id.
    property var applicationPanels: ({})
    property Component applicationPanel: Component {
        FilePanel {}
    }
    property Connections applicationRequests: Connections {
        target: root.app.applicationChooser ?? null
        function onOpened(id: int, request: var): void {
            root.openApplicationPanel(id, request);
        }
        function onClosed(id: int): void {
            root.closeApplicationPanel(id);
        }
    }

    function openApplicationPanel(id: int, request: var): void {
        // A browser window: the one under the panel the user worked in, if it was a panel (review of step 5c, NIT).
        let over = root.lastActiveWindow ?? (root.windows.length > 0 ? root.windows[root.windows.length - 1] : null);
        while (over && root.windows.indexOf(over) < 0)
            over = over.transientParent ?? null;
        const panel = over ? root.applicationPanel.createObject(root, {
            app: root.app,
            host: null,
            appHost: root.app.applicationChooser,
            manager: root,
            requestId: id,
            request: request,
            transientParent: over
        }) : null;
        if (!panel) {
            // No browser window (--info), or the panel could not be made: nothing is chosen.
            if (over)
                console.warn("grassfield-files: cannot make the Choose Application panel:", root.applicationPanel.errorString());
            root.app.applicationChooser.answer(id, 1, {});
            return;
        }
        const next = Object.assign({}, root.applicationPanels);
        next[id] = {
            panel: panel,
            over: over
        };
        root.applicationPanels = next;
        panel.visible = true;
    }

    // The request ended (answered, or its job went): the panel goes, and what follows (the chosen application's errors, KIO's
    // questions) shows in the window it was over.
    function closeApplicationPanel(id: int): void {
        const entry = root.applicationPanels[id];
        if (!entry)
            return;
        const next = Object.assign({}, root.applicationPanels);
        delete next[id];
        root.applicationPanels = next;
        if (root.lastActiveWindow === entry.panel)
            root.lastActiveWindow = root.windows.indexOf(entry.over) >= 0 ? entry.over : null;
        if (root.promptWindow === entry.panel) {
            root.promptWindow = null;
            root.placePrompt();
        }
        entry.panel.visible = false;
        entry.panel.destroy();
    }

    function springStarted(tab: var): void {
        if (root.springTabs.indexOf(tab) < 0)
            root.springTabs = root.springTabs.concat([tab]);
    }

    function dragEnded(dropped: bool): void {
        const tabs = root.springTabs;
        root.springTabs = [];
        for (let i = 0; i < tabs.length; i++) {
            // A tab closed during the drag has no functions left.
            if (tabs[i] && tabs[i].springEnd)
                tabs[i].springEnd(dropped);
        }
    }

    function nextTabId(): int {
        root.lastTabId += 1;
        return root.lastTabId;
    }

    function registerWindow(win: var): void {
        if (root.windows.indexOf(win) < 0)
            root.windows = root.windows.concat([win]);
    }

    function forgetWindow(win: var): void {
        root.windows = root.windows.filter(w => w !== win);
        // Its Choose Application panels go with it, unanswered (Close All, Merge All Windows; review of step 5c, NIT).
        for (const id of Object.keys(root.applicationPanels)) {
            if (root.applicationPanels[id].over === win)
                root.app.applicationChooser.answer(Number(id), 1, {});
        }
        if (root.lastActiveWindow === win)
            root.lastActiveWindow = null;
        if (root.promptWindow === win) {
            root.promptWindow = null;
            root.placePrompt();
        }
    }

    function rememberClosedTab(tab: var): void {
        root.closedTabs = TabsLogic.pushClosed(root.closedTabs, tab.snapshot());
    }

    // File > Reopen Closed Tab: the newest closed tab comes back in `win` (or a new window when none is open).
    function reopenClosedTab(win: var): void {
        if (root.closedTabs.length === 0)
            return;
        const snapshot = root.closedTabs[0];
        root.closedTabs = root.closedTabs.slice(1);
        if (win)
            win.newTab(snapshot.url, snapshot);
        else
            root.newWindow(snapshot.url, null);
    }

    function tabById(id: int): var {
        for (let i = 0; i < root.windows.length; i++) {
            const tabs = root.windows[i].tabs;
            for (let j = 0; j < tabs.length; j++) {
                if (tabs[j].tabId === id)
                    return tabs[j];
            }
        }
        return null;
    }

    // Window > Move Tab to New Window, or a tab dragged out of every window: the tab keeps its state (location,
    // history, view, selection) in a window of its own. A window's only tab stays where it is.
    function moveTabToNewWindow(tab: var): void {
        if (!tab || !tab.win || tab.win.tabs.length <= 1)
            return;
        tab.win.detach(tab);
        root.newWindow(tab.url, tab);
    }

    // A tab bar starts dragging `tab`.
    function tabDragStarted(tab: var): void {
        root.draggedTab = tab;
        root.pendingTabDrop = null;
    }

    // The drag of the tab bar's tab ended (TabBar's Drag.onDragFinished, after the platform's drag loop returned).
    // `tornOff`: nothing took it and it ended outside every Files window, so the tab becomes a window (Finder). The move
    // waits for the event loop (Qt.callLater), when no handler of the drag is on the stack any more.
    function tabDragFinished(tornOff: bool): void {
        const tab = root.draggedTab;
        const drop = root.pendingTabDrop;
        root.draggedTab = null;
        root.pendingTabDrop = null;
        root.tabDragAreas = 0;
        if (drop)
            Qt.callLater(() => root.moveDroppedTab(drop.id, drop.target, drop.slot));
        else if (tornOff && tab)
            Qt.callLater(() => root.moveTabToNewWindow(tab));
    }

    // A dragged tab dropped on `target` at `slot` (-1: anywhere but its tab bar, or past the last tab): recorded while the
    // drag runs (see draggedTab), else moved at once.
    function dropTab(id: int, target: var, slot: int): void {
        if (root.draggedTab !== null) {
            root.pendingTabDrop = {id: id, target: target, slot: slot};
            return;
        }
        root.moveDroppedTab(id, target, slot);
    }

    function moveDroppedTab(id: int, target: var, slot: int): void {
        const tab = root.tabById(id);
        // The target window may have closed since the drop.
        if (!tab || !target || root.windows.indexOf(target) < 0)
            return;
        if (tab.win === target) {
            if (slot >= 0)
                target.moveTab(target.tabs.indexOf(tab), Math.min(slot, target.tabs.length - 1));
            return;
        }
        tab.win.detach(tab);
        target.adopt(tab, slot);
        target.requestActivate();
    }

    // Window > Merge All Windows: every other window's tabs join `target`'s, window by window, and those windows close.
    function mergeAllWindows(target: var): void {
        const others = root.windows.filter(w => w !== target);
        for (let i = 0; i < others.length; i++) {
            const tabs = others[i].tabs.slice();
            for (let j = 0; j < tabs.length; j++) {
                others[i].detach(tabs[j]);
                target.adopt(tabs[j], -1);
            }
        }
    }

    // File > Close All (Option-Cmd-W).
    function closeAllWindows(): void {
        const all = root.windows.slice();
        for (let i = 0; i < all.length; i++)
            all[i].close();
    }

    property Component infoComponent: Component {
        InfoWindow {}
    }

    // The Get Info window of one location, with the info of its row in the parent folder's listing (the same object a
    // browser window shows); a location its parent does not list (a root) shows the folder's own info.
    property Component infoRequest: Component {
        QtObject {
            id: request

            required property url target
            readonly property url parentUrl: {
                const s = request.target.toString().replace(/\/+$/, "");
                const cut = s.lastIndexOf("/");
                return Qt.url(cut > "file://".length ? s.substring(0, cut) : s);
            }
            property var model: null
            property int waited: 0

            function show(info: var): void {
                if (info && info.name !== undefined && root.infoComponent.createObject(root, {app: root.app, info: info, browser: null})) {
                    root.infoShown++;
                    console.info("grassfield-files: Get Info of", request.target, "(" + info.name + ")");
                } else {
                    console.warn("grassfield-files: no info for", request.target);
                }
                root.infoPending--;
                if (root.infoPending === 0 && root.infoShown === 0)
                    Qt.quit();
                request.destroy();
            }

            property Timer poll: Timer {
                interval: 50
                repeat: true
                running: true
                onTriggered: {
                    if (!request.model) {
                        request.model = root.app.createFolderModel(request);
                        request.model.url = request.parentUrl;
                        return;
                    }
                    request.waited += interval;
                    if (request.model.loading && request.waited < 5000)
                        return;
                    stop();
                    const row = request.model.rowForUrl(request.target);
                    if (row >= 0) {
                        request.show(request.model.info(row));
                        return;
                    }
                    request.model.url = request.target;
                    request.waited = 0;
                    request.fallback.start();
                }
            }

            property Timer fallback: Timer {
                interval: 50
                repeat: true
                onTriggered: {
                    request.waited += interval;
                    if (request.model.loading && request.waited < 5000)
                        return;
                    stop();
                    request.show(request.model.info(-1));
                }
            }
        }
    }

    Component.onCompleted: {
        const urls = root.app.initialUrls;
        if (root.infoOnly) {
            root.infoPending = urls.length;
            for (let i = 0; i < urls.length; i++)
                root.infoRequest.createObject(root, {target: urls[i]});
            if (urls.length === 0)
                Qt.quit();
            return;
        }
        if (urls.length === 0)
            root.newWindow(root.app.newWindowUrl, null);
        for (let i = 0; i < urls.length; i++)
            root.newWindow(urls[i], null);
    }
}
