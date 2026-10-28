import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// A stored `update-running` whose waiter did not survive (a reboot or a log out during `omarchy update`, a crash): the
// service checks at once when it reads the file, without a request (integrator review of a9a5974, MAJOR 3). Run by
// tests/shell/software_update_service.sh after it wrote that state, with the fake checker answering `up-to-date`.
// Prints "software-update-stale: PASS" or FAIL <why>.
ShellRoot {
    id: root

    readonly property string fake: Quickshell.env("FAKE")

    FileView {
        id: callsFile
        path: root.fake + "/calls"
        printErrors: false
        blockLoading: true
    }

    function calls(): var {
        callsFile.reload();
        const t = callsFile.text();
        return t === "" ? [] : t.trim().split("\n");
    }

    Timer {
        interval: 200
        repeat: true
        running: true
        property int waited: 0
        onTriggered: {
            waited += interval;
            const done = SoftwareUpdate.loaded && !SoftwareUpdate.checking && SoftwareUpdate.file.state === "up-to-date";
            if (!done && waited < 15000)
                return;
            stop();
            const c = root.calls();
            const ok = done && c.length === 1 && c[0].indexOf("--after-update-lock") < 0;
            console.log(ok ? "software-update-stale: PASS" : "software-update-stale: FAIL state " + SoftwareUpdate.file.state + ", " + c.length + " runs: " + c.join(" / "));
            Qt.quit();
        }
    }
}
