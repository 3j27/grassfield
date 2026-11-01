pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import qs.platform

// ADR-0031: the shell's side of a display trial, on the real Displays singleton (tests/shell/displays_trial.sh runs it against a
// fake Hyprland that records requests and answers a reload a moment later). A trial left by a stopped shell is taken back at
// start; a new trial is asked for (one reload) and published `applying`, then `applied` once Hyprland answered that reload "ok"
// (a trial whose reload Hyprland refuses stays `applying`); Keep empties the file without a reload; the deadline, Revert and a trial already past its deadline take
// it back (the file emptied, then one reload); Keep or Revert of a trial the shell does not run changes nothing. The trial file is
// written atomically (a rename), as Settings writes it. Then the input files (ADR-0031 amendment): three quick writes of a
// keyboard.lua that did not exist give one reload once they settle, a change of mouse-trackpad.lua one more. Then pacman's
// lock (ADR-0041 step 2b, I-2's residual): a reload asked while the lock file exists (SessionConfig.pacmanLockPath, a file
// of the test's own here) waits with its ticket out, goes once the file is gone, and Hyprland's answer reaches answered().
// Prints "displays-trial: PASS" or the failing step.
ShellRoot {
    id: root

    // As shell.qml starts SessionConfig (displays_trial.sh checks that line is there): nothing else here uses it before the
    // input step, so a shell that did not start it would miss the input files' changes.
    readonly property int sessionConfigReloads: SessionConfig.reloads
    readonly property string trialPath: Displays.trialPath
    readonly property int now: Math.floor(Date.now() / 1000)
    property int step: 0
    property var failures: []
    // Every state the shell gave a trial, in order ("t1 applying", "t1 applied", ...).
    property var seen: []
    // The lock-wait step: the fake lock file, the reload's ticket, the answers SessionConfig gave ("<ticket> <ok>").
    readonly property string lockPath: Mode.stateDir + "/fake-db.lck"
    property int lockTicket: 0
    property var lockAnswers: []

    Connections {
        target: SessionConfig

        function onAnswered(ticket: int, ok: bool): void {
            root.lockAnswers.push(ticket + " " + ok);
        }
    }

    FileView {
        id: lockFile
        path: root.lockPath
        blockWrites: true
        printErrors: false
    }

    Process {
        id: rmLock
        command: ["rm", "-f", root.lockPath]
    }

    Connections {
        target: Displays

        function onTrialStateChanged(): void {
            if (Displays.trialState)
                root.seen.push(Displays.trialState.id + " " + Displays.trialState.state);
        }
    }

    function check(name: string, ok: bool): void {
        if (!ok) {
            failures.push("step " + root.step + ": " + name);
            console.log("displays-trial: FAIL step " + root.step + ": " + name + " (reloads " + Displays.reloads + ", running \"" + Displays.running + "\", trial " + JSON.stringify(Displays.trialState) + ", file \"" + trialFile.text().split("\n")[0] + "\")");
        }
    }

    function write(text: string): void {
        trialFile.setText(text);
    }

    function stamp(): int {
        return Math.floor(Date.now() / 1000);
    }

    readonly property string line: "v1\tdesc:GF Reference\t1920x1080@60\t0x0\t1\t0\n"

    FileView {
        id: trialFile
        path: root.trialPath
        atomicWrites: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }

    FileView {
        id: keyboardFile
        path: Mode.configDir + "/keyboard.lua"
        atomicWrites: true
        printErrors: false
    }

    FileView {
        id: mouseFile
        path: Mode.configDir + "/mouse-trackpad.lua"
        atomicWrites: true
        printErrors: false
    }

    FileView {
        id: stateFile
        path: Displays.statePath
        printErrors: false
    }

    function published(): var {
        stateFile.reload();
        stateFile.waitForJob();
        try {
            return JSON.parse(stateFile.text());
        } catch (e) {
            return null;
        }
    }

    // Each step acts, then the next one checks once the shell had time to answer (the watch, the reload request, the publish).
    Timer {
        id: tick
        interval: 600
        repeat: true
        running: true
        onTriggered: {
            root.step++;
            switch (root.step) {
            case 1:
                // The lock step's seam, set many turns before that step: a path changed in the same turn as a reload is read
                // stale even through waitForJob() (the integrator's round 2 of the step 2b slice). The file does not exist
                // until step 20, so no reload before it waits.
                SessionConfig.pacmanLockPath = root.lockPath;
                // At start the trial the test left (a shell that stopped mid-trial) was taken back.
                root.check("the old trial is taken back at start", Displays.reloads === 1 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"old","state":"reverted"}');
                trialFile.reload();
                trialFile.waitForJob();
                root.check("the file is emptied", trialFile.text() === "");
                root.write("trial t1 until " + (root.stamp() + 30) + "\n" + root.line);
                break;
            case 2:
                root.check("a new trial is asked for with one reload", Displays.reloads === 2 && Displays.running === "t1");
                const asked = root.published();
                root.check("applying while Hyprland has not answered", asked !== null && JSON.stringify(asked.trial) === '{"id":"t1","state":"applying"}');
                break;
            case 3:
            case 4:
                break;
            case 5:
                // Hyprland answered t1's reload after 1.4 s: later than a blur push waits, within settings.displayTrialAnswerMs.
                const s = root.published();
                root.check("applied once Hyprland answered, even 1.4 s later", s !== null && JSON.stringify(s.trial) === '{"id":"t1","state":"applied"}');
                root.check("applying until Hyprland answered the reload", JSON.stringify(root.seen.filter(x => x.startsWith("t1 ")))
                    === '["t1 applying","t1 applied"]');
                root.write("kept t1\n");
                break;
            case 6:
                root.check("Keep: no reload, nothing runs", Displays.reloads === 2 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"t1","state":"kept"}');
                trialFile.reload();
                trialFile.waitForJob();
                root.check("Keep empties the file", trialFile.text() === "");
                root.write("trial t2 until " + (root.stamp() + 2) + "\n" + root.line);
                break;
            case 7:
                root.check("t2 asked for", Displays.reloads === 3 && Displays.running === "t2");
                break;
            case 8:
            case 9:
                break;
            case 10:
                // About 2.4 s later: past t2's deadline.
                root.check("the deadline takes it back with one reload", Displays.reloads === 4 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"t2","state":"reverted"}');
                root.write("trial t3 until " + (root.stamp() + 30) + "\n" + root.line);
                break;
            case 11:
                root.check("t3 asked for", Displays.reloads === 5 && Displays.running === "t3");
                root.check("Hyprland refused t3's reload: it stays applying", JSON.stringify(Displays.trialState) === '{"id":"t3","state":"applying"}');
                root.write("revert t3\n");
                break;
            case 12:
                root.check("Revert takes it back with one reload", Displays.reloads === 6 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"t3","state":"reverted"}');
                root.write("revert zz\n");
                break;
            case 13:
                root.check("Revert of a trial nobody runs: nothing", Displays.reloads === 6);
                root.write("kept zz\n");
                break;
            case 14:
                root.check("Keep of a trial nobody runs: nothing", Displays.reloads === 6);
                root.write("trial t4 until " + (root.stamp() - 5) + "\n" + root.line);
                break;
            case 15:
                root.check("a trial past its deadline is taken back at once", Displays.reloads === 7 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"t4","state":"reverted"}');
                root.write("not a trial\n");
                break;
            case 16:
                root.check("a line that is not a trial: nothing", Displays.reloads === 7 && Displays.running === "");
                const last = root.published();
                root.check("the state is published", last !== null && last.v === 1 && Array.isArray(last.monitors));
                root.check("the session config counted the trial's reloads", SessionConfig.reloads === 7);
                keyboardFile.setText("return { repeat_rate = 10 }\n");
                keyboardFile.setText("return { repeat_rate = 15 }\n");
                keyboardFile.setText("return { repeat_rate = 25 }\n");
                break;
            case 17:
                break;
            case 18:
                root.check("three writes of a new keyboard.lua: one reload", SessionConfig.reloads === 8 && Displays.reloads === 7);
                mouseFile.setText("return { tap_to_click = false }\n");
                break;
            case 19:
                break;
            case 20:
                root.check("a change of mouse-trackpad.lua: one more", SessionConfig.reloads === 9);
                // pacman's lock: the file exists (any readable or unreadable file counts; pacman's is unreadable); written
                // synchronously (blockWrites) before the reload is asked, on the path set at step 1.
                lockFile.setText("locked\n");
                root.lockTicket = SessionConfig.reload("lock test", Tokens.settingsDisplayTrialAnswerMs);
                break;
            case 21:
                root.check("a reload asked while pacman holds its lock waits, its ticket out", root.lockTicket === 10 && SessionConfig.reloads === 10
                    && SessionConfig.waiting.length === 1 && root.lockAnswers.length === 0);
                rmLock.running = true;
                break;
            case 22:
            case 23:
                break;
            case 24:
                root.check("...goes once the lock is gone, and Hyprland's answer reaches answered()", SessionConfig.waiting.length === 0
                    && JSON.stringify(root.lockAnswers) === '["10 true"]');
                console.log(root.failures.length === 0 ? "displays-trial: PASS (" + SessionConfig.reloads + " reloads)" : "displays-trial: FAIL " + root.failures.join("; "));
                Qt.quit();
                break;
            }
        }
    }
}
