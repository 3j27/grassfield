pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.services

// tests/shell/startup_settle.sh: the REAL Settings service. EXPECT_FILE=no: grassfield.json does not exist, `loaded` must still
// flip (the defaults are final). EXPECT_FILE=yes: the file has dock.folders ["/tmp/settle-x"] and dock.pinned ["foot"]; at the moment
// `loaded` flips (what a reader that settles on it sees) the values must already be the document's, not the defaults.
// Prints "startup-settle: PASS" or the failures.
ShellRoot {
    id: root

    readonly property bool wantFile: Quickshell.env("EXPECT_FILE") === "yes"
    property var seen: null
    property bool done: false

    Connections {
        target: Settings

        function onLoadedChanged(): void {
            if (Settings.loaded && root.seen === null)
                root.seen = {folders: JSON.stringify(Settings.dockFolders), pinned: JSON.stringify(Settings.dockPinned)};
        }
    }

    Timer {
        interval: 100
        running: true
        repeat: true
        property int ticks: 0
        onTriggered: {
            ticks++;
            if (root.done || (root.seen === null && ticks < 80))
                return;
            root.done = true;
            const fails = [];
            if (root.seen === null)
                fails.push("loaded never became true (" + (root.wantFile ? "with" : "without") + " a file)");
            else if (root.wantFile) {
                if (root.seen.folders !== JSON.stringify(["/tmp/settle-x"]))
                    fails.push("dock.folders at the flip of loaded: " + root.seen.folders);
                if (root.seen.pinned !== JSON.stringify(["foot"]))
                    fails.push("dock.pinned at the flip of loaded: " + root.seen.pinned);
            }
            console.info(fails.length === 0 ? "startup-settle: PASS" : "startup-settle: FAIL " + fails.join("; "));
            Qt.quit();
        }
    }
}
