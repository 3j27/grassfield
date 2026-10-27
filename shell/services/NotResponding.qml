pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import qs.platform
import "NotResponding.js" as Logic

// Apps that do not respond (ADR-0035 D-3, step 3; spec system-dialogs.md section 4). Hyprland runs `hyprland-dialog` when
// an app misses its pings; in the Grassfield session that is the stand-in packaging/session-bin/hyprland-dialog, which
// reports the app's process here (`anr report`) and then waits, silently, until Hyprland kills it (the app answered or
// closed). While it waits the app is marked: "(Not Responding)" in Force Quit, "Application Not Responding" in its Dock menu
// (the macOS model, owner decision Q2: no alert). The mark goes when the stand-in ends. The decisions are NotResponding.js.
Singleton {
    id: root

    // {standin, pid, cls, title}: one per stand-in that waits.
    property var marks: []
    // The compositor this shell belongs to: a report from another (a nested session's stand-in) is refused.
    readonly property string ownInstance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") ?? ""

    function isMarked(pid: int): bool {
        return Logic.isMarked(root.marks, pid);
    }

    function markedAmong(pids: var): var {
        return Logic.markedAmong(root.marks, pids);
    }

    // Force Quit, at the confirmation: the pid still owns a window of that class, or of one of those classes (it was not
    // reused in between).
    function stillOwns(pid: int, cls: var): bool {
        return Logic.stillOwns(Compositor.knownWindows(), pid, cls);
    }

    function initialIndex(rowPids: var): int {
        return Logic.initialIndex(rowPids, root.marks);
    }

    // The stand-ins that ended: their marks go (Hyprland killed them when the app answered or closed, or Force Quit
    // killed the app and Hyprland its dialog). Checked every 250 ms while there is a mark.
    Timer {
        interval: 250
        repeat: true
        running: root.marks.length > 0 && !alive.running
        onTriggered: {
            alive.command = ["sh", "-c", "for p; do kill -0 \"$p\" 2>/dev/null || echo \"$p\"; done", "sh"].concat(root.marks.map(m => String(m.standin)));
            alive.running = true;
        }
    }

    Process {
        id: alive
        stdout: StdioCollector {
            onStreamFinished: {
                const gone = text.split("\n").filter(s => s !== "").map(s => parseInt(s, 10));
                if (gone.length > 0)
                    root.marks = root.marks.filter(m => gone.indexOf(m.standin) < 0);
            }
        }
    }

    IpcHandler {
        target: "anr"

        // The stand-in's report (security.md "IPC surface": an action of packaging/session-bin/hyprland-dialog). It only
        // marks an app in the UI; nothing is killed without the user's Force Quit and its confirmation. "ok" or
        // "refused: <reason>" (the stand-in then runs the stock dialog).
        function report(standin: int, pid: int, cls: string, title: string, instance: string): string {
            const c = Logic.unprefix(cls, "c:");
            const t = Logic.unprefix(title, "t:");
            const i = Logic.unprefix(instance, "i:");
            const d = Logic.decide(standin, pid, c, t, i, root.ownInstance, Compositor.knownWindows());
            if (!d.ok)
                return "refused: " + d.reason;
            root.marks = Logic.withMark(root.marks, {
                standin: standin,
                pid: pid,
                cls: c,
                title: t
            });
            return "ok";
        }

        // Test hook: the marks (window titles: dev only).
        function status(): string {
            if (!Mode.dev)
                return Mode.refused;
            return Logic.statusJson(root.marks);
        }
    }
}
