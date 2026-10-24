pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.I18n
import Grassfield.Ui

// The one way an icon or picture the shell does not own reaches an Image: named by a notification, the polkit sheet, a
// desktop entry, an application, a tray item (StatusNotifierItem) or a file (Notifications, AuthAgent, the Dock, the
// Launchpad, the desktop, Search, the Switcher, the Overview, Stages, Force Quit, About, the menu bar's tray, media art,
// the lock screen's account picture). Integrator decisions after the reviews of 5ee6240 and 423766f: Qt never reads a
// user-writable icon file, and the shell only ever decodes images it produced itself.
//  - Qt's theme and fallback search paths hold only directories the user can neither write nor replace (Grassfield.I18n,
//    ui/i18n/iconsearchpaths.h, applied when that module is imported, before any binding; imported here too so no
//    lookup can come first). A plain theme name is looked up there (Quickshell.hasThemeIcon on the GUI thread reads only
//    root-owned theme files) and shown by its image://icon URL.
//  - Everything else is shown as a PNG the shell made: a name found only in the user's icon folders (a user-installed
//    application, a flatpak user export), an absolute Icon= path, a tray icon from the app's own IconThemePath, a
//    desktop picture's thumbnail, a stack preview, a media art file, the account picture. services/image-copy.py (python3
//    -I, a process of its own, never the GUI thread) finds the file (a plain lookup: theme directory x size folder x
//    apps|status|mimetypes|places|devices x png|svg, hicolor first, then pixmaps; no index.theme), opens it safely
//    (real path under an allowed root, O_NOFOLLOW|O_NONBLOCK, fstat: a regular file within the size cap) and re-encodes
//    it with rsvg-convert, fed on stdin (no base URL: no reference to another file is ever followed), into
//    $XDG_RUNTIME_DIR/grassfield-icons-<display>/<n>.png (0700, emptied at start, maxCopyBytes in all, the least
//    recently used copies deleted to make room). The Image loads only that PNG, asynchronously. Anything else (refused,
//    not made yet): the caller's generic icon.
// The copy directory belongs to the user, like every file of the session: a process of the same user can replace a copy,
// as it could the shell's own QML. The copies protect against what applications NAME (a path, a theme file, a FIFO, an
// SVG with references), not against code already running as the user.
// A copy is made once per run (a new notification naming the icon, or a new media art, makes a new one); until then, and
// when refused, the fallback shows. A helper that hangs is stopped (TERM, then KILL) and its keys refused.
Singleton {
    id: root

    readonly property real maxIconBytes: 8 * 1024 * 1024
    // A picture's source file (a photo may be big); its copy is at most 256 x 256 pixels like any other.
    readonly property real maxPictureBytes: 16 * 1024 * 1024
    // All copies together; past it, the least recently used are deleted to make room.
    readonly property real maxCopyBytes: 128 * 1024 * 1024
    // Past this many keys the least recently used quarter is forgotten (and its copies deleted).
    readonly property int maxKeys: 4096
    readonly property int batchSize: 24
    readonly property string helperPath: Quickshell.shellPath("services/image-copy.py")
    // One directory per Wayland display: a nested dev shell never empties the real session's.
    readonly property string copyDir: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR");
        const display = String(Quickshell.env("WAYLAND_DISPLAY") || "none").replace(/[^A-Za-z0-9._-]/g, "_");
        return runtime ? runtime + "/grassfield-icons-" + display : "";
    }
    property bool copyDirReady: false
    // Key ("name:<theme name>", "icon:<path>", "picture:<path>", "tray:<name>|<IconThemePath>") -> {state: "pending" |
    // "ok" | "no", url, file}; reassigned on every change so bindings that asked re-evaluate.
    property var copies: ({})
    // The least-recently-used order: at[key] is the value of `tick` at the key's last use. Mutated in place, never
    // reassigned: a use (a binding asking) notifies nobody.
    readonly property var lru: ({tick: 0, at: {}})
    property var queue: []
    property var batch: []
    // Copies replaced by a newer one or forgotten, deleted by the next helper run.
    property var dropped: []
    property int counter: 0
    property var activeRun: null

    // An absolute icon path (Icon=/path, file:///path) as a plain path, or "": no control character, at most 4096 characters.
    function plainIconPath(icon: string): string {
        let path = String(icon || "");
        if (path.toLowerCase().startsWith("file://")) {
            try {
                path = decodeURIComponent(path.slice(7));
            } catch (e) {
                return "";
            }
        }
        return path.startsWith("/") && path.length <= 4096 && !/[\u0000-\u001f\u007f]/.test(path) ? path : "";
    }

    // The image URL for theme icon `name`: the system theme's (only root-owned directories are searched), else the copy
    // of the user's icon of that name (a copy is requested; "" until it exists or when there is none).
    function source(name: string): string {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "")
            return "";
        if (Quickshell.hasThemeIcon(safe))
            return Quickshell.iconPath(safe);
        return copyOf("name", safe);
    }

    // The copy of picture file `icon` (an absolute path or file: URL), "" until it exists or when refused.
    function fileSource(icon: string): string {
        const path = plainIconPath(icon);
        return path !== "" ? copyOf("picture", path) : "";
    }

    // "pending", "ok" or "no" for picture file `icon` (fileSource's), "" when never asked.
    function fileState(icon: string): string {
        const entry = copies["picture:" + plainIconPath(icon)];
        return entry === undefined ? "" : entry.state;
    }

    // Picture file `icon` may have new content (a player reuses its art file): a new copy is made, the old one shown
    // until then.
    function refreshFile(icon: string): void {
        const path = plainIconPath(icon);
        if (path !== "")
            request("picture", path, true);
    }

    // An icon from a desktop entry, an application or a file (Icon=: a theme name or an absolute path), as
    // Quickshell.iconPath(icon, fallback) gave it: the system theme's icon or the copy of the user's; until then, and when
    // there is none or it is refused, the fallback theme icon.
    function appIcon(icon: string, fallback: string): string {
        const value = String(icon || "");
        const path = plainIconPath(value);
        const own = path !== "" ? copyOf("icon", path) : (value !== "" ? source(value) : "");
        return own !== "" ? own : (fallback !== "" ? source(fallback) : "");
    }

    // A tray item's icon (Quickshell's SystemTrayItem.icon). Quickshell would resolve an app's IconThemePath and a
    // path-like IconName itself, reading whatever file they name (review of 423766f): only its pixmap images
    // (image://qspixmap/, the IconPixmap pixels the app sent) pass as they are. From image://icon/<name>[?path=<dir>]
    // only a plain theme name is kept: the system theme's icon, else a copy made by the helper from the app's own folder
    // (a user-writable directory like any other), then from the user's icon folders. Anything else: "" (no icon).
    function trayIcon(icon: string): string {
        const value = String(icon || "");
        if (value.startsWith("image://qspixmap/"))
            return value;
        if (!value.startsWith("image://icon/"))
            return "";
        const rest = value.slice(13);
        const q = rest.indexOf("?");
        const raw = q < 0 ? rest : rest.slice(0, q);
        const name = NotificationPrefs.safeIconName(raw);
        if (name === "" || name !== raw)
            return "";
        if (Quickshell.hasThemeIcon(name))
            return Quickshell.iconPath(name);
        const query = q < 0 ? "" : rest.slice(q + 1);
        const dir = query.startsWith("path=") ? query.slice(5).replace(/&fallback=.*$/, "") : "";
        if (dir !== "" && plainIconPath(dir) === dir)
            return copyOf("tray", name + "|" + dir);
        return copyOf("name", name);
    }

    // A new notification names `name`: a user icon of that name is copied again (it may have changed); the current copy
    // shows until then.
    function check(name: string, fresh: bool): void {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "" || Quickshell.hasThemeIcon(safe))
            return;
        request("name", safe, fresh);
    }

    function copyOf(kind: string, value: string): string {
        const key = kind + ":" + value;
        const entry = copies[key];
        if (entry === undefined) {
            Qt.callLater(root.request, kind, value, false);
            return "";
        }
        if (entry.state !== "ok")
            return "";
        lru.tick++;
        lru.at[key] = lru.tick;
        return entry.url;
    }

    function request(kind: string, value: string, fresh: bool): void {
        const key = kind + ":" + value;
        if (copyDir === "" || queue.some(q => q.key === key) || batch.some(q => q.key === key))
            return;
        const entry = copies[key];
        if (!fresh && entry !== undefined)
            return;
        counter++;
        queue = queue.concat([{key: key, kind: kind, value: value, n: counter}]);
        // A copy already made stays shown until its replacement is made (or refused): done() drops it then.
        if (entry === undefined || entry.state !== "ok") {
            const next = Object.assign({}, copies);
            next[key] = {state: "pending", url: "", file: ""};
            copies = Object.keys(next).length > maxKeys ? forget(next) : next;
        }
        run();
    }

    // Past maxKeys keys: the least recently used quarter of the settled keys is forgotten, their copies deleted by the
    // next run (a key asked again is copied again).
    function forget(map: var): var {
        const settled = Object.keys(map).filter(k => map[k].state !== "pending");
        settled.sort((a, b) => (lru.at[a] || 0) - (lru.at[b] || 0));
        const files = [];
        for (const key of settled.slice(0, Math.ceil(maxKeys / 4))) {
            if (map[key].file)
                files.push(map[key].file);
            delete map[key];
            delete lru.at[key];
        }
        dropped = dropped.concat(files);
        return map;
    }

    // The copies the helper may delete to make room, least recently used first.
    function evictable(): var {
        const keys = Object.keys(copies).filter(k => copies[k].state === "ok" && copies[k].file);
        keys.sort((a, b) => (lru.at[a] || 0) - (lru.at[b] || 0));
        return keys.map(k => copies[k].file);
    }

    // One helper run at a time, each its own Process with its batch (Process.running turns true only once started, so two
    // starts in one turn would otherwise both run and the first batch's answer be lost).
    function run(): void {
        if (activeRun !== null || !copyDirReady || queue.length === 0)
            return;
        batch = queue.slice(0, batchSize);
        queue = queue.slice(batchSize);
        const args = [];
        for (const file of dropped)
            args.push("drop", "0", file);
        dropped = [];
        for (const file of evictable())
            args.push("lru", "0", file);
        for (const q of batch)
            args.push(q.kind, String(q.n), q.value);
        const proc = helperRun.createObject(root, {
            keys: batch.map(q => q.key),
            command: ["timeout", "-k", "2", "30", "setpriv", "--pdeathsig", "KILL", "--", "python3", "-I", helperPath, "batch", copyDir,
                String(maxIconBytes), String(maxPictureBytes), String(maxCopyBytes)].concat(args)
        });
        activeRun = proc;
        watchdog.restart();
        proc.running = true;
    }

    // A run's answer; one abandoned by the watchdog is dropped (its keys were already refused).
    function runFinished(proc: var, output: string): void {
        if (proc !== activeRun) {
            proc.destroy();
            return;
        }
        activeRun = null;
        watchdog.stop();
        done(proc.keys, output);
        proc.destroy();
    }

    // "ok<TAB><key><TAB><copy>" for each copy made, "gone<TAB><file>" for each copy deleted to make room; a key with no
    // "ok" line is refused.
    function done(keys: var, output: string): void {
        const said = {};
        const gone = {};
        for (const line of String(output || "").split("\n")) {
            const f = line.split("\t");
            if (f[0] === "ok" && f.length === 3 && f[2].startsWith(copyDir + "/") && /^[0-9]+\.png$/.test(f[2].slice(copyDir.length + 1)))
                said[f[1]] = f[2];
            else if (f[0] === "gone" && f.length === 2)
                gone[f[1]] = true;
        }
        const next = Object.assign({}, copies);
        for (const key in next) {
            if (next[key].file && gone[next[key].file]) {
                delete next[key];
                delete lru.at[key];
            }
        }
        for (const key of keys) {
            const file = said[key];
            if (next[key] !== undefined && next[key].file)
                dropped = dropped.concat([next[key].file]);
            if (file !== undefined) {
                next[key] = {state: "ok", url: "file://" + file.split("/").map(encodeURIComponent).join("/"), file: file.slice(copyDir.length + 1)};
            } else {
                next[key] = {state: "no", url: "", file: ""};
                console.info("grassfield-icons: no usable image for a " + key.slice(0, key.indexOf(":")) + " request (none found, not a regular file within its size cap, or not an image rsvg-convert could re-encode)");
            }
        }
        batch = [];
        copies = next;
        Qt.callLater(run);
    }

    Component {
        id: helperRun

        Process {
            id: proc
            property var keys: []
            stdout: StdioCollector {
                onStreamFinished: root.runFinished(proc, text)
            }
        }
    }

    // A run that does not answer within its own timeout (30 s, KILL 2 s later) is stopped: TERM, then KILL 2 s later (the
    // helper dies with it: --pdeathsig; rsvg-convert, in timeout's process group, too, and it has its own CPU limit), and
    // its keys are refused.
    Timer {
        id: watchdog
        interval: 40000
        onTriggered: {
            const proc = root.activeRun;
            if (proc === null)
                return;
            root.activeRun = null;
            proc.signal(15);
            killer.proc = proc;
            killer.restart();
            root.done(proc.keys, "");
        }
    }

    Timer {
        id: killer
        property var proc: null
        interval: 2000
        onTriggered: {
            if (proc !== null && proc.running)
                proc.signal(9);
            proc = null;
        }
    }

    // Empties (and creates, 0700) the private copy directory once at start; copies wait for it.
    Process {
        running: root.copyDir !== ""
        command: ["sh", "-c", "case $1 in /*/grassfield-icons-*) ;; *) exit 1 ;; esac; rm -rf -- \"$1\" && mkdir -m 700 -- \"$1\"", "gf-icons-prepare", root.copyDir]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.copyDirReady = code === 0;
            if (code !== 0)
                console.warn("grassfield-icons: the private icon directory could not be prepared; user icons are not shown");
            root.run();
        }
    }
}
