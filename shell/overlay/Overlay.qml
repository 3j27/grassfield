pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.menubar
import qs.services

// Host of every popup (menus, status menus, Control Center, dialogs): one transparent
// layer-shell window per screen, mapped only while a popup is open on that screen. It takes
// exclusive keyboard focus, closes on a click outside and lets the menu bar stay clickable so
// the user can switch menus. Content is declared in Popups (kind, anchor, payload).
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
        visible: open
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
        // Everything except the menu bar strip receives input.
        // qmllint disable missing-type
        mask: Region {
            width: win.width
            height: win.height

            Region {
                width: win.width
                height: Tokens.menubarHeight
                intersection: Intersection.Subtract
            }
        }
        BackgroundEffect.blurRegion: Appearance.effectiveTransparency > 0 && win.open ? blurRegion : null
        // qmllint enable missing-type

        Region {
            id: blurRegion
            item: holder
            radius: {
                switch (Popups.kind) {
                case "controlcenter":
                    return Tokens.radiusPanel;
                case "about":
                case "forcequit":
                case "confirm":
                case "appabout":
                case "notice":
                    return Tokens.radiusAlert;
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
            readonly property real wantedX: {
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
