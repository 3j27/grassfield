pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.platform

// ADR-0035 D-2: ConfigErrors reads Hyprland's config errors at start and after each `configreloaded` event, once more when
// an event came during a read, and signals each new set and the end of the errors (tests/shell/config_errors.sh runs it
// against a fake Hyprland that sends the events). Prints "ce: <what>" lines, then "ce: done".
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("CE_DIR") ?? ""

    ConfigErrors {
        // The fake `hyprctl -j configerrors`: counts its runs, waits 0.5 s while the "slow" file exists, prints the answer.
        queryCommand: ["sh", "-c", "n=$(cat \"$1/reads\" 2>/dev/null || echo 0); echo $((n + 1)) >\"$1/reads\"; [ -e \"$1/slow\" ] && sleep 0.5; cat \"$1/answer\"", "sh", root.dir]
        onAppeared: (lines, more) => console.log("ce: appeared " + JSON.stringify(lines) + " " + more + " body " + JSON.stringify(noticeBody(lines, more > 0 ? "and " + more + " more" : "")))
        onCleared: console.log("ce: cleared")
    }

    Timer {
        interval: 9500
        running: true
        onTriggered: {
            console.log("ce: done");
            Qt.quit();
        }
    }
}
