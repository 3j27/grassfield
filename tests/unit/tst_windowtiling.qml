import QtQuick
import QtTest
import "../../shell/platform/WindowTiling.js" as WindowTiling

// The tiling popover's link to the compositor (shell/platform/WindowTiling.js, docs/specs/tiling.md TL22-TL26): the plugin's
// tile-hover event, where the popover opens, the outputs a window can move to.
TestCase {
    name: "WindowTiling"

    function test_parseHoverReadsEnterOpenAndLeave() {
        const enter = WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"55AB","state":"enter","x":120.5,"y":40,"w":14,"h":14,"tileable":true}');
        compare(enter.address, "55ab");
        compare(enter.state, "enter");
        compare(JSON.stringify(enter.light), JSON.stringify({x: 120.5, y: 40, w: 14, h: 14}));
        verify(enter.tileable);
        const open = WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"0x1","state":"open","x":0,"y":0,"w":32,"h":32,"tileable":false}');
        compare(open.state, "open");
        compare(open.address, "1");
        verify(!open.tileable);
        const leave = WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"55ab","state":"leave"}');
        compare(leave.state, "leave");
        compare(leave.light, null);
        // tileable is true only when the plugin says so.
        verify(!WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"1","state":"enter","x":0,"y":0,"w":1,"h":1,"tileable":"yes"}').tileable);
    }

    function test_parseHoverRefusesAnythingElse() {
        const bad = [
            "", "not json", "null", "[]",
            '{"v":"gfc/2","type":"tile-hover","address":"1","state":"leave"}',
            '{"v":"gfc/1","type":"tiling","gen":3}',
            '{"v":"gfc/1","type":"minimize-request","address":"1"}',
            '{"v":"gfc/1","type":"tile-hover","address":"xyz","state":"leave"}',
            '{"v":"gfc/1","type":"tile-hover","address":"12345678901234567","state":"leave"}',
            '{"v":"gfc/1","type":"tile-hover","address":7,"state":"leave"}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"hover"}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"enter"}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"enter","x":0,"y":0,"w":0,"h":14}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"open","x":"0","y":0,"w":14,"h":14}',
            '{"v":"gfc/1","type":"tile-hover","address":"1","state":"open","x":0,"y":0,"w":-1,"h":14}'
        ];
        for (const text of bad)
            compare(WindowTiling.parseHover(text), null, text);
    }

    readonly property var screens: [
        {name: "eDP-1", model: "Panel", x: 0, y: 0, width: 1440, height: 900},
        {name: "DP-1", model: " LG UltraFine ", x: 1440, y: -200, width: 2560, height: 1440},
        {name: "HDMI-A-1", model: "", x: -1920, y: 0, width: 1920, height: 1080}
    ]

    function test_popoverAnchorIsInTheScreenOfTheLightsMiddle() {
        const a = WindowTiling.popoverAnchor({x: 1500, y: -150, w: 14, h: 14}, screens);
        compare(a.screen, "DP-1");
        compare(a.x, 67);
        compare(a.y, 64);
        compare(a.flipY, 50);
        compare(JSON.stringify(a.light), JSON.stringify({x: 60, y: 50, w: 14, h: 14}));
        // A light straddling two screens belongs to the one under its middle.
        compare(WindowTiling.popoverAnchor({x: 1436, y: 10, w: 14, h: 14}, screens).screen, "DP-1");
        compare(WindowTiling.popoverAnchor({x: 1420, y: 10, w: 14, h: 14}, screens).screen, "eDP-1");
        compare(WindowTiling.popoverAnchor({x: -100, y: 500, w: 14, h: 14}, screens).screen, "HDMI-A-1");
        compare(WindowTiling.popoverAnchor({x: 100, y: 5000, w: 14, h: 14}, screens), null);
        compare(WindowTiling.popoverAnchor(null, screens), null);
        compare(WindowTiling.popoverAnchor({x: 0, y: 0, w: 14, h: 14}, null), null);
    }

    function test_otherOutputsAreTheOthersWithTheirNames() {
        const others = WindowTiling.otherOutputs(screens, "DP-1");
        compare(others.map(o => o.name).join(","), "eDP-1,HDMI-A-1");
        verify(others[0].builtIn, "an eDP connector is the built-in panel");
        verify(!others[1].builtIn);
        compare(WindowTiling.otherOutputs(screens, "eDP-1")[0].model, "LG UltraFine");
        for (const name of ["LVDS-1", "DSI-1"])
            verify(WindowTiling.otherOutputs([{name: name, model: ""}], "")[0].builtIn, name);
        verify(!WindowTiling.otherOutputs([{name: "XeDP-1", model: ""}], "")[0].builtIn);
        compare(WindowTiling.otherOutputs([screens[0]], "eDP-1").length, 0, "one output: no Move to row");
        compare(WindowTiling.otherOutputs(null, "").length, 0);
    }

    // TL22, TL34 (integrator review of 4ead6fb): never over the lock, the polkit sheet, a full-attention surface or the Dock.
    function test_hoverRefusedByWhatHoldsTheScreen() {
        const free = {locked: false, authorizing: false, holders: [], dockKeyboard: false};
        compare(WindowTiling.hoverRefusedBy(free), "");
        compare(WindowTiling.hoverRefusedBy(Object.assign({}, free, {holders: ["popup"]})), "", "a popup: the caller decides");
        compare(WindowTiling.hoverRefusedBy(Object.assign({}, free, {locked: true})), "lock");
        compare(WindowTiling.hoverRefusedBy(Object.assign({}, free, {authorizing: true})), "authorization");
        for (const name of ["search", "apps", "overview", "switcher", "notification-center", "widgets-menu-GF-REF"])
            compare(WindowTiling.hoverRefusedBy(Object.assign({}, free, {holders: ["popup", name]})), name, name);
        compare(WindowTiling.hoverRefusedBy(Object.assign({}, free, {dockKeyboard: true})), "dock");
        compare(WindowTiling.hoverRefusedBy(Object.assign({}, free, {locked: true, authorizing: true})), "lock", "the lock first");
        compare(WindowTiling.hoverRefusedBy(null), "lock", "unknown: refused");
        compare(WindowTiling.hoverRefusedBy({authorizing: false, holders: [], dockKeyboard: false}), "lock", "an unknown lock state counts as locked");
    }

    function test_nextOutputGoesByPositionAndWraps() {
        compare(WindowTiling.nextOutput(screens, "eDP-1", "right"), "DP-1");
        compare(WindowTiling.nextOutput(screens, "eDP-1", "left"), "HDMI-A-1");
        compare(WindowTiling.nextOutput(screens, "DP-1", "right"), "HDMI-A-1", "wraps");
        compare(WindowTiling.nextOutput(screens, "HDMI-A-1", "left"), "DP-1", "wraps");
        compare(WindowTiling.nextOutput([screens[0]], "eDP-1", "right"), "");
        compare(WindowTiling.nextOutput(screens, "DP-9", "right"), "");
        compare(WindowTiling.nextOutput(screens, "eDP-1", "up"), "");
        // Stacked outputs (same x): top to bottom.
        const stacked = [{name: "B", x: 0, y: 1080}, {name: "A", x: 0, y: 0}];
        compare(WindowTiling.nextOutput(stacked, "A", "right"), "B");
    }

    // ---- step 4a: the Layouts section and the suggestions (TL27, TL28) ----

    function test_outputClassFollowsThePluginsRule() {
        compare(WindowTiling.outputClass(1919, 1080), "small");
        compare(WindowTiling.outputClass(1440, 900), "small");
        compare(WindowTiling.outputClass(1920, 1080), "large");
        compare(WindowTiling.outputClass(2560, 1440), "large");
        compare(WindowTiling.outputClass(2560, 1080), "ultrawide", "64:27");
        compare(WindowTiling.outputClass(3440, 1440), "ultrawide", "43:18, about 21:9");
        compare(WindowTiling.outputClass(2100, 900), "ultrawide", "exactly 21:9");
        compare(WindowTiling.outputClass(2099, 900), "large", "just under 21:9");
        compare(WindowTiling.outputClass(1680, 720), "ultrawide", "21:9 under 1920 wide");
        compare(WindowTiling.outputClass(1080, 1920), "portrait");
        compare(WindowTiling.outputClass(1000, 1000), "small", "square is not portrait");
        compare(WindowTiling.outputClass(0, 1080), "small");
        compare(WindowTiling.outputClass(NaN, 1080), "small");
    }

    function test_parseNoticeReadsTheTilingNotice() {
        compare(JSON.stringify(WindowTiling.parseNotice('{"v":"gfc/1","type":"tiling","gen":7,"reason":"placed"}')), JSON.stringify({gen: 7, reason: "placed"}));
        compare(JSON.stringify(WindowTiling.parseNotice('{"v":"gfc/1","type":"tiling","gen":0}')), JSON.stringify({gen: 0, reason: ""}));
        for (const text of ["", "x", "null", '{"v":"gfc/2","type":"tiling","gen":1}', '{"v":"gfc/1","type":"tile-hover","gen":1}', '{"v":"gfc/1","type":"tiling"}',
                 '{"v":"gfc/1","type":"tiling","gen":-1}', '{"v":"gfc/1","type":"tiling","gen":1.5}', '{"v":"gfc/1","type":"tiling","gen":"1"}'])
            compare(WindowTiling.parseNotice(text), null, text);
    }

    function reply(suggestion: var): string {
        return JSON.stringify({v: "gfc/1", type: "tiling", gen: 12, outputs: [], suggestion: suggestion});
    }

    readonly property var goodSuggestion: ({gen: 12, address: "ABC", layout: "thirds", output: "GF-REF", zones: [{zone: 0, x: 8, y: 64, w: 629, h: 926}, {zone: 2, x: 1283, y: 64, w: 629, h: 926}], windows: ["d1", "0xD2"]})

    function test_parseSuggestionReadsTheReply() {
        const sg = WindowTiling.parseSuggestion(reply(goodSuggestion));
        compare(sg.gen, 12);
        compare(sg.address, "abc");
        compare(sg.layout, "thirds");
        compare(sg.output, "GF-REF");
        compare(JSON.stringify(sg.zones), JSON.stringify(goodSuggestion.zones));
        compare(JSON.stringify(sg.windows), JSON.stringify(["d1", "d2"]));
        compare(WindowTiling.parseSuggestion(reply(null)), null, "no suggestion");
    }

    function test_parseSuggestionRefusesAnythingMalformed() {
        const bad = [];
        const variant = change => bad.push(Object.assign({}, goodSuggestion, change));
        variant({gen: "12"});
        variant({address: "xyz"});
        variant({layout: ""});
        variant({output: 7});
        variant({zones: []});
        variant({zones: [{zone: 0, x: 0, y: 0, w: 0, h: 10}]});
        variant({zones: [{zone: -1, x: 0, y: 0, w: 10, h: 10}]});
        variant({zones: [{zone: 0.5, x: 0, y: 0, w: 10, h: 10}]});
        variant({zones: [{zone: 0, x: "0", y: 0, w: 10, h: 10}]});
        variant({windows: []});
        variant({windows: ["d1", "nope"]});
        variant({windows: new Array(13).fill("d1")});
        for (const sg of bad)
            compare(WindowTiling.parseSuggestion(reply(sg)), null, JSON.stringify(sg));
        for (const text of ["", "not json", JSON.stringify({v: "gfc/2", type: "tiling", suggestion: goodSuggestion}), JSON.stringify({v: "gfc/1", type: "stages", suggestion: goodSuggestion})])
            compare(WindowTiling.parseSuggestion(text), null, text);
    }

    function test_suggestionGridGivesTheLargestTiles() {
        // Twelve windows in a quarter of GF-REF: four columns of three rows.
        const quarter = WindowTiling.suggestionGrid(12, 944, 470, 1.6, 24, 12, 280);
        compare(quarter.columns, 4);
        compare(quarter.rows, 3);
        compare(quarter.tileWidth, 186);
        compare(quarter.thumbHeight, 116);
        compare(quarter.tileHeight, 140);
        verify(quarter.columns * quarter.tileWidth + (quarter.columns + 1) * 12 <= 944);
        verify(quarter.rows * quarter.tileHeight + (quarter.rows + 1) * 12 <= 470);
        // Two windows in a tall third: one column, the tiles at their largest width.
        const third = WindowTiling.suggestionGrid(2, 629, 926, 1.6, 24, 12, 280);
        compare(third.columns, 1);
        compare(third.tileWidth, 280);
        compare(JSON.stringify(WindowTiling.suggestionGrid(0, 900, 900, 1.6, 24, 12, 280)), JSON.stringify({columns: 0, rows: 0, tileWidth: 0, thumbHeight: 0, tileHeight: 0}));
        compare(WindowTiling.suggestionGrid(3, 10, 10, 1.6, 24, 12, 280).columns, 0, "no room");
    }

    function test_gridStepMovesThroughTheTiles() {
        // 7 tiles in rows of 3: 0 1 2 / 3 4 5 / 6
        compare(WindowTiling.gridStep(-1, 7, 3, "down"), 0, "the first key chooses the first tile");
        compare(WindowTiling.gridStep(0, 7, 3, "right"), 1);
        compare(WindowTiling.gridStep(6, 7, 3, "right"), 0, "wraps");
        compare(WindowTiling.gridStep(0, 7, 3, "left"), 6, "wraps back");
        compare(WindowTiling.gridStep(1, 7, 3, "down"), 4);
        compare(WindowTiling.gridStep(4, 7, 3, "down"), 4, "no tile below: stays");
        compare(WindowTiling.gridStep(3, 7, 3, "down"), 6);
        compare(WindowTiling.gridStep(1, 7, 3, "up"), 1, "first row: stays");
        compare(WindowTiling.gridStep(5, 7, 3, "up"), 2);
        compare(WindowTiling.gridStep(4, 7, 3, "home"), 0);
        compare(WindowTiling.gridStep(1, 7, 3, "end"), 6);
        compare(WindowTiling.gridStep(2, 7, 3, "other"), 2);
        compare(WindowTiling.gridStep(0, 0, 3, "right"), -1, "no tile");
    }
}
