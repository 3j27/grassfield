pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.store

// A settings file the shell cannot use (over 1 MiB, a FIFO, ...) is not read in full on every poll: the poll looks at its signature
// (a stat) and re-reads it at once only when that changed (or the watch fired); while it stays the same the full re-read backs off
// (pollInterval, then 2x, 4x, ... up to badRetryCap) and starts over when the signature changes. Before: one full read per poll, for
// ever. pollInterval 100 ms and badRetryCap 800 ms here (8 polls), over a 6 s window (~60 polls): the old store did ~60 reads, the
// new one at most ~11. The idle lock stays CLOSED (lock.* reads its default 5, validRead false, writeBlocked) the whole time, a
// repair is picked up at the next poll whose signature changed, a change made while the file was bad is written once it is usable,
// and a usable file is read again on a signature change only.
// Offscreen (scripts/dev/test.sh: `qs -p tests/shell/settings_backoff`). Prints "settings-backoff: PASS" or the failing step.
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-backoff-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    readonly property int kWindowMs: 6000
    // Reads: the load, the one that finds out the signature, then 1, 2, 4, 8 polls apart, then every 8 polls: 5 + 45/8 = 11 at most
    // in ~60 polls; some slack for a slow machine (fewer polls only means fewer reads).
    readonly property int kMaxReads: 14

    property var store: null
    property bool finished: false
    property bool expectClosed: false
    property string phase: "idle"
    property string stepName: ""
    property int stepIndex: -1
    property double stepStart: 0
    property int mark: 0

    function dir(n: string): string {
        return root.base + "/" + n;
    }

    function finish(ok: bool, message: string): void {
        if (root.finished)
            return;
        root.finished = true;
        root.phase = "idle";
        console.log(ok ? "settings-backoff: PASS" : "settings-backoff: FAIL " + message);
        cleanup.running = true;
    }

    function fail(message: string): void {
        root.finish(false, "step \"" + root.stepName + "\": " + message + " (fullReads=" + (root.store ? root.store.fullReads : -1) + ")");
    }

    function start(name: string): void {
        if (root.store !== null) {
            root.store.destroy();
            root.store = null;
        }
        root.store = comp.createObject(root, {configDir: root.dir(name)});
    }

    function windowCheck(): string {
        const n = root.store.fullReads;
        console.log("settings-backoff: " + root.stepName + ": " + n + " full reads over " + root.kWindowMs + " ms (one per poll would be ~" + Math.round(root.kWindowMs / 100) + ")");
        return n > 2 && n <= root.kMaxReads ? "" : "fullReads " + n + " over " + root.kWindowMs + " ms, wanted 3.." + root.kMaxReads;
    }

    // The steps, in order. sh: a script run first ($B = the base directory); closed / open: the lock must (not) read closed from
    // here on, set before the script; run: a function; wait: ms to let pass; until: a condition polled for `within` ms (12 s);
    // check: a function returning an error text or ""; shAfter: sh is a file check run once `until` held.
    readonly property var steps: [
        // --- a file over the limit ---
        {name: "over limit: setup", sh: 'mkdir -p "$B/big" && head -c 2097152 /dev/zero > "$B/big/grassfield.json"', run: () => root.start("big")},
        {name: "over limit: unusable", closed: true, until: () => root.store.loaded && root.store.writeBlocked && root.store.lockIdleMinutes === 5},
        {name: "over limit: reads over the window", wait: root.kWindowMs, check: root.windowCheck},
        // The signature changes: read at once, and the backoff starts over (the next poll reads again).
        {name: "over limit: signature change", sh: 'head -c 2097153 /dev/zero > "$B/big/grassfield.json"', run: () => { root.mark = root.store.fullReads; }},
        {name: "over limit: read at once", until: () => root.store.fullReads >= root.mark + 1, within: 600},
        {name: "over limit: backoff starts over", until: () => root.store.fullReads >= root.mark + 2, within: 900},
        {name: "over limit: a change made while bad", run: () => { root.store.setDockAutohide(true); root.store.flush(); }, wait: 600, check: () => root.store.writeBlocked && root.store.dockAutohide ? "" : "blocked / pending state wrong"},
        {name: "over limit: backoff at its longest", wait: 2500},
        {name: "over limit: repaired", open: true, sh: 'printf \'{"version":1,"lock":{"idleMinutes":10},"dock":{"size":70}}\' > "$B/big/grassfield.json.new" && mv -f "$B/big/grassfield.json.new" "$B/big/grassfield.json"'},
        {name: "over limit: repair picked up", until: () => root.store.validRead && !root.store.writeBlocked && root.store.lockIdleMinutes === 10, within: 1500},
        {name: "over limit: the waiting change is saved", shAfter: true, until: () => root.store.dockAutohide && !root.store.writeBlocked, within: 3000,
            sh: 'sleep 1; grep -q \'"autohide": true\' "$B/big/grassfield.json" && grep -q \'"size": 70\' "$B/big/grassfield.json"'},
        // --- a FIFO ---
        {name: "fifo: setup", sh: 'mkdir -p "$B/fifo" && mkfifo "$B/fifo/grassfield.json"', run: () => root.start("fifo")},
        {name: "fifo: unusable", closed: true, until: () => root.store.loaded && root.store.writeBlocked && root.store.lockIdleMinutes === 5},
        {name: "fifo: reads over the window", wait: root.kWindowMs, check: root.windowCheck},
        {name: "fifo: replaced by a file", open: true, sh: 'rm -f "$B/fifo/grassfield.json" && printf \'{"version":1,"lock":{"idleMinutes":0}}\' > "$B/fifo/grassfield.json"'},
        {name: "fifo: repair picked up", until: () => root.store.validRead && root.store.lockIdleMinutes === 0, within: 1500},
        // --- a usable file: read again on a signature change only ---
        {name: "usable: setup", sh: 'mkdir -p "$B/ok" && printf \'{"version":1,"lock":{"idleMinutes":10}}\' > "$B/ok/grassfield.json"', run: () => root.start("ok")},
        {name: "usable: read", until: () => root.store.validRead && root.store.lockIdleMinutes === 10},
        {name: "usable: not read again while unchanged", wait: 2000, check: () => root.store.fullReads === 1 ? "" : "fullReads " + root.store.fullReads + ", wanted 1"},
        {name: "usable: changed", sh: 'printf \'{"version":1,"lock":{"idleMinutes":15}}\' > "$B/ok/grassfield.json.new" && mv -f "$B/ok/grassfield.json.new" "$B/ok/grassfield.json"'},
        {name: "usable: read again", until: () => root.store.lockIdleMinutes === 15 && root.store.fullReads >= 2, within: 1500},
        {name: "usable: not read again after", wait: 1500, check: () => root.store.fullReads <= 3 ? "" : "fullReads " + root.store.fullReads + ", wanted at most 3"}
    ]

    function enter(i: int): void {
        root.stepIndex = i;
        if (i >= root.steps.length) {
            root.finish(true, "");
            return;
        }
        const s = root.steps[i];
        root.stepName = s.name;
        root.stepStart = Date.now();
        if (s.closed === true)
            root.expectClosed = true;
        if (s.open === true)
            root.expectClosed = false;
        if (s.sh !== undefined && s.shAfter !== true) {
            runner.command = ["sh", "-c", "B=$1; " + s.sh, "sh", root.base];
            runner.running = true;
        } else {
            root.act(s);
        }
    }

    function act(s: var): void {
        if (s.run !== undefined)
            s.run();
        root.stepStart = Date.now();
        root.phase = "wait";
    }

    function advance(): void {
        root.phase = "idle";
        root.enter(root.stepIndex + 1);
    }

    Process {
        id: runner
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (root.finished)
                return;
            if (exitCode !== 0)
                root.fail("script failed (exit " + exitCode + ")");
            else
                root.act(root.steps[root.stepIndex]);
        }
    }

    // The file check of a step with shAfter, once its condition held.
    Process {
        id: postCheck
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (root.finished)
                return;
            if (exitCode === 0)
                root.advance();
            else
                root.fail("file check failed");
        }
    }

    Component {
        id: comp

        SettingsStore {
            saveDelay: 10
            pollInterval: 100
            badRetryCap: 800
        }
    }

    Timer {
        interval: 50
        running: root.phase === "wait"
        repeat: true
        onTriggered: {
            if (root.finished)
                return;
            const s = root.steps[root.stepIndex];
            const elapsed = Date.now() - root.stepStart;
            if (s.until !== undefined) {
                const limit = s.within !== undefined ? s.within : 12000;
                if (s.until()) {
                    if (s.shAfter === true) {
                        root.phase = "idle";
                        postCheck.command = ["sh", "-c", "B=$1; " + s.sh, "sh", root.base];
                        postCheck.running = true;
                    } else {
                        root.advance();
                    }
                } else if (elapsed > limit) {
                    root.fail("condition not reached within " + limit + " ms");
                }
                return;
            }
            if (s.wait !== undefined && elapsed < s.wait)
                return;
            if (s.check !== undefined) {
                const err = s.check();
                if (err !== "") {
                    root.fail(err);
                    return;
                }
            }
            root.advance();
        }
    }

    // While the file is unusable the idle lock reads its closed default: sampled all along.
    Timer {
        interval: 25
        running: root.expectClosed && root.store !== null && !root.finished
        repeat: true
        onTriggered: {
            if (root.store.loaded && (root.store.lockIdleMinutes !== 5 || root.store.validRead || !root.store.writeBlocked))
                root.fail("the lock was not closed (lockIdleMinutes=" + root.store.lockIdleMinutes + " validRead=" + root.store.validRead + " writeBlocked=" + root.store.writeBlocked + ")");
        }
    }

    Process {
        id: prepare
        command: ["mkdir", "-p", root.base]
        running: true
        onRunningChanged: {
            if (!running)
                root.enter(0);
        }
    }

    readonly property bool passedAll: root.finished && root.stepIndex >= root.steps.length

    Process {
        id: cleanup
        command: ["sh", "-c", 'chmod -R u+rwx "$1" 2>/dev/null; rm -rf "$1"', "sh", root.base]
        onRunningChanged: {
            if (!running)
                Qt.exit(root.passedAll ? 0 : 1);
        }
    }

    Timer {
        interval: 120000
        running: true
        onTriggered: root.finish(false, "timeout at step \"" + root.stepName + "\"")
    }
}
