import QtQuick
import QtTest
import "../../shell/platform/ScreenChoice.js" as ScreenChoice

// The output a screen-less request opens on: the focused one, the first only as a last resort.
TestCase {
    name: "ScreenChoice"

    readonly property var names: ["WAYLAND-1", "GF-REF"]

    function test_focusedOutputWinsOverTheFirst() {
        compare(ScreenChoice.pick("", "GF-REF", names), "GF-REF");
    }

    function test_aNamedOutputThatExistsWins() {
        compare(ScreenChoice.pick("WAYLAND-1", "GF-REF", names), "WAYLAND-1");
    }

    function test_unknownNamesFallBack() {
        compare(ScreenChoice.pick("HDMI-9", "GF-REF", names), "GF-REF");
        compare(ScreenChoice.pick("", "HDMI-9", names), "WAYLAND-1");
        compare(ScreenChoice.pick("", "", names), "WAYLAND-1");
    }

    function test_centredPopupUsesTheOpenPopupsScreenOnly() {
        compare(ScreenChoice.centered(true, "B", "A"), "B");
        // closed: the old screen is stale, the active display wins
        compare(ScreenChoice.centered(false, "B", "A"), "A");
        compare(ScreenChoice.centered(true, "", "A"), "A");
    }

    function test_theAskingPanelsDisplayWinsForAConfirm() {
        // Search is on B, the pointer-active display is A, a menu was last open on C: the confirm opens on B
        compare(ScreenChoice.centered(false, "C", "A", "B"), "B");
        compare(ScreenChoice.centered(true, "C", "A", "B"), "B");
        compare(ScreenChoice.centered(true, "C", "A", ""), "C");
        compare(ScreenChoice.centered(false, "", "A", undefined), "A");
    }

    // A display unplugged while something was open on it: the owner of the state moves it to the active output.
    function test_goneTellsAnOutputThatWentAway() {
        verify(ScreenChoice.gone("DP-2", ["DP-1"]));
        verify(!ScreenChoice.gone("DP-1", ["DP-1", "DP-2"]));
        verify(!ScreenChoice.gone("", ["DP-1"]), "no name is not a removed output");
        verify(!ScreenChoice.gone(undefined, ["DP-1"]));
        verify(ScreenChoice.gone("DP-1", []), "the last output going away");
        verify(ScreenChoice.gone("DP-1", undefined));
    }

    function test_noOutputs() {
        compare(ScreenChoice.pick("", "GF-REF", []), "");
    }
}
