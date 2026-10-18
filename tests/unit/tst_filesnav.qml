import QtQuick
import QtTest
import "../../apps/files/qml/Nav.js" as Nav

// grassfield-files pure navigation logic: grid and list keyboard moves, history, type-to-select,
// header sort clicks, rubber band hit testing, column view prefix.
TestCase {
    name: "FilesNav"

    function test_gridMoves() {
        // 10 items, 4 per row: rows [0..3] [4..7] [8,9]
        compare(Nav.gridMove(5, "left", 4, 10, 2), 4);
        compare(Nav.gridMove(0, "left", 4, 10, 2), 0);
        compare(Nav.gridMove(5, "right", 4, 10, 2), 6);
        compare(Nav.gridMove(9, "right", 4, 10, 2), 9);
        compare(Nav.gridMove(5, "up", 4, 10, 2), 1);
        compare(Nav.gridMove(1, "up", 4, 10, 2), 1);
        compare(Nav.gridMove(1, "down", 4, 10, 2), 5);
        compare(Nav.gridMove(5, "down", 4, 10, 2), 9);
        compare(Nav.gridMove(7, "down", 4, 10, 2), 9);
        compare(Nav.gridMove(9, "down", 4, 10, 2), 9);
        compare(Nav.gridMove(6, "home", 4, 10, 2), 0);
        compare(Nav.gridMove(2, "end", 4, 10, 2), 9);
    }

    function test_gridPages() {
        compare(Nav.gridMove(1, "pagedown", 4, 30, 2), 9);
        compare(Nav.gridMove(25, "pagedown", 4, 30, 2), 29);
        compare(Nav.gridMove(13, "pageup", 4, 30, 2), 5);
        compare(Nav.gridMove(5, "pageup", 4, 30, 2), 1);
    }

    function test_noCurrentSelectsFirstOrLast() {
        compare(Nav.gridMove(-1, "down", 4, 10, 2), 0);
        compare(Nav.gridMove(-1, "end", 4, 10, 2), 9);
        compare(Nav.gridMove(-1, "down", 4, 0, 2), -1);
    }

    function test_listMoves() {
        compare(Nav.listMove(3, "down", 10, 5), 4);
        compare(Nav.listMove(3, "up", 10, 5), 2);
        compare(Nav.listMove(3, "left", 10, 5), 3);
        compare(Nav.listMove(3, "pagedown", 10, 5), 8);
        compare(Nav.listMove(0, "up", 10, 5), 0);
    }

    function test_history() {
        let h = Nav.pushHistory([], -1, "file:///a");
        compare(h.entries, ["file:///a"]);
        compare(h.index, 0);
        h = Nav.pushHistory(h.entries, h.index, "file:///b");
        h = Nav.pushHistory(h.entries, h.index, "file:///c");
        compare(h.index, 2);
        // Same location: unchanged.
        h = Nav.pushHistory(h.entries, h.index, "file:///c");
        compare(h.entries.length, 3);
        // Back twice then elsewhere: forward entries dropped.
        h = Nav.pushHistory(h.entries, 0, "file:///d");
        compare(h.entries, ["file:///a", "file:///d"]);
        compare(h.index, 1);
    }

    function test_typeahead() {
        compare(Nav.typeahead("", "a", 0, 1000), "a");
        compare(Nav.typeahead("a", "l", 200, 1000), "al");
        compare(Nav.typeahead("al", "b", 1500, 1000), "b");
    }

    function test_sortClick() {
        compare(Nav.sortClick(0, false, 0, false), {key: 0, descending: true});
        compare(Nav.sortClick(0, true, 2, true), {key: 2, descending: true});
        compare(Nav.sortClick(2, true, 2, true), {key: 2, descending: false});
    }

    function test_cellsInRect() {
        // 4 columns of 100 x 100, 10 items.
        compare(Nav.cellsInRect(10, 10, 150, 50, 100, 100, 4, 10), [0, 1]);
        compare(Nav.cellsInRect(150, 250, 10, 120, 100, 100, 4, 10), [4, 5, 8, 9]);
        compare(Nav.cellsInRect(350, 250, 390, 290, 100, 100, 4, 10), []);
        compare(Nav.cellsInRect(0, 0, 10, 10, 100, 100, 4, 0), []);
    }

    function test_commonPrefix() {
        compare(Nav.commonPrefix(["file:///h", "file:///h/a", "file:///h/a/b"], ["file:///h", "file:///h/a", "file:///h/a/c"]), 2);
        compare(Nav.commonPrefix(["file:///h"], ["file:///h", "file:///h/x"]), 1);
        compare(Nav.commonPrefix([], ["file:///"]), 0);
    }

    // Gallery strip: one row, Left/Right step, Home/End jump, pages of the visible thumbnails, Up/Down stay.
    function test_stripMoves() {
        compare(Nav.stripMove(3, "left", 10, 4), 2);
        compare(Nav.stripMove(0, "left", 10, 4), 0);
        compare(Nav.stripMove(3, "right", 10, 4), 4);
        compare(Nav.stripMove(9, "right", 10, 4), 9);
        compare(Nav.stripMove(3, "up", 10, 4), 3);
        compare(Nav.stripMove(3, "down", 10, 4), 3);
        compare(Nav.stripMove(6, "home", 10, 4), 0);
        compare(Nav.stripMove(2, "end", 10, 4), 9);
        compare(Nav.stripMove(2, "pagedown", 10, 4), 6);
        compare(Nav.stripMove(8, "pagedown", 10, 4), 9);
        compare(Nav.stripMove(5, "pageup", 10, 4), 1);
        compare(Nav.stripMove(2, "pageup", 10, 4), 0);
        // A page is never empty.
        compare(Nav.stripMove(2, "pagedown", 10, 0), 3);
    }

    function test_stripWithoutCurrentOrItems() {
        compare(Nav.stripMove(-1, "right", 10, 4), 0);
        compare(Nav.stripMove(-1, "left", 10, 4), 0);
        compare(Nav.stripMove(-1, "end", 10, 4), 9);
        compare(Nav.stripMove(12, "left", 10, 4), 0);
        compare(Nav.stripMove(-1, "right", 0, 4), -1);
        compare(Nav.stripMove(3, "right", 0, 4), -1);
    }

    // View modes: four modes in toolbar/shortcut order, unknown saved values fall back to icons, Ctrl+N picks the
    // Nth mode, tag results in the column mode draw as a list.
    function test_viewModeSwitching() {
        compare(Nav.viewModes, ["icons", "list", "columns", "gallery"]);
        compare(Nav.normalizeViewMode("gallery"), "gallery");
        compare(Nav.normalizeViewMode("columns"), "columns");
        compare(Nav.normalizeViewMode("coverflow"), "icons");
        compare(Nav.normalizeViewMode(""), "icons");
        compare(Nav.normalizeViewMode(undefined), "icons");
        compare(Nav.viewModeForShortcut(1), "icons");
        compare(Nav.viewModeForShortcut(2), "list");
        compare(Nav.viewModeForShortcut(3), "columns");
        compare(Nav.viewModeForShortcut(4), "gallery");
        compare(Nav.viewModeForShortcut(0), "");
        compare(Nav.viewModeForShortcut(5), "");
        compare(Nav.effectiveView("gallery", false), "gallery");
        compare(Nav.effectiveView("columns", false), "columns");
        compare(Nav.effectiveView("columns", true), "list");
        compare(Nav.effectiveView("gallery", true), "gallery");
        compare(Nav.effectiveView("bogus", true), "icons");
    }

    // The gallery always shows an item: the current one, else the first.
    function test_galleryInitialRow() {
        compare(Nav.galleryInitialRow(-1, 5), 0);
        compare(Nav.galleryInitialRow(3, 5), 3);
        compare(Nav.galleryInitialRow(7, 5), 0);
        compare(Nav.galleryInitialRow(-1, 0), -1);
    }
}
