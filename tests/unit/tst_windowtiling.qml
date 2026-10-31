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

    // #48 nested pass, MAJOR C (TL8): a window that does not fit half of its output; only the plugin's true counts.
    function test_parseHoverReadsSplittable() {
        verify(WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"1","state":"open","x":0,"y":0,"w":14,"h":14,"tileable":true,"splittable":true}').splittable);
        verify(!WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"1","state":"open","x":0,"y":0,"w":14,"h":14,"tileable":true,"splittable":false}').splittable);
        verify(!WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"1","state":"open","x":0,"y":0,"w":14,"h":14,"tileable":true}').splittable, "an older plugin: not known to fit");
        verify(!WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"1","state":"enter","x":0,"y":0,"w":14,"h":14,"splittable":"yes"}').splittable);
        verify(!WindowTiling.parseHover('{"v":"gfc/1","type":"tile-hover","address":"1","state":"leave","splittable":true}').splittable, "leave carries nothing");
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

    // ADR-0036 D64: the green light clicked while its popover is open does what the plugin's light does.
    function test_greenActionIsTheLightsOwn() {
        compare(WindowTiling.greenAction(false, false, false), "toggleZoom");
        compare(WindowTiling.greenAction(false, false, true), "enterFullscreen");
        compare(WindowTiling.greenAction(true, false, false), "leaveFullscreen");
        compare(WindowTiling.greenAction(true, false, true), "leaveFullscreen", "Alt changes nothing in full screen");
        compare(WindowTiling.greenAction(false, true, false), "unsplit");
        compare(WindowTiling.greenAction(true, true, true), "unsplit", "a Split View member leaves it, with or without Alt");
        compare(WindowTiling.greenAction(true, true, false), "unsplit");
        compare(WindowTiling.greenAction(false, true, true), "unsplit");
    }

    // Integrator review of 7096305, MAJOR 1: a Split View member's light lies under the menu bar's strip.
    function test_stripPressGoesToTheBarOnlyInView() {
        compare(WindowTiling.stripPress(true, false), "bar");
        compare(WindowTiling.stripPress(true, true), "bar", "a bar in view covers the light under it");
        compare(WindowTiling.stripPress(false, true), "green", "the bar away: the light under the strip is the light's");
        compare(WindowTiling.stripPress(false, false), "close", "the bar away: any click outside");
    }

    function test_inLightExcludesTheFarEdges() {
        const l = {x: 10, y: 20, w: 14, h: 14};
        verify(WindowTiling.inLight(l, 10, 20), "top left corner");
        verify(WindowTiling.inLight(l, 23.5, 33.5));
        verify(!WindowTiling.inLight(l, 24, 25), "right edge");
        verify(!WindowTiling.inLight(l, 15, 34), "bottom edge");
        verify(!WindowTiling.inLight(l, 9.5, 25), "left of it");
        verify(!WindowTiling.inLight(l, 15, 19.5), "above it");
        verify(!WindowTiling.inLight(null, 15, 25), "no light");
        compare(WindowTiling.inLight(undefined, 15, 25), false, "a boolean");
    }

    // ADR-0036 D65: the menu bar comes and goes with a full-screen window's revealed titlebar.
    function test_parseTitlebarRevealReadsTheEvent() {
        compare(JSON.stringify(WindowTiling.parseTitlebarReveal('{"v":"gfc/1","type":"titlebar-reveal","output":"GF-REF","revealed":true}')),
                JSON.stringify({output: "GF-REF", revealed: true}));
        compare(JSON.stringify(WindowTiling.parseTitlebarReveal('{"v":"gfc/1","type":"titlebar-reveal","output":"DP-2","revealed":false}')),
                JSON.stringify({output: "DP-2", revealed: false}));
        for (const text of ["", "x", "null", '{"v":"gfc/2","type":"titlebar-reveal","output":"A","revealed":true}', '{"v":"gfc/1","type":"tiling","output":"A","revealed":true}',
                 '{"v":"gfc/1","type":"titlebar-reveal","revealed":true}', '{"v":"gfc/1","type":"titlebar-reveal","output":"","revealed":true}',
                 '{"v":"gfc/1","type":"titlebar-reveal","output":7,"revealed":true}', '{"v":"gfc/1","type":"titlebar-reveal","output":"A"}',
                 '{"v":"gfc/1","type":"titlebar-reveal","output":"A","revealed":1}', '{"v":"gfc/1","type":"titlebar-reveal","output":"A","revealed":"true"}'])
            compare(WindowTiling.parseTitlebarReveal(text), null, text);
    }

    function test_revealsAfterKeepsEachOutputOnce() {
        compare(JSON.stringify(WindowTiling.revealsAfter([], {output: "A", revealed: true})), JSON.stringify(["A"]));
        compare(JSON.stringify(WindowTiling.revealsAfter(["A"], {output: "A", revealed: true})), JSON.stringify(["A"]), "once");
        compare(JSON.stringify(WindowTiling.revealsAfter(["A", "B"], {output: "A", revealed: false})), JSON.stringify(["B"]));
        compare(JSON.stringify(WindowTiling.revealsAfter(["B"], {output: "A", revealed: false})), JSON.stringify(["B"]), "away from an output not revealed");
        compare(JSON.stringify(WindowTiling.revealsAfter(null, {output: "A", revealed: true})), JSON.stringify(["A"]), "no list yet");
        const before = ["A"];
        verify(WindowTiling.revealsAfter(before, {output: "B", revealed: true}) !== before, "a new list: bindings see the change");
        compare(JSON.stringify(before), JSON.stringify(["A"]), "the old list is left as it was");
    }

    function test_suggestionWaitIsGenerous() {
        // A loaded machine can take seconds to start hyprctl (merge note of #56, ADR-0036 D68).
        compare(WindowTiling.suggestionWaitMs, 6000);
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

    // Integrator review of 3714f47 (LOW, carried): a refused pick gives the panel back.
    function test_pickPendingEndsOnARefusal() {
        compare(WindowTiling.pickPending(true, "invalid"), false, "the zone was taken meanwhile");
        compare(WindowTiling.pickPending(true, "locked"), false);
        compare(WindowTiling.pickPending(true, "placed"), true, "the next suggestion follows the placed notice's reply");
        compare(WindowTiling.pickPending(true, "forgotten"), true);
        compare(WindowTiling.pickPending(false, "placed"), false);
        compare(WindowTiling.pickPending(false, "invalid"), false);
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

    // ---- step 4b: tile groups (TL29) ----

    function stateReply(windows: var): string {
        return JSON.stringify({v: "gfc/1", type: "tiling", gen: 5, outputs: [{name: "GF-REF", windows: windows.slice(0, 3)}, {name: "DP-1", windows: windows.slice(3)}], suggestion: null});
    }

    function test_parseGroupsReadsTheGroupsOfTheReply() {
        const g = WindowTiling.parseGroups(stateReply([
            {address: "A1", group: 2, state: "tiled"}, {address: "b2", group: 0, state: "tiled"}, {address: "c3", group: 2, state: "suspended"},
            {address: "d4", group: 7, state: "tiled"}, {address: "0xE5", group: 7, state: "resizing"}, {address: "f6", group: 9, state: "tiled"}
        ]));
        compare(JSON.stringify(g.members), JSON.stringify({"2": ["a1", "c3"], "7": ["d4", "e5"]}), "groups of two or more, a suspended member counts");
        compare(g.groupOf["a1"], "2");
        compare(g.groupOf["e5"], "7");
        compare(g.groupOf["b2"], undefined, "no group");
        compare(g.groupOf["f6"], undefined, "a group of one is left out");
        compare(JSON.stringify(WindowTiling.parseGroups(stateReply([]))), JSON.stringify({groupOf: {}, members: {}}));
        for (const text of ["", "x", JSON.stringify({v: "gfc/1", type: "tiling"}), JSON.stringify({v: "gfc/2", type: "tiling", outputs: []}), JSON.stringify({v: "gfc/1", type: "stages", outputs: []})])
            compare(WindowTiling.parseGroups(text), null, text);
        // Group 0 is no group, however many windows have it (review of cd74af2, mutant S4).
        const none = WindowTiling.parseGroups(stateReply([{address: "a1", group: 0}, {address: "a2", group: 0}, {address: "a3", group: -1}, {address: "a4", group: -1}]));
        compare(JSON.stringify(none), JSON.stringify({groupOf: {}, members: {}}));
        // Malformed windows are skipped, not fatal.
        const skipped = WindowTiling.parseGroups(stateReply([{address: "zz", group: 3}, {address: "a1", group: "3"}, {address: "a2", group: 3}, null, {address: "a3", group: 3}]));
        compare(JSON.stringify(skipped.members), JSON.stringify({"3": ["a2", "a3"]}));
    }

    function test_tileGroupRowsListTheAppsGroupsOnce() {
        const groups = {groupOf: {"a1": "2", "c3": "2", "d4": "7", "e5": "7"}, members: {"2": ["a1", "c3"], "7": ["d4", "e5"]}};
        const rows = WindowTiling.tileGroupRows(["0xC3", "x9", "a1", "e5"], groups);
        compare(rows.length, 2);
        compare(rows[0].group, "2");
        compare(rows[0].own, "c3", "the app's first window in that group");
        compare(JSON.stringify(rows[0].members), JSON.stringify(["a1", "c3"]));
        compare(rows[1].group, "7");
        compare(rows[1].own, "e5");
        compare(WindowTiling.tileGroupRows(["x9"], groups).length, 0, "no window of the app in a group");
        compare(WindowTiling.tileGroupRows(["a1"], null).length, 0);
        rows[0].members.push("zz");
        compare(groups.members["2"].length, 2, "the rows copy the members");
    }

    function test_membersOfReadsTheWindowsGroup() {
        const groups = {groupOf: {"a1": "2", "c3": "2"}, members: {"2": ["a1", "c3"]}};
        compare(JSON.stringify(WindowTiling.membersOf(groups, "0xA1")), JSON.stringify(["a1", "c3"]));
        compare(JSON.stringify(WindowTiling.membersOf(groups, "b2")), "[]", "in no group: no group_front");
        compare(JSON.stringify(WindowTiling.membersOf(null, "a1")), "[]", "no reply yet");
        WindowTiling.membersOf(groups, "a1").push("zz");
        compare(groups.members["2"].length, 2, "a copy");
    }

    // An Overview drop (D31): the members on the window's Desktop move with it; minimized, hidden or elsewhere they stay.
    function test_groupMoversAreTheMembersOnTheWindowsDesktop() {
        const windows = [
            {address: "a1", workspace: 2, parked: false}, {address: "b2", workspace: 2, parked: false},
            {address: "c3", workspace: -98, parked: true}, {address: "d4", workspace: 3, parked: false},
            {address: "e5", workspace: 2, parked: true}, {address: "f6", workspace: 2, parked: false}
        ];
        compare(JSON.stringify(WindowTiling.groupMovers("0xA1", ["a1", "b2", "c3", "d4", "e5"], windows)), JSON.stringify(["b2"]));
        compare(JSON.stringify(WindowTiling.groupMovers("a1", ["a1"], windows)), "[]");
        compare(JSON.stringify(WindowTiling.groupMovers("c3", ["a1", "b2", "c3"], windows)), "[]", "a parked window is on no Desktop");
        compare(JSON.stringify(WindowTiling.groupMovers("zz", ["a1", "b2"], windows)), "[]");
        compare(JSON.stringify(WindowTiling.groupMovers("a1", ["b2", "zz"], windows)), JSON.stringify(["b2"]), "an unknown member is skipped");
    }

    // Show Tile Group (D30; review of cd74af2: the order the shell sends).
    function test_tileGroupStepsShowTheGroupsDesktopFirst() {
        const steps = (own, members, windows) => JSON.stringify(WindowTiling.tileGroupSteps(own, members, windows));
        const on = (address, workspace, active, minimized) => ({address: address, workspace: workspace, active: active, minimized: minimized});
        // Everything on the Desktop shown: the focus, then the group.
        compare(steps("a1", ["a1", "b2"], [on("a1", 1, true, false), on("b2", 1, true, false)]),
                JSON.stringify([{op: "focus", address: "a1"}, {op: "groupFront", address: "a1"}]));
        // From another Desktop, a member minimized: that Desktop first, then the restore, then the focus and the group.
        compare(steps("0xA1", ["a1", "b2", "c3"], [on("a1", 2, false, false), on("b2", -98, false, true), on("c3", 2, false, false)]),
                JSON.stringify([{op: "space", id: 2}, {op: "restore", address: "b2"}, {op: "focus", address: "a1"}, {op: "groupFront", address: "a1"}]));
        // The app's window minimized itself: the Desktop of a member on one, then its restore and the others'.
        compare(steps("a1", ["b2", "a1", "c3"], [on("a1", -98, false, true), on("b2", 3, false, false), on("c3", -98, false, true)]),
                JSON.stringify([{op: "space", id: 3}, {op: "restore", address: "a1"}, {op: "restore", address: "c3"}, {op: "focus", address: "a1"},
                                {op: "groupFront", address: "a1"}]));
        // Hidden with its app: moved to the group's Desktop (shown already: no space step).
        compare(steps("a1", ["a1", "b2"], [on("a1", -97, false, false), on("b2", 1, true, false)]),
                JSON.stringify([{op: "move", address: "a1", id: 1}, {op: "focus", address: "a1"}, {op: "groupFront", address: "a1"}]));
        // Every member off the Desktops: a plain activation brings the window to the Desktop shown, then the restores.
        compare(steps("a1", ["a1", "b2"], [on("a1", -97, false, false), on("b2", -98, false, true)]),
                JSON.stringify([{op: "activate", address: "a1"}, {op: "restore", address: "b2"}, {op: "focus", address: "a1"}, {op: "groupFront", address: "a1"}]));
        compare(steps("zz", ["a1"], [on("a1", 1, true, false)]), "[]", "an unknown window: nothing");
    }

    // TL33 (step 6a): the Split View Desktops of the reply with their members; an older plugin's reply without "splits" lists none.
    function test_parseSplitsReadsTheSplitViewDesktops() {
        const reply = splits => JSON.stringify({v: "gfc/1", type: "tiling", gen: 5, outputs: [], splits: splits, suggestion: null});
        compare(JSON.stringify(WindowTiling.parseSplits(reply([{workspace: 4, output: "DP-1", home: 1, windows: ["A1", "0xb2"], waiting: false},
                                                                {workspace: 5, output: "GF-REF", home: 2, windows: ["c3"], waiting: true}]))),
                JSON.stringify([{workspace: 4, output: "DP-1", home: 1, windows: ["a1", "b2"], waiting: false}, {workspace: 5, output: "GF-REF", home: 2, windows: ["c3"], waiting: true}]));
        compare(JSON.stringify(WindowTiling.parseSplits(JSON.stringify({v: "gfc/1", type: "tiling", gen: 5, outputs: []}))), "[]", "no splits key: none");
        compare(JSON.stringify(WindowTiling.parseSplits(reply("x"))), "[]");
        // Members: malformed ones are left out; no list, none; waiting only when true.
        compare(JSON.stringify(WindowTiling.parseSplits(reply([{workspace: 4, output: "DP-1", home: 1, windows: ["zz", 7, null, "c3", "c3\""], waiting: "true"}]))),
                JSON.stringify([{workspace: 4, output: "DP-1", home: 1, windows: ["c3"], waiting: false}]));
        compare(JSON.stringify(WindowTiling.parseSplits(reply([{workspace: 4, output: "DP-1", home: 1}]))),
                JSON.stringify([{workspace: 4, output: "DP-1", home: 1, windows: [], waiting: false}]), "an older plugin's entry: no member known");
        // Malformed entries are left out, not fatal.
        const bad = [null, {workspace: 0, output: "DP-1", home: 1}, {workspace: 4.5, output: "DP-1", home: 1}, {workspace: "4", output: "DP-1", home: 1},
                     {workspace: 4, output: "", home: 1}, {workspace: 4, output: 7, home: 1}, {workspace: 4, output: "DP-1", home: -1},
                     {workspace: 4, output: "DP-1"}, {workspace: Infinity, output: "DP-1", home: 1}, {workspace: 6, output: "DP-2", home: 3, windows: ["d4"]}];
        compare(JSON.stringify(WindowTiling.parseSplits(reply(bad))), JSON.stringify([{workspace: 6, output: "DP-2", home: 3, windows: ["d4"], waiting: false}]));
        for (const text of ["", "x", "null", JSON.stringify({v: "gfc/2", type: "tiling", splits: []}), JSON.stringify({v: "gfc/1", type: "stages", splits: []})])
            compare(WindowTiling.parseSplits(text), null, text);
    }

    function test_splitOfWorkspaceFindsTheDesktop() {
        const splits = [{workspace: 4, output: "DP-1", home: 1, windows: ["a1"], waiting: false}, {workspace: 5, output: "GF-REF", home: 2, windows: [], waiting: false}];
        compare(WindowTiling.splitOfWorkspace(splits, 5).home, 2);
        compare(WindowTiling.splitOfWorkspace(splits, 1), null, "a home is no Split View Desktop");
        compare(WindowTiling.splitOfWorkspace(null, 4), null, "no reply yet");
        compare(WindowTiling.splitOfWorkspace([], 4), null);
    }

    // ADR-0036 D52: the members are the Split View's windows; another window on that Desktop is none.
    function test_splitOfWindowFindsTheMembersDesktop() {
        const splits = [{workspace: 4, output: "DP-1", home: 1, windows: ["a1", "b2"], waiting: false}, {workspace: 5, output: "GF-REF", home: 2, windows: ["c3"], waiting: true}];
        compare(WindowTiling.splitOfWindow(splits, "0xB2").workspace, 4);
        compare(WindowTiling.splitOfWindow(splits, "c3").workspace, 5);
        compare(WindowTiling.splitOfWindow(splits, "d4"), null, "not a member");
        compare(WindowTiling.splitOfWindow(splits, ""), null);
        compare(WindowTiling.splitOfWindow(splits, "zz"), null);
        compare(WindowTiling.splitOfWindow(null, "a1"), null, "no reply yet");
    }

    // D43 (#48 review, MAJOR 3): the one member still waiting for its second window fills alone once its picker is not pending.
    function test_lonelyMembersFillUnlessTheirPickerIsPending() {
        const split = (ws, windows, waiting) => ({workspace: ws, output: "DP-1", home: 1, windows: windows, waiting: waiting});
        const splits = [split(4, ["a1"], true), split(5, ["b2", "c3"], false), split(6, ["d4"], false), split(7, ["e5"], true), split(8, [], true)];
        compare(JSON.stringify(WindowTiling.lonelyMembers(splits, "")), JSON.stringify(["a1", "e5"]), "waiting, alone: no picker pending");
        compare(JSON.stringify(WindowTiling.lonelyMembers(splits, "0xA1")), JSON.stringify(["e5"]), "the picker of a1 is shown or on its way");
        compare(JSON.stringify(WindowTiling.lonelyMembers(splits, "e5")), JSON.stringify(["a1"]));
        compare(JSON.stringify(WindowTiling.lonelyMembers([split(4, ["a1", "b2"], true)], "")), "[]", "two members: nothing to fill");
        compare(JSON.stringify(WindowTiling.lonelyMembers([split(6, ["d4"], false)], "")), "[]", "not waiting: the plugin fills it itself");
        compare(JSON.stringify(WindowTiling.lonelyMembers(null, "")), "[]");
    }

    // #48 nested pass, MAJOR B (D48): the picker of a Split View the shell did not start.
    function test_splitPickerAdoptsTheSuggestionOfAWaitingSplitView() {
        const split = (windows, waiting) => ({workspace: 4, output: "DP-1", home: 1, windows: windows, waiting: waiting});
        const sg = (address, gen, layout) => ({gen: gen, address: address, layout: layout || "left-right", output: "DP-1", zones: [{zone: 1, x: 0, y: 0, w: 9, h: 9}], windows: ["b2"]});
        const waiting = [split(["a1"], true)];
        compare(WindowTiling.splitPicker(waiting, sg("a1", 3), null), sg("a1", 3), "its one member waits: its picker shows");
        compare(WindowTiling.splitPicker(waiting, sg("0xA1", 3), null), sg("0xA1", 3), "the address in any case, with or without 0x");
        compare(WindowTiling.splitPicker(waiting, sg("a1", 3, "top-bottom"), null), null, "another layout's suggestion is not a Split View's");
        compare(WindowTiling.splitPicker(waiting, sg("b2", 3), null), null, "the suggestion of another window");
        compare(WindowTiling.splitPicker([split(["a1"], false)], sg("a1", 3), null), null, "not waiting: the plugin fills it");
        compare(WindowTiling.splitPicker([split(["a1", "b2"], true)], sg("a1", 3), null), null, "two members: nothing to pick");
        compare(WindowTiling.splitPicker([], sg("a1", 3), null), null, "no Split View Desktop");
        compare(WindowTiling.splitPicker(null, sg("a1", 3), null), null);
        compare(WindowTiling.splitPicker(waiting, null, null), null, "no suggestion");
        compare(WindowTiling.splitPicker(waiting, sg("", 3), null), null, "no address");
        compare(WindowTiling.splitPicker(waiting, sg("a1", 3), {address: "0xa1", gen: 3}), null, "dismissed: not shown again (its window fills)");
        compare(WindowTiling.splitPicker(waiting, sg("a1", 4), {address: "a1", gen: 3}), sg("a1", 4), "a later Split View of the same window has its own picker");
        compare(WindowTiling.splitPicker(waiting, sg("a1", 3), {address: "b2", gen: 3}), sg("a1", 3), "another window was dismissed");
    }

    // Integrator re-review of 29db357, MAJOR 1: a notice names no window; within an earlier ask's deadline (6 s, D68) a new
    // Split View's notice was taken as that ask's answer and its picker never showed.
    function test_answersAskedIsTheAwaitedSuggestionOnly() {
        const sg = (address, gen) => ({gen: gen, address: address, layout: "left-right"});
        verify(WindowTiling.answersAsked(20, {address: "b2", until: 0}, sg("b2", 20)));
        verify(WindowTiling.answersAsked(20, {address: "0xB2", until: 0}, sg("b2", 20)), "the address in any case");
        verify(!WindowTiling.answersAsked(20, {address: "a1", until: 0}, sg("b2", 20)), "another window's suggestion");
        verify(!WindowTiling.answersAsked(20, {address: "b2", until: 0}, sg("b2", 21)), "another generation");
        verify(!WindowTiling.answersAsked(-1, {address: "b2", until: 0}, sg("b2", 20)), "no notice awaited");
        verify(!WindowTiling.answersAsked(-1, {address: "b2", until: 0}, sg("b2", -1)), "no notice awaited, whatever generation the reply states");
        verify(!WindowTiling.answersAsked(20, null, sg("b2", 20)), "nothing asked");
        verify(!WindowTiling.answersAsked(20, {address: "b2", until: 0}, null), "no suggestion");
        compare(WindowTiling.answersAsked(20, null, null), false, "a boolean");
    }

    function test_replyPickerShowsASecondSplitViewWhileAnEarlierAskIsOpen() {
        const split = (workspace, windows, waiting) => ({workspace: workspace, output: "DP-1", home: 1, windows: windows, waiting: waiting});
        const sg = (address, gen) => ({gen: gen, address: address, layout: "left-right", output: "DP-1", zones: [{zone: 1, x: 0, y: 0, w: 9, h: 9}], windows: ["c3"]});
        // a1's picker was adopted a second ago (asked: a1 for 6 s, its Split View now full); a key makes b2's Split View; its
        // `placed` notice (gen 20) was taken as a1's answer (wantedGen 20); the reply's suggestion is b2's.
        const asked = {address: "a1", until: Date.now() + 5000};
        const splits = [split(4, ["a1", "c3"], false), split(5, ["b2"], true)];
        compare(WindowTiling.replyPicker(20, asked, splits, sg("b2", 20), null), sg("b2", 20), "the second Split View's picker shows");
        compare(WindowTiling.replyPicker(20, {address: "b2", until: 0}, splits, sg("b2", 20), null), null, "the shell's own ask: shown as asked, not adopted");
        compare(WindowTiling.replyPicker(-1, null, splits, sg("b2", 20), null), sg("b2", 20), "nothing asked: adopted as before (D48)");
        compare(WindowTiling.replyPicker(20, asked, splits, sg("b2", 20), {address: "b2", gen: 20}), null, "dismissed: not shown again");
        compare(WindowTiling.replyPicker(20, asked, [split(5, ["b2"], false)], sg("b2", 20), null), null, "not waiting: the plugin fills it");
        compare(WindowTiling.replyPicker(20, asked, splits, null, null), null, "no suggestion");
    }

    // D57 (integrator PASS on 8316ed2, for later): the windows that do not fit half of their output, for the Window menu.
    function test_parseUnfitReadsTheWindowsThatDoNotFit() {
        compare(JSON.stringify(WindowTiling.parseUnfit('{"v":"gfc/1","type":"tiling","gen":1,"outputs":[],"splits":[],"unfit":["A1","0xbeef","xyz",7],"suggestion":null}')),
                JSON.stringify(["a1", "beef"]), "lower-case hex, a malformed one left out");
        compare(JSON.stringify(WindowTiling.parseUnfit('{"v":"gfc/1","type":"tiling","gen":1,"outputs":[],"splits":[],"suggestion":null}')), "[]", "an older plugin lists none");
        for (const bad of ["", "not json", "null", '{"v":"gfc/2","type":"tiling","unfit":["a1"]}', '{"v":"gfc/1","type":"tile-hover","unfit":["a1"]}'])
            compare(WindowTiling.parseUnfit(bad), null, bad);
        verify(!WindowTiling.fitsHalf(["a1", "beef"], "0xA1"), "listed: it does not fit, any address form");
        verify(WindowTiling.fitsHalf(["a1"], "b2"), "not listed: it fits");
        verify(WindowTiling.fitsHalf(null, "a1"), "not known: it fits (the plugin still refuses)");
        verify(WindowTiling.fitsHalf(["a1"], ""), "no window");
    }

    // ADR-0040 step 1b (nested pass of 85c2c10, scenario 6): the windows of fixed size, whose zoom light is disabled.
    function test_parseFixedReadsTheWindowsOfFixedSize() {
        compare(JSON.stringify(WindowTiling.parseFixed('{"v":"gfc/1","type":"tiling","gen":1,"outputs":[],"splits":[],"unfit":[],"fixed":["A1","0xbeef","xyz",7],"suggestion":null}')),
                JSON.stringify(["a1", "beef"]), "lower-case hex, a malformed one left out");
        compare(JSON.stringify(WindowTiling.parseFixed('{"v":"gfc/1","type":"tiling","gen":1,"outputs":[],"splits":[],"unfit":[],"suggestion":null}')), "[]", "an older plugin lists none");
        for (const bad of ["", "not json", "null", '{"v":"gfc/2","type":"tiling","fixed":["a1"]}', '{"v":"gfc/1","type":"tile-hover","fixed":["a1"]}'])
            compare(WindowTiling.parseFixed(bad), null, bad);
        verify(WindowTiling.isFixed(["a1", "beef"], "0xA1"), "listed: of fixed size, any address form");
        verify(!WindowTiling.isFixed(["a1"], "b2"), "not listed");
        verify(!WindowTiling.isFixed(null, "a1"), "not known: not (the plugin still opens nothing from its light)");
        verify(!WindowTiling.isFixed(["a1"], ""), "no window");
    }

    // #48 nested pass, MINOR D: the first window is selected as the picker opens, and a first Return takes it.
    function test_keptSelectionStartsOnTheFirstTile() {
        const three = ["a", "b", "c"];
        compare(WindowTiling.keptSelection(-1, three, true), 0, "a new suggestion: the first");
        compare(WindowTiling.keptSelection(2, three, true), 0, "a new suggestion resets");
        compare(WindowTiling.keptSelection(-1, three, false), 0, "the windows came after the suggestion: the first");
        compare(WindowTiling.keptSelection(2, three, false), 2, "kept while in range");
        compare(WindowTiling.keptSelection(3, three, false), 0, "out of range (a window closed): the first");
        compare(WindowTiling.keptSelection(1, [], false), -1, "no tile");
        compare(WindowTiling.keptSelection(-1, [], true), -1);
        compare(WindowTiling.keptSelection(-1, undefined, true), -1, "the windows not evaluated yet (#48's merge note: no TypeError)");
        compare(WindowTiling.keptSelection(0, null, false), -1);
    }

    // #48 review, MINOR 7: a Split View Desktop takes no number, the Desktops keep theirs.
    function test_numberDesktopsSkipsTheSplitViewDesktops() {
        const spaces = [{id: 1}, {id: 4}, {id: 2}, {id: 3}];
        const splits = [{workspace: 4, output: "DP-1", home: 1, windows: ["a1"], waiting: false}];
        const numbered = WindowTiling.numberDesktops(spaces, splits);
        compare(numbered.map(s => s.id + ":" + (s.split ? "split" : s.number)).join(","), "1:1,4:split,2:2,3:3");
        compare(numbered[1].number, 0);
        verify(numbered[0] !== spaces[0] && spaces[0].number === undefined, "new objects, the spaces untouched");
        compare(WindowTiling.numberDesktops(spaces, []).map(s => s.number).join(","), "1,2,3,4");
        compare(WindowTiling.numberDesktops([], splits).length, 0);
    }

    // D41: each Split View Desktop right after its home, several in id order; one whose home is gone stays at its id.
    function test_desktopOrderListsASplitViewDesktopAfterItsHome() {
        const order = (ids, splits) => WindowTiling.desktopOrder(ids.map(id => ({id: id})), splits).map(s => s.id).join(",");
        compare(order([1, 2, 3, 4], []), "1,2,3,4");
        compare(order([1, 2, 3, 4], null), "1,2,3,4");
        compare(order([1, 2, 3, 4], [{workspace: 4, output: "DP-1", home: 1}]), "1,4,2,3");
        compare(order([1, 2, 3, 5, 6], [{workspace: 6, output: "DP-1", home: 2}, {workspace: 5, output: "DP-1", home: 2}]), "1,2,5,6,3");
        compare(order([1, 4, 5], [{workspace: 4, output: "DP-1", home: 2}]), "1,4,5", "its home not listed (another output): where its id puts it");
        compare(order([1, 2, 3], [{workspace: 2, output: "DP-1", home: 2}]), "1,2,3", "its own home: where its id puts it");
        compare(order([2, 3, 7], [{workspace: 7, output: "DP-1", home: 3}, {workspace: 3, output: "DP-1", home: 2}]), "2,3,7",
                "a chain of homes (never sent): every Desktop once");
        compare(order([1, 3, 7], [{workspace: 7, output: "DP-1", home: 3}, {workspace: 3, output: "DP-1", home: 7}]), "1,3,7",
                "a loop of homes (never sent): id order");
        const spaces = [{id: 1, name: "a"}, {id: 4, name: "b"}];
        verify(WindowTiling.desktopOrder(spaces, [{workspace: 4, output: "DP-1", home: 1}])[1] === spaces[1], "the same objects");
    }
}
