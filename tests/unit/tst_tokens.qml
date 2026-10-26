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

    // GF-125: the compositor blur follows the transparency (docs/specs/ui.md "Material blur").
    function test_blurDefaultIsWhatTheConfigShips() {
        compare(Appearance.blurSize(Tokens.materialDefaultTransparency), 18, "looknfeel.lua ships size 18");
        compare(Appearance.blurPasses(Tokens.materialDefaultTransparency), 3, "and 3 passes");
        compare(Appearance.compositorBlurSize, 18);
        compare(Appearance.compositorBlurPasses, 3);
    }

    function test_blurGrowsWithTransparency() {
        let last = 0;
        for (let t = 0; t <= 1.0001; t += 0.05) {
            const size = Appearance.blurSize(t);
            verify(size >= last, "size is monotonic at " + t);
            last = size;
        }
        compare(Appearance.blurSize(0), Tokens.materialBlurSizeMin);
        compare(Appearance.blurSize(1), Tokens.materialBlurSizeMax);
        verify(Appearance.blurSize(0.05) < Appearance.blurSize(0.25), "a less transparent material blurs less");
        verify(Appearance.blurSize(0.6) > Appearance.blurSize(0.25), "a more transparent one blurs more");
        verify(Appearance.blurPasses(0.05) < Appearance.blurPasses(0.25), "a nearly opaque material uses fewer passes");
        compare(Appearance.blurSize(-3), Tokens.materialBlurSizeMin);
        compare(Appearance.blurSize(9), Tokens.materialBlurSizeMax);
    }

    function test_blurFollowsTheEffectiveTransparency() {
        Appearance.transparency = 0.6;
        compare(Appearance.compositorBlurSize, Appearance.blurSize(0.6));
        Appearance.reduceTransparency = true;
        compare(Appearance.compositorBlurSize, Tokens.materialBlurSizeMin, "Reduce Transparency: the minimum, and no surface asks for blur");
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

    // F1 fidelity pass 1 (docs/testing/f1-reference-gaps.md): measured macOS 26 values, in points.
    function test_referenceMetrics() {
        compare(Tokens.menuItemHeight, 24);
        compare(Tokens.menuSeparatorHeight, 11);
        compare(Tokens.radiusMenu, 12);
        compare(Tokens.controlToggleWidth, 36);
        compare(Tokens.controlToggleHeight, 16);
        compare(Tokens.controlToggleKnobWidth, 21);
        compare(Tokens.controlToggleKnobHeight, 12);
        compare(Tokens.controlSliderTrack, 6);
        compare(Tokens.menubarItemPadding, 10);
        compare(Tokens.panelAlertWidth, 260);
        compare(Tokens.searchWidth, 520);
        compare(Tokens.searchRowHeight, 63);
        compare(Tokens.widgetRadius, 26);
        compare(Tokens.widgetDesktopMargin, 16);
        compare(Tokens.overviewTileWidth, 138);
        compare(Tokens.filesIconCellWidth, 112);
        compare(Tokens.desktopIconCellWidth, 112);
        compare(Tokens.filesInfoWindowWidth, 264);
        // Quick Settings: 4 columns of 63 with 13 gaps are 291 wide; the Notifications column is a banner wide.
        compare(Tokens.panelControlCenterWidth, 4 * Tokens.quicksettingsCell + 3 * Tokens.quicksettingsGap);
        compare(Tokens.quicksettingsCell, 63);
        compare(Tokens.quicksettingsIconDisk, 36);
        compare(Tokens.panelCcIconButton, Tokens.quicksettingsIconDisk);
        // Controls that share a size with the icon disk by accident keep their own tokens.
        compare(Tokens.panelCcJoinButton, 30);
        verify(Tokens.panelCcJoinButton <= Tokens.panelCcRowHeight);
        compare(Tokens.panelCcTransportButton, 26);
        compare(Tokens.panelWidgetTransportButton, 22);
        compare(Tokens.notificationCenterWidth, Tokens.notificationBannerWidth);
        fuzzyCompare(Tokens.materialSeparatorOpacityLight, 0.08, 1e-9);
        Appearance.dark = false;
        fuzzyCompare(Appearance.separatorOpacity, Tokens.materialSeparatorOpacityLight, 1e-9);
        Appearance.dark = true;
        fuzzyCompare(Appearance.separatorOpacity, Tokens.materialSeparatorOpacity, 1e-9);
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
