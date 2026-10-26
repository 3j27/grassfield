pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.platform

// ADR-0027: the shell's side of a display trial, on the real Displays singleton (tests/shell/displays_trial.sh runs it against a
// fake Hyprland that only records requests). A trial left by a stopped shell is taken back at start; a new trial is applied (one
// reload) and published; Keep empties the file without a reload; the deadline, Revert and a trial already past its deadline take
// it back (the file emptied, then one reload); Keep or Revert of a trial the shell does not run changes nothing. The trial file is
// written atomically (a rename), as Settings writes it. Prints "displays-trial: PASS" or the failing step.
ShellRoot {
    id: root

    readonly property string trialPath: Displays.trialPath
    readonly property int now: Math.floor(Date.now() / 1000)
    property int step: 0
    property var failures: []

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
                // At start the trial the test left (a shell that stopped mid-trial) was taken back.
                root.check("the old trial is taken back at start", Displays.reloads === 1 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"old","state":"reverted"}');
                trialFile.reload();
                trialFile.waitForJob();
                root.check("the file is emptied", trialFile.text() === "");
                root.write("trial t1 until " + (root.stamp() + 30) + "\n" + root.line);
                break;
            case 2:
                root.check("a new trial is applied with one reload", Displays.reloads === 2 && Displays.running === "t1");
                const s = root.published();
                root.check("the state says it", s !== null && JSON.stringify(s.trial) === '{"id":"t1","state":"applied"}');
                root.write("kept t1\n");
                break;
            case 3:
                root.check("Keep: no reload, nothing runs", Displays.reloads === 2 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"t1","state":"kept"}');
                trialFile.reload();
                trialFile.waitForJob();
                root.check("Keep empties the file", trialFile.text() === "");
                root.write("trial t2 until " + (root.stamp() + 2) + "\n" + root.line);
                break;
            case 4:
                root.check("t2 applied", Displays.reloads === 3 && Displays.running === "t2");
                break;
            case 5:
            case 6:
                break;
            case 7:
                // About 2.4 s later: past t2's deadline.
                root.check("the deadline takes it back with one reload", Displays.reloads === 4 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"t2","state":"reverted"}');
                root.write("trial t3 until " + (root.stamp() + 30) + "\n" + root.line);
                break;
            case 8:
                root.check("t3 applied", Displays.reloads === 5 && Displays.running === "t3");
                root.write("revert t3\n");
                break;
            case 9:
                root.check("Revert takes it back with one reload", Displays.reloads === 6 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"t3","state":"reverted"}');
                root.write("revert zz\n");
                break;
            case 10:
                root.check("Revert of a trial nobody runs: nothing", Displays.reloads === 6);
                root.write("kept zz\n");
                break;
            case 11:
                root.check("Keep of a trial nobody runs: nothing", Displays.reloads === 6);
                root.write("trial t4 until " + (root.stamp() - 5) + "\n" + root.line);
                break;
            case 12:
                root.check("a trial past its deadline is taken back at once", Displays.reloads === 7 && Displays.running === ""
                    && JSON.stringify(Displays.trialState) === '{"id":"t4","state":"reverted"}');
                root.write("not a trial\n");
                break;
            case 13:
                root.check("a line that is not a trial: nothing", Displays.reloads === 7 && Displays.running === "");
                const last = root.published();
                root.check("the state is published", last !== null && last.v === 1 && Array.isArray(last.monitors));
                console.log(root.failures.length === 0 ? "displays-trial: PASS (" + Displays.reloads + " reloads)" : "displays-trial: FAIL " + root.failures.join("; "));
                Qt.quit();
                break;
            }
        }
    }
}
