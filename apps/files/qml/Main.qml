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

    property list<QtObject> resources: [
        Binding {
            target: Appearance
            property: "dark"
            value: root.app.dark
        },
        // App windows are opaque (master-prompt 5.5): menus drawn with the shared material too.
        Binding {
            target: Appearance
            property: "transparency"
            value: 0
        },
        // The window's own white background and secondary text (Appearance.windowSurface).
        Binding {
            target: Appearance
            property: "windowSurface"
            value: true
        },
        Binding {
            target: Appearance
            property: "reduceMotion"
            value: root.app.reduceMotion
        },
        // Accent colour (accent.color): live like the rest.
        Binding {
            target: Appearance
            property: "accentSetting"
            value: root.app.accentColor
        },
        // Menu shortcuts in the device's style (keyboard.shortcutStyle, owner decision 2026-10-26).
        Binding {
            target: Appearance
            property: "shortcutStyle"
            value: root.app.shortcutStyle
        },
        // Icon appearance (ADR-0014): file and app icons follow the shell live.
        Binding {
            target: Appearance
            property: "iconMode"
            value: root.app.iconMode
        },
        Binding {
            target: Appearance
            property: "iconTintSetting"
            value: root.app.iconTint
        },
        Binding {
            target: Appearance
            property: "folderColorSetting"
            value: root.app.folderColor
        }
    ]

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
        if (root.lastActiveWindow === win)
            root.lastActiveWindow = null;
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

    // A dragged tab dropped on `target` at `slot` (-1: anywhere but its tab bar, or past the last tab).
    function dropTab(id: int, target: var, slot: int): void {
        const tab = root.tabById(id);
        if (!tab || !target)
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
