import QtQuick
import QtTest
import "../../shell/services/VolumeScale.js" as Scale

// The shell shows the cubic (wpctl) volume, PipeWire stores the linear one.
TestCase {
    name: "VolumeScale"

    function test_wpctlHalfIsAnEighthLinear() {
        fuzzyCompare(Scale.toLinear(0.5), 0.125, 1e-9);
        fuzzyCompare(Scale.toPerceptual(0.125), 0.5, 1e-9);
        compare(Scale.wpctlText(Scale.toPerceptual(0.125)), "0.50");
    }

    function test_roundTripAndEnds() {
        for (const p of [0, 0.1, 0.33, 0.75, 1])
            fuzzyCompare(Scale.toPerceptual(Scale.toLinear(p)), p, 1e-9);
        compare(Scale.toLinear(1), 1);
        compare(Scale.toPerceptual(0), 0);
    }

    function test_clampsAndGarbage() {
        compare(Scale.toLinear(2), 1);
        compare(Scale.toPerceptual(8), 1);
        compare(Scale.toLinear(-1), 0);
        compare(Scale.toPerceptual(NaN), 0);
        compare(Scale.toLinear(undefined), 0);
    }
}
