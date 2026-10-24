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

    // AppKit: a field that becomes hidden or disabled while it is being edited resigns first responder, and ending the edit
    // commits it as on Tab or a click elsewhere; the keyboard is never trapped (Tab, Backtab and Escape always propagate).
    property int escapes: 0
    property int accepted: 0

    FocusScope {
        id: dialog

        y: 150
        width: 300
        height: 140
        Keys.onEscapePressed: tc.escapes++

        Column {
            Button {
                id: before
                text: "Before"
            }

            SpinBox {
                id: dSpin
                from: 0
                to: 100
                value: 10
                accessibleName: "Dialog count"
                onValueModified: tc.modified++
            }

            TextField {
                id: dField
                accessibleName: "Dialog name"
                onAccepted: tc.accepted++
            }

            Button {
                id: after
                text: "After"
            }
        }
    }

    function dReset() {
        dSpin.visible = true;
        dSpin.enabled = true;
        dField.visible = true;
        dField.enabled = true;
        dSpin.value = 10;
        dField.text = "";
        tc.modified = 0;
        tc.escapes = 0;
        tc.accepted = 0;
        before.forceActiveFocus();
    }

    function dInput(): TextInput {
        return dSpin.contentItem as TextInput;
    }

    function test_accessibilityIncreaseNeedsAShownEnabledSpinBox() {
        dReset();
        dSpin.Accessible.increaseAction();
        compare(dSpin.value, 11);
        compare(tc.modified, 1);
        dSpin.Accessible.decreaseAction();
        compare(dSpin.value, 10);
        tc.modified = 0;
        for (const state of ["disabled", "hidden"]) {
            if (state === "disabled")
                dSpin.enabled = false;
            else
                dSpin.visible = false;
            dSpin.Accessible.increaseAction();
            dSpin.Accessible.decreaseAction();
            compare(dSpin.value, 10, state + ": no change on an accessibility increase or decrease");
            compare(tc.modified, 0, state + ": nothing reported");
            dSpin.enabled = true;
            dSpin.visible = true;
        }
        verify(dInput().readOnly === false);
        dSpin.enabled = false;
        verify(dInput().readOnly, "the field of a disabled spin box is read-only (an accessibility insert is refused)");
        dSpin.enabled = true;
    }

    // Hidden in the middle of an edit: the focus goes on (to the next control, through FocusGuard) and the edit commits.
    function test_hidingASpinBoxMidEditHandsTheFocusOnAndCommits() {
        dReset();
        dInput().forceActiveFocus(Qt.TabFocusReason);
        dInput().selectAll();
        keyClick("5");
        compare(dInput().text, "5");
        dSpin.visible = false;
        verify(!dInput().activeFocus, "the focus left the hidden spin box");
        compare(Window.activeFocusItem === after || Window.activeFocusItem === dField, true, "and went to the next control, not to the enclosing scope");
        compare(dSpin.value, 5, "the edit committed, as on any focus-out");
    }

    function test_disablingASpinBoxMidEditHandsTheFocusToTheNextControl() {
        dReset();
        dInput().forceActiveFocus(Qt.TabFocusReason);
        dInput().selectAll();
        keyClick("6");
        dSpin.enabled = false;
        verify(!dInput().activeFocus);
        verify(Window.activeFocusItem === after || Window.activeFocusItem === dField, "the next control has the focus, not the dialog scope: " + Window.activeFocusItem);
        compare(dSpin.value, 6, "the edit committed");
    }

    // Focused by code while hidden: no input, but never a trap: Tab, Backtab and Escape propagate.
    function test_aHiddenSpinBoxOrFieldGivenTheFocusByCodeTrapsNothing() {
        for (const kind of ["spin", "field"]) {
            dReset();
            const target = kind === "spin" ? dInput() : dField;
            if (kind === "spin")
                dSpin.visible = false;
            else
                dField.visible = false;
            target.forceActiveFocus(Qt.TabFocusReason);
            keyClick("9");
            keyClick(Qt.Key_Return);
            keyClick(Qt.Key_Up);
            keyClick(Qt.Key_PageUp);
            compare(dSpin.value, 10, kind + ": no value change");
            compare(dField.text, "", kind + ": no text typed");
            compare(tc.accepted, 0, kind + ": Return did not accept");
            compare(tc.modified, 0, kind + ": nothing reported");
            keyClick(Qt.Key_Escape);
            compare(tc.escapes, 1, kind + ": Escape reached the dialog");
            keyClick(Qt.Key_Tab);
            verify(!target.activeFocus, kind + ": Tab moved the focus on");
            target.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Backtab);
            verify(!target.activeFocus, kind + ": Backtab moved the focus on");
            dReset();
        }
    }

    // A Return that was pressed while the spin box was shown and released after it was hidden commits nothing more: the
    // release of a swallowed key does nothing.
    function test_theReleaseOfAReturnOnAHiddenSpinBoxCommitsNothing() {
        dReset();
        dSpin.visible = false;
        dInput().forceActiveFocus(Qt.TabFocusReason);
        dInput().text = "9";   // typed earlier, never committed
        keyClick(Qt.Key_Return);
        compare(dSpin.value, 10, "neither the press nor the release of Return committed the 9");
        compare(tc.modified, 0);
        dSpin.visible = true;
    }

    function test_hiddenTextFieldTakesNoInputAndDisabledNeither() {
        dReset();
        dField.text = "abc";
        dField.visible = false;
        dField.forceActiveFocus(Qt.TabFocusReason);
        keyClick("d");
        keyClick(Qt.Key_Backspace);
        compare(dField.text, "abc", "a hidden field handed the focus ignores typing");
        verify(dField.readOnly, "and is read-only for the accessibility insert");
        dField.visible = true;
        dField.enabled = false;
        keyClick("e");
        compare(dField.text, "abc", "so does a disabled one");
        dField.enabled = true;
        verify(!dField.readOnly);
    }

    function test_spinBoxStaysInRange() {
        spin.value = 100;
        spin.forceActiveFocus();
        keyClick(Qt.Key_Up);
        compare(spin.value, 100);
    }
}
