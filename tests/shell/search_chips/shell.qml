pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.search

// F2c fix pass on the REAL Search controller (scripts/dev/test.sh: `qs -p tests/shell/search_chips`, offscreen; prints
// "search-chips: PASS" or the failures). search, services and platform are symlinks to shell/.
// - filesPending is true while a live file search runs (the array is reassigned, a push never notified): the
//   "No Results" notice must not show while the plocate fallback is still running;
// - the filter chips are reachable by keyboard: Tab past the last group moves the ring to the first chip,
//   Left/Right move, Space toggles, Esc and Tab past the end leave, typing leaves and is handed back to the field;
ShellRoot {
    id: root

    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Search {
        id: search
    }

    function run(): void {
        // filesPending follows the live searches.
        check("pending starts false", search.filesPending === false);
        search.spawnSearch(1, "zz-no-such-file", "plocate");
        check("pending true while a search runs", search.filesPending === true);
        search.cancelFiles();
        check("pending false once cancelled", search.filesPending === false);

        // Chips: two groups, three chips.
        search.query = "x";
        search.chips = ["apps", "commands", "documents"];
        search.groups = [{id: "apps", items: []}, {id: "commands", items: []}];
        search.items = [{groupId: "apps"}, {groupId: "commands"}];
        search.selected = 0;
        check("chips shown", search.chipsShown);
        search.moveGroup(1);
        check("Tab to the next group first", search.zone === "field" && search.selected === 1);
        search.moveGroup(1);
        check("Tab past the last group enters the chips", search.zone === "chips" && search.chipIndex === 0);
        check("Right moves", search.chipKey("right") && search.chipIndex === 1);
        check("Right stops at the end", search.chipKey("end") && search.chipKey("right") && search.chipIndex === 2);
        check("Left moves", search.chipKey("left") && search.chipIndex === 1);
        check("a typed letter leaves and is handed back", !search.chipKey("other") && search.zone === "field");

        // Space asks to toggle (the filter itself is Filters.js + toggleFilter, covered by tst_searchfilters).
        search.zone = "chips";
        search.chipIndex = 1;
        check("Space is consumed by the chips", search.chipKey("activate"));
        search.query = "x";
        search.chips = ["apps", "commands", "documents"];
        search.zone = "chips";
        search.chipIndex = 1;
        check("Esc leaves", search.chipKey("escape") && search.zone === "field");
        search.zone = "chips";
        search.chipIndex = 2;
        check("Tab past the last chip leaves", search.chipKey("next") && search.zone === "field");
        search.query = "x";
        search.chips = ["apps", "commands", "documents"];
        search.groups = [{id: "apps", items: []}, {id: "commands", items: []}];
        search.items = [{groupId: "apps"}, {groupId: "commands"}];
        search.selected = 0;
        search.moveGroup(-1);
        check("Shift+Tab before the first group enters the last chip", search.zone === "chips" && search.chipIndex === 2);
        search.hide();
        check("hide leaves the chips", search.zone === "field");

        // macOS: an empty field lists nothing (no recent documents); the first keystroke brings the results.
        search.recentList = [{path: "/home/u/report.txt"}, {path: "/home/u/notes.txt"}];
        search.fileHits = [];
        search.query = "";
        search.compute();
        check("empty query lists no group", search.groups.length === 0 && search.items.length === 0);
        search.query = "   ";
        search.compute();
        check("blank query lists no group", search.groups.length === 0);
        search.query = "report";
        search.compute();
        const ids = search.groups.map(g => g.id);
        check("a keystroke brings the matching recent document", ids.indexOf("recent") >= 0 || ids.indexOf("top") >= 0);
        check("non-matching recents stay out", JSON.stringify(search.groups).indexOf("notes.txt") < 0);
    }

    Timer {
        interval: 200
        running: true
        onTriggered: {
            root.run();
            if (root.failures.length === 0) {
                console.log("search-chips: PASS");
                Qt.exit(0);
            } else {
                console.log("search-chips: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }
}
