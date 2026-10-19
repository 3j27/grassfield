pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.Ui
import "Minimized.js" as Minimized

// Live pointer size (Settings > Accessibility > Pointer, ADR-0014). The compositor keeps its cursor theme and is only
// asked for a new size: Hyprland's own `setcursor <theme> <size>` request, sent on the request socket of the instance
// this shell belongs to (Hyprland.requestSocketPath, i.e. the nested instance in a dev session, never another one).
// No process, no polling. Degrades quietly: not running under Hyprland (no socket) or no cursor theme in the
// environment (the session did not export HYPRCURSOR_THEME/XCURSOR_THEME) means nothing is sent.
// Delivery: one fresh socket per request (a Quickshell Socket whose connect failed never connects again, so it is
// replaced, not reused). The size counts as applied only when Hyprland answered "ok". A lost request (no connection,
// no answer, another answer) is sent again after a growing wait, up to settingsPointerRetryMax attempts; then it waits
// for the next size change or for Hyprland to announce a config reload (which resets the cursor). No busy loop.
// While the slider is dragged, requests are throttled (leading edge, then the last value after the interval).
// With the compositor capability "cursor-refresh" (gfc/1) a refresh request follows each delivered size so the pointer
// on screen is redrawn at once; without it the new size shows at the next shape change.
// Applications already running keep the size they started with; the ones the shell starts get the size in their
// environment (launchEnvironment). At startup the stored size is sent as soon as the settings file is read.
// See docs/specs/settings.md, Pointer.
Singleton {
    id: root

    // Wanted size in pixels; bound to Settings.pointerSize by the shell.
    property int size: PointerSize.DEFAULT
    // Size of the session environment this shell started with (what applications started elsewhere hold).
    readonly property int sessionSize: PointerSize.normalize(parseInt(Quickshell.env("HYPRCURSOR_SIZE") || Quickshell.env("XCURSOR_SIZE") || "", 10))
    // Size the compositor has, as far as this shell knows: the session size at start, then every request it answered.
    property int applied: sessionSize
    // The theme the session selected (cursor.lua / uwsm finalize); unchanged by this component.
    property string theme: Quickshell.env("HYPRCURSOR_THEME") || Quickshell.env("XCURSOR_THEME") || ""
    property string socketPath: Hyprland.requestSocketPath || ""
    readonly property bool available: root.socketPath !== "" && root.theme !== ""
    // Observable by tests: requests written, requests Hyprland answered "ok", refresh requests sent, last request line.
    property int sent: 0
    property int delivered: 0
    property int refreshed: 0
    property string lastRequest: ""
    // Attempts made for the current size (0 once delivered) and whether the retries ran out.
    property int attempts: 0
    property bool gaveUp: false

    // A change arrived during the throttle interval.
    property bool again: false
    // A request is on the wire: its size, the socket, the connection number (events of older ones are ignored), reply.
    property bool busy: false
    property int inflight: 0
    property var conn: null
    property int serial: 0
    property string reply: ""
    property bool warned: false

    onSizeChanged: root.update()
    onAvailableChanged: root.update()

    // Environment for an application the shell starts: the size the user chose, only when it differs from the session's.
    function launchEnvironment(): var {
        return PointerSize.launchEnvironment(root.size, root.sessionSize);
    }

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
        // The answer or the pending retry sends the current size.
        if (root.busy || retry.running)
            return;
        if (throttle.running) {
            root.again = true;
            return;
        }
        root.attempts = 0;
        root.gaveUp = false;
        root.transmit();
        throttle.restart();
    }

    function transmit(): void {
        const line = PointerSize.setCursorRequest(root.theme, root.size);
        if (line === "" || root.socketPath === "")
            return;
        root.busy = true;
        root.inflight = root.size;
        root.reply = "";
        root.lastRequest = line;
        root.sent++;
        console.info("grassfield-shell: pointer", line);
        const id = ++root.serial;
        const sock = socketFactory.createObject(root, {
            "serial": id,
            "path": root.socketPath,
            "line": line
        });
        root.conn = sock;
        watchdog.restart();
        sock.connected = true;
    }

    // Closes and discards the socket of the request on the wire; its late events are ignored.
    function drop(): void {
        watchdog.stop();
        root.serial++;
        const sock = root.conn;
        root.conn = null;
        if (sock) {
            sock.connected = false;
            sock.destroy();
        }
    }

    function succeed(): void {
        const size = root.inflight;
        root.drop();
        root.busy = false;
        root.applied = size;
        root.attempts = 0;
        root.gaveUp = false;
        root.delivered++;
        root.refresh();
        // The size changed meanwhile.
        root.update();
    }

    function fail(why: string): void {
        root.drop();
        root.busy = false;
        root.attempts++;
        if (root.attempts < Tokens.settingsPointerRetryMax) {
            retry.interval = PointerSize.retryDelay(Tokens.settingsPointerRetryMs, root.attempts);
            console.info("grassfield-shell: pointer request not delivered (" + why + "), retrying in " + retry.interval + " ms");
            retry.start();
        } else {
            root.gaveUp = true;
            console.info("grassfield-shell: pointer request not delivered (" + why + "), giving up until the size or the compositor changes");
        }
    }

    // Asks the plugin to redraw the cursor (gfc/1 "cursor-refresh"); nothing when the plugin does not have it.
    function refresh(): void {
        if (!Capabilities.has("cursor-refresh"))
            return;
        Hyprland.dispatch(Minimized.cursorRefreshCall());
        root.refreshed++;
    }

    function socketConnected(id: int): void {
        // Hyprland answers when it has handled the request, then closes.
        if (id === root.serial && root.busy)
            watchdog.restart();
    }

    function socketReply(id: int, data: string): void {
        if (id !== root.serial || !root.busy)
            return;
        root.reply += data;
        const text = root.reply.trim();
        if (text === "ok")
            root.succeed();
        else if (text !== "" && !"ok".startsWith(text))
            root.fail("the compositor answered: " + text.substring(0, 80));
    }

    function socketClosed(id: int, why: string): void {
        if (id !== root.serial || !root.busy)
            return;
        // A close after "ok" is handled in onReply; here nothing valid came.
        root.fail(why);
    }

    // The compositor reloaded its configuration: its cursor is back to the configured one.
    function compositorReset(): void {
        root.applied = root.sessionSize;
        root.update();
    }

    Connections {
        target: Hyprland

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "configreloaded")
                root.compositorReset();
        }
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

    // Waits before sending a lost request again (interval set by fail()).
    Timer {
        id: retry
        onTriggered: {
            if (root.size !== root.applied && root.available && !root.busy)
                root.transmit();
        }
    }

    // A request no one answered.
    Timer {
        id: watchdog
        interval: Tokens.settingsPointerAnswerMs
        onTriggered: root.fail("no answer")
    }

    // One connection per request.
    Component {
        id: socketFactory

        Socket {
            id: sock
            property int serial: 0
            property string line: ""
            parser: SplitParser {
                // No separator: Hyprland's "ok" has no newline, take what arrives.
                splitMarker: ""
                onRead: data => root.socketReply(sock.serial, data)
            }
            onConnectedChanged: {
                if (connected) {
                    write(sock.line);
                    flush();
                    root.socketConnected(sock.serial);
                } else {
                    root.socketClosed(sock.serial, "connection closed without an answer");
                }
            }
            // Connect failures arrive here (the LocalSocketError type is not importable for a typed handler).
            Component.onCompleted: sock.error.connect(() => root.socketClosed(sock.serial, "socket error"))
        }
    }
}
