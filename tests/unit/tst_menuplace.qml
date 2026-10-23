import QtQuick
import QtTest
import "../../ui/Grassfield/Ui/MenuPlace.js" as MenuPlace

// Menu placement (macOS model): a menu never moves once open; a submenu opens beside its row, to the right or, with no
// room, to the left, and the parent stays put. Screen 1920x1080, margin 6, menu 220x300, submenu 200x160, overlap 4.
TestCase {
    name: "MenuPlace"

    readonly property var area: ({w: 1920, h: 1080})
    readonly property var menu: ({w: 220, h: 300})

    function test_placeAtThePointerWhenItFits() {
        const p = MenuPlace.place({x: 700, y: 500}, menu, area, 6);
        compare(p.x, 700);
        compare(p.y, 500);
    }

    function test_placeFlipsLeftOfThePointerAtTheRightEdge() {
        const p = MenuPlace.place({x: 1900, y: 100}, menu, area, 6);
        compare(p.x, 1900 - 220);
        compare(p.y, 100);
    }

    function test_placeSlidesUpAtTheBottomEdge() {
        const p = MenuPlace.place({x: 100, y: 1070}, menu, area, 6);
        compare(p.x, 100);
        compare(p.y, 1080 - 6 - 300);
    }

    function test_placeCornerAndTallMenu() {
        const p = MenuPlace.place({x: 1919, y: 1079}, menu, area, 6);
        compare(p.x, 1920 - 6 - 220);
        compare(p.y, 1080 - 6 - 300);
        // A menu taller than the area sits at the margin (never negative).
        const q = MenuPlace.place({x: 10, y: 10}, {w: 220, h: 2000}, area, 6);
        compare(q.y, 6);
    }

    // The parent's position is a function of the parent alone: no submenu size is an input of place(), so opening a submenu
    // cannot move it. At every edge region the submenu stays on the screen.
    function test_submenuNeverMovesTheParentAndStaysOnScreen() {
        for (const px of [0, 5, 700, 1700, 1800, 1914, 1919]) {
            for (const py of [0, 5, 500, 700, 790, 1000, 1079]) {
                const at = {x: px, y: py};
                const parent = MenuPlace.place(at, menu, area, 6);
                compare(JSON.stringify(MenuPlace.place(at, menu, area, 6)), JSON.stringify(parent));
                for (const rowY of [8, 150, 290]) {
                    const sx = MenuPlace.submenuX(parent.x, menu.w, 200, 4, area.w, 6);
                    const sy = MenuPlace.submenuY(parent.y, rowY, 160, area.h, 6);
                    verify(parent.x + sx >= 6, "submenu left edge on screen at " + px + "," + py);
                    verify(parent.x + sx + 200 <= area.w - 6, "submenu right edge on screen at " + px + "," + py);
                    verify(parent.y + sy >= 6);
                    verify(parent.y + sy + 160 <= area.h - 6);
                }
            }
        }
    }

    function test_submenuOpensRightWhenThereIsRoom() {
        compare(MenuPlace.submenuX(700, 220, 200, 4, 1920, 6), 216);
    }

    function test_submenuFlipsLeftWithNoRoomOnTheRight() {
        compare(MenuPlace.submenuX(1600, 220, 200, 4, 1920, 6), 4 - 200);
    }

    function test_submenuWithNoRoomEitherSideStaysInside() {
        // 300-wide area: neither side fits a 250-wide submenu; as far right as the area allows.
        const x = MenuPlace.submenuX(20, 100, 250, 4, 300, 6);
        compare(20 + x + 250, 300 - 6);
    }

    function test_submenuMovesUpAtTheBottomAndStaysOnItsRowWhenItFits() {
        compare(MenuPlace.submenuY(100, 40, 160, 1080, 6), 40);
        compare(MenuPlace.submenuY(770, 280, 160, 1080, 6), 1080 - 6 - 770 - 160);
    }
}
