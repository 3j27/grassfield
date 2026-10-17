pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.services
import qs.platform
import "KeyboardFocus.js" as Focus

// Desktop icons (docs/specs/desktop.md): their own layer surface (namespace grassfield-desktop-icons)
// on the Background layer of the primary screen, mapped after the wallpaper so it sits above it and
// below the Bottom-layer widgets surface (which is never touched from here). The surface takes the
// whole screen so that a click on empty desktop can start a rubber band and focus the desktop; the
// widgets live in a higher layer and keep their own input. Nothing animates or repaints on a timer.
// Primary screen: the first one, or the output named by GRASSFIELD_DESKTOP_SCREEN (dev only).
Variants {
    model: Quickshell.screens.filter(s => s.name === (Quickshell.env("GRASSFIELD_DESKTOP_SCREEN") || Quickshell.screens[0].name))

    // qmllint disable uncreatable-type
    PanelWindow {
        // qmllint enable uncreatable-type
        id: win

        required property ShellScreen modelData

        // Window class of Glance (grassfield-preview --glance): opened from the desktop with Space, it
        // gets the keyboard and gives it back to the desktop when it closes.
        readonly property string glanceClass: "org.grassfield.Preview.Glance"

        // Keyboard focus state machine (KeyboardFocus.js): None by default, OnDemand only after a
        // pointer press on this surface, Exclusive briefly to take the keyboard without pointer motion
        // (also when the icon menu closes). While the menu is open the menu window holds the keyboard and
        // this surface is None. Hovering never changes it.
        property var kb: Focus.initial()
        readonly property string kbMode: kb.mode
        // Frames swapped since "take" started (its Exclusive commit is out after two).
        property int takeFrames: 0
        // The surface has the keyboard (wl_keyboard enter).
        readonly property bool hasKeys: view.Window.active
        // The pointer is off the surface and no rename, menu or drag keeps the keyboard here: the
        // desktop lets go of it, because Hyprland would not move it when the user clicks the window it
        // still counts as focused (see KeyboardFocus.js, `away`).
        readonly property bool away: !hover.hovered && view.renaming === "" && !view.menuOpen && !view.dragging

        function feed(event: var): void {
            const r = Focus.next(win.kb, event);
            win.kb = r.state;
            if (r.focus !== "")
                Compositor.focusWindow(r.focus);
        }

        // Layer state reaches the compositor with the next surface commit: render one now, so a
        // change never waits for an unrelated repaint.
        function commitSoon(): void {
            const w = view.Window.window;
            if (w)
                w.update();
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
        WlrLayershell.keyboardFocus: {
            switch (Focus.interactivity(win.kb)) {
            case "exclusive":
                return WlrKeyboardFocus.Exclusive;
            case "onDemand":
                return WlrKeyboardFocus.OnDemand;
            default:
                return WlrKeyboardFocus.None;
            }
        }
        WlrLayershell.namespace: "grassfield-desktop-icons"

        onKbModeChanged: {
            win.takeFrames = 0;
            win.commitSoon();
        }
        onHasKeysChanged: win.feed({
            type: "keys",
            hasKeys: win.hasKeys
        })
        onAwayChanged: win.feed({
            type: "pointer",
            away: win.away
        })
        onVisibleChanged: win.kb = Focus.initial()

        // "take" ends once its Exclusive commit has certainly been sent, even if the keyboard never
        // arrives (e.g. a locked session), so the surface never stays Exclusive.
        Connections {
            target: win.kbMode === "take" ? view.Window.window : null

            function onFrameSwapped(): void {
                win.takeFrames++;
                if (win.takeFrames >= 2)
                    win.feed({
                        type: "committed"
                    });
                else
                    win.commitSoon();
            }
        }

        Connections {
            target: Hyprland

            function onRawEvent(event: HyprlandEvent): void {
                switch (event.name) {
                case "openwindow":
                    {
                        const w = Focus.parseOpenWindow(event.data);
                        if (w)
                            win.feed({
                                type: "openWindow",
                                address: w.address,
                                workspace: w.workspace,
                                focusedWorkspace: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.name : "",
                                returnsFocus: w.appClass === win.glanceClass
                            });
                        break;
                    }
                case "activewindowv2":
                    win.feed({
                        type: "activeWindow",
                        address: event.data
                    });
                    break;
                case "closewindow":
                    win.feed({
                        type: "closeWindow",
                        address: event.data
                    });
                    break;
                case "workspacev2":
                    win.feed({
                        type: "workspace"
                    });
                    break;
                }
            }
        }

        IconsView {
            id: view
            anchors.fill: parent
            screen: win.modelData
            holdsKeys: Focus.holdsKeys(win.kb)
            menuLingers: Focus.menuLingers(win.kb)
            onFocusEvent: event => win.feed(event)
        }

        // Every press and release on the surface (icons and empty space), seen through a passive grab
        // above the view so it never interferes with the view's own handlers. Hover is not a press.
        Item {
            anchors.fill: parent

            PointHandler {
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onActiveChanged: win.feed(active ? {
                    type: "press"
                } : {
                    type: "release",
                    hasKeys: win.hasKeys
                })
            }

            // The wallpaper below no longer sees the pointer: report it for the hot corner re-arm.
            HoverHandler {
                id: hover
                onPointChanged: if (hovered)
                    PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
            }
        }
    }
}
