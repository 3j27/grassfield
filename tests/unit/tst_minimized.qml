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

    function test_windowCallIsBuiltFromValidatedPieces() {
        compare(Minimized.windowCall("minimize", "0x55AB", {x: 2300.4, y: 1010.6, w: 52, h: 52}),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.minimize then p.minimize(\"0x55ab\", 2300, 1011, 52, 52) end end");
        compare(Minimized.windowCall("restore", "55ab", {x: 0, y: 0, w: 0, h: 0}),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.restore then p.restore(\"0x55ab\", 0, 0, 0, 0) end end");
        // Rejected: unknown verb, bad address, missing or non-finite rectangle, injection attempts.
        compare(Minimized.windowCall("hello", "55ab", {x: 0, y: 0, w: 1, h: 1}), "");
        compare(Minimized.windowCall("minimize(1) end; os.exit() --", "55ab", {x: 0, y: 0, w: 1, h: 1}), "");
        compare(Minimized.windowCall("minimize", "55ab\"); os.exit() --", {x: 0, y: 0, w: 1, h: 1}), "");
        compare(Minimized.windowCall("minimize", "55ab", null), "");
        compare(Minimized.windowCall("minimize", "55ab", {x: NaN, y: 0, w: 1, h: 1}), "");
        compare(Minimized.windowCall("minimize", "55ab", {x: "1); os.exit(", y: 0, w: 1, h: 1}), "");
    }

    function test_configCallAllowlist() {
        compare(Minimized.configCall("titlebarDoubleClick", "minimize"),
                "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.config then p.config(\"titlebarDoubleClick\", \"minimize\") end end");
        verify(Minimized.configCall("titlebarDoubleClick", "zoom") !== "");
        verify(Minimized.configCall("titlebarDoubleClick", "none") !== "");
        compare(Minimized.configCall("titlebarDoubleClick", "Zoom"), "");
        compare(Minimized.configCall("titlebarDoubleClick", "zoom\") os.exit() --"), "");
        compare(Minimized.configCall("titlebarDoubleClick", undefined), "");
        compare(Minimized.configCall("appearance", "dark"), "");
        compare(Minimized.configCall("__proto__", "zoom"), "");
        compare(Minimized.configCall("constructor", "zoom"), "");
    }

    // ---- overview verb (docs/specs/overview.md "Shell contract" 3) ----

    readonly property string ovHead: "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.overview then p.overview("
    readonly property string ovTail: ") end end"

    function test_overviewCallOpenIsAValidatedLuaString() {
        const call = Minimized.overviewCall({on: true, durationMs: 350, curve: [0.2, 0, 0, 1], windows: [{address: "0x55AB", x: 10.4, y: 20.6, w: 300.2, h: 200.5}]});
        compare(call, ovHead + "\"{\\\"on\\\":true,\\\"durationMs\\\":350,\\\"curve\\\":[0.2,0,0,1],\\\"windows\\\":[{\\\"address\\\":\\\"0x55ab\\\",\\\"x\\\":10,\\\"y\\\":21,\\\"w\\\":300,\\\"h\\\":201}]}\"" + ovTail);
    }

    function test_overviewCallCloseNeedsNoWindows() {
        compare(Minimized.overviewCall({on: false, durationMs: 0}), ovHead + "\"{\\\"on\\\":false,\\\"durationMs\\\":0}\"" + ovTail);
        verify(Minimized.overviewCall({on: false, durationMs: 350, curve: [0.2, 0, 0, 1]}) !== "");
    }

    function test_overviewCallRejectsEverythingInvalid() {
        const w = [{address: "55ab", x: 0, y: 0, w: 10, h: 10}];
        compare(Minimized.overviewCall(null), "");
        compare(Minimized.overviewCall({on: "yes", durationMs: 0}), "");
        compare(Minimized.overviewCall({durationMs: 0}), "");
        compare(Minimized.overviewCall({on: false}), "");
        compare(Minimized.overviewCall({on: false, durationMs: -1}), "");
        compare(Minimized.overviewCall({on: false, durationMs: 2001}), "");
        compare(Minimized.overviewCall({on: false, durationMs: NaN}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100}), "", "on:true needs windows");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: []}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: [{address: "55ab\"); os.exit() --", x: 0, y: 0, w: 1, h: 1}]}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: [{address: "55ab", x: NaN, y: 0, w: 1, h: 1}]}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: [{address: "55ab", x: Infinity, y: 0, w: 1, h: 1}]}), "");
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: [w[0], w[0]]}), "", "duplicate addresses");
        compare(Minimized.overviewCall({on: false, durationMs: 100, curve: [0.2, 0, 0]}), "");
        compare(Minimized.overviewCall({on: false, durationMs: 100, curve: [2, 0, 0, 1]}), "");
        compare(Minimized.overviewCall({on: false, durationMs: 100, curve: [0.2, 3, 0, 1]}), "");
        const many = [];
        for (let i = 0; i < 65; i++)
            many.push({address: (i + 1).toString(16), x: 0, y: 0, w: 1, h: 1});
        compare(Minimized.overviewCall({on: true, durationMs: 100, windows: many}), "", "more than 64 windows");
        verify(Minimized.overviewCall({on: true, durationMs: 100, windows: many.slice(0, 64)}) !== "");
    }

    function test_overviewCallClampsTinyRectsToOnePixel() {
        const call = Minimized.overviewCall({on: true, durationMs: 0, windows: [{address: "1", x: 5, y: 6, w: 0.2, h: 0}]});
        verify(call.indexOf("\\\"w\\\":1,\\\"h\\\":1") >= 0, call);
    }

    function test_moveWindowV2Parsing() {
        const m = Minimized.parseMoveWindowV2("55924770ce00,-98,special:minimized");
        compare(m.address, "55924770ce00");
        compare(m.workspace, "special:minimized");
        compare(Minimized.parseMoveWindowV2("55AB,2,2").workspace, "2");
        compare(Minimized.parseMoveWindowV2("55ab,3,name, with, commas").workspace, "name, with, commas");
        compare(Minimized.parseMoveWindowV2("55ab,2"), null);
        compare(Minimized.parseMoveWindowV2("zz,2,2"), null);
        compare(Minimized.parseMoveWindowV2("55ab,2,"), null);
        compare(Minimized.parseMoveWindowV2(""), null);
    }

    function test_pluginEventsOtherThanMinimizeRequestAreIgnored() {
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"minimized","address":"55ab"}'), "");
        compare(Minimized.minimizeRequestAddress('{"v":"gfc/1","type":"restored","address":"55ab"}'), "");
    }

    function test_pluginVerbAllowlist() {
        for (const v of ["hello", "minimize", "restore", "config", "appmenu"])
            verify(Minimized.isPluginVerb(v), v);
        verify(Minimized.isPluginVerb("overview"));
        verify(Minimized.isPluginVerb("cursor_refresh"));
        compare(Minimized.cursorRefreshCall(), "function() local p = hl.plugin and hl.plugin.grassfield; if p and p.cursor_refresh then p.cursor_refresh() end end");
        for (const v of ["theme"])
            verify(!Minimized.isPluginVerb(v), v);
        compare(Minimized.guardedPluginCall("theme", []), "");
        compare(Minimized.guardedPluginCall("x end os.exit() --", []), "");
        for (const v of ["", "Minimize", "minimize ", "x end os.execute('id') --", "minimize(1) end; os.exit() --", "constructor", "__proto__", "length"])
            verify(!Minimized.isPluginVerb(v), v);
        verify(!Minimized.isPluginVerb(undefined));
        verify(!Minimized.isPluginVerb(null));
        verify(!Minimized.isPluginVerb(7));
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
