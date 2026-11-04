import QtQuick
import QtTest
import "../../shell/services/EmojiLogic.js" as Logic

// Emoji & Symbols (ADR-0045 OC-3, docs/specs/clipboard.md ES-1 to ES-8): the panel's pure logic on a small fixture of our own
// (tests/fixtures/emojis.json: 28 entries, each CLDR group's first emoji where Omarchy's list has it, never Omarchy's file):
// the entries' validation, the categories from the groups' first emoji and the one "All" group when they are not where they
// belong, the sections in macOS's order, the search's matches and ranking, Recently Used, the grid's rows and keys, the
// placement at the pointer, the insertion's wait and its argument vector.
TestCase {
    name: "Emoji"

    readonly property var fixture: Logic.parse(read("tests/fixtures/emojis.json"))
    readonly property var titles: ({
            recents: "Recently Used",
            smileys: "Smileys & People",
            animals: "Animals & Nature",
            food: "Food & Drink",
            activity: "Activity",
            travel: "Travel & Places",
            objects: "Objects",
            symbols: "Symbols",
            flags: "Flags",
            all: "All"
        })
    // The French titles (the catalog's), for the category search.
    readonly property var titlesFr: ({
            smileys: "Smileys et personnes",
            animals: "Animaux et nature",
            food: "Nourriture et boissons",
            activity: "Activités",
            travel: "Voyages et lieux",
            objects: "Objets",
            symbols: "Symboles",
            flags: "Drapeaux"
        })

    function read(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        return xhr.responseText;
    }

    function glyphs(list) {
        return list.map(item => item.e);
    }

    // ---- The data (ES-3) ----

    function test_theFixtureIsParsed() {
        compare(fixture.length, 28);
        compare(fixture[0].e, "\u{1F600}");
        compare(fixture[0].k, "grinning face smile");
        compare(fixture[0].w, ["grinning", "face", "smile"], "the keywords' words are kept for the search");
        compare(fixture[27].e, "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}", "a subdivision flag (tag characters)");
    }

    function test_badDataGivesNothing() {
        compare(Logic.parse(""), []);
        compare(Logic.parse("not json"), []);
        compare(Logic.parse("{\"e\": \"x\"}"), [], "not an array");
        compare(Logic.parse("null"), []);
    }

    function test_badEntriesAreDropped() {
        const list = Logic.parse(JSON.stringify([
            {e: "\u{1F600}", k: "grinning"},
            {e: "\u{1F600}", k: "a repeat"},
            {e: "", k: "empty"},
            {e: 42, k: "a number"},
            {k: "no glyph"},
            null,
            "a string",
            {e: "a\nb", k: "a line feed"},
            {e: "\u202Eevil", k: "a bidi override"},
            {e: "x".repeat(49), k: "too long"},
            {e: "\u{1F44B}", k: 7},
            {e: "\u{1F431}", k: "k".repeat(600)}
        ]));
        compare(glyphs(list), ["\u{1F600}", "\u{1F44B}", "\u{1F431}"]);
        compare(list[1].k, "", "keywords that are not a string are none");
        compare(list[2].k.length, 512, "keywords are cut at 512 characters");
    }

    function test_glyphRule() {
        verify(Logic.isGlyph("\u{1F600}"));
        verify(Logic.isGlyph("\u{1F469}\u200D\u{1F4BB}"), "a joiner sequence");
        verify(Logic.isGlyph("#\uFE0F\u20E3"), "a keycap");
        verify(!Logic.isGlyph(""));
        verify(!Logic.isGlyph(undefined));
        verify(!Logic.isGlyph("a\u0007"), "a control character");
        verify(!Logic.isGlyph("a\u2028"), "a line separator");
        verify(!Logic.isGlyph("\u2066x"), "a bidi isolate");
        verify(Logic.isGlyph("x".repeat(48)));
        verify(!Logic.isGlyph("x".repeat(49)));
    }

    // ---- Categories (ES-4) ----

    function test_categoriesFromTheGroupsFirstEmoji() {
        compare(Logic.categories(fixture), [
            {id: "smileys", start: 0, end: 6},
            {id: "animals", start: 6, end: 10},
            {id: "food", start: 10, end: 13},
            {id: "travel", start: 13, end: 16},
            {id: "activity", start: 16, end: 19},
            {id: "objects", start: 19, end: 22},
            {id: "symbols", start: 22, end: 25},
            {id: "flags", start: 25, end: 28}
        ]);
    }

    function test_aMissingFirstEmojiGivesOneGroup() {
        const list = fixture.filter(item => item.e !== "\u{1F3E7}");   // no ATM sign: Symbols has no start
        compare(Logic.categories(list), [{id: "all", start: 0, end: 27}]);
    }

    function test_firstEmojiOutOfOrderGivesOneGroup() {
        const list = fixture.slice();
        const flag = list.splice(25, 1)[0];   // the chequered flag before the food
        list.splice(10, 0, flag);
        compare(Logic.categories(list), [{id: "all", start: 0, end: 28}]);
    }

    function test_aListNotStartingWithTheFirstGroupGivesOneGroup() {
        const list = [{e: "\u{1F9EA}", k: "test tube"}].concat(fixture);
        compare(Logic.categories(list), [{id: "all", start: 0, end: 29}]);
        compare(Logic.categories([]), []);
    }

    function test_thePresentationSelectorIsIgnored() {
        const list = fixture.map(item => item.e === "\u{1F30D}" ? {e: "\u{1F30D}\uFE0F", k: item.k} : item);
        compare(Logic.categories(list)[3], {id: "travel", start: 13, end: 16});
    }

    // ---- Sections (ES-2, ES-8) ----

    function test_sectionsInMacOrder() {
        const sections = Logic.sections(fixture, Logic.categories(fixture), [], titles);
        compare(sections.map(s => s.id), ["smileys", "animals", "food", "activity", "travel", "objects", "symbols", "flags"],
                "Activity before Travel & Places, no Recently Used without recents");
        compare(sections[3].title, "Activity");
        compare(sections[3].items, ["\u{1F383}", "\u26BD", "\u{1F3AE}"]);
        compare(sections[0].items.length, 6, "Smileys & Emotion and People & Body are one section");
    }

    function test_recentlyUsedComesFirstWithKnownGlyphsOnly() {
        const sections = Logic.sections(fixture, Logic.categories(fixture), ["\u{1F431}", "\u{1F9EA}", "\u{1F600}"], titles);
        compare(sections[0].id, "recents");
        compare(sections[0].title, "Recently Used");
        compare(sections[0].items, ["\u{1F431}", "\u{1F600}"], "a glyph no longer in the list is not shown");
    }

    function test_theAllGroupIsOneSection() {
        const list = fixture.filter(item => item.e !== "\u{1F3E7}");
        const sections = Logic.sections(list, Logic.categories(list), ["\u{1F600}"], titles);
        compare(sections.map(s => s.id), ["recents", "all"]);
        compare(sections[1].items.length, 27);
        compare(Logic.ICONS[sections[1].id], "grid");
    }

    function test_everySectionHasAGlyph() {
        for (const id of Logic.ORDER)
            verify(typeof Logic.ICONS[id] === "string" && Logic.ICONS[id] !== "", id);
        compare(Logic.ICONS.recents, "clock");
    }

    // ---- Search (ES-5) ----

    function test_searchMatchesKeywords() {
        compare(Logic.search(fixture, Logic.categories(fixture), "cat", titles), ["\u{1F431}"]);
        compare(Logic.search(fixture, Logic.categories(fixture), "PIZZA", titles), ["\u{1F355}"], "case is ignored");
        compare(Logic.search(fixture, Logic.categories(fixture), "", titles), []);
        compare(Logic.search(fixture, Logic.categories(fixture), "   ", titles), []);
        compare(Logic.search(fixture, Logic.categories(fixture), "zebra", titles), []);
    }

    function test_aWholeWordComesBeforeAWordInside() {
        // "light bulb" is a whole word; "flight" holds it: the bulb first though the airplane comes first in the list.
        compare(Logic.search(fixture, Logic.categories(fixture), "light", titles), ["\u{1F4A1}", "\u2708\uFE0F"]);
    }

    function test_aWordsBeginningComesBeforeAnInsideMatch() {
        // "foot" begins "football"; "soccer ball football" is the only one.
        compare(Logic.search(fixture, Logic.categories(fixture), "foot", titles), ["\u26BD"]);
        // "love" is a whole word of two entries: the list's order between them.
        compare(Logic.search(fixture, Logic.categories(fixture), "lov", titles), ["\u{1F970}", "\u2764\uFE0F"]);
    }

    function test_everyWordMustMatch() {
        compare(Logic.search(fixture, Logic.categories(fixture), "dog face", titles), ["\u{1F436}"]);
        compare(Logic.search(fixture, Logic.categories(fixture), "face", titles),
                ["\u{1F600}", "\u{1F602}", "\u{1F970}", "\u{1F435}", "\u{1F431}", "\u{1F436}"]);
    }

    function test_underscoresHyphensAndColonsSplitWords() {
        compare(Logic.search(fixture, Logic.categories(fixture), "lantern", titles), ["\u{1F383}"]);
        compare(Logic.search(fixture, Logic.categories(fixture), "france", titles), ["\u{1F1EB}\u{1F1F7}"]);
    }

    function test_categoryTitlesAreSearchedInTheShellsLanguage() {
        // "animaux" is no keyword: the French title of Animals & Nature finds its four entries, in the list's order.
        compare(Logic.search(fixture, Logic.categories(fixture), "animaux", titlesFr),
                ["\u{1F435}", "\u{1F431}", "\u{1F436}", "\u{1F335}"]);
        // Accents are ignored: "activites" finds Activités.
        compare(Logic.search(fixture, Logic.categories(fixture), "activites", titlesFr), ["\u{1F383}", "\u26BD", "\u{1F3AE}"]);
    }

    function test_aKeywordMatchComesBeforeACategoryMatch() {
        // "flag" is a keyword of the three flags and the beginning of no title in English but "Flags": the keyword matches
        // first, in the list's order.
        compare(Logic.search(fixture, Logic.categories(fixture), "flag", titles), ["\u{1F3C1}", "\u{1F1EB}\u{1F1F7}",
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"]);
        // "objects": the title only; "phone" is a keyword of one of them: it leads.
        compare(Logic.search(fixture, Logic.categories(fixture), "object", titles), ["\u{1F453}", "\u{1F4A1}", "\u{1F4F1}"]);
        compare(Logic.search(fixture, Logic.categories(fixture), "object phone", titles), ["\u{1F4F1}"]);
        // Even a keyword's inside match ("seafood") leads a category title's whole word ("Food").
        const list = Logic.parse(JSON.stringify([{e: "\u{1F990}", k: "shrimp seafood"}, {e: "\u{1F347}", k: "grapes"}]));
        compare(Logic.search(list, [{id: "animals", start: 0, end: 1}, {id: "food", start: 1, end: 2}], "food", titles), ["\u{1F990}", "\u{1F347}"]);
    }

    // ---- Recently Used (ES-8) ----

    function test_recentsRoundTrip() {
        const list = Logic.addRecent(Logic.addRecent([], "\u{1F600}"), "\u{1F431}");
        compare(list, ["\u{1F431}", "\u{1F600}"]);
        compare(Logic.parseRecents(Logic.serializeRecents(list)), list);
        compare(JSON.parse(Logic.serializeRecents(list)).v, 1);
    }

    function test_aRecentGoesFirstOnce() {
        compare(Logic.addRecent(["\u{1F431}", "\u{1F600}", "\u{1F436}"], "\u{1F600}"), ["\u{1F600}", "\u{1F431}", "\u{1F436}"]);
        compare(Logic.addRecent(["\u{1F431}"], "a\nb"), ["\u{1F431}"], "a refused glyph changes nothing");
    }

    function test_recentsKeepThirty() {
        let list = [];
        for (let i = 0; i < 40; i++)
            list = Logic.addRecent(list, String.fromCodePoint(0x1F600 + i));
        compare(list.length, 30);
        compare(list[0], String.fromCodePoint(0x1F600 + 39));
        compare(list[29], String.fromCodePoint(0x1F600 + 10));
        const many = [];
        for (let i = 0; i < 40; i++)
            many.push(String.fromCodePoint(0x1F600 + i));
        compare(Logic.parseRecents(JSON.stringify({v: 1, recents: many})).length, 30, "a longer file is cut");
    }

    function test_badRecentsFileGivesNothingOrTheGoodPart() {
        compare(Logic.parseRecents(""), []);
        compare(Logic.parseRecents("[1, 2]"), []);
        compare(Logic.parseRecents("{\"v\": 1}"), []);
        compare(Logic.parseRecents(JSON.stringify({v: 1, recents: ["\u{1F600}", 3, "a\u0000", "\u{1F600}", "\u{1F431}"]})),
                ["\u{1F600}", "\u{1F431}"]);
    }

    // ---- The grid (ES-6) ----

    function test_rowsHeadersAndIndices() {
        const sections = [{id: "a", title: "A", items: ["1", "2", "3"]}, {id: "b", title: "B", items: ["4", "5"]}];
        const rows = Logic.rows(sections, 2, true);
        compare(rows, [
            {kind: "header", section: 0, title: "A", start: 0},
            {kind: "cells", section: 0, start: 0, items: ["1", "2"]},
            {kind: "cells", section: 0, start: 2, items: ["3"]},
            {kind: "header", section: 1, title: "B", start: 3},
            {kind: "cells", section: 1, start: 3, items: ["4", "5"]}
        ]);
        compare(Logic.rows(sections, 2, false).length, 3, "a search's results have no title row");
        compare(Logic.rowOf(rows, 0), 1);
        compare(Logic.rowOf(rows, 2), 2);
        compare(Logic.rowOf(rows, 4), 4);
        compare(Logic.rowOf(rows, 5), -1);
        compare(Logic.rowOf(rows, -1), -1);
        compare(Logic.sectionRow(rows, 1), 3);
        compare(Logic.sectionOfRow(rows, 4), 1);
        compare(Logic.sectionOfRow(rows, 9), -1);
    }

    // Three sections of 3, 5 and 2 glyphs, three to a row:
    //   0 1 2 | 3 4 5 / 6 7 | 8 9
    readonly property var lengths: [3, 5, 2]

    function move(current, key) {
        return Logic.move(lengths, 3, current, key, 2);
    }

    function test_noSelectionSelectsTheFirstGlyph() {
        compare(move(-1, "down"), 0);
        compare(move(-1, "right"), 0);
        compare(move(-1, "up"), 0);
        compare(move(-1, "end"), 9);
        compare(Logic.move([], 3, -1, "down", 2), -1, "an empty grid");
        compare(Logic.move([0, 0], 3, 2, "down", 2), -1);
    }

    function test_leftAndRightGoInReadingOrder() {
        compare(move(2, "right"), 3, "into the next section");
        compare(move(3, "left"), 2);
        compare(move(0, "left"), 0);
        compare(move(9, "right"), 9);
    }

    function test_downKeepsTheColumn() {
        compare(move(1, "down"), 4, "the next section's first row, same column");
        compare(move(4, "down"), 7);
        compare(move(5, "down"), 7, "a shorter row: its last glyph");
        compare(move(7, "down"), 9, "into the last section");
        compare(move(9, "down"), 9, "the end");
    }

    function test_upKeepsTheColumn() {
        compare(move(9, "up"), 7, "the previous section's last row");
        compare(move(8, "up"), 6);
        compare(move(6, "up"), 3);
        compare(move(4, "up"), 1);
        compare(move(0, "up"), 0);
        compare(Logic.move([3, 4], 3, 6, "up", 2), 3);
        compare(Logic.move([2, 3], 3, 4, "up", 2), 1, "a shorter row above: its last glyph");
    }

    function test_pagesHomeAndEnd() {
        compare(move(0, "pageDown"), 6);
        compare(move(9, "pageUp"), 4);
        compare(move(5, "home"), 0);
        compare(move(5, "end"), 9);
    }

    function test_tabGoesBySection() {
        compare(move(1, "next"), 3);
        compare(move(4, "next"), 8);
        compare(move(9, "next"), 9, "no next section");
        compare(move(4, "previous"), 3, "the start of its own section first");
        compare(move(3, "previous"), 0);
        compare(move(0, "previous"), 0);
    }

    function test_emptySectionsAreSkipped() {
        compare(Logic.move([2, 0, 2], 2, 0, "down", 2), 2);
        compare(Logic.move([2, 0, 2], 2, 2, "up", 2), 0);
        compare(Logic.move([2, 0, 2], 2, 1, "next", 2), 2);
    }

    function test_keyNames() {
        compare(Logic.keyName(Qt.Key_Left, false), "left");
        compare(Logic.keyName(Qt.Key_Right, false), "right");
        compare(Logic.keyName(Qt.Key_Up, false), "up");
        compare(Logic.keyName(Qt.Key_Down, false), "down");
        compare(Logic.keyName(Qt.Key_PageUp, false), "pageUp");
        compare(Logic.keyName(Qt.Key_PageDown, false), "pageDown");
        compare(Logic.keyName(Qt.Key_Tab, false), "next");
        compare(Logic.keyName(Qt.Key_Tab, true), "previous", "Shift+Tab delivered as Tab with Shift");
        compare(Logic.keyName(Qt.Key_Backtab, true), "previous");
        compare(Logic.keyName(Qt.Key_A, false), "", "typing goes to the field");
        compare(Logic.keyName(Qt.Key_Return, false), "");
        compare(Logic.keyName(Qt.Key_Home, false), "", "Home and End stay the field's");
    }

    // ---- Where it opens (ES-1) ----

    function test_cursorPosition() {
        compare(Logic.cursorPosition("{\"x\": 2100.5, \"y\": 40}"), {x: 2100.5, y: 40});
        compare(Logic.cursorPosition(""), null);
        compare(Logic.cursorPosition("{\"x\": 1}"), null);
        compare(Logic.cursorPosition("{\"x\": \"1\", \"y\": 2}"), null);
        compare(Logic.cursorPosition("invalid"), null);
    }

    function test_theOutputUnderThePointer() {
        const screens = [{name: "eDP-1", x: 0, y: 0, width: 1536, height: 960}, {name: "DP-2", x: 1536, y: -200, width: 2560, height: 1440}];
        compare(Logic.pointerOn(screens, 2000, 100), {name: "DP-2", x: 464, y: 300});
        compare(Logic.pointerOn(screens, 1535.5, 959), {name: "eDP-1", x: 1535.5, y: 959});
        compare(Logic.pointerOn(screens, 100, 960), null, "below the laptop's output, outside every output");
        compare(Logic.pointerOn(screens, -1, 10), null);
        compare(Logic.pointerOn([], 0, 0), null);
    }

    // ---- Insertion (ES-7) ----

    function state(over) {
        return Object.assign({locked: false, rememberedAddress: "0x55aa10", activeAddress: "55aa10", closedSinceOpen: false,
            otherSurfaceOpen: false, expired: false}, over || {});
    }

    function test_insertWaitsForTheWindow() {
        compare(Logic.insertStep(state()), "send", "with or without 0x, the same window");
        compare(Logic.insertStep(state({activeAddress: ""})), "wait", "the overlay still has the keyboard");
        compare(Logic.insertStep(state({activeAddress: "77bb20"})), "wait");
        compare(Logic.insertStep(state({activeAddress: "", expired: true})), "the window did not come back");
    }

    function test_insertIsDroppedWhenItCannotGoThere() {
        compare(Logic.insertStep(state({locked: true})), "locked");
        compare(Logic.insertStep(state({locked: undefined})), "locked", "an unknown lock state is locked");
        compare(Logic.insertStep(null), "locked");
        compare(Logic.insertStep(state({rememberedAddress: ""})), "no window");
        compare(Logic.insertStep(state({rememberedAddress: "not an address"})), "no window");
        compare(Logic.insertStep(state({closedSinceOpen: true})), "the window closed", "even when an address is active again");
        compare(Logic.insertStep(state({otherSurfaceOpen: true})), "another surface opened");
    }

    function test_insertCommandIsAnArgumentVector() {
        const script = "/usr/share/grassfield/shell/services/emoji-insert.sh";
        const path = "/usr/share/omarchy/bin/omarchy-menu-emoji-insert";
        compare(Logic.insertCommand("\u{1F44B}", path, script), ["sh", script, "\u{1F44B}", path]);
        compare(Logic.insertCommand("$(reboot)", path, script), ["sh", script, "$(reboot)", path], "an argument, never a command line");
        compare(Logic.insertCommand("a\nb", path, script), [], "a refused glyph runs nothing");
        compare(Logic.insertCommand("-n", path, script), [], "nothing that reads as an option");
        compare(Logic.insertCommand("", path, script), []);
    }

    function test_omarchyPath() {
        compare(Logic.omarchyPath(""), "/usr/share/omarchy");
        compare(Logic.omarchyPath(undefined), "/usr/share/omarchy");
        compare(Logic.omarchyPath("relative/omarchy"), "/usr/share/omarchy", "a relative path is not trusted");
        compare(Logic.omarchyPath("/opt/omarchy/"), "/opt/omarchy");
        compare(Logic.omarchyPath("/opt/x\ny"), "/usr/share/omarchy");
    }
}
