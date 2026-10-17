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
        verify(!Machine.markerSaysLocked(""));
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
        // After an explicit unlock (intent cleared, marker "unlocked") and on a fresh session.
        verify(!Machine.restoreAtStart(false, true, "unlocked\n"));
        verify(!Machine.restoreAtStart(false, true, ""));
        verify(!Machine.restoreAtStart(undefined, true, undefined));
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
