import QtQuick
import QtTest
import "../../shell/security/idle/IdleModel.js" as IdleModel

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

    // ---- Automatic sleep (macOS 27 Energy / Battery > Options: Prevent automatic sleeping [on power adapter] when the
    // display is off; energy.preventSleep, default true). ----

    // On battery the computer always sleeps (macOS); on the power adapter or without a battery only an exact false lets it.
    // Anything else (the default, a value that cannot be read, an unknown power source) keeps it awake, as before the setting.
    function test_sleepPrevented() {
        verify(IdleModel.sleepPrevented(true, false), "prevented on the power adapter");
        verify(!IdleModel.sleepPrevented(false, false), "switch off: sleeps on the power adapter");
        verify(!IdleModel.sleepPrevented(true, true), "battery: sleeps whatever the switch says");
        verify(!IdleModel.sleepPrevented(false, true));
        for (const v of [undefined, null, "false", 0, "", "no", [], {}])
            verify(IdleModel.sleepPrevented(v, false), "unreadable value " + JSON.stringify(v) + " keeps the computer awake");
        // UPower unknown: anything but an exact true is the power adapter, where the switch decides.
        for (const b of [undefined, null, "true", 1])
            verify(IdleModel.sleepPrevented(true, b), "unknown source " + JSON.stringify(b));
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

    // Grassfield suspends only while its own lock holds; an unlocked session is locked first; a lock being acquired waits.
    function test_autoSleepAction() {
        compare(IdleModel.autoSleepAction(true, true), "suspend");
        compare(IdleModel.autoSleepAction(false, false), "lock");
        compare(IdleModel.autoSleepAction(true, false), "wait", "the compositor has not confirmed the lock yet");
        compare(IdleModel.autoSleepAction(false, true), "lock", "a stale holding never suspends an unlocked session");
        compare(IdleModel.autoSleepAction(undefined, true), "lock");
        compare(IdleModel.autoSleepAction(true, "true"), "wait");
        compare(IdleModel.autoSleepAction(1, 1), "lock");
    }

    // The idle decisions of a session whose displays went off for inactivity (unlocked) or on the lock screen (locked and
    // holding), with the switch on and off, on battery and on the power adapter: what Idle.qml derives from IdleModel.
    function decisions(prevent, onBattery, locked, holding) {
        const t = IdleModel.timings(5);
        const prevented = IdleModel.sleepPrevented(prevent, onBattery);
        const displaysOff = IdleModel.displaysOff(locked, !locked, locked, holding);
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
            sleep: armed ? IdleModel.autoSleepAction(locked, holding) : "none"
        };
    }

    // Lock still happens: with prevent-sleep on or off, on battery or not, every lock decision is the same (the idle lock at
    // 5 minutes, the display-off lock at once, the displays off); only the sleep differs. And no lock function takes the
    // setting: their arity is what it was before it (a new parameter would have to be passed by Idle.qml, and reviewed).
    function test_lockIndependentOfSleep() {
        for (const onBattery of [false, true]) {
            for (const state of [[false, false], [true, true]]) {
                const on = decisions(true, onBattery, state[0], state[1]);
                const off = decisions(false, onBattery, state[0], state[1]);
                const odd = decisions("x", onBattery, state[0], state[1]);
                compare(off.lock, on.lock, "battery " + onBattery + ", locked " + state[0]);
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

    // Prevent-sleep on: no automatic sleep on the power adapter; off: an unlocked session is locked first, a locked one
    // sleeps. On battery the computer sleeps either way.
    function test_idleDecisionsWithPreventSleep() {
        compare(decisions(true, false, false, false).sleep, "none");
        compare(decisions(true, false, true, true).sleep, "none");
        compare(decisions(false, false, false, false).sleep, "lock");
        compare(decisions(false, false, true, true).sleep, "suspend");
        compare(decisions(true, true, false, false).sleep, "lock");
        compare(decisions(true, true, true, true).sleep, "suspend");
        compare(decisions(undefined, false, true, true).sleep, "none", "an unreadable setting keeps the computer awake");
    }

    // Idle.qml: the lock paths never read the sleep setting (a source check, comments included in what is read).
    function test_idleQmlLockPathsIgnoreSleep() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/security/idle/Idle.qml"), false);
        xhr.send();
        const text = xhr.responseText;
        verify(text.length > 1000, "Idle.qml read (QML_XHR_ALLOW_FILE_READ=1)");
        const lines = text.split("\n");
        const lockLines = lines.filter(l => /IdleModel\.(timings|idleArmed|inactiveOffArmed|inactiveDisplayOffSeconds|requireAfterDisplayOffMs|displaysOff)\(|Lock\.lock\("(idle|display-off)"\)/.test(l));
        verify(lockLines.length >= 6, "found the lock paths: " + lockLines.length);
        for (const l of lockLines)
            verify(!/preventSleep|sleepPrevented|autoSleep/.test(l), "a lock path reads the sleep setting: " + l.trim());
        // The setting is read in exactly two places: the binding and the fresh check before acting.
        compare(lines.filter(l => l.indexOf("Settings.energyPreventSleep") >= 0).length, 2);
        // The suspend is asked for only on the "suspend" answer, and never in the dev session.
        verify(/if \(root\.devHooks\) \{\s*root\.autoSleepSuppressed\+\+;/.test(text));
        compare(lines.filter(l => l.indexOf("autoSleepRequest.running = true") >= 0).length, 1);
    }
}
