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
    // `loaded` (which is also true for a malformed file, whose values are then only the adapter's leftovers).
    property bool validRead: false

    // The value of a dotted key as every reader of grassfield.json sees it (ui/Grassfield/Ui/SettingsContract.js, generated from
    // the schema; ADR-0020): a number out of range is clamped (an integer rounded first), any other invalid value, a number
    // written as a string or a boolean included, is the key's default. The adapter keeps the stored values untouched (its
    // leaves are vars), so a hand-edited file may hold anything and still reads the same here and in the Settings app.
    function read(path: string): var {
        let node = config;
        for (const part of path.split("."))
            node = node === null || node === undefined ? undefined : node[part];
        // A list comes out of the adapter as an array-like (a QVariantList): the contract checks real arrays.
        if (node !== null && typeof node === "object" && !Array.isArray(node) && typeof node.length === "number")
            node = Array.prototype.slice.call(node);
        return SettingsContract.normalize(path, node);
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
        const list = stringList(config.dock.pinned);
        return list.join("\n") === "foot\nchromium\norg.gnome.Nautilus" ? ["chromium", "foot", "org.grassfield.Settings"] : list;
    }
    readonly property var dockRecent: stringList(config.dock.recent)
    readonly property var dockFolders: read("dock.folders")
    readonly property var dockStackOptions: config.dock.stackOptions && typeof config.dock.stackOptions === "object" ? config.dock.stackOptions : ({})
    readonly property string titlebarDoubleClick: read("windows.titlebarDoubleClick")
    readonly property bool windowsTilingEdges: read("windows.tilingEdges")
    readonly property bool windowsTilingMenuBar: read("windows.tilingMenuBar")
    readonly property bool windowsTilingMargins: read("windows.tilingMargins")
    readonly property bool windowsStages: read("windows.stages")
    readonly property bool windowsRebuildExtension: read("windows.rebuildExtension")
    readonly property string dockMinimizeEffect: read("dock.minimizeEffect")
    readonly property bool notificationsDnd: read("notifications.dnd")
    readonly property var notificationsAppPreviews: NotificationPrefs.normalize(config.notifications.appPreviews)
    readonly property var notificationsAppStyles: NotificationPrefs.normalizeStyles(config.notifications.appStyles)
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
    readonly property string iconMode: read("icons.mode")
    readonly property string iconTint: read("icons.tint")
    readonly property string folderColor: read("icons.folderColor")
    readonly property int pointerSize: read("pointer.size")
    readonly property string pointerOutlineColor: read("pointer.outlineColor")
    readonly property string pointerFillColor: read("pointer.fillColor")
    // The wallpaper settings, complete and valid (WallpaperConfig.normalize: an invalid field reads as its default).
    // The shell only reads them; the Settings app writes them.
    readonly property var wallpaper: WallpaperConfig.normalize({
        source: config.wallpaper.source,
        path: config.wallpaper.path,
        color: config.wallpaper.color,
        fit: config.wallpaper.fit,
        interval: config.wallpaper.interval,
        shuffle: config.wallpaper.shuffle,
        videoOnBattery: config.wallpaper.videoOnBattery,
        online: config.wallpaper.online,
        outputs: config.wallpaper.outputs
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

    component MaterialConfig: JsonObject {
        property var transparency: 0.25
        property var profile: "balanced"
    }

    component AccessibilityConfig: JsonObject {
        property var reduceTransparency: false
        property var reduceMotion: false
        property var increaseContrast: false
        property var textSize: 1
        // Screen magnification (Hyprland cursor:zoom_factor): on or off, and the factor while on, 1.5 to 5.
        property var zoom: false
        property var zoomLevel: 2
    }

    component DockConfig: JsonObject {
        property var pinned: ["chromium", "foot", "org.grassfield.Settings"]
        property var size: 48
        property var position: "bottom"
        property var magnification: 1.6
        property var magnificationEnabled: false
        property var autohide: false
        // Recently launched apps that are not pinned, newest first (owned by the Dock), and whether to show them.
        property var recent: []
        property var showRecents: true
        // Folder stacks in the right section of the Dock ("~/" allowed) and their options per folder (Stacks.js).
        property var folders: ["~/Downloads"]
        property var stackOptions: ({})
        // Minimized windows go into their app's tile instead of getting a tile of their own.
        property var minimizeIntoApp: false
        // "Animate opening applications": the launch bounce (macOS). Attention bounces are not part of it.
        property var animateOpening: true
        // "Show indicators for open applications": the running dot under apps (macOS).
        property var showIndicators: true
        // "Minimize animation": funnel (the default) | shrink. The compositor plugin draws it.
        property var minimizeEffect: "funnel"
    }

    component WindowsConfig: JsonObject {
        property var titlebarDoubleClick: "zoom"
        // Window tiling (macOS 15+, all on by default): drag to the screen edges, drag to the menu bar, margins.
        property var tilingEdges: true
        property var tilingMenuBar: true
        property var tilingMargins: true
        // Stages (macOS: Desktop & Dock > Windows, off by default; ADR-0013, owner decision D-4): pushed to the compositor
        // plugin as config("stagesEnabled") while it advertises stages-available.
        property var stages: false
        // "Rebuild the compositor extension after Hyprland updates" (opt-in, ADR-0009 amendment 2026-10-23): when no
        // extension build matches the installed Hyprland the shell (shell.qml) runs grassfield-compositor-rebuild
        // --session in the background.
        property var rebuildExtension: false
    }

    component LockConfig: JsonObject {
        property var idleMinutes: 5
    }

    component HotCornersConfig: JsonObject {
        property var topLeft: "none"
        property var topRight: "none"
        property var bottomLeft: "none"
        property var bottomRight: "none"
    }

    component DesktopConfig: JsonObject {
        property var showIcons: true
    }

    component MenubarConfig: JsonObject {
        // false: the bar is transparent like macOS 26/27; true restores the frosted material band.
        property var showBackground: false
        // always | desktop | fullscreen | never: "Automatically hide and show the menu bar" (BarHide.js).
        property var autoHide: "fullscreen"
        // Now Playing item of the bar (Settings > Desktop & Dock > Menu Bar): shown while a player has a session.
        property var showNowPlaying: true
        // Search item (magnifier) of the bar.
        property var showSearch: true
        // Status items (Settings > Menu Bar, macOS Control Center menu bar modules).
        property var showWifi: true
        property var showSound: true
        property var showBattery: true
        property var showBatteryPercentage: true
        property var showFocus: true
        // Clock (macOS Clock options): date, day of the week, hour format (auto | 12 | 24), seconds.
        property var clockDate: "auto"
        property var clockShowAmPm: true
        property var clockFlashSeparators: false
        property var showTrayItems: true
        property var recentItems: 10
        property var clockShowDayOfWeek: true
        property var clockHours: "auto"
        property var clockShowSeconds: false
    }

    component AccentConfig: JsonObject {
        // multicolor | blue | purple | pink | red | orange | yellow | green | graphite (Settings > Appearance > Accent colour).
        property var color: "multicolor"
    }

    component IconsConfig: JsonObject {
        // default | dark | clear | tinted (ADR-0014): app and file icons only.
        property var mode: "default"
        // "accent" or a #rrggbb colour for the tinted mode.
        property var tint: "accent"
        // "theme" (the icon theme's own folder colour), "accent" or a #rrggbb colour: every folder icon.
        property var folderColor: "theme"
    }

    component PointerConfig: JsonObject {
        // Cursor size in pixels, 24 to 96 (Settings > Accessibility > Pointer). A var, not an int: an int property
        // would turn "64" into a valid size before PointerSize.fromStored could refuse it (a number is rounded and clamped there).
        property var size: 24
        // #rrggbb colours of the pointer (outline white, fill black = the packaged theme). Vars for the same reason.
        property var outlineColor: "#ffffff"
        property var fillColor: "#000000"
    }

    component WallpaperJson: JsonObject {
        // Vars, not typed properties: a hand-edited file may hold anything, and WallpaperConfig.normalize decides
        // what is valid (a typed property would coerce 1 or "false" into a valid value first).
        property var source: "builtin"
        property var path: ""
        property var color: "#000000"
        property var fit: "fill"
        property var interval: "1h"
        property var shuffle: true
        property var videoOnBattery: false
        // {provider}: a var too, a hand-edited file may hold anything (WallpaperConfig.normalize decides).
        property var online: ({provider: "commons"})
        property var outputs: []
    }

    component NotificationsConfig: JsonObject {
        property var dnd: false
        // always | unlocked | never (ADR-0004). "never" hides bodies; "unlocked" equals "always" until the lock screen exists.
        property var previews: "unlocked"
        // Per-app overrides [{app, previews}] (NotificationPrefs.js).
        property var appPreviews: []
        // Per-app alert style overrides [{app, style}] (banners | alerts | none, NotificationPrefs.js).
        property var appStyles: []
        // How long the history stays on disk: week | day | never.
        property var history: "week"
    }

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
        validRead = ok;
        if (!ok)
            saveTimer.stop();
    }

    function reload(): void {
        file.reload();
    }

    // The adapter keeps the old value of a key that is no longer in the file (a reload only assigns the keys it finds), so a
    // key deleted by hand (or by a reset elsewhere) would leave the old value active while the Settings app shows the default.
    // A missing key is the default: put it back after each load, for every key of the contract (SettingsContract.ALL_DEFAULTS;
    // unsaved local changes go on top again in reapplyDirty). A file that cannot be parsed is left alone.
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
            if (!present)
                applyPath(path, JSON.parse(JSON.stringify(SettingsContract.ALL_DEFAULTS[path])));
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

    JsonAdapter {
        id: config
        property int version: 1
        property var appearance: "dark"
        property MaterialConfig material: MaterialConfig {}
        property AccessibilityConfig accessibility: AccessibilityConfig {}
        property DockConfig dock: DockConfig {}
        property WindowsConfig windows: WindowsConfig {}
        property NotificationsConfig notifications: NotificationsConfig {}
        property LockConfig lock: LockConfig {}
        property HotCornersConfig hotCorners: HotCornersConfig {}
        property DesktopConfig desktop: DesktopConfig {}
        property MenubarConfig menubar: MenubarConfig {}
        property AccentConfig accent: AccentConfig {}
        property IconsConfig icons: IconsConfig {}
        property PointerConfig pointer: PointerConfig {}
        property WallpaperJson wallpaper: WallpaperJson {}
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
        onSaved: root.saved()
        onLoaded: {
            root.checkText(file.text());
            root.resetMissingKeys(file.text());
            root.reapplyDirty();
            root.loadedFile();
        }
    }
}
