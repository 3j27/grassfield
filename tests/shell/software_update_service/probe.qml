import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// SoftwareUpdate (ADR-0033 d; docs/specs/updates.md U4, U10, U20, A9) as the shell runs it, with a fake checker (run by
// tests/shell/software_update_service.sh: a dev session, GRASSFIELD_UPDATE_CHECK_CMD=<fake>, the state under the test's
// directory). The fake answers what $FAKE/answer holds (or $FAKE/answer-waiter for --after-update-lock), logs each call
// with its arguments and XDG_CACHE_HOME to $FAKE/calls, hangs while $FAKE/hang exists and prints junk while $FAKE/junk
// exists. Steps, one after the other:
//   a  a check the user asked for: 2 releases recorded and counted, nothing announced (U20), both versions marked
//   b  Omarchy's request with a newer Grassfield: that version announced once, the Omarchy one already marked is not
//   c  the same answer again: nothing announced
//   d  two requests at once: one run (U4: a request joins the running check)
//   e  update-running: the waiter (--after-update-lock) runs and its answer is recorded; the releases kept meanwhile
//   f  junk on stdout: failed/unavailable recorded, the last success kept, no crash
//   g  a checker that cannot start: failed ("could not start")
//   h  a checker that hangs: stopped at the deadline, failed ("took too long")
//   i  busy: the file is not changed
//   j  GF-083's pending logout written to the file
//   k  IPC (the script calls `qs ipc ... update check bogus|user` once "ipc-ready" is printed): bogus refused, user ran
// Prints "software-update-service: PASS" or FAIL <why>.
ShellRoot {
    id: root

    readonly property string fake: Quickshell.env("FAKE")
    property string failure: ""
    property int announced: 0
    property var lastAnnounce: []
    property int step: 0
    property int callsAtIpc: 0

    function check(cond: bool, what: string): void {
        if (!cond && failure === "")
            failure = what;
        console.log((cond ? "ok  " : "BAD ") + what);
    }

    // gf, om: a version or null (typed `var`: a string parameter would turn null into "null").
    function answer(gf: var, om: var): string {
        return JSON.stringify({version: 1, state: "available", channel: "stable", checkedAt: new Date().toISOString(), grassfield: {installed: "1.0.0-1", available: gf, notes: [], notesError: null}, omarchy: {installed: "4.0.4-1", available: om}, others: 1, otherPackages: [{name: "linux", installed: "6.18.1-1", available: "6.18.2-1"}]});
    }

    function put(name: string, text: string): void {
        writer.path = root.fake + "/" + name;
        writer.setText(text);
    }

    function calls(): var {
        callsFile.reload();
        const t = callsFile.text();
        return t === "" ? [] : t.trim().split("\n");
    }

    Connections {
        target: SoftwareUpdate

        function onAnnounce(kind: string, version: string, installed: string): void {
            root.announced++;
            root.lastAnnounce = [kind, version, installed];
        }
    }

    FileView {
        id: writer
        printErrors: false
        blockWrites: true
    }

    FileView {
        id: callsFile
        path: root.fake + "/calls"
        printErrors: false
        blockLoading: true
    }

    FileView {
        id: stateFile
        path: SoftwareUpdate.statePath
        printErrors: false
        blockLoading: true
    }

    function stateText(): string {
        stateFile.reload();
        return stateFile.text();
    }

    Process {
        id: sh
        property var done: null
        onExited: if (done)
            done()
    }

    function shell(cmd: string, then: var): void {
        sh.done = then;
        sh.command = ["sh", "-c", cmd];
        sh.running = true;
    }

    Timer {
        id: tick
        interval: 300
        repeat: true
        property int waited: 0
        property var until: null
        property var next: null
        onTriggered: {
            waited += interval;
            if (until() || waited > 8000) {
                stop();
                next();
            }
        }
    }

    function when(cond: var, then: var): void {
        tick.waited = 0;
        tick.until = cond;
        tick.next = then;
        tick.restart();
    }

    Component.onCompleted: Qt.callLater(stepA)

    function stepA(): void {
        put("answer", answer("1.0.1-1", "4.0.6-1"));
        when(() => SoftwareUpdate.loaded, () => {
            SoftwareUpdate.request("user");
            when(() => !SoftwareUpdate.checking && calls().length === 1, () => {
                const f = SoftwareUpdate.file;
                root.check(f.state === "available" && SoftwareUpdate.count === 2, "a: state " + f.state + ", count " + SoftwareUpdate.count);
                root.check(root.announced === 0, "a: a user's check announces nothing (" + root.announced + ")");
                root.check(JSON.stringify(f.announced) === JSON.stringify(["grassfield 1.0.1-1", "omarchy 4.0.6-1"]), "a: both versions marked: " + JSON.stringify(f.announced));
                const saved = JSON.parse(root.stateText() || "{}");
                root.check(saved.state === "available" && saved.otherPackages.length === 1, "a: software-update.json written: " + saved.state);
                const c = calls()[0];
                root.check(c.indexOf("args=|") >= 0, "a: no option while online: " + c);
                root.check(c.indexOf("cache=" + Quickshell.env("GRASSFIELD_STATE_HOME") + "/cache") >= 0, "a: the checker's cache under the dev state: " + c);
                stepB();
            });
        });
    }

    function stepB(): void {
        put("answer", answer("1.0.2-1", "4.0.6-1"));
        SoftwareUpdate.request("omarchy");
        when(() => !SoftwareUpdate.checking && calls().length === 2, () => {
            root.check(root.announced === 1 && root.lastAnnounce[0] === "grassfield" && root.lastAnnounce[1] === "1.0.2-1" && root.lastAnnounce[2] === "1.0.0-1", "b: Grassfield 1.0.2-1 announced once: " + root.announced + " " + JSON.stringify(root.lastAnnounce));
            root.check(SoftwareUpdate.releaseName("1.0.2-1", "1.0.0-1") === "1.0.2", "b: its name");
            SoftwareUpdate.request("omarchy");
            when(() => !SoftwareUpdate.checking && calls().length === 3, () => {
                root.check(root.announced === 1, "c: the same answer again announces nothing (" + root.announced + ")");
                stepD();
            });
        });
    }

    function stepD(): void {
        shell("touch '" + root.fake + "/hang'", stepD2);
    }

    function stepD2(): void {
        SoftwareUpdate.request("user");
        SoftwareUpdate.request("user");
        SoftwareUpdate.request("omarchy");
        when(() => calls().length >= 4, () => {
            shell("rm -f '" + root.fake + "/hang'", () => {
                when(() => !SoftwareUpdate.checking, () => {
                    root.check(calls().length === 4, "d: three requests at once ran one check (" + calls().length + " runs)");
                    stepE();
                });
            });
        });
    }

    function stepE(): void {
        put("answer", JSON.stringify({version: 1, state: "update-running", checkedAt: new Date().toISOString()}));
        put("answer-waiter", JSON.stringify({version: 1, state: "up-to-date", channel: "stable", checkedAt: new Date().toISOString(), grassfield: {installed: "1.0.2-1", available: null}, omarchy: {installed: "4.0.6-1", available: null}, others: 0, otherPackages: []}));
        shell("touch '" + root.fake + "/hang-waiter'", stepE2);
    }

    function stepE2(): void {
        SoftwareUpdate.request("omarchy");
        when(() => SoftwareUpdate.waiting && calls().slice(-1)[0].indexOf("--after-update-lock") >= 0, () => {
            const f = SoftwareUpdate.file;
            root.check(f.state === "update-running" && SoftwareUpdate.count === 2, "e: update-running recorded, the releases kept meanwhile (" + f.state + ", " + SoftwareUpdate.count + ")");
            root.check(calls().slice(-1)[0].indexOf("--after-update-lock") >= 0, "e: the waiter runs with --after-update-lock: " + calls().slice(-1)[0]);
            SoftwareUpdate.request("user");
            shell("rm -f '" + root.fake + "/hang-waiter'", () => {
                when(() => !SoftwareUpdate.waiting && SoftwareUpdate.file.state === "up-to-date", () => {
                    root.check(calls().length === 6, "e: a request while the waiter runs joins it (" + calls().length + " runs)");
                    root.check(SoftwareUpdate.file.state === "up-to-date" && SoftwareUpdate.count === 0, "e: the waiter's answer recorded: " + SoftwareUpdate.file.state);
                    stepF();
                });
            });
        });
    }

    function stepF(): void {
        put("answer", answer("1.0.3-1", null));
        SoftwareUpdate.request("user");
        when(() => !SoftwareUpdate.checking && SoftwareUpdate.file.state === "available", () => {
            shell("touch '" + root.fake + "/junk'", () => SoftwareUpdate.request("user"));
            when(() => !SoftwareUpdate.checking && SoftwareUpdate.file.state === "failed", () => {
                const f = SoftwareUpdate.file;
                root.check(f.error === "unavailable" && f.message === "the checker gave no answer", "f: junk -> failed: " + f.error + " " + f.message);
                root.check(SoftwareUpdate.count === 1 && f.previous.grassfield.available === "1.0.3-1", "f: the last success kept (" + SoftwareUpdate.count + ")");
                shell("rm -f '" + root.fake + "/junk'", stepG);
            });
        });
    }

    function stepG(): void {
        const real = SoftwareUpdate.program;
        SoftwareUpdate.program = "/nonexistent/grassfield-update-check";
        SoftwareUpdate.request("user");
        when(() => !SoftwareUpdate.checking && SoftwareUpdate.file.message === "the checker could not start", () => {
            root.check(SoftwareUpdate.file.state === "failed", "g: a checker that cannot start -> failed: " + SoftwareUpdate.file.message);
            SoftwareUpdate.program = real;
            stepH();
        });
    }

    function stepH(): void {
        shell("touch '" + root.fake + "/hang'", stepH2);
    }

    function stepH2(): void {
        SoftwareUpdate.checkTimeoutMs = 800;
        SoftwareUpdate.request("user");
        when(() => !SoftwareUpdate.checking && SoftwareUpdate.file.message === "the check took too long", () => {
            root.check(SoftwareUpdate.file.state === "failed", "h: a hung checker stopped at its deadline: " + SoftwareUpdate.file.message);
            SoftwareUpdate.checkTimeoutMs = 200000;
            shell("rm -f '" + root.fake + "/hang'", stepI);
        });
    }

    function stepI(): void {
        const before = JSON.stringify(SoftwareUpdate.file);
        const n = calls().length;
        put("answer", JSON.stringify({version: 1, state: "busy", checkedAt: new Date().toISOString()}));
        SoftwareUpdate.request("user");
        when(() => !SoftwareUpdate.checking && calls().length === n + 1, () => {
            root.check(JSON.stringify(SoftwareUpdate.file) === before, "i: busy changes nothing");
            stepJ();
        });
    }

    function stepJ(): void {
        SoftwareUpdate.logoutPending = true;
        when(() => (JSON.parse(root.stateText() || "{}").logoutPending === true), () => {
            root.check(JSON.parse(root.stateText() || "{}").logoutPending === true, "j: the pending logout written");
            put("answer", answer(null, null));
            root.callsAtIpc = calls().length;
            console.log("software-update-service: ipc-ready");
            when(() => calls().length > root.callsAtIpc, finish);
        });
    }

    function finish(): void {
        root.check(calls().length === root.callsAtIpc + 1, "k: `update check user` over IPC ran one check (" + (calls().length - root.callsAtIpc) + ")");
        console.log(root.failure === "" ? "software-update-service: PASS" : "software-update-service: FAIL " + root.failure);
        Qt.quit();
    }
}
