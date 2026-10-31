import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Settings' finish (ADR-0039 step 15, audit §4.2): the (i) and (…) buttons take ToolButton's hover and pressed states; one
// empty-list style (centred, secondary, inside the group); ErrorNote in the window's secondary colour; the colour well's hex
// field is the shared TextField and its popover the menus' glass; the glass preview draws the glass controls' class tint and
// turns opaque under Reduce Transparency. The toolbar's rule is tst_settingsmain (it needs the window).
TestCase {
    id: tc

    name: "SettingsFinish"
    width: 400
    height: 300
    visible: true
    when: windowShown

    Column {
        spacing: 10

        SettingsQml.InfoButton {
            id: info
            accessibleName: "Details"
        }

        SettingsQml.MoreButton {
            id: more
            accessibleName: "More"
            items: [{id: "a", text: "A"}]
        }

        SettingsQml.EmptyListRow {
            id: empty
            width: 300
            text: "No printers"
        }

        SettingsQml.ColorWell {
            id: well
            accessibleName: "Colour"
            color: "#e5484d"
        }

        SettingsQml.GlassPreview {
            id: preview
        }
    }

    property bool wasReduced: false

    function initTestCase() {
        tc.wasReduced = Appearance.reduceTransparency;
    }

    function cleanup() {
        Appearance.reduceTransparency = tc.wasReduced;
        mouseMove(tc, tc.width - 2, tc.height - 2);
    }

    function find(root, test) {
        const stack = [root];
        while (stack.length > 0) {
            const it = stack.shift();
            if (test(it))
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // The round fill behind a button's glyph.
    function stateFill(button) {
        return find(button, it => it !== button && String(it).indexOf("QQuickRectangle") === 0 && it.radius === button.width / 2
                    && it.width === button.width);
    }

    function test_theRowButtonsHaveToolButtonsStates_data() {
        return [{tag: "(i)", button: info}, {tag: "(…)", button: more}];
    }

    function test_theRowButtonsHaveToolButtonsStates(data) {
        const fill = stateFill(data.button);
        verify(fill !== null, "a state fill behind the glyph");
        verify(!fill.visible, "at rest: none");
        mouseMove(data.button, data.button.width / 2, data.button.height / 2);
        tryVerify(() => fill.visible, 1000, "hovered: the hover fill");
        verify(Qt.colorEqual(fill.color, Appearance.withAlpha(Appearance.colors.hover, Tokens.materialHoverOpacity)));
        mousePress(data.button, data.button.width / 2, data.button.height / 2);
        verify(Qt.colorEqual(fill.color, Appearance.withAlpha(Appearance.colors.hover, Tokens.controlPressedOpacity)), "pressed: the pressed fill");
        mouseRelease(data.button, data.button.width / 2, data.button.height / 2);
        keyClick(Qt.Key_Escape);
    }

    function test_anEmptyListSaysSoCentredAndSecondary() {
        const label = find(empty, it => String(it).indexOf("QQuickText") === 0 && it.text === "No printers");
        verify(label !== null);
        compare(empty.height, Tokens.settingsEmptyListHeight);
        verify(Math.abs(label.mapToItem(empty, label.width / 2, 0).x - empty.width / 2) < 1, "centred");
        verify(Qt.colorEqual(label.color, Appearance.windowSecondary), "in the window's secondary colour");
        compare(empty.Accessible.role, Accessible.StaticText);
    }

    function test_theColourWellsFieldAndPopover() {
        const field = well.hexInput;
        verify(field.fieldRadius !== undefined && field.placeholderText !== undefined, "the hex field is the shared TextField");
        compare(field.accessibleName, "Colour (#rrggbb)");
        // The popover sits on a window-sized layer over the page (the window's content item).
        verify(find(well.Window.contentItem, it => it.glassClass === "menu") !== null, "the popover is on the menus' glass (Material)");
    }

    function test_theGlassPreviewDrawsTheControlsClass() {
        Appearance.reduceTransparency = false;
        compare(preview.tint, Appearance.glassAlphaOver("controls", preview.transparency, null), "the glass controls' class tint");
        Appearance.reduceTransparency = true;
        compare(preview.tint, Appearance.glassAlphaOver("controls", 0, null), "Reduce Transparency: the opaque glass");
        verify(preview.tint >= Appearance.glassAlphaOver("controls", preview.transparency, null) - 1e-9, "never clearer");
    }

    function test_errorNoteIsInTheWindowsSecondary() {
        const component = Qt.createComponent(Qt.resolvedUrl("../../apps/settings/qml/ErrorNote.qml"));
        compare(component.status, Component.Ready, component.errorString());
        const note = createTemporaryObject(component, tc, {system: {errors: {"x": "-"}}, tag: "x"});
        verify(note !== null);
        verify(note.visible, "a failed action shows its line");
        verify(Qt.colorEqual(note.color, Appearance.windowSecondary));
    }
}
