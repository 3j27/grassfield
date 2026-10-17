pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.services
import qs.platform

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
        // The desktop is armed for the keyboard (OnDemand) only while the pointer is over it (or its
        // icon menu is open): a click then gives it the keyboard. It is disarmed (None) when the
        // pointer leaves, and for a moment after a window maps or is activated or an item was
        // opened, so that the keyboard goes to the new window instead of staying with the desktop.
        property bool suppressed: false
        readonly property bool wantKeys: (pointer.hovered || view.menuOpen) && !suppressed
        WlrLayershell.keyboardFocus: wantKeys ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        WlrLayershell.namespace: "grassfield-desktop-icons"

        function release(): void {
            suppressed = true;
            rearm.restart();
        }

        Timer {
            id: rearm
            interval: 400
            onTriggered: win.suppressed = false
        }

        // The wallpaper below no longer sees the pointer: report it for the hot corner re-arm.
        HoverHandler {
            id: pointer
            onPointChanged: if (hovered)
                PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
        }

        Connections {
            target: Compositor

            function onFocusedToplevelChanged(): void {
                win.release();
            }
        }

        // A window mapping while the desktop holds the keyboard must get it: no activation event
        // arrives in that case, so the raw event is the trigger.
        Connections {
            target: Hyprland

            function onRawEvent(event: HyprlandEvent): void {
                if (event.name === "openwindow")
                    win.release();
            }
        }

        IconsView {
            id: view
            anchors.fill: parent
            screen: win.modelData
            onReleased: win.release()
        }
    }
}
