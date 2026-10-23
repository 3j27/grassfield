import QtQuick
import QtTest
import "../../shell/services/RecentItemsLogic.js" as Logic
import "../../shell/search/Files.js" as Files

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

    // REQ-DOCK-PAR-d6: recent documents of one application, for its Dock menu.
    readonly property string xbel: "<xbel>"
        + "<bookmark href=\"file:///home/u/a.txt\" modified=\"2026-01-02T00:00:00Z\"><info><metadata>"
        + "<bookmark:applications><bookmark:application name=\"Text Editor\" exec=\"&apos;gedit %U&apos;\" modified=\"2026-01-02T00:00:00Z\" count=\"1\"/></bookmark:applications>"
        + "</metadata></info></bookmark>"
        + "<bookmark href=\"file:///home/u/b.png\" modified=\"2026-01-03T00:00:00Z\"><info><metadata>"
        + "<bookmark:applications><bookmark:application name=\"Image Viewer\" exec=\"/usr/bin/eog %u\" count=\"1\"/><bookmark:application name=\"Text Editor\" exec=\"gedit\" count=\"1\"/></bookmark:applications>"
        + "</metadata></info></bookmark>"
        + "<bookmark href=\"file:///home/u/c.md\" modified=\"2026-01-04T00:00:00Z\"><info></info></bookmark></xbel>"

    function test_xbelApplications() {
        const r = Files.parseXbel(xbel);
        compare(r.length, 3);
        compare(r[0].path, "/home/u/c.md");
        compare(r[0].apps.length, 0);
        compare(r[1].apps.map(a => a.cmd).join(), "eog,gedit");
        compare(r[2].apps[0].name, "Text Editor");
        compare(r[2].apps[0].cmd, "gedit");
    }

    function test_documentsOfOneApp() {
        const list = Files.parseXbel(xbel);
        const state = {apps: [], clearedAt: 0};
        const gedit = Logic.documentsForApp(list, {name: "Text Editor", cmd: "gedit"}, state, 5).map(d => d.path);
        compare(gedit.join(), "/home/u/b.png,/home/u/a.txt", "newest first, by name or by program");
        compare(Logic.documentsForApp(list, {name: "", cmd: "/usr/bin/eog"}, state, 5).map(d => d.path).join(), "/home/u/b.png");
        compare(Logic.documentsForApp(list, {name: "text editor", cmd: ""}, state, 1).length, 1, "capped, case-insensitive");
        compare(Logic.documentsForApp(list, {name: "Nope", cmd: "nope"}, state, 5).length, 0);
        compare(Logic.documentsForApp(list, null, state, 5).length, 0);
        compare(Logic.documentsForApp(list, {name: "", cmd: ""}, state, 5).length, 0, "an app with no identity matches nothing");
        const cleared = {apps: [], clearedAt: Date.parse("2026-01-02T12:00:00Z")};
        compare(Logic.documentsForApp(list, {name: "Text Editor", cmd: "gedit"}, cleared, 5).map(d => d.path).join(), "/home/u/b.png", "Clear Menu hides older documents");
        compare(Logic.documentsForApp(null, {name: "x", cmd: "x"}, state, 5).length, 0);
    }
}
