import QtQuick
import QtTest
import "../../shell/services/MediaLogic.js" as Logic

// Opening the app that plays from the Now Playing artwork and title (macOS model).
TestCase {
    name: "MediaLogic"

    function test_raiseWhenThePlayerCan() {
        compare(Logic.openPlan(true, true, []), "raise");
        compare(Logic.openPlan(true, false, [{minimized: false}]), "raise");
        compare(Logic.openPlan(true, true, [{minimized: false}, {minimized: true}]), "raise");
    }

    function test_minimizedAppComesBackFirst() {
        compare(Logic.openPlan(true, true, [{minimized: true}]), "activate");
        compare(Logic.openPlan(false, true, [{minimized: true}, {minimized: true}]), "activate");
    }

    function test_noRaiseUsesTheWindowThenTheEntry() {
        compare(Logic.openPlan(false, true, [{minimized: false}]), "activate");
        compare(Logic.openPlan(false, true, []), "launch");
        compare(Logic.openPlan(false, true, undefined), "launch");
    }

    function test_nothingToOpen() {
        compare(Logic.openPlan(false, false, []), "none");
    }

    // From an overlay panel the click's focus is final: the close that follows must not return it to the previous window.
    function test_overlayChoiceSkipsTheFocusReturn() {
        compare(Logic.skipsFocusReturn(true, "raise"), true);
        compare(Logic.skipsFocusReturn(true, "activate"), true);
        compare(Logic.skipsFocusReturn(true, "launch"), false);
        compare(Logic.skipsFocusReturn(true, "none"), false);
        compare(Logic.skipsFocusReturn(false, "raise"), false);
        compare(Logic.skipsFocusReturn(undefined, "activate"), false);
    }

    function test_appIdStripsTheSuffix() {
        compare(Logic.appIdOf("org.gnome.Lollypop.desktop"), "org.gnome.Lollypop");
        compare(Logic.appIdOf("spotify"), "spotify");
        compare(Logic.appIdOf(undefined), "");
    }
}
