import QtQuick
import QtTest
import "../../shell/platform/ScreenChoice.js" as ScreenChoice

// The output a screen-less request opens on: the focused one, the first only as a last resort.
TestCase {
    id: testCase
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

    function test_replacementIsComputedFromTheLiveNames() {
        compare(ScreenChoice.replacement("GF-SD2", "OUT", ["OUT"]), "OUT");
        compare(ScreenChoice.replacement("GF-SD2", "GF-SD2", ["A", "B"]), "A", "a focus that is gone too falls to the first");
        compare(ScreenChoice.replacement("GF-SD2", "B", ["A", "B"]), "B", "the focused output wins over the first");
        compare(ScreenChoice.replacement("A", "B", ["A", "B"]), "A", "a screen that is still there stays");
        compare(ScreenChoice.replacement("", "B", ["A", "B"]), "", "no screen is no state to move");
        compare(ScreenChoice.replacement("GF-SD2", "", []), "");
        compare(ScreenChoice.replacement("GF-SD2", undefined, ["A"]), "A");
    }

    // A handler of "the outputs changed" can read the OLD value of a binding of the same change (Qt does not promise the order):
    // the unplug handlers therefore compute the screen from the live names they are given. This reproduces the ordering.
    QtObject {
        id: outputs
        property var names: ["OUT", "GF-SD2"]
    }

    Component {
        id: bindingComponent
        QtObject {
            property var src
            // like Compositor.activeScreenName: a binding of the same change
            readonly property string active: ScreenChoice.pick("", "GF-SD2", src.names)
        }
    }

    property string stored: "GF-SD2"
    property string viaBinding: ""
    property string viaLive: ""
    property var lateBinding: null

    Connections {
        target: outputs

        function onNamesChanged(): void {
            // the binding object is created later than this handler, as the Compositor singleton is first evaluated after Popups
            testCase.viaBinding = testCase.lateBinding ? testCase.lateBinding.active : "<not created yet>";
            testCase.viaLive = ScreenChoice.replacement(testCase.stored, "GF-SD2", outputs.names);
        }
    }

    function test_theHandlerNeverNeedsTheBinding() {
        lateBinding = bindingComponent.createObject(this, {src: outputs});
        compare(lateBinding.active, "GF-SD2");
        outputs.names = ["OUT"];
        compare(viaLive, "OUT", "computed from the live names: always the live output");
        compare(lateBinding.active, "OUT", "the binding is right afterwards");
        // what a handler reading the binding would have seen (viaBinding) depends on the creation order: none of ours reads it
        console.log("the binding read inside the handler: '" + viaBinding + "'");
    }

    function test_noOutputs() {
        compare(ScreenChoice.pick("", "GF-REF", []), "");
    }
}
