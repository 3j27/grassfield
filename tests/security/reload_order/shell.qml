pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "probe"

// Quickshell 0.3.1 reload contract the session lock relies on (R12 review blocker, Lock.qml):
//   1. on a soft reload a Singleton's children are reloaded in declaration order, so a
//      PersistentProperties declared before a sibling has its old values restored, and bindings on
//      them re-evaluated, before that sibling reloads (where WlSessionLock keeps or releases the
//      handed-over lock); one declared after it is restored too late (negative control);
//   2. Component.onCompleted of the new instance runs before the reload pass;
//   3. `settings.watchFiles: false` is applied again after a reload (Quickshell resets it to true);
//   4. shell/security/lock/Lock.qml declares its PersistentProperties before its WlSessionLock,
//      binds `locked` to the persisted intent and never lets the restored intent downgrade a lock.
// Run by scripts/dev/test.sh offscreen (`qs -p tests/security/reload_order`): prints
// "reload-order: PASS" and exits 0, or "reload-order: FAIL <checks>" and exits 1.
ShellRoot {
    id: root

    settings.watchFiles: false

    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    function report(): void {
        if (failures.length === 0) {
            console.log("reload-order: PASS");
            Qt.exit(0);
        } else {
            console.log("reload-order: FAIL " + failures.join(", ") + " events=" + JSON.stringify(ReloadProbe.events));
            Qt.exit(1);
        }
    }

    function firstGeneration(): void {
        check("gen1-watchFiles-off", Quickshell.watchFiles === false);
        check("gen1-no-old-instance", !ReloadProbe.seenEarly && ReloadProbe.events.indexOf("early-loaded:false") !== -1);
        ReloadProbe.setIntents(true);
        if (failures.length > 0) {
            report();
            return;
        }
        Qt.callLater(() => Quickshell.reload(false));
    }

    // Runs after the whole reload pass (root first, then singletons).
    function secondGeneration(): void {
        const events = ReloadProbe.events;
        check("onCompleted-before-reload", events.indexOf("completed") === 0);
        check("intent-restored-before-sibling", events.indexOf("early-loaded:true") !== -1 && events.indexOf("early-loaded:true") < events.indexOf("standin-loaded:true"));
        check("binding-true-at-sibling-reload", ReloadProbe.seenEarly === true);
        check("later-sibling-restored-too-late", ReloadProbe.seenLate === false && ReloadProbe.lateIntent === true);
        check("gen2-watchFiles-off", Quickshell.watchFiles === false);
        lockSource.reload();
        lockSource.waitForJob();
        const text = String(lockSource.text());
        const persistAt = text.indexOf("PersistentProperties {");
        const lockAt = text.indexOf("WlSessionLock {");
        check("Lock.qml-readable", text.length > 0);
        check("Lock.qml-persist-before-WlSessionLock", persistAt !== -1 && lockAt !== -1 && persistAt < lockAt);
        check("Lock.qml-locked-bound-to-intent", /WlSessionLock \{[^}]*locked: persist\.intent/.test(text));
        // The restored old intent must not downgrade a lock taken in Component.onCompleted (R12 re-review).
        check("Lock.qml-intent-never-downgraded", /onLoaded: \{\s*intent = intent \|\| controller\.locked;/.test(text));
        // relock() releases the lock object before requesting a new one (not atomic): its only caller is
        // checkOwnership() on Machine.ownershipAction "relock", i.e. a confirmed "unlocked" answer (R12 review #3: the
        // lock() fast path relocked on one stale answer and keys reached a window).
        const code = text.replace(/\/\/[^\n]*/g, "");
        const calls = code.match(/[^\w.]relock\(/g) || [];
        check("Lock.qml-relock-defined-once", (code.match(/function relock\(/g) || []).length === 1);
        check("Lock.qml-relock-single-caller", calls.length === 2); // the definition and one call
        check("Lock.qml-relock-only-on-confirmed-answer", /else if \(action === "relock"\)\s*relock\(/.test(code));
        const lockFn = code.slice(code.indexOf("function lock(reason"), code.indexOf("function engage("));
        check("Lock.qml-lock-never-relocks", lockFn.length > 0 && lockFn.indexOf("relock(") === -1);
        // Defence in depth (R12 review #3 MAJOR): PAM is suppressed in a dev session unless GRASSFIELD_DEV_ALLOW_PAM=1.
        // ...and the lock shows it (a GRASSFIELD_DEV leaking into a real session is visible; the lock still fails closed).
        check("Lock.qml-dev-hint-on-lock", /controller\.pamSuppressed \? qsTr\("dev: password checks disabled"\)/.test(code));
        // SEC-03: the dev gate is DevGate (GRASSFIELD_DEV=1 and no GRASSFIELD_SESSION=1), never GRASSFIELD_DEV alone.
        check("Lock.qml-dev-pam-suppressed", /controller\.pamSuppressed = root\.devHooks && Quickshell\.env\("GRASSFIELD_DEV_ALLOW_PAM"\) !== "1";/.test(code));
        check("Lock.qml-devHooks-is-DevGate", /readonly property bool devHooks: DevGate\.allowed\(Quickshell\.env\("GRASSFIELD_DEV"\), Quickshell\.env\("GRASSFIELD_SESSION"\)\)/.test(code));
        // A lock inherited at start keeps the 100 ms check until relock() or release(): a foreign locker under this lock
        // can release it while this surface keeps the keyboard (R12 counter-review of 620f08c), so keyboard focus must not
        // end the suspicion. inheritedLock = false appears exactly in relock() and release().
        const clears = code.match(/inheritedLock = false;/g) || [];
        const relockFn = code.slice(code.indexOf("function relock("), code.indexOf("function checkOwnership("));
        const releaseFn = code.slice(code.indexOf("function release("), code.indexOf("function writeMarker("));
        check("Lock.qml-inherited-lock-cleared-only-by-relock-and-release", clears.length === 2 && relockFn.indexOf("inheritedLock = false;") !== -1 && releaseFn.indexOf("inheritedLock = false;") !== -1);
        report();
    }

    PersistentProperties {
        id: phase
        reloadableId: "phase"

        property int generation: 0

        onLoaded: {
            generation += 1;
            if (generation === 1)
                Qt.callLater(root.firstGeneration);
            else
                Qt.callLater(root.secondGeneration);
        }
    }

    FileView {
        id: lockSource
        path: Quickshell.shellDir + "/../../../shell/security/lock/Lock.qml"
        blockLoading: true
        printErrors: false
    }

    Connections {
        target: Quickshell

        function onReloadCompleted(): void {
            Quickshell.inhibitReloadPopup();
        }
    }

    // Instantiates the singleton during creation, as shell.qml does for Lock.
    Component.onCompleted: console.info("reload-order: generation start, probe events", ReloadProbe.events.length)

    Timer {
        running: true
        interval: 20000
        onTriggered: {
            root.failures.push("timeout");
            root.report();
        }
    }
}
