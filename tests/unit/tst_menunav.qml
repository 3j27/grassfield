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
        compare(MenuNav.handleKey(items, 3, "right", false).action, "");
        compare(MenuNav.handleKey(items, 0, "left", true).action, "closeSubmenu");
        compare(MenuNav.handleKey(items, 0, "left", false).action, "");
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
}
