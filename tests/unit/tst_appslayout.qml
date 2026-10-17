import QtQuick
import QtTest
import "../../shell/launchpad/Model.js" as Model

TestCase {
    name: "AppsLayout"

    readonly property var installed: [
        {id: "b.desktop", name: "Bravo"},
        {id: "a.desktop", name: "alpha"},
        {id: "c.desktop", name: "Charlie"},
        {id: "d.desktop", name: "Delta"}
    ]
    readonly property var gopts: ({iconSize: 96, widthFraction: 0.8, heightFraction: 0.7, cellWidthScale: 2.2, cellHeightScale: 1.55, minCols: 3, maxCols: 10, minRows: 2, maxRows: 7})

    function ids(items) {
        return items.map(it => it.t === "app" ? it.id : "[" + it.apps.join(",") + "]");
    }

    function test_firstRunSortedByName() {
        compare(ids(Model.reconcile([], installed)), ["a.desktop", "b.desktop", "c.desktop", "d.desktop"]);
    }

    function test_pruneAndAppend() {
        const saved = [{t: "app", id: "gone.desktop"}, {t: "app", id: "c.desktop"},
            {t: "folder", key: "f1", name: "X", apps: ["zzz.desktop", "a.desktop"]},
            {t: "folder", key: "f2", name: "Empty", apps: ["nope.desktop"]}, {t: "app", id: "c.desktop"}];
        const out = Model.reconcile(saved, installed);
        compare(ids(out), ["c.desktop", "[a.desktop]", "b.desktop", "d.desktop"]);
    }

    function test_createFolder() {
        const base = Model.reconcile([], installed);
        const out = Model.createFolder(base, 3, 1, "Untitled");
        compare(ids(out), ["a.desktop", "[b.desktop,d.desktop]", "c.desktop"]);
        compare(out[1].name, "Untitled");
        compare(base.length, 4);
        compare(ids(Model.createFolder(out, 1, 0, "n")), ids(out));
    }

    function test_addAndRemoveFromFolder() {
        let items = Model.createFolder(Model.reconcile([], installed), 1, 0, "F");
        compare(ids(items), ["[a.desktop,b.desktop]", "c.desktop", "d.desktop"]);
        items = Model.addToFolder(items, 1, 0);
        compare(ids(items), ["[a.desktop,b.desktop,c.desktop]", "d.desktop"]);
        const key = items[0].key;
        items = Model.removeFromFolder(items, key, "b.desktop");
        compare(ids(items), ["[a.desktop,c.desktop]", "b.desktop", "d.desktop"]);
        items = Model.removeFromFolder(items, key, "a.desktop");
        items = Model.removeFromFolder(items, key, "c.desktop");
        verify(items.every(it => it.t === "app"), "empty folder disappears");
        compare(items.length, 4);
    }

    function test_moveAndRename() {
        const base = Model.reconcile([], installed);
        compare(ids(Model.moveTo(base, 0, 2)), ["b.desktop", "c.desktop", "a.desktop", "d.desktop"]);
        compare(ids(Model.moveTo(base, 3, 0)), ["d.desktop", "a.desktop", "b.desktop", "c.desktop"]);
        compare(ids(Model.moveTo(base, 1, 1)), ids(base));
        const f = Model.createFolder(base, 1, 0, "Old");
        compare(Model.renameFolder(f, f[0].key, "  New  ")[0].name, "New");
    }

    function test_persistenceRoundTrip() {
        let items = Model.createFolder(Model.reconcile([], installed), 2, 0, "Tools");
        items = Model.moveTo(items, 0, 2);
        const back = Model.parse(Model.serialize(items));
        compare(ids(back), ids(items));
        compare(back.find(i => i.t === "folder").name, "Tools");
        compare(ids(Model.reconcile(back, installed)), ids(items));
    }

    function test_parseCorrupt() {
        compare(Model.parse("not json").length, 0);
        compare(Model.parse('{"version": 2, "items": ["a"]}').length, 0);
        compare(Model.parse('{"version": 1, "items": [1, null, "x.desktop", {"folder": 3}]}').length, 1);
    }

    function test_gridAt1080() {
        const g = Model.grid(1920, 1080, gopts);
        compare(g.cols, 7);
        compare(g.rows, 5);
        compare(g.icon, 96);
        compare(g.perPage, 35);
        const small = Model.grid(800, 600, gopts);
        verify(small.cols >= 3 && small.rows >= 2);
    }

    function test_paging() {
        compare(Model.pageCount(0, 35), 1);
        compare(Model.pageCount(35, 35), 1);
        compare(Model.pageCount(36, 35), 2);
        compare(Model.pageOf(34, 35), 0);
        compare(Model.pageOf(35, 35), 1);
        compare(Model.clampPage(9, 80, 35), 2);
        compare(Model.clampPage(-1, 80, 35), 0);
    }

    function test_cellAt() {
        const g = Model.grid(1920, 1080, gopts);
        const a = Model.cellAt(g.cellW * 1.5, g.cellH * 0.5, g, 0, 100, 0.6);
        compare(a.index, 1);
        verify(a.center);
        const b = Model.cellAt(g.cellW * 1.05, g.cellH * 0.5, g, 1, 100, 0.6);
        compare(b.index, 36);
        verify(!b.center);
        compare(Model.cellAt(-1, 5, g, 0, 100, 0.6).index, -1);
        compare(Model.cellAt(g.cellW * 3.5, g.cellH * 0.5, g, 0, 3, 0.6).index, -1);
    }

    function test_keyboardStep() {
        compare(Model.step(-1, "right", 7, 35, 50), 0);
        compare(Model.step(34, "right", 7, 35, 50), 35);
        compare(Model.step(35, "left", 7, 35, 50), 34);
        compare(Model.step(3, "down", 7, 35, 50), 10);
        compare(Model.step(3, "up", 7, 35, 50), 3);
        compare(Model.step(30, "down", 7, 35, 50), 30);
        compare(Model.step(49, "right", 7, 35, 50), 49);
        compare(Model.step(0, "end", 7, 35, 50), 49);
        compare(Model.step(0, "left", 7, 35, 50), 0);
    }

    function test_hiddenIdsMatchEntryIds() {
        // hidden-entries.sh prints ids without the suffix; tolerate a suffix or CRLF anyway.
        const set = Model.parseHidden("rvhide-kde\nsub-nested.desktop\r\n\nplain\n");
        verify(Model.isHidden(set, "rvhide-kde"));
        verify(Model.isHidden(set, "rvhide-kde.desktop"));
        verify(Model.isHidden(set, "sub-nested"));
        verify(Model.isHidden(set, "plain"));
        verify(!Model.isHidden(set, "rvhide"));
        verify(!Model.isHidden(Model.parseHidden(""), "plain"));
    }
}
