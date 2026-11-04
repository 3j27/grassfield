import QtQuick
import QtTest
import "../../shell/platform/InputSource.js" as InputSource

// Input source HUD logic (the layout change events of the compositor).
TestCase {
    name: "InputSource"

    function test_parse() {
        compare(InputSource.parse("at-translated-set-2-keyboard,English (US)"), {keyboard: "at-translated-set-2-keyboard", layout: "English (US)"});
        compare(InputSource.parse("kb,French, with dead keys").layout, "French, with dead keys");
        compare(InputSource.parse(""), null);
        compare(InputSource.parse("nocomma"), null);
        compare(InputSource.parse(",x"), null);
        compare(InputSource.parse("x,"), null);
        compare(InputSource.parse(undefined), null);
        compare(InputSource.parse("k," + "a".repeat(200)), null);
    }

    function test_firstLayoutIsRememberedWithoutAHud() {
        const r = InputSource.step({last: {}}, {keyboard: "k", layout: "English (US)"});
        verify(!r.show);
        compare(r.state.last.k, "English (US)");
    }

    function test_aSingleLayoutNeverShows() {
        let s = {last: {}};
        for (let i = 0; i < 4; i++) {
            const r = InputSource.step(s, {keyboard: "k", layout: "English (US)"});
            verify(!r.show);
            s = r.state;
        }
    }

    function test_aChangeShows() {
        const s = InputSource.step({last: {}}, {keyboard: "k", layout: "English (US)"}).state;
        let r = InputSource.step(s, {keyboard: "k", layout: "French"});
        verify(r.show);
        r = InputSource.step(r.state, {keyboard: "k", layout: "English (US)"});
        verify(r.show);
    }

    function test_keyboardsAreIndependent() {
        const s = InputSource.step({last: {}}, {keyboard: "a", layout: "English (US)"}).state;
        const r = InputSource.step(s, {keyboard: "b", layout: "French"});
        verify(!r.show);
    }

    // Capture defect 3: a virtual keyboard with its own keymap (wtype) is reported by Hyprland with the layout "error".
    function test_aVirtualKeyboardsErrorIsNeverShown() {
        let s = InputSource.step({last: {}}, {keyboard: "kbd0", layout: "English (US)"}).state;
        for (const word of ["error", "Error", " ERROR ", "unknown", "(unknown)", "none"]) {
            const r = InputSource.step(s, {keyboard: "wtype", layout: word});
            verify(!r.show, word);
            compare(r.state.last.wtype, undefined);
            s = r.state;
        }
        // Whichever way the virtual keyboard comes and goes, the main keyboard's layout is the one that counts.
        let r = InputSource.step(s, {keyboard: "wtype", layout: "error"});
        verify(!r.show);
        r = InputSource.step(r.state, {keyboard: "kbd0", layout: "French"});
        verify(r.show);
    }

    function test_aVirtualKeyboardThatHasNamesStillFollowsTheRule() {
        // Named layouts are real: the change rule applies to them like to any keyboard.
        let s = InputSource.step({last: {}}, {keyboard: "v", layout: "English (US)"}).state;
        verify(InputSource.step(s, {keyboard: "v", layout: "French"}).show);
        verify(InputSource.named("English (US)"));
        verify(!InputSource.named(""));
        verify(!InputSource.named(undefined));
    }

    // Capture defect 10: the name is shown in the shell's language through the xkeyboard-config catalog (layout-names.py).
    function test_lookupIsNeededOutsideEnglish() {
        verify(!InputSource.needsLookup("en"));
        verify(!InputSource.needsLookup("en_US"));
        verify(!InputSource.needsLookup("en-GB.UTF-8"));
        verify(!InputSource.needsLookup(""));
        verify(!InputSource.needsLookup(undefined));
        verify(InputSource.needsLookup("fr"));
        verify(InputSource.needsLookup("fr_FR"));
        verify(InputSource.needsLookup("de_DE.UTF-8"));
        verify(InputSource.needsLookup("eng_X"), "a language that only starts with en");
    }

    function test_lookupResultFallsBackToEnglish() {
        compare(InputSource.lookupResult("Anglais (US)\n", "English (US)"), "Anglais (US)");
        compare(InputSource.lookupResult("", "English (US)"), "English (US)");
        compare(InputSource.lookupResult("\n", "English (US)"), "English (US)");
        compare(InputSource.lookupResult(undefined, "German"), "German");
        compare(InputSource.lookupResult("x".repeat(200), "German"), "German");
        compare(InputSource.lookupResult("Allemand\nignored", "German"), "Allemand");
    }

    function test_stepDoesNotModifyItsInput() {
        const s = {last: {k: "x"}};
        InputSource.step(s, {keyboard: "k", layout: "y"});
        compare(s.last.k, "x");
        compare(InputSource.step(null, {keyboard: "k", layout: "y"}).show, false);
    }
    // ---- Input sources (the Input menu) ----

    readonly property string baseLst: "! model\n  pc105  Generic 105-key PC\n\n! layout\n  fr  French\n  us  English (US)\n  ru  Russian\n\n! variant\n  bepo  fr: French (BEPO)\n  intl  us: English (US, intl., with dead keys)\n\n! option\n  grp  Switching to another layout\n"

    function test_sourcesSplitTheLayoutsString() {
        compare(InputSource.sources("fr,us", ",").map(s => s.layout + "/" + s.variant), ["fr/", "us/"]);
        compare(InputSource.sources("us,fr", ",bepo").map(s => s.layout + "/" + s.variant), ["us/", "fr/bepo"]);
        compare(InputSource.sources("us", "").length, 1);
        // A variant list of another length, or a bad field, drops the variants it cannot place, never the layouts.
        compare(InputSource.sources("fr,us", "").map(s => s.variant), ["", ""]);
        compare(InputSource.sources("fr,us", "bepo").map(s => s.variant), ["bepo", ""]);
        compare(InputSource.sources("fr,us", "B@D,").map(s => s.variant), ["", ""]);
        // Not xkb codes: left out. At most four (xkb has four groups).
        compare(InputSource.sources("fr,;rm,us", "").map(s => s.layout), ["fr", "us"]);
        compare(InputSource.sources("a,b,c,d,e", "").length, 4);
        compare(InputSource.sources("", "").length, 0);
        compare(InputSource.sources(undefined, undefined).length, 0);
    }

    function test_devicesGiveTheMainKeyboardsSources() {
        const reply = JSON.stringify({keyboards: [
            {name: "power-button", layout: "us", variant: "", main: false},
            {name: "kbd-a", layout: "us", variant: "", main: false},
            {name: "kbd-b", layout: "fr,us", variant: "bepo,", main: true}]});
        compare(InputSource.parseDevices(reply).map(s => s.layout + "/" + s.variant), ["fr/bepo", "us/"]);
        // No main flag: the first keyboard that is typed on (a button or a virtual keyboard is not one).
        const none = JSON.stringify({keyboards: [{name: "hl-virtual-keyboard", layout: "us", variant: ""}, {name: "k", layout: "fr,us", variant: ","}]});
        compare(InputSource.parseDevices(none).map(s => s.layout), ["fr", "us"]);
        compare(InputSource.parseDevices("not json"), []);
        compare(InputSource.parseDevices("{}"), []);
        compare(InputSource.parseDevices(JSON.stringify({keyboards: [{name: "lid-switch", layout: "us"}]})), []);
        compare(InputSource.parseDevices(undefined), []);
    }

    function test_devicesGiveTheActiveKeymapOfThatKeyboard() {
        const reply = JSON.stringify({keyboards: [
            {name: "kbd-a", layout: "us", variant: "", active_keymap: "English (US)", main: false},
            {name: "kbd-b", layout: "us,fr", variant: ",", active_keymap: "French", main: true}]});
        compare(InputSource.parseActive(reply), "French");
        compare(InputSource.parseActive(JSON.stringify({keyboards: [{name: "k", layout: "us", active_keymap: "error"}]})), "");
        compare(InputSource.parseActive(JSON.stringify({keyboards: [{name: "k", layout: "us"}]})), "");
        compare(InputSource.parseActive("not json"), "");
        compare(InputSource.parseActive(undefined), "");
    }

    function test_namesAndLabels() {
        const names = InputSource.parseNames(baseLst);
        compare(names.fr, "French");
        compare(names["fr:bepo"], "French (BEPO)");
        compare(names.pc105, undefined);
        compare(InputSource.sourceName({layout: "fr", variant: ""}, names), "French");
        compare(InputSource.sourceName({layout: "fr", variant: "bepo"}, names), "French (BEPO)");
        compare(InputSource.sourceName({layout: "zz", variant: ""}, names), "zz");
        compare(InputSource.sourceName({layout: "zz", variant: "q"}, {}), "zz:q");
        const list = InputSource.sources("fr,us", ",");
        compare(InputSource.label(list[0], list), "FR");
        compare(InputSource.label(list[1], list), "US");
        // Two sources of one layout never show the same label.
        const twins = InputSource.sources("fr,fr", ",bepo");
        compare(InputSource.label(twins[0], twins), "FR");
        compare(InputSource.label(twins[1], twins), "FR bepo");
    }

    function test_theActiveSourceFollowsTheCompositorsName() {
        const names = InputSource.parseNames(baseLst);
        const list = InputSource.sources("fr,us", ",");
        compare(InputSource.activeIndex(list, names, "French", -1), 0);
        compare(InputSource.activeIndex(list, names, "English (US)", 0), 1);
        // A name that matches nothing leaves the position (a keyboard with its own keymap), and none known is the first.
        compare(InputSource.activeIndex(list, names, "Klingon", 1), 1);
        compare(InputSource.activeIndex(list, names, "Klingon", -1), 0);
        compare(InputSource.activeIndex(list, names, "", 1), 1);
        compare(InputSource.activeIndex([], names, "French", 3), 0);
        // xkb's own name of a variant differs from base.lst's: matched on the words before the parenthesis.
        const intl = InputSource.sources("fr,us", ",intl");
        compare(InputSource.activeIndex(intl, names, "English (US, intl., AltGr dead keys)", 0), 1);
        // Two sources of one layout: the one that is not the known position.
        const twins = InputSource.sources("fr,fr", ",bepo");
        compare(InputSource.activeIndex(twins, names, "French (Bepo)", 0), 1);
    }

    function test_nextAndPreviousGoAround() {
        compare(InputSource.stepIndex(0, 2, 1), 1);
        compare(InputSource.stepIndex(1, 2, 1), 0);
        compare(InputSource.stepIndex(0, 2, -1), 1);
        compare(InputSource.stepIndex(0, 3, -1), 2);
        compare(InputSource.stepIndex(2, 3, 1), 0);
        compare(InputSource.stepIndex(1, 3, -1), 0);
        compare(InputSource.stepIndex(0, 0, 1), 0);
    }

    function test_theSwitchRequestNamesEveryKeyboard() {
        compare(InputSource.switchRequest(1, 2), "switchxkblayout all 1");
        compare(InputSource.switchRequest(0, 4), "switchxkblayout all 0");
        compare(InputSource.switchRequest(2, 2), null);
        compare(InputSource.switchRequest(-1, 2), null);
        compare(InputSource.switchRequest(1.5, 2), null);
        compare(InputSource.switchRequest("1", 2), null);
    }

    function test_theInputMenuShowsFromTwoSources() {
        verify(!InputSource.menuShown(0, true));
        verify(!InputSource.menuShown(1, true));
        verify(InputSource.menuShown(2, true));
        verify(InputSource.menuShown(4, undefined));
        verify(!InputSource.menuShown(2, false));
    }
}
