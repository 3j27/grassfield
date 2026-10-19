pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import qs.store

// User configuration facade over SettingsStore (grassfield.json, contract version 1).
// Keys are documented in docs/specs/ui.md.
Singleton {
    id: root

    // GRASSFIELD_CONFIG_HOME (dev) wins; otherwise $XDG_CONFIG_HOME/grassfield.
    readonly property string configDir: {
        const dev = Quickshell.env("GRASSFIELD_CONFIG_HOME");
        if (dev)
            return dev;
        const xdg = Quickshell.env("XDG_CONFIG_HOME");
        return (xdg ? xdg : Quickshell.env("HOME") + "/.config") + "/grassfield";
    }

    // Validated by the store (out-of-range or unknown values fall back to the schema defaults).
    readonly property string appearance: store.appearance
    readonly property bool dark: store.appearance !== "light"
    readonly property real transparency: store.transparency
    readonly property string materialProfile: store.materialProfile
    readonly property bool reduceTransparency: store.data.accessibility.reduceTransparency
    readonly property bool reduceMotion: store.data.accessibility.reduceMotion
    readonly property var dockPinned: store.dockPinned
    readonly property real dockMagnification: store.dockMagnification
    readonly property bool dockMagnificationEnabled: store.data.dock.magnificationEnabled
    readonly property bool dockAutohide: store.data.dock.autohide

    readonly property string iconMode: store.iconMode
    readonly property string iconTint: store.iconTint

    readonly property bool notificationsDnd: store.data.notifications.dnd
    readonly property string notificationsPreviews: store.notificationsPreviews
    readonly property string titlebarDoubleClick: store.titlebarDoubleClick
    readonly property int lockIdleMinutes: store.lockIdleMinutes

    readonly property bool desktopShowIcons: store.data.desktop.showIcons
    readonly property bool menubarShowBackground: store.data.menubar.showBackground
    readonly property string hotCornerTopLeft: store.hotCornerTopLeft
    readonly property string hotCornerTopRight: store.hotCornerTopRight
    readonly property string hotCornerBottomLeft: store.hotCornerBottomLeft
    readonly property string hotCornerBottomRight: store.hotCornerBottomRight

    function setHotCorner(corner: string, action: string): void {
        store.setHotCorner(corner, action);
    }

    function setDesktopShowIcons(value: bool): void {
        store.setDesktopShowIcons(value);
    }

    function setMenubarShowBackground(value: bool): void {
        store.setMenubarShowBackground(value);
    }

    function setAppearance(value: string): void {
        store.setAppearance(value);
    }

    function setTransparency(value: real): void {
        store.setTransparency(value);
    }

    function setReduceTransparency(value: bool): void {
        store.setReduceTransparency(value);
    }

    function setReduceMotion(value: bool): void {
        store.setReduceMotion(value);
    }

    function setDockAutohide(value: bool): void {
        store.setDockAutohide(value);
    }

    function setDockMagnification(value: real, enabled: bool): void {
        store.setDockMagnification(value, enabled);
    }

    function setDockPinned(list: var): void {
        store.setDockPinned(list);
    }

    function setIconMode(value: string): void {
        store.setIconMode(value);
    }

    function setIconTint(value: string): void {
        store.setIconTint(value);
    }

    function setNotificationsDnd(value: bool): void {
        store.setNotificationsDnd(value);
    }

    function setNotificationsPreviews(value: string): void {
        store.setNotificationsPreviews(value);
    }

    SettingsStore {
        id: store
        configDir: root.configDir
    }
}
