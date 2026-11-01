import QtQuick
import Quickshell
import Quickshell.Io
import "Prompter.js" as Prompter

// The shell's end of prompter/1 (ADR-0035 D-9, step 9b; docs/specs/system-dialogs.md section 5): one Unix socket to
// grassfield-prompter (`path`, chosen by SecretAgent: the session's socket, or a dev session's test socket), the shell's
// hello with the kinds it draws, each request handed to SecretAgent (`prompted`), each withdrawal (`withdrawn`), and one
// answer per request (answer()). The bridge checks who connects (the user, the shell's unit); this side reads the bridge
// strictly (Prompter.parseBridgeLine): a line it does not expect closes the connection, which the bridge treats as the
// shell's departure (every request "cancelled", the name released). A lost connection drops every request (`lost`) and is
// tried again after 1 s, doubling to 30 s, reset by the bridge's next hello.
//
// Quickshell 0.3.2's Socket must not be closed from inside its own signals (tests/ci/socket_errors.py): the error handler
// only schedules its work, and a line that closes the connection sets `closing` (later lines of the same read are dropped)
// and closes it in a later turn.
Scope {
    id: root

    // The bridge's socket; "" for none (nothing connects).
    property string path: ""
    // The shell's version, for the bridge's log.
    property string shellVersion: ""

    // "off" (no path, or waiting to try again), "connecting", "hello" (connected, the bridge's hello not read yet),
    // "ready".
    readonly property string state: priv.state
    // The bridge's last word on org.gnome.keyring.SystemPrompter: "released", "queued", "owned", or "" before it said.
    readonly property string nameState: priv.nameState
    // Requests sent by the bridge and not answered or withdrawn yet, by id: {kind, passwordNew, choice, security, nameMode,
    // remember} (what an answer needs). Read by SecretAgent's dev state only through `openCount`.
    readonly property int openCount: priv.openCount

    signal prompted(var request)
    signal withdrawn(string id)
    // The connection ended: every request it carried is gone (the bridge answered them "cancelled").
    signal lost

    QtObject {
        id: priv
        property string state: "off"
        property string nameState: ""
        property var open: ({})
        property int openCount: 0
        property bool helloSeen: false
        property bool closing: false
        property int failures: 0
    }

    // One answer to request `id`, once: "ok" (with the password for a password request) or "cancel". False when `id` is not
    // a request of this connection still open (already answered, withdrawn, never sent), when the line would be wrong
    // (Prompter.answerLine), or when the connection is not ready: nothing is sent then.
    // `identity`: the name of an nm request of security "enterprise", or of a kio request whose sheet asked for one, answered
    // ok, else null; `choice`: a kio request's Remember this password.
    function answer(id: string, ok: bool, password: var, choice: bool, identity: var): bool {
        if (priv.state !== "ready" || priv.closing || !Object.prototype.hasOwnProperty.call(priv.open, id))
            return false;
        const line = Prompter.answerLine(priv.open[id], ok, password, choice, identity);
        if (line === "")
            return false;
        root.forget(id);
        socket.write(line + "\n");
        socket.flush();
        return true;
    }

    function forget(id: string): void {
        const open = priv.open;
        delete open[id];
        priv.open = open;
        priv.openCount = Object.keys(open).length;
    }

    function connectNow(): void {
        if (root.path === "" || socket.connected)
            return;
        priv.closing = false;
        priv.helloSeen = false;
        priv.state = "connecting";
        socket.path = root.path;
        socket.connected = true;
    }

    // The attempt failed or the connection ended: every request is gone; the next attempt after the back-off.
    function ended(why: string): void {
        if (priv.state === "off" && retry.running)
            return;
        if (priv.state === "ready" || priv.state === "hello")
            console.warn("grassfield-secret: connection to grassfield-prompter ended (" + why + "); " + priv.openCount + " request(s) dropped");
        else if (priv.failures === 0)
            console.warn("grassfield-secret: grassfield-prompter not reachable (" + why + "); trying again, up to every " + Prompter.RETRY_MAX_MS / 1000 + " s");
        priv.state = "off";
        priv.nameState = "";
        priv.helloSeen = false;
        priv.open = {};
        priv.openCount = 0;
        root.lost();
        if (root.path !== "") {
            retry.interval = Prompter.retryDelay(priv.failures);
            priv.failures++;
            retry.restart();
        }
    }

    // A line this side does not accept: the connection is closed in a later turn, and nothing more of it is read.
    function fail(reason: string): void {
        if (priv.closing)
            return;
        console.warn("grassfield-secret: closing the connection to grassfield-prompter: " + reason);
        priv.closing = true;
        Qt.callLater(root.close);
    }

    function close(): void {
        if (socket.connected)
            socket.connected = false;
        else
            root.ended("closed");
    }

    function socketFailed(): void {
        if (socket.connected)
            return;
        socket.connected = false;
        root.ended("no connection");
    }

    function handleLine(line: string): void {
        if (priv.closing || priv.state === "off")
            return;
        const parsed = Prompter.parseBridgeLine(line, priv.helloSeen);
        if (!parsed.ok) {
            root.fail(parsed.reason);
            return;
        }
        const m = parsed.message;
        if (m.type === "hello") {
            priv.helloSeen = true;
            priv.failures = 0;
            priv.state = "ready";
            console.info("grassfield-secret: connected to grassfield-prompter " + m.bridge);
        } else if (m.type === "name") {
            if (m.state !== priv.nameState)
                console.info("grassfield-secret: org.gnome.keyring.SystemPrompter " + m.state);
            priv.nameState = m.state;
        } else if (m.type === "prompt") {
            if (Object.prototype.hasOwnProperty.call(priv.open, m.id)) {
                root.fail("request " + m.id + " sent twice");
                return;
            }
            const open = priv.open;
            open[m.id] = {id: m.id, kind: m.kind, passwordNew: m.passwordNew, choice: m.choice, security: m.kind === "nm" ? m.network.security : "", nameMode: m.kind === "kio" ? m.login.nameMode : "", remember: m.kind === "kio" ? m.login.remember : ""};
            priv.open = open;
            priv.openCount = Object.keys(open).length;
            root.prompted(m);
        } else if (m.type === "cancel") {
            // A withdrawal that crossed this side's answer names an id no longer open: nothing to do.
            if (!Object.prototype.hasOwnProperty.call(priv.open, m.id))
                return;
            root.forget(m.id);
            root.withdrawn(m.id);
        } else if (m.type === "error") {
            console.warn("grassfield-secret: grassfield-prompter reports " + m.code + ": " + m.text);
            // Before its hello, an error is the bridge's refusal (refused, busy, version): it closes the connection.
            if (!priv.helloSeen)
                root.fail("refused by the bridge (" + m.code + ")");
        }
    }

    Socket {
        id: socket

        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => root.handleLine(data)
        }

        onConnectionStateChanged: {
            if (socket.connected) {
                priv.state = "hello";
                socket.write(Prompter.helloLine(root.shellVersion) + "\n");
                socket.flush();
            } else {
                // Stops Quickshell's own immediate reconnection: the back-off decides when to try again.
                socket.connected = false;
                root.ended(priv.closing ? "closed by the shell" : "closed by the bridge");
            }
        }
        onError: Qt.callLater(root.socketFailed)
    }

    Timer {
        id: retry
        onTriggered: root.connectNow()
    }

    onPathChanged: {
        retry.stop();
        priv.failures = 0;
        if (socket.connected) {
            priv.closing = true;
            socket.connected = false;
        }
        Qt.callLater(root.connectNow);
    }

    Component.onCompleted: Qt.callLater(root.connectNow)
}
