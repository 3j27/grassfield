pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Activity Monitor (ADR-0038 steps 2a and 2b; spec AM1 to AM19, AM5): the toolbar (the title with the view as its subtitle,
// the five tabs, the search field) over the table of the tab's processes, and the tab's summary under it. App windows are
// opaque (master-prompt 5.5). Step 2c: the Stop button and the action menu, Quit, Force Quit and Send Signal (AM50 to
// AM56). Step 2d: the Info button and Inspect's windows (AM57 to AM59).
Window {
    id: root

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu
    // ADR-0015: this window draws its own chrome (the lights in the toolbar).
    property string gfChromeRole: "activity"
    // The tests read them.
    readonly property alias searchField: search
    readonly property alias processList: processList
    readonly property alias tabs: tabs
    readonly property alias summary: summary
    readonly property alias networkNote: networkNote
    readonly property alias stopButton: stopButton
    readonly property alias infoButton: infoButton
    readonly property alias moreButton: moreButton
    readonly property alias actionMenu: actionMenu
    readonly property alias sheets: sheets

    title: qsTr("Activity Monitor")
    width: root.backend.savedWidth > 0 ? root.backend.savedWidth : Tokens.activityWindowWidth
    height: root.backend.savedHeight > 0 ? root.backend.savedHeight : Tokens.activityWindowHeight
    minimumWidth: Tokens.activityWindowMinWidth
    minimumHeight: Tokens.activityWindowMinHeight
    visible: true
    color: Appearance.colors.windowBackground

    // AM2: the window opens at its last size. AD17: closing it quits the app, its Inspect windows with it.
    onClosing: {
        root.backend.saveSize(root.width, root.height);
        for (const w of root.ownWindows.slice())
            w.close();
    }

    // AM57: the Inspect windows this window opened and that are still open, its transient children (as Files' Get Info).
    property var ownWindows: []
    // One of them is the key window (backend.focusWindow; never `active`: Qt reports a window and its transient children
    // active together): this window's keys and its global menu's wait meanwhile, so Ctrl+W typed there closes that window
    // alone (Files' BrowserWindow.childIsKey).
    readonly property bool childIsKey: root.backend.focusWindow !== null && root.backend.focusWindow !== undefined
        && root.ownWindows.indexOf(root.backend.focusWindow) >= 0

    // AM57: an inspection's window, made or brought forward (a second request raises it).
    function showInspection(inspection: var): void {
        for (const w of root.ownWindows) {
            if (w.inspection === inspection) {
                w.show();
                w.raise();
                w.requestActivate();
                return;
            }
        }
        const w = inspectComponent.createObject(root, {transientParent: root, app: root.backend, inspection: inspection, mainWindow: root});
        if (w) {
            root.ownWindows = root.ownWindows.concat([w]);
            w.closing.connect(() => {
                root.ownWindows = root.ownWindows.filter(o => o !== w);
                Qt.callLater(w.destroy);
            });
        }
    }

    Component {
        id: inspectComponent
        InspectWindow {}
    }

    // The app's own windows other than Inspect (AM66, AM67, AM71, AM72): one each, made or brought forward, transient
    // children as the Inspect windows (closed with this one, their keys their own). `kind`: its objectName.
    function showOwn(kind: string, component: Component): void {
        for (const w of root.ownWindows) {
            if (w.objectName === kind) {
                w.show();
                w.raise();
                w.requestActivate();
                return;
            }
        }
        const w = component.createObject(root, {transientParent: root, app: root.backend, objectName: kind});
        if (w) {
            root.ownWindows = root.ownWindows.concat([w]);
            w.closing.connect(() => {
                root.ownWindows = root.ownWindows.filter(o => o !== w);
                Qt.callLater(w.destroy);
            });
        }
    }

    // AM67 (step 4): View > App History, Ctrl+6.
    function showAppHistory(): void {
        root.showOwn("appHistoryWindow", appHistoryComponent);
    }

    // Ctrl+1: the main window, from any of its windows.
    function showMain(): void {
        root.show();
        root.raise();
        root.requestActivate();
    }

    // AM66 (step 4): View > Performance, Ctrl+5.
    function showPerformance(): void {
        root.showOwn("performanceWindow", performanceComponent);
    }

    // AM71, AM72 (step 5): View > CPU Usage (Ctrl+2), CPU History (Ctrl+3), GPU History (Ctrl+4).
    function showCpuUsage(): void {
        root.showOwn("cpuUsageWindow", cpuUsageComponent);
    }
    function showCpuHistory(): void {
        root.showOwn("cpuHistoryWindow", cpuHistoryComponent);
    }
    function showGpuHistory(): void {
        root.showOwn("gpuHistoryWindow", gpuHistoryComponent);
    }
    // AM72: View > Clear CPU History (Ctrl+K).
    function clearCpuHistory(): void {
        root.backend.performance.clearCpuHistory();
    }

    Component {
        id: appHistoryComponent
        AppHistoryWindow {}
    }

    Component {
        id: performanceComponent
        PerformanceWindow {}
    }

    Component {
        id: cpuUsageComponent
        CpuUsageWindow {}
    }

    Component {
        id: cpuHistoryComponent
        CpuHistoryWindow {}
    }

    Component {
        id: gpuHistoryComponent
        CpuHistoryWindow {
            gpu: true
        }
    }

    Connections {
        target: root.backend
        function onInspectRequested(inspection: var): void {
            root.showInspection(inspection);
        }
    }

    function focusSearch(): void {
        search.forceActiveFocus();
        search.selectAll();
    }

    function copy(): void {
        root.backend.copySelection();
    }

    function selectAll(): void {
        root.backend.table.selectAll();
    }

    // AM3, AM50, AM55: the action menu's items, as the row's context menu shows them.
    function actionItems(): var {
        const actions = root.backend.actions;
        const efficiency = root.backend.efficiency;
        const items = [
            {id: "quit", text: qsTr("Quit Process"), shortcut: "Ctrl+Alt+Q", enabled: actions.canQuit},
            {id: "inspect", text: qsTr("Inspect Process"), shortcut: "Ctrl+I", enabled: root.backend.canInspect},
            {id: "signal", text: qsTr("Send Signal to Process…"), enabled: actions.canSignal}
        ];
        // AM68: a checked item for the selected process; absent without the user manager (AM76).
        if (efficiency.supported)
            items.push({id: "efficiency", text: qsTr("Efficiency Mode"), checked: efficiency.on, enabled: efficiency.available && !efficiency.busy});
        items.push({separator: true});
        items.push({id: "copy", text: qsTr("Copy"), enabled: root.backend.table.selectedCount > 0});
        return items;
    }

    // AM68: on, the first time after its sheet (until "Don't ask again"); off at once.
    function toggleEfficiency(): void {
        const efficiency = root.backend.efficiency;
        if (!efficiency.available || efficiency.busy)
            return;
        if (efficiency.on)
            efficiency.set(false);
        else if (root.backend.askEfficiency)
            sheets.openEfficiency();
        else
            efficiency.set(true);
    }

    function runAction(id: string): void {
        if (id === "quit")
            sheets.openQuit();
        else if (id === "inspect")
            root.backend.inspectSelection();
        else if (id === "signal")
            sheets.openSignal();
        else if (id === "efficiency")
            root.toggleEfficiency();
        else if (id === "copy")
            root.copy();
    }

    // The action menu under its button, or the context menu at the pointer (`x`, `y` in the window).
    function openActionMenu(x: real, y: real): void {
        actionMenu.items = root.actionItems();
        actionMenu.openAt(x, y);
    }

    UnifiedToolbar {
        id: toolbar
        width: parent.width
        window: root
        showTitle: false
        canMinimize: root.backend.canMinimize
        doubleClickAction: root.backend.titlebarDoubleClick

        trailing: [
            // AM3: Stop (Quit Process), Info (Inspect) and the action menu, one glass capsule with a hairline between each two
            // (macOS 27).
            RimmedCapsule {
                id: actionGroup
                width: actionRow.width + Tokens.spacingXs
                height: Tokens.toolbarCapsule
                anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                fillOpacity: Tokens.toolbarCapsuleFillOpacity
                Accessible.role: Accessible.Grouping
                Accessible.name: qsTr("Process actions")

                Repeater {
                    model: 2

                    Rectangle {
                        required property int index
                        x: actionRow.x + stopButton.width + (index === 1 ? infoButton.width : 0) - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: actionGroup.hairline
                        height: Tokens.toolbarDividerHeight
                        color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.toolbarDividerOpacity)
                    }
                }

                Row {
                    id: actionRow
                    anchors.centerIn: parent

                    ToolButton {
                        id: stopButton
                        // The window's own tooltip names it (toolbarTip, AM3), with more than its name.
                        tooltip: ""
                        objectName: "stopButton"
                        capsule: true
                        buttonSize: Tokens.toolbarGroupButton
                        iconName: "xmark-octagon"
                        enabled: root.backend.actions.canQuit
                        accessibleName: qsTr("Quit Process")
                        onClicked: sheets.openQuit()

                        HoverHandler {
                            id: stopHover
                        }
                    }

                    ToolButton {
                        id: infoButton
                        // The window's own tooltip names it (toolbarTip, AM3), with more than its name.
                        tooltip: ""
                        objectName: "infoButton"
                        capsule: true
                        buttonSize: Tokens.toolbarGroupButton
                        iconName: "info"
                        enabled: root.backend.canInspect
                        accessibleName: qsTr("Inspect Process")
                        onClicked: root.backend.inspectSelection()

                        HoverHandler {
                            id: infoHover
                        }
                    }

                    ToolButton {
                        id: moreButton
                        // The window's own tooltip names it (toolbarTip, AM3), with more than its name.
                        tooltip: ""
                        objectName: "moreButton"
                        capsule: true
                        buttonSize: Tokens.toolbarGroupButton
                        iconName: "ellipsis-circle"
                        accessibleName: qsTr("Actions")
                        onClicked: {
                            const p = moreButton.mapToItem(root.contentItem, 0, moreButton.height + Tokens.spacingXs);
                            root.openActionMenu(p.x, p.y);
                        }

                        HoverHandler {
                            id: moreHover
                        }
                    }
                }
            },
            SegmentedControl {
                id: tabs
                objectName: "tabs"
                model: root.backend.tabs.map(t => ({id: t.key, text: t.title}))
                value: root.backend.tab
                accessibleName: qsTr("Resource")
                onPicked: id => root.backend.tab = id

                HoverHandler {
                    id: tabsHover
                }
            },
            SearchField {
                id: search
                objectName: "search"
                width: Tokens.activitySearchWidth
                anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                Accessible.name: qsTr("Search processes")
                // AM14: a live filter, no Return needed.
                onTextChanged: root.backend.search = search.text
                Keys.onDownPressed: processList.forceActiveFocus()

                HoverHandler {
                    id: searchHover
                }
            }
        ]

        // AM3: the app's name with the current view as its subtitle, where a macOS toolbar puts its title.
        Column {
            x: toolbar.contentStart + Tokens.spacingSm
            width: Math.max(0, toolbar.titleEnd - x)
            anchors.verticalCenter: parent.verticalCenter
            visible: width > 0

            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.title
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyMenuSize
                font.weight: Tokens.typographyMenuBoldWeight
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.backend.viewTitle
                color: Appearance.windowSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }
        }
    }

    ProcessList {
        id: processList
        backend: root.backend
        anchors.top: toolbar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: networkNote.visible ? networkNote.top : summary.top
        focus: true
        // AM57: a double-click inspects the row.
        onRowActivated: row => root.backend.inspectRow(row)
        onContextMenuRequested: (x, y) => {
            const p = processList.mapToItem(root.contentItem, x, y);
            root.openActionMenu(p.x, p.y);
        }
    }

    // AM43: the Network tab's columns count TCP only; UDP shows in the totals of the summary.
    Text {
        id: networkNote
        objectName: "networkNote"
        visible: root.backend.tab === "network"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: summary.top
        leftPadding: Tokens.spacingLg
        rightPadding: Tokens.spacingLg
        topPadding: Tokens.spacingXs
        bottomPadding: Tokens.spacingXs
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: qsTr("UDP traffic, such as some video, is counted only in the totals below.")
        color: Appearance.windowSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
    }

    Summary {
        id: summary
        objectName: "summary"
        backend: root.backend
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
    }

    // AM3: every toolbar control has a tooltip, under it after the shared delay; declared after the list so it shows over it.
    Tooltip {
        id: toolbarTip
        objectName: "toolbarTip"
        readonly property Item over: tabsHover.hovered ? tabs : searchHover.hovered ? search : stopHover.hovered ? stopButton
            : infoHover.hovered ? infoButton : moreHover.hovered ? moreButton : null
        readonly property point place: over ? over.mapToItem(root.contentItem, 0, over.height) : Qt.point(0, 0)
        // AM50: with another owner's process or the Kernel row selected, the Stop button says why it is off.
        text: over === tabs ? qsTr("Choose the resource the table shows") : over === search ? qsTr("Search processes by name, user, command or PID")
            : over === stopButton ? (root.backend.actions.refusal !== "" ? root.backend.actions.refusal : qsTr("Quit the selected processes"))
            : over === infoButton ? qsTr("Inspect the selected process")
            : over === moreButton ? qsTr("Act on the selected processes") : ""
        shown: over !== null
        x: Math.round(Math.max(Tokens.spacingXs, Math.min(root.width - width - Tokens.spacingXs, place.x + ((over ? over.width : 0) - width) / 2)))
        y: Math.round(place.y + Tokens.spacingXs)
        z: 10
    }

    // The action menu (the "…" button) and the rows' context menu.
    MenuPopup {
        id: actionMenu
        objectName: "actionMenu"
        accessibleName: qsTr("Actions")
        focusBack: processList
        onChosen: id => root.runAction(id)
    }

    // AM50 to AM56: the sheets, over everything else.
    ActionSheets {
        id: sheets
        objectName: "actionSheets"
        actions: root.backend.actions
        backend: root.backend
        focusBack: processList
        z: 20
    }

    // AM54: the app's own row was quit: its window closes.
    Connections {
        target: root.backend.actions
        function onCloseWindowRequested(): void {
            root.close();
        }
    }

    // ---- Appearance (grassfield.json, read by the backend) and the window's own surface.
    Binding {
        target: Appearance
        property: "windowSurface"
        value: true
    }

    Binding {
        target: Appearance
        property: "transparency"
        value: 0
    }

    Binding {
        target: Appearance
        property: "dark"
        value: root.backend.dark
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: root.backend.reduceMotion
    }

    Binding {
        target: Appearance
        property: "increaseContrast"
        value: root.backend.increaseContrast
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: root.backend.textScale
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: root.backend.accentColor
    }

    Binding {
        target: Appearance
        property: "highlightSetting"
        value: root.backend.accentHighlight
    }

    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: root.backend.shortcutStyle
    }

    // ---- Menus and keyboard (spec AM6, "Keyboard"). The global menu's items carry the same shortcuts; each acts once. The
    // window keeps its own Shortcuts beside the menu's (as the Store), so every key works whatever the menu path.
    Loader {
        active: root.globalMenu
        sourceComponent: GlobalMenu {
            win: root
        }
        onItemChanged: console.info("grassfield: global menu " + (item ? "created" : "destroyed"))
    }

    // None acts while one of this window's Inspect windows is the key window (childIsKey) but Ctrl+Q, which quits the app
    // from any of them.
    component Key: Shortcut {
        property var run: null
        enabled: !root.childIsKey
        onActivated: run()
        onActivatedAmbiguously: run()
    }

    Key {
        sequence: "Ctrl+F"
        run: root.focusSearch
    }
    Key {
        sequences: [StandardKey.Copy]
        run: root.copy
    }
    Key {
        sequences: [StandardKey.SelectAll]
        run: root.selectAll
    }
    Key {
        sequence: "Ctrl+Alt+Q"
        run: () => sheets.openQuit()
    }
    Key {
        sequence: "Ctrl+I"
        run: () => root.backend.inspectSelection()
    }
    Key {
        sequence: "Ctrl+W"
        run: () => root.close()
    }
    Key {
        sequence: "Ctrl+Q"
        enabled: true
        run: () => root.close()
    }
    // Spec "Keyboard": the windows, from any of the app's windows (an application shortcut: the Inspect, Performance and
    // CPU windows have none of their own for these keys).
    component WindowKey: Key {
        enabled: true
        context: Qt.ApplicationShortcut
    }
    WindowKey {
        sequence: "Ctrl+1"
        run: root.showMain
    }
    WindowKey {
        sequence: "Ctrl+2"
        run: root.showCpuUsage
    }
    WindowKey {
        sequence: "Ctrl+3"
        run: root.showCpuHistory
    }
    WindowKey {
        sequence: "Ctrl+4"
        run: root.showGpuHistory
    }
    WindowKey {
        sequence: "Ctrl+K"
        run: root.clearCpuHistory
    }
    WindowKey {
        sequence: "Ctrl+5"
        run: root.showPerformance
    }
    WindowKey {
        sequence: "Ctrl+6"
        run: root.showAppHistory
    }
}
