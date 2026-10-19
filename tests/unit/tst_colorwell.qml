import QtQuick
import QtTest
import "../../apps/settings/qml"

// Settings colour well: the typed #rrggbb field follows the colour however it changes (swatch, host, typing).
TestCase {
    id: testCase
    name: "ColorWell"
    width: 400
    height: 400
    visible: true
    when: windowShown

    Component {
        id: wellComponent
        ColorWell {
            accessibleName: "Test"
            color: "#e5484d"
            presets: [
                {color: "#00ff00", name: "Green"},
                {color: "#e5484d", name: "Red"}
            ]
        }
    }

    function test_fieldFollowsTheColour() {
        const well = createTemporaryObject(wellComponent, testCase);
        verify(well);
        compare(well.hexInput.text, "#e5484d");
        // Typed hex: applied as it is typed.
        let edited = [];
        well.edited.connect(c => edited.push(c));
        well.hexInput.text = "";
        well.hexInput.insert(0, "#00ff00");
        well.hexInput.textEdited();
        compare(edited[edited.length - 1], "#00ff00");
        compare(well.shown, "#00ff00");
        // The typed text stays as typed while it names the colour.
        compare(well.hexInput.text, "#00ff00");
        // Then a swatch is picked (the host keeps its stored colour #e5484d: the bound colour does not change).
        well.pick("#e5484d", true);
        compare(well.shown, "#e5484d");
        compare(well.hexInput.text, "#e5484d");
        // Another pick, and the field keeps following (the binding is not broken by the earlier assignment).
        well.pick("#336699", true);
        compare(well.hexInput.text, "#336699");
    }

    function test_fieldFollowsTheHost() {
        const well = createTemporaryObject(wellComponent, testCase);
        verify(well);
        well.hexInput.text = "";
        well.hexInput.insert(0, "#00ff00");
        well.hexInput.textEdited();
        compare(well.shown, "#00ff00");
        // The host stores another colour (Reset Colour, the file edited by hand, another window).
        well.color = "#ffffff";
        compare(well.shown, "#ffffff");
        compare(well.hexInput.text, "#ffffff");
        well.color = "#000000";
        compare(well.hexInput.text, "#000000");
    }

    function test_partialTypingIsLeftAlone() {
        const well = createTemporaryObject(wellComponent, testCase);
        verify(well);
        well.hexInput.text = "";
        well.hexInput.insert(0, "#00f");
        well.hexInput.textEdited();
        // Fewer than six digits while typing changes nothing and is not overwritten.
        compare(well.shown, "#e5484d");
        compare(well.hexInput.text, "#00f");
        well.hexInput.text = "#00";
        well.hexInput.textEdited();
        compare(well.shown, "#e5484d");
        compare(well.hexInput.text, "#00");
        // A complete colour typed in the long form is applied.
        well.hexInput.text = "#0000ff";
        well.hexInput.textEdited();
        compare(well.shown, "#0000ff");
    }
}
