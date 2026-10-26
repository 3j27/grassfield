pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.dock

// Body of tests/shell/stack_watch.sh: the real StackWatch (what the pile on a stack tile reads) on a folder with files f1..f4
// (f4 the newest), served by the real grassfield-stack-helper (ADR-0025; GRASSFIELD_STACK_HELPER names it). It follows the folder, uses the
// stack's own order (the same as the popup), follows a burst while it lasts, and sees a file appended to as modified.
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("GF_STACK_DIR")
    property var failures: []
    property int step: -1

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function names(): string {
        return watch.newest.map(e => e.path.replace(/^.*\//, "")).join(",");
    }

    StackWatch {
        id: watch
        folder: root.dir
        sort: "dateModified"
    }

    // [shell command run in the folder ($1), pause ms after it, check]
    readonly property var steps: [
        {
            cmd: ":",
            wait: 1200,
            check: () => {
                root.check("the newest three, newest first, not the oldest (Date Modified): " + root.names(), root.names() === "f4,f3,f2");
                root.check("inotify delivers the changes", watch.watching);
            }
        },
        {
            cmd: "printf x > \"$1/newest.txt\"; touch -d '2026-06-01' \"$1/newest.txt\"",
            wait: 1700,
            check: () => root.check("a new file is the top of the pile: " + root.names(), root.names().startsWith("newest.txt,") && watch.newest.length === 3)
        },
        {
            cmd: "printf more >> \"$1/f1\"",
            wait: 1700,
            check: () => root.check("a file appended to moves up with Date Modified: " + root.names(), root.names().startsWith("f1,"))
        },
        {
            cmd: "rm -f \"$1/newest.txt\"",
            wait: 1700,
            check: () => root.check("a removed file leaves the pile: " + root.names(), root.names().indexOf("newest.txt") < 0)
        },
        {
            // creates every 150 ms for 2.4 s: no quiet moment ever comes, the pile still follows to the last file
            cmd: "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do printf x > \"$1/burst$i\"; sleep 0.15; done",
            wait: 700,
            check: () => root.check("a burst is followed to its last file: " + root.names(), root.names().startsWith("burst16,"))
        },
        {
            // the repro of the review: an old file moved in, an old-dated file added: Name and Date Added order
            cmd: "printf x > \"$1/Aardvark.txt\"; touch -d '2021-01-01' \"$1/Aardvark.txt\"; sleep 0.3; printf x > \"$1/old.pdf\"; touch -d '2020-01-01' \"$1/old.pdf\"",
            wait: 1700,
            check: () => {
                watch.sort = "name";
            }
        },
        {
            cmd: ":",
            wait: 1700,
            check: () => {
                root.check("Name: A to Z, the same as the popup: " + root.names(), root.names() === "Aardvark.txt,burst1,burst2");
                watch.sort = "dateAdded";
            }
        },
        {
            cmd: ":",
            wait: 1700,
            check: () => root.check("Date Added: the file that came last is on top (the inode change time), not the newest modification: " + root.names(), root.names().startsWith("old.pdf,"))
        },
        {
            // the folder is deleted and made again: the helper arms the watch again (it looks again after 2 s) and the pile follows
            cmd: "rm -rf \"$1\"; sleep 0.5; mkdir \"$1\"; printf x > \"$1/reborn1\"",
            wait: 3500,
            check: () => {
                root.check("a folder deleted and made again is watched again: " + root.names(), root.names() === "reborn1" && watch.watching);
            }
        },
        {
            cmd: "printf x > \"$1/reborn2\"",
            wait: 1700,
            check: () => root.check("and its changes are followed: " + root.names(), root.names().startsWith("reborn2,"))
        },
        {
            // a symbolic link as the stack folder is followed (the old Qt version did)
            cmd: "ln -s \"$1\" \"$1.link\"",
            wait: 300,
            check: () => {
                watch.folder = root.dir + ".link";
            }
        },
        {
            cmd: ":",
            wait: 1200,
            check: () => {
                root.check("a symlinked stack folder gives a pile: " + root.names(), root.names().indexOf("reborn") >= 0);
                watch.folder = root.dir;
                watch.sort = "dateModified";
            }
        },
        {
            // a name with a line break and a fake line in it must not empty the pile or forge a window
            cmd: "printf x > \"$1/$(printf 'x\\nG')\"",
            wait: 2500,
            check: () => root.check("a name with a line break does not empty the pile: " + root.names(), watch.newest.length >= 2 && watch.watching)
        },
        {
            // a name that is not UTF-8 is not lost: it shows as the popup and Files show it (U+FFFD for the bad byte)
            cmd: "printf x > \"$1/$(printf 'caf\\351.txt')\"",
            wait: 3000,
            check: () => root.check("a name that is not valid UTF-8 shows in the pile: " + root.names(), root.names().indexOf("caf\ufffd.txt") >= 0 && watch.watching)
        },
        {
            // a subfolder whose own date changes re-sorts (Date Modified): created, then made old again
            cmd: "mkdir \"$1/subd\"",
            wait: 1700,
            check: () => root.check("a new subfolder is on top: " + root.names(), root.names().startsWith("subd,"))
        },
        {
            cmd: "touch -d '2000-01-01' \"$1/subd\"",
            wait: 1700,
            check: () => root.check("a subfolder whose date went back leaves the top: " + root.names(), !root.names().startsWith("subd,"))
        },
        {
            // changing the folder in place moves the watch with it
            cmd: "mkdir -p \"$1.2\"; printf x > \"$1.2/other1\"",
            wait: 300,
            check: () => {
                watch.folder = root.dir + ".2";
            }
        },
        {
            cmd: ":",
            wait: 1500,
            check: () => root.check("the other folder is shown: " + root.names(), root.names() === "other1")
        },
        {
            cmd: "printf x > \"$1.2/other2\"; printf x > \"$1/not-this-one\"",
            wait: 1200,
            check: () => root.check("and only its changes are followed: " + root.names(), root.names().startsWith("other2,") && root.names().indexOf("not-this-one") < 0)
        },
        {
            // an unreadable folder: told once as gone, retried with a growing pause, watched when it becomes readable
            cmd: "mkdir -p \"$1.3\"; printf x > \"$1.3/secret1\"; chmod 000 \"$1.3\"",
            wait: 300,
            check: () => {
                watch.folder = root.dir + ".3";
            }
        },
        {
            cmd: ":",
            wait: 1500,
            check: () => root.check("an unreadable folder is not watched and shows nothing: " + root.names(), !watch.watching && watch.newest.length === 0)
        },
        {
            cmd: "chmod 755 \"$1.3\"",
            wait: 9000,
            check: () => root.check("when it becomes readable it is watched and shown: " + root.names(), watch.watching && root.names() === "secret1")
        },
        {
            cmd: "chmod 755 \"$1.3\"; rm -rf \"$1.2\" \"$1.3\" \"$1.link\"",
            wait: 100,
            check: () => {
                watch.folder = root.dir;
            }
        }
    ]

    Timer {
        interval: 100
        running: true
        onTriggered: root.advance()
    }

    function advance(): void {
        step++;
        if (step >= steps.length) {
            finish();
            return;
        }
        const s = steps[step];
        if (s.before)
            s.before();
        runner.command = ["sh", "-c", s.cmd, "sh", root.dir];
        runner.running = true;
    }

    Process {
        id: runner
        onRunningChanged: if (!running && root.step >= 0)
            settle.start()
    }

    Timer {
        id: settle
        interval: root.step >= 0 && root.step < root.steps.length ? root.steps[root.step].wait : 500
        onTriggered: {
            root.steps[root.step].check();
            root.advance();
        }
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("PASS: stack_watch");
            Qt.exit(0);
        } else {
            console.log("FAIL: stack_watch " + failures.join("; "));
            Qt.exit(1);
        }
    }
}
