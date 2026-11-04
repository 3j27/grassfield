import QtQuick
import QtTest
import "../../shell/widgets/Registry.js" as Registry
import "../../shell/widgets/Placements.js" as Placements
import "../../shell/widgets/Calendar.js" as Calendar
import "../../shell/widgets/ArtUrl.js" as ArtUrl
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

    // GF-106: the keyboard moves a desktop widget one cell and never hops over a neighbour or off the grid.
    function test_stepDesktopMovesOneCell() {
        let s = Placements.empty();
        s = Placements.addDesktop(s, "clock", "small", "A", 6, 4);
        const uid = s.desktop[0].uid;
        compare(s.desktop[0].col, 0);
        compare(Placements.stepSpot(s, uid, "left", 6, 4), null);
        compare(Placements.stepSpot(s, uid, "up", 6, 4), null);
        const right = Placements.stepDesktop(s, uid, "right", 6, 4);
        compare(right.desktop[0].col, 1);
        compare(right.desktop[0].row, 0);
        const down = Placements.stepDesktop(right, uid, "down", 6, 4);
        compare(down.desktop[0].row, 1);
        compare(Placements.stepDesktop(s, uid, "left", 6, 4).desktop[0].col, 0);
        compare(Placements.stepDesktop(s, "nope", "right", 6, 4).desktop.length, 1);
        compare(Placements.stepSpot(s, uid, "sideways", 6, 4), null);
    }

    function test_stepDesktopRefusesATakenCell() {
        let s = Placements.empty();
        s = Placements.addDesktop(s, "clock", "small", "A", 6, 4);
        s = Placements.addDesktop(s, "clock", "small", "A", 6, 4);
        const a = s.desktop[0];
        const b = s.desktop[1];
        const spot = Placements.stepSpot(s, a.uid, b.row === a.row ? (b.col > a.col ? "right" : "left") : (b.row > a.row ? "down" : "up"), 6, 4);
        compare(spot, null);
    }

    function test_registryIsValid() {
        compare(Registry.validateAll(), "");
        compare(Registry.ids().join(","), "clock,calendar,battery,nowplaying,system,weather");
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

    // macOS model: Notification Center shows the Calendar widget on the first day; the parsed empty state stays empty so
    // that a user who removed every widget keeps it that way.
    function test_firstRunShowsCalendar() {
        const s = Placements.firstRun();
        compare(s.version, 1);
        compare(s.center.length, 2);
        compare(s.center[0].id, "calendar");
        compare(s.center[0].size, "medium");
        compare(s.center[1].id, "clock");
        compare(s.desktop.length, 0);
        compare(Placements.parse(Placements.serialize(Placements.remove(Placements.remove(s, "calendar-1"), "clock-1"))).state.center.length, 0);
        compare(Placements.parse("").state.center.length, 0);
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
        compare(s.desktop[0].col, 0, "first widget goes to the left edge, top row");
        compare(s.desktop[0].row, 0);
        compare(s.desktop[1].row, 1);
        s = Placements.moveDesktop(s, "system-1", {col: 0, row: 0}, 11, 6);
        verify(!(s.desktop[1].col === 0 && s.desktop[1].row === 0));
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

    function test_firstDay() {
        compare(Calendar.firstDay("monday", 0), 1);
        compare(Calendar.firstDay("sunday", 1), 0);
        compare(Calendar.firstDay("saturday", 1), 6);
        compare(Calendar.firstDay("auto", 1), 1);
        compare(Calendar.firstDay("lundi", 0), 0);
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

    // ---- hostile widgets.json ------------------------------------------------------------------

    function bigFile(count, ids) {
        const desktop = [];
        for (let i = 0; i < count; i++)
            desktop.push({uid: "clock-1", id: ids ? ids[i % ids.length] : "clock", size: "small", screen: "GF-REF", col: i % 1000, row: 5});
        return JSON.stringify({version: 1, center: desktop.slice(0, 100).map(e => ({uid: "clock-1", id: "clock", size: "small"})), desktop: desktop});
    }

    function test_entriesAreCapped() {
        const r = Placements.parse(JSON.stringify({version: 1, center: [], desktop: Array.from({length: 200}, (_, i) => ({id: "clock", size: "small", screen: "S", col: i, row: 0}))}));
        verify(r.ok);
        compare(r.state.desktop.length, 64);
        const uids = {};
        r.state.desktop.forEach(e => uids[e.uid] = true);
        compare(Object.keys(uids).length, 64, "uids are unique");
        const c = Placements.parse(JSON.stringify({version: 1, center: Array.from({length: 200}, () => ({id: "clock", size: "small"})), desktop: []}));
        compare(c.state.center.length, 64);
        let s = Placements.empty();
        for (let i = 0; i < 80; i++)
            s = Placements.addCenter(s, "clock", "small");
        compare(s.center.length, 64);
    }

    function test_oversizedFileIsRejectedFast() {
        const text = bigFile(40000);
        verify(text.length > 262144);
        const t0 = Date.now();
        const r = Placements.parse(text);
        const ms = Date.now() - t0;
        verify(!r.ok);
        compare(r.state.desktop.length, 0);
        verify(ms < 50, "40k entries took " + ms + " ms");
    }

    function test_manyDuplicateUidsAreLinear() {
        // Within the byte cap: thousands of entries that all claim the same uid. Linear work doubles with the input,
        // quadratic work quadruples it: compare the best of several samples at n and 2n instead of an absolute
        // budget. The samples alternate between the two sizes, so a load spike hits both best-ofs alike instead of
        // only the size measured while it lasted (a loaded machine failed the old back-to-back runs).
        const fileOf = n => JSON.stringify({version: 1, center: [], desktop: Array.from({length: n}, () => ({uid: "clock-1", id: "clock", size: "small", screen: "S", col: 0, row: 0}))});
        const small = fileOf(1500);
        const large = fileOf(3000);
        verify(large.length < 262144);
        const sample = text => {
            const t0 = Date.now();
            for (let k = 0; k < 4; ++k)
                Placements.parse(text);
            return Date.now() - t0;
        };
        sample(small); // warm up the JIT
        sample(large);
        let tSmall = Infinity;
        let tLarge = Infinity;
        for (let i = 0; i < 9; ++i) {
            tSmall = Math.min(tSmall, sample(small));
            tLarge = Math.min(tLarge, sample(large));
        }
        const r = Placements.parse(large);
        verify(r.ok);
        compare(r.state.desktop.length, 64);
        // Linear: ~2. Quadratic: ~4. The floor keeps a sub-millisecond small run from inflating the ratio.
        const ratio = tLarge / Math.max(tSmall, 20);
        verify(ratio < 3.2, "3000 entries took " + tLarge + " ms, 1500 took " + tSmall + " ms (ratio " + ratio + ")");
    }

    function test_fitScreenMovesOffGridAndOverlaps() {
        const mk = (uid, size, col, row, screen) => ({uid: uid, id: "clock", size: size, screen: screen || "S", col: col, row: row});
        const s = {version: 1, center: [], desktop: [mk("clock-1", "large", 0, 0), mk("clock-2", "small", 1, 1), mk("clock-3", "small", 1000, 1000), mk("clock-4", "small", 9, 9, "OTHER")]};
        const r = Placements.fitScreen(s, "S", 6, 4);
        verify(r.changed);
        const mine = r.state.desktop.filter(e => e.screen === "S");
        compare(mine.length, 3);
        mine.forEach(e => verify(Placements.isFree(mine.filter(o => o !== e), e.size, e, 6, 4), e.uid + " is inside the grid and free"));
        const other = r.state.desktop.find(e => e.screen === "OTHER");
        compare(other.col, 9, "other screens are untouched");
        compare(s.desktop[2].col, 1000, "input is not modified");
        // A fitted state is stable.
        verify(!Placements.fitScreen(r.state, "S", 6, 4).changed);
        // No room: the entry is dropped.
        const full = Placements.fitScreen({version: 1, center: [], desktop: [mk("clock-1", "large", 0, 0), mk("clock-2", "large", 0, 0)]}, "S", 2, 2);
        compare(full.state.desktop.length, 1);
    }

    // ---- grid below the menu bar and above the Dock ------------------------------------------------

    function test_gridAvoidsMenuBarAndDock() {
        const cell = 158, gap = 16, margin = 24, top = 24, dock = 48 + 14 + 6 + 4 + 6;
        [[1366, 768], [1600, 960], [1920, 1080], [3840, 2160]].forEach(sz => {
            const g = Placements.gridFor(sz[0], sz[1], cell, gap, margin, top, dock);
            verify(g.rows >= 1 && g.cols >= 1);
            compare(g.y0, top + margin);
            const bottom = g.y0 + g.rows * (cell + gap) - gap;
            verify(bottom <= sz[1] - dock - margin + 0.001 || g.rows === 1, sz[1] + ": grid bottom " + bottom + " clears the Dock");
            const right = g.x0 + g.cols * (cell + gap) - gap;
            verify(right <= sz[0] - margin);
            // One more row would not fit.
            verify(g.y0 + (g.rows + 1) * (cell + gap) - gap > sz[1] - dock - margin, sz[1] + ": rows are maximal");
        });
        compare(Placements.gridFor(1366, 768, cell, gap, margin, top, dock).rows, 3);
        compare(Placements.gridFor(1920, 1080, cell, gap, margin, top, dock).rows, 5);
        compare(Placements.gridFor(3840, 2160, cell, gap, margin, top, dock).rows, 11);
        compare(Placements.gridFor(300, 200, cell, gap, margin, top, dock).rows, 1, "never below one row");
    }

    // ---- art URL filter --------------------------------------------------------------------------

    // Review of 423766f: only a local file's path is kept, and it is shown only as a PNG the shell made (ThemeIcons).
    function test_artUrlFilter() {
        compare(ArtUrl.localPath("file:///home/u/.cache/art.png"), "/home/u/.cache/art.png");
        compare(ArtUrl.localPath("file://localhost/tmp/a.jpg"), "/tmp/a.jpg");
        compare(ArtUrl.localPath("FILE:///tmp/a.jpg"), "/tmp/a.jpg");
        compare(ArtUrl.localPath("file:///tmp/my%20art.png"), "/tmp/my art.png", "percent-decoded");
        ["http://127.0.0.1:18765/art.png", "https://example.com/a.png", "HTTP://x/a", "//example.com/a.png", "ftp://x/a", "smb://h/s/a.png",
         "file://example.com/share/a.png", "file:////server/share/a.png", "file:///tmp/a.png?x=1", "file:///", "file://", "qrc:/a.png", "image://theme/x",
         "/tmp/a.png", "a.png", "", "data:image/png;base64,AAAA", "data:image/svg+xml,<svg/>", "data:text/html,<script>", " http://x/a",
         "file:///tmp/a\u0000.png", "file:///tmp/a\n.png", "file:///tmp/a%0A.png", "file:///tmp/a%00.png", "file:///tmp/%E0%A4%A.png",
         null, undefined, 5, {}].forEach(u => compare(ArtUrl.localPath(u), "", "rejected: " + u));
    }

    // The https art the helper may fetch (services/image-copy.py checks the same pattern).
    function test_artRemoteUrl() {
        ["https://i.scdn.co/image/ab67616d0000b273", "https://example.com:8443/a.png?size=640&x=1", "https://cdn.example.org",
         "https://1.example.com/a.png", "https://art.test:4433/ok.png", "https://localhost.example.com/a.png"].forEach(u => compare(ArtUrl.remoteUrl(u), u, "accepted: " + u));
        // Review of dce68c2 (minor 1): no IP literal in any notation, no localhost name.
        ["https://127.0.0.1:4433/ok.png", "https://2130706433/a.png", "https://0x7f000001/a.png", "https://0x7f.0.0.1/a.png", "https://0177.0.0.1/a.png",
         "https://127.1/a.png", "https://10.0.0.1./a.png", "https://8.8.8.8/a.png", "https://localhost/a.png", "https://LOCALHOST./a.png",
         "https://art.localhost:8443/a.png", "https://x.y.localhost/a.png", "https://0x/a.png"].forEach(u => compare(ArtUrl.remoteUrl(u), "", "refused: " + u));
        // Review of 684ed6d: no empty label (curl would not match a trailing-dot name against the helper's pin), LDH
        // labels only; an uppercase or punycode name is fine (the helper lowercases it and pins exactly that).
        ["https://example.com./a.png", "https://example.com../a.png", "https://example..com/a.png", "https://.example.com/a.png",
         "https://-x.example.com/a.png", "https://x-.example.com/a.png", "https://k\u00f6merxe.example/a.png", "https://-/a.png"].forEach(u => compare(ArtUrl.remoteUrl(u), "", "refused: " + u));
        ["https://EXAMPLE.com/a.png", "https://xn--kmerxe-wxa.example/a.png", "https://a-b.example.com/a.png"].forEach(u => compare(ArtUrl.remoteUrl(u), u, "accepted: " + u));
        ["http://example.com/a.png", "HTTPS://example.com/a.png", "https://user:pw@example.com/a.png", "https://user@example.com/a.png",
         "https://[::1]/a.png", "https://example.com/a b.png", "https://example.com/a\\b.png", "https://example.com/a\n.png",
         "https://exa_mple.com/a.png", "https:///a.png", "ftp://example.com/a.png", "file:///tmp/a.png", "data:image/png;base64,AAAA",
         " https://example.com/a.png", "https://example.com/" + "a".repeat(2100), "", null, undefined, 5, {}].forEach(u => compare(ArtUrl.remoteUrl(u), "", "refused: " + u));
    }

    // ---- calendar in a zone with DST at midnight ------------------------------------------------------

    function test_daysInMonthIgnoresLocalTime() {
        // Asia/Beirut starts DST at 00:00 on the last Sunday of March (2024-03-31, 2030-03-31), so local
        // midnight of that day does not exist; the count must come from UTC date math.
        compare(Calendar.daysInMonth(2024, 2), 31);
        compare(Calendar.daysInMonth(2030, 2), 31);
        compare(Calendar.daysInMonth(2024, 1), 29);
        compare(Calendar.daysInMonth(2100, 1), 28);
        compare(Calendar.daysInMonth(2000, 1), 29);
        const real = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        for (let y = 2000; y <= 2060; y++) {
            for (let m = 0; m < 12; m++) {
                const leap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
                compare(Calendar.daysInMonth(y, m), m === 1 && leap ? 29 : real[m], y + "-" + m);
            }
        }
        // March 2024 starts on a Friday: with Sunday first, five leading cells; 31 days -> 6 weeks.
        const g = Calendar.monthGrid(2024, 2, 0);
        compare(g.length, 6);
        compare(g[0].filter(c => !c.inMonth).length, 5);
        compare(g[5].filter(c => c.inMonth).map(c => c.day).join(","), "31");
        compare(Calendar.monthGrid(2030, 2, 1)[0][4].day, 1, "March 2030 starts on a Friday");
    }

    function test_coveredBy() {
        const tile = {x: 24, y: 48, w: 332, h: 158};
        verify(Placements.coveredBy(tile, [{x: 0, y: 0, w: 1920, h: 1080}]), "fullscreen");
        verify(Placements.coveredBy(tile, [{x: 24, y: 48, w: 332, h: 158}]), "exact");
        verify(!Placements.coveredBy(tile, [{x: 25, y: 48, w: 1000, h: 1000}]), "one px short");
        verify(!Placements.coveredBy(tile, [{x: 0, y: 0, w: 200, h: 1080}, {x: 190, y: 0, w: 1000, h: 1080}]), "two windows do not add up");
        verify(!Placements.coveredBy(tile, []));
    }
}
