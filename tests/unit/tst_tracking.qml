import QtQuick
import QtTest
import Grassfield.Ui

// Appearance.tracking(px): Inter dynamic metrics, em = a + b * e^(c * px), returned in pixels (ADR-0003).
TestCase {
    name: "Tracking"

    function formula(px) {
        return (-0.0223 + 0.185 * Math.exp(-0.1745 * px)) * px;
    }

    function test_values_data() {
        return [11, 13, 17, 20, 28].map(px => ({ tag: px + " px", px: px }));
    }

    function test_values(d) {
        fuzzyCompare(Appearance.tracking(d.px), formula(d.px), 1e-9);
    }

    function test_shape() {
        verify(Appearance.tracking(11) > 0, "small text is set slightly looser");
        verify(Appearance.tracking(13) < 0 && Appearance.tracking(13) > -0.1, "13 px is almost neutral");
        verify(Appearance.tracking(28) < Appearance.tracking(20), "larger text is tighter");
        compare(Appearance.tracking(0), 0);
    }
}
