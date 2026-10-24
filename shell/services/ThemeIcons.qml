pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// The one way a sender- or file-chosen icon reaches Qt's icon loader: a notification's app icon or themed image hint
// (Notifications.iconSource), the polkit sheet's action icon (AuthAgent), an application's or a file's Icon= (appIcon: the
// Dock, the Launchpad, the desktop, Search, the Switcher, the Overview, Force Quit, About). Reviews of 2dfd992, eee45cc and
// 100692f: Qt reads, for a theme name, the index.theme and icon-theme.cache of the theme and of every theme it inherits (on
// the GUI thread, in Quickshell.hasThemeIcon), then whichever icon file it picks (in the image loader, or on the GUI thread
// for a synchronous Image); a FIFO, a device or a huge file at any of those paths stalls the shell or the one image loader
// for good. Qt does not say which file it will read, so a helper process checks before a name or path is ever given to Qt
// (hasThemeIcon included; until then, and when refused, the caller shows its fallback):
//  - every icon theme directory the user owns or can write under the theme search paths Qt uses ($HOME/.icons,
//    XDG_DATA_HOME/icons, each XDG_DATA_DIRS entry's icons), dot-named ones included: its index.theme and
//    icon-theme.cache, when present, must be regular files of at most maxThemeFileBytes, and its index.theme may inherit
//    plain theme names only (Qt joins Inherits= to every search path, so "../" would leave them); any other result
//    refuses EVERY name, since Qt would read those files for any lookup;
//  - the candidate files for the name (and for the dash-shortened names Qt falls back to: a-b-c, a-b, a):
//    <folder>/<name>.png, .svg, .svgz and .xpm in EVERY folder of those user theme directories (symlinks followed), plus in
//    every folder an index.theme of theirs names in any form Qt 6.11 may use (every [section], Directories= and
//    ScaledDirectories= split on commas, quotes removed, and taken whole), in every directory of that theme, root-owned ones
//    included (a "../" section leads outside); and <dir>/<name>[.png|.svg|.svgz|.xpm] in the fallback (pixmaps) and
//    search-path roots the user owns or can write. Each one present must be a regular file (symlinks resolved; no FIFO,
//    device, socket, directory, dangling link or loop) of at most maxFileBytes, else the name is refused;
//  - an icon path (appIcon): a regular file of at most maxFileBytes, symlinks resolved, then loaded by a file: URL with
//    every segment encoded.
// The candidates of a whole batch are stat()ed in two calls; listing the folders reads every entry of the user's theme
// directories (about 0.4 s for a theme of 99k files, once per batch). Root-owned trees can only hold what root put there.
// A new check of a key (a new notification naming it) hides it ("pending") until its new verdict; a helper failure or
// timeout refuses (when in doubt, no). Re-checks without blanking the screen (review of 100692f): every
// signatureIntervalMs a signature (inode, mtime, size, type) of those folders, theme files, fallback directories and the
// folders holding the targets of symlinked candidates and icon paths is taken; when it changed, each shown key's own
// signature (its present candidates, lstat and resolved) is taken again in batches, and only the keys whose files
// changed are hidden and checked again; the others stay on screen. Defence in depth: whoever can plant such a file runs as
// the user already; a file swapped after its check can still be read until the next signature (at most
// signatureIntervalMs plus the re-check).
Singleton {
    id: root

    readonly property real maxFileBytes: 8 * 1024 * 1024
    readonly property real maxThemeFileBytes: 64 * 1024 * 1024
    readonly property int batchSize: 24
    // A test may lower it.
    property int signatureIntervalMs: 20000
    // Key (theme name or icon path) -> "pending" | "ok" | "no"; reassigned on every change so bindings that called source()
    // re-evaluate.
    property var verdicts: ({})
    // Key -> its own signature when it was found "ok".
    property var keySignatures: ({})
    // Folders whose change starts a re-check: those holding the targets of symlinked candidates and of icon paths.
    property var watchedFolders: []
    property var queue: []
    property var batch: []
    // Shown keys whose own signature is to be taken again (stage 2), and the batch doing it.
    property var revalidateQueue: []
    property var revalidateBatch: []
    // The last folder signature (stage 1; "" before the first).
    property string signature: ""
    // A user theme file (index.theme, icon-theme.cache, an Inherits= traversal) refuses every name.
    property bool themeFilesRefused: false
    // POSIX sh: the two size caps, the mode, then arguments (never interpolated):
    //   check <keys>: "sig <n>", "bad" when the user theme files refuse every name, "ok <key>" or "no <key>" per key,
    //                 "ksig <n> <key>" per key found ok, "dep <folder>" lines;
    //   ksig <keys>:  "sig <n>", maybe "bad", "ksig <n> <key>" per key;
    //   sig <folders>: "sig <n>" over the theme folders and files plus the given folders, maybe "bad".
    // A key without an "ok" line (the helper failed or timed out) is refused.
    readonly property string script: "cap=$1; tcap=$2; mode=$3; shift 3; set -f; names=; paths=\n"
        + "nl='\n"
        + "'\n"
        + "for n in \"$@\"; do case $n in /*\"$nl\"*) ;; /*) paths=\"$paths$nl$n\" ;; ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*|*..*) printf 'no %s\\n' \"$n\" ;; *) names=\"$names$nl$n\" ;; esac; done\n"
        + "mine() { [ -O \"$1\" ] || [ -w \"$1\" ]; }\n"
        + "okf() { if [ -e \"$1\" ] || [ -L \"$1\" ]; then [ -f \"$1\" ] && z=$(stat -L -c %s -- \"$1\" 2>/dev/null) && [ \"$z\" -le \"$2\" ]; fi; }\n"
        + "entries() { awk '/^[ \\t]*\\[.*\\][ \\t]*$/ { s = $0; sub(/^[ \\t]*\\[/, \"\", s); sub(/\\][ \\t]*$/, \"\", s); if (s != \"Icon Theme\") print s; next }\n"
        + "  /^[ \\t]*(Scaled)?Directories[ \\t]*=/ { v = $0; sub(/^[^=]*=[ \\t]*/, \"\", v); print v; w = v; gsub(/\"/, \"\", w); print w; n = split(w, a, \",\"); for (i = 1; i <= n; i++) { x = a[i]; gsub(/^[ \\t]+|[ \\t]+$/, \"\", x); print x } }'; }\n"
        + "dh=${XDG_DATA_HOME:-$HOME/.local/share}; sp=\"$HOME/.icons\"; fb=\"$dh/pixmaps$nl/usr/share/pixmaps\"\n"
        + "IFS=:; for d in $dh ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do [ -n \"$d\" ] && sp=\"$sp$nl$d/icons\" && fb=\"$fb$nl$d/pixmaps\"; done\n"
        + "IFS=$nl; themes=; set +f\n"
        + "for p in $sp; do [ -d \"$p\" ] || continue; for t in \"$p\"/* \"$p\"/.[!.]* \"$p\"/..?*; do [ -d \"$t\" ] && mine \"$t\" && themes=\"$themes$nl${t##*/}\"; done; done\n"
        + "set -f; themes=$(printf '%s\\n' $themes | sort -u); bad=; sig=\"$sp$nl$fb\"; cdirs=; fdirs=\n"
        + "for f in $fb $sp; do [ -d \"$f\" ] && mine \"$f\" && fdirs=\"$fdirs$nl$f\"; done\n"
        + "for t in $themes; do\n"
        + "  [ -n \"$t\" ] || continue\n"
        + "  for p in $sp; do\n"
        + "    c=$p/$t; [ -d \"$c\" ] && mine \"$c\" || continue\n"
        + "    okf \"$c/index.theme\" \"$tcap\" && okf \"$c/icon-theme.cache\" \"$tcap\" || bad=1\n"
        + "    sig=\"$sig$nl$c/index.theme$nl$c/icon-theme.cache\"\n"
        + "    subs=$(find -L \"$c\" -type d 2>/dev/null | head -n 20001)\n"
        + "    [ \"$(printf '%s\\n' \"$subs\" | grep -c .)\" -le 20000 ] || bad=1\n"
        + "    cdirs=\"$cdirs$nl$subs\"\n"
        + "    [ -z \"$bad\" ] && [ -f \"$c/index.theme\" ] || continue\n"
        + "    idx=$(timeout 3 head -c \"$tcap\" -- \"$c/index.theme\" 2>/dev/null)\n"
        + "    case $(printf '%s\\n' \"$idx\" | sed -n 's/^[[:space:]]*Inherits[[:space:]]*=//p') in */*) bad=1 ;; esac\n"
        + "    ent=$(printf '%s\\n' \"$idx\" | entries | grep -v '^$' | sort -u | head -n 4001)\n"
        + "    [ \"$(printf '%s\\n' \"$ent\" | grep -c .)\" -le 4000 ] || bad=1\n"
        + "    for q in $sp; do [ -d \"$q/$t\" ] || continue; for e in $ent; do [ -d \"$q/$t/$e\" ] && cdirs=\"$cdirs$nl$q/$t/$e\"; done; done\n"
        + "  done\n"
        + "done\n"
        + "cdirs=$(printf '%s\\n' $cdirs | grep -v '^$' | sort -u)\n"
        + "if [ \"$mode\" = sig ]; then for d in \"$@\"; do case $d in /*) sig=\"$sig$nl$d\" ;; esac; done; fi\n"
        + "set -- $(printf '%s\\n' $sig $cdirs $fdirs | sort -u)\n"
        + "s=$(stat -L -c '%n %i %Y %s %F' -- \"$@\" 2>/dev/null | cksum)\n"
        + "echo \"sig ${s%% *}\"\n"
        + "[ -z \"$bad\" ] || echo \"bad\"\n"
        + "[ \"$mode\" = sig ] && exit 0\n"
        + "t=$(mktemp -d \"${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/gf-icon-check.XXXXXX\") || exit 1\n"
        + "trap 'rm -rf \"$t\"' EXIT\n"
        + "# Candidates \"key<TAB>path\" for every theme name: <dir>/<name>.png|.svg|.svgz|.xpm in each folder, <dir>/<name>[...] in\n"
        + "# the fallback folders, for the name and every dash-shortened form (Qt falls back to them).\n"
        + "{ printf 'N\\t%s\\n' $names; printf 'C\\t%s\\n' $cdirs; printf 'F\\t%s\\n' $fdirs; } | awk -F'\\t' '$1 == \"N\" && $2 != \"\" { n[++nn] = $2; next }\n"
        + "  ($1 == \"C\" || $1 == \"F\") && substr($0, 3) != \"\" { k[++nd] = $1; d[nd] = substr($0, 3) }\n"
        + "  END { for (i = 1; i <= nn; i++) for (j = 1; j <= nd; j++) { w = n[i]\n"
        + "    while (w != \"\") { if (k[j] == \"F\") print n[i] \"\\t\" d[j] \"/\" w\n"
        + "      print n[i] \"\\t\" d[j] \"/\" w \".png\"; print n[i] \"\\t\" d[j] \"/\" w \".svg\"; print n[i] \"\\t\" d[j] \"/\" w \".svgz\"; print n[i] \"\\t\" d[j] \"/\" w \".xpm\"\n"
        + "      p = match(w, /-[^-]*$/); if (p) w = substr(w, 1, p - 1); else w = \"\" } } }' >\"$t/pairs\"\n"
        + "for q in $paths; do [ -n \"$q\" ] && printf '%s\\t%s\\n' \"$q\" \"$q\"; done >>\"$t/pairs\"\n"
        + "cut -f2- \"$t/pairs\" | sort -u >\"$t/cands\"\n"
        + "xargs -r -d '\\n' stat -c '%n|%F|%i|%Y|%s' -- <\"$t/cands\" >\"$t/ls\" 2>/dev/null\n"
        + "xargs -r -d '\\n' stat -L -c '%n|%F|%i|%Y|%s' -- <\"$t/cands\" >\"$t/lt\" 2>/dev/null\n"
        + "# Per key: \"R <present> <regular of bounded size> <key>\"; its stat lines go to k<index> (its signature).\n"
        + "awk -F'\\t' -v c=\"$cap\" -v dir=\"$t\" '\n"
        + "  function path(l) { sub(/\\|[^|]*\\|[^|]*\\|[^|]*\\|[^|]*$/, \"\", l); return l }\n"
        + "  FILENAME == dir \"/pairs\" { key = $1; p = substr($0, length($1) + 2); if (!(key in idx)) { idx[key] = ++nk; keys[nk] = key }\n"
        + "    owners[p] = owners[p] SUBSEP idx[key]; next }\n"
        + "  FILENAME == dir \"/ls\" { p = path($0); m = split(owners[p], o, SUBSEP); for (i = 2; i <= m; i++) { present[o[i]]++; print \"L \" $0 > (dir \"/k\" o[i]) } next }\n"
        + "  FILENAME == dir \"/lt\" { p = path($0); n = split($0, f, \"|\"); good = n >= 5 && f[n - 3] ~ /^regular/ && f[n] + 0 <= c + 0\n"
        + "    m = split(owners[p], o, SUBSEP); for (i = 2; i <= m; i++) { if (good) regular[o[i]]++; print \"T \" $0 > (dir \"/k\" o[i]) } next }\n"
        + "  END { for (i = 1; i <= nk; i++) printf \"R %d %d %d %s\\n\", i, present[i] + 0, regular[i] + 0, keys[i] }' \"$t/pairs\" \"$t/ls\" \"$t/lt\" >\"$t/r\"\n"
        + "while IFS=' ' read -r tag i a g key; do\n"
        + "  [ \"$tag\" = R ] || continue\n"
        + "  if [ \"$mode\" = check ]; then\n"
        + "    case $key in\n"
        + "      /*) [ \"$a\" -gt 0 ] && [ \"$a\" = \"$g\" ] || { printf 'no %s\\n' \"$key\"; continue; } ;;\n"
        + "      *) [ -z \"$bad\" ] && [ \"$a\" = \"$g\" ] || { printf 'no %s\\n' \"$key\"; continue; } ;;\n"
        + "    esac\n"
        + "    printf 'ok %s\\n' \"$key\"\n"
        + "  fi\n"
        + "  s=$(cat \"$t/k$i\" 2>/dev/null | sort | cksum)\n"
        + "  printf 'ksig %s %s\\n' \"${s%% *}\" \"$key\"\n"
        + "done <\"$t/r\"\n"
        + "# Folders whose change must trigger a new look (stage 1 of the signature): those holding the targets of symlinked\n"
        + "# candidates and of icon paths.\n"
        + "if [ \"$mode\" = check ]; then\n"
        + "  { awk -F'|' 'NF >= 5 && $(NF-3) == \"symbolic link\" { sub(/\\|[^|]*\\|[^|]*\\|[^|]*\\|[^|]*$/, \"\"); print }' \"$t/ls\" | xargs -r -d '\\n' readlink -f -- 2>/dev/null\n"
        + "    for q in $paths; do [ -n \"$q\" ] && printf '%s\\n' \"$q\"; done; } | sed -n 's|^\\(/.*\\)/[^/]*$|\\1|p' | sort -u | sed 's/^/dep /'\n"
        + "fi\n"

    // An absolute icon path (an application's Icon=/path, file:///path) as a plain path, or "": no control character, at
    // most 4096 characters.
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

    // The verdict key of a theme name or an icon path ("" when it is neither).
    function keyOf(icon: string): string {
        const path = plainIconPath(icon);
        return path !== "" ? path : NotificationPrefs.safeIconName(icon);
    }

    // The image URL for theme icon `name`, or "" (not a plain theme name: NotificationPrefs.safeIconName; not checked yet:
    // a check is requested; refused; or the theme lacks it, so Qt never paints a checkerboard). Quickshell.hasThemeIcon
    // (Qt reads the theme files on the GUI thread) runs only for a name whose files were checked.
    function source(name: string): string {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "")
            return "";
        const verdict = verdicts[safe];
        if (verdict === undefined) {
            Qt.callLater(root.check, safe, false);
            return "";
        }
        return verdict === "ok" && Quickshell.hasThemeIcon(safe) ? Quickshell.iconPath(safe) : "";
    }

    // The file: URL of icon file `icon` (an absolute path or file: URL), every segment encoded, once it was found to be a
    // regular file of at most maxFileBytes; else "" (not a path, not checked yet: a check is requested, or refused).
    function fileSource(icon: string): string {
        const path = plainIconPath(icon);
        if (path === "")
            return "";
        const verdict = verdicts[path];
        if (verdict === undefined) {
            Qt.callLater(root.check, path, false);
            return "";
        }
        return verdict === "ok" ? "file://" + path.split("/").map(encodeURIComponent).join("/") : "";
    }

    // An icon from a desktop entry, an application or a file (Icon=: a theme name or an absolute path), as
    // Quickshell.iconPath(icon, fallback) gave it, but only once checked (review of eee45cc: a FIFO Icon= stalled the image
    // loader; of 100692f: a synchronous Image froze the shell). Until the icon's verdict, and when it is refused or missing,
    // the (checked) fallback theme icon; "" while that is not checked either.
    function appIcon(icon: string, fallback: string): string {
        const value = String(icon || "");
        const own = plainIconPath(value) !== "" ? fileSource(value) : (value !== "" ? source(value) : "");
        return own !== "" ? own : (fallback !== "" ? source(fallback) : "");
    }

    // Asks for a check of `name` (a theme name or an icon path); `fresh`: also when it has a verdict (a new notification
    // naming it, or its files changed). It is then "pending" (nothing shown) until the new verdict: a file swapped in after
    // the last check never reaches Qt (review of eee45cc).
    function check(name: string, fresh: bool): void {
        const key = keyOf(name);
        if (key === "" || queue.indexOf(key) >= 0 || batch.indexOf(key) >= 0)
            return;
        if (!fresh && verdicts[key] !== undefined)
            return;
        queue = queue.concat([key]);
        if (verdicts[key] !== "pending") {
            const next = Object.assign({}, verdicts);
            next[key] = "pending";
            verdicts = next;
        }
        run();
    }

    // One helper at a time: check batches first, then re-check batches. Each run is its own Process carrying its mode and
    // keys, and `activeRun` says one is under way: Process.running only turns true once the process has started, so two
    // calls in one turn would otherwise both start a batch, and the first batch's answer was lost (its keys stayed
    // "pending" for good).
    function run(): void {
        if (activeRun !== null)
            return;
        if (queue.length > 0) {
            batch = queue.slice(0, batchSize);
            queue = queue.slice(batchSize);
            startRun("check", batch);
        } else if (revalidateQueue.length > 0) {
            revalidateBatch = revalidateQueue.slice(0, batchSize);
            revalidateQueue = revalidateQueue.slice(batchSize);
            startRun("ksig", revalidateBatch);
        }
    }

    function startRun(mode: string, keys: var): void {
        const proc = helperRun.createObject(root, {mode: mode, keys: keys, command: helper(mode, keys)});
        activeRun = proc;
        watchdog.restart();
        proc.running = true;
    }

    // A run's answer; one abandoned by the watchdog is dropped (its keys were already refused or queued again).
    function runFinished(proc: var, output: string): void {
        if (proc !== activeRun) {
            proc.destroy();
            return;
        }
        activeRun = null;
        watchdog.stop();
        finish(proc.mode, output);
        proc.destroy();
    }

    function finish(mode: string, output: string): void {
        if (mode === "check")
            done(output);
        else if (mode === "ksig")
            revalidated(output);
        else
            signatureDone(output);
    }

    function helper(mode: string, args: var): var {
        return ["timeout", "-k", "2", "30", "sh", "-c", script, "gf-icon-check", String(maxFileBytes), String(maxThemeFileBytes), mode].concat(args);
    }

    // "<word> <rest>" lines of the helper's output: {rest: second word} for "ksig <n> <key>", {key: word} for "ok|no <key>".
    function linesOf(output: string, pattern: var): var {
        const out = {};
        for (const line of String(output || "").split("\n")) {
            const m = pattern.exec(line);
            if (m)
                out[m[2]] = m[1];
        }
        return out;
    }

    function done(output: string): void {
        const failed = !/^sig [0-9]+$/m.test(String(output || ""));
        const said = linesOf(output, /^(ok|no) (.+)$/);
        const sigs = linesOf(output, /^ksig ([0-9]+) (.+)$/);
        const next = Object.keys(verdicts).length > 4096 ? {} : Object.assign({}, verdicts);
        const nextSigs = Object.assign({}, keySignatures);
        for (const key of batch) {
            const ok = !failed && said[key] === "ok" && sigs[key] !== undefined;
            next[key] = ok ? "ok" : "no";
            if (ok) {
                nextSigs[key] = sigs[key];
            } else {
                delete nextSigs[key];
                console.info("grassfield-icons: icon \"" + key + "\" refused: a file Qt could read for it is not a regular file of bounded size (or the check failed)");
            }
        }
        const folders = watchedFolders.slice();
        for (const line of String(output || "").split("\n")) {
            if (line.startsWith("dep /") && folders.indexOf(line.slice(4)) < 0 && folders.length < 1024)
                folders.push(line.slice(4));
        }
        watchedFolders = folders;
        batch = [];
        settleThemeFiles(/^bad$/m.test(String(output || "")), next, nextSigs);
        Qt.callLater(run);
    }

    // The user theme files refuse every name (Qt would read them for any lookup): names are refused at once; once they
    // are fine again, refused names are checked again when next shown.
    function settleThemeFiles(bad: bool, next: var, nextSigs: var): void {
        for (const key in next) {
            if (key.startsWith("/"))
                continue;
            if (bad && next[key] !== "no") {
                next[key] = "no";
                delete nextSigs[key];
            } else if (!bad && themeFilesRefused && next[key] === "no") {
                delete next[key];
            }
        }
        if (bad && !themeFilesRefused)
            console.warn("grassfield-icons: a user icon theme file is not a regular file of bounded size (or inherits a path); theme icons are refused");
        themeFilesRefused = bad;
        keySignatures = nextSigs;
        verdicts = next;
    }

    // Stage 2: a shown key whose own signature changed (or got no answer) is hidden and checked again; the others stay.
    function revalidated(output: string): void {
        const sigs = linesOf(output, /^ksig ([0-9]+) (.+)$/);
        const changed = revalidateBatch.filter(key => verdicts[key] === "ok" && sigs[key] !== keySignatures[key]);
        revalidateBatch = [];
        const next = Object.assign({}, verdicts);
        const nextSigs = Object.assign({}, keySignatures);
        for (const key of changed) {
            console.info("grassfield-icons: the files of icon \"" + key + "\" changed; checked again");
            next[key] = "pending";
            delete nextSigs[key];
            if (queue.indexOf(key) < 0)
                queue = queue.concat([key]);
        }
        settleThemeFiles(/^bad$/m.test(String(output || "")), next, nextSigs);
        Qt.callLater(run);
    }

    // Stage 1: a changed folder signature (or a failed one) queues every shown key for stage 2.
    function signatureDone(output: string): void {
        const m = /^sig ([0-9]+)$/m.exec(String(output || ""));
        const sig = m ? m[1] : "";
        const next = Object.assign({}, verdicts);
        const nextSigs = Object.assign({}, keySignatures);
        settleThemeFiles(/^bad$/m.test(String(output || "")), next, nextSigs);
        if (sig === "" || sig !== signature) {
            signature = sig;
            const shown = Object.keys(verdicts).filter(key => verdicts[key] === "ok" && revalidateQueue.indexOf(key) < 0);
            revalidateQueue = revalidateQueue.concat(shown);
        }
        Qt.callLater(run);
    }

    property var activeRun: null

    Component {
        id: helperRun

        Process {
            id: proc
            property string mode: ""
            property var keys: []
            stdout: StdioCollector {
                onStreamFinished: root.runFinished(proc, text)
            }
        }
    }

    // A run that never answers (it cannot even start) is stopped and counts as a failure: its keys are refused or queued
    // again, and the next run starts. Longer than the helper's own `timeout` (30 s, then KILL 2 s later).
    Timer {
        id: watchdog
        interval: 40000
        onTriggered: {
            const proc = root.activeRun;
            if (proc === null)
                return;
            root.activeRun = null;
            proc.running = false;
            root.finish(proc.mode, "");
        }
    }

    Timer {
        interval: root.signatureIntervalMs
        repeat: true
        running: Object.keys(root.keySignatures).length > 0 || root.themeFilesRefused
        onTriggered: {
            if (root.activeRun !== null || root.queue.length > 0 || root.revalidateQueue.length > 0)
                return;
            root.startRun("sig", root.watchedFolders.slice());
        }
    }
}
