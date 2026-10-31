pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Grassfield.I18n
import qs.search

// Capture defect 5 on the REAL Search controller, in French (scripts/dev/test.sh: `qs -p tests/shell/search_locale`, offscreen, a
// dev session with the shipped catalog; prints "search-locale: PASS" or the failures). The shell's language drives the
// conversions and the calculator (connectors, decimal comma, grouping) and the duplicate "Lock Screen" rows of the commands and
// the Settings pages are one.
ShellRoot {
    id: root

    property var failures: []

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Search {
        id: search
        showApps: false
        showDocuments: false
        showRecents: false
        showCalculator: true
        showConversions: true
        showSettings: true
        showCommands: true
    }

    function group(id: string): var {
        return search.groups.find(g => g.id === id);
    }

    function rows(): string {
        return search.items.map(i => i.title + "|" + i.subtitle).join(" // ");
    }

    function run(): void {
        const g = Qt.locale().groupSeparator;
        check("the session is French", Translator.language === "fr" && Qt.locale().decimalPoint === ",");

        search.setQuery("25 km en mi");
        check("en: a conversion", root.group("units") !== undefined && root.group("units").items[0].title === "15,5343 mi");
        search.setQuery("25 km vers mi");
        check("vers: a conversion", root.group("units") !== undefined && root.group("units").items[0].title === "15,5343 mi");
        search.setQuery("2,5 km en m");
        check("decimal comma", root.group("units") !== undefined && root.group("units").items[0].title === "2" + g + "500 m");
        search.setQuery("120*163");
        check("calculator grouping", root.group("calc") !== undefined && root.group("calc").items[0].title === "19" + g + "560");
        search.setQuery("1,5*2");
        check("calculator decimal comma", root.group("calc") !== undefined && root.group("calc").items[0].title === "3");

        // « écran »: the command and the Settings page are not the same row twice.
        search.setQuery("écran");
        const titles = search.items.map(i => i.title);
        const lockRows = titles.filter(t => t === "Verrouiller l’écran");
        check("one 'Verrouiller l'écran' for écran, got: " + root.rows(), lockRows.length === 1);
        check("the Settings page keeps its own name", titles.indexOf("Écran verrouillé") >= 0);
        check("a title is never shown twice", titles.length === new Set(titles).size);

        // English: the command and the page read the same, one row.
        Translator.language = "en";
        search.setQuery("lock screen");
        const en = search.items.map(i => i.title).filter(t => t === "Lock Screen");
        check("English: one 'Lock Screen' row, got: " + root.rows(), en.length === 1);
        search.setQuery("25 km in mi");
        check("English: the point and no grouping under 1000", root.group("units") !== undefined && root.group("units").items[0].title === "15.5343 mi");

        if (failures.length === 0) {
            console.log("search-locale: PASS");
            Qt.exit(0);
        } else {
            console.log("search-locale: FAIL " + failures.join("; "));
            Qt.exit(1);
        }
    }

    Timer {
        interval: 300
        running: true
        onTriggered: {
            Translator.language = "fr";
            root.run();
        }
    }
}
