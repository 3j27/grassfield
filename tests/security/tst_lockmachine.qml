import QtQuick
import QtTest
import "../../shell/security/LockMachine.js" as Machine

// Lock state machine (ADR-0010): only a PAM success reaches "unlocked".
TestCase {
    name: "LockMachine"

    function test_happyPath() {
        let s = Machine.UNLOCKED;
        s = Machine.next(s, "request");
        compare(s, "locking");
        s = Machine.next(s, "acquired");
        compare(s, "locked");
        s = Machine.next(s, "submit");
        compare(s, "authenticating");
        s = Machine.next(s, "success");
        compare(s, "unlocked");
    }

    function test_failuresReturnToLocked() {
        const events = ["failure", "error", "timeout", "abort"];
        for (let i = 0; i < events.length; i++)
            compare(Machine.next("authenticating", events[i]), "locked", events[i]);
    }

    // Exhaustive: from any locked state, no event except a PAM success unlocks.
    function test_onlyPamSuccessUnlocks() {
        const lockedStates = ["locking", "locked", "authenticating"];
        for (let i = 0; i < lockedStates.length; i++) {
            for (let j = 0; j < Machine.EVENTS.length; j++) {
                const event = Machine.EVENTS[j];
                const after = Machine.next(lockedStates[i], event);
                if (after === "unlocked")
                    verify(event === "success" && lockedStates[i] === "authenticating" || event === "fingerprint" && lockedStates[i] !== "locking", lockedStates[i] + " + " + event);
            }
        }
    }

    function test_successOutsideAuthenticationIsIgnored() {
        compare(Machine.next("locked", "success"), "locked");
        compare(Machine.next("locking", "success"), "locking");
        compare(Machine.next("locking", "fingerprint"), "locking");
    }

    function test_unknownEventsAndStatesFailClosed() {
        compare(Machine.next("locked", "bogus"), "locked");
        compare(Machine.next("authenticating", ""), "authenticating");
        compare(Machine.next("garbage", "success"), "locking");
        compare(Machine.next(undefined, "request"), "locking");
    }

    function test_lostLockIsReacquired() {
        compare(Machine.next("locked", "lost"), "locking");
        compare(Machine.next("authenticating", "lost"), "locking");
        compare(Machine.next("unlocked", "lost"), "unlocked");
    }

    function test_submitOnlyWhenLocked() {
        compare(Machine.next("locking", "submit"), "locking");
        compare(Machine.next("unlocked", "submit"), "unlocked");
        compare(Machine.next("authenticating", "submit"), "authenticating");
    }

    function test_marker() {
        verify(Machine.markerSaysLocked("locked\n"));
        verify(Machine.markerSaysLocked("garbage"));
        verify(!Machine.markerSaysLocked("unlocked\n"));
        verify(!Machine.markerSaysLocked("  unlocked  "));
        verify(Machine.markerSaysLocked("unlocked locked"));
        // Existing but empty or unreadable (markerRead gives ""): not exactly "unlocked" -> lock.
        verify(Machine.markerSaysLocked(""));
        // Missing (markerRead gives null): the first start of this compositor instance.
        verify(!Machine.markerSaysLocked(null));
        verify(!Machine.markerSaysLocked(undefined));
        compare(Machine.markerName("abc_123_4", "wayland-1"), "grassfield-lock-abc_123_4");
        compare(Machine.markerName("", "/run/user/1000/wayland-1"), "grassfield-lock-_run_user_1000_wayland-1");
        compare(Machine.markerName("", ""), "grassfield-lock-default");
    }

    // Start/reload decision (R12 review blocker): fail closed; only a proven unlock starts unlocked.
    function test_restoreAtStart() {
        // Soft reload while locked: the carried intent wins over a missing or forged marker.
        verify(Machine.restoreAtStart(true, true, ""));
        verify(Machine.restoreAtStart(true, true, "unlocked\n"));
        verify(Machine.restoreAtStart(true, false, ""));
        // Crash restart: the marker decides.
        verify(Machine.restoreAtStart(false, true, "locked\n"));
        verify(Machine.restoreAtStart(false, true, "garbage"));
        // No XDG_RUNTIME_DIR: nothing can prove the session unlocked.
        verify(Machine.restoreAtStart(false, false, ""));
        verify(Machine.restoreAtStart(false, undefined, "unlocked\n"));
        // Unreadable marker (mode 000, a directory, I/O error): proves nothing -> lock (R12 re-review).
        verify(Machine.restoreAtStart(false, true, Machine.markerRead(false, true, "")));
        verify(Machine.restoreAtStart(false, true, ""));
        // After an explicit unlock (intent cleared, marker "unlocked") and on a fresh session.
        verify(!Machine.restoreAtStart(false, true, "unlocked\n"));
        verify(!Machine.restoreAtStart(false, true, Machine.markerRead(true, true, "")));
        verify(!Machine.restoreAtStart(false, true, null));
        verify(!Machine.restoreAtStart(undefined, true, undefined));
    }

    // FileView result -> marker content: only FileNotFound is "missing"; any other failure is "".
    function test_markerRead() {
        compare(Machine.markerRead(true, true, ""), null);
        compare(Machine.markerRead(false, false, "unlocked\n"), "unlocked\n");
        compare(Machine.markerRead(false, false, "locked\n"), "locked\n");
        // Permission denied / not a file / unknown error: the text is never trusted.
        compare(Machine.markerRead(false, true, ""), "");
        compare(Machine.markerRead(false, true, "unlocked\n"), "");
        compare(Machine.markerRead(false, undefined, "unlocked\n"), "");
        compare(Machine.markerRead(undefined, undefined, "unlocked\n"), "");
        compare(Machine.markerRead(false, false, null), "");
        verify(Machine.markerSaysLocked(Machine.markerRead(false, true, "unlocked\n")));
        verify(!Machine.markerSaysLocked(Machine.markerRead(false, false, "unlocked\n")));
        verify(!Machine.markerSaysLocked(Machine.markerRead(true, true, "")));
    }

    // Lock watchdog (R12 re-review): a session found unlocked under a lock still reported secure is
    // re-locked after a confirming answer; a locked session (ours or a foreign locker's) is left alone.
    function test_ownershipAction() {
        compare(Machine.ownershipAction("locked", 0), "ok");
        compare(Machine.ownershipAction("locked", 5), "ok");
        compare(Machine.ownershipAction("unlocked", 0), "confirm");
        compare(Machine.ownershipAction("unlocked", 1), "relock");
        compare(Machine.ownershipAction("unlocked", 3), "relock");
        compare(Machine.ownershipAction("unknown", 0), "unknown");
        compare(Machine.ownershipAction("unknown", 2), "unknown");
        compare(Machine.ownershipAction(undefined, 1), "unknown");
        // Never "relock" without an "unlocked" answer; never anything that unlocks.
        const states = ["locked", "unlocked", "unknown", "", null];
        for (let i = 0; i < states.length; i++) {
            for (let n = 0; n < 3; n++) {
                const a = Machine.ownershipAction(states[i], n);
                verify(["ok", "unknown", "confirm", "relock"].indexOf(a) !== -1, a);
                if (a === "relock")
                    verify(states[i] === "unlocked" && n >= 1, states[i] + " " + n);
            }
        }
        // Answers as Hyprland 0.56 gives them, before and after a foreign locker released the session.
        compare(Machine.ownershipAction(Machine.compositorLockState([{solitaryBlockedBy: ["LOCK", "WINDOWED", "CANDIDATE"]}]), 0), "ok");
        compare(Machine.ownershipAction(Machine.compositorLockState([{solitaryBlockedBy: ["WINDOWED", "CANDIDATE"]}]), 1), "relock");
    }

    // Suspected takeover (R12 review #3): the probe runs every 100 ms while no lock surface of this
    // shell has the keyboard or the lock was inherited at start; 1 s only when both are known false.
    function test_takeoverSuspected() {
        compare(Machine.takeoverSuspected(true, false), false);
        verify(Machine.takeoverSuspected(false, false));
        verify(Machine.takeoverSuspected(true, true));
        verify(Machine.takeoverSuspected(false, true));
        // Unknown inputs never slow the probe down.
        verify(Machine.takeoverSuspected(undefined, false));
        verify(Machine.takeoverSuspected(true, undefined));
        verify(Machine.takeoverSuspected(1, false));
        verify(Machine.takeoverSuspected(null, null));
        compare(Machine.probeInterval(false), 1000);
        compare(Machine.probeInterval(true), 100);
        compare(Machine.probeInterval(undefined), 100);
        compare(Machine.probeInterval(0), 100);
        verify(Machine.PROBE_SUSPECTED_MS < Machine.PROBE_INTERVAL_MS);
        verify(Machine.PROBE_SUSPECTED_MS <= 100);
    }

    // Hyprland 0.56 `hyprctl -j monitors` shapes (verified in nested: LOCK stays after the lock
    // client is killed).
    function test_compositorLockState() {
        compare(Machine.compositorLockState([{name: "A", solitaryBlockedBy: ["LOCK", "WINDOWED", "CANDIDATE"]}]), "locked");
        compare(Machine.compositorLockState([{solitaryBlockedBy: ["WORKSPACE"]}, {solitaryBlockedBy: ["WINDOWED", "LOCK"]}]), "locked");
        compare(Machine.compositorLockState([{solitaryBlockedBy: ["WINDOWED", "CANDIDATE"]}]), "unlocked");
        // A monitor without a workspace stops the list before LOCK: proves nothing.
        compare(Machine.compositorLockState([{solitaryBlockedBy: ["WORKSPACE"]}]), "unknown");
        compare(Machine.compositorLockState([{solitaryBlockedBy: ["WORKSPACE"]}, {solitaryBlockedBy: []}]), "unlocked");
        compare(Machine.compositorLockState([]), "unknown");
        compare(Machine.compositorLockState(undefined), "unknown");
        compare(Machine.compositorLockState([null, {}, {solitaryBlockedBy: "LOCK"}]), "unknown");
    }

    // Lazy reading (R12 counter-review: per-probe garbage of the 100 ms check): same answers as compositorLockState for
    // every shape, and while locked only the first monitor's IPC object is read.
    function test_compositorLockStateLazy() {
        const shapes = [
            [{solitaryBlockedBy: ["LOCK", "WINDOWED", "CANDIDATE"]}],
            [{solitaryBlockedBy: ["WORKSPACE"]}, {solitaryBlockedBy: ["WINDOWED", "LOCK"]}],
            [{solitaryBlockedBy: ["WINDOWED", "CANDIDATE"]}],
            [{solitaryBlockedBy: ["WORKSPACE"]}],
            [{solitaryBlockedBy: ["WORKSPACE"]}, {solitaryBlockedBy: []}],
            [],
            [null, {}, {solitaryBlockedBy: "LOCK"}],
            [{solitaryBlockedBy: ["WINDOWED"]}, {solitaryBlockedBy: ["LOCK"]}],
            [{solitaryBlockedBy: ["LOCK"]}, {solitaryBlockedBy: ["WINDOWED"]}]
        ];
        for (let k = 0; k < shapes.length; k++) {
            const list = shapes[k];
            compare(Machine.compositorLockStateLazy(list.length, i => list[i]), Machine.compositorLockState(list), JSON.stringify(list));
        }
        // Locked on the first monitor: the second is never read.
        let reads = [];
        const locked = [{solitaryBlockedBy: ["LOCK"]}, {solitaryBlockedBy: ["LOCK"]}];
        compare(Machine.compositorLockStateLazy(2, i => { reads.push(i); return locked[i]; }), "locked");
        compare(reads, [0]);
        // Unlocked: every monitor is read (a later LOCK would still win), each once, in order.
        reads = [];
        const unlocked = [{solitaryBlockedBy: ["WINDOWED"]}, {solitaryBlockedBy: ["CANDIDATE"]}];
        compare(Machine.compositorLockStateLazy(2, i => { reads.push(i); return unlocked[i]; }), "unlocked");
        compare(reads, [0, 1]);
        // Bad counts read nothing and prove nothing.
        compare(Machine.compositorLockStateLazy(undefined, i => locked[i]), "unknown");
        compare(Machine.compositorLockStateLazy(0, i => locked[i]), "unknown");
    }

    function test_displayNameAndInitials() {
        const passwd = "root:x:0:0::/root:/bin/bash\nada:x:1000:1000:Ada Lovelace,,,:/home/ada:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/sh\n";
        compare(Machine.displayName(passwd, "ada"), "Ada Lovelace");
        compare(Machine.displayName(passwd, "bob"), "bob");
        compare(Machine.displayName(passwd, "eve"), "eve");
        compare(Machine.initials("Ada Lovelace"), "AL");
        compare(Machine.initials("chapdel"), "C");
        compare(Machine.initials("  "), "");
    }

    function test_capsLockInference() {
        compare(Machine.capsLockFromKey("A", false), true);
        compare(Machine.capsLockFromKey("a", false), false);
        compare(Machine.capsLockFromKey("a", true), true);
        compare(Machine.capsLockFromKey("A", true), false);
        compare(Machine.capsLockFromKey("1", false), null);
        compare(Machine.capsLockFromKey("", false), null);
    }

    function test_clockFormat() {
        compare(Machine.clockFormat("h:mm AP"), "h:mm");
        compare(Machine.clockFormat("HH:mm"), "H:mm");
    }
}
