pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui

// The one way a sender-chosen icon THEME NAME reaches an Image: a notification's app icon or themed image hint
// (Notifications.iconSource) and the polkit sheet's action icon (AuthAgent). Review of 2dfd992: a valid theme name still
// resolved to whatever file Qt found for it, and a FIFO there (~/.local/share/icons/<theme>/.../evil.png, ~/.icons, an
// XDG_DATA_DIRS entry's pixmaps, or a symlink to one, or to /dev/zero) stalled the one image loader for good; Qt does not
// say which file it will read. So before a name is shown, a helper process checks every file Qt could pick for it:
// <name>, <name>.png, .svg, .svgz and .xpm anywhere under the icon search paths (XDG_DATA_HOME, each XDG_DATA_DIRS entry:
// icons/ and pixmaps/; ~/.icons; /usr/share/pixmaps), symlinked directories followed. Each candidate must be a regular
// file (after resolving symlinks: no FIFO, device, socket, directory, dangling link or loop) of at most maxFileBytes, else
// the name is refused and the caller shows its generic icon. Only directories the user owns or can write are searched: a
// root-owned tree can only hold what root put there (and searching all of /usr/share/icons took 0.7 s). Until the verdict
// (well under a second) the generic icon shows; a helper failure or timeout refuses (when in doubt, no). Defence in depth:
// whoever can plant a file there runs as the user already, and a file swapped between the check and Qt's read is not
// caught (the check narrows that window to one check per name, re-run when a new notification names it).
Singleton {
    id: root

    readonly property real maxFileBytes: 8 * 1024 * 1024
    // Name -> "pending" | "ok" | "no"; reassigned on every change so bindings that called source() re-evaluate.
    property var verdicts: ({})
    property var queue: []
    property var batch: []
    // POSIX sh: the size cap, then the names as arguments (never interpolated). One line per name: "ok <name>" or
    // "no <name>"; a name without a line (the helper failed or timed out) is refused.
    readonly property string script: "cap=$1; shift; names=; set -f\n"
        + "for n in \"$@\"; do case $n in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*|*..*) echo \"no $n\" ;; *) names=\"$names $n\" ;; esac; done\n"
        + "[ -n \"$names\" ] || exit 0\n"
        + "command -v find >/dev/null && command -v stat >/dev/null || { for n in $names; do echo \"no $n\"; done; exit 0; }\n"
        + "dh=${XDG_DATA_HOME:-$HOME/.local/share}; set --; ifs=$IFS; IFS=:\n"
        + "for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do [ -n \"$d\" ] && set -- \"$@\" \"$d/icons\" \"$d/pixmaps\"; done\n"
        + "IFS=$ifs; set -- \"$@\" \"$HOME/.icons\" \"$dh/icons\" \"$dh/pixmaps\" /usr/share/pixmaps\n"
        + "for b do shift; [ -d \"$b\" ] && set -- \"$@\" \"$b\"; done\n"
        + "bad=\n"
        + "if [ $# -gt 0 ]; then\n"
        + "  set -- \"$@\" \"(\" -type d \"!\" -user \"$(id -u)\" \"!\" -writable -prune \")\" -o \"(\"\n"
        + "  for n in $names; do set -- \"$@\" -name \"$n\" -o -name \"$n.png\" -o -name \"$n.svg\" -o -name \"$n.svgz\" -o -name \"$n.xpm\" -o; done\n"
        + "  set -- \"$@\" -false \")\" -exec sh -c 'c=$1; shift; for f do if [ -f \"$f\" ] && s=$(stat -L -c %s -- \"$f\" 2>/dev/null) && [ \"$s\" -le \"$c\" ]; then :; else printf \"%s\\n\" \"${f##*/}\"; fi; done' gf-icon-file \"$cap\" \"{}\" +\n"
        + "  bad=$(find -L \"$@\" 2>/dev/null; find \"$@\" 2>/dev/null)\n"
        + "fi\n"
        + "for n in $names; do v=ok; for e in \"\" .png .svg .svgz .xpm; do case \"\n"
        + "$bad\n"
        + "\" in *\"\n"
        + "$n$e\n"
        + "\"*) v=no ;; esac; done; echo \"$v $n\"; done\n"

    // The image URL for theme icon `name`, or "" (not a plain theme name: NotificationPrefs.safeIconName; not checked yet:
    // a check is requested; refused; or the theme lacks it, so Qt never paints a checkerboard).
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

    // Asks for a check of `name`; `fresh`: also when it has a verdict (a new notification naming it), which stays in force
    // until the new one.
    function check(name: string, fresh: bool): void {
        const safe = NotificationPrefs.safeIconName(name);
        if (safe === "" || queue.indexOf(safe) >= 0 || batch.indexOf(safe) >= 0)
            return;
        if (!fresh && verdicts[safe] !== undefined)
            return;
        queue = queue.concat([safe]);
        if (verdicts[safe] === undefined) {
            const next = Object.assign({}, verdicts);
            next[safe] = "pending";
            verdicts = next;
        }
        run();
    }

    function run(): void {
        if (checker.running || queue.length === 0)
            return;
        batch = queue.slice(0, 32);
        queue = queue.slice(32);
        checker.command = ["timeout", "-k", "2", "20", "sh", "-c", script, "gf-icon-check", String(maxFileBytes)].concat(batch);
        checker.running = true;
    }

    function done(output: string): void {
        const said = {};
        for (const line of String(output || "").split("\n")) {
            const m = /^(ok|no) ([A-Za-z0-9._-]+)$/.exec(line);
            if (m)
                said[m[2]] = m[1];
        }
        const next = Object.keys(verdicts).length > 512 ? {} : Object.assign({}, verdicts);
        for (const name of batch) {
            next[name] = said[name] === "ok" ? "ok" : "no";
            if (next[name] !== "ok")
                console.info("grassfield-icons: theme icon \"" + name + "\" refused: a file Qt could read for it is not a regular file of at most " + maxFileBytes + " bytes (or the check failed)");
        }
        batch = [];
        verdicts = next;
        Qt.callLater(run);
    }

    Process {
        id: checker
        stdout: StdioCollector {
            onStreamFinished: root.done(text)
        }
    }
}
