import QtQuick
import QtTest
import "../../shell/dock/Magnify.js" as Magnify

TestCase {
    name: "Magnify"

    function test_peakAtPointer() {
        fuzzyCompare(Magnify.scale(0, 52, 1.6, 3), 1.6, 1e-9);
    }

    function test_noEffectAtAndBeyondReach() {
        compare(Magnify.scale(3 * 52, 52, 1.6, 3), 1);
        compare(Magnify.scale(-500, 52, 1.6, 3), 1);
    }

    function test_smootherstepProfile() {
        // Halfway to the reach the bump is at half height; a quarter of the way it is NOT the cosine's 0.8536.
        fuzzyCompare(Magnify.scale(1.5 * 52, 52, 1.6, 3), 1.3, 1e-9);
        const t = 0.25;
        const smoother = 10 * t * t * t - 15 * t * t * t * t + 6 * t * t * t * t * t;
        fuzzyCompare(Magnify.scale(t * 3 * 52, 52, 1.6, 3), 1 + 0.6 * (1 - smoother), 1e-9);
    }

    function test_flatAtTheEdge() {
        // Zero slope and curvature at the reach: 3 px from it the scale is within 1e-4 of 1 (the cosine is 1e-3).
        verify(Magnify.scale(3 * 52 - 3, 52, 1.6, 3) - 1 < 1e-4);
    }

    function test_integralMatchesTheCurve() {
        // meanScale over a stretch equals the numeric mean of the curve.
        let sum = 0;
        const n = 2000;
        for (let i = 0; i < n; i++)
            sum += Magnify.scale(-60 + 150 * (i + 0.5) / n, 52, 1.6, 3);
        fuzzyCompare(Magnify.meanScale(-60, 90, 52, 1.6, 3), sum / n, 1e-5);
    }

    function test_monotonicAndSymmetric() {
        let prev = Magnify.scale(0, 52, 1.6, 3);
        for (let d = 5; d <= 156; d += 5) {
            const s = Magnify.scale(d, 52, 1.6, 3);
            verify(s <= prev + 1e-12, "monotonic at " + d);
            fuzzyCompare(s, Magnify.scale(-d, 52, 1.6, 3), 1e-12);
            prev = s;
        }
    }

    function test_disabledWhenMaxIsOne() {
        compare(Magnify.scale(0, 52, 1.0, 3), 1);
        compare(Magnify.scale(0, 52, 0.5, 3), 1);
    }

    function test_scalesNeedPointer() {
        const centers = Magnify.centersFor([48, 48, 48], 4, 0);
        compare(centers.join(","), "24,76,128");
        const none = Magnify.scales(centers, -1, 52, 1.6, 3);
        compare(none.join(","), "1,1,1");
        const hot = Magnify.scales(centers, 76, 52, 1.6, 3);
        fuzzyCompare(hot[1], 1.6, 1e-9);
        fuzzyCompare(hot[0], hot[2], 1e-9);
        verify(hot[0] > 1 && hot[0] < 1.6);
    }

    function test_totalWidth() {
        compare(Magnify.totalWidth([48, 48, 48], 4), 152);
        compare(Magnify.totalWidth([], 4), 0);
        compare(Magnify.totalWidth([10], 4), 10);
    }
}
