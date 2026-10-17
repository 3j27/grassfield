pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.security.lock
import "IdleModel.js" as IdleModel

// Lock before sleep (SEC1, ADR-0010): a logind *delay* inhibitor on "sleep" is held while the
// session runs; on PrepareForSleep(true) the screen locks and the inhibitor is released as soon
// as the compositor confirms the lock surfaces, so suspend continues; it is taken again on resume.
//
// Quickshell 0.3.1 has no D-Bus or logind API, so both halves are small child processes:
//   - inhibitor: `systemd-inhibit --mode=delay … cat`; `cat` reads this process's stdin pipe, so
//     the inhibitor dies with the shell (EOF) and can never outlive it;
//   - watcher: `gdbus monitor` on /org/freedesktop/login1 (signal subscription, no privileges).
// Both run under `setpriv --pdeathsig TERM` (util-linux): the kernel sends them SIGTERM when the
// shell dies, even by SIGKILL, so a crash leaves no orphan behind.
// In the nested dev session (GRASSFIELD_DEV=1) the inhibitor is never taken: it would delay the
// owner's real suspend. The watcher only listens and stays on.
Scope {
    id: root

    readonly property bool dev: Quickshell.env("GRASSFIELD_DEV") === "1"
    readonly property bool inhibiting: inhibitor.running
    property bool sleeping: false
    // Consecutive early exits of a child; restarts stop after maxFailures.
    property int inhibitorFailures: 0
    property int watcherFailures: 0
    readonly property int maxFailures: 5
    // Prefix for long-lived children: die with the shell (PR_SET_PDEATHSIG, kept across exec).
    readonly property var dieWithShell: ["setpriv", "--pdeathsig", "TERM", "--"]

    function take(): void {
        if (dev || inhibitor.running || inhibitorFailures >= maxFailures)
            return;
        inhibitor.running = true;
    }

    function release(why: string): void {
        releaseTimer.stop();
        if (!inhibitor.running)
            return;
        inhibitor.running = false;
        console.info("grassfield-idle: sleep inhibitor released (" + why + ")");
    }

    function beforeSleep(): void {
        console.info("grassfield-idle: system is going to sleep, locking");
        sleeping = true;
        Lock.lock("sleep");
        if (Lock.secure)
            release("locked");
        else
            releaseTimer.restart();
    }

    function afterResume(): void {
        console.info("grassfield-idle: system resumed");
        sleeping = false;
        releaseTimer.stop();
        take();
    }

    function handleLine(line: string): void {
        const value = IdleModel.prepareForSleep(line);
        if (value === true)
            beforeSleep();
        else if (value === false)
            afterResume();
    }

    Connections {
        target: Lock

        function onSecureChanged(): void {
            if (root.sleeping && Lock.secure)
                root.release("locked");
        }
    }

    // logind proceeds after InhibitDelayMaxSec (5 s by default) regardless; let go just before.
    Timer {
        id: releaseTimer
        interval: 4000
        onTriggered: root.release("timeout")
    }

    Process {
        id: inhibitor

        property double startedAt: 0

        command: root.dieWithShell.concat(["systemd-inhibit", "--what=sleep", "--mode=delay", "--who=Grassfield", "--why=" + qsTr("Lock the screen before sleep"), "cat"])
        stdinEnabled: true
        onStarted: {
            startedAt = Date.now();
            console.info("grassfield-idle: sleep inhibitor taken");
        }
        onRunningChanged: {
            if (running || root.sleeping || root.dev)
                return;
            root.inhibitorFailures = Date.now() - startedAt < 2000 ? root.inhibitorFailures + 1 : 0;
            if (root.inhibitorFailures >= root.maxFailures)
                console.warn("grassfield-idle: systemd-inhibit keeps failing; no lock before sleep");
            else
                inhibitorRestart.restart();
        }
    }

    Timer {
        id: inhibitorRestart
        interval: 5000
        onTriggered: root.take()
    }

    Process {
        id: watcher

        property double startedAt: 0

        running: true
        command: root.dieWithShell.concat(["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"])
        stdout: SplitParser {
            onRead: line => root.handleLine(line)
        }
        onStarted: startedAt = Date.now()
        onRunningChanged: {
            if (running)
                return;
            root.watcherFailures = Date.now() - startedAt < 2000 ? root.watcherFailures + 1 : 0;
            if (root.watcherFailures >= root.maxFailures)
                console.warn("grassfield-idle: cannot watch logind PrepareForSleep; no lock before sleep");
            else
                watcherRestart.restart();
        }
    }

    Timer {
        id: watcherRestart
        interval: 5000
        onTriggered: watcher.running = true
    }

    Component.onCompleted: {
        if (dev)
            console.info("grassfield-idle: inhibitor skipped (dev)");
        else
            take();
    }
}
