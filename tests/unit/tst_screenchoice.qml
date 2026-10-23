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

    function test_noOutputs() {
        compare(ScreenChoice.pick("", "GF-REF", []), "");
    }
}
