pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Grassfield Settings: sidebar with search and sections on the left, detail pane on the right (macOS 27 layout, ADR-0024).
// App windows are opaque (master-prompt 5.5): the sidebar is a flat, slightly darker surface edge to edge, not the shell material.
Window {
    id: root

    // Set by the launcher (src/main.cpp).
    required property var backend
    // The registrar is there (kept up to date by src/main.cpp): the window exports its menus to the global menu bar.
    required property bool globalMenu
    // Section to open first (--section=<id> on the command line); "" opens Appearance.
    property string startSection: ""
    readonly property alias searchField: search
    // ADR-0015: this window draws its own chrome (lights and toolbar below); the apps' tagger (apps/windowchrome.h)
    // names its role for the compositor, whose plugin then draws no titlebar on it.
    property string gfChromeRole: "settings"
    // False when the shell says the compositor plugin is absent: the minimize light is greyed (ADR-0015 Q4b).
    property bool canMinimize: true
    // Colour of each section's icon tile: a Grassfield accent colour (color.accentLight), own values, white glyph on it.
    readonly property var tileColors: ({
            wifi: "blue", bluetooth: "blue", sound: "pink", displays: "blue", appearance: "graphite", wallpaper: "purple",
            accessibility: "blue", desktop: "graphite", menubar: "graphite", notifications: "red", lock: "graphite",
            mouse: "graphite", keyboard: "graphite", about: "green"
        })
    // The title of the shown section (the toolbar's title; the page itself repeats nothing).
    readonly property string sectionTitle: {
        for (const e of root.sections) {
            if (e.id === root.selectedId)
                return e.title;
        }
        return qsTr("Appearance");
    }

    readonly property var sections: [
        {id: "wifi", title: qsTr("Wi-Fi"), icon: "wifi-3", keywords: qsTr("wireless network internet networkmanager")},
        {id: "bluetooth", title: qsTr("Bluetooth"), icon: "bluetooth", keywords: qsTr("devices headphones pair connect")},
        {id: "sound", title: qsTr("Sound"), icon: "volume-3", keywords: qsTr("volume output input speakers microphone mute audio")},
        {id: "displays", title: qsTr("Displays"), icon: "display", keywords: qsTr("monitor screen resolution refresh scale arrangement")},
        {id: "appearance", title: qsTr("Appearance"), icon: "sun", keywords: qsTr("dark light theme transparency material motion icons tint")},
        {id: "wallpaper", title: qsTr("Wallpaper"), icon: "wallpaper", keywords: qsTr("background picture photo image folder slideshow shuffle colour color desktop picture")},
        {id: "accessibility", title: qsTr("Accessibility"), icon: "person", keywords: qsTr("pointer cursor size mouse large color colour outline fill contrast transparency motion text size larger display")},
        {id: "desktop", title: qsTr("Desktop & Dock"), icon: "overview", keywords: qsTr("dock magnification autohide desktop icons items screen corners titlebar window")},
        {id: "menubar", title: qsTr("Menu Bar"), icon: "control-center", keywords: qsTr("menu bar clock date time seconds 24-hour hide status items battery percentage wifi sound focus now playing background transparent")},
        {id: "notifications", title: qsTr("Notifications"), icon: "bell", keywords: qsTr("do not disturb previews banners")},
        {id: "lock", title: qsTr("Lock Screen"), icon: "lock", keywords: qsTr("idle inactivity password")},
        {id: "mouse", title: qsTr("Mouse & Trackpad"), icon: "mouse", keywords: qsTr("pointer tracking speed scrolling natural tap click secondary right click touchpad")},
        {id: "keyboard", title: qsTr("Keyboard"), icon: "keyboard", keywords: qsTr("shortcuts keys bindings")},
        {id: "about", title: qsTr("About"), icon: "grassfield-logo", keywords: qsTr("version system hardware processor memory")}
    ]
    property string selectedId: root.startSection !== "" ? root.startSection : "appearance"
    property string query: ""
    readonly property var filtered: {
        const q = root.query.trim().toLowerCase();
        if (q === "")
            return root.sections;
        return root.sections.filter(s => s.title.toLowerCase().indexOf(q) >= 0 || s.keywords.toLowerCase().indexOf(q) >= 0);
    }
    // The reasons are sentence fragments; a trailing full stop (a JavaScript engine message) is dropped so that the
    // sentences around them never show two.
    readonly property string bannerText: cfg.blocked
        ? qsTr("grassfield.json cannot be used: %1. Settings are read-only until the file is fixed; the file has not been changed.").arg(root.fragment(cfg.error))
        : cfg.writeError !== "" ? qsTr("The change could not be saved: %1.").arg(root.fragment(cfg.writeError)) : ""

    function fragment(reason: string): string {
        return reason.trim().replace(/[.\s]+$/, "");
    }

    title: qsTr("Grassfield Settings")
    width: Tokens.settingsWindowWidth
    height: Tokens.settingsWindowHeight
    minimumWidth: Tokens.settingsWindowMinWidth
    minimumHeight: Tokens.settingsWindowMinHeight
    visible: true
    color: Appearance.colors.windowBackground

    function readCapabilities(): void {
        const file = root.backend.readText(root.backend.capabilitiesFile);
        root.canMinimize = WindowActions.minimizeAvailable(file.exists && file.ok ? file.text : "");
    }

    Component.onCompleted: {
        root.backend.watch(root.backend.capabilitiesFile);
        root.readCapabilities();
    }

    Connections {
        target: root.backend
        function onFileChanged(path: string): void {
            if (path === root.backend.capabilitiesFile)
                root.readCapabilities();
        }
    }

    ConfigStore {
        id: cfg
        backend: root.backend
    }

    SystemService {
        id: sys
        backend: root.backend
    }

    Binding {
        target: Appearance
        property: "dark"
        value: AutoAppearance.isDark(cfg.value("appearance"), root.clock, Tokens.autoAppearanceDarkFromHour, Tokens.autoAppearanceDarkToHour)
    }

    // Auto appearance follows the local schedule: re-evaluated each minute while it is selected.
    property date clock: new Date()
    Timer {
        interval: Tokens.autoAppearanceRecheckInterval
        repeat: true
        running: cfg.value("appearance") === "auto"
        onTriggered: root.clock = new Date()
    }

    // App windows are opaque: menus drawn with the shared material must not show what is behind them.
    Binding {
        target: Appearance
        property: "transparency"
        value: 0
    }

    Binding {
        target: Appearance
        property: "reduceMotion"
        value: cfg.value("accessibility.reduceMotion")
    }

    Binding {
        target: Appearance
        property: "increaseContrast"
        value: cfg.value("accessibility.increaseContrast")
    }

    Binding {
        target: Appearance
        property: "textScale"
        value: cfg.value("accessibility.textSize")
    }

    Binding {
        target: Appearance
        property: "accentSetting"
        value: cfg.value("accent.color")
    }

    // Icon appearance (ADR-0014): the previews and any app icon follow the file live.
    Binding {
        target: Appearance
        property: "iconMode"
        value: cfg.value("icons.mode")
    }

    Binding {
        target: Appearance
        property: "iconTintSetting"
        value: cfg.value("icons.tint")
    }

    Binding {
        target: Appearance
        property: "folderColorSetting"
        value: cfg.value("icons.folderColor")
    }

    function select(id: string): void {
        root.selectedId = id;
    }

    function focusSearch(): void {
        search.forceActiveFocus();
        search.selectAll();
    }

    // Global menu (T1). Its shortcuts duplicate the two below; see GlobalMenu.qml for the single dispatch.
    Loader {
        active: root.globalMenu
        sourceComponent: GlobalMenu {
            win: root
        }
    }

    Shortcut {
        sequence: "Ctrl+F"
        onActivated: root.focusSearch()
        onActivatedAmbiguously: root.focusSearch()
    }

    Shortcut {
        sequence: "Ctrl+W"
        onActivated: root.close()
        onActivatedAmbiguously: root.close()
    }

    function stepSection(direction: int): void {
        let index = -1;
        for (let i = 0; i < root.filtered.length; i++) {
            if (root.filtered[i].id === root.selectedId)
                index = i;
        }
        const next = Math.max(0, Math.min(root.filtered.length - 1, index + direction));
        if (root.filtered.length > 0)
            root.select(root.filtered[next].id);
    }

    Item {
        id: sidebar
        width: Tokens.settingsSidebarWidth
        height: parent.height

        // Edge to edge and a step darker than the detail pane, with no dividing line (macOS 27).
        Rectangle {
            anchors.fill: parent
            color: Appearance.colors.sidebarFill
        }

        // The window lights, in the corner of the sidebar (ADR-0015); the toolbar over the detail pane holds the title.
        UnifiedToolbar {
            id: sidebarToolbar
            width: parent.width
            window: root
            showTitle: false
            canMinimize: root.canMinimize
            doubleClickAction: cfg.value("windows.titlebarDoubleClick")
        }

        // A capsule search field, as wide as the selection (macOS 27).
        Rectangle {
            id: searchBox
            x: Tokens.settingsSidebarInset
            y: sidebarToolbar.height + Tokens.spacingSm
            width: parent.width - 2 * Tokens.settingsSidebarInset
            height: Tokens.settingsSearchHeight
            radius: height / 2
            color: Appearance.withAlpha(Appearance.colors.fill, Appearance.fillOpacity)
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
                anchors {
                    left: searchIcon.right
                    leftMargin: Tokens.spacingSm
                    right: parent.right
                    rightMargin: Tokens.spacingSm
                    verticalCenter: parent.verticalCenter
                }
                clip: true
                activeFocusOnTab: true
                // The selection survives the global menu taking the keyboard (Edit > Cut/Copy act on it).
                persistentSelection: true
                color: Appearance.colors.text
                selectionColor: Appearance.highlight
                selectedTextColor: Appearance.highlightText
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                onTextChanged: root.query = text
                Accessible.role: Accessible.EditableText
                Accessible.name: qsTr("Search settings")
                Accessible.searchEdit: true

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down) {
                        list.forceActiveFocus();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (root.filtered.length > 0)
                            root.select(root.filtered[0].id);
                        list.forceActiveFocus();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Escape && text !== "") {
                        text = "";
                        event.accepted = true;
                    }
                }

                Text {
                    textFormat: Text.PlainText
                    visible: search.text === "" && !search.activeFocus
                    text: qsTr("Search")
                    color: Appearance.colors.textSecondary
                    font: search.font
                }
            }
        }

        ListView {
            id: list
            anchors {
                top: searchBox.bottom
                topMargin: Tokens.spacingMd
                left: parent.left
                right: parent.right
                bottom: parent.bottom
                leftMargin: Tokens.settingsSidebarInset
                rightMargin: Tokens.settingsSidebarInset
            }
            model: root.filtered
            spacing: 0
            // Room for the focus ring outside the first and last rows (the list clips).
            topMargin: Tokens.controlFocusOutline
            bottomMargin: Tokens.controlFocusOutline
            clip: true
            interactive: false
            keyNavigationEnabled: false
            activeFocusOnTab: true
            Accessible.role: Accessible.List
            Accessible.name: qsTr("Sections")

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Up) {
                    root.stepSection(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down) {
                    root.stepSection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Home && root.filtered.length > 0) {
                    root.select(root.filtered[0].id);
                    event.accepted = true;
                } else if (event.key === Qt.Key_End && root.filtered.length > 0) {
                    root.select(root.filtered[root.filtered.length - 1].id);
                    event.accepted = true;
                }
            }

            delegate: Item {
                id: entry

                required property var modelData
                readonly property bool selected: entry.modelData.id === root.selectedId

                width: ListView.view.width
                height: Tokens.settingsSidebarItemHeight
                Accessible.role: Accessible.ListItem
                Accessible.name: entry.modelData.title
                Accessible.selectable: true
                Accessible.selected: entry.selected
                Accessible.onPressAction: root.select(entry.modelData.id)

                Rectangle {
                    anchors.fill: parent
                    radius: Tokens.settingsSidebarItemRadius
                    color: entry.selected ? Appearance.colors.selection : (hover.containsMouse ? Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity) : "transparent")
                }

                // Keyboard focus ring: outside the selected row, accent and translucent (as macOS).
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -Tokens.controlFocusOutline
                    radius: Tokens.settingsSidebarItemRadius + Tokens.controlFocusOutline
                    visible: entry.selected && list.activeFocus
                    color: "transparent"
                    border.width: Tokens.controlFocusOutline
                    border.color: Appearance.focusRingColor
                }

                // The section's coloured tile with a white glyph (macOS 27); it keeps its colour when the row is selected.
                Rectangle {
                    id: glyph
                    x: Tokens.spacingSm
                    y: Math.round((parent.height - height) / 2)
                    width: Tokens.settingsSidebarIconSize
                    height: Tokens.settingsSidebarIconSize
                    radius: Tokens.settingsSidebarTileRadius
                    color: Tokens.colorAccentLight[root.tileColors[entry.modelData.id] || "graphite"]

                    Icon {
                        anchors.centerIn: parent
                        name: entry.modelData.icon
                        size: Tokens.settingsSidebarGlyphSize
                        color: Tokens.settingsSidebarTileGlyph
                    }
                }

                Text {
                    textFormat: Text.PlainText
                    anchors {
                        left: glyph.right
                        leftMargin: Tokens.spacingSm
                        right: parent.right
                        rightMargin: Tokens.spacingSm
                        verticalCenter: parent.verticalCenter
                    }
                    text: entry.modelData.title
                    elide: Text.ElideRight
                    color: entry.selected ? Appearance.colors.selectionText : Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    font.weight: entry.selected ? Tokens.typographyMenuBoldWeight : Tokens.typographyMenuWeight
                }

                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: {
                        list.forceActiveFocus();
                        root.select(entry.modelData.id);
                    }
                }
            }
        }
    }

    Item {
        id: detail
        x: sidebar.width
        width: parent.width - sidebar.width
        height: parent.height

        UnifiedToolbar {
            id: detailToolbar
            width: parent.width
            window: root
            showControls: false
            title: root.sectionTitle
            canMinimize: root.canMinimize
            doubleClickAction: cfg.value("windows.titlebarDoubleClick")
        }

        Rectangle {
            id: banner
            visible: root.bannerText !== ""
            x: Tokens.spacingLg
            y: detailToolbar.height + Tokens.spacingLg
            width: parent.width - 2 * Tokens.spacingLg
            height: visible ? bannerLabel.implicitHeight + 2 * Tokens.spacingMd : 0
            radius: Tokens.radiusMenu
            // Destructive colour: the file is refused (or a change failed), nothing is written.
            color: Appearance.colors.destructive
            Accessible.role: Accessible.AlertMessage
            Accessible.name: root.bannerText

            Text {
                id: bannerLabel
                textFormat: Text.PlainText
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    margins: Tokens.spacingMd
                }
                text: root.bannerText
                wrapMode: Text.Wrap
                color: Appearance.colors.destructiveText
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
            }
        }

        Loader {
            id: page
            anchors {
                top: banner.visible ? banner.bottom : detailToolbar.bottom
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            // A malformed file makes every control inert (nothing is written).
            enabled: !cfg.blocked
            opacity: cfg.blocked ? Tokens.materialDisabledOpacity : 1
            sourceComponent: {
                switch (root.selectedId) {
                case "wifi":
                    return wifiPage;
                case "bluetooth":
                    return bluetoothPage;
                case "sound":
                    return soundPage;
                case "displays":
                    return displaysPage;
                case "wallpaper":
                    return wallpaperPage;
                case "accessibility":
                    return accessibilityPage;
                case "desktop":
                    return desktopPage;
                case "menubar":
                    return menuBarPage;
                case "notifications":
                    return notificationsPage;
                case "lock":
                    return lockPage;
                case "mouse":
                    return mousePage;
                case "keyboard":
                    return keyboardPage;
                case "about":
                    return aboutPage;
                }
                return appearancePage;
            }
        }
    }

    Component {
        id: wifiPage
        WifiPage {
            backend: root.backend
            system: sys
        }
    }

    Component {
        id: bluetoothPage
        BluetoothPage {
            backend: root.backend
            system: sys
        }
    }

    Component {
        id: soundPage
        SoundPage {
            backend: root.backend
            system: sys
        }
    }

    Component {
        id: displaysPage
        DisplaysPage {
            backend: root.backend
        }
    }

    Component {
        id: appearancePage
        AppearancePage {
            store: cfg
        }
    }

    Component {
        id: wallpaperPage
        WallpaperPage {
            store: cfg
            backend: root.backend
        }
    }

    Component {
        id: accessibilityPage
        AccessibilityPage {
            store: cfg
        }
    }

    Component {
        id: desktopPage
        DesktopPage {
            store: cfg
        }
    }

    Component {
        id: menuBarPage
        MenuBarPage {
            store: cfg
            onClockOptionsRequested: clockSheet.open()
        }
    }

    Component {
        id: notificationsPage
        NotificationsPage {
            store: cfg
            backend: root.backend
        }
    }

    Component {
        id: lockPage
        LockPage {
            store: cfg
        }
    }

    Component {
        id: mousePage
        MousePage {
            backend: root.backend
        }
    }

    Component {
        id: keyboardPage
        KeyboardPage {
            backend: root.backend
        }
    }

    Component {
        id: aboutPage
        AboutPage {
            backend: root.backend
        }
    }

    // Menu Bar > Clock Options…: a sheet over the whole window.
    ClockOptionsSheet {
        id: clockSheet
        store: cfg
    }
}
