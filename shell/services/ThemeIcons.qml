pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.I18n
import Grassfield.Ui

// The one way an icon named by a notification, the polkit sheet, a desktop entry, an application or a file reaches an
// Image (Notifications, AuthAgent, the Dock, the Launchpad, the desktop, Search, the Switcher, the Overview, Force Quit,
// About). Integrator decision after the review of 5ee6240 (mirroring Qt's index.theme parser to check what it would read
// proved endless): Qt never reads a user-writable icon file.
//  - Qt's theme and fallback search paths hold only directories the user can neither write nor replace (Grassfield.I18n,
//    ui/i18n/iconsearchpaths.h, applied when that module is imported, before any binding; imported here too so no
//    lookup can come first). A theme name is looked up there (Quickshell.hasThemeIcon on the GUI thread reads only
//    root-owned theme files) and shown by its image://icon URL.
//  - A name found only in the user's icon directories (a user-installed application, a flatpak user export), an absolute
//    Icon= path and a desktop picture's thumbnail are shown as private copies: a helper process (python3, off the GUI
//    thread) finds the name with a plain lookup (each theme directory x size folder x apps|mimetypes|places x png|svg,
//    hicolor first, then pixmaps; no index.theme), opens each candidate with O_NOFOLLOW|O_NONBLOCK, accepts it only when
//    fstat says a regular, non-empty file within the size cap (an SVG also without external references or entities),
//    and copies it into $XDG_RUNTIME_DIR/grassfield-icons-<display> (0700, emptied at start, maxCopyBytes in all). The
//    Image loads only that copy, asynchronously. Anything else: the caller's generic icon.
// A copy is made once per run (a new notification naming the icon makes a new one); until then, and when refused, the
// fallback shows. A helper that hangs is stopped (TERM, then KILL) and its keys refused.
Singleton {
    id: root

    readonly property real maxIconBytes: 8 * 1024 * 1024
    // A desktop picture's thumbnail (a photo may be big).
    readonly property real maxPictureBytes: 16 * 1024 * 1024
    // All private copies together; past it, new ones are refused (the generic icon), none is evicted.
    readonly property real maxCopyBytes: 128 * 1024 * 1024
    readonly property int batchSize: 24
    // One directory per Wayland display: a nested dev shell never empties the real session's.
    readonly property string copyDir: {
        const runtime = Quickshell.env("XDG_RUNTIME_DIR");
        const display = String(Quickshell.env("WAYLAND_DISPLAY") || "none").replace(/[^A-Za-z0-9._-]/g, "_");
        return runtime ? runtime + "/grassfield-icons-" + display : "";
    }
    property bool copyDirReady: false
    // Key ("name:<theme name>", "icon:<path>", "picture:<path>") -> {state: "pending" | "ok" | "no", url, file}; reassigned on
    // every change so bindings that asked re-evaluate.
    property var copies: ({})
    property var queue: []
    property var batch: []
    // Copies replaced by a newer one, deleted by the next helper run.
    property var dropped: []
    property int counter: 0
    property var activeRun: null
    // POSIX-free: python3 -I -c <script> <dir> <icon cap> <picture cap> <total cap> then "<kind> <n> <value>" triples and
    // "drop 0 <file>" (never interpolated). One line per triple: "ok<TAB><key><TAB><copy path>" or "no<TAB><key>".
    readonly property string script: "import os, re, stat, sys\n"
        + "out, iconcap, piccap, budget = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])\n"
        + "args = sys.argv[5:]\n"
        + "home = os.environ.get(\"HOME\", \"\")\n"
        + "data_home = os.environ.get(\"XDG_DATA_HOME\") or os.path.join(home, \".local/share\")\n"
        + "data_dirs = [d for d in (os.environ.get(\"XDG_DATA_DIRS\") or \"/usr/local/share:/usr/share\").split(\":\") if d]\n"
        + "sizes = [\"scalable\", \"512x512\", \"256x256\", \"192x192\", \"128x128\", \"96x96\", \"72x72\", \"64x64\", \"48x48\", \"36x36\", \"32x32\", \"24x24\", \"22x22\", \"16x16\"]\n"
        + "kinds = [\"apps\", \"mimetypes\", \"places\"]\n"
        + "svg_bad = re.compile(rb\"<!ENTITY|<!DOCTYPE[^>]*\\[|@import|url\\(\\s*[\\\"']?\\s*(?!#)|href\\s*=\\s*[\\\"']\\s*(?!#|data:)\", re.I)\n"
        + "\n"
        + "def mapped_root():\n"
        + "    try:\n"
        + "        if open(\"/proc/self/uid_map\").read().split()[:2] == [\"0\", \"0\"]:\n"
        + "            return -1\n"
        + "        return int(open(\"/proc/sys/kernel/overflowuid\").read())\n"
        + "    except (OSError, ValueError):\n"
        + "        return -1\n"
        + "\n"
        + "ROOT = mapped_root()\n"
        + "\n"
        + "# The rule of iconsearchpaths.h: Qt searches a directory only when it and every ancestor belong to root and the user can\n"
        + "# neither own nor write them; every other existing icon directory is the user's, looked up here.\n"
        + "def user_changeable(path):\n"
        + "    p = os.path.realpath(path)\n"
        + "    if not os.path.isdir(p):\n"
        + "        return False\n"
        + "    while True:\n"
        + "        try:\n"
        + "            st = os.stat(p)\n"
        + "        except OSError:\n"
        + "            return True\n"
        + "        if st.st_uid not in (0, ROOT) or st.st_uid == os.geteuid() or os.access(p, os.W_OK):\n"
        + "            return True\n"
        + "        if p == \"/\":\n"
        + "            return False\n"
        + "        p = os.path.dirname(p)\n"
        + "\n"
        + "# Icon directories Qt no longer searches (iconsearchpaths.h): the user's own, and user-changeable data dirs.\n"
        + "bases = [b for b in [os.path.join(home, \".icons\"), os.path.join(data_home, \"icons\")] + [os.path.join(d, \"icons\") for d in data_dirs] if user_changeable(b)]\n"
        + "pixmaps = [p for p in [os.path.join(data_home, \"pixmaps\")] + [os.path.join(d, \"pixmaps\") for d in data_dirs] if user_changeable(p)]\n"
        + "\n"
        + "def candidates(name):\n"
        + "    for base in bases:\n"
        + "        try:\n"
        + "            themes = sorted(e.name for e in os.scandir(base) if e.is_dir())[:64]\n"
        + "        except OSError:\n"
        + "            continue\n"
        + "        themes = [\"hicolor\"] + [t for t in themes if t != \"hicolor\"]\n"
        + "        for theme in themes:\n"
        + "            for size in sizes:\n"
        + "                for kind in kinds:\n"
        + "                    for ext in (\"png\", \"svg\"):\n"
        + "                        yield os.path.join(base, theme, size, kind, name + \".\" + ext)\n"
        + "    for d in pixmaps:\n"
        + "        for ext in (\"png\", \"svg\"):\n"
        + "            yield os.path.join(d, name + \".\" + ext)\n"
        + "\n"
        + "def used():\n"
        + "    total = 0\n"
        + "    for e in os.scandir(out):\n"
        + "        try:\n"
        + "            total += e.stat(follow_symlinks=False).st_size\n"
        + "        except OSError:\n"
        + "            pass\n"
        + "    return total\n"
        + "\n"
        + "def copy(src, n, cap):\n"
        + "    try:\n"
        + "        st = os.lstat(src)\n"
        + "    except OSError:\n"
        + "        return None\n"
        + "    if not stat.S_ISREG(st.st_mode):\n"
        + "        return None\n"
        + "    try:\n"
        + "        fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)\n"
        + "    except OSError:\n"
        + "        return None\n"
        + "    try:\n"
        + "        st = os.fstat(fd)\n"
        + "        if not stat.S_ISREG(st.st_mode) or st.st_size > cap or st.st_size == 0:\n"
        + "            return None\n"
        + "        chunks, left = [], st.st_size\n"
        + "        while left > 0:\n"
        + "            b = os.read(fd, min(left, 1 << 20))\n"
        + "            if not b:\n"
        + "                break\n"
        + "            chunks.append(b)\n"
        + "            left -= len(b)\n"
        + "        data = b\"\".join(chunks)\n"
        + "    finally:\n"
        + "        os.close(fd)\n"
        + "    ext = os.path.splitext(src)[1].lower().lstrip(\".\")\n"
        + "    if not re.fullmatch(r\"[a-z0-9]{1,5}\", ext):\n"
        + "        ext = \"img\"\n"
        + "    if (ext == \"svg\" or data.lstrip()[:5].lower() in (b\"<?xml\", b\"<svg \", b\"<svg>\")) and svg_bad.search(data):\n"
        + "        return None\n"
        + "    if used() + len(data) > budget:\n"
        + "        return None\n"
        + "    dst = os.path.join(out, \"%d.%s\" % (n, ext))\n"
        + "    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)\n"
        + "    try:\n"
        + "        os.write(fd, data)\n"
        + "    finally:\n"
        + "        os.close(fd)\n"
        + "    return dst\n"
        + "\n"
        + "if not os.path.isdir(out) or os.path.islink(out):\n"
        + "    sys.exit(1)\n"
        + "i = 0\n"
        + "while i + 3 <= len(args):\n"
        + "    kind, n, value = args[i], args[i + 1], args[i + 2]\n"
        + "    i += 3\n"
        + "    if kind == \"drop\":\n"
        + "        if re.fullmatch(r\"[0-9]+\\.[a-z0-9]{1,5}\", value):\n"
        + "            try:\n"
        + "                os.unlink(os.path.join(out, value))\n"
        + "            except OSError:\n"
        + "                pass\n"
        + "        continue\n"
        + "    key = kind + \":\" + value\n"
        + "    path = None\n"
        + "    try:\n"
        + "        if kind == \"name\" and re.fullmatch(r\"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\", value) and \"..\" not in value:\n"
        + "            for c in candidates(value):\n"
        + "                path = copy(c, int(n), iconcap)\n"
        + "                if path:\n"
        + "                    break\n"
        + "        elif kind in (\"icon\", \"picture\") and value.startswith(\"/\") and \"\\n\" not in value:\n"
        + "            path = copy(value, int(n), iconcap if kind == \"icon\" else piccap)\n"
        + "    except Exception:\n"
        + "        path = None\n"
        + "    print((\"ok\\t%s\\t%s\" % (key, path)) if path else (\"no\\t%s\" % key), flush=True)\n"

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

    // The image URL for theme icon `name`: the system theme's (only root-owned directories are searched), else the private
    // copy of the user's icon of that name (a copy is requested; "" until it exists or when there is none).
    function source(name: string): string {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "")
            return "";
        if (Quickshell.hasThemeIcon(safe))
            return Quickshell.iconPath(safe);
        return copyOf("name", safe);
    }

    // The private copy of icon file `icon` (an absolute path or file: URL), "" until it exists or when refused.
    function fileSource(icon: string): string {
        const path = plainIconPath(icon);
        return path !== "" ? copyOf("picture", path) : "";
    }

    // An icon from a desktop entry, an application or a file (Icon=: a theme name or an absolute path), as
    // Quickshell.iconPath(icon, fallback) gave it: the system theme's icon or the private copy of the user's; until then,
    // and when there is none or it is refused, the fallback theme icon.
    function appIcon(icon: string, fallback: string): string {
        const value = String(icon || "");
        const path = plainIconPath(value);
        const own = path !== "" ? copyOf("icon", path) : (value !== "" ? source(value) : "");
        return own !== "" ? own : (fallback !== "" ? source(fallback) : "");
    }

    // A new notification names `name`: a user icon of that name is copied again (it may have changed), hidden until then.
    function check(name: string, fresh: bool): void {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "" || Quickshell.hasThemeIcon(safe))
            return;
        request("name", safe, fresh);
    }

    function copyOf(kind: string, value: string): string {
        const entry = copies[kind + ":" + value];
        if (entry === undefined) {
            Qt.callLater(root.request, kind, value, false);
            return "";
        }
        return entry.state === "ok" ? entry.url : "";
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
        const next = Object.keys(copies).length > 4096 ? {} : Object.assign({}, copies);
        if (entry !== undefined && entry.file)
            dropped = dropped.concat([entry.file]);
        next[key] = {state: "pending", url: "", file: ""};
        copies = next;
        run();
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
        for (const q of batch)
            args.push(q.kind, String(q.n), q.value);
        const proc = helperRun.createObject(root, {
            keys: batch.map(q => q.key),
            command: ["timeout", "-k", "2", "30", "setpriv", "--pdeathsig", "KILL", "--", "python3", "-I", "-c", script, copyDir,
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

    function done(keys: var, output: string): void {
        const said = {};
        for (const line of String(output || "").split("\n")) {
            const f = line.split("\t");
            if (f[0] === "ok" && f.length === 3 && f[2].startsWith(copyDir + "/"))
                said[f[1]] = f[2];
        }
        const next = Object.assign({}, copies);
        for (const key of keys) {
            const file = said[key];
            if (file !== undefined) {
                next[key] = {state: "ok", url: "file://" + file.split("/").map(encodeURIComponent).join("/"), file: file.slice(copyDir.length + 1)};
            } else {
                next[key] = {state: "no", url: "", file: ""};
                console.info("grassfield-icons: no usable icon for \"" + key + "\" (none in the user's icon folders, or not a regular file within its size cap)");
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
    // helper dies with it: --pdeathsig), and its keys are refused.
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
