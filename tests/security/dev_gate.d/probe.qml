pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.security.lock
import qs.services

// The REAL Lock singleton (and VisualFixtures) under the environment tests/security/dev_gate.sh sets
// (GF-AUDIT-001 SEC-03): DEV_GATE_EXPECT=open (dev session: GRASSFIELD_DEV=1, no GRASSFIELD_SESSION) or closed (a real
// session, GRASSFIELD_SESSION=1, with or without a leaked GRASSFIELD_DEV=1). DEV_GATE_PAM=allowed: the L2 opt-in
// GRASSFIELD_DEV_ALLOW_PAM=1 is set. Offscreen, no compositor: nothing here can lock (the session starts unlocked, no
// marker) and no hook used here touches PAM or logind. Prints "dev-gate: PASS <case>" or "dev-gate: FAIL <checks>".
ShellRoot {
    id: root

    settings.watchFiles: false

    readonly property string expect: Quickshell.env("DEV_GATE_EXPECT")
    readonly property bool pamAllowed: Quickshell.env("DEV_GATE_PAM") === "allowed"
    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function run(): void {
        if (expect === "slept") {
            // Follow-up N1: an "unlocked" marker written before a sleep the shell did not lock for -> the start locks
            // (offscreen there is no compositor: the lock stays requested, "locking").
            check("relocked-after-a-sleep", Lock.lockState !== "unlocked");
        } else if (expect === "notslept") {
            check("unlocked-without-a-sleep", Lock.lockState === "unlocked");
        } else {
            check("started-unlocked", Lock.lockState === "unlocked");
        }
        if (expect === "slept" || expect === "notslept") {
            // nothing else: the start decision is the whole check
        } else if (expect === "closed") {
            check("devHooks-off", Lock.devHooks === false);
            check("pam-not-suppressed", Lock.pamSuppressed === false);
            check("status-refused", Lock.devStatus() === "refused");
            check("pause-refused", Lock.devPauseOwnershipCheck() === "refused");
            check("forge-refused", Lock.devForgeUnlockedAnswer() === "refused");
            check("lockview-refused", Lock.devLockView() === "refused");
            // Last: when open it would reload the shell.
            check("reload-refused", Lock.devReload() === "refused");
            check("fixtures-off", VisualFixtures.dev === false && VisualFixtures.active === false);
        } else if (expect === "open") {
            check("devHooks-on", Lock.devHooks === true);
            check("pam-suppressed-unless-opt-in", Lock.pamSuppressed === !pamAllowed);
            check("status-answers", Lock.devStatus() === "unlocked");
            check("pause-answers", Lock.devPauseOwnershipCheck() === "paused");
            check("forge-not-holding", Lock.devForgeUnlockedAnswer() === "not-holding");
            let view = null;
            try {
                view = JSON.parse(Lock.devLockView());
            } catch (e) {
                view = null;
            }
            check("lockview-json", view !== null && view.state === "unlocked" && view.field === "empty" && view.pamSuppressed === !pamAllowed);
            check("lockview-no-text", view !== null && Object.keys(view).sort().join(",") === "failedAttempts,field,message,pamSuppressed,state");
            check("fixtures-dev", VisualFixtures.dev === true);
        } else {
            check("DEV_GATE_EXPECT-set", false);
        }
        if (failures.length === 0) {
            console.log("dev-gate: PASS " + expect + (pamAllowed ? " (PAM opt-in)" : ""));
            Qt.exit(0);
        } else {
            console.log("dev-gate: FAIL " + expect + ": " + failures.join(", "));
            Qt.exit(1);
        }
    }

    // After the singleton's Component.onCompleted (PAM suppression, restore) has run.
    Timer {
        running: true
        interval: 500
        onTriggered: root.run()
    }
}
