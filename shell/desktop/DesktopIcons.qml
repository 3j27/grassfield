pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import Grassfield.Ui
import qs.services
import "KeyboardFocus.js" as Focus

// Desktop icons (docs/specs/desktop.md): their own layer surface (namespace grassfield-desktop-icons)
// on the Background layer of the primary screen, mapped after the wallpaper so it sits above it and
// below the Bottom-layer widgets surface (which is never touched from here). The surface takes the
// whole screen so that a click on empty desktop can start a rubber band and focus the desktop; the
// widgets live in a higher layer and keep their own input. Nothing animates or repaints on a timer.
// Primary screen: the first one, or the output named by GRASSFIELD_DESKTOP_SCREEN (dev only).
//
// Keyboard focus (ADR-0012, KeyboardFocus.js): the desktop is click-to-focus. Keyboard interactivity is None
// until a press on the desktop, then OnDemand; it goes back to None when the pointer leaves the surface or the
// keyboard is not granted. Hyprland decides who holds the keyboard; nothing here guesses.
Variants {
    model: Quickshell.screens.filter(s => s.name === (Quickshell.env("GRASSFIELD_DESKTOP_SCREEN") || Quickshell.screens[0].name))

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        property var kb: Focus.initial()
        // The transient kicker surface is mapped (two phases: mapped, unmapped).
        property bool kickOn: false
        // The surface has the keyboard (wl_keyboard enter): the window is active. activeFocus is not enough, forceActiveFocus sets it on an inactive window.
        readonly property bool hasKeys: view.Window.active

        function feed(event: var): void {
            win.kb = Focus.next(win.kb, event);
            if (Focus.rearmAfter(event))
                rearmTimer.restart();
        }

        screen: modelData
        visible: Settings.desktopShowIcons
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.keyboardFocus: Focus.interactivity(win.kb) === "ondemand" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-desktop-icons"

        onHasKeysChanged: win.feed({
            type: "keys",
            hasKeys: win.hasKeys
        })
        onVisibleChanged: win.kb = Focus.initial()

        // Hyprland grants the keyboard to an OnDemand surface only at the next pointer motion (measured: ADR-0012,
        // spike). Mapping and unmapping a transparent 1x1 layer surface makes it re-run its pointer focus logic, so
        // the keyboard arrives without any motion. If it is not granted (the pointer is over a window), give up.
        onKbChanged: {
            if (Focus.kicking(win.kb)) {
                if (!kickTimer.running && !win.kickOn)
                    kickTimer.restart();
                armTimer.restart();
            } else {
                kickTimer.stop();
                armTimer.stop();
                win.kickOn = false;
            }
        }

        Timer {
            id: kickTimer
            interval: Tokens.desktopIconFocusKickMs
            onTriggered: {
                win.kickOn = !win.kickOn;
                if (win.kickOn)
                    restart();
            }
        }

        Timer {
            id: armTimer
            interval: Tokens.desktopIconFocusArmMs
            onTriggered: win.feed({
                type: "armTimeout"
            })
        }

        // After an outside dismissal of the menu: None for one beat (above), then ask again.
        Timer {
            id: rearmTimer
            interval: Tokens.desktopIconFocusKickMs
            onTriggered: win.feed({
                type: "press"
            })
        }

        // qmllint disable uncreatable-type
        PanelWindow {
            // qmllint enable uncreatable-type
            id: kicker

            screen: win.modelData
            visible: win.kickOn
            anchors {
                top: true
                left: true
            }
            implicitWidth: 1
            implicitHeight: 1
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "grassfield-desktop-kicker"
        }

        IconsView {
            id: view
            anchors.fill: parent
            focus: true
            screen: win.modelData
            hostWindow: win
            keysActive: Focus.keysActive(win.kb)
            onFocusEvent: event => win.feed(event)
        }

        Item {
            anchors.fill: parent

            // The wallpaper below no longer sees the pointer: report it for the hot corner re-arm.
            HoverHandler {
                id: hover
                onPointChanged: if (hovered)
                    PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
                onHoveredChanged: if (!hovered)
                    win.feed({
                        type: "pointerLeft"
                    })
            }

            // A left press on the desktop (an icon, empty space) asks for the keyboard. Passive: the icons and
            // the rubber band keep their own handling.
            PointHandler {
                acceptedButtons: Qt.LeftButton
                onActiveChanged: if (active)
                    win.feed({
                        type: "press"
                    })
            }
        }
    }
}
