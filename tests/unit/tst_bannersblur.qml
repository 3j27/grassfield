import QtQuick
import QtTest

// UI audit 2026-11-05 (Reduce Motion strip): a blur Region that follows an Item hears only that item's own geometry, so a
// card carried by its slot in the Column moved without a word and a region made in the frame a gap closed stayed at the
// old place (a faint band under the stack, nested capture). The banner regions are explicit rects built from properties that
// notify, and the registry of drawn cards never keeps a dead (null) entry. A source test: Banners.qml is a PanelWindow.
TestCase {
    name: "BannersBlur"

    function source() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../shell/notifications/Banners.qml"), false);
        xhr.send();
        verify(xhr.responseText.length > 0);
        return xhr.responseText;
    }

    function test_regionsAreExplicitRects() {
        const s = source();
        const v = s.substring(s.indexOf("id: blurRegions"), s.indexOf("// The window's input region"));
        verify(v.indexOf("x: modelData.blurX") >= 0 && v.indexOf("y: modelData.blurY") >= 0, "x and y from the slot's notifying properties");
        verify(v.indexOf("width: modelData.blurW") >= 0 && v.indexOf("height: modelData.blurH") >= 0);
        compare(v.indexOf("item:"), -1, "no Region that follows an Item");
        verify(/blurY: card \? Math\.round\(stack\.y \+ slot\.y \+ card\.y\)/.test(s), "the slot's place is a dependency");
    }

    function test_registryDropsDeadEntries() {
        const s = source();
        const filters = s.split("\n").filter(l => l.indexOf("win.cards.filter(") >= 0);
        verify(filters.length >= 2);
        for (const l of filters)
            verify(l.indexOf("c && c !== slot") >= 0, "drops null entries: " + l.trim());
    }
}
