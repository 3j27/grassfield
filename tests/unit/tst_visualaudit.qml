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
}
