import QtQuick
import QtTest
import "../../shell/services/WallClock.js" as Tick

// The wall clock's next tick comes from epoch milliseconds only (shell/services/WallClock.qml): never negative, never
// zero, at most the cap, and the same whatever the time zone or daylight saving time does (Quickshell 0.3.1's
// SystemClock spun at 1 ms in the repeated hour of the 2026-10-25 fall-back).
TestCase {
    name: "WallClock"

    readonly property int minute: 60000
    readonly property int second: 1000
    readonly property int cap: 10000

    function test_nextMinuteFromTheEpochMinute() {
        // 2026-10-25T01:25:30.250Z: 29.75 s to the next minute, capped at 10 s.
        const t = Date.UTC(2026, 9, 25, 1, 25, 30, 250);
        compare(Tick.msToNext(t, minute, cap), cap);
        compare(Tick.msToNext(t, minute, 60000), 29750 + 2);
    }

    function test_nextSecond() {
        const t = Date.UTC(2026, 9, 25, 1, 25, 30, 250);
        compare(Tick.msToNext(t, second, cap), 750 + 2);
    }

    function test_onTheBoundaryWaitsAWholeUnit() {
        const t = Date.UTC(2026, 9, 25, 1, 26, 0, 0);
        compare(Tick.msToNext(t, second, cap), 1000 + 2);
        compare(Tick.msToNext(t, minute, 120000), 60000 + 2);
    }

    function test_neverBelowOneNorAboveTheCap() {
        // Every millisecond of a minute, and the instants around the 2026-10-25 fall-back (01:00 UTC) and the 2027-03-28
        // spring-forward (01:00 UTC) in steps of 7 ms.
        const starts = [Date.UTC(2026, 9, 25, 0, 59, 0, 0), Date.UTC(2027, 2, 28, 0, 59, 0, 0)];
        for (const s of starts) {
            for (let t = s; t < s + 2 * minute; t += 7) {
                const m = Tick.msToNext(t, minute, cap);
                const n = Tick.msToNext(t, second, cap);
                if (m < 1 || m > cap || n < 1 || n > second + 2)
                    fail("bad wait at " + t + ": minute " + m + ", second " + n);
            }
        }
        verify(Tick.msToNext(-1, minute, cap) >= 1, "an instant before the epoch still gives a positive wait");
    }

    function test_unitIndexChangesOnTheBoundary() {
        const t = Date.UTC(2026, 9, 25, 1, 59, 59, 999);
        verify(Tick.unitIndex(t, minute) !== Tick.unitIndex(t + 1, minute));
        compare(Tick.unitIndex(t, minute), Tick.unitIndex(t - 59999, minute));
    }

    // The fall-back hour happens twice in local time; epoch arithmetic does not see it: the waits around 01:00 UTC are
    // the same as an hour before or after.
    function test_sameWaitsAcrossTheFallBack() {
        const at = Date.UTC(2026, 9, 25, 1, 0, 0, 0);
        for (let d = -90000; d <= 90000; d += 1250)
            compare(Tick.msToNext(at + d, minute, 120000), Tick.msToNext(at + d - 3600000, minute, 120000));
    }
}
