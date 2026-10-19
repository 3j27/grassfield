pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.Ui

// Live pointer size (Settings > Accessibility > Pointer, ADR-0014). The compositor keeps its cursor theme and is only
// asked for a new size: Hyprland's own `setcursor <theme> <size>` request, sent on the request socket of the instance
// this shell belongs to (Hyprland.requestSocketPath, i.e. the nested instance in a dev session, never another one).
// No process, no polling. Degrades quietly: not running under Hyprland (no socket) or no cursor theme in the
// environment (the session did not export HYPRCURSOR_THEME/XCURSOR_THEME) means nothing is sent.
// While the slider is dragged, requests are throttled (leading edge, then the last value after the interval).
// Applications already running keep the size they started with; new ones read XCURSOR_SIZE/HYPRCURSOR_SIZE from the
// session environment (docs/specs/settings.md, Pointer).
Singleton {
    id: root

    // Wanted size in pixels; bound to Settings.pointerSize by the shell.
    property int size: PointerSize.DEFAULT
    // Size the compositor has, as far as this shell knows: the session environment at start, then every request sent.
    property int applied: PointerSize.normalize(parseInt(Quickshell.env("HYPRCURSOR_SIZE") || Quickshell.env("XCURSOR_SIZE") || "", 10))
    // The theme the session selected (cursor.lua / uwsm finalize); unchanged by this component.
    readonly property string theme: Quickshell.env("HYPRCURSOR_THEME") || Quickshell.env("XCURSOR_THEME") || ""
    readonly property string socketPath: Hyprland.requestSocketPath || ""
    readonly property bool available: root.socketPath !== "" && root.theme !== ""
    // Requests sent and last request line (observable by tests, logged once per change at info level).
    property int sent: 0
    property string lastRequest: ""

    // A change arrived during the throttle interval; a request sent while the previous one is still on the wire.
    property bool again: false
    property string queuedLine: ""
    property string line: ""
    property bool busy: false
    property bool warned: false

    onSizeChanged: root.update()
    onAvailableChanged: root.update()

    function update(): void {
        if (root.size === root.applied)
            return;
        if (!root.available) {
            if (!root.warned) {
                root.warned = true;
                console.info("grassfield-shell: pointer size not applied (no Hyprland request socket or no cursor theme in the environment)");
            }
            return;
        }
        if (throttle.running) {
            root.again = true;
            return;
        }
        root.sendNow();
        throttle.restart();
    }

    function sendNow(): void {
        const line = PointerSize.setCursorRequest(root.theme, root.size);
        if (line === "")
            return;
        root.applied = root.size;
        root.lastRequest = line;
        root.sent++;
        console.info("grassfield-shell: pointer", line);
        if (root.busy) {
            root.queuedLine = line;
            return;
        }
        root.transmit(line);
    }

    function transmit(request: string): void {
        root.busy = true;
        root.line = request;
        socket.path = root.socketPath;
        socket.connected = true;
        watchdog.restart();
    }

    Timer {
        id: throttle
        interval: Tokens.settingsPointerApplyMs
        onTriggered: {
            if (root.again) {
                root.again = false;
                root.update();
            }
        }
    }

    // The request is done (answered and closed, or never connected): send the one that arrived meanwhile.
    function finished(): void {
        watchdog.stop();
        root.busy = false;
        if (root.queuedLine !== "") {
            const next = root.queuedLine;
            root.queuedLine = "";
            root.transmit(next);
        }
    }

    // One connection per request: Hyprland answers and closes.
    Socket {
        id: socket
        onConnectedChanged: {
            if (connected) {
                write(root.line);
                flush();
                watchdog.restart();
            } else {
                root.finished();
            }
        }
    }

    // Closes our side shortly after the write; also frees the channel when the connection never came up.
    Timer {
        id: watchdog
        interval: Tokens.settingsPointerApplyMs
        onTriggered: {
            if (socket.connected) {
                socket.connected = false;
            } else {
                console.info("grassfield-shell: pointer request not delivered");
                root.finished();
            }
        }
    }
}
