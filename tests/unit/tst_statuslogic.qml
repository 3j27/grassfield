import QtQuick
import QtTest
import "../../shell/menubar/StatusLogic.js" as Logic

// Pure decisions of the menu bar's status area: which tray items get a slot, what a press does (StatusNotifierItem
// semantics), the accessible name, when Now Playing shows, and which items crowding hides.
TestCase {
    name: "StatusLogic"

    function item(over) {
        return Object.assign({id: "app", title: "App", tooltipTitle: "", icon: "image://icon/app", status: 1, hasMenu: true, onlyMenu: false}, over || {});
    }

    function test_traySlots() {
        verify(Logic.trayShown(item()));
        verify(Logic.trayShown(item({status: 2})), "NeedsAttention is shown");
        verify(!Logic.trayShown(item({status: 0})), "Passive is hidden");
        verify(!Logic.trayShown(item({icon: ""})), "no icon: a phantom slot");
        verify(!Logic.trayShown(null));
        verify(!Logic.trayShown(undefined));
        verify(!Logic.trayShown("chrome_status_icon_1"), "an id string is not an item");
    }

    function test_attention() {
        verify(Logic.needsAttention(item({status: 2})));
        verify(!Logic.needsAttention(item()));
        verify(!Logic.needsAttention(null));
    }

    function test_clickSemantics() {
        // Not ItemIsMenu: the primary click is Activate, the menu is the context menu.
        compare(Logic.clickAction(item(), "left"), "activate");
        compare(Logic.clickAction(item(), "right"), "menu");
        compare(Logic.clickAction(item(), "middle"), "secondary");
        // ItemIsMenu: the primary click opens the menu.
        compare(Logic.clickAction(item({onlyMenu: true}), "left"), "menu");
        // ItemIsMenu without a menu: nothing to open, Activate.
        compare(Logic.clickAction(item({onlyMenu: true, hasMenu: false}), "left"), "activate");
        // No menu at all: the context click does nothing.
        compare(Logic.clickAction(item({hasMenu: false}), "right"), "none");
        compare(Logic.clickAction(null, "left"), "none");
    }

    function test_opensMenu() {
        verify(Logic.opensMenu(item()));
        verify(!Logic.opensMenu(item({hasMenu: false})));
        verify(!Logic.opensMenu(null));
    }

    function test_accessibleName() {
        compare(Logic.accessibleName(item({title: " Steam "})), "Steam");
        compare(Logic.accessibleName(item({title: "", tooltipTitle: "Tip"})), "Tip");
        compare(Logic.accessibleName(item({title: "  ", tooltipTitle: "", id: "chrome_status_icon_1"})), "chrome_status_icon_1");
        compare(Logic.accessibleName(null), "");
    }

    function test_nowPlaying() {
        verify(Logic.nowPlayingShown(true, true, true, ""), "playing");
        verify(Logic.nowPlayingShown(true, true, false, "Song"), "paused with a track");
        verify(!Logic.nowPlayingShown(true, true, false, ""), "a player with no track");
        verify(!Logic.nowPlayingShown(true, false, true, "Song"), "no player");
        verify(!Logic.nowPlayingShown(false, true, true, "Song"), "turned off in Settings");
    }

    function keys(hidden) {
        return Object.keys(hidden).sort().join(",");
    }

    function bar(widths) {
        return widths.map((w, i) => ({key: "k" + i, width: w, optional: i < 3}));
    }

    function test_crowdingNothingHiddenWhenItFits() {
        compare(keys(Logic.hiddenItems(100, bar([20, 20, 20, 20, 20]), 0)), "");
        compare(keys(Logic.hiddenItems(120, bar([20, 20, 20, 20, 20]), 4)), "");
    }

    function test_crowdingHidesFromTheLeft() {
        // 100 needed, 80 available: the leftmost optional goes first.
        compare(keys(Logic.hiddenItems(80, bar([20, 20, 20, 20, 20]), 0)), "k0");
        compare(keys(Logic.hiddenItems(60, bar([20, 20, 20, 20, 20]), 0)), "k0,k1");
        compare(keys(Logic.hiddenItems(40, bar([20, 20, 20, 20, 20]), 0)), "k0,k1,k2");
    }

    function test_crowdingNeverHidesMandatory() {
        // Only the two mandatory items remain, they stay even when they do not fit.
        compare(keys(Logic.hiddenItems(10, bar([20, 20, 20, 20, 20]), 0)), "k0,k1,k2");
    }

    function test_crowdingStopsAsSoonAsItFits() {
        // Widths differ: dropping the first (30) is enough for 100 -> 70.
        compare(keys(Logic.hiddenItems(75, bar([30, 10, 10, 25, 25]), 0)), "k0");
    }

    function test_crowdingCountsTheGap() {
        // 5 items of 20 plus a gap of 2 each = 110: 105 available hides one.
        compare(keys(Logic.hiddenItems(105, bar([20, 20, 20, 20, 20]), 2)), "k0");
    }

    function test_crowdingEmpty() {
        compare(keys(Logic.hiddenItems(0, [], 0)), "");
    }
}
