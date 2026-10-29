pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Activity Monitor (ADR-0038 step 2a; spec AM1 to AM19): the toolbar (the title with the view as its subtitle, the five tabs,
// the search field) over the table of the tab's processes. App windows are opaque (master-prompt 5.5). Step 2b adds each
// tab's summary under the table, 2c Quit, Force Quit and Send Signal, 2d Inspect.
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

    UnifiedToolbar {
        id: toolbar
        width: parent.width
        window: root
        showTitle: false
        canMinimize: root.backend.canMinimize
        doubleClickAction: root.backend.titlebarDoubleClick

        trailing: [
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
        anchors.bottom: parent.bottom
        focus: true
    }

    // AM3: every toolbar control has a tooltip, under it after the shared delay; declared after the list so it shows over it.
    Tooltip {
        id: toolbarTip
        objectName: "toolbarTip"
        readonly property Item over: tabsHover.hovered ? tabs : searchHover.hovered ? search : null
        readonly property point place: over ? over.mapToItem(root.contentItem, 0, over.height) : Qt.point(0, 0)
        text: over === tabs ? qsTr("Choose the resource the table shows") : over === search ? qsTr("Search processes by name, user, command or PID") : ""
        shown: over !== null
        x: Math.round(Math.max(Tokens.spacingXs, Math.min(root.width - width - Tokens.spacingXs, place.x + ((over ? over.width : 0) - width) / 2)))
        y: Math.round(place.y + Tokens.spacingXs)
        z: 10
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
        sequence: "Ctrl+W"
        run: () => root.close()
    }
    Key {
        sequence: "Ctrl+Q"
        run: () => root.close()
    }
}
