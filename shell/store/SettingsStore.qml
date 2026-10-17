pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// grassfield.json (contract version 1): schema, defaults, persistence. Not a singleton so that
// tests can create independent instances; the shell uses it through the Settings singleton.
// A missing or unreadable file leaves the defaults in place. The file is created on the first
// change made through a setter (Control Center, Dock menu), never otherwise. Every key of
// config/schema/grassfield.schema.json is declared so that a write keeps the whole file. A file
// that exists but is not valid JSON is never overwritten (`writeBlocked`); the user fixes it.
Scope {
    id: root

    property string configDir: ""
    // Debounce for writes; tests use flush().
    property int saveDelay: 150

    readonly property alias data: config
    readonly property alias loaded: file.loaded
    // True while the file on disk could not be parsed: nothing is written until it loads again.
    property bool writeBlocked: false

    // Validated views of the loaded values (a hand-edited file may hold anything).
    readonly property string appearance: ["dark", "light", "auto"].indexOf(config.appearance) >= 0 ? config.appearance : "dark"
    readonly property real transparency: clampNumber(config.material.transparency, 0, 1, 0.25)
    readonly property string materialProfile: ["full", "balanced", "reduced"].indexOf(config.material.profile) >= 0 ? config.material.profile : "balanced"
    readonly property real dockMagnification: clampNumber(config.dock.magnification, 1, 2.5, 1.6)
    readonly property var dockPinned: stringList(config.dock.pinned)
    readonly property string titlebarDoubleClick: ["zoom", "minimize", "none"].indexOf(config.windows.titlebarDoubleClick) >= 0 ? config.windows.titlebarDoubleClick : "zoom"
    readonly property string notificationsPreviews: ["always", "unlocked", "never"].indexOf(config.notifications.previews) >= 0 ? config.notifications.previews : "unlocked"
    readonly property int lockIdleMinutes: Math.round(clampNumber(config.lock.idleMinutes, 0, 240, 5))

    // Array-like (the adapter hands out a QVariantList) to a plain array of non-empty strings.
    function stringList(list: var): var {
        const out = [];
        const n = list && typeof list.length === "number" ? list.length : 0;
        for (let i = 0; i < n; i++) {
            if (typeof list[i] === "string" && list[i] !== "")
                out.push(list[i]);
        }
        return out;
    }

    function clampNumber(value: var, min: real, max: real, fallback: real): real {
        const n = Number(value);
        return isFinite(n) ? Math.max(min, Math.min(max, n)) : fallback;
    }

    signal saved
    signal loadedFile

    component MaterialConfig: JsonObject {
        property real transparency: 0.25
        property string profile: "balanced"
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

    component WindowsConfig: JsonObject {
        property string titlebarDoubleClick: "zoom"
    }

    component LockConfig: JsonObject {
        property int idleMinutes: 5
    }

    component NotificationsConfig: JsonObject {
        property bool dnd: false
        // always | unlocked | never (ADR-0004). "never" hides bodies; "unlocked" equals "always" until the lock screen exists.
        property string previews: "unlocked"
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

    function setNotificationsDnd(value: bool): void {
        config.notifications.dnd = value;
        save();
    }

    function setNotificationsPreviews(value: string): void {
        config.notifications.previews = ["always", "unlocked", "never"].indexOf(value) >= 0 ? value : "unlocked";
        save();
    }

    function save(): void {
        if (!writeBlocked)
            saveTimer.restart();
    }

    // Write now (tests, shutdown).
    function flush(): void {
        saveTimer.stop();
        if (!writeBlocked)
            mkdir.running = true;
    }

    // Called with the file contents after each load: a malformed file blocks all writes.
    function checkText(text: string): void {
        let ok = true;
        // An empty file is a fresh one, not a damaged one.
        try {
            const parsed = text.trim() === "" ? {} : JSON.parse(text);
            ok = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
        } catch (e) {
            ok = false;
        }
        if (!ok && !writeBlocked)
            console.warn("settings: " + file.path + " is not valid JSON; keeping the file untouched, changes will not be saved until it is fixed");
        writeBlocked = !ok;
        if (!ok)
            saveTimer.stop();
    }

    function reload(): void {
        file.reload();
    }

    Timer {
        id: saveTimer
        interval: root.saveDelay
        onTriggered: {
            if (!root.writeBlocked)
                mkdir.running = true;
        }
    }

    // The config directory may not exist yet.
    Process {
        id: mkdir
        command: ["mkdir", "-p", root.configDir]
        onRunningChanged: {
            if (!running && !root.writeBlocked)
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
        property WindowsConfig windows: WindowsConfig {}
        property NotificationsConfig notifications: NotificationsConfig {}
        property LockConfig lock: LockConfig {}
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
        onLoaded: {
            root.checkText(file.text());
            root.loadedFile();
        }
    }
}
