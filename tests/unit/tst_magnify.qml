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

    function test_cosineMidpoint() {
        // Halfway to the reach the cosine bump is at half height.
        fuzzyCompare(Magnify.scale(1.5 * 52, 52, 1.6, 3), 1.3, 1e-9);
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
