import QtQuick
import QtTest
import Grassfield.Ui

// Values of the visual audit 2026-10-25 (docs/audits/visual-tahoe-2026-10-25.md, "Priorities" 1-7): the measured macOS
// numbers the tokens now carry, and the geometry derived from them. A change here is a design decision, not a refactor.
TestCase {
    name: "VisualAudit"

    // Priority 1: the plain menu text inset is menu padding + item padding (the audit measured 16, there were 37 to 38).
    function test_menuTextInsetWithoutSlot() {
        const inset = Tokens.menuPadding + Tokens.menuItemPadding;
        verify(inset >= 15 && inset <= 16);
        verify(inset + Tokens.menuIconSize + Tokens.spacingSm >= 37);
    }

    // Priority 2: Search rows.
    function test_searchRowMetrics() {
        compare(Tokens.searchTitleSize, 17);
        compare(Tokens.searchSubtitleSize, 15);
        compare(Tokens.searchTextInset, 72);
        compare(Tokens.searchQueryInset, 61);
        compare(Tokens.searchRowRadius, 18);
        compare(Tokens.searchRowInset, 10);
        // Two lines of the row type fit the 56-pt row.
        verify(Tokens.searchTitleSize * 1.2 + Tokens.searchSubtitleSize * 1.2 < Tokens.searchRowHeight);
        // The icon ends before the text starts, with a gap.
        const iconEnd = Tokens.searchFieldInset + Tokens.searchRowIconSize;
        verify(Tokens.searchTextInset - iconEnd >= Tokens.spacingMd);
        // The query starts after the magnifier.
        verify(Tokens.searchQueryInset >= Tokens.searchFieldInset + Tokens.searchFieldIconSize);
    }

    // Priority 3: notifications. Cards 6 apart, banners start at the column's top, equal 22-pt capsules.
    function test_notificationMetrics() {
        compare(Tokens.notificationBannerGap, 6);
        compare(Tokens.notificationActionHeight, 22);
        verify(Tokens.notificationCenterInset >= Tokens.notificationBannerGap);
    }

    // WCAG relative luminance and contrast of two "#rrggbb" colours.
    function lum(hex) {
        const ch = k => {
            const v = parseInt(hex.substr(1 + 2 * k, 2), 16) / 255;
            return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        };
        return 0.2126 * ch(0) + 0.7152 * ch(1) + 0.0722 * ch(2);
    }

    function ratio(a, b) {
        const la = lum(a), lb = lum(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    // Priority 4: opaque windows. White window, an app-only lighter secondary text that still holds 4.5:1 on it (A2 for
    // windows; the material's textSecondary stays for the shell surfaces).
    function test_windowSurfaceColours() {
        compare(Tokens.colorLight.windowBackground, "#FFFFFF");
        for (const palette of [Tokens.colorLight, Tokens.colorDark]) {
            verify(ratio(palette.windowTextSecondary, palette.windowBackground) >= 4.5, palette.windowTextSecondary);
            verify(ratio(palette.text, palette.windowBackground) >= 7);
        }
        // Lighter than the material's secondary text, which is darker for A2 on the blurred wallpaper (light appearance).
        verify(lum(Tokens.colorLight.windowTextSecondary) > lum(Tokens.colorLight.textSecondary));
    }

    function test_windowSurfaceSwitch() {
        const saved = Appearance.windowSurface;
        const dark = Appearance.dark;
        Appearance.dark = false;
        Appearance.windowSurface = false;
        compare(String(Appearance.colors.materialTint).toLowerCase(), Tokens.colorLight.materialTint.toLowerCase());
        Appearance.windowSurface = true;
        compare(String(Appearance.colors.materialTint).toLowerCase(), "#ffffff");
        compare(String(Appearance.colors.textSecondary).toLowerCase(), Tokens.colorLight.windowTextSecondary.toLowerCase());
        Appearance.windowSurface = saved;
        Appearance.dark = dark;
    }

    // Settings pane geometry (macOS: 460 wide content, 20 margins, groups 10 apart, rows 36, groups at about 3 %).
    function test_settingsMetrics() {
        compare(Tokens.settingsContentMaxWidth, 460);
        compare(Tokens.settingsContentMargin, 20);
        compare(Tokens.settingsGroupGap, 10);
        compare(Tokens.settingsRowHeight, 36);
        compare(Tokens.settingsPageTop, 0);
        verify(Tokens.settingsGroupFillOpacity > 0.02 && Tokens.settingsGroupFillOpacity < 0.05);
    }
}
