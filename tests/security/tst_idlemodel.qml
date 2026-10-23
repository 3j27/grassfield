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

    function test_zeroDisables() {
        verify(!IdleModel.timings(0).enabled);
    }

    function test_invalidFallsBackToDefault() {
        const values = [-1, 241, 2.5, NaN, undefined, "x"];
        for (let i = 0; i < values.length; i++) {
            const t = IdleModel.timings(values[i]);
            verify(t.enabled, String(values[i]));
            compare(t.lockSeconds, 300, String(values[i]));
        }
    }

    // GF-030: a failing inhibitor or watcher is never given up; after MAX_FAST_FAILURES fast exits in a row the module is
    // degraded (the user is told) and retries slowly; a run of FAST_EXIT_MS resets the count.
    function test_failuresAfterExit() {
        compare(IdleModel.failuresAfterExit(0, 10), 1);
        compare(IdleModel.failuresAfterExit(4, 1999), 5);
        compare(IdleModel.failuresAfterExit(7, IdleModel.FAST_EXIT_MS), 0);
        compare(IdleModel.failuresAfterExit(3, 60000), 0);
        compare(IdleModel.failuresAfterExit(undefined, 5), 1);
        compare(IdleModel.failuresAfterExit(-2, 5), 1);
        compare(IdleModel.failuresAfterExit(2, NaN), 3, "unknown run time counts as a failure");
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

    function test_prepareForSleep() {
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"), true);
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"), false);
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('3', '/x')"), null);
        compare(IdleModel.prepareForSleep("Monitoring signals on object /org/freedesktop/login1"), null);
    }
}
