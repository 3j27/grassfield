import QtQuick
import QtTest
import "../../shell/platform/Minimized.js" as Minimized
import "../../shell/dock/DockModel.js" as DockModel

// Minimized-window state model and the Dock section built from it.
TestCase {
    name: "Minimized"

    function rec(top, appId, address) {
        return {toplevel: top, address: address ? address : "1a", appId: appId, title: "T " + top};
    }

    function test_addIsIdempotentAndRemove() {
        let list = Minimized.add([], rec("a", "foot"));
        list = Minimized.add(list, rec("a", "foot"));
        compare(list.length, 1);
        verify(Minimized.has(list, "a"));
        list = Minimized.remove(list, "a");
        compare(list.length, 0);
    }

    function test_pruneDropsClosedWindows() {
        const list = [rec("a", "foot"), rec("b", "foot")];
        compare(Minimized.prune(list, ["b", "c"]).map(r => r.toplevel).join(","), "b");
    }

    function test_forAppIsCaseInsensitive() {
        const list = [rec("a", "Foot"), rec("b", "chromium")];
        compare(Minimized.forApp(list, "foot").length, 1);
    }

    function test_addressValidation() {
        compare(Minimized.normalizeAddress("0x5599AABB"), "5599aabb");
        compare(Minimized.normalizeAddress("5599aabb"), "5599aabb");
        compare(Minimized.normalizeAddress("zz"), "");
        compare(Minimized.normalizeAddress("1; hl.dsp.exit()"), "");
        compare(Minimized.normalizeAddress(""), "");
    }

    function test_minimizeRequestParsing() {
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"minimize-request","address":"55AB"}'), "55ab");
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"capabilities","address":"55ab"}'), "");
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/2","type":"minimize-request","address":"55ab"}'), "");
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"minimize-request","address":"x\\"); hl.dsp.exit() --"}'), "");
        compare(Minimized.minimizeRequestAddress("not json"), "");
    }

    function lookup(id) {
        return id === "foot" ? {id: "foot", name: "Foot", icon: "foot-icon"} : null;
    }

    function test_dockSectionSitsBetweenSeparatorAndTrash() {
        const tiles = DockModel.minimizedItems([rec("a", "foot", "1a"), rec("b", "mystery", "2b")], lookup);
        compare(tiles[0].name, "T a");
        compare(tiles[0].icon, "foot-icon");
        compare(tiles[1].icon, "mystery");
        const items = DockModel.withTail([{kind: "app", key: "foot"}], tiles);
        compare(items.map(i => i.kind).join(","), "app,separator,minimized,minimized,trash");
    }

    function test_noMinimizedKeepsPreviousLayout() {
        compare(DockModel.withTail([]).map(i => i.kind).join(","), "separator,trash");
        compare(DockModel.withTail([], DockModel.minimizedItems([], lookup)).map(i => i.kind).join(","), "separator,trash");
    }

    function test_tileNameFallsBackToAppName() {
        const tiles = DockModel.minimizedItems([{toplevel: "a", address: "1", appId: "foot", title: ""}], lookup);
        compare(tiles[0].name, "Foot");
    }

    function test_moveRequestValidates() {
        compare(Minimized.moveRequest("0x55AB", "3"), "hl.dsp.window.move({ workspace = \"3\", follow = false, window = \"address:0x55ab\" })");
        compare(Minimized.moveRequest("55ab", "special:minimized").indexOf("special:minimized") > 0, true);
        compare(Minimized.moveRequest("0x1; hl.dsp.exit()", "3"), "");
        compare(Minimized.moveRequest("\"})", "3"), "");
        compare(Minimized.moveRequest("55ab", "3\", x = 1"), "");
        compare(Minimized.moveRequest("55ab", ""), "");
        compare(Minimized.moveRequest("", "3"), "");
        compare(Minimized.moveRequest("55ab", "undefined"), "");
        compare(Minimized.moveRequest("55ab", undefined), "");
        compare(Minimized.moveRequest("55ab", "foo"), "");
        compare(Minimized.moveRequest("55ab", "0"), "");
        compare(Minimized.moveRequest("55ab", 4).indexOf("workspace = \"4\"") > 0, true);
    }

    function test_focusRequestValidates() {
        compare(Minimized.focusRequest(3), "hl.dsp.focus({ workspace = \"3\" })");
        compare(Minimized.focusRequest("12"), "hl.dsp.focus({ workspace = \"12\" })");
        compare(Minimized.focusRequest(0), "");
        compare(Minimized.focusRequest(-1), "");
        compare(Minimized.focusRequest(1.5), "");
        compare(Minimized.focusRequest(undefined), "");
        compare(Minimized.focusRequest("3\", x = 1"), "");
    }

    function test_fullscreenRequest() {
        compare(Minimized.fullscreenRequest("0xAB12", "maximized"), "hl.dsp.window.fullscreen({ mode = \"maximized\", window = \"address:0xab12\" })");
        compare(Minimized.fullscreenRequest("0xAB12", "bogus"), "");
        compare(Minimized.fullscreenRequest("zz", "maximized"), "");
    }

    function test_finiteRect() {
        verify(Minimized.finiteRect({x: 1, y: 2, w: 3, h: 4}) !== null);
        compare(Minimized.finiteRect({x: NaN, y: 2, w: 3, h: 4}), null);
        compare(Minimized.finiteRect({x: 1, y: Infinity, w: 3, h: 4}), null);
        compare(Minimized.finiteRect(null), null);
    }

    function test_isZoomed() {
        compare(Minimized.isZoomed({fullscreen: 1}), true);
        compare(Minimized.isZoomed({fullscreen: 2}), false);
        compare(Minimized.isZoomed({fullscreen: 0}), false);
        compare(Minimized.isZoomed(null), false);
    }
}
