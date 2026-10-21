import QtQuick
import Quickshell
import Quickshell.Io
import qs.store

// WatchedDir: the path changes while its mkdir runs (tests/shell/watched_dir_race.sh makes mkdir slow). `ready` must not
// come on the end of the first mkdir: when it does, the directory of the current path must exist.
ShellRoot {
    id: root

    readonly property string base: Quickshell.env("GF_BASE")
    property bool readySeen: false

    WatchedDir {
        id: dir
        path: root.base + "/a"
        onReadyChanged: {
            if (!ready)
                return;
            root.readySeen = true;
            check.command = ["sh", "-c", "test -d \"$1\"", "sh", dir.path];
            check.running = true;
        }
    }

    Process {
        id: check
        onExited: code => {
            console.log(code === 0 ? "watched-dir: PASS ready for " + dir.path : "watched-dir: FAIL ready before the directory of " + dir.path + " exists");
            Qt.quit();
        }
    }

    Timer {
        interval: 300
        running: true
        onTriggered: dir.path = root.base + "/b"
    }

    Timer {
        interval: 8000
        running: true
        onTriggered: {
            console.log("watched-dir: FAIL ready never came (seen=" + root.readySeen + ")");
            Qt.quit();
        }
    }
}
