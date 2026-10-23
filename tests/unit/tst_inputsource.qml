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

    function test_stepDoesNotModifyItsInput() {
        const s = {last: {k: "x"}};
        InputSource.step(s, {keyboard: "k", layout: "y"});
        compare(s.last.k, "x");
        compare(InputSource.step(null, {keyboard: "k", layout: "y"}).show, false);
    }
}
