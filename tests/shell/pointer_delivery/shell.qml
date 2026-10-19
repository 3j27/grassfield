pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform

// Delivery of the pointer size to the compositor (shell/platform/Pointer.qml), against a fake Hyprland request socket
// (a Quickshell SocketServer in this process). Run by scripts/dev/test.sh: `qs -p tests/shell/pointer_delivery`
// (offscreen). Prints "pointer-delivery: PASS" and exits 0, or prints the failures and exits 1.
// Scenarios: server not started yet (retries with backoff, delivered when it appears), server restarted, silent server
// (no answer: not applied, resent), another answer, retries run out (no busy loop, new size starts again), refresh
// request only with the "cursor-refresh" capability, config reload, a theme name that is not plain is never sent.
ShellRoot {
    id: root

    readonly property string sock: (Quickshell.env("TMPDIR") || "/tmp") + "/gfp-" + Date.now() + "-" + Math.floor(Math.random() * 1e6) + ".sock"
    property var failures: []
    property var requests: []
    // What the fake server does with a request: ok | silent | bad
    property string mode: "ok"
    property int step: -1
    property double deadline: 0
    property var wait: null
    property int mark: 0

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function last(): string {
        return requests.length ? requests[requests.length - 1] : "";
    }

    SocketServer {
        id: server
        active: false
        path: root.sock
        handler: Socket {
            id: peer
            parser: SplitParser {
                splitMarker: ""
                onRead: data => {
                    root.requests.push(data);
                    if (root.mode === "ok") {
                        peer.write("ok");
                        peer.flush();
                        peer.connected = false;
                    } else if (root.mode === "bad") {
                        peer.write("unknown request");
                        peer.flush();
                        peer.connected = false;
                    }
                }
            }
        }
    }

    // Steps run in order; each one starts something and names what to wait for.
    readonly property var steps: [
        function () {
            // Late server: nothing listens yet.
            root.mark = Pointer.sent;
            Pointer.size = 48;
            root.waitFor(() => Pointer.sent >= root.mark + 2, 3000);
        },
        function () {
            root.check("late: not applied while nobody answers", Pointer.applied === 24 && Pointer.delivered === 0);
            server.active = true;
            root.waitFor(() => Pointer.applied === 48, 4000);
        },
        function () {
            root.check("late: delivered once the server is up", Pointer.applied === 48 && Pointer.delivered === 1);
            root.check("late: request line", root.last() === "/setcursor gf-test 48");
            root.check("late: attempts reset", Pointer.attempts === 0 && !Pointer.gaveUp);
            // Restart: the server goes away and comes back with the next size already wanted.
            server.active = false;
            Pointer.size = 64;
            restartTimer.start();
            root.waitFor(() => Pointer.applied === 64, 4000);
        },
        function () {
            root.check("restart: delivered after the server came back", Pointer.applied === 64 && root.last() === "/setcursor gf-test 64");
            // Silent server: connects, never answers.
            root.mode = "silent";
            Pointer.size = 72;
            root.waitFor(() => Pointer.attempts >= 1, 3000);
        },
        function () {
            root.check("silent: size not applied without an answer", Pointer.applied === 64 && Pointer.size === 72);
            root.check("silent: request was written", root.last() === "/setcursor gf-test 72");
            root.mode = "bad";
            root.waitFor(() => Pointer.attempts >= 2, 4000);
        },
        function () {
            root.check("bad answer: not applied", Pointer.applied === 64);
            root.mode = "ok";
            root.waitFor(() => Pointer.applied === 72, 4000);
        },
        function () {
            root.check("recovered: applied after the server answers ok", Pointer.applied === 72 && !Pointer.gaveUp);
            // No capability: no refresh request.
            root.check("no refresh without the capability", Pointer.refreshed === 0);
            Capabilities.features = ["cursor-refresh"];
            Capabilities.pluginPresent = true;
            Pointer.size = 76;
            root.waitFor(() => Pointer.applied === 76, 3000);
        },
        function () {
            root.check("refresh sent after the delivered size with the capability", Pointer.refreshed === 1);
            Capabilities.pluginPresent = false;
            // Retries run out: stops sending (no busy loop), a new size starts a new series.
            server.active = false;
            Pointer.size = 80;
            root.waitFor(() => Pointer.gaveUp, 12000);
        },
        function () {
            root.mark = Pointer.sent;
            root.check("gave up: attempts bounded", Pointer.attempts === 5 && Pointer.applied === 76);
            idle.start();
        },
        function () {
            root.check("gave up: nothing sent while idle", Pointer.sent === root.mark);
            server.active = true;
            Pointer.size = 84;
            root.waitFor(() => Pointer.applied === 84, 3000);
        },
        function () {
            root.check("new size after give-up delivered", Pointer.applied === 84 && !Pointer.gaveUp);
            // Config reload: the compositor cursor is back to the session's; the wanted size is sent again.
            root.mark = Pointer.delivered;
            Pointer.compositorReset();
            root.waitFor(() => Pointer.delivered === root.mark + 1, 3000);
        },
        function () {
            root.check("reload: size resent", root.last() === "/setcursor gf-test 84" && Pointer.applied === 84);
            // Injection: a theme that is not a plain name is never sent.
            root.mark = root.requests.length;
            Pointer.theme = "x\n/dispatch exit";
            Pointer.size = 28;
            idle.start();
        },
        function () {
            root.check("bad theme never reaches the socket", root.requests.length === root.mark);
            root.finish();
        }
    ]

    function waitFor(predicate: var, ms: int): void {
        wait = predicate;
        deadline = Date.now() + ms;
        poll.start();
    }

    function advance(): void {
        step++;
        if (step < steps.length)
            steps[step]();
    }

    function finish(): void {
        poll.stop();
        server.active = false;
        cleanup.running = true;
    }

    Timer {
        id: poll
        interval: 40
        repeat: true
        onTriggered: {
            if (root.wait()) {
                poll.stop();
                root.advance();
            } else if (Date.now() > root.deadline) {
                poll.stop();
                root.check("step " + root.step + " timed out", false);
                root.finish();
            }
        }
    }

    Timer {
        id: restartTimer
        interval: 300
        onTriggered: server.active = true
    }

    // The server is started in onCompleted; once the event loop ran, a server that is not active could not listen.
    Timer {
        id: probe
        interval: 200
        onTriggered: {
            if (!server.active) {
                console.log("pointer-delivery: PASS (SKIPPED, nothing checked: no Unix socket server in this sandbox)");
                Qt.exit(0);
                return;
            }
            server.active = false;
            root.advance();
        }
    }

    Timer {
        id: idle
        interval: 1200
        onTriggered: root.advance()
    }

    Process {
        id: cleanup
        command: ["rm", "-f", root.sock]
        onRunningChanged: {
            if (running)
                return;
            if (root.failures.length === 0) {
                console.log("pointer-delivery: PASS");
                Qt.exit(0);
            } else {
                console.log("pointer-delivery: FAIL " + root.failures.join("; "));
                Qt.exit(1);
            }
        }
    }

    Component.onCompleted: {
        Pointer.socketPath = root.sock;
        Pointer.theme = "gf-test";
        // The Claude Code sandbox has no Unix sockets: the fake server cannot listen, the test is skipped there.
        server.active = true;
        probe.start();
    }
}
