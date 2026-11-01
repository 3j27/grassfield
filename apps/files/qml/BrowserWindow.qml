pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "TabsLogic.js" as TabsLogic

// A Files window: sidebar, toolbar (back/forward, title, view switcher, Action menu, search), tab bar
// (from two tabs), the current tab's view, path bar and status bar. Keyboard shortcuts follow the
// macOS file manager with Ctrl in place of Command.
Window {
    id: win

    required property var app
    // Main.qml: the windows, closed tabs and moves of tabs between windows.
    required property var manager
    required property url startUrl
    // A tab of another window that this window takes as its first tab (Move Tab to New Window, a tab dragged out).
    property var adoptTab: null
    // Every tab left for another window: closing then remembers no tab (Reopen Closed Tab).
    property bool emptied: false

    property var tabs: []
    property int currentIndex: 0
    readonly property var tab: win.tabs.length > 0 ? win.tabs[Math.min(win.currentIndex, win.tabs.length - 1)] : null
    readonly property var folder: win.tab ? win.tab.activeFolder : null
    readonly property alias menuLayer: menuLayer
    // Where this window's tabs live (Main.qml moves a tab into another window's host).
    readonly property alias tabHost: tabHost
    readonly property bool tabBarVisible: TabsLogic.barVisible(win.app.tabBarShown, win.tabs.length)
    // How far a preview pane's fill reaches up behind the toolbar (macOS 27: to the top of the window); not past the tab
    // bar or a banner.
    readonly property real previewExtension: win.tabBarVisible || banner.visible ? 0 : tabHost.y
    // The view switcher folds into its pop-up while the search field is open (Finder-Search), or where the whole switcher
    // would leave the title less than its room (measured with the whole switcher, so folding cannot unfold it again).
    readonly property bool compactViews: {
        if (searchCapsule.expanded)
            return true;
        const trailing = viewSwitcher.fullWidth + Tokens.filesGroupButtonWidth + actionButton.width + searchCapsule.width + 3 * Tokens.spacingSm;
        const room = toolbar.width - toolbar.titleStart - Tokens.windowItemsGap - trailing - Tokens.windowItemsInset;
        return room < Math.min(titleMetrics.advanceWidth, Tokens.filesToolbarTitleMinWidth);
    }
    property string notice: ""
    // ADR-0015: the window draws its own chrome; the apps' tagger (apps/windowchrome.h) names its role for the
    // compositor, whose plugin then draws no titlebar on it.
    property string gfChromeRole: "browser"
    property string bannerText: ""
    // The registrar is there: the window exports its menus to the global menu bar (GlobalMenu.qml).
    readonly property bool globalMenu: win.manager.globalMenu

    title: win.tab ? win.tab.title : qsTr("Files")
    width: Tokens.filesWindowWidth
    height: Tokens.filesWindowHeight
    minimumWidth: Tokens.filesWindowMinWidth
    minimumHeight: Tokens.filesWindowMinHeight
    color: Appearance.colors.windowBackground
    visible: true

    onClosing: {
        if (!win.emptied) {
            for (let i = 0; i < win.tabs.length; i++)
                win.manager.rememberClosedTab(win.tabs[i]);
        }
        win.keepSize();
        win.manager.forgetWindow(win);
        Qt.callLater(win.destroy);
    }

    Component.onCompleted: {
        win.manager.registerWindow(win);
        if (win.adoptTab)
            win.adopt(win.adoptTab, 0);
        else
            win.newTab(win.startUrl, null);
    }

    // The size of a window in its normal state is kept for the next window (ADR-0026 part 1); a zoomed or full-screen
    // size never is.
    function keepSize(): void {
        if (win.visibility === Window.Windowed)
            win.app.rememberWindowSize(win.width, win.height);
    }

    onWidthChanged: sizeTimer.restart()
    onHeightChanged: sizeTimer.restart()

    Timer {
        id: sizeTimer
        interval: Tokens.filesWindowSizeDelay
        onTriggered: win.keepSize()
    }

    // Tabs -----------------------------------------------------------------------------------

    // A new tab at the end of the bar (Finder); `restore`: a closed tab's snapshot (Reopen Closed Tab).
    function newTab(url: url, restore: var): void {
        const t = win.manager.tabComponent.createObject(tabHost, {app: win.app, win: win, startUrl: url, tabId: win.manager.nextTabId(), restore: restore ? restore : null});
        if (!t)
            return;
        const list = win.tabs.slice();
        list.push(t);
        win.tabs = list;
        win.currentIndex = list.length - 1;
        win.focusTabLater();
    }

    function focusTabLater(): void {
        Qt.callLater(() => {
            if (win.tab)
                win.tab.focusView();
        });
    }

    function closeTab(index: int): void {
        if (index < 0 || index >= win.tabs.length)
            return;
        if (win.tabs.length <= 1) {
            win.close();
            return;
        }
        const list = win.tabs.slice();
        const t = list.splice(index, 1)[0];
        win.manager.rememberClosedTab(t);
        win.currentIndex = TabsLogic.indexAfterClose(win.currentIndex, index, win.tabs.length);
        win.tabs = list;
        t.destroy();
        win.focusTabLater();
    }

    function closeOtherTabs(keep: var): void {
        const others = win.tabs.filter(t => t !== keep);
        for (let i = 0; i < others.length; i++)
            win.closeTab(win.tabs.indexOf(others[i]));
    }

    // A tab of another window (or of this one) placed at `index` (-1: the end) and shown.
    function adopt(tab: var, index: int): void {
        const list = win.tabs.filter(t => t !== tab);
        const at = index < 0 || index > list.length ? list.length : index;
        list.splice(at, 0, tab);
        win.app.reparent(tab, tabHost);
        tab.parent = tabHost;
        tab.win = win;
        win.tabs = list;
        win.currentIndex = at;
        win.focusTabLater();
    }

    // Takes `tab` out of this window without closing it (it moves to another window); the window closes when it was
    // the last one.
    function detach(tab: var): void {
        const index = win.tabs.indexOf(tab);
        if (index < 0)
            return;
        const list = win.tabs.slice();
        list.splice(index, 1);
        if (list.length === 0) {
            win.emptied = true;
            win.tabs = list;
            Qt.callLater(win.close);
            return;
        }
        win.currentIndex = TabsLogic.indexAfterClose(win.currentIndex, index, win.tabs.length);
        win.tabs = list;
    }

    // A tab dragged along this window's own bar.
    function moveTab(from: int, to: int): void {
        if (from < 0 || from >= win.tabs.length || from === to)
            return;
        const current = win.tab;
        win.tabs = TabsLogic.moved(win.tabs, from, to);
        win.currentIndex = Math.max(0, win.tabs.indexOf(current));
    }

    function selectTab(index: int): void {
        if (win.tabs.length === 0)
            return;
        win.currentIndex = (index + win.tabs.length) % win.tabs.length;
        win.tab.focusView();
    }

    // Dialogs --------------------------------------------------------------------------------

    Component {
        id: infoComponent
        InfoWindow {}
    }

    Component {
        id: customizeComponent
        CustomizeFolderWindow {}
    }

    // The windows this window opened for itself and that are still open (Get Info, Customize Folder): its transient
    // children, placed and stacked with it and closed with it.
    property var ownWindows: []
    // One of them is the key window (FilesApp.focusWindow; never `active`: Qt reports a window and its transient children
    // active together, whichever has the keyboard). Qt still counts this window as active then, and the shortcut matcher
    // of QtQuick.Templates, loaded with Grassfield.Ui's controls (GF-085), matches this window's Shortcuts and its global
    // menu's keys on that ground: Ctrl+W typed in Get Info closed this window, and Get Info with it. A key belongs to the
    // key window alone (macOS), so this window's keys wait meanwhile (and those windows' own keys wait while this one is
    // the key window: InfoWindow, CustomizeFolderWindow).
    readonly property bool childIsKey: win.app.focusWindow !== null && win.app.focusWindow !== undefined && win.ownWindows.indexOf(win.app.focusWindow) >= 0

    function openOwnWindow(component: Component, props: var): var {
        const w = component.createObject(win, Object.assign({transientParent: win}, props));
        if (w) {
            win.ownWindows = win.ownWindows.concat([w]);
            w.closing.connect(() => win.ownWindows = win.ownWindows.filter(o => o !== w));
        }
        return w;
    }

    // Customize Folder for local folder URLs (a window per request, like Get Info).
    function customizeFolders(urls: var, name: string, iconName: string): void {
        if (urls && urls.length > 0)
            win.openOwnWindow(customizeComponent, {app: win.app, urls: urls, folderName: name, iconName: iconName});
    }

    function showInfo(info: var): void {
        if (info && info.name !== undefined)
            win.openOwnWindow(infoComponent, {app: win.app, info: info, browser: win});
    }

    function confirm(title: string, message: string, confirmText: string, action: var): void {
        confirmSheet.title = title;
        confirmSheet.message = message;
        confirmSheet.confirmText = confirmText;
        confirmSheet.confirmHandler = () => {
            action();
            return "";
        };
        confirmSheet.focusBack = win.tab ? win.tab.view : null;
        confirmSheet.open();
    }

    function goToFolder(): void {
        goSheet.focusBack = win.tab ? win.tab.view : null;
        goSheet.open();
    }

    function goToStandardFolder(which: string): void {
        const url = win.app.standardFolder(which);
        if (String(url) !== "")
            win.tab.navigate(url, true);
    }

    // Go > Connect to Server… (FP-77): its own window, one per browser window, connected to this window's tab.
    property var connectWindow: null
    function connectToServer(): void {
        if (!win.connectWindow) {
            win.connectWindow = connectComponent.createObject(win, {app: win.app, browser: win});
            if (!win.connectWindow) {
                console.warn("grassfield-files: cannot create Connect to Server:", connectComponent.errorString());
                return;
            }
        }
        win.connectWindow.show();
        win.connectWindow.raise();
        win.connectWindow.requestActivate();
    }

    Component {
        id: connectComponent
        ConnectWindow {}
    }

    // File > New Smart Folder (Finder): a new window on an empty search of this computer, the + ready for its rules.
    function newSmartFolder(): void {
        win.manager.newWindow(win.app.searchUrl({text: "", folder: "", criteria: []}), null);
    }

    function focusSearch(): void {
        searchCapsule.focusField();
    }

    // A place of the sidebar (Go menu): opened like a sidebar click.
    function openPlace(row: int, url: url, mounted: bool): void {
        sidebar.openRow(row, url, mounted);
    }

    function showNotice(text: string): void {
        win.notice = text;
        noticeTimer.restart();
    }

    function showBanner(text: string): void {
        win.bannerText = text;
        bannerTimer.restart();
    }

    Timer {
        id: noticeTimer
        interval: Tokens.filesNoticeTimeout
        onTriggered: win.notice = ""
    }

    Timer {
        id: bannerTimer
        interval: Tokens.filesBannerTimeout
        onTriggered: win.bannerText = ""
    }

    // App-wide errors show in the window the user last worked in: an action chosen in the global menu runs while the
    // shell's menu holds the keyboard, so no window is active at that moment.
    onActiveChanged: {
        if (win.active)
            win.manager.lastActiveWindow = win;
    }

    Connections {
        target: win.app
        function onOperationFailed(message: string): void {
            // Or the window under the Choose Application panel the user works in (Main.qml; review of step 5c, MINOR 1).
            const last = win.manager.lastActiveWindow;
            if (win.active || last === win || (last && last.transientParent === win))
                win.showBanner(message);
        }
    }

    // Global menu (T1) ------------------------------------------------------------------------

    Loader {
        active: win.globalMenu
        sourceComponent: GlobalMenu {
            win: win
        }
        // One log line per change (tests/apps/files_registrar.sh reads them: the menu bar exists only while the
        // registrar does).
        onItemChanged: console.info("grassfield: global menu " + (item ? "created" : "destroyed"))
    }

    // Shortcuts ------------------------------------------------------------------------------
    // Every key here except Delete is also the shortcut of a global menu item (GlobalMenu.qml): Qt then hands each
    // press to one of the two, so a Shortcut acts on activatedAmbiguously exactly as on activated. None is live while one
    // of this window's own windows is the key window (childIsKey): that window's keys are its own.

    Shortcut {
        sequence: "Ctrl+T"
        enabled: !win.childIsKey
        onActivated: win.newTab(win.app.newWindowUrl, null)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+W"
        enabled: !win.childIsKey
        onActivated: win.closeTab(win.currentIndex)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+W"
        enabled: !win.childIsKey
        onActivated: win.close()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Alt+W"
        enabled: !win.childIsKey
        onActivated: win.manager.closeAllWindows()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+N"
        enabled: !win.childIsKey
        onActivated: win.manager.newWindow(win.app.newWindowUrl, null)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+T"
        enabled: !win.childIsKey && win.tabs.length <= 1
        onActivated: win.app.tabBarShown = !win.app.tabBarShown
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Alt+Shift+T"
        enabled: !win.childIsKey && win.manager.closedTabs.length > 0
        onActivated: win.manager.reopenClosedTab(win)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Tab", "Ctrl+Shift+]"]
        enabled: !win.childIsKey
        onActivated: win.selectTab(win.currentIndex + 1)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Shift+Tab", "Ctrl+Shift+["]
        enabled: !win.childIsKey
        onActivated: win.selectTab(win.currentIndex - 1)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+[", "Alt+Left"]
        enabled: !win.childIsKey
        onActivated: win.tab.back()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+]", "Alt+Right"]
        enabled: !win.childIsKey
        onActivated: win.tab.forward()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Up", "Alt+Up"]
        enabled: !win.childIsKey
        onActivated: win.tab.up()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+O", "Ctrl+Down", "Alt+Down"]
        enabled: !win.childIsKey
        onActivated: win.tab.openSelection()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Backspace"
        enabled: !win.childIsKey
        onActivated: win.tab.trashSelection()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Delete"
        enabled: !win.childIsKey
        onActivated: {
            if (!win.folder.isTrash)
                win.tab.trashSelection();
        }
    }
    Shortcut {
        sequence: "F2"
        enabled: !win.childIsKey
        onActivated: win.tab.renameSelection()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+C"
        enabled: !win.childIsKey
        onActivated: win.tab.copySelection(false)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+X"
        enabled: !win.childIsKey
        onActivated: win.tab.copySelection(true)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+V"
        enabled: !win.childIsKey
        onActivated: win.tab.paste()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+A"
        enabled: !win.childIsKey
        onActivated: win.folder.selectAll()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+D"
        enabled: !win.childIsKey
        onActivated: win.tab.duplicateSelection()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+I"
        enabled: !win.childIsKey
        onActivated: win.tab.getInfo()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+N"
        enabled: !win.childIsKey
        onActivated: win.tab.newFolder()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Z"
        enabled: !win.childIsKey && win.app.canUndo
        onActivated: win.app.undo()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        // Shift+Cmd+Z only: Cmd+Y is Glance (Finder's Quick Look).
        sequence: "Ctrl+Shift+Z"
        enabled: !win.childIsKey && win.app.canRedo
        onActivated: win.app.redo()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Alt+N"
        enabled: !win.childIsKey
        onActivated: win.newSmartFolder()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+F"
        enabled: !win.childIsKey
        onActivated: searchCapsule.focusField()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+H"
        enabled: !win.childIsKey
        onActivated: win.app.showHidden = !win.app.showHidden
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Shift+G", "Ctrl+L"]
        enabled: !win.childIsKey
        onActivated: win.goToFolder()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+H"
        enabled: !win.childIsKey
        onActivated: win.tab.navigate(Qt.url("file://" + win.app.homePath), true)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+A"
        enabled: !win.childIsKey
        onActivated: win.tab.navigate(win.app.applicationsUrl(), true)
        onActivatedAmbiguously: activated()
    }
    // The Go menu's places (Finder): Desktop, Documents, Downloads, Computer, Network (decision F-1: no Utilities folder).
    Instantiator {
        model: [{keys: "Ctrl+Shift+D", place: "desktop"}, {keys: "Ctrl+Shift+O", place: "documents"}, {keys: "Ctrl+Alt+L", place: "downloads"},
                {keys: "Ctrl+Shift+C", place: "computer"}, {keys: "Ctrl+Shift+K", place: "network"}]

        delegate: Shortcut {
            required property var modelData
            sequence: modelData.keys
            enabled: !win.childIsKey && win.tab !== null
            onActivated: win.goToStandardFolder(modelData.place)
            onActivatedAmbiguously: activated()
        }
    }
    // Show Hidden Files (Finder's Shift+Cmd+.; Ctrl+H stays for the PC habit).
    Shortcut {
        // Shift+. types ">" on most layouts: both spellings, as the Open and Save panels (FilePanel.qml).
        sequences: ["Ctrl+Shift+.", "Ctrl+>"]
        enabled: !win.childIsKey
        onActivated: win.app.showHidden = !win.app.showHidden
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+K"
        enabled: !win.childIsKey
        onActivated: win.connectToServer()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+R", "F5"]
        enabled: !win.childIsKey
        onActivated: win.tab.folder.reload()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+1"
        enabled: !win.childIsKey
        onActivated: win.tab.setViewModeByNumber(1)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+2"
        enabled: !win.childIsKey
        onActivated: win.tab.setViewModeByNumber(2)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+3"
        enabled: !win.childIsKey
        onActivated: win.tab.setViewModeByNumber(3)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+4"
        enabled: !win.childIsKey
        onActivated: win.tab.setViewModeByNumber(4)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Alt+P"
        enabled: !win.childIsKey
        onActivated: win.app.pathBarShown = !win.app.pathBarShown
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+/"
        enabled: !win.childIsKey
        onActivated: win.app.statusBarShown = !win.app.statusBarShown
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Y"
        enabled: !win.childIsKey
        onActivated: win.tab.glance()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+F"
        enabled: !win.childIsKey
        onActivated: win.tab.navigate(win.app.recentsUrl(), true)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Meta+0"
        enabled: !win.childIsKey
        onActivated: win.tab.toggleGroups()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Meta+S"
        enabled: !win.childIsKey
        onActivated: win.app.sidebarShown = !win.app.sidebarShown
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+P"
        enabled: !win.childIsKey
        onActivated: win.tab.togglePreview()
        onActivatedAmbiguously: activated()
    }

    // Layout ---------------------------------------------------------------------------------

    // File > Eject (Ctrl+E): the volume the sidebar points at (Sidebar.ejectRow).
    readonly property bool canEject: sidebar.ejectRow >= 0

    function ejectVolume(): bool {
        return sidebar.eject();
    }

    Shortcut {
        sequence: "Ctrl+E"
        enabled: !win.childIsKey && win.canEject
        onActivated: win.ejectVolume()
        onActivatedAmbiguously: activated()
    }

    // A dragged tab anywhere over the window (under every other drop target): over its own window nothing happens (the
    // drag is not a tear-off); over another window the tab moves there, last (Main.qml dropTab).
    DropArea {
        anchors.fill: parent
        keys: [TabsLogic.tabMimeType]
        onEntered: win.manager.tabDragAreas++
        onExited: win.manager.tabDragAreas = Math.max(0, win.manager.tabDragAreas - 1)
        onDropped: drop => {
            const id = TabsLogic.tabIdFrom(drop.getDataAsString(TabsLogic.tabMimeType), win.app.processId);
            if (id >= 0)
                win.manager.dropTab(id, win, -1);
            drop.accept(Qt.MoveAction);
        }
    }

    // Right-click or Cmd-click on the title: the enclosing folders, the shown one first (Finder's title menu).
    function titleMenu(x: real, y: real): void {
        const segments = win.tab ? win.tab.segments : [];
        const items = [];
        for (let i = segments.length - 1; i >= 0; i--)
            items.push({id: String(i), text: DisplayName.text(segments[i].label), iconName: "folder"});
        if (items.length > 0)
            win.menuLayer.open(items, x, y, id => win.tab.navigate(segments[parseInt(id)].url, true), win.tab.view, false);
    }

    // View > Hide Sidebar (Ctrl+Cmd+S): the lights move into the toolbar (macOS).
    Sidebar {
        id: sidebar
        visible: win.app.sidebarShown
        width: visible ? Tokens.filesSidebarWidth : 0
        height: parent.height
        app: win.app
        tab: win.tab
        topInset: sidebarToolbar.height
    }

    // The window lights in the corner of the sidebar (ADR-0015); the toolbar over the content holds the title.
    UnifiedToolbar {
        id: sidebarToolbar
        visible: sidebar.visible
        width: sidebar.width
        window: win
        showTitle: false
        doubleClickAction: win.app.titlebarDoubleClick
        canMinimize: win.app.canMinimize
    }

    Item {
        id: main
        x: sidebar.width
        width: parent.width - x
        height: parent.height

        // Toolbar: the title and the app's items in the unified toolbar of grassfield-ui (ADR-0015); the lights are in the
        // sidebar's corner (sidebarToolbar above).
        UnifiedToolbar {
            id: toolbar
            // Over the tab's content: a preview pane's fill runs up behind it (previewExtension).
            z: 1
            width: parent.width
            window: win
            showControls: !sidebar.visible
            title: win.title
            doubleClickAction: win.app.titlebarDoubleClick
            canMinimize: win.app.canMinimize

            TextMetrics {
                id: titleMetrics
                text: win.title
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.windowTitleSize
                font.weight: Tokens.typographyMenuBoldWeight
            }

            // Over the title only: a plain press still moves the window (the toolbar's drag area below).
            MouseArea {
                x: toolbar.titleStart
                width: Math.max(0, Math.min(titleMetrics.advanceWidth, toolbar.titleEnd - toolbar.titleStart))
                height: parent.height
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: mouse => {
                    if (mouse.button === Qt.RightButton || (mouse.modifiers & Qt.ControlModifier)) {
                        const p = mapToItem(null, 0, height - Tokens.spacingSm);
                        win.titleMenu(p.x, p.y);
                        return;
                    }
                    mouse.accepted = false;
                }
            }

            // Back and forward: one 72 x 36 capsule (macOS).
            leading: NavCapsule {
                tab: win.tab
            }

            trailing: Row {
                id: tools
                spacing: Tokens.spacingSm

                ViewSwitcher {
                    id: viewSwitcher
                    anchors.verticalCenter: parent.verticalCenter
                    tab: win.tab
                    compact: win.compactViews
                    menuLayer: win.menuLayer
                }

                // Group By (Finder): a capsule with the groups glyph and a chevron; its menu groups and sorts the folder.
                Rectangle {
                    width: Tokens.filesGroupButtonWidth
                    height: Tokens.filesToolbarCapsule
                    radius: height / 2
                    color: Appearance.buttonFill
                    anchors.verticalCenter: parent.verticalCenter

                    ToolButton {
                        id: groupButton
                        anchors.fill: parent
                        capsule: true
                        buttonSize: Tokens.filesToolbarCapsule
                        enabled: win.tab !== null && win.tab.groupsShown
                        accessibleName: qsTr("Group By")
                        onClicked: {
                            const p = groupButton.mapToItem(null, 0, groupButton.height + Tokens.spacingXs);
                            const items = win.tab.groupSubmenu().submenu.concat([{separator: true}, win.tab.sortSubmenu()]);
                            win.menuLayer.open(items, p.x, p.y, id => win.tab.runAction(id, win.folder), win.tab.view, false);
                        }

                        Item {
                            width: groupButton.width
                            height: groupButton.height

                            ViewGlyph {
                                x: Tokens.filesGroupButtonInset
                                anchors.verticalCenter: parent.verticalCenter
                                size: Tokens.filesGroupGlyphWidth
                                kind: "group"
                                color: groupButton.foreground
                            }

                            Icon {
                                x: Tokens.filesGroupButtonInset + Tokens.filesGroupGlyphWidth + Tokens.filesGroupChevronGap
                                anchors.verticalCenter: parent.verticalCenter
                                name: "chevron-down"
                                size: Tokens.filesGroupChevronSize
                                color: groupButton.foreground
                            }
                        }
                    }
                }

                ToolButton {
                    id: actionButton
                    accessibleName: qsTr("Action")
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: {
                        const p = actionButton.mapToItem(null, 0, actionButton.height + Tokens.spacingXs);
                        win.menuLayer.open(win.tab.actionMenu(), p.x, p.y, id => win.tab.runAction(id, win.folder), win.tab.view, false);
                    }

                    ViewGlyph {
                        anchors.centerIn: parent
                        kind: "more"
                    }
                }

                // Search field (ADR-0027): while a search is shown it takes the toolbar's free width, the title keeping its
                // own (Finder-Search, FP-22).
                SearchCapsule {
                    id: searchCapsule
                    anchors.verticalCenter: parent.verticalCenter
                    tab: win.tab
                    expandedWidth: {
                        if (!win.tab || !win.tab.fileSearch)
                            return Tokens.filesSearchWidth;
                        const others = Tokens.filesViewPopupWidth + Tokens.filesGroupButtonWidth + actionButton.width + 3 * Tokens.spacingSm;
                        const title = Math.min(titleMetrics.advanceWidth, Math.max(Tokens.filesToolbarTitleMinWidth, toolbar.width / 3));
                        const room = toolbar.width - toolbar.titleStart - title - Tokens.windowItemsGap - others - Tokens.windowItemsInset;
                        return Math.max(Tokens.filesSearchWidth, Math.floor(room));
                    }
                }
            }
        }

        // Tab bar (from two tabs on, or always with View > Show Tab Bar)
        TabBar {
            id: tabBar
            anchors.top: toolbar.bottom
            width: parent.width
            height: win.tabBarVisible ? implicitHeight : 0
            visible: win.tabBarVisible
            win: win
        }

        Rectangle {
            id: toolbarRule
            anchors.top: tabBar.bottom
            width: parent.width
            height: Tokens.appsBorderWidth
            // A search's scope bar draws its own hairline below; none between it and the toolbar (Finder-Search).
            opacity: win.tabBarVisible || (win.tab !== null && win.tab.scrolled && !scopeBar.visible) ? 1 : 0
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        // A search location's scope and filter rows (ADR-0027).
        ScopeBar {
            id: scopeBar
            anchors.top: toolbarRule.bottom
            width: parent.width
            height: implicitHeight
            app: win.app
            tab: win.tab
            onSaveRequested: win.openSaveSearch()
        }

        // Error banner
        Rectangle {
            id: banner
            anchors.top: scopeBar.bottom
            anchors.topMargin: visible ? Tokens.spacingSm : 0
            x: Tokens.spacingMd
            width: parent.width - 2 * Tokens.spacingMd
            readonly property string text: win.bannerText !== "" ? win.bannerText : win.folder && win.folder.error !== "" && win.folder.count > 0 ? win.folder.error : ""
            visible: banner.text !== ""
            height: visible ? bannerLabel.implicitHeight + 2 * Tokens.spacingSm : 0
            radius: Tokens.radiusMenu
            // Destructive colour, like the Settings refusal banner.
            color: Appearance.colors.destructive
            Accessible.role: Accessible.AlertMessage
            Accessible.name: banner.text

            Text {
                id: bannerLabel
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: bannerClose.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.spacingSm
                text: banner.text
                wrapMode: Text.Wrap
                color: Appearance.colors.destructiveText
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }

            ToolButton {
                id: bannerClose
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconName: "close-glyph"
                tint: Appearance.colors.destructiveText
                accessibleName: qsTr("Dismiss")
                onClicked: win.bannerText = ""
            }
        }

        Item {
            id: tabHost
            anchors.top: banner.bottom
            anchors.bottom: pathBar.top
            width: parent.width

            // Only the current tab is shown; the others keep their state.
            property var currentTab: win.tab
            onChildrenChanged: tabHost.layoutTabs()
            onCurrentTabChanged: tabHost.layoutTabs()
            function layoutTabs(): void {
                for (let i = 0; i < tabHost.children.length; i++) {
                    const t = tabHost.children[i];
                    t.anchors.fill = tabHost;
                    t.visible = t === tabHost.currentTab;
                    t.focus = t === tabHost.currentTab;
                }
            }
        }

        // View > Show Path Bar / Show Status Bar: hidden by default (decision F-11). Until Files has a progress window
        // (FP-68) the status bar also shows while a job runs or a notice is up, so that feedback is never lost.
        PathBar {
            id: pathBar
            anchors.bottom: statusBar.top
            // A search shows the selected result's path (Finder-Search, FP-74) whatever View > Show Path Bar says.
            visible: win.app.pathBarShown || (win.tab !== null && win.tab.fileSearch)
            width: parent.width
            height: visible ? Tokens.filesPathBarHeight : 0
            tab: win.tab
        }

        // Status bar
        Item {
            id: statusBar
            anchors.bottom: parent.bottom
            visible: win.app.statusBarShown || win.notice !== "" || win.app.activity !== ""
            width: parent.width
            height: visible ? Tokens.filesStatusBarHeight : 0
            Accessible.role: Accessible.StatusBar
            Accessible.name: statusText.text

            Rectangle {
                width: parent.width
                height: Tokens.appsBorderWidth
                color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }

            Text {
                id: statusText
                textFormat: Text.PlainText
                anchors.centerIn: parent
                width: parent.width - 2 * Tokens.spacingMd
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                text: {
                    if (win.notice !== "")
                        return win.notice;
                    if (win.app.activity !== "")
                        return win.app.activityPercent >= 0 ? qsTr("%1 %2%").arg(win.app.activity).arg(win.app.activityPercent) : win.app.activity;
                    const f = win.folder;
                    if (!f)
                        return "";
                    if (f.loading && f.count === 0)
                        return f.isSearch ? qsTr("Searching…") : qsTr("Loading…");
                    const total = f.count === 1 ? qsTr("1 item") : qsTr("%1 items").arg(f.count);
                    const items = f.selectedCount > 0 ? qsTr("%1 of %2 selected").arg(f.selectedCount).arg(total) : total;
                    // A search: still running, or stopped by its bounds (TagSearch, FileSearch) before it saw everything.
                    if (f.isSearch && f.loading)
                        return qsTr("%1, searching…").arg(items);
                    if (f.isFileSearch && f.searchContentsUnavailable)
                        return qsTr("Contents can’t be searched: the search index (localsearch) isn’t available.");
                    if (f.isFileSearch && f.searchLimited)
                        return qsTr("%1 (the search stopped early: add words or rules to narrow it)").arg(items);
                    if (f.isSearch && f.searchLimited)
                        return qsTr("%1 (the search stopped early: the folder holds too many items)").arg(items);
                    return f.freeSpace >= 0 ? qsTr("%1, %2 available").arg(items).arg(win.app.formatSize(f.freeSpace)) : items;
                }
            }
        }
    }

    GoToFolderPanel {
        id: goSheet
        app: win.app
        tab: win.tab
    }

    Sheet {
        id: confirmSheet
        destructive: true
    }

    // Save (the scope bar): a name and Add To Sidebar (the Finder's Save sheet; its Where pop-up has one place here, the
    // saved searches folder, so it is not shown). A name in use asks once; saving it again replaces that search.
    function openSaveSearch(): void {
        if (!win.tab || !win.tab.fileSearch)
            return;
        saveSheet.replacing = "";
        saveSheet.setField(win.tab.savedSearch ? win.tab.savedSearch.name : (win.tab.searchText.trim() !== "" ? win.tab.searchText.trim() : qsTr("Untitled Search")));
        sidebarCheck.checked = win.tab.savedSearch ? win.tab.savedSearch.sidebar : true;
        saveSheet.open();
    }

    Sheet {
        id: saveSheet
        property string replacing: ""
        title: qsTr("Save Search")
        withField: true
        placeholder: qsTr("Name")
        confirmText: qsTr("Save")
        focusBack: win.tab ? win.tab.view : null
        confirmHandler: text => {
            const name = text.trim();
            if (name === "")
                return qsTr("A saved search needs a name.");
            const own = win.tab.savedSearch && win.tab.savedSearch.name === name;
            if (!own && win.app.hasSavedSearch(name) && saveSheet.replacing !== name) {
                saveSheet.replacing = name;
                return qsTr("A saved search named “%1” already exists. Save again to replace it.").arg(name);
            }
            return win.app.saveSearch(name, win.tab.url, sidebarCheck.checked);
        }

        CheckBox {
            id: sidebarCheck
            text: qsTr("Add To Sidebar")
            accessibleName: text
        }
    }

    // KIO's questions (a name that exists, a certificate…), in the window Main.qml places them in. One sheet at a time, as
    // AppKit queues a window's sheets and holds them while a menu is open: a question waits while Go to Folder, a
    // confirmation or a menu is open, and comes after.
    KioSheets {
        prompts: win.app.prompts ?? null
        shown: win.manager.promptWindow === win && !goSheet.shown && !confirmSheet.shown && !saveSheet.shown && !menuLayer.visible
        focusBack: win.tab ? win.tab.view : null
    }

    MenuLayer {
        id: menuLayer
    }
}
