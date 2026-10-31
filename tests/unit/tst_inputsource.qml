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
}
