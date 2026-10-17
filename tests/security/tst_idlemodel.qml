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

    function test_prepareForSleep() {
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"), true);
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"), false);
        compare(IdleModel.prepareForSleep("/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('3', '/x')"), null);
        compare(IdleModel.prepareForSleep("Monitoring signals on object /org/freedesktop/login1"), null);
    }
}
