pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.menubar
import qs.platform
import qs.services

// Host of every popup (menus, status menus, Control Center, dialogs): one transparent
// layer-shell window per screen, mapped only while a popup is open on that screen. It takes
// exclusive keyboard focus, closes on a click outside and hands the menu bar strip to that output's
// bar so the user can switch menus (hover or click, macOS). Content is declared in Popups (kind, anchor, payload).
Variants {
    id: root

    model: Quickshell.screens

    // Quickshell qmltypes mark PanelWindow uncreatable (metadata quirk); suppress just this warning.
    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        readonly property bool open: Popups.active && Popups.screenName === modelData.name

        screen: modelData
        // Mapped a moment longer than it holds the keyboard: a layer destroyed while Exclusive leaves the compositor with no
        // keyboard focus.
        visible: release.mapped
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-overlay"
        // The whole output receives input while a popup is open (the bar strip is handed to the bar, below); nothing once
        // it closed: the surface stays mapped a moment for the keyboard release, and a click in that moment belongs to the
        // window under it.
        // qmllint disable missing-type
        mask: win.open ? openMask : passThrough
        // Quick Settings is several floating modules: one blur region each. Everything else is one surface.
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.open ? (Popups.kind === "controlcenter" ? modulesRegion : blurRegion) : null
        // qmllint enable missing-type

        // The whole output, the menu bar strip included: the strip is handed to the bar below (Popups.bars). Leaving it out
        // left a press there with no surface at all when the pointer had not moved since the popup opened (Hyprland takes
        // the pointer from the bar when this Exclusive layer maps and enters it only where it takes input).
        Region {
            id: openMask
            width: win.width
            height: win.height
        }

        Region {
            id: passThrough
        }

        KeyboardRelease {
            id: release
            shown: win.open
        }

        // Closed but still mapped (the hold): a press the compositor delivered before the empty mask landed (late whenever
        // the GUI thread was busy) is swallowed here, never handled by the menu item under it.
        MouseArea {
            anchors.fill: parent
            z: 1000
            visible: !win.open
            acceptedButtons: Qt.AllButtons
        }

        // Key focus returns to the window active when the popup opened (FocusReturn); one call per window, idempotent.
        Connections {
            target: Popups

            function onActiveChanged(): void {
                if (Popups.active)
                    FocusReturn.opened("popup");
                else
                    FocusReturn.closed("popup", true);
            }
        }

        Region {
            id: modulesRegion
            regions: moduleRegions.instances
        }

        Variants {
            id: moduleRegions
            model: {
                const cc = holder.item as ControlCenter;
                return Popups.kind === "controlcenter" && cc ? cc.surfaces : [];
            }

            Region {
                required property var modelData
                item: modelData
                radius: modelData ? modelData.radius : 0
            }
        }

        Region {
            id: blurRegion
            item: holder
            radius: {
                switch (Popups.kind) {
                case "about":
                case "forcequit":
                case "confirm":
                case "appabout":
                case "notice":
                    return Tokens.radiusAlert;
                case "nowplaying":
                    return Tokens.quicksettingsRadiusTile;
                }
                return Tokens.radiusMenu;
            }
        }

        // Click outside closes. Right and middle buttons too.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: Popups.close()
        }

        // The menu bar strip while a popup is open: Hyprland sends the pointer to this Exclusive layer, not to the bar under
        // it (a press at the Window title landed here), so the strip goes to that output's bar (Popups.bars): moving onto
        // another title or status item switches menus, a click on the open title closes it, a click on another opens it.
        Item {
            width: win.width
            height: Tokens.menubarHeight
            visible: win.open

            HoverHandler {
                onPointChanged: {
                    const bar = Popups.bars[win.modelData.name];
                    if (hovered && bar)
                        bar.trackAt(point.position.x);
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onPressed: mouse => {
                    const bar = Popups.bars[win.modelData.name];
                    if (bar)
                        bar.pressAt(mouse.x, mouse.button === Qt.RightButton ? "right" : mouse.button === Qt.MiddleButton ? "middle" : "left");
                    else
                        Popups.close();
                }
            }
        }

        // Swallows clicks on the popup itself so they do not reach the click-outside area.
        MouseArea {
            x: holder.x
            y: holder.y
            width: holder.width
            height: holder.height
            acceptedButtons: Qt.AllButtons
        }

        Loader {
            id: holder

            readonly property real margin: Tokens.panelPopupMargin
            readonly property bool ccPlaced: Popups.kind === "controlcenter"
            readonly property real wantedX: {
                // Quick Settings keeps the macOS offsets: a fixed inset from the right edge of the screen.
                if (ccPlaced)
                    return win.width - width - Tokens.quicksettingsEdgeMargin;
                switch (Popups.align) {
                case "right":
                    return Popups.anchorX - width;
                case "above":
                    return Popups.anchorX - width / 2;
                case "center":
                    return (win.width - width) / 2;
                }
                return Popups.anchorX;
            }
            readonly property real wantedY: {
                if (ccPlaced)
                    return Tokens.menubarHeight + Tokens.quicksettingsTopGap;
                switch (Popups.align) {
                case "above":
                    return Popups.anchorY - height;
                case "center":
                    return (win.height - height) / 2 - win.height * Tokens.panelDialogRaise;
                }
                return Popups.anchorY;
            }

            active: win.open
            x: Math.max(margin, Math.min(win.width - width - margin, wantedX))
            y: Math.max(0, Math.min(win.height - height - margin, wantedY))
            opacity: item ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: Appearance.duration(Tokens.motionFast)
                }
            }

            sourceComponent: {
                switch (Popups.kind) {
                case "system":
                    return systemMenu;
                case "app":
                case "appfile":
                case "appwindow":
                    return appMenu;
                case "appbridge":
                    return bridgeMenu;
                case "tray":
                    return trayMenu;
                case "nowplaying":
                    return nowPlayingPopover;
                case "volume":
                    return volumeMenu;
                case "network":
                    return networkMenu;
                case "battery":
                    return batteryMenu;
                case "controlcenter":
                    return controlCenter;
                case "dock":
                    return dockMenu;
                case "about":
                    return aboutPanel;
                case "forcequit":
                    return forceQuit;
                case "confirm":
                    return confirmDialog;
                case "appabout":
                    return appAbout;
                case "notice":
                    return noticeDialog;
                }
                return null;
            }

            onLoaded: (item as Item).forceActiveFocus()
        }

        Component {
            id: systemMenu
            SystemMenu {}
        }

        Component {
            id: appMenu
            AppMenu {}
        }

        // An application's own menu (T1/T2, qs.menubar BridgeMenu).
        Component {
            id: bridgeMenu
            BridgeMenu {}
        }

        // A status item's own menu (StatusNotifierItem, DBusMenu).
        Component {
            id: trayMenu
            TrayMenu {}
        }

        // The Now Playing status item's popover: the Quick Settings module on its own.
        Component {
            id: nowPlayingPopover
            NowPlayingPopover {}
        }

        Component {
            id: volumeMenu
            VolumeMenu {}
        }

        Component {
            id: networkMenu
            NetworkMenu {}
        }

        Component {
            id: batteryMenu
            BatteryMenu {}
        }

        Component {
            id: controlCenter
            ControlCenter {}
        }

        Component {
            id: dockMenu
            DockMenu {}
        }

        Component {
            id: aboutPanel
            AboutPanel {}
        }

        Component {
            id: forceQuit
            ForceQuitPanel {}
        }

        Component {
            id: confirmDialog
            ConfirmDialog {}
        }

        Component {
            id: appAbout
            AppAboutPanel {}
        }

        Component {
            id: noticeDialog
            NoticeDialog {}
        }
    }
}
