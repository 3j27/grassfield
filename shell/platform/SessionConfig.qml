pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.Ui
import qs.lib

// The session configuration read again (ADR-0031 and its amendment). Hyprland reads the files Settings writes for the session
// (displays.conf and a display trial through config/hypr/grassfield/displays.lua; mouse-trackpad.lua and keyboard.lua through
// grassfield/input.lua and bindings.lua) only when it parses its configuration, so a choice made in Settings applies when the
// shell asks it to read the configuration again: the request `reload` on the request socket, one connection per request (as
// the blur push), never a `hyprctl` process. Displays.qml asks for it during a trial; the two input files are watched here and
// a change is applied once the writes settle. In a dev session the files are the dev configuration directory's and the socket
// is the nested Hyprland's.
Singleton {
    id: root

    property int reloads: 0

    // Hyprland's answer to a request reload() made: its ticket (what reload() returned) and whether it said "ok" (it answers
    // once it has read its configuration again; a late answer counts as no).
    signal answered(int ticket, bool ok)

    readonly property string mouseTrackpadPath: Mode.configDir + "/mouse-trackpad.lua"
    readonly property string keyboardPath: Mode.configDir + "/keyboard.lua"

    // ADR-0041 step 2b (I-2's residual): a reload asked while pacman holds its database lock (/var/lib/pacman/db.lck: a
    // transaction may be rewriting the Lua tree Hyprland would read) waits for the lock to go, polled every
    // Tokens.sessionConfigLockPollMs, at most Tokens.sessionConfigLockWaitMs, then goes ahead anyway (a display trial's
    // countdown must not be what ends the wait). pacman creates the file root's and unreadable (mode 0): it exists whenever
    // the read fails for any reason but "no such file". The path is a test seam (tests/shell/displays_trial.d); "" waits never.
    property string pacmanLockPath: "/var/lib/pacman/db.lck"
    // The reloads waiting for the lock to go, in order: [{path, ticket, why, answerMs}]; their tickets are already out.
    property var waiting: []
    property int waited: 0

    function pacmanLocked(): bool {
        if (root.pacmanLockPath === "")
            return false;
        // reload() alone reads later, even with blockLoading (the integrator's review of 69757ef: the first reload after
        // the lock appeared still read "no such file"); waitForJob() makes this read the one judged.
        lockFile.reload();
        lockFile.waitForJob();
        return lockFile.loadError !== FileViewError.FileNotFound;
    }

    // The request's ticket (answered() names it), or 0 when there is no Hyprland to ask. `answerMs`: how long its answer may
    // take (a display trial's reload gets longer than the input files': Tokens.settingsDisplayTrialAnswerMs).
    function reload(why: string, answerMs: int): int {
        return root.ask(why, answerMs, false);
    }

    // The same request without its journal lines (a caller that logs the state it acts on itself: the display without a mode,
    // asked again every minute while it lasts, would otherwise put a line in the journal every minute all night).
    function reloadQuietly(why: string, answerMs: int): int {
        return root.ask(why, answerMs, true);
    }

    function ask(why: string, answerMs: int, quiet: bool): int {
        const path = Hyprland.requestSocketPath || "";
        if (path === "") {
            if (!quiet)
                console.info("grassfield-shell: session config: no Hyprland request socket, not read again (" + why + ")");
            return 0;
        }
        root.reloads++;
        const request = {"path": path, "ticket": root.reloads, "why": why, "answerMs": answerMs > 0 ? answerMs : Tokens.materialBlurAnswerMs, "quiet": quiet};
        if (root.waiting.length > 0 || root.pacmanLocked()) {
            if (root.waiting.length === 0) {
                root.waited = 0;
                lockPoll.restart();
            }
            root.waiting = root.waiting.concat([request]);
            if (!quiet)
                console.info("grassfield-shell: session config: pacman holds its database lock, read again once it is released (" + why + ")");
            return request.ticket;
        }
        root.send(request);
        return request.ticket;
    }

    function send(request: var): void {
        if (!request.quiet)
            console.info("grassfield-shell: session config read again (" + request.why + ")");
        reloadSocket.createObject(root, {"path": request.path, "ticket": request.ticket, "answerMs": request.answerMs});
    }

    Timer {
        id: lockPoll
        interval: Tokens.sessionConfigLockPollMs
        repeat: true
        onTriggered: {
            root.waited += interval;
            if (root.waited < Tokens.sessionConfigLockWaitMs && root.pacmanLocked())
                return;
            stop();
            if (root.waited >= Tokens.sessionConfigLockWaitMs)
                console.warn("grassfield-shell: session config: pacman still holds its database lock after " + Math.round(root.waited / 1000) + " s: read again anyway");
            const queue = root.waiting;
            root.waiting = [];
            for (const request of queue)
                root.send(request);
        }
    }

    FileView {
        id: lockFile
        path: root.pacmanLockPath
        printErrors: false
        blockLoading: true
        // The result of the last read (FileViewError): a missing lock file is the only "not locked".
        property int loadError: FileViewError.Success
        onLoaded: loadError = FileViewError.Success
        onLoadFailed: error => loadError = error
    }

    // Settings writes a file on every step of a slider: one reload once the writes settle.
    Timer {
        id: inputSettle
        interval: Tokens.settingsInputReloadMs
        onTriggered: root.reload("input settings", Tokens.materialBlurAnswerMs)
    }

    FileView {
        path: root.mouseTrackpadPath
        printErrors: false
        watchChanges: true
        onFileChanged: inputSettle.restart()
    }

    FileView {
        path: root.keyboardPath
        printErrors: false
        watchChanges: true
        onFileChanged: inputSettle.restart()
    }

    // One connection per request: it sends `reload` and collects the answer until Hyprland closes the connection (or the
    // answer is late), then it is judged once and destroyed later (a Socket cannot be destroyed from its own error signal).
    Component {
        id: reloadSocket

        Socket {
            id: sock
            property int ticket: 0
            property int answerMs: Tokens.materialBlurAnswerMs
            property string reply: ""
            property bool judged: false

            function finish(): void {
                if (sock.judged)
                    return;
                sock.judged = true;
                sock.answerTimeout.stop();
                if (sock.reply.trim() !== "ok")
                    console.info("grassfield-shell: session config: Hyprland answered the reload with \"" + sock.reply.trim() + "\"");
                sock.connected = false;
                root.answered(sock.ticket, sock.reply.trim() === "ok");
                Qt.callLater(() => sock.destroy());
            }

            parser: SplitParser {
                // No separator: Hyprland's answer has no newline, take what arrives and add it up.
                splitMarker: ""
                onRead: data => sock.reply += data
            }
            onConnectedChanged: {
                if (connected) {
                    write("reload");
                    flush();
                    sock.answerTimeout.start();
                } else {
                    sock.finish();
                }
            }

            readonly property Timer answerTimeout: Timer {
                interval: sock.answerMs
                onTriggered: sock.finish()
            }

            // Judged after Quickshell's error handler has returned (closing from inside the signal crashes Quickshell 0.3.2).
            Component.onCompleted: {
                sock.error.connect(() => Qt.callLater(sock.finish));
                sock.connected = true;
            }
        }
    }
}
