pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.lib
import qs.platform

// ADR-0041 step 2c (incident I-1 as a regression): the real SessionConfig's request socket on its error paths, against the
// fake Hyprland of tests/shell/hypr_socket_errors.sh. Four reloads, each with a 1 s answer bound: with no request socket at
// all (a connect error), against a peer that hangs up without an answer, against one that answers "ok", against one that stays
// silent past the bound and hangs up late. Every one is judged exactly once through answered(ticket, ok), none twice, and
// Quickshell is still up at the end. Prints "hypr-socket-errors: PASS" or the failing step.
ShellRoot {
    id: root

    readonly property int answerMs: 1000
    property int step: 0
    property var failures: []
    // Every answer SessionConfig gave, in order ("<ticket> <ok>").
    property var answers: []
    property var tickets: []

    Connections {
        target: SessionConfig

        function onAnswered(ticket: int, ok: bool): void {
            root.answers.push(ticket + " " + ok);
        }
    }

    // The fake binds its request socket once this file exists.
    FileView {
        id: goFile
        path: Mode.stateDir + "/go"
        blockWrites: true
        printErrors: false
    }

    function check(name: string, ok: bool): void {
        if (!ok) {
            failures.push("step " + root.step + ": " + name);
            console.log("hypr-socket-errors: FAIL step " + root.step + ": " + name + " (answers " + JSON.stringify(root.answers) + ", tickets " + JSON.stringify(root.tickets) + ")");
        }
    }

    function ask(why: string): void {
        root.tickets.push(SessionConfig.reload(why, root.answerMs));
    }

    Timer {
        interval: 500
        repeat: true
        running: true
        onTriggered: {
            root.step++;
            switch (root.step) {
            case 1:
                root.check("a Hyprland instance is set (the request socket path is known)", (Hyprland.requestSocketPath || "") !== "");
                // No pacman lock wait here (ADR-0041 step 2b): on a machine where pacman runs, the wait would move every step.
                SessionConfig.pacmanLockPath = "";
                root.ask("no request socket");
                break;
            case 3:
                root.check("a connect error is judged once, after the signal: answered(1, false)", JSON.stringify(root.answers) === '["1 false"]' && root.tickets[0] === 1);
                goFile.setText("go\n");
                break;
            case 5:
                root.ask("peer hangs up");
                break;
            case 7:
                root.check("a peer that hangs up without an answer: answered(2, false)", JSON.stringify(root.answers) === '["1 false","2 false"]');
                root.ask("peer answers");
                break;
            case 9:
                root.check("a peer that answers ok: answered(3, true)", JSON.stringify(root.answers) === '["1 false","2 false","3 true"]');
                root.ask("peer stays silent");
                break;
            case 12:
                // 1.5 s after the request: past the 1 s bound, before the fake's hang-up at 2.5 s.
                root.check("a silent peer is judged by the bound: answered(4, false)", JSON.stringify(root.answers) === '["1 false","2 false","3 true","4 false"]');
                break;
            case 18:
                // 4.5 s after the request: the fake hung up at 2.5 s on a socket judged already.
                root.check("the late hang-up judges nothing twice", root.answers.length === 4 && SessionConfig.reloads === 4);
                console.log(root.failures.length === 0 ? "hypr-socket-errors: PASS (" + SessionConfig.reloads + " reloads, " + root.answers.length + " answers)" : "hypr-socket-errors: FAIL " + root.failures.join("; "));
                Qt.quit();
                break;
            }
        }
    }
}
