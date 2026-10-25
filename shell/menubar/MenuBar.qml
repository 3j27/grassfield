pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import Grassfield.Ui
import qs.notifications
import qs.platform
import qs.services
import "BarHide.js" as BarHide
import "../dock/AutoHide.js" as AutoHide
import "StatusLogic.js" as Logic

// Top bar, one per screen. Left: Grassfield menu (leaf mark), the focused app name with its
// application menu, then the app's own menus when it exports them (T1/T2 through MenuBridge) or the
// T0 File menu, then Window. Right (real backends only): network, volume, battery (when present),
// Control Center, clock. Popups are rendered by qs.overlay through Popups.
Scope {
    id: root

    // The Search status item asks the shell to toggle Search (shell.qml owns it); `searchActive` lights the item while open.
    property bool searchActive: false
    signal searchRequested

    // Test and keyboard hook: qs ipc call menubar open <system|app|volume|network|battery|controlcenter> <output|"">.
    IpcHandler {
        target: "menubar"

        // screen: output name, empty for the first one.
        function open(kind: string, screen: string): void {
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            const wanted = screen !== "" ? screen : Compositor.focusedScreenName;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === wanted)
                    bar = all[i];
            }
            if (bar)
                bar.popup(kind);
        }

        // Centered panels without a bar anchor: about, forcequit.
        function panel(kind: string, screen: string): void {
            Popups.open(kind, screen, 0, 0, "center", {});
        }

        // Test hook: refused outside a dev session (VisualFixtures.dev), like every read-only hook below (SEC-04).
        function close(): void {
            if (VisualFixtures.dev)
                Popups.close();
        }

        // Test hook (tests/visual/menubar-macos.sh): the open popup's kind and output, "" when none. Read-only.
        function openKind(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Popups.active ? Popups.kind + "@" + Popups.screenName : "";
        }

        // Test hook (tests/visual/menubar-macos.sh): "held" while the overlay waits for the end of a press on the bar before it
        // takes the keyboard (a press whose release the bar never saw would leave it so: keys then reach the window below).
        function keyboardWait(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Popups.active && Popups.pointerHeld ? "held" : "";
        }

        // Test hook (tests/visual/menubar-status.sh): JSON {menusRight, status: [{name, x, w}]} of the bar of `screen`.
        function statusState(screen: string): string {
            if (!VisualFixtures.dev)
                return "refused";
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    bar = all[i];
            }
            return bar ? JSON.stringify({menusRight: bar.menusRight(), status: bar.statusRects()}) : "{}";
        }

        // Test hook (tests/visual/menubar-macos.sh): the auto-hide state of an output's bar as JSON. Read-only.
        function autohide(screen: string): string {
            if (!VisualFixtures.dev)
                return "refused";
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    bar = all[i];
            }
            if (!bar)
                return "{}";
            return JSON.stringify({
                mode: bar.hideMode,
                fullscreen: bar.fullscreen,
                hides: bar.autoHides,
                state: bar.hideMachine.state,
                visible: bar.hideMachine.visible,
                away: bar.away,
                overlay: BarHide.overlayLayer(bar.fullscreen),
                zone: bar.exclusiveZone
            });
        }

        // Test hook (tests/integration/global_menus.sh): JSON with the shown window, the bridge state, the bar's
        // left titles and, when a bridge menu is open, its rows (submenus included), in output coordinates.
        function bridgeState(screen: string): string {
            if (!VisualFixtures.dev)
                return "refused";
            const all = bars.instances;
            let bar = all.length > 0 ? all[0] : null;
            for (let i = 0; i < all.length; i++) {
                if (all[i].screen.name === screen)
                    bar = all[i];
            }
            return JSON.stringify({
                window: MenuBridge.window,
                windowAppId: MenuBridge.windowAppId,
                connected: MenuBridge.connected,
                registrar: MenuBridge.registrar,
                menus: MenuBridge.menus.map(m => m.title),
                bar: bar ? bar.titleRects() : [],
                popup: Popups.kind === "appbridge" && MenuBridge.popup ? root.rowRects(MenuBridge.popup) : []
            });
        }
    }

    // Rows of an open bridge menu and of its open submenus: [{text, dbusId, enabled, submenu, x, y, w, h}].
    function rowRects(menu: Item): var {
        const out = [];
        const walk = item => {
            const kids = item.children;
            for (let i = 0; i < kids.length; i++) {
                const k = kids[i];
                // PopupMenu rows are delegates with a `modelData` item (generic Item access: no static type).
                const data = k["modelData"];
                if (data && typeof data === "object" && data.dbusId !== undefined && k.visible) {
                    const p = k.mapToItem(null, 0, 0);
                    out.push({text: data.text, dbusId: data.dbusId, enabled: data.enabled !== false, submenu: data.submenu !== undefined, x: Math.round(p.x), y: Math.round(p.y), w: Math.round(k.width), h: Math.round(k.height)});
                }
                walk(k);
            }
        };
        walk(menu);
        return out;
    }

    // Test hook: set Control Center values the way the UI does (persisted too). Refused outside a dev session
    // (VisualFixtures.dev, SEC-04): another process must not change the user's settings behind their back.
    IpcHandler {
        target: "controlcenter"

        function transparency(value: real): void {
            if (VisualFixtures.dev)
                Settings.setTransparency(value);
        }

        function appearance(name: string): void {
            if (VisualFixtures.dev)
                Settings.setAppearance(name);
        }

        function reduceTransparency(on: bool): void {
            if (VisualFixtures.dev)
                Settings.setReduceTransparency(on);
        }

        function reduceMotion(on: bool): void {
            if (VisualFixtures.dev)
                Settings.setReduceMotion(on);
        }

        // The Sound and Display sliders by IPC (REQ-QS-CC5/CC6 acceptance: set the slider, then `wpctl get-volume
        // @DEFAULT_AUDIO_SINK@` or `brightnessctl` agrees). Test hooks, so refused outside a dev session (SEC-04: another
        // process must not drive the shell's controls); in the dev session the sliders' own dev guard then answers
        // "refused: dev guard" and changes nothing (tests/shell/cc_sliders_ipc.sh). `value` is 0..1.
        function volume(value: real): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Audio.deviceReady ? (Audio.setVolume(value) ? "ok" : "refused: dev guard") : "unavailable: no output";
        }

        function brightness(value: real): string {
            if (!VisualFixtures.dev)
                return "refused";
            if (!Brightness.deviceAvailable)
                return "unavailable: no backlight";
            return Brightness.setLevel(value) ? "ok" : "refused: dev guard";
        }

        // Read-only: the level the sliders show, 0..1 with two decimals ("none" without the device). Dev session only.
        function volumeLevel(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Audio.deviceReady ? Audio.deviceVolume.toFixed(2) : "none";
        }

        function brightnessLevel(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return Brightness.deviceAvailable ? Brightness.deviceLevel.toFixed(2) : "none";
        }

        // Read-only: what the shell applies of the Quick Settings values, as JSON (tests/visual/flow-quicksettings.sh,
        // flow-settings.sh). `nightShift` is "hidden" when the helper or hyprsunset is missing (the switch is not
        // shown), else "off" or "on". Dev session only.
        function state(): string {
            if (!VisualFixtures.dev)
                return "refused";
            return JSON.stringify({
                appearance: Settings.appearance,
                dark: Settings.dark,
                transparency: Math.round(Settings.transparency * 100) / 100,
                reduceTransparency: Settings.reduceTransparency,
                reduceMotion: Settings.reduceMotion,
                dnd: Notifications.dnd,
                nightShift: NightShift.available ? (NightShift.on ? "on" : "off") : "hidden"
            });
        }
    }

    Variants {
        id: bars

        model: Quickshell.screens

        // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: win

            required property ShellScreen modelData

            // Gate P5: the first frame of this bar counts toward "grassfield-shell: usable" (platform/Usable.qml).
            UsableProbe {
                kind: "bar"
                screenName: win.modelData ? win.modelData.name : ""
            }

            // Last non-empty app: layer-shell focus (a popup is open) clears the active toplevel.
            // It only counts while that app still has a window: a killed last window must not leave
            // its name in the bar.
            property string lastAppId: ""
            readonly property bool lastAppAlive: {
                if (lastAppId === "")
                    return false;
                const list = Compositor.toplevels.values;
                for (let i = 0; i < list.length; i++) {
                    if (list[i].appId === lastAppId)
                        return true;
                }
                return false;
            }
            // The desktop holds the keyboard: Hyprland still reports the last window as active, the bar shows the desktop (Finder).
            // With Stages on and no active window (an Exclusive layer holds the keyboard after a swap) the front app of the
            // Stages state is named (display only, AppMenus.context disables the window commands).
            readonly property string shownAppId: DesktopState.holdsKeyboard ? "" : Compositor.focusedAppId !== "" ? Compositor.focusedAppId : (Popups.active && lastAppId !== "" && lastAppAlive ? lastAppId : Compositor.stagesFrontAppId)
            readonly property string appName: {
                if (shownAppId === "")
                    return qsTr("Desktop");
                return Apps.nameFor(shownAppId);
            }
            readonly property bool hasApp: shownAppId !== ""
            // The app's own menus (T1/T2, MenuBridge) for the shown app: [{dbusId, title, enabled}], [] when it
            // exports none (GTK4, Electron, no plugin or bridge): the T0 menus then stay. MenuBridge is read first
            // so that the singleton (bridge connection, appmenu registrations) exists from the start.
            readonly property var bridgeMenus: MenuBridge.menus.length > 0 && hasApp && MenuBridge.windowAppId.toLowerCase() === shownAppId.toLowerCase() ? MenuBridge.menus : []
            // T0 File (desktop entry actions) gives way to the app's own menus; the actions stay in the Dock menu.
            readonly property bool hasFileMenu: hasApp && bridgeMenus.length === 0 && AppMenus.model.hasFileMenu(AppMenus.context(shownAppId))
            // Transparent by default (like macOS 26/27); `menubar.showBackground` restores the frosted band, and so does a wallpaper
            // strip over which neither tone reaches 4.5:1 (BarTone.assistOf, ADR-0016: shown on that output until the wallpaper changes).
            // Over a full-screen window the bar is drawn on that window's content, not on the wallpaper the tone was measured on: the frosted band then (macOS does the same).
            readonly property bool showBackground: Settings.menubarShowBackground || BarTone.assistOf(win.screen.name) || win.fullscreen
            // Without a background the bar sits on the wallpaper and its foreground adapts to the wallpaper strip under this
            // output's bar (BarTone, the macOS model): white text over a dark wallpaper, black over a light one, with a faint
            // shadow of the opposite colour (gate A2). On the material it is the appearance's text colour.
            readonly property bool darkTone: BarTone.toneOf(win.screen.name) === "dark"
            readonly property var barPalette: darkTone ? Appearance.lightColors : Appearance.darkColors
            readonly property color barText: showBackground ? Appearance.colors.text : barPalette.barText
            readonly property color barTextDisabled: Appearance.withAlpha(showBackground ? Appearance.colors.text : barPalette.barText, Tokens.materialDisabledOpacity)
            readonly property color barTint: showBackground ? Appearance.colors.hover : barPalette.hover
            readonly property color barShadow: darkTone ? barPalette.materialHighlight : barPalette.shadow
            readonly property var battery: UPower.displayDevice
            // Now Playing (macOS: "Show When Active"): while a player has a session (playing, or paused with a track).
            readonly property bool showNowPlaying: Logic.nowPlayingShown(Settings.menubarShowNowPlaying, Media.available, Media.playing, Media.title)
            // Crowding (macOS: status items that would collide with the menus are hidden): the status area gets the width
            // between the application menus and the right inset; optional items (third-party, Now Playing, Search) give way
            // leftmost first, never the system items, Quick Settings or the clock (StatusLogic.hiddenItems). Implicit widths
            // only: a hidden item never changes the decision.
            readonly property real statusIconWidth: Tokens.menubarIconSize + 2 * Tokens.menubarStatusItemPadding
            readonly property var statusItems: {
                const list = [];
                const trays = TrayHost.items;
                for (let i = 0; i < trays.length; i++)
                    list.push({key: "tray" + i, width: statusIconWidth, optional: true});
                if (showNowPlaying)
                    list.push({key: "nowplaying", width: statusIconWidth, optional: true});
                list.push({key: "system", width: (Notifications.dnd ? dndButton.implicitWidth : 0) + networkButton.implicitWidth + volumeButton.implicitWidth + (hasBattery ? batteryButton.implicitWidth : 0), optional: false});
                if (Settings.menubarShowSearch)
                    list.push({key: "search", width: statusIconWidth, optional: true});
                list.push({key: "core", width: ccButton.implicitWidth + clockButton.implicitWidth, optional: false});
                return list;
            }
            // Width of the status items that never give way (system items, Quick Settings, clock).
            readonly property real statusMandatoryWidth: {
                let sum = 0;
                for (let i = 0; i < statusItems.length; i++) {
                    if (!statusItems[i].optional)
                        sum += statusItems[i].width;
                }
                return sum;
            }
            // Room for the application name: the bar minus the insets, the fixed titles and the mandatory status items.
            readonly property real appTitleMax: Math.max(0, win.width - (Tokens.menubarInsetLeft - Tokens.menubarItemPadding) - (Tokens.menubarInsetRight - Tokens.menubarItemPadding)
                - systemButton.implicitWidth - (hasFileMenu ? fileButton.implicitWidth : 0) - (hasApp ? windowButton.implicitWidth : 0)
                - 2 * Tokens.menubarItemPadding - statusMandatoryWidth - 2 * Tokens.menubarItemPadding)
            readonly property real statusAvailable: win.width - (Tokens.menubarInsetRight - Tokens.menubarItemPadding) - (leftRow.x + leftRow.width) - Tokens.menubarItemPadding
            readonly property var hiddenStatus: Logic.hiddenItems(statusAvailable, statusItems, 0)
            readonly property bool hasBattery: !VisualFixtures.active && battery !== null && battery.isPresent && battery.isLaptopBattery

            // SingleMainWindow of the app's desktop entry decides whether File has New Window.
            onShownAppIdChanged: {
                // The app is gone: its open app menu would act on nothing.
                if (shownAppId === "" && ["app", "appfile", "appwindow", "appbridge"].indexOf(Popups.kind) >= 0 && Popups.screenName === (win.screen ? win.screen.name : ""))
                    Qt.callLater(Popups.close);
                const entry = shownAppId !== "" ? Apps.lookup(shownAppId) : null;
                if (entry)
                    AppMenus.probe(entry.id);
            }

            Connections {
                target: Compositor

                function onFocusedAppIdChanged(): void {
                    if (Compositor.focusedAppId !== "")
                        win.lastAppId = Compositor.focusedAppId;
                }
            }

            // Forget the remembered app once its last window is gone. Deferred: writing lastAppId from this
            // handler would re-enter the lastAppAlive binding (binding loop).
            onLastAppAliveChanged: {
                if (!lastAppAlive && lastAppId !== "")
                    Qt.callLater(() => {
                        if (!win.lastAppAlive)
                            win.lastAppId = "";
                    });
            }

            // The app's menus went away (window closed, app quit, bridge gone): an open one would act on nothing.
            onBridgeMenusChanged: {
                if (bridgeMenus.length === 0 && isOpen("appbridge"))
                    Qt.callLater(Popups.close);
            }

            // Auto-hide (macOS "Automatically hide and show the menu bar", BarHide.js): the Dock's state machine (AutoHide.js) per
            // output. The bar window keeps its size; only the content slides, and only the edge strip takes input while it is
            // away. Over a full-screen window it sits on the overlay layer (Hyprland draws full-screen windows above the top layer).
            readonly property string hideMode: BarHide.normalize(Settings.menubarAutoHide)
            readonly property bool fullscreen: Compositor.fullscreenOn(win.screen.name, Compositor.topologyRevision)
            readonly property bool autoHides: BarHide.hides(hideMode, fullscreen)
            property var hideMachine: AutoHide.create()
            // A menu of this bar open (or Notification Center from the clock) keeps it in view; the pointer on the bar or its edge strip too.
            readonly property var hideInhibitors: ({
                    pointer: winHover.hovered,
                    popup: tracking || (Notifications.centerOpen && Notifications.centerScreen === (win.screen ? win.screen.name : ""))
                })
            readonly property var hideTiming: ({
                    hideGrace: Tokens.menubarHideGrace,
                    hideDuration: Appearance.reduceMotion ? 0 : Tokens.menubarHideDuration,
                    revealDwell: Tokens.menubarRevealDwell,
                    revealDuration: Appearance.reduceMotion ? 0 : Tokens.menubarRevealDuration
                })
            readonly property bool away: autoHides && hideMachine.state === "hidden" && !AutoHide.forcing(hideInhibitors)
            readonly property real slideY: BarHide.slideOffset(Tokens.menubarHeight, AutoHide.ease(hideMachine.visible))

            // The Now Playing item went away (player closed, switched off in Settings): its open popover would act on nothing.
            onShowNowPlayingChanged: {
                if (!showNowPlaying && isOpen("nowplaying"))
                    Qt.callLater(Popups.close);
            }

            function isOpen(kind: string): bool {
                return Popups.kind === kind && Popups.screenName === (win.screen ? win.screen.name : "");
            }

            // macOS menu tracking: while one of this bar's menus is open, moving onto another title or status item opens
            // its menu without a click. The clock (Notification Center) and the Do Not Disturb indicator are not menus.
            readonly property var trackedKinds: ["system", "app", "appfile", "appwindow", "appbridge", "network", "volume", "battery", "controlcenter", "tray", "nowplaying"]
            readonly property bool tracking: Popups.active && Popups.screenName === (win.screen ? win.screen.name : "") && trackedKinds.indexOf(Popups.kind) >= 0

            function hoverSwitch(kind: string): void {
                if (win.tracking && Popups.kind !== kind)
                    win.popup(kind);
            }

            function hoverSwitchBridge(button: Item, menu: var): void {
                if (win.tracking && !(Popups.kind === "appbridge" && Popups.data.dbusId === menu.dbusId))
                    win.openBridge(button, menu);
            }

            function hoverSwitchTray(button: Item, item: var): void {
                if (item && win.tracking && !(Popups.kind === "tray" && Popups.data.item === item))
                    win.openTray(button, item);
            }

            // Opens (or closes, if it is open) a status item's own menu, aligned to the right edge of its button.
            function openTray(button: Item, item: var): void {
                if (isOpen("tray") && Popups.data.item === item) {
                    Popups.close();
                    return;
                }
                const x = button.mapToItem(null, button.width, 0).x;
                Popups.open("tray", (win.screen ? win.screen.name : ""), x, Tokens.menubarHeight, "right", {item: item});
            }

            // Left titles that open a menu, in bar order: [{kind, button, menu}] (menu: the bridge entry, else null).
            function menuTitles(): var {
                const out = [];
                const kids = leftRow.children;
                let bridge = 0;
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i];
                    const name = k.objectName;
                    if (name.indexOf("menubar-") !== 0)
                        continue;
                    const sep = name.indexOf(":");
                    const kind = sep < 0 ? name.slice(8) : name.slice(8, sep);
                    const menu = kind === "bridge" ? win.bridgeMenus[bridge++] : null;
                    if (!k.visible || (menu && !menu.enabled))
                        continue;
                    out.push({kind: kind, button: k, menu: menu});
                }
                return out;
            }

            // Every item the keyboard cycle reaches, in bar order: the left titles, then the status items that open a menu
            // (third-party tray items first). Search, the clock and Do Not Disturb are not menus: they have their own keys.
            function navEntries(): var {
                const out = win.menuTitles();
                const kids = rightRow.children;
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i] as BarButton;
                    if (!k || !k.visible || !k.opensMenu)
                        continue;
                    if (k.objectName === "menubar-tray")
                        out.push({kind: "tray", button: k, menu: null});
                    else if (k.menuKind !== "")
                        out.push({kind: k.menuKind, button: k, menu: null});
                }
                return out;
            }

            readonly property var popupKindOf: ({system: "system", app: "app", bridge: "appbridge", file: "appfile", window: "appwindow"})

            function isEntryOpen(t: var): bool {
                const popupKind = win.popupKindOf[t.kind] !== undefined ? win.popupKindOf[t.kind] : t.kind;
                if (popupKind !== Popups.kind)
                    return false;
                if (t.menu)
                    return Popups.data.dbusId === t.menu.dbusId;
                if (t.kind === "tray")
                    return Popups.data.item === t.button.item;
                return true;
            }

            function openEntry(t: var): void {
                if (t.menu)
                    win.openBridge(t.button, t.menu);
                else if (t.kind === "tray")
                    win.openTray(t.button, t.button.item);
                else
                    win.popup(t.kind === "file" ? "appfile" : t.kind === "window" ? "appwindow" : t.kind);
            }

            // Left/Right in an open menu (macOS): the previous or next item's menu, wrapping around.
            function stepMenu(direction: int): void {
                const titles = win.navEntries();
                let at = -1;
                for (let i = 0; i < titles.length; i++) {
                    if (win.isEntryOpen(titles[i]))
                        at = i;
                }
                if (at < 0 || titles.length < 2)
                    return;
                win.openEntry(titles[(at + direction + titles.length) % titles.length]);
            }

            // Ctrl+F8 (macOS "move focus to the status menus"): the first status item's menu; no status menu: nothing.
            function openFirstStatus(): void {
                const all = win.navEntries();
                for (let i = 0; i < all.length; i++) {
                    if (["network", "volume", "battery", "controlcenter", "nowplaying", "tray"].indexOf(all[i].kind) >= 0) {
                        win.openEntry(all[i]);
                        return;
                    }
                }
            }

            Connections {
                target: Popups

                function onMenuStepRequested(screen: string, direction: int): void {
                    if (screen === (win.screen ? win.screen.name : ""))
                        win.stepMenu(direction);
                }
            }

            // The bar button under x (output coordinates), null for none.
            function buttonAt(x: real): BarButton {
                const rows = [leftRow, rightRow];
                for (let r = 0; r < rows.length; r++) {
                    const kids = rows[r].children;
                    for (let i = 0; i < kids.length; i++) {
                        const k = kids[i] as BarButton;
                        if (!k || !k.visible)
                            continue;
                        const left = k.mapToItem(null, 0, 0).x;
                        if (x >= left && x < left + k.width)
                            return k;
                    }
                }
                return null;
            }

            // The overlay's share of the bar strip while a popup is open (Popups.bars): moving onto a menu item switches to
            // its menu; a press acts like a click on that item (the open one closes, another opens), and a press on the
            // clock, the Do Not Disturb item or empty bar closes the open menu first.
            function trackAt(x: real): void {
                const b = win.buttonAt(x);
                if (b && b.opensMenu)
                    b.entered();
            }

            function pressAt(x: real, button: string): void {
                const b = win.buttonAt(x);
                if (!b || !b.opensMenu)
                    Popups.close();
                if (!b)
                    return;
                if (button === "right" || button === "middle")
                    b.auxPressed(button);
                else
                    b.activated();
            }

            Component.onCompleted: Popups.registerBar(win.screen.name, win)
            Component.onDestruction: Popups.unregisterBar(win.screen.name, win)

            // Opens a popup under (left) or aligned to the right edge of (right) a bar button.
            function openFor(kind: string, button: Item, alignment: string, payload: var): void {
                const x = button.mapToItem(null, alignment === "right" ? button.width : 0, 0).x;
                Popups.toggle(kind, (win.screen ? win.screen.name : ""), x, Tokens.menubarHeight, alignment, payload);
            }

            // Opens (or closes, if it is open) one of the app's own menus under its title.
            function openBridge(button: Item, menu: var): void {
                if (!menu.enabled)
                    return;
                if (isOpen("appbridge") && Popups.data.dbusId === menu.dbusId) {
                    Popups.close();
                    return;
                }
                const x = button.mapToItem(null, 0, 0).x;
                Popups.open("appbridge", (win.screen ? win.screen.name : ""), x, Tokens.menubarHeight, "left", {dbusId: menu.dbusId, window: MenuBridge.window, title: menu.title});
                MenuBridge.aboutToShow(menu.dbusId);
            }

            // Left titles in output coordinates (test hook): [{kind, title, x, y, w, h}], kind app|bridge|file|window.
            function titleRects(): var {
                const out = [];
                const kids = leftRow.children;
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i];
                    const name = k.objectName;
                    if (!k.visible || name.indexOf("menubar-") !== 0)
                        continue;
                    const p = k.mapToItem(null, 0, 0);
                    const sep = name.indexOf(":");
                    out.push({kind: sep < 0 ? name.slice(8) : name.slice(8, sep), title: sep < 0 ? "" : name.slice(sep + 1), x: Math.round(p.x), y: Math.round(p.y), w: Math.round(k.width), h: Math.round(k.height)});
                }
                return out;
            }

            // Visible status buttons in output coordinates (test hook): [{name, x, w}] left to right, and the right edge of the
            // application menus (`menusRight`), to check that the two never overlap.
            function statusRects(): var {
                const out = [];
                const kids = rightRow.children;
                for (let i = 0; i < kids.length; i++) {
                    const k = kids[i] as BarButton;
                    if (!k || !k.visible)
                        continue;
                    out.push({name: k.accessibleName, x: Math.round(k.mapToItem(null, 0, 0).x), w: Math.round(k.width)});
                }
                return out;
            }

            function menusRight(): real {
                return Math.round(leftRow.mapToItem(null, leftRow.width, 0).x);
            }

            function popup(kind: string): void {
                switch (kind) {
                case "status":
                    win.openFirstStatus();
                    break;
                case "system":
                    openFor("system", systemButton, "left", {});
                    break;
                case "app":
                    openFor("app", appButton, "left", {appId: win.shownAppId});
                    break;
                case "appfile":
                    openFor("appfile", fileButton, "left", {appId: win.shownAppId});
                    break;
                case "appwindow":
                    openFor("appwindow", windowButton, "left", {appId: win.shownAppId});
                    break;
                case "network":
                    openFor("network", networkButton, "right", {});
                    break;
                case "volume":
                    openFor("volume", volumeButton, "right", {});
                    break;
                case "battery":
                    if (win.hasBattery)
                        openFor("battery", batteryButton, "right", {});
                    break;
                case "controlcenter":
                    openFor("controlcenter", ccButton, "right", {});
                    break;
                case "nowplaying":
                    if (win.showNowPlaying)
                        openFor("nowplaying", nowPlayingButton, "right", {});
                    break;
                }
            }

            screen: modelData
            anchors {
                top: true
                left: true
                right: true
            }
            implicitHeight: Tokens.menubarHeight
            // Only a bar that is on the desktop in its mode reserves space, constantly: reveal and hide never reflow windows.
            exclusiveZone: BarHide.reservesSpace(hideMode) ? Tokens.menubarHeight : 0
            color: "transparent"
            // Never the keyboard: hovering or starting must never take it from the focused window, and while one of this
            // bar's menus is open its popup holds it (Exclusive, shell/overlay; CTRL+F2 opens the system menu that way).
            // An OnDemand bar took the keyboard as a menu closed with the pointer resting on the bar (Hyprland gives an
            // on-demand layer under the pointer the keyboard when it refocuses), so the window it still counted active lost
            // its keys (tests/compositor/click_focus.sh).
            focusable: false
            WlrLayershell.layer: BarHide.overlayLayer(win.fullscreen) ? WlrLayer.Overlay : WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-menubar"
            // Quickshell qmltypes name this property's type PendingRegion/FileViewAdapter without exporting it (metadata quirk).
            // qmllint disable missing-type
            BackgroundEffect.blurRegion: win.showBackground && material.blurActive && win.hideMachine.visible > 0 ? blurRegion : null
            // The bar, or only the top edge strip while it is away.
            mask: Region {
                item: hitItem
            }
            // qmllint enable missing-type

            Region {
                id: blurRegion
                item: material
                radius: material.radius
            }

            Item {
                id: hitItem
                width: win.width
                height: BarHide.inputHeight(Tokens.menubarHeight, Tokens.menubarRevealZone, win.away)
            }

            // The menu bar window is mapped for the whole session: it hosts the idle reads of the icon shapes (the first output's
            // bar only), so that the Apps panel opens with every icon's shape known (PERF-01).
            IconShapePrewarm {
                sources: Quickshell.screens.length > 0 && win.screen && Quickshell.screens[0].name === (win.screen ? win.screen.name : "") ? Apps.listedIconSources : []
            }

            HoverHandler {
                id: winHover
                onPointChanged: if (hovered)
                    PointerTracker.report(win.screen.name, point.position.x, point.position.y)
            }

            // Press, drag, release (macOS): a title opens its menu on the press and the button is still down, so the pointer
            // stays with this window (implicit grab) as it moves down onto the menu. Relay it to the open menu (it highlights
            // the row under the pointer) and, on the release, let it run that row; a release on no row leaves the menu open.
            PointHandler {
                id: menuDrag
                property real lastX: 0
                property real lastY: 0
                acceptedButtons: Qt.LeftButton
                onPointChanged: {
                    lastX = point.scenePosition.x;
                    lastY = point.scenePosition.y;
                    if (active)
                        Popups.trackPointer(win.screen.name, lastX, lastY);
                }
                onActiveChanged: {
                    if (active) {
                        Popups.pointerHeld = true;
                    } else {
                        Popups.releasePointer(win.screen.name, lastX, lastY);
                        Popups.pointerHeld = false;
                    }
                }
            }

            // Frame clock of the auto-hide machine: stops while nothing can change (away and idle, or in view and held).
            FrameAnimation {
                running: AutoHide.active(win.hideMachine, win.hideInhibitors, win.autoHides)
                onTriggered: win.hideMachine = AutoHide.step(win.hideMachine, win.hideInhibitors, win.autoHides, win.hideTiming, Math.min(frameTime * 1000, 100))
            }

            WallClock {
                id: clock
            }

            // macOS: with several displays the menu bar of the one that is not active is dimmed (band and content). A single
            // output, no focused output known, or a bar with one of its menus open (the user is using it, whatever output
            // Hyprland counts as focused) is never dimmed.
            readonly property bool dimmed: Quickshell.screens.length > 1 && Compositor.focusedScreenName !== "" && Compositor.focusedScreenName !== (win.screen ? win.screen.name : "")
                && !(Popups.active && Popups.screenName === (win.screen ? win.screen.name : ""))
            property real dimOpacity: win.dimmed ? Tokens.menubarInactiveOpacity : 1

            Behavior on dimOpacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            Material {
                id: material
                y: win.slideY
                width: parent.width
                height: parent.height
                opacity: win.dimOpacity
                visible: win.showBackground
                radius: Tokens.radiusMenuBar
                shadowEnabled: false
                highlightEnabled: false
                borderEnabled: false

                // Hairline along the bottom edge instead of a full border.
                Rectangle {
                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                    }
                    height: 1
                    color: Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity)
                }
            }

            // Content: drawn straight on the wallpaper unless the user turns the background on (Settings, Menu Bar).
            Item {
                id: barContent
                y: win.slideY
                width: parent.width
                height: parent.height
                opacity: win.dimOpacity

                    Row {
                        id: leftRow
                        anchors {
                            left: parent.left
                            leftMargin: Tokens.menubarInsetLeft - Tokens.menubarItemPadding
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 0

                        BarButton {
                            id: systemButton
                            objectName: "menubar-system"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            accessibleName: qsTr("Grassfield menu")
                            active: win.isOpen("system")
                            onActivated: win.popup("system")
                            opensMenu: true
                            onEntered: win.hoverSwitch("system")

                            Icon {
                                size: Tokens.menubarIconSize
                                color: win.barText
                                name: "grassfield-logo"
                            }
                        }

                        BarButton {
                            id: appButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            objectName: "menubar-app"
                            accessibleName: qsTr("Application menu: %1").arg(win.appName)
                            active: win.isOpen("app")
                            onActivated: win.popup("app")
                            opensMenu: true
                            onEntered: win.hoverSwitch("app")

                            Text {
                                textFormat: Text.PlainText
                                text: win.appName
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuBoldWeight
                                elide: Text.ElideRight
                                // A name too long for the room the always-present status items leave is elided.
                                width: Math.min(implicitWidth, win.appTitleMax)
                            }
                        }

                        // The app's own menus (T1/T2), in the app's order.
                        Repeater {
                            model: win.bridgeMenus

                            delegate: BarButton {
                                id: bridgeButton
                                tint: win.barTint
                                shadowed: !win.showBackground
                            shadowColor: win.barShadow

                                required property var modelData

                                objectName: "menubar-bridge:" + modelData.title
                                accessibleName: qsTr("%1 menu").arg(modelData.title)
                                active: win.isOpen("appbridge") && Popups.data.dbusId === modelData.dbusId
                                onActivated: win.openBridge(bridgeButton, bridgeButton.modelData)
                                opensMenu: true
                                onEntered: win.hoverSwitchBridge(bridgeButton, bridgeButton.modelData)

                                Text {
                                    textFormat: Text.PlainText
                                    text: bridgeButton.modelData.title
                                    color: bridgeButton.modelData.enabled ? win.barText : win.barTextDisabled
                                    font.family: Appearance.fontFamily
                                    font.pixelSize: Tokens.typographyMenuSize
                                    font.weight: Tokens.typographyMenuWeight
                                }
                            }
                        }

                        BarButton {
                            id: fileButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            objectName: "menubar-file"
                            visible: win.hasFileMenu
                            accessibleName: qsTr("File menu")
                            active: win.isOpen("appfile")
                            onActivated: win.popup("appfile")
                            opensMenu: true
                            onEntered: win.hoverSwitch("appfile")

                            Text {
                                textFormat: Text.PlainText
                                text: qsTr("File")
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }

                        BarButton {
                            id: windowButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            objectName: "menubar-window"
                            visible: win.hasApp
                            accessibleName: qsTr("Window menu")
                            active: win.isOpen("appwindow")
                            onActivated: win.popup("appwindow")
                            opensMenu: true
                            onEntered: win.hoverSwitch("appwindow")

                            Text {
                                textFormat: Text.PlainText
                                text: qsTr("Window")
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }
                    }

                    Row {
                        id: rightRow
                        anchors {
                            right: parent.right
                            rightMargin: Tokens.menubarInsetRight - Tokens.menubarItemPadding
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 0

                        // Third-party status items (StatusNotifierItem), leftmost: macOS keeps them left of the system's.
                        Repeater {
                            model: TrayHost.items

                            delegate: TrayButton {
                                required property var modelData
                                required property int index

                                item: modelData
                                visible: !win.hiddenStatus["tray" + index]
                                bar: win
                                tint: win.barTint
                                shadowed: !win.showBackground
                                shadowColor: win.barShadow
                            }
                        }

                        // Now Playing: the active player's controls, while it has a session.
                        BarButton {
                            id: nowPlayingButton
                            menuKind: "nowplaying"
                            objectName: "menubar-nowplaying"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: win.showNowPlaying && !win.hiddenStatus.nowplaying
                            accessibleName: Media.title !== "" ? qsTr("Now Playing: %1").arg(Media.title) : qsTr("Now Playing")
                            active: win.isOpen("nowplaying")
                            onActivated: win.popup("nowplaying")
                            opensMenu: true
                            onEntered: win.hoverSwitch("nowplaying")

                            Icon {
                                size: Tokens.menubarIconSize
                                color: win.barText
                                name: "now-playing"
                            }
                        }

                        // Do Not Disturb indicator; click turns it off.
                        BarButton {
                            id: dndButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: Notifications.dnd
                            accessibleName: qsTr("Do Not Disturb is on")
                            onActivated: Notifications.setDnd(false)

                            Icon {
                                size: Tokens.menubarIconSize
                                color: win.barText
                                name: "moon"
                            }
                        }

                        BarButton {
                            id: networkButton
                            menuKind: "network"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            accessibleName: qsTr("Network: %1").arg(Connectivity.description)
                            active: win.isOpen("network")
                            onActivated: win.popup("network")
                            opensMenu: true
                            onEntered: win.hoverSwitch("network")

                            Icon {
                                size: Tokens.menubarIconSize
                                color: win.barText
                                name: Connectivity.iconName
                            }
                        }

                        BarButton {
                            id: volumeButton
                            menuKind: "volume"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            accessibleName: qsTr("Volume: %1%").arg(Math.round(Audio.volume * 100))
                            active: win.isOpen("volume")
                            onActivated: win.popup("volume")
                            opensMenu: true
                            onEntered: win.hoverSwitch("volume")
                            onScrolled: delta => Audio.adjust(delta > 0 ? 0.05 : -0.05)

                            Icon {
                                size: Tokens.menubarIconSize
                                color: win.barText
                                name: Audio.iconName
                            }
                        }

                        BarButton {
                            id: batteryButton
                            menuKind: "battery"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: win.hasBattery
                            accessibleName: qsTr("Battery %1%").arg(win.battery ? Math.round(win.battery.percentage * 100) : 0)
                            active: win.isOpen("battery")
                            onActivated: win.popup("battery")
                            opensMenu: true
                            onEntered: win.hoverSwitch("battery")

                            Icon {
                                size: Tokens.menubarIconSize
                                color: win.barText
                                name: win.battery && win.battery.state === UPowerDeviceState.Charging ? "battery-charging" : "battery"
                            }

                            Text {
                                textFormat: Text.PlainText
                                text: win.battery ? qsTr("%1%").arg(Math.round(win.battery.percentage * 100)) : ""
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }

                        // Search (macOS shows the Spotlight magnifier by default): toggles Search, not a menu.
                        BarButton {
                            id: searchButton
                            objectName: "menubar-search"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            visible: Settings.menubarShowSearch && !win.hiddenStatus.search
                            accessibleName: qsTr("Search")
                            active: root.searchActive
                            onActivated: root.searchRequested()

                            Icon {
                                size: Tokens.menubarIconSize
                                color: win.barText
                                name: "search"
                            }
                        }

                        BarButton {
                            id: ccButton
                            menuKind: "controlcenter"
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            padding: Tokens.menubarStatusItemPadding
                            accessibleName: qsTr("Quick Settings")
                            active: win.isOpen("controlcenter")
                            onActivated: win.popup("controlcenter")
                            opensMenu: true
                            onEntered: win.hoverSwitch("controlcenter")

                            Icon {
                                size: Tokens.menubarIconSize
                                color: win.barText
                                name: "control-center"
                            }
                        }

                        BarButton {
                            id: clockButton
                            tint: win.barTint
                            shadowed: !win.showBackground
                            shadowColor: win.barShadow
                            accessibleName: qsTr("Date and time: %1. Open Notifications").arg(clockText.text)
                            active: Notifications.centerOpen && Notifications.centerScreen === (win.screen ? win.screen.name : "")
                            onActivated: Notifications.toggleCenter(win.screen.name)

                            Text {
                                textFormat: Text.PlainText
                                id: clockText
                                text: Qt.locale().toString(FixedTime.date(clock.date), qsTr("ddd d MMM")) + " "
                                    + Qt.formatTime(FixedTime.date(clock.date), Qt.locale().timeFormat(Locale.ShortFormat))
                                color: win.barText
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }
                    }
            }
        }
    }
}
