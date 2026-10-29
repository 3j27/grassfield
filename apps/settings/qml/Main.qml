pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "MouseTrackpad.js" as MouseTrackpad
import "NavHistory.js" as NavHistory
import "Power.js" as Power

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
            wifi: "blue", bluetooth: "blue", network: "blue", vpn: "blue", battery: "green", sound: "pink", displays: "blue", appearance: "graphite", wallpaper: "purple",
            accessibility: "blue", desktop: "graphite", menubar: "graphite", search: "graphite", notifications: "red", focus: "purple", lock: "graphite",
            mouse: "graphite", trackpad: "graphite", printers: "graphite", keyboard: "graphite", general: "graphite", about: "graphite", storage: "graphite",
            "software-update": "graphite",
            datetime: "blue", language: "blue", login: "graphite", privacy: "blue",
            "accessibility-zoom": "graphite", "accessibility-display": "blue", "accessibility-motion": "green", "accessibility-keyboard": "graphite",
            "privacy-location": "blue", "privacy-background": "graphite", "privacy-camera": "graphite", "privacy-remote-desktop": "blue",
            "privacy-screen-sharing": "purple"
        })
    // The title of the shown section (the toolbar's title; the page itself repeats nothing). A hub shows its own header card
    // instead, so the toolbar has no title there (macOS 27 General).
    readonly property string sectionTitle: {
        if (root.selectedId === "general")
            return "";
        if (root.notificationApp !== "")
            return root.notificationApp;
        for (const e of root.sections) {
            if (e.id === root.selectedId)
                return e.title;
        }
        return qsTr("Appearance");
    }

    // The sidebar in the macOS 27 order and groups (`group`: a gap before each new one), without the panes Grassfield has no
    // counterpart for (docs/specs/settings.md § macOS 27 parity inventory). Sub-panes name their hub (`parent`): they are not in
    // the sidebar, the hub's rows open them, and the search finds them.
    readonly property var sections: [
        {id: "wifi", group: 1, title: qsTr("Wi-Fi"), icon: "wifi-3", keywords: qsTr("wireless network internet networkmanager")},
        {id: "bluetooth", group: 1, title: qsTr("Bluetooth"), icon: "bluetooth", keywords: qsTr("devices headphones pair connect")},
        {id: "network", group: 1, title: qsTr("Network"), icon: "globe", keywords: qsTr("ethernet wired ip address router dns firewall")},
        {id: "vpn", group: 1, title: qsTr("VPN"), icon: "vpn", keywords: qsTr("vpn wireguard openvpn tunnel")},
        {id: "battery", group: 1, title: qsTr("Battery"), icon: "battery", keywords: qsTr("battery power low power mode energy health charging charge limit")},
        {id: "general", group: 2, title: qsTr("General"), icon: "gear", keywords: qsTr("about software update storage date time language region login items startup")},
        {id: "accessibility", group: 2, title: qsTr("Accessibility"), icon: "person", keywords: qsTr("vision physical motor zoom display motion keyboard")},
        {id: "appearance", group: 2, title: qsTr("Appearance"), icon: "sun", keywords: qsTr("dark light theme transparency material motion icons tint")},
        {id: "desktop", group: 2, title: qsTr("Desktop & Dock"), icon: "overview", keywords: qsTr("dock magnification autohide desktop icons items screen corners titlebar window")},
        {id: "displays", group: 2, title: qsTr("Displays"), icon: "display", keywords: qsTr("monitor screen resolution refresh scale arrangement")},
        {id: "menubar", group: 2, title: qsTr("Menu Bar"), icon: "control-center", keywords: qsTr("menu bar clock date time seconds 24-hour hide status items battery percentage wifi sound focus now playing background transparent")},
        {id: "search", group: 2, title: qsTr("Search"), icon: "search", keywords: qsTr("search results history calculator conversions documents commands clipboard copy paste")},
        {id: "wallpaper", group: 2, title: qsTr("Wallpaper"), icon: "wallpaper", keywords: qsTr("background picture photo image folder slideshow shuffle colour color desktop picture")},
        {id: "notifications", group: 3, title: qsTr("Notifications"), icon: "bell", keywords: qsTr("do not disturb previews banners")},
        {id: "sound", group: 3, title: qsTr("Sound"), icon: "volume-3", keywords: qsTr("volume output input speakers microphone mute audio")},
        {id: "focus", group: 3, title: qsTr("Focus"), icon: "moon", keywords: qsTr("do not disturb silence quiet banners")},
        {id: "lock", group: 4, title: qsTr("Lock Screen"), icon: "lock", keywords: qsTr("idle inactivity password")},
        {id: "privacy", group: 4, title: qsTr("Privacy & Security"), icon: "hand", keywords: qsTr("privacy permissions location camera background screen sharing remote desktop apps flatpak portal")},
        {id: "keyboard", group: 5, title: qsTr("Keyboard"), icon: "keyboard", keywords: qsTr("shortcuts keys bindings")},
        {id: "mouse", group: 5, title: qsTr("Mouse"), icon: "mouse", keywords: qsTr("pointer tracking speed scrolling natural wheel bluetooth")},
        {id: "trackpad", group: 5, title: qsTr("Trackpad"), icon: "trackpad", keywords: qsTr("touchpad pointer tracking speed scrolling natural tap click secondary right click gestures swipe pinch")},
        {id: "printers", group: 5, title: qsTr("Printers"), icon: "printer", keywords: qsTr("printer printing print queue cups paper size default printer add remove airprint ipp everywhere")},
        {id: "about", parent: "general", title: qsTr("About"), icon: "laptop", keywords: qsTr("version system hardware processor memory computer name graphics serial")},
        {id: "software-update", parent: "general", title: qsTr("Software Update"), icon: "gear", keywords: qsTr("software update upgrade new version release notes beta omarchy packages automatic")},
        {id: "storage", parent: "general", title: qsTr("Storage"), icon: "drive", keywords: qsTr("disk space volume free used documents downloads pictures music videos trash")},
        {id: "datetime", parent: "general", title: qsTr("Date & Time"), icon: "clock", keywords: qsTr("clock time zone city automatic network time ntp 24-hour")},
        {id: "login", parent: "general", title: qsTr("Login Items"), icon: "list", keywords: qsTr("login items startup autostart open at login background services")},
        {id: "language", parent: "general", title: qsTr("Language & Region"), icon: "globe", keywords: qsTr("language region formats locale date number first day of week calendar")},
        {id: "dnd", parent: "focus", title: qsTr("Do Not Disturb"), icon: "moon", keywords: qsTr("focus silence quiet banners notifications")},
        {id: "accessibility-zoom", parent: "accessibility", title: qsTr("Zoom"), icon: "zoom-in", keywords: qsTr("accessibility magnify magnifier zoom level larger screen")},
        {id: "accessibility-display", parent: "accessibility", title: qsTr("Display"), icon: "display", keywords: qsTr("accessibility contrast transparency text size larger pointer cursor size mouse large color colour outline fill")},
        {id: "accessibility-motion", parent: "accessibility", title: qsTr("Motion"), icon: "motion", keywords: qsTr("accessibility reduce motion animations")},
        {id: "accessibility-keyboard", parent: "accessibility", title: qsTr("Keyboard"), icon: "keyboard", keywords: qsTr("accessibility sticky keys slow keys")},
        {id: "privacy-location", parent: "privacy", title: qsTr("Location Services"), icon: "location", keywords: qsTr("privacy location where apps allow")},
        {id: "privacy-background", parent: "privacy", title: qsTr("Background Apps"), icon: "background", keywords: qsTr("privacy background apps running allow")},
        {id: "privacy-camera", parent: "privacy", title: qsTr("Camera"), icon: "camera", keywords: qsTr("privacy camera webcam video apps allow")},
        {id: "privacy-remote-desktop", parent: "privacy", title: qsTr("Remote Desktop"), icon: "remote-desktop", keywords: qsTr("privacy remote desktop control saved choices")},
        {id: "privacy-screen-sharing", parent: "privacy", title: qsTr("Screen Sharing"), icon: "screen-share", keywords: qsTr("privacy screen sharing recording window saved choices")}
    ]
    // An app's sub-pane of Notifications: "notifications/<app name>" (the name as the shell saw it).
    readonly property string notificationAppPrefix: "notifications/"
    readonly property string notificationApp: root.selectedId.indexOf(root.notificationAppPrefix) === 0 ? root.selectedId.substring(root.notificationAppPrefix.length) : ""
    property string selectedId: root.startSection !== "" ? root.pointerPane(root.startSection) : "appearance"
    property string query: ""
    // The state a pane shows under its title in the toolbar (Battery), "" for none.
    readonly property string pageSubtitle: (page.item as BatteryPage)?.subtitle ?? ""
    // Battery is there only on a computer with a laptop battery (macOS shows it on a laptop only).
    property bool hasBattery: false
    // Mouse while a mouse is connected and Trackpad where there is one (macOS): MouseTrackpad.pointers of the kernel's input
    // devices, read again with the system state while the window is active.
    property bool hasMouse: false
    property bool hasTouchpad: false
    readonly property var available: root.sections.filter(s => (s.id !== "battery" || root.hasBattery) && (s.id !== "mouse" || root.hasMouse)
        && (s.id !== "trackpad" || root.hasTouchpad))
    readonly property var filtered: {
        const q = root.query.trim().toLowerCase();
        if (q === "")
            return root.available.filter(s => s.parent === undefined);
        return root.available.filter(s => s.title.toLowerCase().indexOf(q) >= 0 || s.keywords.toLowerCase().indexOf(q) >= 0);
    }

    // The hub a sub-pane belongs to ("" for a sidebar section): the sidebar keeps the hub selected while one of its sub-panes is open.
    function parentOf(id: string): string {
        if (id.indexOf(root.notificationAppPrefix) === 0)
            return "notifications";
        for (const e of root.sections) {
            if (e.id === id)
                return e.parent !== undefined ? e.parent : "";
        }
        return "";
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
        root.readPointers();
        root.navState = NavHistory.start(root.selectedId);
        root.backend.watch(root.backend.capabilitiesFile);
        root.readCapabilities();
        root.backend.busQuery("power.state", "main.power");
    }

    Connections {
        target: root.backend
        function onFileChanged(path: string): void {
            if (path === root.backend.capabilitiesFile)
                root.readCapabilities();
        }
        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "main.power") {
                const power = ok ? Power.parseState(output) : null;
                root.hasBattery = power !== null && power.present;
            }
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

    // Software Update (ADR-0033): what the shell found, for the pane and the badges of the General rows (U19).
    SoftwareUpdateState {
        id: updateState
        backend: root.backend
        system: sys
    }

    // The window's own surface and its secondary text grey (Appearance.windowSurface, Appearance.windowSecondary).
    Binding {
        target: Appearance
        property: "windowSurface"
        value: true
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

    Binding {
        target: Appearance
        property: "highlightSetting"
        value: cfg.value("accent.highlight")
    }

    // Menu shortcuts in the device's style (keyboard.shortcutStyle, owner decision 2026-10-26); the device facts are read once.
    readonly property bool macDevice: MenuShortcut.macDevice(root.backend.readText("/sys/class/dmi/id/sys_vendor").text, root.backend.readText("/proc/bus/input/devices").text)

    Binding {
        target: Appearance
        property: "shortcutStyle"
        value: MenuShortcut.style(cfg.value("keyboard.shortcutStyle"), root.macDevice)
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

    // Back and forward through the panes (the toolbar's capsule): NavHistory.js.
    property var navState: ({back: [], forward: [], current: ""})

    function select(id: string): void {
        const shown = root.pointerPane(id);
        root.navState = NavHistory.visit(root.navState, shown);
        root.selectedId = shown;
    }

    // Asked for Mouse without a mouse, or for Trackpad without a touchpad, the other is shown when it is there.
    function pointerPane(id: string): string {
        return MouseTrackpad.paneFor(id, {mouse: root.hasMouse, touchpad: root.hasTouchpad});
    }

    function readPointers(): void {
        const found = MouseTrackpad.pointers(root.backend.readText("/proc/bus/input/devices").text);
        root.hasMouse = found.mouse;
        root.hasTouchpad = found.touchpad;
        if (root.pointerPane(root.selectedId) !== root.selectedId)
            root.select(root.selectedId);
    }

    Timer {
        interval: Tokens.settingsSystemRefreshMs
        running: root.active
        repeat: true
        onTriggered: root.readPointers()
    }

    function navBack(): void {
        root.navState = NavHistory.back(root.navState);
        root.selectedId = root.navState.current;
    }

    function navForward(): void {
        root.navState = NavHistory.forward(root.navState);
        root.selectedId = root.navState.current;
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
        const hub = root.parentOf(root.selectedId);
        for (let i = 0; i < root.filtered.length; i++) {
            if (root.filtered[i].id === root.selectedId || (index < 0 && root.filtered[i].id === hub))
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

        // A capsule search field, as wide as the selection, with the glass rims of macOS 27 (RimmedCapsule).
        RimmedCapsule {
            id: searchBox
            x: Tokens.settingsSidebarInset
            y: sidebarToolbar.height + Tokens.spacingSm
            width: parent.width - 2 * Tokens.settingsSidebarInset
            height: Tokens.settingsSearchHeight

            FocusRing {
                visible: search.activeFocus
                shapeRadius: searchBox.radius
            }

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
                    // Tab, Shift+Tab, Down and Return hand the focus to the list by the keyboard.
                    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab || event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                        list.keyboardRing = true;
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

            // The focus ring is for the keyboard (macOS): it appears with the first key that moves the focus or the selection
            // (Tab, Down, Return in the search field; the arrows here) and goes with the focus, so a click on a row or the focus
            // coming back when the window is activated again shows none.
            property bool keyboardRing: false
            onActiveFocusChanged: if (!activeFocus)
                keyboardRing = false

            Keys.onPressed: event => {
                keyboardRing = true;
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
                required property int index
                readonly property bool selected: entry.modelData.id === root.selectedId || entry.modelData.id === root.parentOf(root.selectedId)
                // The first row of a new sidebar group: a gap above it (macOS 27). Search results are one list, without gaps.
                readonly property real gap: root.query.trim() === "" && entry.index > 0 && root.filtered[entry.index - 1].group !== entry.modelData.group
                    ? Tokens.settingsSidebarGroupGap : 0

                width: ListView.view.width
                height: Tokens.settingsSidebarItemHeight + entry.gap
                Accessible.role: Accessible.ListItem
                Accessible.name: countBadge.count > 0 ? entry.modelData.title + ", " + countBadge.spoken : entry.modelData.title
                Accessible.selectable: true
                Accessible.selected: entry.selected
                Accessible.onPressAction: root.select(entry.modelData.id)

                // The row itself, below the group gap.
                Item {
                    y: entry.gap
                    width: parent.width
                    height: Tokens.settingsSidebarItemHeight

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
                        visible: entry.selected && list.activeFocus && list.keyboardRing
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
                            right: countBadge.visible ? countBadge.left : parent.right
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

                    // Available updates (U19): a red count on General, and on Software Update among search results.
                    CountBadge {
                        id: countBadge
                        anchors.right: parent.right
                        anchors.rightMargin: Tokens.spacingSm
                        anchors.verticalCenter: parent.verticalCenter
                        count: entry.modelData.id === "general" || entry.modelData.id === "software-update" ? updateState.count : 0
                    }

                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            list.keyboardRing = false;
                            list.forceActiveFocus();
                            root.select(entry.modelData.id);
                        }
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

            // Back and forward: one 72 x 36 glass capsule with a hairline between them (macOS 27).
            leading: RimmedCapsule {
                width: navRow.width + Tokens.spacingXs
                height: Tokens.filesToolbarCapsule
                fillOpacity: Tokens.settingsToolbarFillOpacity
                Accessible.role: Accessible.Grouping
                Accessible.name: qsTr("Navigation")

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.hairline
                    height: Tokens.settingsToolbarDividerHeight
                    color: Appearance.withAlpha(Appearance.colors.shadow, Tokens.settingsToolbarDividerOpacity)
                }

                Row {
                    id: navRow
                    anchors.centerIn: parent

                    ToolButton {
                        capsule: true
                        buttonSize: Tokens.filesToolbarGroupButton
                        iconName: "chevron-right"
                        iconRotation: 180
                        enabled: NavHistory.canBack(root.navState)
                        accessibleName: qsTr("Back")
                        onClicked: root.navBack()
                    }

                    ToolButton {
                        capsule: true
                        buttonSize: Tokens.filesToolbarGroupButton
                        iconName: "chevron-right"
                        enabled: NavHistory.canForward(root.navState)
                        accessibleName: qsTr("Forward")
                        onClicked: root.navForward()
                    }
                }
            }

            // A pane with a state to show under its title (macOS 27 Battery: "Fully Charged" with the battery glyph): the title
            // moves up and the state goes under it.
            showTitle: root.pageSubtitle === ""

            Item {
                visible: root.pageSubtitle !== ""
                x: detailToolbar.titleStart
                width: detailToolbar.titleEnd - x
                height: detailToolbar.height
                Accessible.role: Accessible.Heading
                Accessible.name: root.sectionTitle + ", " + root.pageSubtitle

                Text {
                    textFormat: Text.PlainText
                    y: Tokens.settingsToolbarSubtitleTitleBaseline - baselineOffset
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.sectionTitle
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.windowTitleSize
                    font.weight: Tokens.typographyMenuBoldWeight
                }

                Icon {
                    id: subtitleGlyph
                    anchors.verticalCenter: subtitleText.verticalCenter
                    name: "battery"
                    size: Tokens.settingsWifiGlyphSize
                    color: Appearance.windowSecondary
                }

                Text {
                    id: subtitleText
                    textFormat: Text.PlainText
                    x: subtitleGlyph.width + Tokens.settingsToolbarSubtitleGlyphGap
                    y: Tokens.settingsToolbarSubtitleBaseline - baselineOffset
                    width: parent.width - x
                    elide: Text.ElideRight
                    text: root.pageSubtitle
                    color: Appearance.windowSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }
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
                if (root.notificationApp !== "")
                    return notificationAppPage;
                switch (root.selectedId) {
                case "wifi":
                    return wifiPage;
                case "bluetooth":
                    return bluetoothPage;
                case "network":
                    return networkPage;
                case "vpn":
                    return vpnPage;
                case "battery":
                    return batteryPage;
                case "sound":
                    return soundPage;
                case "displays":
                    return displaysPage;
                case "wallpaper":
                    return wallpaperPage;
                case "accessibility":
                    return accessibilityPage;
                case "accessibility-zoom":
                    return accessibilityZoomPage;
                case "accessibility-display":
                    return accessibilityDisplayPage;
                case "accessibility-motion":
                    return accessibilityMotionPage;
                case "accessibility-keyboard":
                    return accessibilityKeyboardPage;
                case "desktop":
                    return desktopPage;
                case "menubar":
                    return menuBarPage;
                case "search":
                    return searchPage;
                case "notifications":
                    return notificationsPage;
                case "focus":
                    return focusPage;
                case "dnd":
                    return dndPage;
                case "lock":
                    return lockPage;
                case "privacy":
                    return privacyPage;
                case "privacy-location":
                case "privacy-background":
                case "privacy-camera":
                case "privacy-remote-desktop":
                case "privacy-screen-sharing":
                    return privacyCategoryPage;
                case "mouse":
                    return mousePage;
                case "trackpad":
                    return trackpadPage;
                case "printers":
                    return printersPage;
                case "keyboard":
                    return keyboardPage;
                case "general":
                    return generalPage;
                case "about":
                    return aboutPage;
                case "software-update":
                    return softwareUpdatePage;
                case "storage":
                    return storagePage;
                case "datetime":
                    return dateTimePage;
                case "language":
                    return languagePage;
                case "login":
                    return loginItemsPage;
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
            onPasswordRequested: net => wifiPassword.openFor(net)
            onForgetRequested: net => forgetNetwork.openFor(net)
            onDetailsRequested: (net, device) => networkDetails.openFor(net, device)
        }
    }

    Component {
        id: networkPage
        NetworkPage {
            backend: root.backend
            system: sys
            onOpenRequested: id => root.select(id)
            onDetailsRequested: (name, device) => networkDetails.openForService(name, device)
        }
    }

    Component {
        id: vpnPage
        VpnPage {
            backend: root.backend
            system: sys
        }
    }

    Component {
        id: batteryPage
        BatteryPage {
            backend: root.backend
            system: sys
            onInfoRequested: (topic, power) => batteryInfo.openFor(topic, power)
        }
    }

    // Battery > (i): Battery Health, Charging (the charge limit goes back to the page).
    BatteryInfoSheet {
        id: batteryInfo
        onLimitRequested: on => {
            (page.item as BatteryPage)?.setLimit(on);
            batteryInfo.close();
        }
    }

    // Wi-Fi: a secured network's password, Details…, Forget This Network…: sheets over the whole window; the page acts on the
    // answers. Network shows an Ethernet service's addresses in the same details sheet.
    WifiPasswordSheet {
        id: wifiPassword
        onJoin: (net, psk) => (page.item as WifiPage)?.join(net, psk)
    }

    NetworkDetailsSheet {
        id: networkDetails
        onForgetRequested: net => forgetNetwork.openFor(net)
    }

    ForgetNetworkSheet {
        id: forgetNetwork
        onForget: net => (page.item as WifiPage)?.forget(net)
    }

    Component {
        id: bluetoothPage
        BluetoothPage {
            backend: root.backend
            system: sys
            onInfoRequested: device => bluetoothDevice.openFor(device)
            onForgetRequested: device => forgetDevice.openFor(device)
        }
    }

    // Bluetooth: a device's sheet and Forget This Device…; the page acts on the answers.
    BluetoothDeviceSheet {
        id: bluetoothDevice
        onConnectRequested: device => (page.item as BluetoothPage)?.connectDevice(device)
        onForgetRequested: device => forgetDevice.openFor(device)
    }

    ForgetDeviceSheet {
        id: forgetDevice
        onForget: device => (page.item as BluetoothPage)?.forget(device)
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
            system: sys
            onKeepRequested: until => displayKeep.openFor(until)
            onTrialEnded: displayKeep.close()
            onArrangeRequested: monitors => displayArrange.openFor(monitors)
        }
    }

    // Displays (ADR-0031): keep or revert a change while the shell counts down; Arrange… for several displays.
    DisplayKeepSheet {
        id: displayKeep
        canKeep: (page.item as DisplaysPage)?.trialApplied ?? false
        onKeep: (page.item as DisplaysPage)?.keep()
        onRevert: (page.item as DisplaysPage)?.revert()
    }

    ArrangeSheet {
        id: displayArrange
        onArranged: positions => (page.item as DisplaysPage)?.arrange(positions)
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
            onScreenSaverRequested: screenSaverSheet.open()
        }
    }

    Component {
        id: accessibilityPage
        AccessibilityPage {
            onOpen: id => root.select(id)
        }
    }

    Component {
        id: accessibilityZoomPage
        AccessibilityZoomPage {
            store: cfg
        }
    }

    Component {
        id: accessibilityDisplayPage
        AccessibilityDisplayPage {
            store: cfg
        }
    }

    Component {
        id: accessibilityMotionPage
        AccessibilityMotionPage {
            store: cfg
        }
    }

    Component {
        id: accessibilityKeyboardPage
        AccessibilityKeyboardPage {}
    }

    Component {
        id: desktopPage
        DesktopPage {
            store: cfg
            onScreenCornersRequested: screenCornersSheet.open()
        }
    }

    Component {
        id: menuBarPage
        MenuBarPage {
            store: cfg
            hasBattery: root.hasBattery
            backend: root.backend
            onClockOptionsRequested: clockSheet.open()
            onBatteryOptionsRequested: batteryOptionsSheet.open()
        }
    }

    Component {
        id: notificationsPage
        NotificationsPage {
            store: cfg
            backend: root.backend
            onAppRequested: name => root.select(root.notificationAppPrefix + name)
        }
    }

    Component {
        id: searchPage
        SearchPage {
            store: cfg
            onHistoryDeleteRequested: deleteSearchHistory.open()
            onClipboardClearRequested: {
                alsoPinned.checked = false;
                clearClipboardHistory.open();
            }
        }
    }

    Component {
        id: notificationAppPage
        NotificationAppPage {
            store: cfg
            app: root.notificationApp
        }
    }

    Component {
        id: focusPage
        FocusPage {
            store: cfg
            onOpen: id => root.select(id)
        }
    }

    Component {
        id: dndPage
        DoNotDisturbPage {
            store: cfg
        }
    }

    Component {
        id: lockPage
        LockPage {
            store: cfg
            hasBattery: root.hasBattery
            onMessageRequested: lockMessageSheet.open()
        }
    }

    Component {
        id: privacyPage
        PrivacyPage {
            backend: root.backend
            system: sys
            onOpen: id => root.select(id)
        }
    }

    // A category of Privacy & Security: the section id names its key in the permission state (Privacy.js).
    Component {
        id: privacyCategoryPage
        PrivacyCategoryPage {
            backend: root.backend
            system: sys
            key: ({"privacy-location": "location", "privacy-background": "background", "privacy-camera": "camera",
                    "privacy-remote-desktop": "remoteDesktop", "privacy-screen-sharing": "screencast"})[root.selectedId] ?? "location"
        }
    }

    Component {
        id: mousePage
        MousePage {
            backend: root.backend
            onOpenRequested: id => root.select(id)
        }
    }

    Component {
        id: trackpadPage
        TrackpadPage {
            backend: root.backend
            onOpenRequested: id => root.select(id)
        }
    }

    Component {
        id: printersPage
        PrintersPage {
            backend: root.backend
            system: sys
            onDetailsRequested: printer => printerSheet.openFor(printer)
            onAddRequested: {
                (page.item as PrintersPage)?.startSearching();
                addPrinter.openWith();
            }
        }
    }

    // Printers: a printer's sheet, Remove Printer…'s confirmation and Add Printer…; the page acts on the answers.
    PrinterSheet {
        id: printerSheet
        onRemoveRequested: printer => removePrinter.openFor(printer)
        onResumeRequested: name => (page.item as PrintersPage)?.resume(name)
    }

    RemovePrinterSheet {
        id: removePrinter
        onRemove: name => (page.item as PrintersPage)?.remove(name)
    }

    AddPrinterSheet {
        id: addPrinter
        found: (page.item as PrintersPage)?.found ?? []
        answered: (page.item as PrintersPage)?.foundAnswered ?? false
        onPicked: printer => (page.item as PrintersPage)?.add(printer)
        onShownChanged: {
            if (!addPrinter.shown)
                (page.item as PrintersPage)?.stopSearching();
        }
    }

    Component {
        id: keyboardPage
        KeyboardPage {
            backend: root.backend
            store: cfg
            onShortcutsRequested: list => keyboardShortcuts.openWith(list, root.backend.bindingsFile)
            onSourcesRequested: (sources, layouts) => inputSources.openWith(sources, layouts)
        }
    }

    // Keyboard: the shortcuts, read-only; Input Sources and the layout to add (the page writes each change).
    KeyboardShortcutsSheet {
        id: keyboardShortcuts
    }

    InputSourcesSheet {
        id: inputSources
        onChanged: list => (page.item as KeyboardPage)?.setSources(list)
        onAddRequested: (layouts, used) => layoutPicker.openWith(layouts, used)
    }

    LayoutPickerSheet {
        id: layoutPicker
        onPicked: source => inputSources.add(source)
    }

    Component {
        id: generalPage
        GeneralPage {
            updateCount: updateState.count
            onOpen: id => root.select(id)
        }
    }

    Component {
        id: softwareUpdatePage
        SoftwareUpdatePage {
            updates: updateState
            store: cfg
            system: sys
            onInfoRequested: topic => updateSheet.openFor(topic)
            onEndSessionRequested: action => (action === "restart" ? restartSheet : logOutSheet).open()
        }
    }

    // Software Update's (i) sheets, More Info… and the other updates.
    SoftwareUpdateSheet {
        id: updateSheet
        updates: updateState
        store: cfg
    }

    // Software Update > Log Out…, Restart… (U14): asked first, in the words of the Grassfield menu; then the session ends the way
    // that menu ends it (grassfield-session-end: every application may keep its window to save its work).
    Sheet {
        id: logOutSheet
        title: qsTr("Are you sure you want to quit all applications and log out now?")
        message: qsTr("Open applications will be closed.")
        confirmText: qsTr("Log Out")
        onAccepted: updateState.endSession("logout")
    }

    Sheet {
        id: restartSheet
        title: qsTr("Are you sure you want to restart your computer now?")
        message: qsTr("Open applications will be closed.")
        confirmText: qsTr("Restart")
        onAccepted: updateState.endSession("restart")
    }

    Component {
        id: aboutPage
        AboutPage {
            backend: root.backend
            system: sys
        }
    }

    Component {
        id: dateTimePage
        DateTimePage {
            backend: root.backend
            system: sys
            store: cfg
            onSetRequested: wall => timeSheet.openAt(wall)
        }
    }

    Component {
        id: storagePage
        StoragePage {
            backend: root.backend
            onAllVolumesRequested: volumesSheet.open()
        }
    }

    // Storage > All Volumes…: a sheet over the whole window.
    VolumesSheet {
        id: volumesSheet
        backend: root.backend
    }

    Component {
        id: loginItemsPage
        LoginItemsPage {
            backend: root.backend
            system: sys
            onAddRequested: apps => appPicker.openWith(apps)
        }
    }

    // Login Items > +: a sheet over the whole window; the page writes the choice.
    AppPickerSheet {
        id: appPicker
        onChosen: app => (page.item as LoginItemsPage)?.add(app)
    }

    Component {
        id: languagePage
        LanguagePage {
            backend: root.backend
            system: sys
            store: cfg
        }
    }

    // Date & Time > Set…: a sheet over the whole window; the page sends the answer to timedate1.
    SetDateTimeSheet {
        id: timeSheet
        onChosen: wall => (page.item as DateTimePage)?.setWallClock(wall)
    }

    // Menu Bar > Clock Options…: a sheet over the whole window.
    ClockOptionsSheet {
        id: clockSheet
        store: cfg
    }

    // Search > Delete Search History…: asked first, as macOS does; Search forgets the results picked before now.
    Sheet {
        id: deleteSearchHistory
        title: qsTr("Delete your search history?")
        message: qsTr("Search forgets the results you picked, so it no longer puts them first.")
        confirmText: qsTr("Delete")
        destructive: true
        onAccepted: cfg.set("search.historyResetAt", Date.now())
    }

    // Search > Clear Clipboard History…: asked first (macOS 27: Clear Clipboard History, then Clear). The shell's clipboard
    // history deletes the items not pinned; with "Also delete pinned items" the pinned ones too, from memory and the disk
    // (ADR-0034 §6). SearchPage.clearClipboard writes both keys at once.
    Sheet {
        id: clearClipboardHistory
        title: qsTr("Clear your clipboard history?")
        message: qsTr("The items you copied are deleted from Search. Pinned items stay unless you delete them too.")
        confirmText: qsTr("Clear")
        destructive: true
        onAccepted: (page.item as SearchPage)?.clearClipboard(alsoPinned.checked)

        CheckBox {
            id: alsoPinned
            text: qsTr("Also delete pinned items")
        }
    }

    // Wallpaper > Screen Saver… (ADR-0032); Lock Screen Settings… in its note opens the Lock Screen pane.
    ScreenSaverSheet {
        id: screenSaverSheet
        store: cfg
        hasBattery: root.hasBattery
        onLockScreenRequested: {
            screenSaverSheet.close();
            root.select("lock");
        }
    }

    // Lock Screen > Show message when locked > Set…
    LockMessageSheet {
        id: lockMessageSheet
        store: cfg
    }

    // Menu Bar > Battery Options…
    BatteryOptionsSheet {
        id: batteryOptionsSheet
        store: cfg
    }

    // Desktop & Dock > Screen Corners…
    ScreenCornersSheet {
        id: screenCornersSheet
        store: cfg
    }

    // Every sheet of the window. Each gives the keyboard focus back, when it closes, to what had it as the sheet appeared (the
    // page's button that opened it; Sheet.open shows the sheet before it moves the focus into its panel): focusBack.
    readonly property list<Item> sheets: [batteryInfo, wifiPassword, networkDetails, forgetNetwork, bluetoothDevice, forgetDevice,
        displayKeep, displayArrange, printerSheet, removePrinter, addPrinter, keyboardShortcuts, inputSources, layoutPicker,
        volumesSheet, appPicker, timeSheet, clockSheet, deleteSearchHistory, clearClipboardHistory, screenSaverSheet,
        lockMessageSheet, batteryOptionsSheet, screenCornersSheet, updateSheet, logOutSheet, restartSheet]

    Instantiator {
        model: root.sheets

        delegate: Connections {
            id: opener
            required property Sheet modelData
            target: opener.modelData

            function onShownChanged(): void {
                if (opener.modelData.shown)
                    opener.modelData.focusBack = root.activeFocusItem;
            }
        }
    }
}
