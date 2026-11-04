import QtQuick
import QtTest
import "../../shell/security/idle/IdleModel.js" as IdleModel
import "../../shell/security/LockMachine.js" as Machine

TestCase {
    name: "IdleModel"

    function test_defaultTimings() {
        const t = IdleModel.timings(5);
        verify(t.enabled);
        compare(t.lockSeconds, 300);
        compare(t.dimSeconds, 290);
        compare(t.lockDelayMs, 10000);
    }

    // GF-016: an application's org.freedesktop.ScreenSaver inhibitor holds the idle dim and lock; nothing else changes.
    function test_idleArmed() {
        verify(IdleModel.idleArmed(true, false, false, false));
        verify(!IdleModel.idleArmed(true, false, false, true), "inhibited over D-Bus");
        verify(!IdleModel.idleArmed(false, false, false, false), "idle lock off");
        verify(!IdleModel.idleArmed(true, true, false, false), "already locked");
        verify(!IdleModel.idleArmed(true, false, true, false), "re-arming");
        // Only an explicit true inhibits (a missing or odd value never disarms the idle lock).
        verify(IdleModel.idleArmed(true, false, false, undefined));
        verify(IdleModel.idleArmed(true, false, false, "true"));
        verify(IdleModel.idleArmed(true, false, false, 1));
    }

    function test_zeroDisables() {
        verify(!IdleModel.timings(0).enabled);
    }

    // Omarchy 4.0.6 drift review (docs/specs/security.md "Upstream base"): upstream stopped binding its lock timer's
    // interval to the settings, because a settings change restarted a pending timer and locked early or late. Idle.qml
    // still binds lockTimer.interval, which is safe only while that interval is the same for every enabled setting (a
    // change of lock.idleMinutes then never changes it) and the idle monitor's timeout is never 0 (idle at once).
    function test_lockDelaySameForEverySetting() {
        for (let m = 0; m <= IdleModel.MAX_MINUTES; m++) {
            const t = IdleModel.timings(m);
            verify(t.dimSeconds >= 1, "dimSeconds at " + m + " min: " + t.dimSeconds);
            if (m > 0)
                compare(t.lockDelayMs, IdleModel.DIM_LEAD_SECONDS * 1000, "lockDelayMs at " + m + " min");
        }
    }

    function test_invalidFallsBackToDefault() {
        // false, "0", "", null and [0] are 0 to Number(): they must never switch the lock off.
        const values = [-1, 241, 2.5, NaN, undefined, "x", false, true, "0", "5", "", null, [0], {}, 0.4, 0.49, -0.5, 1e-9, -2147483648, -1e308, Infinity, -Infinity];
        for (let i = 0; i < values.length; i++) {
            const t = IdleModel.timings(values[i]);
            verify(t.enabled, String(values[i]));
            compare(t.lockSeconds, 300, String(values[i]));
        }
    }

    // GF-030: a failing inhibitor or watcher is never given up; after MAX_FAST_FAILURES fast exits in a row the module is
    // degraded (the user is told) and retries slowly; a run of FAST_EXIT_MS resets the count.
    // Review of 2dfd992: whether the child ran FAST_EXIT_MS comes from a Timer (monotonic), never from the wall clock.
    function test_failuresAfterRun() {
        compare(IdleModel.failuresAfterRun(0, false), 1);
        compare(IdleModel.failuresAfterRun(4, false), 5);
        compare(IdleModel.failuresAfterRun(7, true), 0);
        compare(IdleModel.failuresAfterRun(undefined, false), 1);
        compare(IdleModel.failuresAfterRun(-2, false), 1);
        compare(IdleModel.failuresAfterRun(2, undefined), 3, "unknown counts as a failure");
        compare(IdleModel.failuresAfterRun(2, 1), 3, "only true resets");
        compare(IdleModel.failuresAfterRun(2, 60000), 3, "a duration is not an answer");
    }

    // Review of eee45cc: a child without progress within PROGRESS_BUDGET_MS is a failure; the budget leaves room for a
    // slow start but is far below the slow retry period.
    function test_progressBudget() {
        compare(IdleModel.PROGRESS_BUDGET_MS, 35000);
        verify(IdleModel.PROGRESS_BUDGET_MS > 25000, "above sd-bus' and GDBus' 25 s default call timeout");
        verify(IdleModel.PROGRESS_BUDGET_MS > IdleModel.FAST_EXIT_MS);
        verify(IdleModel.PROGRESS_BUDGET_MS < IdleModel.SLOW_RETRY_MS);
        compare(IdleModel.failuresAfterRun(4, false), 5, "a hung child stopped by the budget counts as a failure");
    }

    // Review of 100692f: gdbus' first line comes before the subscription; the owner line comes after it.
    function test_watcherSubscribed() {
        verify(IdleModel.watcherSubscribed("The name org.freedesktop.login1 is owned by :1.5"));
        verify(!IdleModel.watcherSubscribed("Monitoring signals on object /org/freedesktop/login1 owned by org.freedesktop.login1"));
        verify(!IdleModel.watcherSubscribed("The name org.freedesktop.login1 does not have an owner"));
        verify(!IdleModel.watcherSubscribed(""));
        verify(!IdleModel.watcherSubscribed(undefined));
    }

    function test_retryNeverStops() {
        for (let n = 0; n < 50; n++) {
            const delay = IdleModel.retryDelayMs(n);
            verify(delay > 0 && delay <= IdleModel.SLOW_RETRY_MS, "failures " + n);
            compare(delay, n >= IdleModel.MAX_FAST_FAILURES ? IdleModel.SLOW_RETRY_MS : IdleModel.FAST_RETRY_MS, "failures " + n);
            compare(IdleModel.degraded(n), n >= IdleModel.MAX_FAST_FAILURES, "failures " + n);
        }
    }

    // Port of Omarchy's derive_budget_ms: a fifth of logind's window (at least 1 s) kept for logind, capped at 12 s.
    function test_sleepBudget() {
        compare(IdleModel.sleepBudgetMs("t 5000000"), 4000);
        compare(IdleModel.sleepBudgetMs("t 15000000\n"), 12000);
        compare(IdleModel.sleepBudgetMs("t 10000000"), 8000);
        compare(IdleModel.sleepBudgetMs("t 60000000"), IdleModel.BUDGET_CAP_MS);
        compare(IdleModel.sleepBudgetMs("t 1000000"), 0);
        const unreadable = ["", "garbage", "t -5", "t 0", "u 5000000", undefined, null];
        for (let i = 0; i < unreadable.length; i++)
            compare(IdleModel.sleepBudgetMs(unreadable[i]), 4000, String(unreadable[i]));
    }

    function test_displayOffAfterLock() {
        verify(IdleModel.DISPLAY_OFF_SECONDS > 0 && IdleModel.DISPLAY_OFF_SECONDS <= 60);
    }

    // A lost "on" while a lock is being acquired is sent again before the lock before sleep runs out of time.
    function test_acquireDisplaysOnRetry() {
        verify(IdleModel.ACQUIRE_DISPLAYS_ON_MS > 0);
        verify(IdleModel.ACQUIRE_DISPLAYS_ON_MS < IdleModel.sleepBudgetMs(""));
        // A few tries, not one per 2 s all night.
        verify(IdleModel.ACQUIRE_DISPLAYS_ON_TRIES >= 2 && IdleModel.ACQUIRE_DISPLAYS_ON_TRIES <= 10);
    }

    // Settings > Lock Screen: Turn display off on battery / on power adapter when inactive (lock.displayOffBattery/Power).
    function test_inactiveDisplayOff() {
        compare(IdleModel.inactiveDisplayOffSeconds(2, 10, true), 120);
        compare(IdleModel.inactiveDisplayOffSeconds(2, 10, false), 600);
        // Not a known battery reading: the power adapter's delay.
        compare(IdleModel.inactiveDisplayOffSeconds(2, 10, undefined), 600);
        compare(IdleModel.inactiveDisplayOffSeconds(0, 10, true), 0);
        // Anything that is not a whole number of minutes in range is never (the lock does not depend on it).
        const bad = [-1, 0.5, 241, NaN, Infinity, "2", true, null, undefined, [2]];
        for (let i = 0; i < bad.length; i++)
            compare(IdleModel.inactiveDisplayOffSeconds(bad[i], bad[i], true), 0, String(bad[i]));
    }

    function test_inactiveOffArmed() {
        verify(IdleModel.inactiveOffArmed(120, false, false, false, false));
        verify(!IdleModel.inactiveOffArmed(0, false, false, false, false), "never");
        verify(!IdleModel.inactiveOffArmed(120, true, false, false, false), "locked: the lock screen's own delay");
        verify(IdleModel.inactiveOffArmed(120, true, true, false, false), "locked after it turned the displays off: they stay off");
        verify(!IdleModel.inactiveOffArmed(120, false, false, true, false), "re-arming");
        verify(!IdleModel.inactiveOffArmed(120, false, false, false, true), "an application inhibits idle");
        verify(IdleModel.inactiveOffArmed(120, false, false, false, "yes"), "only true inhibits");
    }

    function test_displaysOff() {
        // Unlocked: dark after the inactivity delay.
        verify(!IdleModel.displaysOff(false, false, false, false));
        verify(IdleModel.displaysOff(false, true, false, false));
        // The lock screen's own delay.
        verify(IdleModel.displaysOff(true, false, true, true));
        // A lock being acquired is never kept dark: the compositor must draw it to confirm it (review of 6e61829); once it
        // holds, a session that went dark for inactivity is dark again.
        verify(!IdleModel.displaysOff(false, true, true, false));
        verify(IdleModel.displaysOff(false, true, true, true));
        verify(!IdleModel.displaysOff(undefined, "yes", false, false));
    }

    function test_prepareForSleep() {
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"), true);
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"), false);
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('3', '/x')"), null);
        compare(IdleModel.prepareForSleep("Monitoring signals on object /org/freedesktop/login1"), null);
    }

    // ADR-0040 IQ-T4 A: when a display that turned off for inactivity locks the session.
    function test_requireAfterDisplayOffMs() {
        compare(IdleModel.requireAfterDisplayOffMs("immediately"), 0);
        compare(IdleModel.requireAfterDisplayOffMs("5s"), 5000);
        compare(IdleModel.requireAfterDisplayOffMs("1m"), 60000);
        compare(IdleModel.requireAfterDisplayOffMs("5m"), 300000);
        compare(IdleModel.requireAfterDisplayOffMs("15m"), 900000);
        compare(IdleModel.requireAfterDisplayOffMs("1h"), 3600000);
        compare(IdleModel.requireAfterDisplayOffMs("never"), -1);
        // Anything unknown: at once (the stricter choice).
        for (const v of ["", "2m", "Never", undefined, null, 5, "constructor", "toString"])
            compare(IdleModel.requireAfterDisplayOffMs(v), 0, String(v));
        verify(IdleModel.DIM_UNTIL_LOCK_MAX_MS > 0 && IdleModel.DIM_UNTIL_LOCK_MAX_MS <= 10000);
    }

    // ---- Automatic sleep (macOS 27 Energy / Battery > Options…: Prevent automatic sleeping when the display is off;
    // energy.preventSleep, default true; on battery and on the power adapter alike, integrator decision 2026-11-04). ----

    // Only an exact false lets the computer sleep, on battery as on the power adapter; anything else (the default, a value
    // that cannot be read) keeps it awake, as before the setting.
    function test_sleepPrevented() {
        verify(IdleModel.sleepPrevented(true), "the default: prevented");
        verify(!IdleModel.sleepPrevented(false), "switch off: sleeps");
        for (const v of [undefined, null, "false", 0, "", "no", [], {}])
            verify(IdleModel.sleepPrevented(v), "unreadable value " + JSON.stringify(v) + " keeps the computer awake");
        compare(IdleModel.sleepPrevented.length, 1, "no power source parameter: the switch applies on battery too");
        verify(IdleModel.AUTO_SLEEP_SECONDS >= 30 && IdleModel.AUTO_SLEEP_SECONDS <= 120);
    }

    // Armed only while this module has the displays off for lack of input, sleep is not prevented, and no application holds
    // an org.freedesktop.ScreenSaver inhibitor.
    function test_autoSleepArmed() {
        verify(IdleModel.autoSleepArmed(true, false, false));
        verify(!IdleModel.autoSleepArmed(true, true, false), "prevented");
        verify(!IdleModel.autoSleepArmed(false, false, false), "displays on");
        verify(!IdleModel.autoSleepArmed(true, false, true), "an application inhibits idle over D-Bus");
        // Fail awake: odd values never arm it.
        verify(!IdleModel.autoSleepArmed("true", false, false));
        verify(!IdleModel.autoSleepArmed(true, undefined, false), "an unknown prevention is not 'not prevented'");
        verify(!IdleModel.autoSleepArmed(true, 0, false));
        verify(IdleModel.autoSleepArmed(true, false, undefined), "no inhibitor reported");
    }

    // Grassfield suspends only in LOCKED with the lock secure (confirmed and verified); an exactly UNLOCKED session is locked
    // first; every other state waits. The states are LockMachine.js's own.
    function test_autoSleepAction() {
        compare(Machine.LOCKED, "locked");
        compare(Machine.UNLOCKED, "unlocked");
        compare(IdleModel.autoSleepAction(Machine.LOCKED, true), "suspend");
        compare(IdleModel.autoSleepAction(Machine.UNLOCKED, false), "lock");
        compare(IdleModel.autoSleepAction(Machine.UNLOCKED, true), "lock", "a stale secure never suspends an unlocked session");
        compare(IdleModel.autoSleepAction(Machine.LOCKING, false), "wait", "the compositor has not confirmed the lock yet");
        compare(IdleModel.autoSleepAction(Machine.LOCKED, false), "wait", "confirmed but not verified yet");
        compare(IdleModel.autoSleepAction(Machine.AUTHENTICATING, true), "wait", "a password or a fingerprint is being checked");
        compare(IdleModel.autoSleepAction(undefined, true), "wait");
        compare(IdleModel.autoSleepAction("LOCKED", true), "wait");
        compare(IdleModel.autoSleepAction(Machine.LOCKED, "true"), "wait");
    }

    // Review of 95dab794: a fingerprint success just before the 60 s mark moves the lock to RELEASING (the unlock's fade),
    // where Lock.holding and the secure lock are still true. No suspend may start then, at the decision or at the re-check
    // right before systemctl runs.
    function test_noSuspendDuringTheReleaseFade() {
        verify(Machine.isHolding(Machine.RELEASING), "the old decision's input (holding) was true here");
        compare(IdleModel.autoSleepAction(Machine.RELEASING, true), "wait");
        compare(IdleModel.autoSleepAction(Machine.RELEASING, false), "wait");
        // The whole fingerprint path, state by state: only LOCKED (before the success) suspends.
        const path = [Machine.LOCKED, Machine.AUTHENTICATING, Machine.RELEASING, Machine.UNLOCKED];
        compare(path.map(s => IdleModel.autoSleepAction(s, s !== Machine.UNLOCKED)), ["suspend", "wait", "wait", "lock"]);
    }

    // The idle decisions of a session whose displays went off for inactivity (unlocked) or on the lock screen (locked and
    // secure), with the switch on and off, on battery and on the power adapter: what Idle.qml derives from IdleModel.
    function decisions(prevent, onBattery, state) {
        const locked = state !== Machine.UNLOCKED;
        const t = IdleModel.timings(5);
        const prevented = IdleModel.sleepPrevented(prevent);
        const displaysOff = IdleModel.displaysOff(locked, !locked, locked, locked);
        const armed = IdleModel.autoSleepArmed(displaysOff, prevented, false);
        return {
            lock: {
                idleLock: t.enabled,
                lockSeconds: t.lockSeconds,
                idleArmed: IdleModel.idleArmed(t.enabled, locked, false, false),
                inactiveOffArmed: IdleModel.inactiveOffArmed(IdleModel.inactiveDisplayOffSeconds(2, 10, onBattery), locked, !locked, false, false),
                displayOffLockMs: IdleModel.requireAfterDisplayOffMs("immediately"),
                displaysOff: displaysOff
            },
            sleep: armed ? IdleModel.autoSleepAction(state, locked) : "none"
        };
    }

    // The idle lock, the display-off lock and the displays' power-off are the same whatever the switch says, on battery or
    // not; only the sleep differs. No lock function takes the setting: their arity is what it was before it (a new parameter
    // would have to be passed by Idle.qml, and reviewed).
    function test_lockIndependentOfSleep() {
        for (const onBattery of [false, true]) {
            for (const state of [Machine.UNLOCKED, Machine.LOCKED]) {
                const on = decisions(true, onBattery, state);
                const off = decisions(false, onBattery, state);
                const odd = decisions("x", onBattery, state);
                compare(off.lock, on.lock, "battery " + onBattery + ", " + state);
                compare(odd.lock, on.lock);
                verify(on.lock.idleLock && on.lock.lockSeconds === 300 && on.lock.displayOffLockMs === 0);
                verify(on.lock.displaysOff, "the displays still turn off with prevent-sleep on");
            }
        }
        compare(IdleModel.timings.length, 1);
        compare(IdleModel.idleArmed.length, 4);
        compare(IdleModel.inactiveOffArmed.length, 5);
        compare(IdleModel.inactiveDisplayOffSeconds.length, 3);
        compare(IdleModel.requireAfterDisplayOffMs.length, 1);
        compare(IdleModel.displaysOff.length, 4);
    }

    // The integrator decision of 2026-11-04: prevent-sleep on means no automatic sleep, on battery as on the power adapter;
    // off, an unlocked session is locked first and a locked one sleeps, on battery as on the power adapter.
    function test_idleDecisionsWithPreventSleep() {
        for (const onBattery of [false, true]) {
            const where = onBattery ? "battery" : "power adapter";
            compare(decisions(true, onBattery, Machine.UNLOCKED).sleep, "none", where + ", on, unlocked: no sleep");
            compare(decisions(true, onBattery, Machine.LOCKED).sleep, "none", where + ", on, locked: no suspend");
            compare(decisions(false, onBattery, Machine.UNLOCKED).sleep, "lock", where + ", off, unlocked: the lock first");
            compare(decisions(false, onBattery, Machine.LOCKED).sleep, "suspend", where + ", off, locked: suspend");
            compare(decisions(undefined, onBattery, Machine.LOCKED).sleep, "none", where + ": an unreadable setting keeps the computer awake");
        }
    }

    // The automatic sleep only ever ADDS a lock (review of 95dab794: it is the one path where energy.preventSleep leads to a
    // lock). Its answers are suspend, lock or wait over every state and secure value; "lock" only on an UNLOCKED session.
    function test_autoSleepOnlyAddsLocks() {
        const states = [Machine.UNLOCKED, Machine.LOCKING, Machine.LOCKED, Machine.AUTHENTICATING, Machine.RELEASING, "", undefined, null, "x"];
        for (const s of states) {
            for (const secure of [true, false, undefined, "true"]) {
                const a = IdleModel.autoSleepAction(s, secure);
                verify(["suspend", "lock", "wait"].indexOf(a) >= 0, String(s) + "/" + String(secure) + ": " + a);
                if (a === "lock")
                    compare(s, Machine.UNLOCKED, "a lock is only ever requested on an unlocked session");
            }
        }
        // In Idle.qml, the automatic sleep's block calls no Lock function that could unlock, release, abort or delay a lock,
        // and assigns nothing on Lock: its only Lock calls are lock("sleep") and the two read-only getters.
        const text = source();
        const begin = text.indexOf("// ---- Automatic sleep");
        const end = text.indexOf("SleepInhibitor {", begin);
        verify(begin > 0 && end > begin, "the automatic sleep block");
        const block = text.substring(begin, end);
        const calls = block.match(/Lock\.[A-Za-z]+\s*\(/g) || [];
        const kinds = calls.map(c => c.replace(/\s*\($/, "")).filter((c, i, all) => all.indexOf(c) === i).sort();
        compare(kinds, ["Lock.currentState", "Lock.currentlySecure", "Lock.lock"]);
        compare(block.match(/Lock\.lock\("[^"]*"\)/g) || [], ['Lock.lock("sleep")']);
        verify(!/Lock\.[A-Za-z]+\s*=[^=]/.test(block), "nothing assigned on Lock");
        verify(!/unlock|release\(|interruptRelease|abort\(/.test(block.replace(/\/\/[^\n]*/g, "")), "no unlock, release or abort");
    }

    // Review of 95dab794: a refused suspend (a download's sleep block inhibitor) is asked again while the displays stay off,
    // every AUTO_SLEEP_RETRY_MS, never in a tight loop; input disarms it.
    function test_autoSleepRetry() {
        compare(IdleModel.AUTO_SLEEP_RETRY_MS, 300000, "5 minutes");
        verify(IdleModel.AUTO_SLEEP_RETRY_MS >= 5 * IdleModel.AUTO_SLEEP_SECONDS * 1000, "never a tight loop");
        verify(IdleModel.autoSleepRetryArmed(true, true), "displays off, a request was made: retry");
        verify(!IdleModel.autoSleepRetryArmed(true, false), "nothing asked yet: the first request comes from the monitor");
        verify(!IdleModel.autoSleepRetryArmed(false, true), "input (displays on) or prevented: no retry");
        verify(!IdleModel.autoSleepRetryArmed("true", 1), "exact values only");
        // In Idle.qml: a repeating Timer of that interval, running only while armed and asked; it clears the request and
        // decides again (which re-reads the lock and the setting).
        const text = source();
        verify(/id: autoSleepRetry\s*\n\s*interval: IdleModel\.AUTO_SLEEP_RETRY_MS\s*\n\s*repeat: true\s*\n\s*running: IdleModel\.autoSleepRetryArmed\(root\.autoSleepArmed, root\.autoSleepAsked\)/.test(text));
        verify(/id: autoSleepRetry[\s\S]*?onTriggered: \{\s*root\.autoSleepAsked = false;\s*root\.autoSleepCheck\(\);\s*\}/.test(text));
        compare(text.split("\n").filter(l => l.indexOf("root.autoSleepAsked = false") >= 0).length, 3, "the period change, the retry, a re-check that refused");
    }

    function source() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/security/idle/Idle.qml"), false);
        xhr.send();
        verify(xhr.responseText.length > 1000, "Idle.qml read (QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    // Idle.qml: the idle lock and display-off lock paths never read the sleep setting (a source check); the one lock the
    // automatic sleep can request is pinned by test_autoSleepOnlyAddsLocks.
    function test_idleQmlLockPathsIgnoreSleep() {
        const text = source();
        const lines = text.split("\n");
        const lockLines = lines.filter(l => /IdleModel\.(timings|idleArmed|inactiveOffArmed|inactiveDisplayOffSeconds|requireAfterDisplayOffMs|displaysOff)\(|Lock\.lock\("(idle|display-off)"\)/.test(l));
        verify(lockLines.length >= 6, "found the lock paths: " + lockLines.length);
        for (const l of lockLines)
            verify(!/preventSleep|sleepPrevented|autoSleep/.test(l), "a lock path reads the sleep setting: " + l.trim());
        // The setting is read in exactly two places: the binding and the fresh check before acting.
        compare(lines.filter(l => l.indexOf("Settings.energyPreventSleep") >= 0).length, 2);
        // The suspend is asked for only on the "suspend" answer, re-read right before systemctl, and never in the dev session.
        verify(/if \(root\.devHooks\) \{\s*root\.autoSleepSuppressed\+\+;/.test(text));
        compare(lines.filter(l => l.indexOf("autoSleepRequest.running = true") >= 0).length, 1);
        verify(/if \(IdleModel\.autoSleepAction\(Lock\.currentState\(\), Lock\.currentlySecure\(\)\) !== "suspend"\) \{\s*root\.autoSleepAsked = false;\s*return;\s*\}\s*console\.info\([^\n]*\);\s*autoSleepRequest\.running = true;/.test(text),
               "the state is read again right before systemctl runs");
        verify(!/autoSleepAction\([^)]*holding/.test(text), "the decision never uses the holding binding");
        // logind's own suspend, never with --ignore-inhibitors (-i) and never asking for authorization behind the lock.
        verify(text.indexOf('command: ["systemctl", "--no-ask-password", "suspend"]') >= 0);
        verify(!/systemctl[^\n]*(-i\b|--ignore-inhibitors|--force|-f\b)/.test(text));
    }
}
