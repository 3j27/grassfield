import QtQuick
import QtTest
import "../../shell/platform/Minimized.js" as Minimized
import "../../shell/platform/StagesState.js" as StagesState
import "../../shell/stages/Layout.js" as Layout

// Stages shell side (docs/specs/stages.md "Shell side"): the verb and config builders, the event state, the strip layout and
// what clicks and drops ask of the plugin. Test names state the user-visible rule.
TestCase {
    name: "Stages"

    readonly property var t: ({tileWidth: 160, tileHeight: 120, tileGap: 24, edgeMargin: 12, maxTiles: 8, revealZone: 6})
    readonly property var screen: ({x: 0, y: 0, width: 1920, height: 1080})
    readonly property var insets: ({left: 0, top: 32, bottom: 0})

    function event(extra) {
        const base = {v: "gfc/1", type: "stages", on: true, monitors: [{monitor: "GF-REF", workspace: 2, active: 5, hidden: false, overlap: false,
                stages: [{id: 5, slot: -1, windows: [{address: "aa"}]},
                         {id: 7, slot: 0, windows: [{address: "b1", x: 10, y: 20, w: 100, h: 80}, {address: "b2", x: 12, y: 22, w: 100, h: 80}]},
                         {id: 9, slot: 1, windows: [{address: "0xC3"}]}]}]};
        return JSON.stringify(Object.assign(base, extra || {}));
    }

    function mon() {
        return StagesState.parse(event()).monitors["GF-REF"];
    }

    // ---- plugin verb and config ----

    function test_stagesIsAGuardedPluginVerb() {
        verify(Minimized.isPluginVerb("stages"));
        verify(Minimized.guardedPluginCall("stages", ["\"{}\""]).indexOf("p.stages") > 0);
    }

    function test_stagesEnabledIsAnAllowedConfigKeyWithExactValues() {
        verify(Minimized.configCall("stagesEnabled", "true") !== "");
        verify(Minimized.configCall("stagesEnabled", "false") !== "");
        compare(Minimized.configCall("stagesEnabled", "yes"), "");
        compare(Minimized.configCall("stagesEnabled", true), "");
    }

    function test_onRequestIsBuiltFromValidatedPieces() {
        const strips = [{monitor: "GF-REF", hidden: false, tiles: [{x: 12, y: 100, w: 160, h: 120}]}];
        const lua = Minimized.stagesCall({op: "on", durationMs: 350, curve: [0.2, 0, 0, 1], strips: strips});
        verify(lua.indexOf("p.stages(") > 0);
        verify(lua.indexOf("\\\"op\\\":\\\"on\\\"") > 0);
        compare(Minimized.stagesCall({op: "on", durationMs: 350, strips: []}), "");
        compare(Minimized.stagesCall({op: "on", durationMs: 5000, strips: strips}), "");
        compare(Minimized.stagesCall({op: "on", durationMs: 0, strips: [{monitor: "a\"b", hidden: false, tiles: strips[0].tiles}]}), "");
        compare(Minimized.stagesCall({op: "on", durationMs: 0, strips: [{monitor: "A", hidden: false, tiles: [{x: 0, y: 0, w: 8, h: 120}]}]}), "");
        compare(Minimized.stagesCall({op: "on", durationMs: 0, strips: [{monitor: "A", hidden: "no", tiles: strips[0].tiles}]}), "");
        compare(Minimized.stagesCall({op: "on", durationMs: 0, strips: [strips[0], strips[0]]}), "");
    }

    function test_otherOpsValidateStageIdsAndAddresses() {
        verify(Minimized.stagesCall({op: "activate", stage: 7}) !== "");
        verify(Minimized.stagesCall({op: "merge", stage: 7}) !== "");
        compare(Minimized.stagesCall({op: "activate", stage: "7"}), "");
        compare(Minimized.stagesCall({op: "activate", stage: -1}), "");
        compare(Minimized.stagesCall({op: "activate", stage: 1.5}), "");
        verify(Minimized.stagesCall({op: "move", address: "0xAB12", stage: "new"}) !== "");
        verify(Minimized.stagesCall({op: "move", address: "ab12", stage: 3}) !== "");
        compare(Minimized.stagesCall({op: "move", address: "zz", stage: 3}), "");
        compare(Minimized.stagesCall({op: "move", address: "ab12", stage: "old"}), "");
        verify(Minimized.stagesCall({op: "off", durationMs: 350}) !== "");
        compare(Minimized.stagesCall({op: "explode"}), "");
        compare(Minimized.stagesCall(null), "");
    }

    // ---- event state ----

    function test_theEventBecomesAStatePerMonitor() {
        const s = StagesState.parse(event());
        verify(s.on);
        compare(s.reason, "");
        compare(s.monitors["GF-REF"].active, 5);
        compare(s.monitors["GF-REF"].stages.length, 3);
        compare(s.monitors["GF-REF"].stages[2].windows[0].address, "c3");
    }

    function test_foreignOrMalformedEventsAreIgnored() {
        compare(StagesState.parse("not json"), null);
        compare(StagesState.parse(JSON.stringify({v: "gfc/2", type: "stages", on: true, monitors: []})), null);
        compare(StagesState.parse(JSON.stringify({v: "gfc/1", type: "overview", on: true})), null);
        compare(StagesState.parse(JSON.stringify({v: "gfc/1", type: "stages", on: "yes"})), null);
    }

    function test_unknownReasonsAndBadEntriesAreDropped() {
        const s = StagesState.parse(event({reason: "made-up", monitors: [{monitor: "bad name", stages: []}, {monitor: "A", stages: [{id: -3, slot: 0, windows: []}, {id: 1, slot: 0, windows: [{address: "zz"}]}]}]}));
        compare(s.reason, "");
        compare(Object.keys(s.monitors).length, 1);
        compare(s.monitors.A.stages.length, 1);
        compare(s.monitors.A.stages[0].windows.length, 0);
        compare(StagesState.parse(event({on: false, reason: "no-strip"})).reason, "no-strip");
    }

    function test_theStripIsTheStagesOtherThanTheActiveOne() {
        const strip = StagesState.stripStages(mon());
        compare(strip.length, 2);
        compare(strip[0].id, 7);
        compare(StagesState.stageAtSlot(mon(), 1).id, 9);
        compare(StagesState.stageAtSlot(mon(), -1), null);
        compare(StagesState.stageOfWindow(mon(), "0xB2").id, 7);
        compare(StagesState.stripStages(null).length, 0);
    }

    // ---- layout ----

    function test_tilesAreCentredVerticallyAndNeverMoreThanFit() {
        const g = Layout.geometry(screen, insets, 3, t);
        compare(g.tiles.length, 3);
        const top = g.tiles[0].y;
        const bottom = g.tiles[2].y + g.tiles[2].h;
        // free height is [insets.top + edge, screen.height - edge]
        fuzzyCompare((top - (32 + 12)) , (1080 - 12) - bottom, 1);
        compare(g.tiles[1].y - g.tiles[0].y, 120 + 24);
        compare(Layout.capacity(100, t), 1);
        compare(Layout.capacity(100000, t), 8);
        compare(Layout.tileCount(0, 1000, t), 1);
        compare(Layout.tileCount(20, 1000, t), Layout.capacity(1000, t));
    }

    function test_theSurfaceCoversEveryTileAndTheInputBoxCoversTheTiles() {
        const g = Layout.geometry(screen, insets, 4, t);
        for (const r of g.tiles) {
            verify(r.x >= g.surface.x && r.x + r.w <= g.surface.x + g.surface.w);
            verify(r.y >= g.surface.y && r.y + r.h <= g.surface.y + g.surface.h);
            // box is relative to the surface
            verify(r.x - g.surface.x >= g.box.x && r.x - g.surface.x + r.w <= g.box.x + g.box.w);
            verify(r.y - g.surface.y >= g.box.y && r.y - g.surface.y + r.h <= g.box.y + g.box.h);
        }
    }

    function test_aDockOnTheLeftPushesTheStripRight() {
        const g = Layout.geometry(screen, {left: 80, top: 32, bottom: 0}, 1, t);
        compare(g.surface.x, 80);
        compare(g.tiles[0].x, 80 + 12);
    }

    function test_theStripHidesWhileAWindowOverlapsUnlessRevealed() {
        verify(Layout.shown(true, 2, false, false));
        verify(!Layout.shown(true, 2, true, false));
        verify(Layout.shown(true, 2, true, true));
        verify(!Layout.shown(true, 0, false, false));
        verify(!Layout.shown(false, 2, false, false));
    }

    function test_theInputRegionIsNeverEmptyWhileStagesIsOn() {
        verify(Layout.edgeActive(true, false));
        verify(!Layout.edgeActive(true, true));
        verify(!Layout.edgeActive(false, false));
    }

    // ---- clicks and drops ----

    function test_clickingATileActivatesItsStageAndShiftMergesIt() {
        compare(JSON.stringify(Layout.clickRequest(mon(), 0, false)), JSON.stringify({op: "activate", stage: 7}));
        compare(JSON.stringify(Layout.clickRequest(mon(), 1, true)), JSON.stringify({op: "merge", stage: 9}));
        compare(Layout.clickRequest(mon(), 5, false), null);
        compare(Layout.clickRequest(mon(), -1, false), null);
        compare(Layout.clickRequest(null, 0, false), null);
    }

    function test_droppingOnTheStageMovesTheFrontWindowIntoTheActiveStage() {
        const geo = Layout.geometry(screen, insets, 2, t);
        const target = Layout.dropTarget(geo.surface.w + 40, 100, geo);
        compare(target.kind, "stage");
        const req = Layout.dropRequest(mon(), 0, target);
        compare(req.op, "move");
        compare(req.address, "b2");
        compare(req.stage, 5);
    }

    function test_droppingOnAnotherTileMovesItIntoThatStage() {
        const geo = Layout.geometry(screen, insets, 2, t);
        const r = geo.tiles[1];
        const target = Layout.dropTarget(r.x - geo.surface.x + 10, r.y - geo.surface.y + 10, geo);
        compare(target.kind, "tile");
        compare(target.slot, 1);
        compare(Layout.dropRequest(mon(), 0, target).stage, 9);
        // on its own tile or on nothing: nothing is asked
        compare(Layout.dropRequest(mon(), 1, target), null);
        compare(Layout.dropRequest(mon(), 0, {kind: "none"}), null);
    }

    function test_theBadgeShowsTheFrontWindowsAppFirst() {
        const apps = {b1: "org.a", b2: "org.b", aa: "org.c"};
        const ids = Layout.appIds(mon().stages[1], a => apps[a] || "");
        compare(ids[0], "org.b");
        compare(ids.length, 2);
        compare(Layout.appIds(null, a => "x").length, 0);
    }
}
