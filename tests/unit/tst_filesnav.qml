import QtQuick
import QtTest
import "../../apps/files/qml/Nav.js" as Nav

// grassfield-files pure navigation logic: grid and list keyboard moves, history, type-to-select,
// header sort clicks, rubber band hit testing, column view prefix, per-folder view and arrangement (F-3).
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

    // While a drag started from a view runs, that view stays whatever the folder sprung into wants (BrowserTab.dragView):
    // destroying the item that started a system drag before it ends is a use-after-free in Qt Quick.
    function test_aDragKeepsItsView() {
        compare(Nav.shownView("", "list", false), "list", "no drag: the folder's view");
        compare(Nav.shownView("icons", "list", false), "icons", "a folder whose own view is List sprung open: still icons");
        compare(Nav.shownView("gallery", "columns", false), "gallery");
        compare(Nav.shownView("list", "columns", true), "list");
        compare(Nav.shownView("icons", "gallery", true), "icons", "the search ending under the drag changes nothing");
        compare(Nav.shownView("", "columns", true), "list", "after the drag: the effective view again");
    }

    // The gallery always shows an item: the current one, else the first.
    function test_galleryInitialRow() {
        compare(Nav.galleryInitialRow(-1, 5), 0);
        compare(Nav.galleryInitialRow(3, 5), 3);
        compare(Nav.galleryInitialRow(7, 5), 0);
        compare(Nav.galleryInitialRow(-1, 0), -1);
    }

    // F-3: a folder's own view wins, else the view the tab already shows, else the default; column view sticks.
    function test_viewForAFolder() {
        compare(Nav.viewFor("", "list", "icons"), "list", "a new tab opens a folder in its own view");
        compare(Nav.viewFor("", undefined, "gallery"), "gallery", "a new tab on a folder without one: the default");
        compare(Nav.viewFor("", "bogus", "bogus"), "icons", "invalid values fall back to icons");
        compare(Nav.viewFor("icons", "list", "icons"), "list", "browsing into a folder with its own view");
        compare(Nav.viewFor("list", undefined, "icons"), "list", "browsing into a folder without one keeps the tab's view");
        compare(Nav.viewFor("columns", "list", "icons"), "columns", "column view sticks while browsing");
        compare(Nav.viewFor("gallery", "columns", "icons"), "columns", "a folder kept in columns opens in columns");
    }

    function test_groupedIconMove() {
        // Three groups: rows 0-4 in one row, 5-6 in one row, 7-12 shown in full four to a line.
        const groups = [{first: 0, count: 5, columns: 5}, {first: 5, count: 2, columns: 2}, {first: 7, count: 6, columns: 4}];
        compare(Nav.groupedIconMove(4, "right", groups), 5, "Right walks into the next group");
        compare(Nav.groupedIconMove(5, "left", groups), 4);
        compare(Nav.groupedIconMove(3, "down", groups), 6, "down to the next group, its last item for a far column");
        compare(Nav.groupedIconMove(1, "down", groups), 6);
        compare(Nav.groupedIconMove(0, "down", groups), 5);
        compare(Nav.groupedIconMove(6, "down", groups), 8, "column 1 of the full group's first line");
        compare(Nav.groupedIconMove(8, "down", groups), 12, "the item below in the full group");
        compare(Nav.groupedIconMove(9, "down", groups), 12, "into the shorter last line: its last item");
        compare(Nav.groupedIconMove(11, "up", groups), 7);
        compare(Nav.groupedIconMove(7, "up", groups), 5, "from the full group's first line to the group above");
        compare(Nav.groupedIconMove(12, "up", groups), 8);
        compare(Nav.groupedIconMove(2, "up", groups), 2, "the first group's line stays");
        compare(Nav.groupedIconMove(2, "pagedown", groups), 6);
        compare(Nav.groupedIconMove(10, "pageup", groups), 6);
        compare(Nav.groupedIconMove(6, "end", groups), 12);
        compare(Nav.groupedIconMove(-1, "down", groups), 0);
        compare(Nav.groupedIconMove(0, "down", []), -1);
    }

    function test_groupedIconLayout() {
        // Rows 0-4 in one line, 5-6 in one line, 7-12 in full four to a line; headers 32, cells 100 x 90.
        const groups = [{first: 0, count: 5, columns: 5}, {first: 5, count: 2, columns: 2}, {first: 7, count: 6, columns: 4}];
        compare(Nav.groupedIconTops(groups, 32, 90), [0, 122, 244, 456], "each header over its lines, the height last");
        compare(Nav.groupedIconTops([], 32, 90), [0]);
        compare(Nav.groupedIconCell(3, 100, 90, 32, groups), {group: 0, index: 3, line: 0, column: 3, x: 300, y: 32});
        compare(Nav.groupedIconCell(12, 100, 90, 32, groups), {group: 2, index: 5, line: 1, column: 1, x: 100, y: 366}, "second line of the full group");
        compare(Nav.groupedIconCell(13, 100, 90, 32, groups), null);
    }

    function test_groupedIconCells() {
        const groups = [{first: 0, count: 5, columns: 5, scrollX: 0}, {first: 5, count: 2, columns: 2, scrollX: 0},
                        {first: 7, count: 6, columns: 4, scrollX: 0}];
        compare(Nav.groupedIconCells(0, 0, 400, 20, 100, 90, 32, groups), [], "a header alone selects nothing");
        compare(Nav.groupedIconCells(150, 40, 250, 60, 100, 90, 32, groups), [1, 2]);
        compare(Nav.groupedIconCells(50, 100, 150, 160, 100, 90, 32, groups), [0, 1, 5, 6], "across a header");
        compare(Nav.groupedIconCells(150, 400, 50, 300, 100, 90, 32, groups), [7, 8, 11, 12], "upwards, both lines of the full group");
        groups[0].scrollX = 200;
        compare(Nav.groupedIconCells(0, 40, 50, 60, 100, 90, 32, groups), [2], "a line scrolled sideways");
        compare(Nav.groupedIconCells(0, 500, 400, 600, 100, 90, 32, groups), [], "below the last group");
    }

    function test_groupedRowsInSpan() {
        // Two groups: rows 0-2 under a 28-high header, rows 3-4 under the next; rows 20 high.
        const groups = [{first: 0, count: 3}, {first: 3, count: 2}];
        // Layout: header 0-28, rows 28-88, header 88-116, rows 116-156.
        compare(Nav.groupedRowsInSpan(0, 10, 20, 28, groups), [], "a header alone selects nothing");
        compare(Nav.groupedRowsInSpan(30, 50, 20, 28, groups), [0, 1]);
        compare(Nav.groupedRowsInSpan(80, 120, 20, 28, groups), [2, 3], "across a header");
        compare(Nav.groupedRowsInSpan(150, 30, 20, 28, groups), [0, 1, 2, 3, 4], "upwards too");
        compare(Nav.groupedRowsInSpan(200, 300, 20, 28, groups), [], "below the last row");
    }

    function test_sortForAFolder() {
        const descendingOf = key => key === 2 || key === 3;
        compare(Nav.sortFor({}, 0, false, descendingOf), {key: 0, descending: false}, "no entry: the defaults");
        compare(Nav.sortFor({sortKey: 2}, 0, false, descendingOf), {key: 2, descending: true}, "a key alone takes its default order");
        compare(Nav.sortFor({sortKey: 3, sortDescending: false}, 0, false, descendingOf), {key: 3, descending: false});
        compare(Nav.sortFor({sortDescending: true}, 1, false, descendingOf), {key: 1, descending: true}, "an order alone");
        compare(Nav.sortFor(null, 1, true, descendingOf), {key: 1, descending: true});
    }

    // Column view (ColumnView.qml): Cmd-double-click on a folder opens it in a new tab like the other views; a plain
    // double-click on a folder does nothing more than its click (the next column); a file opens either way.
    function test_columnDoubleClick() {
        compare(Nav.columnDoubleClickOpens(true, true), true, "Cmd-double-click on a folder: a new tab");
        compare(Nav.columnDoubleClickOpens(true, false), false, "a plain double-click on a folder: the column only");
        compare(Nav.columnDoubleClickOpens(false, false), true, "a file opens");
        compare(Nav.columnDoubleClickOpens(false, true), true, "a file opens with Cmd too");
    }
}
