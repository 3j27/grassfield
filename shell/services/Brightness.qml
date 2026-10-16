pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Backlight of the first /sys/class/backlight device. Absent when there is none (desktops):
// available stays false and the OSD and IPC do nothing. Changes made by anyone (brightness keys,
// brightnessctl) are seen through the sysfs file; set() goes through brightnessctl.
//
// In a GRASSFIELD_DEV session the hardware is never changed (the nested shell runs on the owner's
// machine): set() only logs.
Singleton {
    id: root

    property string device: ""
    property int max: 0
    property int value: 0
    // True after the first read; consumers ignore changes before that.
    property bool loaded: false

    readonly property bool available: device !== "" && max > 0
    readonly property real level: available ? Math.max(0, Math.min(1, value / max)) : 0
    readonly property bool devSession: Quickshell.env("GRASSFIELD_DEV") === "1"

    signal commandFinished

    // delta: fraction of the range (0.05 = 5 percent). Returns false when nothing was changed.
    function adjust(delta: real): bool {
        if (!available)
            return false;
        if (devSession) {
            console.info("brightness: dev session, not changing the backlight (" + (delta > 0 ? "+" : "") + Math.round(delta * 100) + "%)");
            return false;
        }
        const pct = Math.round(Math.abs(delta) * 100);
        setter.command = ["brightnessctl", "-q", "-d", root.device, "set", pct + "%" + (delta > 0 ? "+" : "-")];
        setter.running = true;
        return true;
    }

    function refresh(): void {
        current.reload();
    }

    Component.onCompleted: finder.running = true

    Process {
        id: finder
        command: ["sh", "-c", "ls -1 /sys/class/backlight 2>/dev/null | head -n 1"]
        stdout: StdioCollector {
            onStreamFinished: root.device = text.trim()
        }
    }

    Process {
        id: setter
        onRunningChanged: {
            if (!running) {
                root.refresh();
                root.commandFinished();
            }
        }
    }

    FileView {
        id: maximum
        path: root.device !== "" ? "/sys/class/backlight/" + root.device + "/max_brightness" : ""
        printErrors: false
        onLoaded: root.max = parseInt(maximum.text().trim(), 10) || 0
    }

    FileView {
        id: current
        path: root.device !== "" ? "/sys/class/backlight/" + root.device + "/actual_brightness" : ""
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root.value = parseInt(current.text().trim(), 10) || 0;
            root.loaded = true;
        }
    }

    // sysfs does not always raise inotify events; poll slowly as a fallback.
    Timer {
        interval: 1500
        running: root.available
        repeat: true
        onTriggered: current.reload()
    }
}
