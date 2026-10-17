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
            readonly property string shownAppId: Compositor.focusedAppId !== "" ? Compositor.focusedAppId : (Popups.active && lastAppId !== "" && lastAppAlive ? lastAppId : "")
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
            // A menu of this bar is open: only then may the bar take the keyboard (never on hover or at start).
            readonly property bool menuOpen: Popups.active && Popups.screenName === win.screen.name
            readonly property var battery: UPower.displayDevice
            readonly property bool hasBattery: battery !== null && battery.isPresent && battery.isLaptopBattery

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

            function isOpen(kind: string): bool {
                return Popups.kind === kind && Popups.screenName === win.screen.name;
            }

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
            exclusiveZone: Tokens.menubarHeight
            color: "transparent"
            // No keyboard focus by default (hovering or starting must never take the keyboard from the focused
            // window); OnDemand only while one of this bar's menus is open (the popup itself takes exclusive focus,
            // CTRL+F2 opens the system menu that way) and released when it closes.
            focusable: win.menuOpen
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: win.menuOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-menubar"
            // Quickshell qmltypes name this property's type PendingRegion/FileViewAdapter without exporting it (metadata quirk).
            // qmllint disable missing-type
            BackgroundEffect.blurRegion: material.blurActive ? blurRegion : null
            // qmllint enable missing-type

            Region {
                id: blurRegion
                item: material
                radius: material.radius
            }

            HoverHandler {
                onPointChanged: if (hovered)
                    PointerTracker.report(win.screen.name, point.position.x, point.position.y)
            }

            SystemClock {
                id: clock
                precision: SystemClock.Minutes
            }

            Material {
                id: material
                anchors.fill: parent
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

                Row {
                    id: leftRow
                    anchors {
                        left: parent.left
                        leftMargin: Tokens.spacingXs
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 0

                    BarButton {
                        id: systemButton
                        accessibleName: qsTr("Grassfield menu")
                        active: win.isOpen("system")
                        onActivated: win.popup("system")

                        Icon {
                            size: Tokens.menubarIconSize
                            name: "grassfield-logo"
                        }
                    }

                    BarButton {
                        id: appButton
                        objectName: "menubar-app"
                        accessibleName: qsTr("Application menu: %1").arg(win.appName)
                        active: win.isOpen("app")
                        onActivated: win.popup("app")

                        Text {
                            textFormat: Text.PlainText
                            text: win.appName
                            color: Appearance.colors.text
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

                            required property var modelData

                            objectName: "menubar-bridge:" + modelData.title
                            accessibleName: qsTr("%1 menu").arg(modelData.title)
                            active: win.isOpen("appbridge") && Popups.data.dbusId === modelData.dbusId
                            onActivated: win.openBridge(bridgeButton, bridgeButton.modelData)

                            Text {
                                textFormat: Text.PlainText
                                text: bridgeButton.modelData.title
                                color: bridgeButton.modelData.enabled ? Appearance.colors.text : Appearance.withAlpha(Appearance.colors.text, Tokens.materialDisabledOpacity)
                                font.family: Appearance.fontFamily
                                font.pixelSize: Tokens.typographyMenuSize
                                font.weight: Tokens.typographyMenuWeight
                            }
                        }
                    }

                    BarButton {
                        id: fileButton
                        objectName: "menubar-file"
                        visible: win.hasFileMenu
                        accessibleName: qsTr("File menu")
                        active: win.isOpen("appfile")
                        onActivated: win.popup("appfile")

                        Text {
                            textFormat: Text.PlainText
                            text: qsTr("File")
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyMenuSize
                            font.weight: Tokens.typographyMenuWeight
                        }
                    }

                    BarButton {
                        id: windowButton
                        objectName: "menubar-window"
                        visible: win.hasApp
                        accessibleName: qsTr("Window menu")
                        active: win.isOpen("appwindow")
                        onActivated: win.popup("appwindow")

                        Text {
                            textFormat: Text.PlainText
                            text: qsTr("Window")
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyMenuSize
                            font.weight: Tokens.typographyMenuWeight
                        }
                    }
                }

                Row {
                    anchors {
                        right: parent.right
                        rightMargin: Tokens.spacingXs
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 0

                    // Do Not Disturb indicator; click turns it off.
                    BarButton {
                        id: dndButton
                        visible: Notifications.dnd
                        accessibleName: qsTr("Do Not Disturb is on")
                        onActivated: Notifications.setDnd(false)

                        Icon {
                            size: Tokens.menubarIconSize
                            name: "moon"
                        }
                    }

                    BarButton {
                        id: networkButton
                        accessibleName: qsTr("Network: %1").arg(Connectivity.description)
                        active: win.isOpen("network")
                        onActivated: win.popup("network")

                        Icon {
                            size: Tokens.menubarIconSize
                            name: Connectivity.iconName
                        }
                    }

                    BarButton {
                        id: volumeButton
                        accessibleName: qsTr("Volume: %1%").arg(Math.round(Audio.volume * 100))
                        active: win.isOpen("volume")
                        onActivated: win.popup("volume")
                        onScrolled: delta => Audio.adjust(delta > 0 ? 0.05 : -0.05)

                        Icon {
                            size: Tokens.menubarIconSize
                            name: Audio.iconName
                        }
                    }

                    BarButton {
                        id: batteryButton
                        visible: win.hasBattery
                        accessibleName: qsTr("Battery %1%").arg(win.battery ? Math.round(win.battery.percentage * 100) : 0)
                        active: win.isOpen("battery")
                        onActivated: win.popup("battery")

                        Icon {
                            size: Tokens.menubarIconSize
                            name: win.battery && win.battery.state === UPowerDeviceState.Charging ? "battery-charging" : "battery"
                        }

                        Text {
                            textFormat: Text.PlainText
                            text: win.battery ? qsTr("%1%").arg(Math.round(win.battery.percentage * 100)) : ""
                            color: Appearance.colors.text
                            font.family: Appearance.fontFamily
                            font.pixelSize: Tokens.typographyMenuSize
                            font.weight: Tokens.typographyMenuWeight
                        }
                    }

                    BarButton {
                        id: ccButton
                        accessibleName: qsTr("Control Center")
                        active: win.isOpen("controlcenter")
                        onActivated: win.popup("controlcenter")

                        Icon {
                            size: Tokens.menubarIconSize
                            name: "control-center"
                        }
                    }

                    BarButton {
                        id: clockButton
                        accessibleName: qsTr("Date and time: %1. Open Notification Center").arg(clockText.text)
                        active: Notifications.centerOpen && Notifications.centerScreen === win.screen.name
                        onActivated: Notifications.toggleCenter(win.screen.name)

                        Text {
                            textFormat: Text.PlainText
                            id: clockText
                            text: Qt.locale().toString(FixedTime.date(clock.date), qsTr("ddd d MMM")) + " "
                                + Qt.formatTime(FixedTime.date(clock.date), Qt.locale().timeFormat(Locale.ShortFormat))
                            color: Appearance.colors.text
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
