pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

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
        // On demand: the desktop takes the keyboard when it is clicked, never otherwise.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        WlrLayershell.namespace: "grassfield-desktop-icons"

        // The wallpaper below no longer sees the pointer: report it for the hot corner re-arm.
        HoverHandler {
            onPointChanged: if (hovered)
                PointerTracker.report(win.modelData.name, point.position.x, point.position.y)
        }

        IconsView {
            anchors.fill: parent
            screen: win.modelData
        }
    }
}
