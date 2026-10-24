pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.notifications
import qs.services

// Probe of tests/security/theme_icon_files.sh (reviews of 2dfd992 and eee45cc). The script planted files for the theme
// icon name "evil" (PROBE_KIND says which) and a regular icon "ctl" in a scratch XDG_DATA_DIRS entry's pixmaps. As a
// notification would, it takes "evil" in as an app icon, waits for ThemeIcons' verdict, gives the notification's icon
// source and the polkit sheet's (ThemeIcons.source, AuthAgent's call) to Images, then loads "ctl": that Image only becomes
// Ready when the one image loader never stalled. Two kinds start from a regular evil.png that is shown, then replace it
// with a FIFO:
//   swap    a new notification names "evil" at once: the name is hidden ("pending") from that moment, then refused;
//   change  nothing names it again: the next signature (lowered to 1 s here) sees the folder change, the name's own
//           files changed, so it alone is checked again and refused; "ctl", checked before, stays shown throughout;
//   linkswap evil.png is a symlink to a file outside every icon folder; that target is replaced by a FIFO: the signature
//           covers the target's folder, so the name is refused too, "ctl" again staying shown.
// Prints one "probe:" line and exits.
ShellRoot {
    id: root

    readonly property string kind: Quickshell.env("PROBE_KIND")
    readonly property string pixmaps: Quickshell.env("PROBE_PIXMAPS")
    property string phase: "verdict"
    property int waited: 0
    property string verdict: ""
    property string notifSource: ""
    property string polkitSource: ""
    property string before: ""
    property string atSwap: ""
    // "ctl" left "ok" at some point after the swap (it must not: its files did not change).
    property bool ctlBlanked: false

    Component.onCompleted: {
        ThemeIcons.signatureIntervalMs = 1000;
        Notifications.checkedAppIcon("evil", "Probe");
        ThemeIcons.check("ctl", false);
        poll.start();
    }

    Process {
        id: swapper
        command: ["sh", "-c", "if [ -L \"$1/evil.png\" ]; then t=$(readlink \"$1/evil.png\"); rm -f \"$t\" && mkfifo \"$t\"; else rm -f \"$1/evil.png\" && mkfifo \"$1/evil.png\"; fi", "sh", root.pixmaps]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            if (root.kind === "swap") {
                Notifications.checkedAppIcon("evil", "Probe"); // a new notification naming it
                root.atSwap = Notifications.iconSource("", "evil") + "|" + ThemeIcons.verdicts["evil"];
            }
            root.phase = "verdict";
            root.waited = 0;
            poll.start();
        }
    }

    FloatingWindow {
        visible: true
        implicitWidth: 96
        implicitHeight: 32

        Image {
            id: viaNotification
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(256, 256)
        }

        Image {
            id: viaPolkit
            x: 32
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(128, 128)
        }

        Image {
            id: control
            x: 64
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(64, 64)
        }
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === "verdict") {
                // As a binding would, ask again: after a dropped verdict this requests the new check.
                Notifications.iconSource("", "evil");
                const v = ThemeIcons.verdicts["evil"];
                const watching = root.before !== "" && (root.kind === "change" || root.kind === "linkswap");
                if (watching && ThemeIcons.verdicts["ctl"] !== "ok")
                    root.ctlBlanked = true;
                const waiting = v === undefined || v === "pending" || (watching && v === "ok") || (!watching && ThemeIcons.verdicts["ctl"] !== "ok" && root.before === "" && (root.kind === "change" || root.kind === "linkswap"));
                if (waiting && root.waited < 10000)
                    return;
                if ((root.kind === "swap" || root.kind === "change" || root.kind === "linkswap") && root.before === "") {
                    // First round on the regular file: shown; then the swap.
                    root.before = String(v) + ":" + Notifications.iconSource("", "evil");
                    stop();
                    swapper.running = true;
                    return;
                }
                root.verdict = String(v);
                root.notifSource = Notifications.iconSource("", "evil");
                root.polkitSource = ThemeIcons.source("evil");
                viaNotification.source = root.notifSource;
                viaPolkit.source = root.polkitSource;
                ThemeIcons.check("ctl", false);
                root.phase = "control";
                root.waited = 0;
            } else if (root.phase === "control") {
                // At least a second after "evil" was handed to the loader, so a stalled read has started.
                const c = ThemeIcons.source("ctl");
                if ((c === "" || root.waited < 1000) && root.waited < 10000)
                    return;
                control.source = c;
                root.phase = "loaded";
                root.waited = 0;
            } else if (root.phase === "loaded") {
                if (control.status !== Image.Ready && root.waited < 5000)
                    return;
                stop();
                console.log("probe: kind=" + root.kind + " before=" + root.before + " atswap=" + root.atSwap + " ctlblanked=" + root.ctlBlanked + " verdict=" + root.verdict + " notif=" + root.notifSource
                    + " polkit=" + root.polkitSource + " evil=" + viaNotification.status + " ctl=" + control.status);
                Qt.exit(0);
            }
        }
    }
}
