import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/services/BarToneLogic.js" as Logic

// Adaptive menu bar foreground: luminance of the wallpaper strip -> light or dark, hysteresis, one tone per output.
TestCase {
    id: testCase
    name: "BarTone"

    readonly property real lo: Tokens.menubarToneLightBelow
    readonly property real hi: Tokens.menubarToneDarkAbove

    function px(r, g, b, count) {
        const out = [];
        for (let i = 0; i < count; i++)
            out.push(r, g, b, 255);
        return out;
    }

    function test_luminanceEndpoints() {
        fuzzyCompare(Logic.luminance(0, 0, 0), 0, 1e-9);
        fuzzyCompare(Logic.luminance(1, 1, 1), 1, 1e-9);
        // mid grey 128 is 0.2159 (WCAG)
        fuzzyCompare(Logic.luminance(128 / 255, 128 / 255, 128 / 255), 0.2159, 1e-3);
    }

    function test_meanLuminanceOfPixels() {
        compare(Logic.meanLuminance([]), 0);
        fuzzyCompare(Logic.meanLuminance(px(255, 255, 255, 8)), 1, 1e-9);
        fuzzyCompare(Logic.meanLuminance(px(0, 0, 0, 8)), 0, 1e-9);
        // half white, half black: the mean of the linear luminance (0.5), not of the sRGB values
        fuzzyCompare(Logic.meanLuminance(px(255, 255, 255, 4).concat(px(0, 0, 0, 4))), 0.5, 1e-9);
        // a transparent pixel counts as black
        fuzzyCompare(Logic.meanLuminance([255, 255, 255, 0, 255, 255, 255, 255]), 0.5, 1e-9);
    }

    function test_thresholdsAreOrdered() {
        verify(lo > 0 && lo < hi && hi < 1);
    }

    function test_clearCases() {
        compare(Logic.decide(1, "", lo, hi), "dark");
        compare(Logic.decide(0, "", lo, hi), "light");
        // the opposite previous choice does not matter outside the band
        compare(Logic.decide(1, "light", lo, hi), "dark");
        compare(Logic.decide(0, "dark", lo, hi), "light");
        // the fixtures of gate A2: white, black, mid grey
        const grey = Logic.luminance(128 / 255, 128 / 255, 128 / 255);
        compare(Logic.decide(Logic.luminance(1, 1, 1), "", lo, hi), "dark");
        compare(Logic.decide(Logic.luminance(0, 0, 0), "", lo, hi), "light");
        compare(Logic.decide(grey, "light", lo, hi), "dark");
        compare(Logic.decide(grey, "", lo, hi), "dark");
    }

    function test_hysteresisKeepsThePreviousTone() {
        const mid = (lo + hi) / 2;
        for (const l of [lo, mid, hi]) {
            compare(Logic.decide(l, "light", lo, hi), "light");
            compare(Logic.decide(l, "dark", lo, hi), "dark");
        }
        // just across a threshold flips
        compare(Logic.decide(hi + 1e-6, "light", lo, hi), "dark");
        compare(Logic.decide(lo - 1e-6, "dark", lo, hi), "light");
    }

    function test_firstDecisionInTheBandUsesTheMiddle() {
        compare(Logic.decide((lo + hi) / 2 + 1e-6, "", lo, hi), "dark");
        compare(Logic.decide((lo + hi) / 2 - 1e-6, "", lo, hi), "light");
    }

    function test_wobblingLuminanceDoesNotFlip() {
        let tone = Logic.decide(0.05, "", lo, hi);
        compare(tone, "light");
        for (const l of [lo + 0.001, hi - 0.001, lo + 0.002, hi - 0.002])
            tone = Logic.decide(l, tone, lo, hi);
        compare(tone, "light");
        tone = Logic.decide(0.9, tone, lo, hi);
        compare(tone, "dark");
        for (const l of [lo + 0.001, hi - 0.001])
            tone = Logic.decide(l, tone, lo, hi);
        compare(tone, "dark");
    }

    function test_perOutput() {
        let tones = {};
        tones = Logic.update(tones, "DP-1", 1, lo, hi);
        tones = Logic.update(tones, "DP-2", 0, lo, hi);
        compare(tones["DP-1"], "dark");
        compare(tones["DP-2"], "light");
        // a new measurement changes only its own output, and the hysteresis is per output
        const before = tones;
        tones = Logic.update(tones, "DP-2", (lo + hi) / 2 + 0.001, lo, hi);
        compare(tones["DP-2"], "light");
        compare(tones["DP-1"], "dark");
        verify(before !== tones, "update returns a new object so that bindings re-evaluate");
        tones = Logic.update(tones, "DP-1", (lo + hi) / 2, lo, hi);
        compare(tones["DP-1"], "dark");
        tones = Logic.update(tones, "DP-1", 0, lo, hi);
        compare(tones["DP-1"], "light");
        compare(tones["DP-2"], "light");
    }

    function test_gradientStrip() {
        const top = {r: 15 / 255, g: 42 / 255, b: 63 / 255};
        const next = {r: 47 / 255, g: 111 / 255, b: 126 / 255};
        const l = Logic.stripOfGradient(top, next, 0.1);
        verify(l > Logic.luminance(top.r, top.g, top.b));
        verify(l < Logic.luminance(next.r, next.g, next.b));
        compare(Logic.decide(l, "", lo, hi), "light");
        // an empty strip is the top colour; the reach is clamped
        fuzzyCompare(Logic.stripOfGradient(top, next, 0), Logic.luminance(top.r, top.g, top.b), 1e-12);
        fuzzyCompare(Logic.stripOfGradient(top, next, 5), Logic.stripOfGradient(top, next, 1), 1e-12);
    }

    // White text keeps 4.5:1 up to the dark-to-light threshold, black text from the light-to-dark one (hysteresis band included).
    function test_foregroundContrastAtTheEdges() {
        verify((1 + 0.05) / (hi + 0.05) >= 4.5, "white text at the light-to-dark threshold");
        verify((lo + 0.05) / (0 + 0.05) >= 4.5 - 1e-9, "black text at the dark-to-light threshold");
    }
}
