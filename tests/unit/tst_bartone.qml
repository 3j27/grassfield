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

    // ---- Dock running dots: 3:1 or more against the shelf over every wallpaper and appearance ----

    function ratio(a, b) {
        return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
    }

    function rgb(hex) {
        return {r: parseInt(hex.substr(1, 2), 16) / 255, g: parseInt(hex.substr(3, 2), 16) / 255, b: parseInt(hex.substr(5, 2), 16) / 255};
    }

    // The dot follows the appearance (white in dark, black in light) and reads by its own halo, the opposite colour at
    // dock.dotHaloOpacity (ADR-0024 G-7), whatever lies behind the clear shelf (wallpaper or a window: black, white, greys,
    // noise averaged by the blur; the shelf's own faint tint only moves the backdrop within that range). The worst cases are
    // the extremes; the halo is composited over the backdrop in sRGB, as the renderer does.
    function test_dockDotKeepsContrastOverAnyBackdrop() {
        const dots = {dark: rgb(Tokens.colorDark.indicator), light: rgb(Tokens.colorLight.indicator)};
        const halos = {dark: rgb(Tokens.colorDark.shadow), light: rgb(Tokens.colorLight.knob)};
        const a = Tokens.dockDotHaloOpacity;
        for (const appearance of ["dark", "light"]) {
            const d = dots[appearance];
            const h = halos[appearance];
            const dotLum = Logic.luminance(d.r, d.g, d.b);
            let worst = 99;
            for (let i = 0; i <= 100; i++) {
                const g = i / 100;  // backdrop grey, sRGB 0..1
                const ring = Logic.luminance(h.r * a + g * (1 - a), h.g * a + g * (1 - a), h.b * a + g * (1 - a));
                worst = Math.min(worst, ratio(dotLum, ring));
            }
            verify(worst >= 3, appearance + " worst case " + worst);
        }
    }

    function test_dockShelfIsClearGlass() {
        // ADR-0024 section 2 point 1: the shelf holds no text; its tint is the class value.
        verify(Tokens.dockTintAlphaLight <= 0.1 && Tokens.dockTintAlphaDark <= 0.1);
        verify(Tokens.dockDotHalo > 0 && Tokens.dockDotHaloOpacity > 0);
    }

    // ---- percentile decision and the automatic band (ADR-0016 W6) ----
    readonly property real needed: Tokens.menubarToneNeededContrast
    readonly property real margin: Tokens.menubarToneMargin

    function test_stripToneUniformWallpapers() {
        const dark = Logic.stripTone(0.02, 0.04, "", needed, margin);
        compare(dark.tone, "light");
        verify(!dark.assist);
        verify(dark.white > 10);
        const light = Logic.stripTone(0.8, 0.9, "", needed, margin);
        compare(light.tone, "dark");
        verify(!light.assist);
        verify(light.black > 12);
    }

    function test_stripToneSplitWallpaperNeedsTheBand() {
        // White left, black right: the strip holds both extremes whichever tone is chosen.
        const split = Logic.stripTone(0, 1, "", needed, margin);
        verify(split.assist);
        verify(split.best < 1.1);
        // A busy mid-range strip.
        const mid = Logic.stripTone(0.05, 0.6, "", needed, margin);
        verify(mid.assist, "white over 0.6 is 1.5:1, black over 0.05 is 1.0:1");
        // A strip that one tone handles: dark photo with a small bright patch (p95 low).
        const patch = Logic.stripTone(0.01, 0.05, "", needed, margin);
        verify(!patch.assist);
    }

    function test_stripToneCrossoverIsTheLimit() {
        // At the tone crossover (luminance 0.179) both tones give 4.5:1: just enough, no band.
        const edge = Logic.stripTone(0.179, 0.179, "", needed, margin);
        verify(edge.best >= 4.5 - 0.05);
        // 0.16 to 0.19 is the known weak zone of menubar.md: best case ~4.3-4.5, so the band decides by the 4.5 rule.
        const blue = Logic.stripTone(0.166, 0.166, "", needed, margin);
        compare(blue.assist, Math.max(blue.white, blue.black) < needed);
    }

    function test_stripToneHysteresis() {
        // White and black almost equal: the previous tone stays.
        const a = Logic.stripTone(0.18, 0.18, "light", needed, margin);
        const b = Logic.stripTone(0.18, 0.18, "dark", needed, margin);
        compare(a.tone, "light");
        compare(b.tone, "dark");
        // A clear difference overrides the previous tone.
        compare(Logic.stripTone(0.9, 0.95, "light", needed, margin).tone, "dark");
        compare(Logic.stripTone(0.0, 0.03, "dark", needed, margin).tone, "light");
        // Inputs are clamped.
        verify(isFinite(Logic.stripTone(-1, 5, "", needed, margin).white));
    }

    // Review finding (A2): after a light wallpaper (tone dark) a mid-grey strip #737373|#757575 gives black 4.42:1 and white
    // 4.61:1, a difference under the margin. Keeping "dark" showed 4.42:1 without the band; the chosen tone must pass.
    function test_stripToneHysteresisNeverKeepsAFailingTone() {
        const lumOf = v => Logic.luminance(v / 255, v / 255, v / 255);
        const p5 = lumOf(0x73), p95 = lumOf(0x75);
        const r = Logic.stripTone(p5, p95, "dark", needed, margin);
        verify(Math.abs(r.white - r.black) < margin, "the case is inside the margin");
        verify(r.black < needed, "black alone would fail: " + r.black);
        compare(r.tone, "light", "the passing tone wins over the previous one");
        verify(!r.assist);
        verify(r.best >= needed);
        // Both tones fail: the band, whatever the previous tone.
        for (const prev of ["light", "dark", ""])
            verify(Logic.stripTone(0, 1, prev, needed, margin).assist, prev);
        // The previous tone stays while it passes and the other is only slightly better (0.18: white 4.57, black 4.60).
        const stay = Logic.stripTone(0.18, 0.18, "light", needed, margin);
        compare(stay.tone, "light");
        verify(!stay.assist);
        compare(Logic.stripTone(0.18, 0.18, "dark", needed, margin).tone, "dark");
        // Assist always describes the chosen tone.
        for (const prev of ["light", "dark", ""]) {
            const c = Logic.stripTone(lumOf(0x74), lumOf(0x74), prev, needed, margin);
            compare(c.assist, c.best < needed, prev);
            compare(c.best, c.tone === "light" ? c.white : c.black);
        }
    }

    // Generated busy wallpapers (the A2 worst cases: split, horizon, threshold, blocks, large-scale noise) as strip
    // statistics: whatever the strip, the bar ends with either a tone that reaches 4.5:1 or the band.
    function test_stripToneEveryStripIsLegibleOrAssisted() {
        let seed = 7;
        function rnd() {
            seed = (seed * 1103515245 + 12345) % 2147483648;
            return seed / 2147483648;
        }
        for (let i = 0; i < 500; i++) {
            const a = rnd(), b = rnd();
            const p5 = Math.min(a, b), p95 = Math.max(a, b);
            const r = Logic.stripTone(p5, p95, rnd() < 0.5 ? "light" : "dark", needed, margin);
            // With the band the text is the material's; without it the CHOSEN tone must reach the contrast (not the better of
            // the two: hysteresis can keep the other one).
            if (!r.assist)
                verify((r.tone === "light" ? r.white : r.black) >= needed, "p5 " + p5 + " p95 " + p95 + " previous " + r.tone);
            compare(r.assist, r.best < needed);
        }
    }

    function test_dockDotColoursArePureTones() {
        compare(Tokens.colorDark.indicator, "#FFFFFF");
        compare(Tokens.colorLight.indicator, "#000000");
    }
}
