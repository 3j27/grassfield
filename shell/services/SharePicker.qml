pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.lib
import "SharePicker.js" as Logic

// The screen-sharing picker's channel (ADR-0035 D-6, step 7a; spec system-dialogs.md section 3). xdph runs the stand-in
// packaging/session-bin/hyprland-share-picker, which asks here with `picker request <id> <socket>`; the answer comes at
// once: "accepted", "busy" (a picker is open: one at a time), "locked" (owner decision Q15: nothing shows while the session
// is locked) or "refused" (not a request of the stand-in's form; it then runs the stock picker, as with no shell). Accepted,
// the shell connects to the stand-in's one-time socket and shows the panel (SharePickerPanel, popup kind "sharePicker") only
// once the stand-in's window list has arrived on it; a connection that fails or a list that does not come within 2 s shows
// nothing. While the panel is open the shell writes `<id> wait` every 5 s, then one answer, `<id> <flags>/<choice>` or
// `<id> cancel`, and closes. The panel goes when the stand-in's end closes (it gave up, or xdph ended), when the session
// locks, or when another popup takes its place: each of those is "cancelled". Window titles are never logged.
Singleton {
    id: root

    // The request being answered, {id, path}, or null.
    property var current: null
    // The windows xdph listed ({handle, appId, title, address}), from the stand-in's first line.
    property var windows: []
    // The panel was shown for the current request.
    property bool shown: false
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") ?? ""

    // The displays the panel offers: Hyprland's names, as xdph reads them.
    function outputs(): var {
        return Quickshell.screens.map(s => s.name);
    }

    // The user's choice: a display's name or a window's handle; `remember` for Remember this choice.
    function share(kind: string, value: string, remember: bool): void {
        const line = Logic.selection(kind, value, remember, root.outputs(), root.windows);
        if (line === "" || root.current === null)
            return;
        root.finish(root.current.id + " " + line);
    }

    function cancel(): void {
        if (root.current !== null)
            root.finish(root.current.id + " cancel");
    }

    // One answer line (or none), then the channel and the panel close.
    function finish(line: string): void {
        const wasShown = root.shown;
        if (line !== "" && channel.connected) {
            channel.write(line + "\n");
            channel.flush();
        }
        root.current = null;
        root.windows = [];
        root.shown = false;
        connectDeadline.stop();
        channel.connected = false;
        if (wasShown && Popups.kind === "sharePicker")
            Popups.close();
    }

    function received(line: string): void {
        if (root.current === null || root.shown)
            return;
        const listed = Logic.parseList(line, root.current.id);
        if (listed === null)
            return;
        root.windows = listed;
        root.shown = true;
        connectDeadline.stop();
        Popups.openCentered("sharePicker", {}, "");
        if (Popups.kind !== "sharePicker")
            root.cancel();
    }

    // The connection failed, or ended: the stand-in gave up (2 s without a connection) or xdph ended.
    function lost(): void {
        if (root.current !== null && !channel.connected)
            root.finish("");
    }

    Socket {
        id: channel
        parser: SplitParser {
            onRead: line => root.received(line)
        }
        onConnectedChanged: Qt.callLater(root.lost)
        onError: Qt.callLater(root.lost)
    }

    // Accepted: the connection and the window list within 2 s, as the stand-in waits for them; else nothing shows.
    Timer {
        id: connectDeadline
        interval: 2000
        onTriggered: {
            if (root.current !== null && !root.shown)
                root.finish("");
        }
    }

    // While the panel is open: the stand-in counts 15 s without a line as a shell that hangs.
    Timer {
        interval: 5000
        repeat: true
        running: root.shown && channel.connected
        onTriggered: {
            channel.write(root.current.id + " wait\n");
            channel.flush();
        }
    }

    Connections {
        target: SessionState
        function onLockedChanged(): void {
            if (SessionState.locked)
                root.cancel();
        }
    }

    // Another popup in its place (a menu bar click, an IPC open) or a click outside closed the panel: cancelled.
    Connections {
        target: Popups
        function onKindChanged(): void {
            if (root.shown && Popups.kind !== "sharePicker")
                root.cancel();
        }
    }

    IpcHandler {
        target: "picker"

        // The stand-in's request (security.md "IPC surface": an action of packaging/session-bin/hyprland-share-picker).
        function request(id: string, socket: string): string {
            if (SessionState.refuses("picker"))
                return "locked";
            if (!Logic.validRequest(id, socket, root.runtimeDir)) {
                console.info("grassfield: share picker request refused: not the stand-in's form");
                return "refused";
            }
            if (root.current !== null)
                return "busy";
            root.current = {
                id: id,
                path: socket
            };
            root.windows = [];
            root.shown = false;
            connectDeadline.restart();
            channel.path = socket;
            channel.connected = true;
            return "accepted";
        }

        // Test hooks: the state (window titles: dev only), and the user's choice as the panel makes it.
        function status(): string {
            if (!Mode.dev)
                return Mode.refused;
            return JSON.stringify({
                open: root.current !== null,
                shown: root.shown,
                connected: channel.connected,
                popup: Popups.kind,
                outputs: root.outputs(),
                windows: root.windows
            });
        }

        function choose(kind: string, value: string, remember: string): string {
            if (!Mode.dev)
                return Mode.refused;
            if (!root.shown)
                return "closed";
            root.share(kind, value, remember === "remember");
            return "ok";
        }
    }
}
