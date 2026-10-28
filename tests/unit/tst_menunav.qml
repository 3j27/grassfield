import QtQuick
import QtTest
import "../../ui/Grassfield/Ui/MenuNav.js" as MenuNav

TestCase {
    name: "MenuNav"

    readonly property var items: [
        {text: "About"},
        {separator: true},
        {text: "Settings", enabled: false},
        {text: "Quit"},
        {text: "More", submenu: [{text: "Sub A"}, {text: "Sub B"}]}
    ]

    function test_downSkipsSeparatorsAndDisabled() {
        compare(MenuNav.handleKey(items, -1, "down", false).index, 0);
        compare(MenuNav.handleKey(items, 0, "down", false).index, 3);
        compare(MenuNav.handleKey(items, 3, "down", false).index, 4);
    }

    // A section header (Window > Move & Resize: Halves, Quarters, Arrange) is never selected nor run.
    function test_headersAreSkipped() {
        const headed = [{header: true, text: "Halves"}, {text: "Left"}, {separator: true}, {header: true, text: "Quarters"}, {text: "Top Left"}];
        verify(!MenuNav.selectable(headed[0]));
        compare(MenuNav.first(headed), 1);
        compare(MenuNav.handleKey(headed, 1, "down", true).index, 4);
        compare(MenuNav.handleKey(headed, 4, "down", true).index, 1);
        compare(MenuNav.handleKey(headed, 1, "up", true).index, 4);
        compare(MenuNav.handleKey(headed, 0, "return", true).action, "");
    }

    function test_wrapAround() {
        compare(MenuNav.handleKey(items, 4, "down", false).index, 0);
        compare(MenuNav.handleKey(items, 0, "up", false).index, 4);
        compare(MenuNav.handleKey(items, -1, "up", false).index, 4);
    }

    function test_homeEnd() {
        compare(MenuNav.handleKey(items, 3, "home", false).index, 0);
        compare(MenuNav.handleKey(items, 0, "end", false).index, 4);
    }

    function test_returnActivatesLeafOnly() {
        compare(MenuNav.handleKey(items, 3, "return", false).action, "activate");
        compare(MenuNav.handleKey(items, 2, "return", false).action, "");
        compare(MenuNav.handleKey(items, 1, "return", false).action, "");
        compare(MenuNav.handleKey(items, -1, "return", false).action, "");
    }

    function test_submenuKeys() {
        compare(MenuNav.handleKey(items, 4, "right", false).action, "openSubmenu");
        compare(MenuNav.handleKey(items, 4, "return", false).action, "openSubmenu");
        // macOS: Right on a row without a submenu (in a submenu too) and Left in a top-level menu move to the neighbouring
        // menu bar title; Left in a submenu closes it.
        compare(MenuNav.handleKey(items, 3, "right", false).action, "nextMenu");
        compare(MenuNav.handleKey(items, 3, "right", true).action, "nextMenu");
        compare(MenuNav.handleKey(items, 0, "left", true).action, "closeSubmenu");
        compare(MenuNav.handleKey(items, 0, "left", false).action, "previousMenu");
    }

    function test_escape() {
        compare(MenuNav.handleKey(items, 0, "escape", false).action, "close");
        compare(MenuNav.handleKey(items, 0, "escape", true).action, "closeSubmenu");
    }

    function test_noSelectableItems() {
        const dead = [{separator: true}, {text: "x", enabled: false}];
        compare(MenuNav.handleKey(dead, -1, "down", false).index, -1);
        compare(MenuNav.first(dead), -1);
        compare(MenuNav.last(dead), -1);
        compare(MenuNav.first([]), -1);
    }

    function test_unknownKeyIsNoop() {
        const r = MenuNav.handleKey(items, 3, "x", false);
        compare(r.index, 3);
        compare(r.action, "");
    }

    // A swatch row is one row: Up/Down pass it like an item, Left/Right move between its swatches (wrapping),
    // Return/Space choose the swatch; a disabled swatch row is skipped and Left/Right then do nothing.
    function test_swatchRows() {
        const swatches = [{id: "s0"}, {id: "s1"}, {id: "s2"}];
        const menu = [{text: "Open"}, {id: "tags", swatches: swatches}, {id: "off", swatches: swatches, enabled: false}, {text: "Copy"}];
        verify(MenuNav.hasSwatches(menu[1]));
        verify(!MenuNav.hasSwatches(menu[0]));
        verify(!MenuNav.hasSwatches({swatches: []}));
        compare(MenuNav.handleKey(menu, 0, "down", false).index, 1);
        compare(MenuNav.handleKey(menu, 1, "down", false).index, 3);
        compare(MenuNav.handleKey(menu, 1, "right", false).action, "swatchNext");
        compare(MenuNav.handleKey(menu, 1, "left", false).action, "swatchPrevious");
        compare(MenuNav.handleKey(menu, 1, "left", true).action, "swatchPrevious", "Left on a swatch row of a submenu moves, it does not close");
        compare(MenuNav.handleKey(menu, 1, "return", false).action, "activate");
        compare(MenuNav.handleKey(menu, 2, "right", false).action, "nextMenu", "a disabled swatch row is no swatch row: Right moves on");
        compare(MenuNav.stepSwatch(menu[1], 0, 1), 1);
        compare(MenuNav.stepSwatch(menu[1], 2, 1), 0);
        compare(MenuNav.stepSwatch(menu[1], 0, -1), 2);
        compare(MenuNav.stepSwatch(menu[1], -1, 1), 0);
        compare(MenuNav.stepSwatch(menu[0], 0, 1), -1);
    }
}
