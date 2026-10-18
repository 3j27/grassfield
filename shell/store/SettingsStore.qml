pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// grassfield.json (contract version 1): schema, defaults, persistence. Not a singleton so that
// tests can create independent instances; the shell uses it through the Settings singleton.
// A missing or unreadable file leaves the defaults in place. The file is created on the first
// change made through a setter (Control Center, Dock menu), never otherwise. Every key of
// config/schema/grassfield.schema.json is declared so that a fresh file holds every key. Writes
// are merges: each setter records its dotted key in `dirty`; before writing, the file is re-read
// and only the dirty keys are replaced, so external edits (Settings app, by hand) and keys this
// shell does not know (not allowed by the schema, but never dropped) survive. The result is
// written atomically. A file that exists but is not valid JSON, or that JSON.parse cannot
// round-trip (integers beyond 2^53, duplicate keys; JsonSafety.js, same rule as the Settings app),
// is never overwritten (`writeBlocked`, logged once); the in-memory changes stay and the user
// fixes the file.
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
    readonly property string hotCornerTopLeft: cornerAction(config.hotCorners.topLeft)
    readonly property string hotCornerTopRight: cornerAction(config.hotCorners.topRight)
    readonly property string hotCornerBottomLeft: cornerAction(config.hotCorners.bottomLeft)
    readonly property string hotCornerBottomRight: cornerAction(config.hotCorners.bottomRight)

    // Hot corner action clamped to the schema enum.
    function cornerAction(value: var): string {
        return ["none", "overview", "notifications", "apps", "lock"].indexOf(value) >= 0 ? value : "none";
    }

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
        property bool magnificationEnabled: false
        property bool autohide: false
    }

    component WindowsConfig: JsonObject {
        property string titlebarDoubleClick: "zoom"
    }

    component LockConfig: JsonObject {
        property int idleMinutes: 5
    }

    component HotCornersConfig: JsonObject {
        property string topLeft: "none"
        property string topRight: "none"
        property string bottomLeft: "none"
        property string bottomRight: "none"
    }

    component DesktopConfig: JsonObject {
        property bool showIcons: true
    }

    component MenubarConfig: JsonObject {
        // false: the bar is transparent like macOS 26/27; true restores the frosted material band.
        property bool showBackground: false
    }

    component NotificationsConfig: JsonObject {
        property bool dnd: false
        // always | unlocked | never (ADR-0004). "never" hides bodies; "unlocked" equals "always" until the lock screen exists.
        property string previews: "unlocked"
    }

    function setAppearance(value: string): void {
        change("appearance", value === "light" ? "light" : "dark");
    }

    function setTransparency(value: real): void {
        change("material.transparency", Math.max(0, Math.min(1, value)));
    }

    function setReduceTransparency(value: bool): void {
        change("accessibility.reduceTransparency", value);
    }

    function setReduceMotion(value: bool): void {
        change("accessibility.reduceMotion", value);
    }

    function setDockAutohide(value: bool): void {
        change("dock.autohide", value);
    }

    function setDockMagnification(value: real, enabled: bool): void {
        change("dock.magnification", Math.max(1, Math.min(2.5, value)));
        change("dock.magnificationEnabled", enabled);
    }

    function setDockPinned(list: var): void {
        change("dock.pinned", list);
    }

    // corner: topLeft | topRight | bottomLeft | bottomRight.
    function setHotCorner(corner: string, action: string): void {
        if (["topLeft", "topRight", "bottomLeft", "bottomRight"].indexOf(corner) < 0)
            return;
        change("hotCorners." + corner, cornerAction(action));
    }

    function setDesktopShowIcons(value: bool): void {
        change("desktop.showIcons", value);
    }

    function setMenubarShowBackground(value: bool): void {
        change("menubar.showBackground", value);
    }

    function setNotificationsDnd(value: bool): void {
        change("notifications.dnd", value);
    }

    function setNotificationsPreviews(value: string): void {
        change("notifications.previews", ["always", "unlocked", "never"].indexOf(value) >= 0 ? value : "unlocked");
    }

    // Keys the shell changed since its last write: dotted path -> value. Only these are merged into
    // the file, so edits made elsewhere (Settings app, by hand) survive.
    property var dirty: ({})

    // Setter helper: update the in-memory adapter and remember the key for the next merge.
    function change(path: string, value: var): void {
        applyPath(path, value);
        const d = dirty;
        d[path] = value;
        dirty = d;
        save();
    }

    function applyPath(path: string, value: var): void {
        const parts = path.split(".");
        let target = config;
        for (let i = 0; i < parts.length - 1; i++)
            target = target[parts[i]];
        target[parts[parts.length - 1]] = value;
    }

    // A reload from disk replaces the adapter values; put pending local changes back on top.
    function reapplyDirty(): void {
        for (const path in dirty)
            applyPath(path, dirty[path]);
    }

    // Merge the dirty keys into the file as it is on disk right now (fresh read) and write the
    // result atomically. Keys the shell does not know are kept as they are. A file that is
    // missing or empty is created from the full adapter state. A malformed file is never written.
    function writeMerged(): void {
        if (writeBlocked)
            return;
        diskRead.running = true;
    }

    // Second half of writeMerged(), once the fresh file text is in.
    function mergeInto(text: string): void {
        if (writeBlocked)
            return;
        if (text.trim() === "") {
            file.writeAdapter();
            dirty = ({});
            return;
        }
        let obj = null;
        try {
            obj = JSON.parse(text);
        } catch (e) {
            obj = null;
        }
        if (obj === null || typeof obj !== "object" || Array.isArray(obj)) {
            checkText(text);
            return;
        }
        if (JsonSafety.unsafeReason(text) !== "") {
            checkText(text);
            return;
        }
        for (const path in dirty) {
            const parts = path.split(".");
            let target = obj;
            for (let i = 0; i < parts.length - 1; i++) {
                if (target[parts[i]] === null || typeof target[parts[i]] !== "object" || Array.isArray(target[parts[i]]))
                    target[parts[i]] = {};
                target = target[parts[i]];
            }
            target[parts[parts.length - 1]] = dirty[path];
        }
        dirty = ({});
        disk.setText(JSON.stringify(obj, null, 2) + "\n");
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
        let why = "is not valid JSON";
        if (ok) {
            const unsafe = JsonSafety.unsafeReason(text);
            if (unsafe !== "") {
                ok = false;
                why = "cannot be rewritten safely: " + unsafe;
            }
        }
        if (!ok && !writeBlocked)
            console.warn("settings: " + file.path + " " + why + "; keeping the file untouched, changes will not be saved until it is fixed");
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
                root.writeMerged();
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
        property HotCornersConfig hotCorners: HotCornersConfig {}
        property DesktopConfig desktop: DesktopConfig {}
        property MenubarConfig menubar: MenubarConfig {}
    }

    // Fresh read of the file for the merge (the watched FileView may lag behind an external write).
    Process {
        id: diskRead
        command: ["sh", "-c", 'cat "$1" 2>/dev/null; true', "sh", file.path]
        stdout: StdioCollector {
            onStreamFinished: root.mergeInto(text)
        }
    }

    // Atomic write of the merged text; never watched.
    FileView {
        id: disk
        path: file.path
        printErrors: false
        atomicWrites: true
        onSaved: root.saved()
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
            root.reapplyDirty();
            root.loadedFile();
        }
    }
}
