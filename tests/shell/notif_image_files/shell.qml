pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.notifications

// Review of 8b2a710 (major 2), on the REAL Notifications singleton (scripts/dev/test.sh: `qs -p tests/shell/notif_image_files`,
// a dev session without the D-Bus server; see the dev-session marker file): a notification image or app icon that names a
// local file is shown only once `stat` said it is a regular file of at most History.MAX_IMAGE_FILE_BYTES. A FIFO (which
// blocked the one image loader for good), a character device, a symlink to a FIFO, a directory, a missing file and an
// oversized (sparse) file are never handed to an Image; a small regular file is, as a path, a file: URL, Quickshell's
// image://icon//path and an app icon path. Prints "notif-image-files: PASS" or the failures.
ShellRoot {
    id: root

    property var failures: []
    readonly property string dir: Quickshell.env("GRASSFIELD_TEST_TMP") + "/notif-image-files"
    property int waited: 0

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
            device: "/dev/null"
        })

    // Fixtures: a small regular file (any bytes: only its kind is checked), a FIFO, a symlink to it, a 20 MiB sparse file,
    // a directory.
    Process {
        id: setup
        running: true
        command: ["sh", "-c", "rm -rf \"$1\" && mkdir -p \"$1/folder.png\" && printf 'png' >\"$1/ok.png\" && mkfifo \"$1/fifo.png\" && ln -s fifo.png \"$1/link.png\" && truncate -s 20M \"$1/big.png\"", "sh", root.dir]
        // Quickshell's qmltypes name QProcess::ExitStatus without exporting it (metadata quirk).
        // qmllint disable signal-handler-parameters
        onExited: code => {
            // qmllint enable signal-handler-parameters
            root.check("fixtures created", code === 0);
            const p = root.paths;
            for (const k in p)
                Notifications.requestFileCheck(p[k]);
            poll.start();
        }
    }

    function settled(): bool {
        const p = root.paths;
        for (const k in p) {
            if (Notifications.fileChecks[p[k]] === undefined)
                return false;
        }
        return true;
    }

    function run(): void {
        const p = root.paths;
        const c = Notifications.fileChecks;
        check("a small regular file is ok", c[p.regular] === "ok");
        check("a FIFO is refused", c[p.fifo] === "no");
        check("a symlink to a FIFO is refused", c[p.fifoLink] === "no");
        check("a character device is refused", c[p.device] === "no");
        check("an oversized file is refused", c[p.big] === "no");
        check("a directory is refused", c[p.folder] === "no");
        check("a missing file is refused", c[p.missing] === "no");
        // What the UI loads (iconSource), for every way a local file is named.
        check("image path shown", Notifications.iconSource(p.regular, "") === p.regular);
        check("image file: URL shown", Notifications.iconSource("file://" + p.regular, "") === "file://" + p.regular);
        check("Quickshell app icon path shown", Notifications.iconSource("image://icon/" + p.regular, "") === "image://icon/" + p.regular);
        check("app icon path shown", Notifications.iconSource("", p.regular) === "file://" + p.regular);
        check("FIFO image never loaded", Notifications.iconSource(p.fifo, "") === "");
        check("FIFO as a file: URL never loaded", Notifications.iconSource("file://" + p.fifo, "") === "");
        check("FIFO via image://icon// never loaded", Notifications.iconSource("image://icon/" + p.fifo, "") === "");
        check("FIFO app icon never loaded", Notifications.iconSource("", p.fifo) === "");
        check("device never loaded", Notifications.iconSource(p.device, "") === "");
        check("oversized never loaded", Notifications.iconSource(p.big, "") === "");
        check("a refused image falls back to the app icon path when that one is fine", Notifications.iconSource(p.fifo, p.regular) === "file://" + p.regular);
        // A file not checked yet is not shown either (the check is requested; it shows on the next evaluation).
        check("an unchecked file is not shown yet", Notifications.iconSource(dir + "/later.png", "") === "");
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        onTriggered: {
            root.waited += interval;
            if (!root.settled() && root.waited < 20000)
                return;
            stop();
            root.run();
            if (root.failures.length === 0) {
                console.log("notif-image-files: PASS");
                Qt.exit(0);
            } else {
                console.log("notif-image-files: FAIL: " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }
}
