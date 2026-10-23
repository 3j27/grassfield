pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.notifications
import qs.security.lock
import "IdleModel.js" as IdleModel
import "../../services/DevGate.js" as DevGate

// Lock before sleep (SEC1, ADR-0010): a logind *delay* inhibitor on "sleep" is held while the
// session runs; on PrepareForSleep(true) the screen locks and the inhibitor is released as soon
// as Lock.currentlySecure() holds, so suspend continues; it is taken again on resume. Secure is a lock
// of this shell that the compositor confirmed AND, if it was already held, that Hyprland reported
// locked again after this sleep request (Lock.lock() re-verifies; a session found unlocked under
// a stale lock gets a fresh one first). The decision reads the lock state afresh (Omarchy v4.0.6 fix,
// basecamp/omarchy@237f1b4, see Lock.currentlyLocked()).
//
// Quickshell 0.3.1 has no D-Bus or logind API, so both halves are small child processes:
//   - inhibitor: `systemd-inhibit --mode=delay … cat`; `cat` reads this process's stdin pipe, so
//     the inhibitor dies with the shell (EOF) and can never outlive it;
//   - watcher: `gdbus monitor` on /org/freedesktop/login1 (signal subscription, no privileges).
// Both run under `setpriv --pdeathsig TERM` (util-linux): the kernel sends them SIGTERM when the
// shell dies, even by SIGKILL, so a crash leaves no orphan behind.
// Neither is ever given up (GF-AUDIT-001 SEC-02/GF-030): after IdleModel.MAX_FAST_FAILURES early exits in a row the
// user gets a notice (Notifications, "The screen may not lock before sleep") and the child is retried every minute;
// the notice is withdrawn once it runs again.
// The sleep delay lasts at most what logind allows (InhibitDelayMaxUSec, IdleModel.sleepBudgetMs).
// In the nested dev session (DevGate: GRASSFIELD_DEV=1 and no GRASSFIELD_SESSION=1) the inhibitor is never taken: it
// would delay the owner's real suspend. The watcher only listens and stays on. A GRASSFIELD_DEV=1 that leaks into a
// real session (GRASSFIELD_SESSION=1) changes nothing here (SEC-03).
Scope {
    id: root

    readonly property bool dev: DevGate.allowed(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    readonly property bool inhibiting: inhibitor.running
    property bool sleeping: false
    // Consecutive early exits of a child (IdleModel.failuresAfterExit); reset once it has run FAST_EXIT_MS.
    property int inhibitorFailures: 0
    property int watcherFailures: 0
    // Lock before sleep cannot be guaranteed: the user is told (notice) until both children run again.
    readonly property bool degraded: (!dev && IdleModel.degraded(inhibitorFailures)) || IdleModel.degraded(watcherFailures)
    property string noticeKey: ""
    // Longest wait for a confirmed lock before the sleep delay is released (logind's window, read at start).
    property int budgetMs: IdleModel.sleepBudgetMs("")
    // Prefix for long-lived children: die with the shell (PR_SET_PDEATHSIG, kept across exec).
    readonly property var dieWithShell: ["setpriv", "--pdeathsig", "TERM", "--"]

    function take(): void {
        if (dev || inhibitor.running)
            return;
        inhibitor.running = true;
    }

    function release(why: string): void {
        releaseTimer.stop();
        if (sleeping)
            console.info("grassfield-idle: ready for sleep (" + why + ", lock " + (Lock.currentlySecure() ? "confirmed" : "NOT confirmed") + ")");
        if (!inhibitor.running)
            return;
        inhibitor.running = false;
        console.info("grassfield-idle: sleep inhibitor released (" + why + ")");
    }

    function beforeSleep(): void {
        console.info("grassfield-idle: system is going to sleep, locking");
        sleeping = true;
        Lock.lock("sleep");
        if (Lock.currentlySecure())
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

    onDegradedChanged: {
        if (degraded && noticeKey === "") {
            console.warn("grassfield-idle: lock before sleep is not guaranteed (inhibitor failures " + inhibitorFailures + ", watcher failures " + watcherFailures + "); user notified, retrying every " + IdleModel.SLOW_RETRY_MS / 1000 + " s");
            noticeKey = Notifications.postInternal(qsTr("The screen may not lock before sleep"), IdleModel.degraded(watcherFailures) ? qsTr("Grassfield cannot see when the computer goes to sleep. Lock the screen yourself (Super+Control+Q) before you leave the computer.") : qsTr("Grassfield cannot delay sleep until the screen is locked. Lock the screen yourself (Super+Control+Q) before you close the lid."));
        } else if (!degraded && noticeKey !== "") {
            console.info("grassfield-idle: lock before sleep available again");
            Notifications.clear(noticeKey);
            noticeKey = "";
        }
    }

    Connections {
        target: Lock

        function onSecureChanged(): void {
            if (root.sleeping && Lock.currentlySecure())
                root.release("locked");
        }
    }

    // logind proceeds after its window (InhibitDelayMaxSec) regardless; let go just before.
    Timer {
        id: releaseTimer
        interval: root.budgetMs
        onTriggered: root.release("timeout")
    }

    Process {
        id: inhibitor

        property double startedAt: 0

        command: root.dieWithShell.concat(["systemd-inhibit", "--what=sleep", "--mode=delay", "--who=Grassfield", "--why=" + qsTr("Lock the screen before sleep"), "cat"])
        stdinEnabled: true
        onStarted: {
            startedAt = Date.now();
            inhibitorHealthy.restart();
            console.info("grassfield-idle: sleep inhibitor taken");
        }
        onRunningChanged: {
            if (running || root.sleeping || root.dev)
                return;
            inhibitorHealthy.stop();
            root.inhibitorFailures = IdleModel.failuresAfterExit(root.inhibitorFailures, Date.now() - startedAt);
            inhibitorRestart.interval = IdleModel.retryDelayMs(root.inhibitorFailures);
            if (root.inhibitorFailures > 0)
                console.warn("grassfield-idle: sleep inhibitor exited early (" + root.inhibitorFailures + " in a row); retrying in " + inhibitorRestart.interval / 1000 + " s");
            inhibitorRestart.restart();
        }
    }

    // Ran long enough: no longer failing.
    Timer {
        id: inhibitorHealthy
        interval: IdleModel.FAST_EXIT_MS
        onTriggered: {
            if (inhibitor.running)
                root.inhibitorFailures = 0;
        }
    }

    Timer {
        id: inhibitorRestart
        interval: IdleModel.FAST_RETRY_MS
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
        onStarted: {
            startedAt = Date.now();
            watcherHealthy.restart();
        }
        onRunningChanged: {
            if (running)
                return;
            watcherHealthy.stop();
            root.watcherFailures = IdleModel.failuresAfterExit(root.watcherFailures, Date.now() - startedAt);
            watcherRestart.interval = IdleModel.retryDelayMs(root.watcherFailures);
            if (root.watcherFailures > 0)
                console.warn("grassfield-idle: PrepareForSleep watcher exited early (" + root.watcherFailures + " in a row); retrying in " + watcherRestart.interval / 1000 + " s");
            watcherRestart.restart();
        }
    }

    Timer {
        id: watcherHealthy
        interval: IdleModel.FAST_EXIT_MS
        onTriggered: {
            if (watcher.running)
                root.watcherFailures = 0;
        }
    }

    Timer {
        id: watcherRestart
        interval: IdleModel.FAST_RETRY_MS
        onTriggered: watcher.running = true
    }

    // logind's delay window, read once (read-only property; no privileges). Not in dev: no inhibitor there.
    Process {
        id: budgetQuery
        command: ["busctl", "get-property", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "InhibitDelayMaxUSec"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.budgetMs = IdleModel.sleepBudgetMs(text);
                console.info("grassfield-idle: sleep delay budget " + root.budgetMs + " ms (logind InhibitDelayMaxUSec: " + String(text).trim() + ")");
            }
        }
    }

    Component.onCompleted: {
        if (dev) {
            console.info("grassfield-idle: inhibitor skipped (dev)");
        } else {
            budgetQuery.running = true;
            take();
        }
    }
}
