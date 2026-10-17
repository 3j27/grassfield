import QtQuick
import QtTest
import "../../shell/widgets/Registry.js" as Registry
import "../../shell/widgets/Placements.js" as Placements
import "../../shell/widgets/Calendar.js" as Calendar
import "../../shell/widgets/SystemStats.js" as Stats

// Widgets v1 logic: registry/manifest validation, placement persistence, grid snapping, calendar math.
TestCase {
    id: testCase
    name: "Widgets"

    function readJson(url) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url, false);
        xhr.send();
        return JSON.parse(xhr.responseText);
    }

    // ---- registry --------------------------------------------------------------------------

    function test_registryIsValid() {
        compare(Registry.validateAll(), "");
        compare(Registry.ids().join(","), "clock,calendar,battery,nowplaying,system");
    }

    function test_registryMatchesManifestFiles() {
        Registry.ids().forEach(id => {
            const file = readJson(Qt.resolvedUrl("../../shell/widgets/builtin/" + id + "/manifest.json"));
            compare(JSON.stringify(file), JSON.stringify(Registry.find(id)), id);
            compare(Registry.validateManifest(file), "", id);
        });
    }

    function test_manifestValidationRejects() {
        const good = Registry.find("clock");
        const bad = changes => Registry.validateManifest(Object.assign({}, good, changes));
        compare(bad({}), "");
        verify(bad({id: "Bad Id"}) !== "");
        verify(bad({version: "1"}) !== "");
        verify(bad({contract: "widgets/2"}) !== "");
        verify(bad({sizes: []}) !== "");
        verify(bad({sizes: ["huge"]}) !== "");
        verify(bad({sizes: ["small", "small"]}) !== "");
        verify(bad({permissions: ["network"]}) !== "", "network is not a v1 permission");
        verify(bad({permissions: "media"}) !== "");
        verify(bad({name: ""}) !== "");
        verify(Registry.validateManifest(null) !== "");
    }

    // ---- placements ------------------------------------------------------------------------

    function test_persistenceRoundTrip() {
        let s = Placements.empty();
        s = Placements.addCenter(s, "clock", "medium");
        s = Placements.addCenter(s, "clock", "small");
        s = Placements.addDesktop(s, "calendar", "large", "GF-REF", 11, 6);
        s = Placements.addDesktop(s, "system", "small", "GF-REF", 11, 6);
        const back = Placements.parse(Placements.serialize(s));
        verify(back.ok);
        compare(JSON.stringify(back.state), JSON.stringify(s));
        compare(back.state.center.map(e => e.uid).join(","), "clock-1,clock-2");
    }

    function test_parseDropsUnknownAndInvalid() {
        const text = JSON.stringify({
            version: 1,
            center: [{uid: "clock-1", id: "clock", size: "small"}, {uid: "evil-1", id: "evil", size: "small"}, {uid: "battery-1", id: "battery", size: "large"}, 5],
            desktop: [{uid: "clock-1", id: "clock", size: "medium", screen: "A", col: 2, row: 1}, {id: "calendar", size: "small", screen: "", col: 0, row: 0}, {id: "system", size: "small", screen: "A", col: -4, row: "x"}]
        });
        const r = Placements.parse(text);
        verify(r.ok);
        compare(r.state.center.length, 1);
        compare(r.state.center[0].id, "clock");
        compare(r.state.desktop.length, 2);
        verify(r.state.desktop[0].uid !== "clock-1", "duplicate uid is regenerated");
        compare(r.state.desktop[1].col, 0);
        compare(r.state.desktop[1].row, 0);
    }

    function test_parseBadFiles() {
        compare(Placements.parse("").ok, true);
        compare(Placements.parse("{not json").ok, false);
        compare(Placements.parse("[]").ok, false);
        compare(Placements.parse('{"version": 2}').ok, false);
        compare(Placements.parse("{not json").state.center.length, 0);
    }

    function test_removeAndResize() {
        let s = Placements.addCenter(Placements.empty(), "battery", "small");
        s = Placements.setSize(s, "battery-1", "medium", null);
        compare(s.center[0].size, "medium");
        s = Placements.setSize(s, "battery-1", "large", null);
        compare(s.center[0].size, "medium", "battery has no large size");
        s = Placements.remove(s, "battery-1");
        compare(s.center.length, 0);
    }

    function test_centerReorder() {
        let s = Placements.empty();
        s = Placements.addCenter(s, "clock", "small");
        s = Placements.addCenter(s, "calendar", "small");
        s = Placements.moveCenter(s, "calendar-1", 0);
        compare(s.center.map(e => e.id).join(","), "calendar,clock");
    }

    // ---- grid ------------------------------------------------------------------------------

    function test_gridSize() {
        const g = Placements.gridSize(1920, 1080, 158, 16, 24);
        compare(g.cols, 10);
        compare(g.rows, 6);
        compare(Placements.gridSize(100, 100, 158, 16, 24).cols, 1);
    }

    function test_footprints() {
        compare(Placements.px("small", 158, 16).w, 158);
        compare(Placements.px("medium", 158, 16).w, 332);
        compare(Placements.px("large", 158, 16).h, 332);
    }

    function test_snap() {
        const s = (x, y, size) => Placements.snap(x, y, size, 158, 16, 11, 6);
        compare(JSON.stringify(s(0, 0, "small")), JSON.stringify({col: 0, row: 0}));
        compare(JSON.stringify(s(80, 60, "small")), JSON.stringify({col: 0, row: 0}));
        compare(JSON.stringify(s(90, 100, "small")), JSON.stringify({col: 1, row: 1}));
        compare(JSON.stringify(s(-500, -500, "small")), JSON.stringify({col: 0, row: 0}));
        // A large widget never leaves the grid.
        compare(JSON.stringify(s(99999, 99999, "large")), JSON.stringify({col: 9, row: 4}));
        compare(JSON.stringify(s(99999, 99999, "medium")), JSON.stringify({col: 9, row: 5}));
    }

    function test_collisionsAndNearestFree() {
        const others = [{col: 0, row: 0, size: "large"}];
        verify(!Placements.isFree(others, "small", {col: 1, row: 1}, 11, 6));
        verify(Placements.isFree(others, "small", {col: 2, row: 0}, 11, 6));
        const spot = Placements.nearestFree(others, "small", {col: 0, row: 0}, 11, 6);
        compare(JSON.stringify(spot), JSON.stringify({col: 2, row: 0}), "ties go to the top row");
        compare(Placements.nearestFree([], "large", {col: 0, row: 0}, 1, 1), null);
    }

    function test_moveDesktopAvoidsOverlap() {
        let s = Placements.addDesktop(Placements.empty(), "clock", "small", "A", 11, 6);
        s = Placements.addDesktop(s, "system", "small", "A", 11, 6);
        compare(s.desktop[0].col, 10, "first widget goes to the right edge");
        compare(s.desktop[1].row, 1);
        s = Placements.moveDesktop(s, "system-1", {col: 10, row: 0}, 11, 6);
        verify(!(s.desktop[1].col === 10 && s.desktop[1].row === 0));
        s = Placements.moveDesktop(s, "system-1", {col: 3, row: 3}, 11, 6);
        compare(s.desktop[1].col, 3);
        compare(s.desktop[1].row, 3);
    }

    function test_addDesktopFull() {
        let s = Placements.empty();
        s = Placements.addDesktop(s, "clock", "large", "A", 2, 2);
        s = Placements.addDesktop(s, "system", "small", "A", 2, 2);
        compare(s.desktop.length, 1, "no room: not added");
    }

    // ---- calendar --------------------------------------------------------------------------

    function test_daysInMonth() {
        compare(Calendar.daysInMonth(2024, 1), 29);
        compare(Calendar.daysInMonth(2025, 1), 28);
        compare(Calendar.daysInMonth(2026, 9), 31);
        compare(Calendar.daysInMonth(2026, 11), 31);
    }

    function test_monthGridSundayStart() {
        // October 2026 starts on a Thursday.
        const g = Calendar.monthGrid(2026, 9, 0);
        compare(g.length, 5);
        compare(g[0].map(c => c.day).join(","), "27,28,29,30,1,2,3");
        verify(!g[0][0].inMonth);
        verify(g[0][4].inMonth);
        compare(g[4].map(c => c.day).join(","), "25,26,27,28,29,30,31");
    }

    function test_monthGridMondayStart() {
        const g = Calendar.monthGrid(2026, 9, 1);
        compare(g[0].map(c => c.day).join(","), "28,29,30,1,2,3,4");
        compare(g[4].map(c => c.day).join(","), "26,27,28,29,30,31,1");
        verify(!g[4][6].inMonth);
    }

    function test_monthGridSixRowsAndEdges() {
        // March 2026 starts on a Sunday: Monday start gives 6 rows (lead of 6 days).
        compare(Calendar.monthGrid(2026, 2, 1).length, 6);
        compare(Calendar.monthGrid(2026, 2, 0).length, 5);
        // February 2026 starts on a Sunday and has 28 days: 4 rows with a Sunday start.
        compare(Calendar.monthGrid(2026, 1, 0).length, 4);
        // January pads from December of the previous year.
        compare(Calendar.monthGrid(2026, 0, 0)[0][0].day, 28);
        compare(Calendar.monthGrid(2026, 0, 0)[0][0].inMonth, false);
    }

    function test_weekdayOrder() {
        compare(Calendar.weekdayOrder(0).join(""), "0123456");
        compare(Calendar.weekdayOrder(1).join(""), "1234560");
        compare(Calendar.weekdayOrder(6).join(""), "6012345");
    }

    // ---- system ----------------------------------------------------------------------------

    function test_cpuLoad() {
        const a = Stats.parseCpu("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 1 1 1 1 1 1 1 1 1\n");
        compare(a.total, 1000);
        compare(a.idle, 800);
        const b = Stats.parseCpu("cpu  200 0 200 750 150 0 0 0 0 0\n");
        fuzzyCompare(Stats.cpuLoad(a, b), 2 / 3, 0.0001);
        compare(Stats.cpuLoad(a, a), 0);
        compare(Stats.parseCpu("nonsense"), null);
    }

    function test_memory() {
        const m = Stats.parseMemory("MemTotal:       16000000 kB\nMemFree: 1 kB\nMemAvailable:    4000000 kB\n");
        compare(m.total, 16000000);
        compare(m.used, 12000000);
        compare(Stats.parseMemory("MemTotal: 5 kB\n"), null);
    }
}
