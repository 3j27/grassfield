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

    // Follow-up N1: the marker records the kernel's count of completed suspends; a restarted shell locks when the
    // machine slept since an "unlocked" line was written (a crash or restart right before or during that sleep).
    function test_markerWithSleepCount() {
        compare(Machine.markerLine("unlocked", 12), "unlocked sleeps=12");
        compare(Machine.markerLine("locked", 0), "locked sleeps=0");
        compare(Machine.markerLine("unlocked", -1), "unlocked");
        compare(Machine.markerLine("locked", NaN), "locked");
        compare(Machine.markerLine("garbage", 3), "locked sleeps=3", "anything unknown is written as locked");
        compare(Machine.parseSleepCount("7\n"), 7);
        compare(Machine.parseSleepCount(" 0 "), 0);
        const bad = ["", "x", "-1", "1.5", "12 13", undefined, null];
        for (let i = 0; i < bad.length; i++)
            compare(Machine.parseSleepCount(bad[i]), -1, String(bad[i]));
        verify(!Machine.markerSaysLocked("unlocked sleeps=12\n"));
        verify(Machine.markerSaysLocked("locked sleeps=12\n"));
        verify(Machine.markerSaysLocked("unlocked sleeps=\n"));
        verify(Machine.markerSaysLocked("unlocked sleeps=-1"));
        verify(Machine.markerSaysLocked("unlocked sleeps=12 extra"));
        // Slept since the unlocked line: lock. Same count, unknown counts, an old line without a count: no evidence.
        verify(Machine.sleptSince("unlocked sleeps=12\n", 13));
        verify(!Machine.sleptSince("unlocked sleeps=12\n", 12));
        verify(!Machine.sleptSince("unlocked sleeps=12\n", -1));
        verify(!Machine.sleptSince("unlocked sleeps=12\n", undefined));
        verify(!Machine.sleptSince("unlocked\n", 13));
        verify(!Machine.sleptSince(null, 13));
        verify(Machine.restoreAtStart(false, true, "unlocked sleeps=12\n", 13));
        verify(Machine.restoreAtStart(false, true, "unlocked sleeps=12\n", 11), "a lower count (reboot of the counter) is a difference too");
        verify(!Machine.restoreAtStart(false, true, "unlocked sleeps=12\n", 12));
        verify(!Machine.restoreAtStart(false, true, "unlocked sleeps=12\n", -1));
        verify(Machine.restoreAtStart(false, true, "locked sleeps=12\n", 12));
        verify(!Machine.restoreAtStart(false, true, null, 13), "fresh session (no marker): unlocked");
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

    // Review of the lock's monitor queries (Quickshell 0.3.1, read in its source): a query from QML never creates a monitor
    // object and, sent before Hyprland answered Quickshell's own first query, leaves Hyprland.monitors empty until a monitor
    // event. The lock sends none while the model is empty (Lock.qml requestMonitors); an empty model is an unknown lock
    // state, never "unlocked": no relock, no "nothing stranded", WlSessionLock keeps the session locked (fail closed).
    function test_monitorQueryAllowed() {
        compare(Machine.monitorQueryAllowed(0), false);
        compare(Machine.monitorQueryAllowed(1), true);
        compare(Machine.monitorQueryAllowed(2), true);
        // Anything that is not a positive count is an empty model: no query.
        const empty = [undefined, null, NaN, -1, 0.5, "2", true, [1], {}];
        for (let i = 0; i < empty.length; i++)
            compare(Machine.monitorQueryAllowed(empty[i]), false, String(empty[i]));
        // The state an empty model gives, whatever its (absent) monitors would say.
        const unlocked = () => ({solitaryBlockedBy: ["WINDOWED"]});
        compare(Machine.compositorLockStateLazy(0, unlocked), "unknown");
        compare(Machine.compositorLockState([]), "unknown");
        compare(Machine.ownershipAction(Machine.compositorLockStateLazy(0, unlocked), 0), "unknown");
        compare(Machine.ownershipAction(Machine.compositorLockStateLazy(0, unlocked), 1), "unknown");
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

    // Review of 423766f: the account picture is only ever a PNG the shell made (ThemeIcons), ~/.face first.
    function test_avatarSource() {
        const made = {"/home/a/.face": "file:///run/x/1.png", "/var/lib/AccountsService/icons/a": "file:///run/x/2.png"};
        let states = {};
        const asked = [];
        const source = p => {
            asked.push(p);
            return states[p] === "ok" ? made[p] : "";
        };
        const state = p => states[p] || "";
        compare(Machine.avatarSource("/home/a/.face", "/var/lib/AccountsService/icons/a", source, state), "", "nothing made yet: the initials");
        compare(asked, ["/home/a/.face"], "the AccountsService picture is not asked while ~/.face is pending");
        states = {"/home/a/.face": "ok"};
        compare(Machine.avatarSource("/home/a/.face", "/var/lib/AccountsService/icons/a", source, state), "file:///run/x/1.png");
        states = {"/home/a/.face": "no", "/var/lib/AccountsService/icons/a": "ok"};
        compare(Machine.avatarSource("/home/a/.face", "/var/lib/AccountsService/icons/a", source, state), "file:///run/x/2.png", "~/.face refused: AccountsService");
        states = {"/home/a/.face": "no", "/var/lib/AccountsService/icons/a": "no"};
        compare(Machine.avatarSource("/home/a/.face", "/var/lib/AccountsService/icons/a", source, state), "", "both refused: the initials");
        states = {"/var/lib/AccountsService/icons/a": "ok"};
        compare(Machine.avatarSource("", "/var/lib/AccountsService/icons/a", source, state), "file:///run/x/2.png", "no HOME");
        compare(Machine.avatarSource("", "", source, state), "");
        compare(Machine.accountsIconPath("ada"), "/var/lib/AccountsService/icons/ada");
        ["", "../root", ".hidden", "a/b", "a\nb", null, undefined, "x".repeat(65)].forEach(u => compare(Machine.accountsIconPath(u), "", "refused: " + u));
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

    // Lock.currentlySecure() (Omarchy 4.0.6 port): only locked/authenticating hold a lock; anything else waits.
    function test_isHolding() {
        verify(Machine.isHolding("locked"));
        verify(Machine.isHolding("authenticating"));
        const others = ["unlocked", "locking", "", "LOCKED", undefined, null, "garbage"];
        for (let i = 0; i < others.length; i++)
            verify(!Machine.isHolding(others[i]), String(others[i]));
    }

    // D-4: the lid locks unless a physical external display is active (clamshell, macOS); unreadable input locks.
    function test_lidShouldLock() {
        verify(Machine.lidShouldLock(["eDP-1"]));
        verify(Machine.lidShouldLock([]));
        verify(Machine.lidShouldLock(["eDP-1", "HEADLESS-1"]), "a headless output is not a display in use");
        verify(Machine.lidShouldLock(["WAYLAND-1", "GF-REF"]), "nested outputs are not external displays");
        verify(Machine.lidShouldLock(["LVDS-1", "DSI-1"]));
        verify(Machine.lidShouldLock(["eDP-1", "DPX-1", "HDMI-1", "dp-1", "DP-"]), "not a DRM connector name");
        verify(Machine.lidShouldLock(undefined));
        verify(Machine.lidShouldLock(null));
        verify(Machine.lidShouldLock("DP-1"), "a string is not a list of names");
        const docked = [["eDP-1", "DP-1"], ["DP-3"], ["eDP-1", "HDMI-A-1"], ["eDP-1", "DVI-D-2"], ["VGA-1"], ["eDP-1", "USB-1"]];
        for (let i = 0; i < docked.length; i++)
            verify(!Machine.lidShouldLock(docked[i]), docked[i].join(","));
    }
}
