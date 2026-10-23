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

    // Validated views of the loaded values (a hand-edited file may hold anything).
    readonly property string appearance: ["dark", "light", "auto"].indexOf(config.appearance) >= 0 ? config.appearance : "dark"
    readonly property real transparency: clampNumber(config.material.transparency, 0, 1, 0.25)
    readonly property string materialProfile: ["full", "balanced", "reduced"].indexOf(config.material.profile) >= 0 ? config.material.profile : "balanced"
    // Text size multiplier of the shell's text (Settings > Accessibility > Display), 1 to 1.3; a hand-edited value is clamped.
    readonly property real textSize: clampNumber(config.accessibility.textSize, 1, 1.3, 1)
    // Tile size of the Dock in px (Settings > Size); a hand-edited value is clamped to the slider range.
    readonly property int dockSize: tileSize(config.dock.size)
    // Screen edge of the Dock (Settings > Position on screen); anything but left/right is the bottom.
    readonly property string dockPosition: dockEdge(config.dock.position)
    readonly property real dockMagnification: clampNumber(config.dock.magnification, 1, 2.5, 1.6)
    // The default list of the first releases (a file written by them holds it) reads as the current default: Files is the
    // fixed first tile now and Nautilus is no default any more (same rule as DockModel.migratePinned). Any other list, a
    // user's own, is returned as it is. Nothing is written back.
    readonly property var dockPinned: {
        const list = stringList(config.dock.pinned);
        return list.join("\n") === "foot\nchromium\norg.gnome.Nautilus" ? ["chromium", "foot", "org.grassfield.Settings"] : list;
    }
    readonly property var dockRecent: stringList(config.dock.recent)
    readonly property string titlebarDoubleClick: ["zoom", "minimize", "none"].indexOf(config.windows.titlebarDoubleClick) >= 0 ? config.windows.titlebarDoubleClick : "zoom"
    readonly property string dockMinimizeEffect: ["funnel", "shrink"].indexOf(config.dock.minimizeEffect) >= 0 ? config.dock.minimizeEffect : "funnel"
    readonly property var notificationsAppPreviews: NotificationPrefs.normalize(config.notifications.appPreviews)
    readonly property string notificationsPreviews: ["always", "unlocked", "never"].indexOf(config.notifications.previews) >= 0 ? config.notifications.previews : "unlocked"
    readonly property string menubarAutoHide: ["always", "desktop", "fullscreen", "never"].indexOf(config.menubar.autoHide) >= 0 ? config.menubar.autoHide : "fullscreen"
    readonly property string accentColor: Accent.normalize(config.accent.color)
    readonly property string iconMode: IconModes.normalizeMode(config.icons.mode)
    readonly property string iconTint: IconModes.validTint(config.icons.tint) ? config.icons.tint : "accent"
    readonly property string folderColor: FolderStyle.normalizeColor(config.icons.folderColor)
    readonly property int pointerSize: PointerSize.fromStored(config.pointer.size)
    readonly property string pointerOutlineColor: PointerColors.normalizeOutline(config.pointer.outlineColor)
    readonly property string pointerFillColor: PointerColors.normalizeFill(config.pointer.fillColor)
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
    readonly property int lockIdleMinutes: Math.round(clampNumber(config.lock.idleMinutes, 0, 240, 5))

    // Array-like (the adapter hands out a QVariantList) to a plain array of non-empty strings.
    readonly property string hotCornerTopLeft: cornerAction(config.hotCorners.topLeft)
    readonly property string hotCornerTopRight: cornerAction(config.hotCorners.topRight)
    readonly property string hotCornerBottomLeft: cornerAction(config.hotCorners.bottomLeft)
    readonly property string hotCornerBottomRight: cornerAction(config.hotCorners.bottomRight)

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
        property real transparency: 0.25
        property string profile: "balanced"
    }

    component AccessibilityConfig: JsonObject {
        property bool reduceTransparency: false
        property bool reduceMotion: false
        property bool increaseContrast: false
        property real textSize: 1
    }

    component DockConfig: JsonObject {
        property var pinned: ["chromium", "foot", "org.grassfield.Settings"]
        property var size: 48
        property string position: "bottom"
        property real magnification: 1.6
        property bool magnificationEnabled: false
        property bool autohide: false
        // Recently launched apps that are not pinned, newest first (owned by the Dock), and whether to show them.
        property var recent: []
        property bool showRecents: true
        // Minimized windows go into their app's tile instead of getting a tile of their own.
        property bool minimizeIntoApp: false
        // "Animate opening applications": the launch bounce (macOS). Attention bounces are not part of it.
        property bool animateOpening: true
        // "Show indicators for open applications": the running dot under apps (macOS).
        property bool showIndicators: true
        // "Minimize animation": funnel (the default) | shrink. The compositor plugin draws it.
        property string minimizeEffect: "funnel"
    }

    component WindowsConfig: JsonObject {
        property string titlebarDoubleClick: "zoom"
        // Window tiling (macOS 15+, all on by default): drag to the screen edges, drag to the menu bar, margins.
        property bool tilingEdges: true
        property bool tilingMenuBar: true
        property bool tilingMargins: true
        // Stages (macOS: Desktop & Dock > Windows, off by default; ADR-0013, owner decision D-4): pushed to the compositor
        // plugin as config("stagesEnabled") while it advertises stages-available.
        property bool stages: false
        // "Rebuild the compositor extension after Hyprland updates" (opt-in, ADR-0009 amendment 2026-10-23): when no
        // extension build matches the installed Hyprland the shell (shell.qml) runs grassfield-compositor-rebuild
        // --session in the background.
        property bool rebuildExtension: false
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
        // always | desktop | fullscreen | never: "Automatically hide and show the menu bar" (BarHide.js).
        property string autoHide: "fullscreen"
        // Now Playing item of the bar (Settings > Desktop & Dock > Menu Bar): shown while a player has a session.
        property bool showNowPlaying: true
        // Search item (magnifier) of the bar.
        property bool showSearch: true
    }

    component AccentConfig: JsonObject {
        // multicolor | blue | purple | pink | red | orange | yellow | green | graphite (Settings > Appearance > Accent colour).
        property string color: "multicolor"
    }

    component IconsConfig: JsonObject {
        // default | dark | clear | tinted (ADR-0014): app and file icons only.
        property string mode: "default"
        // "accent" or a #rrggbb colour for the tinted mode.
        property string tint: "accent"
        // "theme" (the icon theme's own folder colour), "accent" or a #rrggbb colour: every folder icon.
        property string folderColor: "theme"
    }

    component PointerConfig: JsonObject {
        // Cursor size in pixels, 24 to 96 (Settings > Accessibility > Pointer). A var, not an int: an int property
        // would turn 51.5 or "64" into a valid size before PointerSize.fromStored could refuse them.
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
        property bool dnd: false
        // always | unlocked | never (ADR-0004). "never" hides bodies; "unlocked" equals "always" until the lock screen exists.
        property string previews: "unlocked"
        // Per-app overrides [{app, previews}] (NotificationPrefs.js).
        property var appPreviews: []
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

    // The adapter keeps the old value of a key that is no longer in the file (a reload only assigns the keys it finds), so
    // a pointer key deleted by hand (or by a reset elsewhere) would leave the old size or colour active while the Settings
    // app shows the default. A missing key is the default: put it back after each load (unsaved local changes go on top
    // again in reapplyDirty). A file that cannot be parsed is left alone.
    function resetMissingPointerKeys(text: string): void {
        let parsed = null;
        try {
            parsed = text.trim() === "" ? {} : JSON.parse(text);
        } catch (e) {
            return;
        }
        if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
            return;
        const pointer = parsed.pointer !== null && typeof parsed.pointer === "object" && !Array.isArray(parsed.pointer) ? parsed.pointer : {};
        if (!("size" in pointer))
            config.pointer.size = PointerSize.DEFAULT;
        if (!("outlineColor" in pointer))
            config.pointer.outlineColor = PointerColors.DEFAULT_OUTLINE;
        if (!("fillColor" in pointer))
            config.pointer.fillColor = PointerColors.DEFAULT_FILL;
        // And for the per-app previews list.
        const notif = parsed.notifications !== null && typeof parsed.notifications === "object" && !Array.isArray(parsed.notifications) ? parsed.notifications : {};
        if (!("appPreviews" in notif))
            config.notifications.appPreviews = [];
        // Same for the wallpaper group (ADR-0016): removing a key, or the whole object, reads as the defaults.
        const wp = parsed.wallpaper !== null && typeof parsed.wallpaper === "object" && !Array.isArray(parsed.wallpaper) ? parsed.wallpaper : {};
        const d = WallpaperConfig.WALLPAPER_DEFAULTS;
        if (!("source" in wp))
            config.wallpaper.source = d.source;
        if (!("path" in wp))
            config.wallpaper.path = d.path;
        if (!("color" in wp))
            config.wallpaper.color = d.color;
        if (!("fit" in wp))
            config.wallpaper.fit = d.fit;
        if (!("interval" in wp))
            config.wallpaper.interval = d.interval;
        if (!("shuffle" in wp))
            config.wallpaper.shuffle = d.shuffle;
        if (!("videoOnBattery" in wp))
            config.wallpaper.videoOnBattery = d.videoOnBattery;
        if (!("online" in wp))
            config.wallpaper.online = {provider: d.online.provider};
        if (!("outputs" in wp))
            config.wallpaper.outputs = [];
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
            root.resetMissingPointerKeys(file.text());
            root.reapplyDirty();
            root.loadedFile();
        }
    }
}
