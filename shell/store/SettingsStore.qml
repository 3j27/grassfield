pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// grassfield.json (contract version 1): schema, defaults, persistence. Not a singleton so that
// tests can create independent instances; the shell uses it through the Settings singleton.
// A missing or unreadable file leaves the defaults in place. The file is created on the first
// change made through a setter (Control Center, Dock menu), never otherwise.
Scope {
    id: root

    property string configDir: ""
    // Debounce for writes; tests use flush().
    property int saveDelay: 150

    readonly property alias data: config
    readonly property alias loaded: file.loaded

    signal saved
    signal loadedFile

    component MaterialConfig: JsonObject {
        property real transparency: 0.25
    }

    component AccessibilityConfig: JsonObject {
        property bool reduceTransparency: false
        property bool reduceMotion: false
    }

    component DockConfig: JsonObject {
        property var pinned: ["foot", "chromium", "org.gnome.Nautilus"]
        property real magnification: 1.6
        property bool magnificationEnabled: true
        property bool autohide: false
    }

    function setAppearance(value: string): void {
        config.appearance = value === "light" ? "light" : "dark";
        save();
    }

    function setTransparency(value: real): void {
        config.material.transparency = Math.max(0, Math.min(1, value));
        save();
    }

    function setReduceTransparency(value: bool): void {
        config.accessibility.reduceTransparency = value;
        save();
    }

    function setReduceMotion(value: bool): void {
        config.accessibility.reduceMotion = value;
        save();
    }

    function setDockAutohide(value: bool): void {
        config.dock.autohide = value;
        save();
    }

    function setDockMagnification(value: real, enabled: bool): void {
        config.dock.magnification = Math.max(1, Math.min(2.5, value));
        config.dock.magnificationEnabled = enabled;
        save();
    }

    function setDockPinned(list: var): void {
        config.dock.pinned = list;
        save();
    }

    function save(): void {
        saveTimer.restart();
    }

    // Write now (tests, shutdown).
    function flush(): void {
        saveTimer.stop();
        mkdir.running = true;
    }

    function reload(): void {
        file.reload();
    }

    Timer {
        id: saveTimer
        interval: root.saveDelay
        onTriggered: mkdir.running = true
    }

    // The config directory may not exist yet.
    Process {
        id: mkdir
        command: ["mkdir", "-p", root.configDir]
        onRunningChanged: {
            if (!running)
                file.writeAdapter();
        }
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
        id: file
        path: root.configDir !== "" ? root.configDir + "/grassfield.json" : ""
        watchChanges: true
        printErrors: false
        atomicWrites: true
        // Quickshell qmltypes name this property's type PendingRegion/FileViewAdapter without exporting it (metadata quirk).
        // qmllint disable missing-type
        adapter: config
        // qmllint enable missing-type
        onFileChanged: reload()
        onSaved: root.saved()
        onLoaded: root.loadedFile()
    }
}
