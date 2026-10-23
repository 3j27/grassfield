import QtQuick
import QtTest
import Grassfield.Ui
import "../../shell/overlay/controlcenter/Model.js" as Model

// Auto appearance (REQ-QS-CC8): the fixed local schedule, dark from the token hour to the token hour.
TestCase {
    name: "AutoAppearance"

    function at(h, m) {
        return new Date(2026, 9, 23, h, m, 0);
    }

    function dark(setting, h, m) {
        return AutoAppearance.isDark(setting, at(h, m), Tokens.autoAppearanceDarkFromHour, Tokens.autoAppearanceDarkToHour);
    }

    function test_tokensAreTheDocumentedSchedule() {
        compare(Tokens.autoAppearanceDarkFromHour, 19);
        compare(Tokens.autoAppearanceDarkToHour, 7);
    }

    function test_lightAndDarkIgnoreTheClock() {
        verify(!dark("light", 23, 0));
        verify(dark("dark", 12, 0));
        verify(dark("bogus", 12, 0));
    }

    function test_autoFollowsTheSchedule() {
        verify(!dark("auto", 12, 0));
        verify(!dark("auto", 7, 0));
        verify(!dark("auto", 18, 59));
        verify(dark("auto", 19, 0));
        verify(dark("auto", 23, 59));
        verify(dark("auto", 0, 0));
        verify(dark("auto", 6, 59));
    }

    function test_nonWrappingWindowAndEmptyWindow() {
        verify(AutoAppearance.nightAt(at(3, 0), 0, 6));
        verify(!AutoAppearance.nightAt(at(12, 0), 0, 6));
        verify(!AutoAppearance.nightAt(at(3, 0), 5, 5));
    }

    function test_label() {
        const l = {light: "L", dark: "D", auto: "A"};
        compare(Model.appearanceLabel("light", l), "L");
        compare(Model.appearanceLabel("auto", l), "A");
        compare(Model.appearanceLabel("x", l), "D");
    }
}
