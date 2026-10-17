import QtQuick
import QtTest
import Grassfield.Ui

// Gate A2: label text on the accent fill reaches WCAG AA (4.5:1) in both appearances.
TestCase {
    name: "Contrast"

    function channel(v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }

    function luminance(hex) {
        const c = Qt.color(hex);
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    }

    function ratio(a, b) {
        const la = luminance(a);
        const lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function test_accentTextDark() {
        verify(ratio(Tokens.colorDark.accentText, Tokens.colorDark.accent) >= 4.5);
    }

    function test_accentTextLight() {
        verify(ratio(Tokens.colorLight.accentText, Tokens.colorLight.accent) >= 4.5);
    }

    function test_bodyTextOnTint() {
        verify(ratio(Tokens.colorDark.text, Tokens.colorDark.materialTint) >= 4.5);
        verify(ratio(Tokens.colorLight.text, Tokens.colorLight.materialTint) >= 4.5);
    }

    function test_ratioSanity() {
        fuzzyCompare(ratio("#000000", "#FFFFFF"), 21, 1e-6);
    }
}
