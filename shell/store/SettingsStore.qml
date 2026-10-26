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
    // True once a file was read and is valid (an empty file counts); false before any read and while the file on disk is
    // malformed or unreadable. Consumers that act destructively on "the settings are the defaults" wait for this, not for
    // `loaded` (which is also true for a malformed file, whose values are then only the last good ones).
    property bool validRead: false
    // True while the file on disk is valid JSON that cannot be rewritten safely (JsonSafety.unsafeReason): its values are
    // not used, the defaults are (see read()).
    property bool unsafeFile: false

    // The last document read from the file (JSON.parse of its text, the same path a fresh start takes) with the shell's own
    // pending changes on top. Every view reads from it, never from the adapter's properties: the adapter does not replace a
    // property whose new value loosely equals the old one (0 and false, 10 and "10", 1 and true), so on a running shell an
    // edit of lock.idleMinutes from 0 to false left the auto-lock off while Settings and a restarted shell read 5.
    property var parsedFile: ({})
    property int parsedFileRevision: 0

    // The stored (raw) value of a dotted key in parsedFile, undefined when the file has none.
    function rawValue(path: string): var {
        root.parsedFileRevision;
        let node = root.parsedFile;
        for (const part of path.split(".")) {
            if (node === null || node === undefined || typeof node !== "object" || Array.isArray(node))
                return undefined;
            node = node[part];
        }
        return node;
    }

    // The value of a dotted key as every reader of grassfield.json sees it (ui/Grassfield/Ui/SettingsContract.js, generated from
    // the schema; ADR-0020): a number out of range is clamped (an integer rounded first), any other invalid value, a number
    // written as a string or a boolean included, is the key's default (lock.idleMinutes: only an exact 0 is "never"; false,
    // "0", a negative number and 0.4 read 5; a value above 240 reads 240, the lock still fires). A hand-edited file may hold
    // anything and reads the same here, in a restarted shell and in the Settings app, after every reload.
    function read(path: string): var {
        // A file the Settings app refuses to edit (an integer beyond 2^53, a duplicate key: JsonSafety) shows its defaults
        // there under a banner: the shell reads the same, never the values of a file it could not rewrite safely either.
        if (root.unsafeFile && SettingsContract.DEFAULTS[path] !== undefined) {
            root.parsedFileRevision;
            return JSON.parse(JSON.stringify(SettingsContract.DEFAULTS[path]));
        }
        return SettingsContract.normalize(path, rawValue(path));
    }

    // Sets a dotted key of parsedFile (a local change, or one put back on top of a fresh load).
    function setParsed(path: string, value: var): void {
        const parts = path.split(".");
        let node = root.parsedFile;
        for (let i = 0; i < parts.length - 1; i++) {
            if (node[parts[i]] === null || typeof node[parts[i]] !== "object" || Array.isArray(node[parts[i]]))
                node[parts[i]] = ({});
            node = node[parts[i]];
        }
        node[parts[parts.length - 1]] = value;
        root.parsedFileRevision++;
    }

    // After each load: the file's own text is the document. An empty file is an empty document (every key its default). A file
    // that is not a JSON object leaves the last good document in place for the cosmetic keys (validRead tells it is malformed),
    // but NOT for lock.*: the idle lock fails closed there, it reads what a fresh start reads (the default 5), never the last
    // good value, which may be 0 = never.
    function takeDocument(text: string): void {
        let parsed = null;
        try {
            parsed = text.trim() === "" ? {} : JSON.parse(text);
        } catch (e) {
            parsed = null;
        }
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
            if ("lock" in root.parsedFile) {
                delete root.parsedFile.lock;
                root.parsedFileRevision++;
            }
            return;
        }
        root.parsedFile = parsed;
        root.parsedFileRevision++;
    }

    // The file is gone: exactly a fresh start without a file. The document is empty (every key its default, lock.idleMinutes 5),
    // the adapter is put back to the defaults, writes are allowed again (the next change creates the file from the defaults),
    // and the shell's own pending changes stay on top.
    function takeMissingFile(): void {
        root.parsedFile = ({});
        root.unsafeFile = false;
        root.writeBlocked = false;
        root.validRead = false;
        root.parsedFileRevision++;
        root.resetMissingKeys("");
        root.reapplyDirty();
    }

    readonly property string appearance: read("appearance")
    readonly property real transparency: read("material.transparency")
    readonly property string materialProfile: read("material.profile")
    readonly property bool reduceTransparency: read("accessibility.reduceTransparency")
    readonly property bool reduceMotion: read("accessibility.reduceMotion")
    readonly property bool increaseContrast: read("accessibility.increaseContrast")
    // Text size multiplier of the shell's text (Settings > Accessibility > Display), 1 to 1.3; a hand-edited value is clamped.
    readonly property real textSize: read("accessibility.textSize")
    readonly property bool zoomOn: read("accessibility.zoom")
    readonly property real zoomLevel: read("accessibility.zoomLevel")
    // Tile size of the Dock in px (Settings > Size); a hand-edited value is clamped to the slider range.
    readonly property int dockSize: read("dock.size")
    // Screen edge of the Dock (Settings > Position on screen).
    readonly property string dockPosition: read("dock.position")
    readonly property real dockMagnification: read("dock.magnification")
    readonly property bool dockMagnificationEnabled: read("dock.magnificationEnabled")
    readonly property bool dockAutohide: read("dock.autohide")
    readonly property bool dockShowRecents: read("dock.showRecents")
    readonly property bool dockMinimizeIntoApp: read("dock.minimizeIntoApp")
    readonly property bool dockAnimateOpening: read("dock.animateOpening")
    readonly property bool dockShowIndicators: read("dock.showIndicators")
    // The default list of the first releases (a file written by them holds it) reads as the current default: Files is the
    // fixed first tile now and Nautilus is no default any more (same rule as DockModel.migratePinned). Any other list, a
    // user's own, is returned as it is. Nothing is written back. The Dock owns this key and its recent list and stack options.
    readonly property var dockPinned: {
        const stored = rawValue("dock.pinned");
        const list = stringList(stored === undefined ? SettingsContract.ALL_DEFAULTS["dock.pinned"] : stored);
        return list.join("\n") === "foot\nchromium\norg.gnome.Nautilus" ? ["chromium", "foot", "org.grassfield.Settings"] : list;
    }
    readonly property var dockRecent: stringList(rawValue("dock.recent"))
    readonly property var dockFolders: read("dock.folders")
    readonly property var dockStackOptions: {
        const stored = rawValue("dock.stackOptions");
        return stored !== null && typeof stored === "object" && !Array.isArray(stored) ? stored : ({});
    }
    readonly property string titlebarDoubleClick: read("windows.titlebarDoubleClick")
    readonly property bool windowsTilingEdges: read("windows.tilingEdges")
    readonly property bool windowsTilingMenuBar: read("windows.tilingMenuBar")
    readonly property bool windowsTilingMargins: read("windows.tilingMargins")
    readonly property bool windowsStages: read("windows.stages")
    readonly property bool windowsRebuildExtension: read("windows.rebuildExtension")
    readonly property string dockMinimizeEffect: read("dock.minimizeEffect")
    readonly property bool notificationsDnd: read("notifications.dnd")
    readonly property var notificationsAppPreviews: read("notifications.appPreviews")
    readonly property var notificationsAppStyles: read("notifications.appStyles")
    readonly property string notificationsHistory: read("notifications.history")
    readonly property string notificationsPreviews: read("notifications.previews")
    readonly property bool desktopShowIcons: read("desktop.showIcons")
    readonly property bool menubarShowBackground: read("menubar.showBackground")
    readonly property string menubarAutoHide: read("menubar.autoHide")
    readonly property bool menubarShowNowPlaying: read("menubar.showNowPlaying")
    readonly property bool menubarShowSearch: read("menubar.showSearch")
    readonly property bool menubarShowWifi: read("menubar.showWifi")
    readonly property bool menubarShowSound: read("menubar.showSound")
    readonly property bool menubarShowBattery: read("menubar.showBattery")
    readonly property bool menubarShowBatteryPercentage: read("menubar.showBatteryPercentage")
    readonly property bool menubarShowFocus: read("menubar.showFocus")
    readonly property string menubarClockDate: read("menubar.clockDate")
    readonly property bool menubarClockShowAmPm: read("menubar.clockShowAmPm")
    readonly property bool menubarClockFlashSeparators: read("menubar.clockFlashSeparators")
    readonly property bool menubarShowTrayItems: read("menubar.showTrayItems")
    readonly property int menubarRecentItems: read("menubar.recentItems")
    readonly property bool menubarClockShowDayOfWeek: read("menubar.clockShowDayOfWeek")
    readonly property string menubarClockHours: read("menubar.clockHours")
    readonly property bool menubarClockShowSeconds: read("menubar.clockShowSeconds")
    readonly property string accentColor: read("accent.color")
    // automatic | mac | pc (Settings > Keyboard): how menus label shortcuts; "automatic" follows the device (MenuShortcut.style).
    readonly property string keyboardShortcutStyle: read("keyboard.shortcutStyle")
    // auto | a locale name ("fr_CH"), and auto | monday … sunday (Settings > General > Language & Region): the formats of dates,
    // times and numbers, and the first day of the week in the calendars.
    readonly property string regionFormats: read("region.formats")
    readonly property string regionFirstDayOfWeek: read("region.firstDayOfWeek")
    readonly property string iconMode: read("icons.mode")
    readonly property string iconTint: read("icons.tint")
    readonly property string folderColor: read("icons.folderColor")
    readonly property int pointerSize: read("pointer.size")
    readonly property string pointerOutlineColor: read("pointer.outlineColor")
    readonly property string pointerFillColor: read("pointer.fillColor")
    // The wallpaper settings, complete and valid (WallpaperConfig.normalize: an invalid field reads as its default).
    // The shell only reads them; the Settings app writes them.
    readonly property var wallpaper: root.unsafeFile ? WallpaperConfig.normalize({}) : WallpaperConfig.normalize({
        source: rawValue("wallpaper.source"),
        path: rawValue("wallpaper.path"),
        color: rawValue("wallpaper.color"),
        fit: rawValue("wallpaper.fit"),
        interval: rawValue("wallpaper.interval"),
        shuffle: rawValue("wallpaper.shuffle"),
        videoOnBattery: rawValue("wallpaper.videoOnBattery"),
        online: rawValue("wallpaper.online"),
        outputs: rawValue("wallpaper.outputs")
    })
    // Minutes of inactivity before the session locks, 0 = never. An invalid value is the default 5, never 0 (fail closed:
    // false or "0" in a hand-edited file must not switch the auto-lock off).
    readonly property int lockIdleMinutes: read("lock.idleMinutes")

    readonly property string hotCornerTopLeft: read("hotCorners.topLeft")
    readonly property string hotCornerTopRight: read("hotCorners.topRight")
    readonly property string hotCornerBottomLeft: read("hotCorners.bottomLeft")
    readonly property string hotCornerBottomRight: read("hotCorners.bottomRight")

    // A stored tile size: a whole number inside the slider's range (dock.sizeMin..dock.sizeMax); anything that is not a number reads
    // as the default size (same rule as Geometry.clampSize, which the Dock uses for the live resize).
    function tileSize(value: var): int {
        return typeof value === "number" && isFinite(value) ? Math.round(Math.max(Tokens.dockSizeMin, Math.min(Tokens.dockSizeMax, value))) : Tokens.dockIconSize;
    }

    // A stored Dock edge: left or right, anything else is the bottom (Geometry.normalizeEdge).
    function dockEdge(value: var): string {
        return value === "left" || value === "right" ? value : "bottom";
    }

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

    function setAppearance(value: string): void {
        change("appearance", value === "light" || value === "auto" ? value : "dark");
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

    function setIncreaseContrast(value: bool): void {
        change("accessibility.increaseContrast", value);
    }

    function setZoom(value: bool): void {
        change("accessibility.zoom", value);
    }

    function setZoomLevel(value: real): void {
        change("accessibility.zoomLevel", clampNumber(Math.round(value * 2) / 2, 1.5, 5, 2));
    }

    function setTextSize(value: real): void {
        change("accessibility.textSize", clampNumber(value, 1, 1.3, 1));
    }

    function setDockAutohide(value: bool): void {
        change("dock.autohide", value);
    }

    function setDockSize(value: real): void {
        change("dock.size", tileSize(value));
    }

    function setDockPosition(value: string): void {
        change("dock.position", dockEdge(value));
    }

    function setDockMagnification(value: real, enabled: bool): void {
        change("dock.magnification", Math.max(1, Math.min(2.5, value)));
        change("dock.magnificationEnabled", enabled);
    }

    function setDockPinned(list: var): void {
        change("dock.pinned", list);
    }

    function setDockRecent(list: var): void {
        change("dock.recent", stringList(list));
    }

    function setDockFolders(list: var): void {
        change("dock.folders", stringList(list));
    }

    // Options of the stacks as a whole ({path: {sort, view, display}}, already normalized by Stacks.withOption).
    function setDockStackOptions(options: var): void {
        change("dock.stackOptions", options && typeof options === "object" ? options : ({}));
    }

    // corner: topLeft | topRight | bottomLeft | bottomRight.
    function setHotCorner(corner: string, action: string): void {
        if (["topLeft", "topRight", "bottomLeft", "bottomRight"].indexOf(corner) < 0)
            return;
        change("hotCorners." + corner, cornerAction(action));
    }

    function setStagesEnabled(value: bool): void {
        change("windows.stages", value);
    }

    function setDesktopShowIcons(value: bool): void {
        change("desktop.showIcons", value);
    }

    function setMenubarShowBackground(value: bool): void {
        change("menubar.showBackground", value);
    }

    function setMenubarAutoHide(value: string): void {
        change("menubar.autoHide", ["always", "desktop", "fullscreen", "never"].indexOf(value) >= 0 ? value : "fullscreen");
    }

    function setAccentColor(value: string): void {
        change("accent.color", Accent.normalize(value));
    }

    function setIconMode(value: string): void {
        change("icons.mode", IconModes.normalizeMode(value));
    }

    function setIconTint(value: string): void {
        change("icons.tint", IconModes.validTint(value) ? value : "accent");
    }

    function setFolderColor(value: string): void {
        change("icons.folderColor", FolderStyle.normalizeColor(value));
    }

    function setPointerSize(value: int): void {
        change("pointer.size", PointerSize.snap(value));
    }

    function setNotificationsDnd(value: bool): void {
        change("notifications.dnd", value);
    }

    // One app's Show previews: always | unlocked | never, or "default" to follow the global setting again.
    function setNotificationsAppPreview(app: string, value: string): void {
        change("notifications.appPreviews", NotificationPrefs.withValue(notificationsAppPreviews, app, value));
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
        setParsed(path, value);
        const d = dirty;
        d[path] = value;
        dirty = d;
        save();
    }

    function applyPath(path: string, value: var): void {
        const parts = path.split(".");
        let target = config;
        for (let i = 0; i < parts.length - 1; i++) {
            target = target[parts[i]];
            // A group that is not an object (a var that held null or a number in a hand-edited file) has nothing to set.
            if (target === null || target === undefined || typeof target !== "object")
                return;
        }
        target[parts[parts.length - 1]] = value;
    }

    // A reload from disk replaces the adapter values; put pending local changes back on top.
    function reapplyDirty(): void {
        for (const path in dirty) {
            applyPath(path, dirty[path]);
            setParsed(path, dirty[path]);
        }
    }

    // Merge the dirty keys into the file as it is on disk right now (fresh read) and write the
    // result atomically. Keys the shell does not know are kept as they are. A file that is
    // missing or empty is created from the full adapter state. A malformed file is never written.
    function writeMerged(): void {
        if (writeBlocked)
            return;
        diskRead.running = true;
    }

    // The document of a fresh file: every key of the schema (nested) at its default, the contract version first.
    function defaultDocument(): var {
        const doc = {version: SettingsContract.VERSION};
        for (const path in SettingsContract.ALL_DEFAULTS) {
            const parts = path.split(".");
            let node = doc;
            for (let i = 0; i < parts.length - 1; i++) {
                if (node[parts[i]] === undefined)
                    node[parts[i]] = {};
                node = node[parts[i]];
            }
            node[parts[parts.length - 1]] = JSON.parse(JSON.stringify(SettingsContract.ALL_DEFAULTS[path]));
        }
        return doc;
    }

    // Second half of writeMerged(), once the fresh file text is in.
    function mergeInto(text: string): void {
        if (writeBlocked)
            return;
        let obj = null;
        if (text.trim() === "") {
            // A missing or empty file: a fresh one holding every key at its default. Built from the schema defaults, never from
            // the JSON adapter (file.writeAdapter()), which keeps the values of the file that was there before.
            obj = defaultDocument();
        } else {
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
        // FileView skips a write equal to the text it last wrote, even when another writer (the Settings app) changed
        // the file since: a Quick Settings change back to an earlier value was applied but never saved. Re-read first
        // so its cache is the file on disk (the same guard as the lock marker, Lock.qml writeMarker).
        disk.reload();
        disk.waitForJob();
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
        let unsafeNow = false;
        if (ok) {
            const unsafe = JsonSafety.unsafeReason(text);
            if (unsafe !== "") {
                ok = false;
                unsafeNow = true;
                why = "cannot be rewritten safely: " + unsafe;
            }
        }
        unsafeFile = unsafeNow;
        if (!ok && !writeBlocked)
            console.warn("settings: " + file.path + " " + why + "; keeping the file untouched, changes will not be saved until it is fixed");
        writeBlocked = !ok;
        validRead = ok;
        if (!ok)
            saveTimer.stop();
    }

    function reload(): void {
        file.reload();
    }

    // The views read parsedFile, not the adapter, and a write is built from the file on disk (or the schema defaults), not from the adapter either.
    // The adapter keeps the old value of a key that is no longer in the file (a reload only assigns the keys it finds), so an emptied
    // file would show stale values in store.data. A missing key is the default there too: put it back after each load, for every
    // key of the contract (SettingsContract.ALL_DEFAULTS; unsaved local changes go on top again in reapplyDirty). A file that
    // cannot be parsed is left alone.
    function resetMissingKeys(text: string): void {
        let parsed = null;
        try {
            parsed = text.trim() === "" ? {} : JSON.parse(text);
        } catch (e) {
            return;
        }
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
            return;
        for (const path in SettingsContract.ALL_DEFAULTS) {
            let node = parsed;
            let present = true;
            for (const part of path.split(".")) {
                if (node === null || typeof node !== "object" || Array.isArray(node) || !(part in node)) {
                    present = false;
                    break;
                }
                node = node[part];
            }
            if (!present) {
                // wallpaper.online is one var holding an object (it may hold anything in a hand-edited file, null included):
                // it is put back whole.
                if (path === "wallpaper.online.provider")
                    config.wallpaper.online = {provider: SettingsContract.ALL_DEFAULTS[path]};
                else
                    applyPath(path, JSON.parse(JSON.stringify(SettingsContract.ALL_DEFAULTS[path])));
            }
        }
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

    // Every key of the schema, a var each, with its default (generated: scripts/dev/gen-settings.py).
    SettingsData {
        id: config
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

    // The directory is created first and the FileView gets its path only afterwards: a FileView cannot watch inside a
    // directory that does not exist yet (see WatchedDir), so on a fresh account no Settings change would apply.
    WatchedDir {
        id: watchedDir
        path: root.configDir
    }

    FileView {
        id: file
        path: watchedDir.ready ? root.configDir + "/grassfield.json" : ""
        watchChanges: true
        printErrors: false
        atomicWrites: true
        // Quickshell qmltypes name this property's type PendingRegion/FileViewAdapter without exporting it (metadata quirk).
        // qmllint disable missing-type
        adapter: config
        // qmllint enable missing-type
        onFileChanged: reload()
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                root.takeMissingFile();
        }
        onSaved: root.saved()
        onLoaded: {
            root.checkText(file.text());
            root.takeDocument(file.text());
            root.resetMissingKeys(file.text());
            root.reapplyDirty();
            root.loadedFile();
        }
    }
}
