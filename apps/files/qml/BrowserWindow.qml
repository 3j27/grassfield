pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// A Files window: sidebar, toolbar (back/forward, title, view switcher, Action menu, search), tab bar
// (from two tabs), the current tab's view, path bar and status bar. Keyboard shortcuts follow the
// macOS file manager with Ctrl in place of Command.
Window {
    id: win

    required property var app
    // Main.qml: newWindow(url).
    required property var manager
    required property url startUrl

    property var tabs: []
    property int currentIndex: 0
    readonly property var tab: win.tabs.length > 0 ? win.tabs[Math.min(win.currentIndex, win.tabs.length - 1)] : null
    readonly property var folder: win.tab ? win.tab.activeFolder : null
    readonly property alias menuLayer: menuLayer
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
    color: Appearance.colors.materialTint
    visible: true

    onClosing: Qt.callLater(win.destroy)

    Component.onCompleted: win.newTab(win.startUrl)

    // Tabs -----------------------------------------------------------------------------------

    Component {
        id: tabComponent
        BrowserTab {}
    }

    function newTab(url: url): void {
        const t = tabComponent.createObject(tabHost, {app: win.app, win: win, startUrl: url});
        if (!t)
            return;
        const list = win.tabs.slice();
        list.push(t);
        win.tabs = list;
        win.currentIndex = list.length - 1;
        Qt.callLater(() => {
            if (win.tab)
                win.tab.focusView();
        });
    }

    function closeTab(index: int): void {
        if (win.tabs.length <= 1) {
            win.close();
            return;
        }
        const list = win.tabs.slice();
        const t = list.splice(index, 1)[0];
        win.tabs = list;
        win.currentIndex = Math.min(win.currentIndex >= index && win.currentIndex > 0 ? win.currentIndex - 1 : win.currentIndex, list.length - 1);
        t.destroy();
        Qt.callLater(() => {
            if (win.tab)
                win.tab.focusView();
        });
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

    // Customize Folder for local folder URLs (a window per request, like Get Info).
    function customizeFolders(urls: var, name: string, iconName: string): void {
        if (urls && urls.length > 0)
            customizeComponent.createObject(win, {app: win.app, urls: urls, folderName: name, iconName: iconName, transientParent: win});
    }

    function showInfo(info: var): void {
        if (info && info.name !== undefined)
            infoComponent.createObject(win, {app: win.app, info: info, browser: win, transientParent: win});
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
        goSheet.setField("");
        goSheet.open();
    }

    function focusSearch(): void {
        search.forceActiveFocus();
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
            if (win.active || win.manager.lastActiveWindow === win)
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
    // press to one of the two, so a Shortcut acts on activatedAmbiguously exactly as on activated.

    Shortcut {
        sequence: "Ctrl+T"
        onActivated: win.newTab(win.tab ? win.tab.url : win.startUrl)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+W"
        onActivated: win.closeTab(win.currentIndex)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+N"
        onActivated: win.manager.newWindow(win.tab ? win.tab.url : win.startUrl)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Tab", "Ctrl+Shift+]"]
        onActivated: win.selectTab(win.currentIndex + 1)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Shift+Tab", "Ctrl+Shift+["]
        onActivated: win.selectTab(win.currentIndex - 1)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+[", "Alt+Left"]
        onActivated: win.tab.back()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+]", "Alt+Right"]
        onActivated: win.tab.forward()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Up", "Alt+Up"]
        onActivated: win.tab.up()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Down", "Alt+Down"]
        onActivated: win.tab.openSelection()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Backspace"
        onActivated: win.tab.trashSelection()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Delete"
        onActivated: {
            if (!win.folder.isTrash)
                win.tab.trashSelection();
        }
    }
    Shortcut {
        sequence: "F2"
        onActivated: win.tab.renameSelection()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+C"
        onActivated: win.tab.copySelection(false)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+X"
        onActivated: win.tab.copySelection(true)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+V"
        onActivated: win.tab.paste()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+A"
        onActivated: win.folder.selectAll()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+D"
        onActivated: win.tab.duplicateSelection()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+I"
        onActivated: win.tab.getInfo()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+N"
        onActivated: win.tab.newFolder()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Z"
        enabled: win.app.canUndo
        onActivated: win.app.undo()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]
        enabled: win.app.canRedo
        onActivated: win.app.redo()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+F"
        onActivated: search.forceActiveFocus()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+H"
        onActivated: win.app.showHidden = !win.app.showHidden
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+Shift+G", "Ctrl+L"]
        onActivated: win.goToFolder()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+H"
        onActivated: win.tab.navigate(Qt.url("file://" + win.app.homePath), true)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequences: ["Ctrl+R", "F5"]
        onActivated: win.tab.folder.reload()
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+1"
        onActivated: win.tab.setViewModeByNumber(1)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+2"
        onActivated: win.tab.setViewModeByNumber(2)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+3"
        onActivated: win.tab.setViewModeByNumber(3)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+4"
        onActivated: win.tab.setViewModeByNumber(4)
        onActivatedAmbiguously: activated()
    }
    Shortcut {
        sequence: "Ctrl+Shift+P"
        onActivated: win.tab.toggleGalleryInfo()
        onActivatedAmbiguously: activated()
    }

    // Layout ---------------------------------------------------------------------------------

    Sidebar {
        id: sidebar
        width: Tokens.filesSidebarWidth
        height: parent.height
        app: win.app
        tab: win.tab
        topInset: sidebarToolbar.height
    }

    // The window lights in the corner of the sidebar (ADR-0015); the toolbar over the content holds the title.
    UnifiedToolbar {
        id: sidebarToolbar
        width: sidebar.width
        window: win
        showTitle: false
        doubleClickAction: win.app.titlebarDoubleClick
        canMinimize: win.app.canMinimize
    }

    Item {
        id: main
        x: sidebar.width
        width: parent.width - sidebar.width
        height: parent.height

        // Toolbar: the title and the app's items in the unified toolbar of grassfield-ui (ADR-0015); the lights are in the
        // sidebar's corner (sidebarToolbar above).
        UnifiedToolbar {
            id: toolbar
            width: parent.width
            window: win
            showControls: false
            title: win.title
            doubleClickAction: win.app.titlebarDoubleClick
            canMinimize: win.app.canMinimize

            leading: Row {
                id: navButtons
                spacing: Tokens.spacingXs / 2

                ToolButton {
                    iconName: "chevron-right"
                    iconRotation: 180
                    enabled: win.tab !== null && win.tab.canBack
                    accessibleName: qsTr("Back")
                    onClicked: win.tab.back()
                }

                ToolButton {
                    iconName: "chevron-right"
                    enabled: win.tab !== null && win.tab.canForward
                    accessibleName: qsTr("Forward")
                    onClicked: win.tab.forward()
                }
            }

            trailing: Row {
                id: tools
                spacing: Tokens.spacingSm

                // View switcher (segmented)
                Rectangle {
                    width: viewRow.width + Tokens.spacingXs
                    height: Tokens.filesToolbarButtonSize + Tokens.spacingXs
                    radius: Tokens.radiusControl + Tokens.spacingXs / 2
                    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.filesStripeOpacity * 2)
                    anchors.verticalCenter: parent.verticalCenter
                    Accessible.role: Accessible.Grouping
                    Accessible.name: qsTr("View")

                    Row {
                        id: viewRow
                        anchors.centerIn: parent

                        Repeater {
                            model: [
                                {mode: "icons", name: qsTr("as Icons")},
                                {mode: "list", name: qsTr("as List")},
                                {mode: "columns", name: qsTr("as Columns")},
                                {mode: "gallery", name: qsTr("as Gallery")}
                            ]
                            delegate: ToolButton {
                                required property var modelData
                                glyph: modelData.mode
                                checkable: true
                                checked: win.tab !== null && win.tab.viewMode === modelData.mode
                                accessibleName: modelData.name
                                onClicked: win.tab.setViewMode(modelData.mode)
                            }
                        }
                    }
                }

                ToolButton {
                    id: actionButton
                    glyph: "more"
                    accessibleName: qsTr("Action")
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: {
                        const p = actionButton.mapToItem(null, 0, actionButton.height + Tokens.spacingXs);
                        win.menuLayer.open(win.tab.actionMenu(), p.x, p.y, id => win.tab.runAction(id, win.folder), win.tab.view, false);
                    }
                }

                // Search field (filters the current folder)
                Rectangle {
                    width: Tokens.filesSearchWidth
                    height: Tokens.filesToolbarButtonSize
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Tokens.radiusControl
                    color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                    border.width: search.activeFocus ? Tokens.controlFocusOutline : 0
                    border.color: Appearance.focusRingColor

                    Icon {
                        id: searchIcon
                        name: "search"
                        size: Tokens.menuIconSize
                        color: Appearance.colors.textSecondary
                        x: Tokens.spacingSm
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    TextInput {
                        id: search
                        TextCursor {}
                        anchors.left: searchIcon.right
                        anchors.leftMargin: Tokens.spacingXs
                        anchors.right: parent.right
                        anchors.rightMargin: Tokens.spacingSm
                        anchors.verticalCenter: parent.verticalCenter
                        clip: true
                        activeFocusOnTab: true
                        color: Appearance.colors.text
                        selectionColor: Appearance.colors.accent
                        selectedTextColor: Appearance.colors.accentText
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        text: win.tab ? win.tab.searchText : ""
                        onTextEdited: win.tab.setSearch(text)
                        Accessible.role: Accessible.EditableText
                        Accessible.name: qsTr("Search in this folder")
                        Accessible.searchEdit: true

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) {
                                win.tab.setSearch("");
                                win.tab.focusView();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                if (win.folder.count > 0 && win.folder.selectedCount === 0)
                                    win.folder.select(0, 0);
                                win.tab.focusView();
                                event.accepted = true;
                            }
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.verticalCenter: parent.verticalCenter
                            visible: search.text === ""
                            text: qsTr("Search")
                            color: Appearance.colors.textSecondary
                            font: search.font
                        }
                    }
                }
            }
        }

        // Tab bar (from two tabs on)
        Row {
            id: tabBar
            anchors.top: toolbar.bottom
            width: parent.width
            height: win.tabs.length > 1 ? Tokens.filesTabHeight : 0
            visible: win.tabs.length > 1
            Accessible.role: Accessible.PageTabList
            Accessible.name: qsTr("Tabs")

            Repeater {
                model: win.tabs

                delegate: Item {
                    id: tabItem
                    required property var modelData
                    required property int index
                    readonly property bool current: tabItem.index === win.currentIndex

                    width: (tabBar.width - newTabButton.width) / Math.max(1, win.tabs.length)
                    height: tabBar.height
                    Accessible.role: Accessible.PageTab
                    Accessible.name: tabItem.modelData.title
                    Accessible.selected: tabItem.current
                    Accessible.onPressAction: win.selectTab(tabItem.index)

                    Rectangle {
                        anchors.fill: parent
                        color: tabItem.current ? "transparent" : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
                        border.width: Tokens.appsBorderWidth
                        border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                    }

                    Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        width: parent.width - 2 * Tokens.filesTabHeight
                        horizontalAlignment: Text.AlignHCenter
                        text: tabItem.modelData.title
                        elide: Text.ElideMiddle
                        color: tabItem.current ? Appearance.colors.text : Appearance.colors.textSecondary
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyCaptionSize
                        font.weight: tabItem.current ? Tokens.typographyMenuWeight : Tokens.typographySmallWeight
                    }

                    MouseArea {
                        id: tabMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.MiddleButton)
                                win.closeTab(tabItem.index);
                            else
                                win.selectTab(tabItem.index);
                        }
                    }

                    HoverHandler {
                        id: tabHover
                    }

                    ToolButton {
                        visible: tabHover.hovered
                        anchors.left: parent.left
                        anchors.leftMargin: Tokens.spacingXs
                        anchors.verticalCenter: parent.verticalCenter
                        width: Tokens.filesTabHeight - Tokens.spacingSm
                        height: width
                        iconName: "close-glyph"
                        accessibleName: qsTr("Close Tab")
                        onClicked: win.closeTab(tabItem.index)
                    }
                }
            }

            ToolButton {
                id: newTabButton
                width: Tokens.filesTabHeight
                height: Tokens.filesTabHeight
                glyph: "plus"
                accessibleName: qsTr("New Tab")
                onClicked: win.newTab(win.tab.url)
            }
        }

        Rectangle {
            id: toolbarRule
            anchors.top: tabBar.bottom
            width: parent.width
            height: Tokens.appsBorderWidth
            color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
        }

        // Error banner
        Rectangle {
            id: banner
            anchors.top: toolbarRule.bottom
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

        PathBar {
            id: pathBar
            anchors.bottom: statusBar.top
            width: parent.width
            height: Tokens.filesPathBarHeight
            tab: win.tab
        }

        // Status bar
        Item {
            id: statusBar
            anchors.bottom: parent.bottom
            width: parent.width
            height: Tokens.filesStatusBarHeight
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
                    // A tag search: still running, or stopped by its bounds (TagSearch) before the whole folder was seen.
                    if (f.isSearch && f.loading)
                        return qsTr("%1, searching…").arg(items);
                    if (f.isSearch && f.searchLimited)
                        return qsTr("%1 (the search stopped early: the folder holds too many items)").arg(items);
                    return f.freeSpace >= 0 ? qsTr("%1, %2 available").arg(items).arg(win.app.formatSize(f.freeSpace)) : items;
                }
            }
        }
    }

    Sheet {
        id: goSheet
        title: qsTr("Go to the folder:")
        withField: true
        placeholder: qsTr("~/Documents, /usr/share or trash:/")
        confirmText: qsTr("Go")
        confirmHandler: text => {
            const url = win.app.resolveLocation(text, win.tab.url);
            if (String(url) === "")
                return qsTr("The folder “%1” can’t be found.").arg(text);
            win.tab.navigate(url, true);
            return "";
        }
    }

    Sheet {
        id: confirmSheet
        destructive: true
    }

    MenuLayer {
        id: menuLayer
    }
}
