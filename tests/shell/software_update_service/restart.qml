import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// ADR-0041 step 2b (U31), the crash-restart scenario (the integrator's review of 9043ac4, major 2): the shell crashed and
// Restart=always brought it back after a toolkit package was replaced under the session. Run by
// tests/shell/software_update_service.sh with HYPRLAND_INSTANCE_SIGNATURE naming the session's start (10:00) and a stored
// file whose toolkit lists qt6-base installed at 11:00, the log out due and its announcement marked: at load the log out is
// due again (the session's start, not this shell's), and a check with the same answer announces nothing more. Prints
// "software-update-restart: PASS" or FAIL <why>.
ShellRoot {
    id: root

    readonly property string fake: Quickshell.env("FAKE")
    property int announced: 0
    property int phase: 0

    Connections {
        target: SoftwareUpdate

        function onAnnounce(kind: string, version: string, installed: string): void {
            root.announced++;
        }
    }

    FileView {
        id: stateFile
        path: SoftwareUpdate.statePath
        printErrors: false
        blockLoading: true
    }

    function saved(): var {
        stateFile.reload();
        try {
            return JSON.parse(stateFile.text() || "{}");
        } catch (e) {
            return {};
        }
    }

    function fail(why: string): void {
        console.log("software-update-restart: FAIL " + why);
        Qt.quit();
    }

    Timer {
        interval: 200
        repeat: true
        running: true
        property int waited: 0
        onTriggered: {
            waited += interval;
            if (root.phase === 0) {
                if (!SoftwareUpdate.loaded) {
                    if (waited > 15000)
                        root.fail("never loaded");
                    return;
                }
                const start = Date.parse("2026-10-28T10:00:00Z");
                if (SoftwareUpdate.sessionStartedAt !== start)
                    return root.fail("the session's start is " + SoftwareUpdate.sessionStartedAt + ", not the signature's " + start);
                if (!SoftwareUpdate.toolkitLogout)
                    return root.fail("the log out is not due again at load");
                if (root.saved().logoutPending !== true || root.saved().toolkitLogout !== true)
                    return root.fail("the file lost the pending log out: " + JSON.stringify(root.saved()));
                root.phase = 1;
                waited = 0;
                SoftwareUpdate.request("omarchy");
                return;
            }
            if (SoftwareUpdate.checking || waited < 1000) {
                if (waited > 15000)
                    root.fail("the check never ended");
                return;
            }
            stop();
            const ok = root.announced === 0 && SoftwareUpdate.toolkitLogout && root.saved().toolkitLogout === true;
            console.log(ok ? "software-update-restart: PASS" : "software-update-restart: FAIL announced " + root.announced + ", due " + SoftwareUpdate.toolkitLogout + ", file " + JSON.stringify(root.saved()));
            Qt.quit();
        }
    }
}
