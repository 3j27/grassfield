pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// User configuration (grassfield.json, contract version 1). Read-only here: a missing
// or unreadable file simply leaves the defaults in place and nothing is ever created.
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

    readonly property int version: config.version
    readonly property string appearance: config.appearance
    readonly property bool dark: config.appearance !== "light"
    readonly property real transparency: config.material.transparency
    readonly property bool reduceTransparency: config.accessibility.reduceTransparency
    readonly property bool reduceMotion: config.accessibility.reduceMotion
    readonly property var dockPinned: config.dock.pinned

    component MaterialConfig: JsonObject {
        property real transparency: 0.25
    }

    component AccessibilityConfig: JsonObject {
        property bool reduceTransparency: false
        property bool reduceMotion: false
    }

    component DockConfig: JsonObject {
        property var pinned: ["foot", "chromium", "org.gnome.Nautilus"]
    }

    JsonAdapter {
        id: config
        property int version: 1
        property string appearance: "dark"
        property MaterialConfig material: MaterialConfig {}
        property AccessibilityConfig accessibility: AccessibilityConfig {}
        property DockConfig dock: DockConfig {}
    }

    FileView {
        path: root.configDir + "/grassfield.json"
        watchChanges: true
        printErrors: false
        // Quickshell qmltypes name this property's type PendingRegion/FileViewAdapter without exporting it (metadata quirk).
        // qmllint disable missing-type
        adapter: config
        // qmllint enable missing-type
        onFileChanged: reload()
    }
}
