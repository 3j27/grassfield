pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

// Compositor state and actions for the shell (master-prompt 5.2: the only place, together
// with Capabilities, that talks to the compositor). Event-driven; never polls hyprctl.
Singleton {
    id: root

    // Live toplevel list (foreign-toplevel protocol: reliable app ids, no title matching).
    readonly property var toplevels: ToplevelManager.toplevels
    readonly property var focusedToplevel: ToplevelManager.activeToplevel
    readonly property string focusedAppId: focusedToplevel ? focusedToplevel.appId : ""
    readonly property string focusedClass: focusedAppId
    readonly property string focusedTitle: focusedToplevel ? focusedToplevel.title : ""

    readonly property var workspaces: Hyprland.workspaces
    readonly property var focusedWorkspace: Hyprland.focusedWorkspace

    // Hyprland dispatcher request (shell actions that have no protocol equivalent).
    function dispatch(request: string): void {
        Hyprland.dispatch(request);
    }

    // Activate (focus, un-minimize) a toplevel through the protocol.
    function activate(toplevel: var): void {
        if (toplevel)
            toplevel.activate();
    }

    // Running toplevels belonging to an app id (case-insensitive, as desktop entry ids and
    // Wayland app ids differ in case for some toolkits).
    function toplevelsFor(appId: string): var {
        const wanted = appId.toLowerCase();
        const out = [];
        const all = root.toplevels ? root.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (all[i].appId.toLowerCase() === wanted)
                out.push(all[i]);
        }
        return out;
    }
}
