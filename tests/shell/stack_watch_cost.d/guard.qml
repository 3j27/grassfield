pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.dock

// Body of tests/shell/stack_watch_cost.sh: the real StackWatch on a big folder, served by the real grassfield-stack-helper
// (ADR-0025; GRASSFIELD_STACK_HELPER names it). GF_MODE says what happens after the first window:
//   creates  this process creates 10 files, one every 300 ms, and reports 1.2 s after the last;
//   wait     (idle, bursts, streams, refills) the test script does whatever it does from outside, and creates the file GF_DONE_FILE
//            when it is over; the report follows within a quarter second;
//   popup    as wait, and a second helper (the open popup: 300 entries) is started on the same folder one second after the first
//            window: "POPSTART <ms>", then "POP <ms> <count>" for each window it gives;
//   mem      as wait, for the memory gate: the folder of GF_STACK_DIR is small (the warm baseline: the shell and its helper have
//            run once), "BASE" is logged after a gc, then the folder of GF_BIG_DIR is shown (the pile and the popup, Kind order).
// The script samples the CPU and the memory of this process and its helper around that. A 5 ms timer measures how long the GUI
// thread was blocked (waits of more than 15 ms): "BLOCK max=<ms> total=<ms>". Every change of the pile is logged as
// "TOP <epoch ms> <names>" (the latency gates read them).
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("GF_STACK_DIR")
    readonly property string bigDir: Quickshell.env("GF_BIG_DIR")
    readonly property string mode: Quickshell.env("GF_MODE") || "creates"
    readonly property string doneFile: Quickshell.env("GF_DONE_FILE")
    readonly property string order: Quickshell.env("GF_SORT") || "dateAdded"
    property real last: 0
    property real maxGap: 0
    property real late: 0
    property bool ready: false
    property string popFolder: ""

    StackWatch {
        id: watch
        folder: root.dir
        sort: root.mode === "mem" ? "name" : root.order
        onNewestChanged: {
            console.log("TOP " + Date.now() + " " + newest.map(e => e.path.replace(/^.*\//, "")).join(","));
            if (newest.length > 0 && !root.ready) {
                root.ready = true;
                root.last = Date.now();
                console.log("READY");
            }
        }
    }

    // the open popup's own helper (K = Tokens.dockStackItemMax)
    StackHelper {
        id: pop
        folder: root.popFolder
        sort: root.order
        limit: Tokens.dockStackItemMax
        onArrived: if (loaded)
            console.log("POP " + Date.now() + " " + entries.length + " " + entries.slice(0, 3).map(e => e.name).join(","))
    }

    // The creates, the popup and the baseline start 1 s after the first window: the script samples the process at READY.
    Timer {
        interval: 1000
        running: root.ready
        onTriggered: {
            if (root.mode === "creates") {
                creator.running = true;
            } else if (root.mode === "popup") {
                console.log("POPSTART " + Date.now());
                root.popFolder = root.dir;
                poll.start();
            } else if (root.mode === "mem") {
                gc();
                console.log("BASE");
                switchBig.start();
            } else {
                poll.start();
            }
        }
    }

    Timer {
        id: switchBig
        interval: 500
        onTriggered: {
            watch.sort = root.order;
            watch.folder = root.bigDir;
            root.popFolder = root.bigDir;
            poll.start();
        }
    }

    // How late the GUI thread was: a tick that comes after more than 5 ms was waiting for something else to finish.
    Timer {
        interval: 5
        repeat: true
        running: root.ready
        onTriggered: {
            const now = Date.now();
            const gap = now - root.last - 5;
            root.last = now;
            // Only waits of more than 15 ms count: the small lateness of every tick is the load of the machine, not a blocked thread.
            if (gap > 15) {
                if (gap > 30)
                    console.log("WAIT " + Date.now() + " " + Math.round(gap));
                root.late += gap;
                if (gap > root.maxGap)
                    root.maxGap = gap;
            }
        }
    }

    Process {
        id: creator
        command: ["sh", "-c", "for i in 1 2 3 4 5 6 7 8 9 10; do printf x > \"$1/new$i\"; sleep 0.3; done", "sh", root.dir]
        onRunningChanged: if (!running)
            end.start()
    }

    // wait modes: look for the done file (the burst and the settle time are the script's)
    Timer {
        id: poll
        interval: 250
        repeat: true
        onTriggered: if (!check.running)
            check.running = true
    }

    Process {
        id: check
        command: ["sh", "-c", "test -e \"$1\" && echo done", "sh", root.doneFile]
        stdout: StdioCollector {
            onStreamFinished: if (text.indexOf("done") >= 0) {
                poll.stop();
                end.start();
            }
        }
    }

    Timer {
        id: end
        interval: root.mode === "creates" ? 1200 : 50
        onTriggered: {
            gc();
            console.log("COST top=" + watch.newest.map(e => e.path.replace(/^.*\//, "")).join(","));
            console.log("BLOCK max=" + Math.round(root.maxGap) + " total=" + Math.round(root.late));
            // stays alive a moment: the script samples the process and its helper now
            leave.start();
        }
    }

    Timer {
        id: leave
        interval: 1500
        onTriggered: Qt.exit(watch.newest.length === 3 ? 0 : 1)
    }
}
