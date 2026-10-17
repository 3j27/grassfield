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

// Top bar, one per screen. Left: Grassfield menu (leaf mark) and the focused app name with its
// application menu. Right (real backends only): network, volume, battery (when present),
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
            readonly property bool hasFileMenu: hasApp && AppMenus.model.hasFileMenu(AppMenus.context(shownAppId))
            readonly property var battery: UPower.displayDevice
            readonly property bool hasBattery: battery !== null && battery.isPresent && battery.isLaptopBattery

            // SingleMainWindow of the app's desktop entry decides whether File has New Window.
            onShownAppIdChanged: {
                // The app is gone: its open app menu would act on nothing.
                if (shownAppId === "" && ["app", "appfile", "appwindow"].indexOf(Popups.kind) >= 0 && Popups.screenName === win.screen.name)
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

            // Forget the remembered app once its last window is gone.
            onLastAppAliveChanged: {
                if (!lastAppAlive)
                    lastAppId = "";
            }

            function isOpen(kind: string): bool {
                return Popups.kind === kind && Popups.screenName === win.screen.name;
            }

            // Opens a popup under (left) or aligned to the right edge of (right) a bar button.
            function openFor(kind: string, button: Item, alignment: string, payload: var): void {
                const x = button.mapToItem(null, alignment === "right" ? button.width : 0, 0).x;
                Popups.toggle(kind, win.screen.name, x, Tokens.menubarHeight, alignment, payload);
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
            // OnDemand: clicking the bar lets Tab reach its items; popups take exclusive focus.
            focusable: true
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
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

                    BarButton {
                        id: fileButton
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
                            text: Qt.formatDateTime(clock.date, qsTr("ddd d MMM")) + " "
                                + Qt.formatTime(clock.date, Qt.locale().timeFormat(Locale.ShortFormat))
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
