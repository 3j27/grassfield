pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.desktop

// The real DesktopFiles with the unit environment and a fresh account: $XDG_CONFIG_HOME/grassfield does not exist when
// the shell starts. folder-styles.json is then written the way Files writes it (create the directory, a file next to
// the target renamed over it) and DesktopFiles.folderStore must show the style within the budget; a second write must
// apply too. Printed: "folder-styles-apply: PASS" or the failure.
ShellRoot {
    id: root

    readonly property int budgetMs: 1500
    readonly property string dir: Quickshell.env("XDG_CONFIG_HOME") + "/grassfield"
    property int step: 0
    property int waited: 0
    property bool failed: false

    DesktopFiles {
        id: files
    }

    function body(color: string): string {
        return JSON.stringify({
            "version": 1,
            "serial": 1,
            "folders": {
                "/x/folder": {
                    "color": color
                }
            }
        });
    }

    function write(color: string): void {
        waited = 0;
        writer.command = ["sh", "-c", 'mkdir -p "$1" && printf "%s\\n" "$2" > "$1/folder-styles.json.tmp" && mv "$1/folder-styles.json.tmp" "$1/folder-styles.json"', "sh", root.dir, root.body(color)];
        writer.running = true;
    }

    function shown(): string {
        const s = files.folderStore["/x/folder"];
        return s ? s.color : "";
    }

    Component.onCompleted: {
        if (Quickshell.env("QS_DISABLE_FILE_WATCHER") !== "1" || Quickshell.env("GRASSFIELD_SESSION") !== "1" || Quickshell.env("GRASSFIELD_DEV") || Quickshell.env("GRASSFIELD_CONFIG_HOME")) {
            console.log("folder-styles-apply: FAIL env is not the unit's");
            Qt.exit(1);
        }
        startTimer.start();
    }

    Timer {
        id: startTimer
        interval: 800
        onTriggered: {
            root.step = 1;
            root.write("#ff0000");
        }
    }

    Process {
        id: writer
        onRunningChanged: {
            if (!running)
                poll.start();
        }
    }

    Timer {
        id: poll
        interval: 50
        repeat: true
        onTriggered: {
            root.waited += interval;
            const want = root.step === 1 ? "#ff0000" : "#00ff00";
            if (root.shown().toLowerCase() === want) {
                stop();
                if (root.step === 1) {
                    root.step = 2;
                    root.write("#00ff00");
                } else {
                    console.log("folder-styles-apply: PASS (both writes applied)");
                    Qt.exit(0);
                }
            } else if (root.waited >= root.budgetMs) {
                stop();
                console.log("folder-styles-apply: FAIL write " + root.step + " not applied in " + root.budgetMs + " ms (shows '" + root.shown() + "')");
                Qt.exit(1);
            }
        }
    }

    Timer {
        interval: 60000
        running: true
        onTriggered: {
            console.log("folder-styles-apply: FAIL timeout");
            Qt.exit(1);
        }
    }
}
