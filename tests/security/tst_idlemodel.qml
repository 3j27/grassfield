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
}
