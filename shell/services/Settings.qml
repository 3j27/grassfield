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

    readonly property int version: store.data.version
    readonly property string appearance: store.data.appearance
    readonly property bool dark: store.data.appearance !== "light"
    readonly property real transparency: store.data.material.transparency
    readonly property bool reduceTransparency: store.data.accessibility.reduceTransparency
    readonly property bool reduceMotion: store.data.accessibility.reduceMotion
    readonly property var dockPinned: store.data.dock.pinned
    readonly property real dockMagnification: store.data.dock.magnification
    readonly property bool dockMagnificationEnabled: store.data.dock.magnificationEnabled
    readonly property bool dockAutohide: store.data.dock.autohide
    // Schema: integer 0..240 (0 = never); values outside the range are clamped.
    readonly property int lockIdleMinutes: Math.max(0, Math.min(240, Math.round(store.data.lock.idleMinutes)))

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

    function flush(): void {
        store.flush();
    }

    SettingsStore {
        id: store
        configDir: root.configDir
    }
}
