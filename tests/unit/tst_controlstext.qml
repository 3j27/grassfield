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

    function test_spinBoxStaysInRange() {
        spin.value = 100;
        spin.forceActiveFocus();
        keyClick(Qt.Key_Up);
        compare(spin.value, 100);
    }
}
