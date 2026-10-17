pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
// Symlink to shell/security/LockMachine.js: Quickshell refuses imports from outside the config dir.
import "LockMachine.js" as Machine

// Crash-recovery marker reads through the real Quickshell FileView (R12 re-review, minor): only a
// missing marker counts as missing; an unreadable one (mode 000, a directory) must lock, like any
// content that is not exactly "unlocked". Mirrors Lock.qml's `marker` FileView and readMarker(),
// and checks that Lock.qml still reads the marker that way.
// Run by scripts/dev/test.sh offscreen (`qs -p tests/security/marker_read`): prints
// "marker-read: PASS" and exits 0, or "marker-read: FAIL <checks>" and exits 1.
// Files live under $GRASSFIELD_TEST_TMP (test.sh removes it); the test also removes its own dir.
ShellRoot {
    id: root

    settings.watchFiles: false

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-marker-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    // Same calls and mapping as Lock.readMarker().
    function read(path: string): var {
        marker.path = path;
        marker.reload();
        marker.waitForJob();
        return Machine.markerRead(marker.loadError === FileViewError.FileNotFound, marker.loadError !== FileViewError.Success, marker.text());
    }

    function run(): void {
        const missing = read(base + "/missing");
        check("missing-is-null", missing === null);
        check("missing-does-not-lock", !Machine.markerSaysLocked(missing));

        const unlocked = read(base + "/unlocked");
        check("unlocked-read", unlocked === "unlocked\n");
        check("unlocked-does-not-lock", !Machine.markerSaysLocked(unlocked));

        check("locked-locks", Machine.markerSaysLocked(read(base + "/locked")));
        check("empty-locks", Machine.markerSaysLocked(read(base + "/empty")));

        // Holds "unlocked" but cannot be read: before the fix it read as "" and counted as missing.
        const denied = read(base + "/denied");
        check("denied-is-permission-denied", marker.loadError === FileViewError.PermissionDenied);
        check("denied-is-not-missing", denied !== null);
        check("denied-locks", Machine.markerSaysLocked(denied));
        check("denied-restores-lock", Machine.restoreAtStart(false, true, denied));

        const directory = read(base + "/directory");
        check("directory-is-not-a-file", marker.loadError === FileViewError.NotAFile);
        check("directory-locks", Machine.markerSaysLocked(directory));

        lockSource.reload();
        lockSource.waitForJob();
        const text = String(lockSource.text());
        check("Lock.qml-readable", text.length > 0);
        check("Lock.qml-readMarker-uses-markerRead", text.indexOf("Machine.markerRead(marker.loadError === FileViewError.FileNotFound, marker.loadError !== FileViewError.Success, marker.text())") !== -1);
        check("Lock.qml-marker-tracks-loadError", /onLoadFailed: error => loadError = error/.test(text));

        cleanup.running = true;
    }

    function report(): void {
        if (failures.length === 0) {
            console.log("marker-read: PASS");
            Qt.exit(0);
        } else {
            console.log("marker-read: FAIL " + failures.join(", "));
            Qt.exit(1);
        }
    }

    // Like Lock.qml's `marker`.
    FileView {
        id: marker

        property int loadError: FileViewError.Success

        blockLoading: true
        printErrors: false
        onLoaded: loadError = FileViewError.Success
        onLoadFailed: error => loadError = error
    }

    FileView {
        id: lockSource
        path: Quickshell.shellDir + "/../../../shell/security/lock/Lock.qml"
        blockLoading: true
        printErrors: false
    }

    Process {
        id: setup
        running: true
        command: ["sh", "-c", 'mkdir -p "$1/directory" && printf "unlocked\\n" > "$1/unlocked" && printf "locked\\n" > "$1/locked" && : > "$1/empty" && printf "unlocked\\n" > "$1/denied" && chmod 000 "$1/denied"', "sh", root.base]
        // A failed setup fails the checks of run() (missing fixtures read as missing, not locked).
        onRunningChanged: {
            if (!running)
                root.run();
        }
    }

    Process {
        id: cleanup
        command: ["sh", "-c", 'chmod 600 "$1/denied" 2>/dev/null; rm -rf "$1"', "sh", root.base]
        onRunningChanged: {
            if (!running)
                root.report();
        }
    }

    Timer {
        running: true
        interval: 20000
        onTriggered: {
            root.failures.push("timeout");
            root.report();
        }
    }
}
