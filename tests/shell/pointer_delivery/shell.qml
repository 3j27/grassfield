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
            // Colours: a valid session theme again, and the fake builder (same arguments as branding/cursors/build.sh).
            Pointer.theme = "gf-test";
            server.active = true;
            Pointer.builder.script = Quickshell.shellPath("../pointer_theme/fake-build.sh");
            Pointer.builder.iconsDir = root.sock + ".icons";
            Pointer.builder.debounceMs = 100;
            root.waitFor(() => Pointer.applied === 28, 4000);
        },
        function () {
            root.check("colours: size delivered with the session theme", root.last() === "/setcursor gf-test 28");
            root.mark = root.requests.length;
            Pointer.outlineColor = "#ffeedd";
            Pointer.fillColor = "#112233";
            // Nothing is sent before the theme is on disk: the pointer stays as it is.
            idle.start();
        },
        function () {
            root.check("colours: waiting for the build, then switched to the custom theme",root.requests.length === root.mark + 1 && root.last() === "/setcursor grassfield-cursors-custom 28");
            root.check("colours: applied theme is the custom one", Pointer.appliedTheme === "grassfield-cursors-custom" && Pointer.builder.ready);
            const env = Pointer.launchEnvironment();
            root.check("colours: new apps get the custom theme", env["XCURSOR_THEME"] === "grassfield-cursors-custom" && env["HYPRCURSOR_THEME"] === "grassfield-cursors-custom");
            // New colours: the rebuilt theme has the same name, the request is sent again once it is built.
            root.mark = root.requests.length;
            Pointer.fillColor = "#223344";
            idle.start();
        },
        function () {
            root.check("colours: rebuilt theme requested again under the same name, once", root.requests.length === root.mark + 1 && root.last() === "/setcursor grassfield-cursors-custom 28");
            root.check("colours: the compositor has the colours of the second build", Pointer.appliedKey === "#ffeedd|#223344");
            // A failing build: nothing is sent, the pointer keeps what it has, apps still match it.
            root.mark = root.requests.length;
            Pointer.fillColor = "#ff0000";
            idle.start();
        },
        function () {
            root.check("colours: failed build sends nothing", root.requests.length === root.mark && Pointer.builder.error !== "");
            root.check("colours: pointer keeps the previous custom theme", Pointer.appliedTheme === "grassfield-cursors-custom");
            root.check("colours: apps still get the theme on screen", Pointer.launchEnvironment()["XCURSOR_THEME"] === "grassfield-cursors-custom");
            root.rem = Pointer.builder.removals;
            // Reset Color: back to the session theme, then the custom theme is deleted.
            root.mark = root.requests.length;
            Pointer.outlineColor = "#ffffff";
            Pointer.fillColor = "#000000";
            root.waitFor(() => Pointer.appliedTheme === "gf-test" && Pointer.builder.removals === root.rem + 1 && !Pointer.builder.removing, 4000);
        },
        function () {
            root.check("reset: session theme requested", root.requests.length === root.mark + 1 && root.last() === "/setcursor gf-test 28");
            root.check("reset: no custom theme for new apps", Pointer.launchEnvironment()["XCURSOR_THEME"] === undefined);
            // A real session after a login with the custom theme on disk (the session environment names it) and the
            // stored colours of that theme: the stamp matches, nothing is built, the custom theme is asked for once.
            root.mark = root.requests.length;
            root.builds = Pointer.builder.started;
            root.run(["sh", "-c", "d=\"$1\"; mkdir -p \"$d/grassfield-cursors-custom\"; touch \"$d/grassfield-cursors-custom/manifest.hl\"; echo '#ffeedd #112233' > \"$d/grassfield-cursors-custom/colors\"", "sh", root.sock + ".icons"], () => {
                Pointer.theme = "grassfield-cursors-custom";
                Pointer.builder.dirty = true;
                Pointer.outlineColor = "#ffeedd";
                Pointer.fillColor = "#112233";
                // The shell reads the stamp when it starts (here: again, the directory changed under it).
                Pointer.builder.iconsDir = "";
                Pointer.builder.iconsDir = root.sock + ".icons";
                Pointer.compositorReset();
                idle.start();
            });
        },
        function () {
            root.check("login: the custom theme of matching colours is requested without a build", root.requests.length === root.mark + 1 && root.last() === "/setcursor grassfield-cursors-custom 28" && Pointer.builder.started === root.builds);
            root.check("login: the session theme in the environment is not what is wanted for the default colours", Pointer.baseTheme === "grassfield-cursors");
            // Reset Colour: the packaged theme is requested although the environment says custom, then the theme is deleted.
            root.mark = root.requests.length;
            root.rem = Pointer.builder.removals;
            Pointer.outlineColor = "#ffffff";
            Pointer.fillColor = "#000000";
            root.waitFor(() => Pointer.appliedTheme === "grassfield-cursors" && !Pointer.builder.removing && Pointer.builder.removals === root.rem + 1, 5000);
        },
        function () {
            root.check("login reset: the packaged theme is requested (" + root.last() + ")", root.requests.length === root.mark + 1 && root.last() === "/setcursor grassfield-cursors 28");
            root.run(["sh", "-c", "test -e \"$1\"/grassfield-cursors-custom; echo $?", "sh", root.sock + ".icons"], () => root.advance());
        },
        function () {
            root.check("login reset: the custom theme is gone", root.out.trim() === "1");
            // A real session start with default colours and a custom theme left on disk (stale, or from before a reset
            // that never ran): the compositor gets the packaged theme, the directory goes.
            root.rem = Pointer.builder.removals;
            root.mark = root.requests.length;
            root.run(["sh", "-c", "d=\"$1\"; mkdir -p \"$d/grassfield-cursors-custom\"; touch \"$d/grassfield-cursors-custom/manifest.hl\"; echo '#aa0000 #0000aa' > \"$d/grassfield-cursors-custom/colors\"", "sh", root.sock + ".icons"], () => {
                Pointer.theme = "grassfield-cursors-custom";
                Pointer.builder.dirty = true;
                Pointer.compositorReset();
                root.waitFor(() => Pointer.appliedTheme === "grassfield-cursors" && !Pointer.builder.removing && Pointer.builder.removals === root.rem + 1, 5000);
            });
        },
        function () {
            root.check("login with defaults: the packaged theme is requested once (" + root.last() + ")", root.requests.length === root.mark + 1 && root.last() === "/setcursor grassfield-cursors 28");
            root.run(["sh", "-c", "test -e \"$1\"/grassfield-cursors-custom; echo $?", "sh", root.sock + ".icons"], () => root.advance());
        },
        function () {
            root.check("login with defaults: the custom theme directory is gone", root.out.trim() === "1");
            // The settings were not read yet (colours not known): nothing is deleted.
            root.run(["sh", "-c", "d=\"$1\"; mkdir -p \"$d/grassfield-cursors-custom\"; touch \"$d/grassfield-cursors-custom/manifest.hl\"", "sh", root.sock + ".icons"], () => {
                root.rem = Pointer.builder.removals;
                Pointer.colorsKnown = false;
                Pointer.builder.dirty = true;
                Pointer.theme = "grassfield-cursors";
                Pointer.compositorReset();
                idle.start();
            });
        },
        function () {
            root.check("settings not read: the custom theme is not removed", Pointer.builder.removals === root.rem);
            Pointer.colorsKnown = true;
            root.waitFor(() => Pointer.builder.removals === root.rem + 1 && !Pointer.builder.removing, 4000);
        },
        function () {
            root.check("settings read: now it is removed", Pointer.builder.removals === root.rem + 1);
            root.finish();
        }
    ]
    property int builds: 0
    property int rem: 0

    // Runs a command, then continues with `next`; its stdout is in `out`.
    property string out: ""
    function run(argv: var, next: var): void {
        runner.next = next;
        runner.command = argv;
        runner.running = true;
    }

    Process {
        id: runner
        property var next: null
        stdout: StdioCollector {
            id: runnerOut
            onStreamFinished: {
                root.out = runnerOut.text;
                const continuation = runner.next;
                runner.next = null;
                if (continuation)
                    continuation();
            }
        }
    }

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
                console.log("pointer-delivery: SKIP (nothing checked: no Unix socket server in this sandbox)");
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
        command: ["rm", "-rf", root.sock, root.sock + ".icons"]
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
        Pointer.colorsKnown = true;
        // The Claude Code sandbox has no Unix sockets: the fake server cannot listen, the test is skipped there.
        server.active = true;
        probe.start();
    }
}
