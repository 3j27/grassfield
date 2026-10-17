pragma Singleton
import QtQuick
import Quickshell

// Which shell popup is open, where, and with which payload. One at a time. The Overlay window
// of the matching screen renders it; menus, status items and the Dock only call open()/close().
//
// kind: "" | "system" | "app" | "appfile" | "appwindow" | "volume" | "network" | "battery" | "controlcenter" | "dock"
//       | "about" | "forcequit" | "confirm" | "appabout" | "notice"
Singleton {
    id: root

    property string kind: ""
    property string screenName: ""
    // Anchor in screen coordinates. align: "left" (popup's left edge at x, top at y),
    // "right" (right edge at x), "above" (centered on x, bottom edge at y), "center" (screen centre).
    property real anchorX: 0
    property real anchorY: 0
    property string align: "left"
    property var data: ({})

    readonly property bool active: kind !== ""

    function open(popupKind: string, screen: string, x: real, y: real, alignment: string, payload: var): void {
        data = payload ? payload : {};
        screenName = screen;
        anchorX = x;
        anchorY = y;
        align = alignment;
        kind = popupKind;
    }

    // Opens on the screen of the current popup, or the first screen (IPC and keyboard use).
    function openCentered(popupKind: string, payload: var): void {
        const name = screenName !== "" ? screenName : (Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "");
        open(popupKind, name, 0, 0, "center", payload);
    }

    // Toggle: the same kind at the same screen closes it.
    function toggle(popupKind: string, screen: string, x: real, y: real, alignment: string, payload: var): void {
        if (kind === popupKind && screenName === screen)
            close();
        else
            open(popupKind, screen, x, y, alignment, payload);
    }

    function confirm(title: string, message: string, confirmLabel: string, action: string, args: var, destructive: bool): void {
        openCentered("confirm", {title: title, message: message, confirmLabel: confirmLabel, action: action, args: args, destructive: destructive});
    }

    function notice(title: string, message: string): void {
        openCentered("notice", {title: title, message: message});
    }

    function close(): void {
        kind = "";
        data = {};
    }
}
