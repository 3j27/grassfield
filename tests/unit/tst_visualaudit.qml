import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/menubar/ClockFormat.js" as Clock

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
        // The text box starts 71 in (a whole number); the ink of the 17-pt glyphs about 1.5 further, macOS ink at 72.5.
        compare(Tokens.searchTextInset, 71);
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

    // Priority 5: Dock. No band under the icons, the dot inside the padding with its centre 5 above the shelf edge.
    function test_dockMetrics() {
        compare(Tokens.dockIndicatorArea, 0);
        compare(Tokens.dockPadding - Tokens.dockIndicatorSize, 2 * Tokens.dockIndicatorGap);
        compare(Tokens.dockPadding - Tokens.dockIndicatorGap - Tokens.dockIndicatorSize / 2, 5);
        verify(Tokens.dockSeparatorSpace > 2 * Tokens.dockSpacing + Tokens.dockSeparatorWidth);
        verify(Tokens.dockSeparatorOpacity >= 0.25);
        // The room above the shelf holds the label (24 + 7 tail) and the 8-pt gap to the shelf.
        verify(Tokens.dockTooltipArea >= 24 + 7 + Tokens.dockTooltipGap);
    }

    // Priority 6: light controls on light glass. White chips and wells, a 6 % grey secondary button, and the dark appearance
    // keeps the material fill.
    function test_lightControlFills() {
        const dark = Appearance.dark;
        Appearance.dark = false;
        compare(Appearance.chipFill.r, 1);
        fuzzyCompare(Appearance.chipFill.a, Tokens.materialChipFillOpacityLight, 0.01);
        fuzzyCompare(Appearance.buttonFill.a, Tokens.materialButtonFillOpacityLight, 0.01);
        verify(Appearance.buttonFill.r < 0.1);
        fuzzyCompare(Appearance.lightWellFill.a, Tokens.materialWellFillOpacityLight, 0.01);
        verify(Tokens.materialButtonFillOpacityLight <= 0.08);
        Appearance.dark = true;
        fuzzyCompare(Appearance.chipFill.a, Tokens.materialFillOpacity, 0.01);
        fuzzyCompare(Appearance.buttonFill.a, Tokens.materialFillOpacity, 0.01);
        Appearance.dark = dark;
    }

    // Priority 8: Quick Settings. The glyph in a disk is about 20 (macOS), a 1x1 module is a circle one cell wide.
    function test_quickSettingsMetrics() {
        compare(Tokens.quicksettingsDiskGlyph, 20);
        verify(Tokens.quicksettingsDiskGlyph < Tokens.quicksettingsIconDisk);
        // A circle module (cols 1, rows 1) is rounded to a full circle by Module's radius rule (height <= cell).
        verify(Tokens.quicksettingsCell > 0);
    }

    // Priority 9: Apps header row. A borderless 56-pt row, 24-pt glyph and type; the first icon row about 30 under the chips.
    function test_appsHeaderMetrics() {
        compare(Tokens.launcherHeaderHeight, 56);
        compare(Tokens.launcherGlassSize, 24);
        compare(Tokens.launcherQueryFontSize, 24);
        // chips, their hairline gap, the gap to the grid and the grid's own top margin (spacing.sm): about 30 to the first icon.
        const toIcons = Tokens.launcherChipHairlineGap + 1 + Tokens.launcherChipToGrid + Tokens.spacingSm;
        verify(toIcons >= 30 && toIcons <= 42, String(toIcons));
    }

    // Priority 10: Settings floating sidebar (inset 8, radius 18, 32-pt rows, 20-pt tiles) and Files sidebar rows 32.
    function test_sidebarMetrics() {
        compare(Tokens.settingsSidebarInset, 8);
        compare(Tokens.settingsSidebarRadius, 18);
        compare(Tokens.settingsSidebarItemHeight, 32);
        compare(Tokens.settingsSidebarTile, 20);
        verify(Tokens.settingsSidebarIconSize < Tokens.settingsSidebarTile);
        compare(Tokens.filesSidebarItemHeight, 32);
        verify(Tokens.settingsSidebarSelectionRadius > Tokens.radiusControl);
    }

    // Priority 11: toolbar capsules are 36 pt; two 34-pt buttons make the 72-pt back/forward capsule.
    function test_toolbarCapsules() {
        compare(Tokens.filesToolbarCapsule, 36);
        compare(2 * Tokens.filesToolbarGroupButton + Tokens.spacingXs, 72);
        verify(Tokens.filesSearchWidth >= 180);
    }

    // Priority 12: Overview. The wallpaper is barely dimmed (about 0.1, macOS), a desktop is a miniature of its windows.
    function test_overviewMetrics() {
        verify(Tokens.overviewBackdropOpacity <= 0.12 && Tokens.overviewBackdropOpacity >= 0.05);
        // Reduce Transparency keeps its opaque dim.
        verify(Tokens.overviewBackdropOpacityOpaque > 0.8);
        verify(Tokens.overviewMiniMaxWindows >= 4);
        verify(Tokens.overviewMiniIconScale > 0 && Tokens.overviewMiniIconScale < 1);
    }

    function readFile(url) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url, false);
        xhr.send();
        return xhr.responseText;
    }

    // Priority 7: menu bar. 16-pt glyphs with heavier strokes (our own SVGs, icons-bar/ copies of branding/icons/symbolic with
    // only the stroke changed), a wider Wi-Fi glyph, a floating capsule, desktop icons 10 from the edge.
    function test_menuBarMetrics() {
        compare(Tokens.menubarIconSize, 16);
        // The app name starts at 55 and the mark is centred at 27 (macOS): inset + icon + two paddings.
        compare(Tokens.menubarInsetLeft + Tokens.menubarIconSize + 2 * Tokens.menubarItemPadding, 55);
        compare(Tokens.menubarInsetLeft + Tokens.menubarIconSize / 2, 27);
        // The speaker is drawn larger than the others: ink 12-13.5 tall (the drawing is 15/24 of the box).
        const speakerInk = Tokens.menubarIconSize * Tokens.menubarVolumeIconScale * 15 / 24;
        verify(speakerInk >= 12 && speakerInk <= 13.5, String(speakerInk));
        verify(Tokens.menubarIconSize * Tokens.menubarWifiIconScale * 19 / 24 >= 16);
        verify(Tokens.menubarHoverInsetTop >= 1 && Tokens.menubarHoverInsetBottom >= 1);
        compare(Tokens.desktopIconMargin, 10);
    }

    function test_barGlyphsAreTheSameDrawingsWithAHeavierStroke() {
        const names = ["grassfield-logo", "wifi-1", "wifi-2", "wifi-3", "wifi-off", "network-wired", "volume-1", "volume-2", "volume-3", "volume-mute",
            "battery", "battery-charging", "search", "now-playing", "moon", "control-center"];
        for (const n of names) {
            const base = readFile(Qt.resolvedUrl("../../ui/Grassfield/Ui/icons/" + n + ".svg"));
            const bar = readFile(Qt.resolvedUrl("../../ui/Grassfield/Ui/icons-bar/" + n + ".svg"));
            verify(base.length > 0, n);
            compare(bar, base.replace(/stroke-width="1\.75"/g, 'stroke-width="2.4"'), n);
        }
    }

    function test_menuBarClockGap() {
        verify(Tokens.menubarClockGap.length >= 2);
        compare(Clock.join("Sat Oct 17", "09:41", Tokens.menubarClockGap), "Sat Oct 17" + Tokens.menubarClockGap + "09:41");
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

    // Dark appearance keeps its previous values (no dark macOS reference): the window secondary text is the old textSecondary.
    function test_darkWindowValuesAreTheOldOnes() {
        compare(Tokens.colorDark.windowTextSecondary, Tokens.colorDark.textSecondary);
        compare(Tokens.colorDark.windowBackground, Tokens.colorDark.materialTint);
    }

    // Search rows follow Accessibility > Text Size like every other text.
    function test_searchTextFollowsTheTextSize() {
        const saved = Appearance.textScale;
        Appearance.textScale = 1;
        compare(Tokens.searchTitleSize, 17);
        compare(Tokens.searchSubtitleSize, 15);
        Appearance.textScale = 1.3;
        compare(Tokens.searchTitleSize, 22);
        compare(Tokens.searchSubtitleSize, 20);
        verify((Tokens.searchTitleSize + Tokens.searchSubtitleSize) * 1.2 < Tokens.searchRowHeight);
        Appearance.textScale = saved;
    }

    function test_windowSurfaceSwitch() {
        const saved = Appearance.windowSurface;
        const dark = Appearance.dark;
        Appearance.dark = false;
        Appearance.windowSurface = false;
        compare(String(Appearance.colors.materialTint).toLowerCase(), Tokens.colorLight.materialTint.toLowerCase());
        Appearance.windowSurface = true;
        compare(String(Appearance.colors.materialTint).toLowerCase(), "#ffffff");
        // The lighter grey is its own role: textSecondary (fields, tabs, chips) is untouched.
        compare(String(Appearance.windowSecondary).toLowerCase(), Tokens.colorLight.windowTextSecondary.toLowerCase());
        compare(String(Appearance.colors.textSecondary).toLowerCase(), Tokens.colorLight.textSecondary.toLowerCase());
        Appearance.windowSurface = false;
        compare(String(Appearance.windowSecondary).toLowerCase(), Tokens.colorLight.textSecondary.toLowerCase());
        Appearance.windowSurface = true;
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
