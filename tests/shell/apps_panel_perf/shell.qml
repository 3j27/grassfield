pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "Ranking.js" as Ranking

// Apps panel cost with about 200 entries (docs/specs/apps.md, A9 and A4): time from showing the grid to its
// first rendered frame ("open"), and from a query change (ranking + model update) to the next rendered
// frame ("keystroke"), over a typing and erasing sequence. Run by scripts/dev/test.sh:
// `qs -p tests/shell/apps_panel_perf` (offscreen); prints the numbers and "apps-panel-perf: PASS" or FAIL.
// AppsGrid.qml, AppsCell.qml and Ranking.js are symlinks to shell/. The budgets are the spec's: open <= 300 ms (P3),
// keystroke p95 and first keystroke <= 50 ms (P4); the numbers are the evidence.
ShellRoot {
    id: root

    readonly property int count: 200
    readonly property var words: ["alpha", "beta", "gamma", "delta", "terminal", "editor", "browser", "music", "video", "photo", "mail", "chat", "game", "calc", "notes", "clock", "maps", "files", "archive", "paint"]
    readonly property var queries: ["t", "te", "ter", "term", "termi", "termin", "termina", "terminal", "termina", "termin", "termi", "term", "ter", "te", "t", "", "a", "al", "alp", "alph", "alpha", "alph", "alp", "al", "a", "", "zzz", ""]

    property var records: []
    property var allItems: []
    property int step: -1
    property real t0: 0
    property real openMs: 0
    property real changeMs: 0
    property var keyMs: []

    function build(): void {
        const recs = [];
        const items = [];
        for (let i = 0; i < count; i++) {
            const rec = {
                id: "fake" + i + ".desktop",
                name: words[i % words.length] + " " + words[(i * 7 + 3) % words.length] + " " + i,
                genericName: i % 3 === 0 ? "Utility" : "",
                comment: "Fake application number " + i,
                keywords: [words[(i * 5) % words.length]],
                icon: "application-x-executable"
            };
            recs.push(rec);
            items.push({key: "app:" + rec.id, id: rec.id, name: rec.name, rec: rec});
        }
        records = recs;
        allItems = items;
        // As AppsController does when the list is built: the first keystroke must not pay for the preparation.
        Ranking.warm(recs);
    }

    function itemsFor(q: string): var {
        if (q === "")
            return allItems;
        const byId = {};
        for (const it of allItems)
            byId[it.id] = it;
        return Ranking.rank(records, q, Ranking.newUsage(), 0).map(r => byId[r.app.id]);
    }

    function median(a: var): real {
        const s = a.slice().sort((x, y) => x - y);
        return s[Math.floor(s.length / 2)];
    }

    function finish(): void {
        const sorted = keyMs.slice().sort((x, y) => x - y);
        const p95 = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))];
        const max = sorted[sorted.length - 1];
        console.info("apps-panel-perf: open", openMs, "ms,", count, "items; keystroke median", median(keyMs), "p95", p95, "max", max, "ms over", keyMs.length, "queries");
        console.info("apps-panel-perf: per query (ms):", keyMs.map((ms, i) => "'" + queries[i] + "' " + ms).join(", "));
        const fails = [];
        if (openMs > 300)
            fails.push("open " + openMs + " ms > 300");
        // P4: a keystroke costs at most 50 ms (p95), and so does the first one after the panel was built.
        if (p95 > 50)
            fails.push("keystroke p95 " + p95 + " ms > 50");
        if (keyMs[0] > 50)
            fails.push("first keystroke " + keyMs[0] + " ms > 50");
        console.info(fails.length === 0 ? "apps-panel-perf: PASS" : "apps-panel-perf: FAIL " + fails.join("; "));
        Qt.quit();
    }

    FloatingWindow {
        id: win
        implicitWidth: 844
        implicitHeight: 560
        visible: false
        color: "black"

        // The symlinked component is resolved by Quickshell from this directory; qmllint cannot see it.
        // qmllint disable import unresolved-type missing-property unqualified
        AppsGrid {
            id: grid
            anchors.fill: parent
            cellWidth: width / 7
            cellHeight: 102
            items: []
            selectedIndex: -1
            ringVisible: false
        }
        // qmllint enable import unresolved-type missing-property unqualified

        // A query whose result is the same list in the same order changes nothing on screen, so no frame
        // follows: the guard then records the time of the change itself.
        Timer {
            id: guard
            interval: 300
            onTriggered: root.record(root.changeMs)
        }

        Connections {
            target: win.visible ? grid.Window.window : null

            function onFrameSwapped(): void {
                guard.stop();
                root.record(Date.now() - root.t0);
            }
        }
    }

    // One measurement done: store it and start the next query once the frame has finished.
    function record(ms: real): void {
        if (step < 0)
            openMs = ms;
        else
            keyMs.push(ms);
        step++;
        if (step >= queries.length) {
            finish();
            return;
        }
        Qt.callLater(() => {
            t0 = Date.now();
            grid.items = itemsFor(queries[step]);
            changeMs = Date.now() - t0;
            guard.restart();
        });
    }

    Component.onCompleted: {
        build();
        Qt.callLater(() => {
            // Idle time after the list is built (before the window is ever shown): fill the cell pool, as AppsWindow does.
            grid.items = root.allItems;
            grid.warmPool();
            root.t0 = Date.now();
            win.visible = true;
        });
    }
}
