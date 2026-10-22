import QtQuick
import QtTest
import "../../shell/services/RecentItemsLogic.js" as Logic

// Recent Items of the Grassfield menu (macOS Apple menu > Recent Items): launch history, Clear Menu, the submenu rows.
TestCase {
    name: "RecentItems"

    readonly property var texts: ({applications: "Applications", documents: "Documents", clear: "Clear Menu"})

    function lookup(id) {
        return id === "gone" ? null : {name: id.toUpperCase()};
    }

    function test_launchesGoToTheFrontOnceAndAreCapped() {
        let s = {apps: [], clearedAt: 0};
        s = Logic.withLaunch(s, "a", 1, 3);
        s = Logic.withLaunch(s, "b", 2, 3);
        s = Logic.withLaunch(s, "a", 3, 3);
        s = Logic.withLaunch(s, "c", 4, 3);
        s = Logic.withLaunch(s, "d", 5, 3);
        compare(s.apps.map(a => a.id).join(","), "d,c,a");
        compare(s.apps[2].at, 3);
        compare(Logic.withLaunch(s, "", 6, 3).apps.length, 3, "an empty id is ignored");
        compare(Logic.withLaunch(s, 42, 6, 3).apps[0].id, "d", "a non-string id is ignored");
    }

    function test_clearHidesEverythingBeforeIt() {
        let s = Logic.withLaunch({apps: [], clearedAt: 0}, "a", 1, 10);
        s = Logic.cleared(s, 100);
        compare(s.apps.length, 0);
        const docs = [{path: "/h/new.txt", modified: 150}, {path: "/h/old.txt", modified: 50}];
        compare(Logic.documents(docs, s, 10).map(d => d.path).join(","), "/h/new.txt");
        compare(Logic.documents(docs, {apps: [], clearedAt: 0}, 1).length, 1, "capped");
    }

    function test_untrustedStateIsNormalized() {
        const s = Logic.normalize({apps: [{id: "ok", at: 1}, {id: "", at: 2}, {id: "x"}, null, {id: 7, at: 3}], clearedAt: "soon"});
        compare(s.apps.map(a => a.id).join(","), "ok");
        compare(s.clearedAt, 0);
        compare(Logic.normalize(null).apps.length, 0);
        compare(Logic.normalize("junk").clearedAt, 0);
    }

    function test_applicationsSkipEntriesThatAreGone() {
        const s = {apps: [{id: "gone", at: 3}, {id: "foot", at: 2}, {id: "files", at: 1}], clearedAt: 0};
        const apps = Logic.applications(s, 10, lookup);
        compare(apps.map(a => a.id).join(","), "foot,files");
        compare(apps[0].name, "FOOT");
        compare(Logic.applications(s, 1, lookup).length, 1);
    }

    function test_menuRows() {
        const rows = Logic.menu([{id: "foot", name: "Foot"}], [{path: "/h/Docs/report.pdf", modified: 5}], texts);
        compare(rows.filter(r => !r.separator).map(r => r.id).join(","), "recentHeader,recentApp,recentHeader,recentDocument,recentClear");
        compare(rows[0].text, "Applications");
        verify(rows[0].enabled === false, "headers are not choosable");
        compare(rows[1].appId, "foot");
        const doc = rows.find(r => r.id === "recentDocument");
        compare(doc.text, "report.pdf");
        compare(doc.path, "/h/Docs/report.pdf");
        verify(rows.find(r => r.id === "recentClear").enabled);
        const empty = Logic.menu([], [], texts);
        compare(empty.filter(r => !r.separator).map(r => r.id).join(","), "recentHeader,recentHeader,recentClear");
        verify(!empty.find(r => r.id === "recentClear").enabled, "nothing to clear");
    }
}
