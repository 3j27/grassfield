pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.desktop

// New Folder on the desktop when the listing lags behind the folder (real session 2026-10-22: "mkdir failed ...
// untitled folder: File exists"). Case 1: a folder named "untitled folder" is made by someone else just before New
// Folder, so the listing does not know it yet. Case 2: two New Folder in the same turn. Every New Folder must create a
// folder and never report a failure. Printed: "desktop-new-folder: PASS" or the failure.
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("GRASSFIELD_DESKTOP_DIR")
    property int step: 0
    property int failures: 0
    property int waited: 0

    DesktopFiles {
        id: files
        onNewFolderFailed: root.failures++
    }

    Process {
        id: external
        command: ["mkdir", root.dir + "/untitled folder"]
        onRunningChanged: {
            if (running)
                return;
            // The listing has not seen it yet: New Folder right away.
            files.newFolder();
            root.step = 2;
        }
    }

    Process {
        id: lister
        command: ["sh", "-c", 'cd "$1" && ls -1d */ | sed "s#/\\$##"', "sh", root.dir]
        stdout: StdioCollector {
            onStreamFinished: root.check(text.trim().split("\n").filter(n => n !== ""))
        }
    }

    function check(folders: var): void {
        const want = root.step === 3 ? 2 : 4;
        if (folders.length < want && waited < 40) {
            waited++;
            poll.restart();
            return;
        }
        if (root.failures > 0 || folders.length !== want) {
            console.log("desktop-new-folder: FAIL at case " + (root.step === 3 ? 1 : 2) + ": folders " + JSON.stringify(folders) + ", failures " + root.failures);
            Qt.exit(1);
            return;
        }
        if (root.step === 3) {
            console.log("desktop-new-folder: case 1 ok " + JSON.stringify(folders));
            root.step = 4;
            waited = 0;
            files.newFolder();
            files.newFolder();
            poll.restart();
            return;
        }
        console.log("desktop-new-folder: case 2 ok " + JSON.stringify(folders));
        console.log("desktop-new-folder: PASS");
        Qt.exit(0);
    }

    Timer {
        id: poll
        interval: 100
        onTriggered: lister.running = true
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            if (root.step === 0 && files.dir !== "") {
                root.step = 1;
                external.running = true;
            } else if (root.step === 2) {
                root.step = 3;
                poll.restart();
            }
        }
    }

    Timer {
        interval: 30000
        running: true
        onTriggered: {
            console.log("desktop-new-folder: FAIL (timeout at step " + root.step + ")");
            Qt.exit(1);
        }
    }
}
