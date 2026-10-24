pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.notifications
import qs.services

// Reviews of 8b2a710 (major 2) and beebaff (major), on the REAL Notifications singleton (scripts/dev/test.sh:
// `qs -p tests/shell/notif_image_files`, a dev session without the D-Bus server; see the dev-session marker file).
// A notification image or app icon that names a local file is never loaded from where it was named: a helper copies it
// into the shell's private directory after checking the OPENED descriptor (regular file, at most
// History.MAX_IMAGE_FILE_BYTES), and the Image loads the copy by a URL built from its number.
//  - a small PNG is copied and shown (as a path, a file: URL, Quickshell's image://icon//path and an app icon path), and
//    the Image of the copy becomes Ready;
//  - a FIFO, a symlink to a FIFO, /dev/null, a directory, a missing file and an oversized (sparse) file are refused;
//  - the reviewer's bypass forms (a FIFO "x.png" next to regular files "x.png?a", "x%2Epng", "x.png#f",
//    "x.png?fallback=a"): every "?", "#" or "%" form is refused outright, and file:///…/x%2Epng names the FIFO and is
//    refused by the copy step;
//  - a checked file later swapped for a FIFO: the shown copy stays a regular file of the shell; the next intake's copy
//    is refused;
//  - after all of it, a normal image still loads (the one image loader never stalled);
//  - previews hidden for a sender (Quick Settings merge): its image and an app icon path are dropped, the private copy
//    included; only a plain theme name stays (Notifications.imageFor/appIconFor, as Banner and NotificationList call them).
// Prints "notif-image-files: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    readonly property string dir: Quickshell.env("GRASSFIELD_TEST_TMP") + "/notif-image-files"
    property int waited: 0
    property int phase: 0
    property string firstCopy: ""
    // A 1x1 PNG.
    readonly property string png: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    readonly property var paths: ({
            regular: dir + "/ok.png",
            fifo: dir + "/fifo.png",
            fifoLink: dir + "/link.png",
            big: dir + "/big.png",
            folder: dir + "/folder.png",
            missing: dir + "/missing.png",
            device: "/dev/null",
            swap: dir + "/swap.png",
            bypassFifo: dir + "/x.png"
        })

    Process {
        id: setup
        running: true
        command: ["sh", "-c", "set -e; d=$1; rm -rf \"$d\"; mkdir -p \"$d/folder.png\"; printf '%s' \"$2\" | base64 -d >\"$d/ok.png\"; "
            + "cp \"$d/ok.png\" \"$d/swap.png\"; mkfifo \"$d/fifo.png\" \"$d/x.png\"; ln -s fifo.png \"$d/link.png\"; "
            + "truncate -s 20M \"$d/big.png\"; mkfifo \"$d/evil.png\"; cp \"$d/ok.png\" \"$d/evil2.png\"; for n in 'x.png?a' 'x%2Epng' 'x.png#f' 'x.png?fallback=a'; do cp \"$d/ok.png\" \"$d/$n\"; done", "sh", root.dir, root.png]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.check("fixtures created", code === 0);
            const p = root.paths;
            for (const k in p)
                Notifications.requestCopy(p[k], true, "Files Test");
            poll.start();
        }
    }

    Process {
        id: swapper
        command: ["sh", "-c", "rm -f \"$1\" && mkfifo \"$1\"", "sh", root.paths.swap]
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.check("swap: ok.png replaced by a FIFO", code === 0);
            Notifications.keptImage(root.paths.swap, "Files Test"); // a new notification naming the swapped file
            root.phase = 2;
            root.waited = 0;
            poll.start();
        }
    }

    function state(path: string): string {
        const e = Notifications.localCopies[path];
        return e === undefined ? "" : e.state;
    }

    function settled(): bool {
        const p = root.paths;
        for (const k in p) {
            const s = state(p[k]);
            if (s === "" || s === "pending")
                return false;
        }
        return true;
    }

    function runChecks(): void {
        const p = root.paths;
        check("the private directory is under XDG_RUNTIME_DIR (" + Notifications.copyDir + ")", Notifications.copyDir.startsWith(Quickshell.env("XDG_RUNTIME_DIR") + "/grassfield-notification-images-"));
        check("a small regular file is copied", state(p.regular) === "ok");
        check("a FIFO is refused", state(p.fifo) === "no");
        check("a symlink to a FIFO is refused", state(p.fifoLink) === "no");
        check("a character device is refused", state(p.device) === "no");
        check("an oversized file is refused", state(p.big) === "no");
        check("a directory is refused", state(p.folder) === "no");
        check("a missing file is refused", state(p.missing) === "no");
        check("the bypass FIFO is refused", state(p.bypassFifo) === "no");
        const copy = Notifications.iconSource(p.regular, "");
        check("the shown source is the private copy (" + copy + ")", copy.startsWith("file://") && copy.indexOf("/grassfield-notification-images-") > 0 && copy.endsWith(".img"));
        check("never the named path itself", copy.indexOf("/notif-image-files/") < 0);
        check("a file: URL shows the copy", Notifications.iconSource("file://" + p.regular, "") === copy);
        check("Quickshell's app icon path shows the copy", Notifications.iconSource("image://icon/" + p.regular, "") === copy);
        check("an app icon path shows the copy", Notifications.iconSource("", p.regular) === copy);
        for (const k of ["fifo", "fifoLink", "device", "big", "folder", "missing"])
            check(k + " never shown", Notifications.iconSource(p[k], "") === "" && Notifications.iconSource("", p[k]) === "");
        // The reviewer's bypass forms.
        const d = root.dir;
        const forms = [d + "/x.png?a", "file://" + d + "/x.png?a", d + "/x%2Epng", "file://" + d + "/x.png#f", d + "/x.png#f",
            "image://icon/" + d + "/x.png?fallback=a"];
        for (const f of forms) {
            // As a new notification would: the intake requests a copy of what the reference names, at once.
            Notifications.keptImage(f, "Files Test");
            Notifications.checkedAppIcon(f, "Files Test");
            check("bypass form refused as an image: " + f, Notifications.iconSource(f, "") === "");
            check("bypass form refused as an app icon: " + f, Notifications.iconSource("", f) === "");
        }
        check("file:///…/x%2Epng names the FIFO and is refused", Notifications.iconSource("file://" + d + "/x%2Epng", "") === "");
        for (const name of ["x.png?a", "x%2Epng", "x.png#f", "x.png?fallback=a"])
            check("no copy was ever requested for " + name, Notifications.localCopies[d + "/" + name] === undefined);
        root.firstCopy = Notifications.iconSource(p.swap, "");
        check("swap: the file is first copied", root.firstCopy !== "");
        shown.source = copy;
        // Review of 6e24d36: an app icon NAME with "../" resolved through Qt's fallback icon directory (/usr/share/pixmaps)
        // to any file. evil.png is a FIFO (it stalled the one image loader for good), evil2.png a regular file (any file
        // the sender picks). Both names are refused at intake and by iconSource; whatever iconSource returns is given to
        // an Image, so a regression stalls the loader and the "later image still loads" check below fails.
        const rel = "../../.." + d;
        for (const name of [rel + "/evil", rel + "/evil2", "hicolor/../../../.." + d + "/evil"]) {
            check("a traversal app icon name is dropped at intake: " + name, Notifications.checkedAppIcon(name, "Files Test") === "");
            check("a traversal app icon name is never resolved: " + name, Notifications.iconSource("", name) === "");
        }
        check("a plain theme name still reaches the theme", Notifications.checkedAppIcon("dialog-information", "Files Test") === "dialog-information");
        nameShown.source = Notifications.iconSource("", rel + "/evil");
        Settings.setNotificationsAppPreview("Private Sender", "never");
    }

    function finish(): void {
        if (failures.length === 0) {
            console.log("notif-image-files: PASS");
            Qt.exit(0);
        } else {
            console.log("notif-image-files: FAIL: " + failures.join("; "));
            Qt.exit(1);
        }
    }

    Window {
        visible: true
        width: 64
        height: 64

        Image {
            id: shown
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(256, 256)
        }

        Image {
            id: control
            x: 32
            width: 32
            height: 32
            asynchronous: true
        }

        Image {
            id: nameShown
            y: 32
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(256, 256)
        }
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === 0) {
                if (!root.settled() && root.waited < 30000)
                    return;
                stop();
                root.runChecks();
                root.phase = 1;
                swapper.running = true;
            } else if (root.phase === 2) {
                if (root.state(root.paths.swap) !== "no" && root.waited < 20000)
                    return;
                stop();
                root.check("swap: the next intake's copy of the FIFO is refused", root.state(root.paths.swap) === "no");
                root.check("swap: nothing is shown for it any more", Notifications.iconSource(root.paths.swap, "") === "");
                root.check("swap: the image of the copy loaded (" + shown.status + ")", shown.status === Image.Ready);
                control.source = Notifications.iconSource(root.paths.regular, "");
                root.phase = 3;
                root.waited = 0;
                poll.start();
            } else if (root.phase === 3) {
                if (control.status !== Image.Ready && root.waited < 10000)
                    return;
                stop();
                root.check("a later image still loads: the image loader never stalled (" + control.status + ")", control.status === Image.Ready);
                // Seconds later (any copy a bypass form could have queued is long done): still nothing for them.
                const d = root.dir;
                for (const name of ["x.png?a", "x%2Epng", "x.png#f", "x.png?fallback=a"]) {
                    root.check("still no copy for " + name, Notifications.localCopies[d + "/" + name] === undefined);
                    root.check("still nothing shown for " + name, Notifications.iconSource(d + "/" + name, "") === "");
                }
                const p = root.paths;
                const shownFor = app => Notifications.iconSource(Notifications.imageFor(p.regular, app), Notifications.appIconFor(p.regular, app));
                root.check("previews shown: the private copy (" + shownFor("Open Sender") + ")", shownFor("Open Sender").endsWith(".img"));
                root.check("previews hidden: neither the image nor the app icon path, not even as a copy (" + shownFor("Private Sender") + ")", shownFor("Private Sender") === "");
                root.check("previews hidden: a plain theme name stays", Notifications.appIconFor("dialog-information", "Private Sender") === "dialog-information");
                root.check("previews hidden: a traversal name is dropped", Notifications.appIconFor("../../.." + d + "/evil", "Private Sender") === "");
                root.finish();
            }
        }
    }
}
