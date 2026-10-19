pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Test fixture (tests/security/reload_locked.sh, NESTED ONLY): a foreign ext-session-lock client
// standing in for a live third-party locker such as hyprlock. It takes the session lock at start
// and holds it until told to release it over IPC; it has no PAM and no password field.
//   GRASSFIELD_FOREIGN_LOCKER=1 WAYLAND_DISPLAY=<nested> HYPRLAND_INSTANCE_SIGNATURE=<nested> \
//     qs -p tests/security/foreign_locker/ForeignLocker.qml        take the lock
//   qs ipc -p <same path> call foreign status                      "locked secure" | "locked" | "unlocked"
//   qs ipc -p <same path> call foreign unlock                      release the lock, then exit
// Killing the process instead leaves Hyprland's dead-locker screen (the session stays locked).
// Safety: on the owner's real session it would lock the screen with no way to unlock it, so it
// refuses to lock (and exits) unless GRASSFIELD_FOREIGN_LOCKER=1, WAYLAND_DISPLAY is set, and
// HYPRLAND_INSTANCE_SIGNATURE is set and differs from the owner's instance recorded by
// scripts/dev/nested-up.sh in .dev/main.instance (missing record: refused).
// Not named shell.qml: scripts/dev/test.sh runs every tests/security/*/shell.qml offscreen.
ShellRoot {
    id: root

    settings.watchFiles: false

    readonly property string instance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
    readonly property string mainInstance: String(mainRecord.text()).trim()
    readonly property bool allowed: Quickshell.env("GRASSFIELD_FOREIGN_LOCKER") === "1" && (Quickshell.env("WAYLAND_DISPLAY") || "") !== "" && instance !== "" && mainInstance !== "" && instance !== mainInstance

    FileView {
        id: mainRecord
        path: Quickshell.shellDir + "/../../../.dev/main.instance"
        blockLoading: true
        printErrors: false
    }

    WlSessionLock {
        id: sessionLock

        locked: root.allowed
        onLockStateChanged: console.info("foreign-locker: locked=" + locked)
        onSecureStateChanged: console.info("foreign-locker: secure=" + secure)

        WlSessionLockSurface {
            color: "#5a1010"

            Text {
                anchors.centerIn: parent
                text: "FOREIGN LOCKER (test fixture)"
                textFormat: Text.PlainText
                color: "white"
                font.pixelSize: 48
            }
        }
    }

    Timer {
        id: quitTimer
        interval: 300
        onTriggered: Qt.quit()
    }

    IpcHandler {
        target: "foreign"

        function status(): string {
            if (!sessionLock.locked)
                return "unlocked";
            return sessionLock.secure ? "locked secure" : "locked";
        }

        function unlock(): string {
            // Epoch ms of the release, compared with the shell log by tests/security/reload_locked.sh (unlocked window).
            console.info("foreign-locker: unlocking on request at " + Date.now());
            sessionLock.locked = false;
            quitTimer.start();
            return "unlocked";
        }
    }

    Component.onCompleted: {
        if (!allowed) {
            console.warn("foreign-locker: refused: nested only (needs GRASSFIELD_FOREIGN_LOCKER=1 and a Hyprland instance other than .dev/main.instance)");
            Qt.callLater(() => Qt.exit(2)); // Qt.exit() is ignored before the event loop runs
        }
    }
}
