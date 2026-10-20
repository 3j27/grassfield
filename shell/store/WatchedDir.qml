pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io

// A directory that exists before anything inside it is watched. Quickshell's FileView watches a path through inotify
// and cannot watch inside a directory that does not exist when its path is set: on a fresh account the file created
// later (grassfield.json, folder-styles.json, state files) would never be noticed. Every FileView with watchChanges
// under ~/.config/grassfield or ~/.local/state/grassfield takes its path from this helper:
//
//   WatchedDir { id: dir; path: root.configDir }
//   FileView { path: dir.ready ? dir.path + "/x.json" : ""; watchChanges: true; ... }
//
// `ready` is true once `mkdir -p` has finished (a failed mkdir, for example a read-only home, still lets the watch be
// tried) and goes false while a changed path is being created.
QtObject {
    id: root

    property string path: ""
    readonly property bool ready: root.doneFor !== "" && root.doneFor === root.path

    // The path whose mkdir finished.
    property string doneFor: ""

    function ensure(): void {
        doneFor = "";
        if (path !== "") {
            mkdir.command = ["mkdir", "-p", root.path];
            mkdir.running = true;
        }
    }

    onPathChanged: ensure()
    Component.onCompleted: ensure()

    property Process mkdir: Process {
        onRunningChanged: {
            if (running || root.path === "")
                return;
            if (root.mkdir.command[2] === root.path)
                root.doneFor = root.path;
            else
                root.ensure(); // the path changed while the previous mkdir ran
        }
    }
}
