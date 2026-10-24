pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// The one way a sender- or file-chosen icon THEME NAME reaches Qt's icon loader: a notification's app icon or themed image
// hint (Notifications.iconSource), the polkit sheet's action icon (AuthAgent), an application's Icon= (Dock, Launchpad).
// Reviews of 2dfd992 and eee45cc: Qt reads, for a name, its theme's index.theme and icon-theme.cache (on the GUI thread,
// in Quickshell.hasThemeIcon) and then whichever icon file it picks (in the image loader); a FIFO, a device or a huge file
// at any of those paths stalls the shell or the one image loader for good. Qt does not say which file it will read, so a
// helper process checks, before a name is ever given to Qt (hasThemeIcon included):
//  - in every icon theme directory the user owns or can write, under the theme search paths Qt uses ($HOME/.icons,
//    XDG_DATA_HOME/icons, each XDG_DATA_DIRS entry's icons): index.theme and icon-theme.cache, when present, are regular
//    files of at most maxThemeFileBytes; any other result refuses EVERY name (Qt would read them for any lookup);
//  - the candidate files Qt could open for the name: <dir>/<name>.png, .svg, .svgz and .xpm in each Directories= and
//    ScaledDirectories= entry of the theme's index.theme (the first one in search-path order, as Qt reads it), in each of
//    those user directories, and <dir>/<name>[.png|.svg|.svgz|.xpm] in the fallback directories (pixmaps) and search-path
//    roots the user owns or can write; also for the dash-shortened names Qt falls back to (a-b-c, a-b, a). Each one present
//    must be a regular file (symlinks resolved; no FIFO, device, socket, directory, dangling link or loop) of at most
//    maxFileBytes, else the name is refused.
// No recursive walk: the candidates are stat()ed in two batched calls per name, so a user theme of 100k files costs about
// 0.15 s per name. Root-owned trees can only hold what root put there and are not checked. Until a verdict the caller shows
// its generic icon; a new check of a name (a new notification naming it) hides it again until its new verdict; a helper
// failure or timeout refuses (when in doubt, no). Every signatureIntervalMs a signature of those directories and theme
// files (inode, mtime, size) is taken again: when it changed (a theme installed or switched, an icon added, a file swapped)
// every verdict is dropped and names are checked again when next shown. Defence in depth: whoever can plant such a file
// runs as the user already; a file swapped after its check is caught at the next signature, not before.
Singleton {
    id: root

    readonly property real maxFileBytes: 8 * 1024 * 1024
    readonly property real maxThemeFileBytes: 64 * 1024 * 1024
    readonly property int batchSize: 8
    // A test may lower it.
    property int signatureIntervalMs: 20000
    // Name -> "pending" | "ok" | "no"; reassigned on every change so bindings that called source() re-evaluate.
    property var verdicts: ({})
    property var queue: []
    property var batch: []
    // The signature the current verdicts were checked against ("" before the first check).
    property string signature: ""
    // POSIX sh: the two size caps, the mode ("check": a "sig <n>" line, then one "ok <name>" or "no <name>" line per name;
    // "sig": the signature line only), then the names as arguments (never interpolated). A name without a line (the helper
    // failed or timed out) is refused. The signature is taken before the verdicts, so a change during a check shows at the
    // next signature.
    readonly property string script: "cap=$1; tcap=$2; mode=$3; shift 3; set -f; names=\n"
        + "nl='\n"
        + "'\n"
        + "for n in \"$@\"; do case $n in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*|*..*) echo \"no $n\" ;; *) names=\"$names$nl$n\" ;; esac; done\n"
        + "mine() { [ -O \"$1\" ] || [ -w \"$1\" ]; }\n"
        + "okf() { if [ -e \"$1\" ] || [ -L \"$1\" ]; then [ -f \"$1\" ] && z=$(stat -L -c %s -- \"$1\" 2>/dev/null) && [ \"$z\" -le \"$2\" ]; fi; }\n"
        + "dh=${XDG_DATA_HOME:-$HOME/.local/share}; sp=\"$HOME/.icons\"; fb=\"$dh/pixmaps$nl/usr/share/pixmaps\"\n"
        + "IFS=:; for d in $dh ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do [ -n \"$d\" ] && sp=\"$sp$nl$d/icons\" && fb=\"$fb$nl$d/pixmaps\"; done\n"
        + "IFS=$nl; themes=; set +f\n"
        + "for p in $sp; do [ -d \"$p\" ] || continue; for t in \"$p\"/*; do [ -d \"$t\" ] && mine \"$t\" && themes=\"$themes$nl${t##*/}\"; done; done\n"
        + "set -f; themes=$(printf '%s\\n' $themes | sort -u); bad=; sig=\"$sp$nl$fb\"; cdirs=; fdirs=\n"
        + "for f in $fb $sp; do [ -d \"$f\" ] && mine \"$f\" && fdirs=\"$fdirs$nl$f\"; done\n"
        + "for t in $themes; do\n"
        + "  [ -n \"$t\" ] || continue; idx=\n"
        + "  for p in $sp; do\n"
        + "    c=$p/$t; [ -d \"$c\" ] || continue\n"
        + "    [ -z \"$idx\" ] && { [ -e \"$c/index.theme\" ] || [ -L \"$c/index.theme\" ]; } && idx=$c/index.theme\n"
        + "    mine \"$c\" || continue\n"
        + "    okf \"$c/index.theme\" \"$tcap\" && okf \"$c/icon-theme.cache\" \"$tcap\" || bad=1\n"
        + "    sig=\"$sig$nl$c$nl$c/index.theme$nl$c/icon-theme.cache\"\n"
        + "  done\n"
        + "  [ -n \"$idx\" ] || continue\n"
        + "  okf \"$idx\" \"$tcap\" || { bad=1; continue; }\n"
        + "  dirs=$(timeout 3 head -c \"$tcap\" -- \"$idx\" 2>/dev/null | sed -n 's/^[[:space:]]*\\(Scaled\\)\\{0,1\\}Directories[[:space:]]*=//p' | tr ',' '\\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -n 4001)\n"
        + "  [ \"$(printf '%s\\n' \"$dirs\" | grep -c .)\" -le 4000 ] || bad=1\n"
        + "  for p in $sp; do\n"
        + "    c=$p/$t; [ -d \"$c\" ] && mine \"$c\" || continue\n"
        + "    for d in $dirs; do\n"
        + "      [ -d \"$c/$d\" ] && cdirs=\"$cdirs$nl$c/$d\"\n"
        + "      [ -d \"$c/${d%%/*}\" ] && sig=\"$sig$nl$c/${d%%/*}\"\n"
        + "    done\n"
        + "  done\n"
        + "done\n"
        + "set -- $(printf '%s\\n' $sig $cdirs $fdirs | sort -u)\n"
        + "s=$(stat -L -c '%n %i %Y %s' -- \"$@\" 2>/dev/null | cksum)\n"
        + "echo \"sig ${s%% *}\"\n"
        + "[ \"$mode\" = check ] || exit 0\n"
        + "gen() { w=$1; k=0; while [ -n \"$w\" ] && [ \"$k\" -lt 6 ]; do for x in $cdirs; do for e in .png .svg .svgz .xpm; do printf '%s\\n' \"$x/$w$e\"; done; done\n"
        + "  for x in $fdirs; do for e in \"\" .png .svg .svgz .xpm; do printf '%s\\n' \"$x/$w$e\"; done; done; case $w in *-*) w=${w%-*} ;; *) w= ;; esac; k=$((k + 1)); done; }\n"
        + "for n in $names; do\n"
        + "  [ -n \"$n\" ] || continue\n"
        + "  if [ -n \"$bad\" ]; then echo \"no $n\"; continue; fi\n"
        + "  a=$(gen \"$n\" | xargs -r -d '\\n' stat -c %F -- 2>/dev/null | grep -c .)\n"
        + "  g=$(gen \"$n\" | xargs -r -d '\\n' stat -L -c '%F %s' -- 2>/dev/null | awk -v c=\"$cap\" '$1 == \"regular\" && $NF + 0 <= c + 0 { g++ } END { print g + 0 }')\n"
        + "  if [ \"$a\" = \"$g\" ]; then echo \"ok $n\"; else echo \"no $n\"; fi\n"
        + "done\n"

    // The image URL for theme icon `name`, or "" (not a plain theme name: NotificationPrefs.safeIconName; not checked yet:
    // a check is requested; refused; or the theme lacks it, so Qt never paints a checkerboard). Quickshell.hasThemeIcon
    // (Qt reads the theme's index.theme on the GUI thread) runs only for a name whose files were checked.
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

    // Asks for a check of `name`; `fresh`: also when it has a verdict (a new notification naming it). The name is then
    // "pending" (nothing shown) until the new verdict: a file swapped in after the last check never reaches Qt (review of
    // eee45cc).
    function check(name: string, fresh: bool): void {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "" || queue.indexOf(safe) >= 0 || batch.indexOf(safe) >= 0)
            return;
        if (!fresh && verdicts[safe] !== undefined)
            return;
        queue = queue.concat([safe]);
        if (verdicts[safe] !== "pending") {
            const next = Object.assign({}, verdicts);
            next[safe] = "pending";
            verdicts = next;
        }
        run();
    }

    function run(): void {
        if (checker.running || queue.length === 0)
            return;
        batch = queue.slice(0, batchSize);
        queue = queue.slice(batchSize);
        checker.command = ["timeout", "-k", "2", "20", "sh", "-c", script, "gf-icon-check", String(maxFileBytes), String(maxThemeFileBytes), "check"].concat(batch);
        checker.running = true;
    }

    function signatureOf(output: string): string {
        const m = /^sig ([0-9]+)$/m.exec(String(output || ""));
        return m ? m[1] : "";
    }

    function done(output: string): void {
        const said = {};
        for (const line of String(output || "").split("\n")) {
            const m = /^(ok|no) ([A-Za-z0-9._-]+)$/.exec(line);
            if (m)
                said[m[2]] = m[1];
        }
        const sig = signatureOf(output);
        // The directories changed since the other verdicts were taken (or this check failed): they go.
        const stale = sig === "" || (signature !== "" && sig !== signature) || Object.keys(verdicts).length > 512;
        const next = stale ? {} : Object.assign({}, verdicts);
        for (const name of batch) {
            next[name] = sig !== "" && said[name] === "ok" ? "ok" : "no";
            if (next[name] !== "ok")
                console.info("grassfield-icons: theme icon \"" + name + "\" refused: a file Qt could read for it is not a regular file of bounded size (or the check failed)");
        }
        if (stale && sig !== signature)
            console.info("grassfield-icons: icon directories changed; theme icons are checked again");
        signature = sig;
        batch = [];
        verdicts = next;
        Qt.callLater(run);
    }

    // A changed signature (or a failed one) drops every verdict: names are checked again when next shown.
    function signatureDone(output: string): void {
        const sig = signatureOf(output);
        if (signature !== "" && sig !== signature) {
            console.info("grassfield-icons: icon directories changed; theme icons are checked again");
            signature = "";
            verdicts = ({});
        }
    }

    Process {
        id: checker
        stdout: StdioCollector {
            onStreamFinished: root.done(text)
        }
    }

    Process {
        id: signatureCheck
        command: ["timeout", "-k", "2", "20", "sh", "-c", root.script, "gf-icon-check", String(root.maxFileBytes), String(root.maxThemeFileBytes), "sig"]
        stdout: StdioCollector {
            onStreamFinished: root.signatureDone(text)
        }
    }

    Timer {
        interval: root.signatureIntervalMs
        repeat: true
        running: root.signature !== ""
        onTriggered: {
            if (!signatureCheck.running && !checker.running)
                signatureCheck.running = true;
        }
    }
}
