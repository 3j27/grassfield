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

// Top bar, one per screen. Left: Grassfield menu (leaf mark), the focused app name with its
// application menu, then the app's own menus when it exports them (T1/T2 through MenuBridge) or the
// T0 File menu, then Window. Right (real backends only): network, volume, battery (when present),
// Control Center, clock. Popups are rendered by qs.overlay through Popups.
Scope {
    id: root

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

        function close(): void {
            Popups.close();
        }

        // Test hook (tests/visual/menubar-macos.sh): the open popup's kind and output, "" when none. Read-only.
        function openKind(): string {
            return Popups.active ? Popups.kind + "@" + Popups.screenName : "";
        }

        // Test hook (tests/visual/menubar-macos.sh): the auto-hide state of an output's bar as JSON. Read-only.
        function autohide(screen: string): string {
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

    // Test hook: set Control Center values the way the UI does (persisted too).
    IpcHandler {
        target: "controlcenter"

        function transparency(value: real): void {
            Settings.setTransparency(value);
        }

        function appearance(name: string): void {
            Settings.setAppearance(name);
        }

        function reduceTransparency(on: bool): void {
            Settings.setReduceTransparency(on);
        }

        function reduceMotion(on: bool): void {
            Settings.setReduceMotion(on);
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
            // Stages event is named (display only, AppMenus.context disables the window commands).
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
            readonly property bool showBackground: Settings.menubarShowBackground || BarTone.assistOf(win.screen.name)
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
            readonly property bool hasBattery: !VisualFixtures.active && battery !== null && battery.isPresent && battery.isLaptopBattery

            // SingleMainWindow of the app's desktop entry decides whether File has New Window.
            onShownAppIdChanged: {
                // The app is gone: its open app menu would act on nothing.
                if (shownAppId === "" && ["app", "appfile", "appwindow", "appbridge"].indexOf(Popups.kind) >= 0 && Popups.screenName === win.screen.name)
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
            readonly property string hideMode: "fullscreen"
            readonly property bool fullscreen: Compositor.fullscreenOn(win.screen.name, Compositor.topologyRevision)
            readonly property bool autoHides: BarHide.hides(hideMode, fullscreen)
            property var hideMachine: AutoHide.create()
            // A menu of this bar open (or Notification Center from the clock) keeps it in view; the pointer on the bar or its edge strip too.
            readonly property var hideInhibitors: ({
                    pointer: winHover.hovered,
                    popup: tracking || (Notifications.centerOpen && Notifications.centerScreen === win.screen.name)
                })
            readonly property var hideTiming: ({
                    hideGrace: Tokens.menubarHideGrace,
                    hideDuration: Appearance.reduceMotion ? 0 : Tokens.menubarHideDuration,
                    revealDwell: Tokens.menubarRevealDwell,
                    revealDuration: Appearance.reduceMotion ? 0 : Tokens.menubarRevealDuration
                })
            readonly property bool away: autoHides && hideMachine.state === "hidden" && !AutoHide.forcing(hideInhibitors)
            readonly property real slideY: BarHide.slideOffset(Tokens.menubarHeight, AutoHide.ease(hideMachine.visible))

            function isOpen(kind: string): bool {
                return Popups.kind === kind && Popups.screenName === win.screen.name;
            }

            // macOS menu tracking: while one of this bar's menus is open, moving onto another title or status item opens
            // its menu without a click. The clock (Notification Center) and the Do Not Disturb indicator are not menus.
            readonly property var trackedKinds: ["system", "app", "appfile", "appwindow", "appbridge", "network", "volume", "battery", "controlcenter"]
            readonly property bool tracking: Popups.active && Popups.screenName === win.screen.name && trackedKinds.indexOf(Popups.kind) >= 0

            function hoverSwitch(kind: string): void {
                if (win.tracking && Popups.kind !== kind)
                    win.popup(kind);
            }

            function hoverSwitchBridge(button: Item, menu: var): void {
                if (win.tracking && !(Popups.kind === "appbridge" && Popups.data.dbusId === menu.dbusId))
                    win.openBridge(button, menu);
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

            // Left/Right in an open menu (macOS): the previous or next title's menu, wrapping around.
            function stepMenu(direction: int): void {
                const titles = win.menuTitles();
                const kindOf = {system: "system", app: "app", bridge: "appbridge", file: "appfile", window: "appwindow"};
                let at = -1;
                for (let i = 0; i < titles.length; i++) {
                    const t = titles[i];
                    if (kindOf[t.kind] === Popups.kind && (!t.menu || Popups.data.dbusId === t.menu.dbusId))
                        at = i;
                }
                if (at < 0 || titles.length < 2)
                    return;
                const next = titles[(at + direction + titles.length) % titles.length];
                if (next.menu)
                    win.openBridge(next.button, next.menu);
                else
                    win.popup(kindOf[next.kind]);
            }

            Connections {
                target: Popups

                function onMenuStepRequested(screen: string, direction: int): void {
                    if (screen === win.screen.name)
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

            function pressAt(x: real): void {
                const b = win.buttonAt(x);
                if (!b || !b.opensMenu)
                    Popups.close();
                if (b)
                    b.activated();
            }

            Component.onCompleted: Popups.registerBar(win.screen.name, win)
            Component.onDestruction: Popups.unregisterBar(win.screen.name, win)

            // Opens a popup under (left) or aligned to the right edge of (right) a bar button.
            function openFor(kind: string, button: Item, alignment: string, payload: var): void {
                const x = button.mapToItem(null, alignment === "right" ? button.width : 0, 0).x;
                Popups.toggle(kind, win.screen.name, x, Tokens.menubarHeight, alignment, payload);
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
                Popups.open("appbridge", win.screen.name, x, Tokens.menubarHeight, "left", {dbusId: menu.dbusId, window: MenuBridge.window, title: menu.title});
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

            function popup(kind: string): void {
                switch (kind) {
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

            HoverHandler {
                id: winHover
                onPointChanged: if (hovered)
                    PointerTracker.report(win.screen.name, point.position.x, point.position.y)
            }

            // Frame clock of the auto-hide machine: stops while nothing can change (away and idle, or in view and held).
            FrameAnimation {
                running: AutoHide.active(win.hideMachine, win.hideInhibitors, win.autoHides)
                onTriggered: win.hideMachine = AutoHide.step(win.hideMachine, win.hideInhibitors, win.autoHides, win.hideTiming, Math.min(frameTime * 1000, 100))
            }

            SystemClock {
                id: clock
                precision: SystemClock.Minutes
            }

            Material {
                id: material
                y: win.slideY
                width: parent.width
                height: parent.height
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

                        BarButton {
                            id: ccButton
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
                            active: Notifications.centerOpen && Notifications.centerScreen === win.screen.name
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
