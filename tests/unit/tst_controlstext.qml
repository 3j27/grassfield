import QtQuick
import QtTest
import Grassfield.Ui

// The text controls of Grassfield.Ui on QtQuick.Templates (GF-085): TextField, SearchField, SpinBox.
TestCase {
    id: tc

    name: "ControlsText"
    width: 400
    height: 300
    visible: true
    when: windowShown

    property int clearedCount: 0
    property int modified: 0

    Column {
        spacing: 8

        TextField {
            id: field
            accessibleName: "Name"
            placeholderText: "Type"
        }

        SearchField {
            id: search
            accessibleName: "Find"
            onCleared: tc.clearedCount++
        }

        SpinBox {
            id: spin
            from: 0
            to: 100
            value: 10
            stepSize: 1
            accessibleName: "Count"
            onValueModified: tc.modified++
        }
    }

    function init() {
        tc.clearedCount = 0;
        tc.modified = 0;
        field.text = "";
        search.text = "";
        spin.value = 10;
    }

    function test_fieldTypesAndHasTheFieldHeight() {
        compare(field.height, Tokens.controlFieldHeight);
        mouseClick(field);
        verify(field.activeFocus);
        keyClick("a");
        keyClick("b");
        compare(field.text, "ab");
        compare(field.Accessible.name, "Name");
        compare(field.Accessible.role, Accessible.EditableText);
    }

    function test_fieldNameFallsBackToThePlaceholder() {
        field.accessibleName = "";
        compare(field.Accessible.name, "Type");
        field.accessibleName = "Name";
    }

    function test_fieldShowsTheRingWhileFocused() {
        field.forceActiveFocus();
        const ring = field.background.children[0];
        verify(ring.visible);
        compare(ring.border.width, Tokens.controlFocusOutline);
        search.forceActiveFocus();
        verify(!ring.visible);
    }

    function test_fieldHonoursIncreaseContrast() {
        Appearance.increaseContrast = false;
        compare((field.background as Rectangle).border.width, 0);
        Appearance.increaseContrast = true;
        compare((field.background as Rectangle).border.width, 1);
        Appearance.increaseContrast = false;
    }

    function test_searchEscapeClearsFirstThenPropagates() {
        search.forceActiveFocus();
        keyClick("x");
        compare(search.text, "x");
        keyClick(Qt.Key_Escape);
        compare(search.text, "");
        compare(tc.clearedCount, 1);
        compare(search.Accessible.searchEdit, true);
        keyClick(Qt.Key_Escape);
        compare(tc.clearedCount, 1, "a second Escape finds nothing to clear");
    }

    function test_searchClearButtonClears() {
        search.text = "abc";
        let btn = null;
        for (let i = 0; i < search.children.length; i++) {
            if (search.children[i].objectName === "clearButton")
                btn = search.children[i];
        }
        verify(btn !== null);
        verify(btn.visible);
        btn.clicked();
        compare(search.text, "");
        compare(tc.clearedCount, 1);
    }

    function test_spinBoxStepsWithArrowsAndPages() {
        spin.forceActiveFocus();
        keyClick(Qt.Key_Up);
        compare(spin.value, 11);
        keyClick(Qt.Key_Down);
        keyClick(Qt.Key_Down);
        compare(spin.value, 9);
        keyClick(Qt.Key_PageUp);
        compare(spin.value, 19);
        keyClick(Qt.Key_PageDown);
        keyClick(Qt.Key_PageDown);
        compare(spin.value, 0, "clamped at from");
        verify(tc.modified >= 4);
        compare(spin.Accessible.name, "Count");
    }

    // A hidden or disabled spin box never takes input: not from the assistive technology, not from keys handed to it by code.
    function test_hiddenOrDisabledSpinBoxTakesNoInput() {
        spin.Accessible.increaseAction();
        compare(spin.value, 11, "an enabled one increases on an accessibility increase");
        compare(tc.modified, 1, "and reports it");
        spin.Accessible.decreaseAction();
        compare(spin.value, 10);
        tc.modified = 0;
        for (const state of ["disabled", "hidden"]) {
            if (state === "disabled")
                spin.enabled = false;
            else
                spin.visible = false;
            spin.Accessible.increaseAction();
            spin.Accessible.decreaseAction();
            compare(spin.value, 10, state + ": no change on an accessibility increase or decrease");
            compare(tc.modified, 0, state + ": nothing reported");
            if (state === "hidden") {
                spin.contentItem.forceActiveFocus(Qt.TabFocusReason);
                keyClick("5");
                keyClick(Qt.Key_Return);
                keyClick(Qt.Key_Up);
                compare(spin.value, 10, "a hidden spin box handed the focus ignores typing and Return");
                compare(spin.contentItem.text, "10");
            }
            spin.enabled = true;
            spin.visible = true;
        }
    }

    // Hiding a spin box in the middle of an edit keeps the typed text and commits nothing; an explicit Return commits it.
    function test_hidingASpinBoxMidEditKeepsTheEditUncommitted() {
        spin.contentItem.forceActiveFocus(Qt.TabFocusReason);
        spin.contentItem.selectAll();
        keyClick("5");
        compare(spin.contentItem.text, "5");
        spin.visible = false;
        compare(spin.value, 10, "hiding did not commit the edit");
        compare(spin.contentItem.text, "5", "and kept it as typed");
        keyClick("7");
        compare(spin.contentItem.text, "5", "a hidden spin box takes no more input");
        spin.visible = true;
        compare(spin.value, 10, "showing it again commits nothing either");
        keyClick(Qt.Key_Return);
        compare(spin.value, 5, "an explicit Return commits");
    }

    function test_hiddenTextFieldTakesNoInput() {
        field.text = "abc";
        field.visible = false;
        field.forceActiveFocus(Qt.TabFocusReason);
        keyClick("d");
        keyClick(Qt.Key_Backspace);
        compare(field.text, "abc", "a hidden field handed the focus ignores typing");
        field.visible = true;
        field.enabled = false;
        keyClick("e");
        compare(field.text, "abc", "so does a disabled one");
        field.enabled = true;
    }

    function test_spinBoxStaysInRange() {
        spin.value = 100;
        spin.forceActiveFocus();
        keyClick(Qt.Key_Up);
        compare(spin.value, 100);
    }
}
