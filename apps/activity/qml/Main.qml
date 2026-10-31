pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Activity Monitor (ADR-0038 steps 2a and 2b; spec AM1 to AM19, AM5): the toolbar (the title with the view as its subtitle,
// the five tabs, the search field) over the table of the tab's processes, and the tab's summary under it. App windows are
// opaque (master-prompt 5.5). Step 2c: the Stop button and the action menu, Quit, Force Quit and Send Signal (AM50 to
// AM56); 2d adds Inspect.
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

    // AM2: the window opens at its last size.
    onClosing: root.backend.saveSize(root.width, root.height)

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
        return [
            {id: "quit", text: qsTr("Quit Process"), shortcut: "Ctrl+Alt+Q", enabled: actions.canQuit},
            {id: "signal", text: qsTr("Send Signal to Process…"), enabled: actions.canSignal},
            {separator: true},
            {id: "copy", text: qsTr("Copy"), enabled: root.backend.table.selectedCount > 0}
        ];
    }

    function runAction(id: string): void {
        if (id === "quit")
            sheets.openQuit();
        else if (id === "signal")
            sheets.openSignal();
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
            // AM3: Stop (Quit Process) and the action menu, one glass capsule with a hairline between them (macOS 27).
            RimmedCapsule {
                id: actionGroup
                width: actionRow.width + Tokens.spacingXs
                height: Tokens.toolbarCapsule
                anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                fillOpacity: Tokens.toolbarCapsuleFillOpacity
                Accessible.role: Accessible.Grouping
                Accessible.name: qsTr("Process actions")

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.hairline
                    height: Tokens.toolbarDividerHeight
                    color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.toolbarDividerOpacity)
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
                color: Appearance.colors.textSecondary
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
            : moreHover.hovered ? moreButton : null
        readonly property point place: over ? over.mapToItem(root.contentItem, 0, over.height) : Qt.point(0, 0)
        // AM50: with another owner's process or the Kernel row selected, the Stop button says why it is off.
        text: over === tabs ? qsTr("Choose the resource the table shows") : over === search ? qsTr("Search processes by name, user, command or PID")
            : over === stopButton ? (root.backend.actions.refusal !== "" ? root.backend.actions.refusal : qsTr("Quit the selected processes"))
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

    component Key: Shortcut {
        property var run: null
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
        sequence: "Ctrl+W"
        run: () => root.close()
    }
    Key {
        sequence: "Ctrl+Q"
        run: () => root.close()
    }
}
