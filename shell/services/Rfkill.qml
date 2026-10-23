pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Rfkill.js" as Logic

// rfkill soft block for Airplane Mode (REQ-QS-CC3). Opening /dev/rfkill needs no root: logind gives the seat's user
// an ACL on it (uaccess). `usable` is false when the device is missing or not writable (or the `rfkill` tool is not
// installed); Connectivity then falls back to the NetworkManager and BlueZ power switches and tells the user why.
// State is event-driven: `rfkill event` prints a line on every change, which re-reads the list (no polling).
Singleton {
    id: root

    // "" when the soft block can be used, else "missing" | "no-tool" | "not-writable" (Logic.unavailableReason).
    property string reason: "missing"
    property bool probed: false
    readonly property bool usable: probed && reason === ""
    // The radios as read from rfkill (see Logic.parseList) and Airplane Mode derived from them.
    property var devices: []
    readonly property bool known: usable && Logic.airplane(devices).known
    readonly property bool airplane: known && Logic.airplane(devices).on

    readonly property string reasonText: {
        switch (reason) {
        case "missing":
            return qsTr("rfkill is not available on this computer");
        case "no-tool":
            return qsTr("the rfkill tool is not installed");
        case "not-writable":
            return qsTr("rfkill is not writable by this session");
        }
        return "";
    }

    // Blocks (on) or unblocks the radios. Returns false when the soft block is not usable (the caller falls back).
    function setBlocked(on: bool): bool {
        if (!usable)
            return false;
        setter.command = Logic.command(on);
        setter.running = true;
        return true;
    }

    function refresh(): void {
        lister.running = true;
    }

    Component.onCompleted: probe.running = true

    // exists / tool / writable, one probe at start (a udev ACL change needs a new login anyway).
    Process {
        id: probe
        command: ["sh", "-c", "e=0; w=0; t=0; [ -e /dev/rfkill ] && e=1; [ -r /dev/rfkill ] && [ -w /dev/rfkill ] && w=1; command -v rfkill >/dev/null && t=1; echo $e $w $t"]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim().split(" ");
                root.reason = Logic.unavailableReason(p[0] === "1", p[1] === "1", p[2] === "1");
                root.probed = true;
                if (root.reason !== "") {
                    console.info("rfkill: soft block not used (" + root.reasonText + "); Airplane Mode falls back to the Wi-Fi and Bluetooth power switches");
                } else {
                    root.refresh();
                }
            }
        }
    }

    Process {
        id: lister
        command: ["rfkill", "--json", "list"]
        stdout: StdioCollector {
            onStreamFinished: root.devices = Logic.parseList(text)
        }
    }

    Process {
        id: setter
        onRunningChanged: {
            if (!running)
                root.refresh();
        }
    }

    // One line per rfkill event; the list is re-read (a burst of events re-reads once).
    Process {
        id: watcher
        running: root.usable
        command: ["rfkill", "event"]
        stdout: SplitParser {
            onRead: debounce.restart()
        }
    }

    Timer {
        id: debounce
        interval: Tokens.rfkillDebounce
        onTriggered: root.refresh()
    }
}
