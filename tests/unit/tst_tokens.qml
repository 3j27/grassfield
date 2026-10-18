import QtQuick
import QtTest
import Grassfield.Ui

TestCase {
    id: testCase
    name: "Tokens"

    function init() {
        Appearance.dark = true;
        Appearance.transparency = Tokens.materialDefaultTransparency;
        Appearance.reduceTransparency = false;
        Appearance.reduceMotion = false;
    }

    function test_tintAlphaEndpoints() {
        compare(Appearance.tintAlpha(0), 1.0);
        fuzzyCompare(Appearance.tintAlpha(1), Tokens.materialTintAlphaMin, 1e-9);
    }

    function test_tintAlphaDefaultIsHighOpacity() {
        fuzzyCompare(Tokens.materialDefaultTransparency, 0.25, 1e-9);
        fuzzyCompare(Appearance.tintAlpha(0.25), 1 - 0.25 * (1 - Tokens.materialTintAlphaMin), 1e-9);
        // Frosted at the default: the tint is at most 0.85 (master-prompt 5.5), and above the A2 clamp (unclamped).
        verify(Appearance.tintAlpha(0.25) <= 0.85 + 1e-9);
        verify(Appearance.tintAlpha(0.25) >= Tokens.materialTintAlphaClamp);
    }

    function test_tintAlphaClampOnlyAtHighTransparency() {
        // Up to tintClampUntil the tint never drops below the clamp; the clamp is not active at the default.
        for (const t of [0.3, 0.4, 0.5, 0.6])
            verify(Appearance.tintAlpha(t) >= Tokens.materialTintAlphaClamp - 1e-9);
        fuzzyCompare(Appearance.tintAlpha(0.6), Tokens.materialTintAlphaClamp, 1e-9);
        fuzzyCompare(Appearance.tintAlpha(Tokens.materialTintClampUntil), Tokens.materialTintAlphaClamp, 1e-9);
        // Past it the slider keeps working, down to tintAlphaMin at 1.
        verify(Appearance.tintAlpha(0.8) < Tokens.materialTintAlphaClamp);
        verify(Appearance.tintAlpha(0.9) < Appearance.tintAlpha(0.8));
    }

    function test_tintAlphaMonotonicAndClamped() {
        verify(Appearance.tintAlpha(0.6) <= Appearance.tintAlpha(0.3));
        verify(Appearance.tintAlpha(0.6) < Appearance.tintAlpha(0.1));
        verify(Appearance.tintAlpha(1) < Appearance.tintAlpha(0.6));
        compare(Appearance.tintAlpha(-5), 1.0);
        fuzzyCompare(Appearance.tintAlpha(7), Tokens.materialTintAlphaMin, 1e-9);
    }

    function test_reduceTransparencyIsOpaque() {
        Appearance.transparency = 0.5;
        fuzzyCompare(Appearance.effectiveTransparency, 0.5, 1e-9);
        Appearance.reduceTransparency = true;
        compare(Appearance.effectiveTransparency, 0);
        compare(Appearance.tintAlpha(Appearance.effectiveTransparency), 1.0);
    }

    function test_reduceMotionCapsDurations() {
        compare(Appearance.duration(350), 350);
        Appearance.reduceMotion = true;
        compare(Appearance.duration(350), Tokens.motionReducedMax);
        compare(Appearance.duration(50), 50);
        verify(Tokens.motionReducedMax <= 100);
    }

    function test_appearanceSelectsPalette() {
        compare(Appearance.colors.text, Tokens.colorDark.text);
        Appearance.dark = false;
        compare(Appearance.colors.text, Tokens.colorLight.text);
    }

    function test_paletteRolesMatch() {
        const dark = Object.keys(Tokens.colorDark).sort();
        const light = Object.keys(Tokens.colorLight).sort();
        compare(dark.join(","), light.join(","));
        for (const role of dark) {
            verify(/^#[0-9A-Fa-f]{6}$/.test(Tokens.colorDark[role]), role);
            verify(/^#[0-9A-Fa-f]{6}$/.test(Tokens.colorLight[role]), role);
        }
    }

    function test_sizes() {
        compare(Tokens.menubarHeight, 24);
        verify(Tokens.dockIconSize > 0);
        compare(Tokens.motionCurveStandard.length % 6, 0);
        compare(Tokens.typographyFamily, "Inter");
        compare(Tokens.typographyFallbackFamily, "Noto Sans");
    }

    Component {
        id: materialComponent
        Material {
            width: 100
            height: 40
        }
    }

    function test_materialBlurContract() {
        const m = createTemporaryObject(materialComponent, testCase);
        verify(m !== null);
        verify(m.blurActive);
        fuzzyCompare(m.tintAlpha, Appearance.tintAlpha(0.25), 1e-9);
        Appearance.reduceTransparency = true;
        verify(!m.blurActive);
        compare(m.tintAlpha, 1.0);
    }
}
