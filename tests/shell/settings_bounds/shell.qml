pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.store

// The settings file is never read without a bound (GF-084 C3 review, a pre-existing flaw of the shell's store): a symlink to
// /dev/zero made any toggle abort the shell (qBadAlloc), a 256 MB file cost 2.5 GB at its peak and froze the GUI for seconds, a FIFO
// would block a read forever. The store reads a file only when it is a regular one of at most maxFileBytes (1 MiB), through one
// bounded script, and reads anything else as malformed: lock.* fails closed to 5, nothing is written back, the file is left alone.
// Also: a symlinked grassfield.json replaced by a regular file is followed (the watch is set again on the path, and the path is
// looked at every pollInterval), and a write that fails (a read-only directory) keeps its change pending and is retried.
// Each case runs on its own directory under ONE live shell; the shell must stay alive, finish each case within seconds, and its peak
// resident memory (VmHWM, measured offscreen) must stay within kMemoryBoundKb of where it started. Offscreen
// (scripts/dev/test.sh: `qs -p tests/shell/settings_bounds`). Prints "settings-bounds: PASS" or the failing stage.
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-bounds-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    // A peak far below what the unbounded read cost (300 MB file: 2.4 GB). Measured: the idle shell grows by a few MB.
    readonly property int kMemoryBoundKb: 150 * 1024

    readonly property string lock0: '{"version":1,"lock":{"idleMinutes":0}}'
    readonly property string lock10: '{"version":1,"lock":{"idleMinutes":10}}'

    // want: [store property, value]; run / verify: sh scripts, $B is the case directory; toggle: setDockAutohide(true) and flush
    readonly property var cases: [
        {name: "symlink to /dev/zero", stages: [
                {run: 'mkdir -p "$B" && ln -s /dev/zero "$B/grassfield.json"', want: [["lockIdleMinutes", 5], ["validRead", false], ["writeBlocked", true], ["loaded", true]]},
                {toggle: true, want: [["dockAutohide", true]],
                    verify: '[ "$(readlink "$B/grassfield.json")" = /dev/zero ] && [ "$(ls -A "$B")" = grassfield.json ]'}
            ]},
        {name: "a 300 MB file", stages: [
                {run: 'mkdir -p "$B" && truncate -s 300M "$B/grassfield.json"', want: [["lockIdleMinutes", 5], ["validRead", false], ["writeBlocked", true]]},
                {toggle: true, want: [["dockAutohide", true]], verify: '[ "$(stat -c %s "$B/grassfield.json")" = 314572800 ] && [ "$(ls -A "$B")" = grassfield.json ]'}
            ]},
        {name: "a FIFO", stages: [
                {run: 'mkdir -p "$B" && mkfifo "$B/grassfield.json"', want: [["lockIdleMinutes", 5], ["validRead", false], ["writeBlocked", true]]},
                {toggle: true, want: [["dockAutohide", true]], verify: '[ -p "$B/grassfield.json" ] && [ "$(ls -A "$B")" = grassfield.json ]'}
            ]},
        {name: "a directory named grassfield.json", stages: [
                {run: 'mkdir -p "$B/grassfield.json"', want: [["lockIdleMinutes", 5], ["validRead", false], ["writeBlocked", true]]},
                {toggle: true, want: [["dockAutohide", true]], verify: '[ -d "$B/grassfield.json" ] && [ "$(ls -A "$B")" = grassfield.json ]'}
            ]},
        {name: "valid JSON over the limit (idleMinutes 0 + 2 MiB of blanks)", stages: [
                {run: 'mkdir -p "$B" && { printf \'{"version":1,"lock":{"idleMinutes":0}}\'; head -c 2097152 /dev/zero | tr "\\\\0" " "; } > "$B/grassfield.json"',
                    want: [["lockIdleMinutes", 5], ["validRead", false], ["writeBlocked", true]]},
                {toggle: true, want: [["dockAutohide", true]], verify: '[ "$(stat -c %s "$B/grassfield.json")" -gt 2000000 ] && [ "$(ls -A "$B")" = grassfield.json ]'}
            ]},
        {name: "valid JSON under the limit (idleMinutes 10 + 900 KB of blanks)", stages: [
                {run: 'mkdir -p "$B" && { printf \'{"version":1,"lock":{"idleMinutes":10}}\'; head -c 900000 /dev/zero | tr "\\\\0" " "; } > "$B/grassfield.json"',
                    want: [["lockIdleMinutes", 10], ["validRead", true], ["writeBlocked", false]]}
            ]},
        {name: "a file that is not readable", stages: [
                {run: 'mkdir -p "$B" && printf \'%s\' \'' + '{"version":1,"lock":{"idleMinutes":0}}' + '\' > "$B/grassfield.json" && chmod 000 "$B/grassfield.json"',
                    want: [["lockIdleMinutes", 5], ["validRead", false], ["writeBlocked", true]]},
                {run: 'chmod 600 "$B/grassfield.json"', want: [["lockIdleMinutes", 0], ["validRead", true], ["writeBlocked", false]]}
            ]},
        {name: "a symlinked grassfield.json replaced by a regular file", stages: [
                {run: 'mkdir -p "$B/t" && printf \'%s\' \'' + '{"version":1,"lock":{"idleMinutes":0}}' + '\' > "$B/t/a.json" && ln -s t/a.json "$B/grassfield.json"', want: [["lockIdleMinutes", 0]]},
                {run: 'printf \'%s\' \'' + '{"version":1,"lock":{"idleMinutes":10}}' + '\' > "$B/new.json" && mv -fT "$B/new.json" "$B/grassfield.json"', want: [["lockIdleMinutes", 10]]},
                {toggle: true, want: [["lockIdleMinutes", 10], ["dockAutohide", true]],
                    verify: '[ ! -L "$B/grassfield.json" ] && grep -q \'"autohide": true\' "$B/grassfield.json" && grep -q \'"idleMinutes": 10\' "$B/grassfield.json" && grep -q \'"idleMinutes":0\' "$B/t/a.json"'}
            ]},
        {name: "a symlinked grassfield.json is written through to its target", stages: [
                {run: 'mkdir -p "$B/t" && printf \'%s\' \'' + '{"version":1,"lock":{"idleMinutes":10}}' + '\' > "$B/t/a.json" && ln -s t/a.json "$B/grassfield.json"', want: [["lockIdleMinutes", 10]]},
                {toggle: true, want: [["dockAutohide", true]],
                    verify: '[ -L "$B/grassfield.json" ] && grep -q \'"autohide": true\' "$B/t/a.json" && grep -q \'"idleMinutes": 10\' "$B/t/a.json"'}
            ]},
        {name: "a write that fails keeps its change pending and is retried", stages: [
                {run: 'mkdir -p "$B" && printf \'%s\' \'' + '{"version":1,"lock":{"idleMinutes":10}}' + '\' > "$B/grassfield.json" && chmod 500 "$B"', want: [["lockIdleMinutes", 10]]},
                {toggle: true, want: [["dockAutohide", true], ["writeFailures", 1]],
                    verify: '! grep -q autohide "$B/grassfield.json"'},
                {run: 'chmod 700 "$B"', want: [["dockAutohide", true], ["writeFailures", 0]],
                    verify: 'grep -q \'"autohide": true\' "$B/grassfield.json" && grep -q \'"idleMinutes": 10\' "$B/grassfield.json"'}
            ]}
    ]

    // GF_BOUNDS_ONLY="0,2": only these cases (to check one case at a time against another version of the store).
    readonly property var only: Quickshell.env("GF_BOUNDS_ONLY") ? Quickshell.env("GF_BOUNDS_ONLY").split(",").map(n => parseInt(n)) : []

    property int caseIndex: -1
    property int stageIndex: -1
    property int tries: 0
    // "running": the stage's script is running; "wait": the stage's readings are polled.
    property string phase: "idle"
    property bool finished: false
    property bool verified: true
    property bool verifying: false
    property int baselineKb: 0
    property int peakKb: 0
    property var store: null

    function dir(): string {
        return root.base + "/c" + root.caseIndex;
    }

    function stage(): var {
        return root.cases[root.caseIndex].stages[root.stageIndex];
    }

    function finish(ok: bool, message: string): void {
        if (root.finished)
            return;
        root.finished = true;
        root.phase = "idle";
        console.log(ok ? "settings-bounds: PASS (" + root.cases.length + " hostile or unusual files, peak memory +" + Math.round((root.peakKb - root.baselineKb) / 1024) + " MB)" : "settings-bounds: FAIL " + message);
        cleanup.running = true;
    }

    function describe(): string {
        const st = root.stage();
        const readings = st.want.map(w => w[0] + "=" + JSON.stringify(root.store ? root.store[w[0]] : undefined) + " wanted " + JSON.stringify(w[1])).join(", ");
        return "case \"" + root.cases[root.caseIndex].name + "\" stage " + root.stageIndex + ": " + readings + (st.verify !== undefined ? "; file check " + (root.verified ? "passed" : "failed") : "");
    }

    function nextCase(): void {
        if (root.store !== null) {
            root.store.destroy();
            root.store = null;
        }
        root.caseIndex++;
        while (root.only.length > 0 && root.caseIndex < root.cases.length && root.only.indexOf(root.caseIndex) < 0)
            root.caseIndex++;
        if (root.caseIndex >= root.cases.length) {
            root.finish(true, "");
            return;
        }
        root.enterStage(0);
    }

    function enterStage(i: int): void {
        root.stageIndex = i;
        root.tries = 0;
        root.verifying = false;
        const st = root.stage();
        root.verified = st.verify === undefined;
        if (st.run !== undefined) {
            root.phase = "running";
            runner.command = ["sh", "-c", "B=$1; " + st.run, "sh", root.dir()];
            runner.running = true;
        } else {
            if (st.toggle === true) {
                root.store.setDockAutohide(true);
                root.store.flush();
            }
            root.phase = "wait";
        }
    }

    // The stage's script has run: the live store starts on the directory (the first stage of a case prepares the files, so the
    // shell finds them as it would at its start), then the stage's readings are polled.
    Process {
        id: runner
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (root.phase !== "running" || root.finished)
                return;
            if (exitCode !== 0) {
                root.finish(false, "the setup of case \"" + root.cases[root.caseIndex].name + "\" stage " + root.stageIndex + " failed (exit " + exitCode + ")");
                return;
            }
            if (root.store === null)
                root.store = storeComponent.createObject(root, {configDir: root.dir()});
            if (root.stage().toggle === true) {
                root.store.setDockAutohide(true);
                root.store.flush();
            }
            root.phase = "wait";
        }
    }

    Component {
        id: storeComponent

        SettingsStore {
            saveDelay: 10
            pollInterval: 300
        }
    }

    // The peak resident memory of this shell: the parent of the sh the Process starts.
    Process {
        id: memory
        property bool atStart: false
        command: ["sh", "-c", "awk '/^VmHWM:/ {print $2}' /proc/$PPID/status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const kb = parseInt(text.trim());
                if (memory.atStart) {
                    root.baselineKb = kb;
                    root.peakKb = kb;
                    root.nextCase();
                    return;
                }
                root.peakKb = Math.max(root.peakKb, kb);
                console.log("settings-bounds: after case \"" + root.cases[root.caseIndex].name + "\" the peak is " + Math.round(kb / 1024) + " MB (+" + Math.round((kb - root.baselineKb) / 1024) + ")");
                if (kb - root.baselineKb > root.kMemoryBoundKb)
                    root.finish(false, "case \"" + root.cases[root.caseIndex].name + "\": the shell's peak memory is " + Math.round(kb / 1024) + " MB, " + Math.round((kb - root.baselineKb) / 1024) + " MB above where it started");
                else
                    root.nextCase();
            }
        }
    }

    Process {
        id: verifier
        stdout: StdioCollector {}
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            root.verified = exitCode === 0;
            root.verifying = false;
        }
    }

    Process {
        id: prepare
        command: ["mkdir", "-p", root.base]
        running: true
        onRunningChanged: {
            if (!running) {
                memory.atStart = true;
                memory.running = true;
            }
        }
    }

    // Each stage: poll until the store reads what is wanted (and the file check passes), or give up after 12 s.
    Timer {
        interval: 100
        running: root.phase === "wait"
        repeat: true
        onTriggered: {
            if (root.finished || memory.running)
                return;
            const st = root.stage();
            let ok = true;
            for (const w of st.want) {
                if (root.store[w[0]] !== w[1])
                    ok = false;
            }
            if (ok && st.verify !== undefined && !root.verified) {
                if (!root.verifying) {
                    root.verifying = true;
                    verifier.command = ["sh", "-c", "B=$1; " + st.verify, "sh", root.dir()];
                    verifier.running = true;
                }
                ok = false;
            }
            if (ok) {
                if (root.stageIndex + 1 < root.cases[root.caseIndex].stages.length) {
                    root.enterStage(root.stageIndex + 1);
                } else {
                    root.phase = "idle";
                    memory.atStart = false;
                    memory.running = true;
                }
                return;
            }
            if (++root.tries > 120)
                root.finish(false, root.describe());
        }
    }

    Process {
        id: cleanup
        command: ["sh", "-c", 'chmod -R u+rwx "$1" 2>/dev/null; rm -rf "$1"', "sh", root.base]
        onRunningChanged: {
            if (!running)
                Qt.exit(root.passed ? 0 : 1);
        }
    }

    readonly property bool passed: root.finished && root.caseIndex >= root.cases.length

    Timer {
        interval: 240000
        running: true
        onTriggered: root.finish(false, "timeout at case " + root.caseIndex + " stage " + root.stageIndex)
    }
}
