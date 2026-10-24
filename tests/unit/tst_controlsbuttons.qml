import QtQuick
import QtTest
import Grassfield.Ui

// The button family of Grassfield.Ui on QtQuick.Templates (GF-085): Button, ToolButton, CheckBox, RadioButton, Switch and
// the host-driven Toggle: pointer, keys, checked state, accessibility role and name, the one focus ring, Increase Contrast.
TestCase {
    id: tc

    name: "ControlsButtons"
    width: 400
    height: 300
    visible: true
    when: windowShown

    property int clicks: 0
    property int toggles: 0
    property int viewKeys: 0

    Column {
        id: host

        spacing: 8

        Button {
            id: button
            text: "Save"
            onClicked: tc.clicks++
        }

        ToolButton {
            id: tool
            accessibleName: "Info"
            onClicked: tc.clicks++
        }

        Row {
            id: group

            ToolButton {
                id: radioA
                radio: true
                checkable: true
                checked: true
                accessibleName: "A"
            }

            ToolButton {
                id: radioB
                radio: true
                checkable: true
                accessibleName: "B"
            }
        }

        ToolButton {
            id: toggleTool
            checkable: true
            accessibleName: "Sidebar"
        }

        Item {
            id: view
            width: 10
            height: 10
            activeFocusOnTab: true
            Keys.onSpacePressed: tc.viewKeys++
        }

        Item {
            id: forwarder
            property var reached: []
            property Item target: null
            width: 10
            height: 10
            Keys.forwardTo: [forwarder.target]
            Keys.onPressed: event => {
                forwarder.reached = forwarder.reached.concat([event.key]);
                event.accepted = true;
            }
        }

        CheckBox {
            id: check
            text: "Remember"
            onToggled: tc.toggles++
        }

        Column {
            RadioButton {
                id: radio1
                text: "One"
                checked: true
            }

            RadioButton {
                id: radio2
                text: "Two"
            }
        }

        Switch {
            id: sw
            accessibleName: "Wi-Fi"
            onToggled: tc.toggles++
        }

        Toggle {
            id: toggle
            accessibleName: "Hosted"
            checked: false
            onToggled: checked => tc.toggles++
        }
    }

    function init() {
        tc.clicks = 0;
        tc.toggles = 0;
        tc.viewKeys = 0;
        Appearance.increaseContrast = false;
        Appearance.reduceMotion = false;
        button.enabled = true;
        tool.enabled = true;
    }

    function test_buttonClickAndKeys() {
        mouseClick(button);
        compare(tc.clicks, 1);
        verify(button.activeFocus, "a click focuses the button");
        keyClick(Qt.Key_Space);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Enter);
        compare(tc.clicks, 4);
    }

    function test_buttonRoleAndName() {
        compare(button.Accessible.role, Accessible.Button);
        compare(button.Accessible.name, "Save");
        compare(tool.Accessible.role, Accessible.Button);
        compare(tool.Accessible.name, "Info");
    }

    function test_disabledButtonDimsOnceAsAWhole() {
        compare(button.opacity, 1);
        button.enabled = false;
        compare(button.opacity, Tokens.materialDisabledOpacity);
        compare(button.contentItem.opacity, 1, "the label is not dimmed a second time");
    }

    function test_disabledButtonNeverActs() {
        button.enabled = false;
        mouseClick(button);
        verify(!button.activate());
        compare(tc.clicks, 0);
    }

    function test_oneFocusRingOfTheTokenWidth() {
        view.forceActiveFocus();
        button.forceActiveFocus(Qt.TabFocusReason);
        let ring = null;
        for (let i = 0; i < button.children.length; i++) {
            if (button.children[i].border !== undefined && button.children[i].border.width === Tokens.controlFocusOutline)
                ring = button.children[i];
        }
        verify(ring !== null, "a ring child of the focus outline width");
        verify(ring.visible);
        compare(ring.border.width, 3);
        compare(ring.anchors.margins, -Tokens.controlFocusOutline);
        tool.forceActiveFocus(Qt.TabFocusReason);
        verify(!ring.visible, "the ring leaves with the focus");
    }

    // The ring is for keyboard focus: a click gives the focus to a button but shows no ring.
    function test_noRingAfterAClick() {
        mouseClick(button);
        verify(button.activeFocus);
        verify(!button.visualFocus);
        let shown = false;
        for (let i = 0; i < button.children.length; i++) {
            if (button.children[i].border !== undefined && button.children[i].border.width === Tokens.controlFocusOutline && button.children[i].visible)
                shown = true;
        }
        verify(!shown, "no ring after a click");
    }

    // macOS toolbar buttons never take the focus on a click: the view they act on keeps it (Space then goes to the view).
    function test_toolButtonClickKeepsTheFocusOnTheView() {
        view.forceActiveFocus();
        mouseClick(tool);
        compare(tc.clicks, 1);
        verify(view.activeFocus, "the view still has the focus");
        verify(!tool.activeFocus);
        keyClick(Qt.Key_Space);
        compare(tc.clicks, 1, "Space does not fire the button again");
        compare(tc.viewKeys, 1);
        // Keyboard navigation reaches it.
        tool.forceActiveFocus(Qt.TabFocusReason);
        verify(tool.visualFocus);
    }

    function test_increaseContrastDrawsABorder() {
        compare((button.background as Rectangle).border.width, 0);
        Appearance.increaseContrast = true;
        compare((button.background as Rectangle).border.width, 1);
    }

    function test_toolButtonReturnClicks() {
        tool.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Space);
        compare(tc.clicks, 2);
        tool.enabled = false;
        verify(!tool.activate());
    }

    function test_radioToolButtonsAreExclusiveAndRoleRadio() {
        compare(radioA.Accessible.role, Accessible.RadioButton);
        compare(toggleTool.Accessible.role, Accessible.CheckBox);
        mouseClick(radioB);
        verify(radioB.checked);
        verify(!radioA.checked);
        mouseClick(radioB);
        verify(radioB.checked, "a checked choice is not unchecked by clicking it");
        mouseClick(toggleTool);
        verify(toggleTool.checked);
        mouseClick(toggleTool);
        verify(!toggleTool.checked, "a toggle flips back");
    }

    function test_checkBoxTogglesWithSpaceAndNotReturn() {
        check.forceActiveFocus();
        keyClick(Qt.Key_Space);
        verify(check.checked);
        compare(tc.toggles, 1);
        keyClick(Qt.Key_Return);
        verify(check.checked, "Return does not toggle");
        mouseClick(check);
        verify(!check.checked);
        compare(check.Accessible.name, "Remember");
        check.tristate = true;
        check.checkState = Qt.PartiallyChecked;
        compare(check.checkState, Qt.PartiallyChecked);
        check.tristate = false;
        check.checked = false;
    }

    function test_radioButtonsAreExclusive() {
        mouseClick(radio2);
        verify(radio2.checked);
        verify(!radio1.checked);
        mouseClick(radio2);
        verify(radio2.checked);
        compare(radio2.Accessible.role, Accessible.RadioButton);
    }

    function test_radioArrowKeysMoveWithinTheGroup() {
        radio1.checked = true;
        radio1.forceActiveFocus(Qt.TabFocusReason);
        keyClick(Qt.Key_Down);
        verify(radio2.checked);
        verify(radio2.activeFocus);
        verify(radio2.visualFocus);
        keyClick(Qt.Key_Down);
        verify(radio2.checked, "no wrap past the last");
        keyClick(Qt.Key_Up);
        verify(radio1.checked);
        verify(radio1.activeFocus);
        keyClick(Qt.Key_Right);
        verify(radio2.checked);
        keyClick(Qt.Key_Left);
        verify(radio1.checked);
    }

    function test_switchTogglesItselfAndToggleLeavesTheValueToTheHost() {
        mouseClick(sw);
        verify(sw.checked);
        compare(tc.toggles, 1);
        compare(sw.Accessible.name, "Wi-Fi");
        toggle.forceActiveFocus();
        keyClick(Qt.Key_Space);
        verify(!toggle.checked, "the host owns Toggle.checked");
        compare(tc.toggles, 2);
        verify(toggle.activeFocus);
        compare(toggle.Accessible.role, Accessible.CheckBox);
    }

    // A disabled or hidden control ignores every activation path, assistive technology included (R12).
    function test_accessibilityActivationIsGuarded() {
        const controls = [check, radio2, sw];
        for (const c of controls) {
            c.checked = false;
            c.Accessible.pressAction();
            verify(c.checked, c.Accessible.name + ": a shown, enabled control acts on press");
            c.checked = false;
            c.Accessible.toggleAction();
            verify(c.checked, c.Accessible.name + ": and on toggle");
            c.checked = false;
            c.enabled = false;
            c.Accessible.pressAction();
            c.Accessible.toggleAction();
            verify(!c.checked, c.Accessible.name + ": disabled ignores press and toggle");
            c.enabled = true;
            c.visible = false;
            c.Accessible.pressAction();
            c.Accessible.toggleAction();
            verify(!c.checked, c.Accessible.name + ": hidden ignores press and toggle");
            c.visible = true;
        }
        tc.toggles = 0;
        toggleTool.checked = false;
        toggleTool.visible = false;
        toggleTool.Accessible.toggleAction();
        toggleTool.Accessible.pressAction();
        verify(!toggleTool.checked, "a hidden checkable ToolButton ignores toggle and press");
        toggleTool.visible = true;
        toggleTool.enabled = false;
        toggleTool.Accessible.toggleAction();
        verify(!toggleTool.checked, "a disabled one too");
        toggleTool.enabled = true;
        toggleTool.Accessible.toggleAction();
        verify(toggleTool.checked, "a shown, enabled one toggles");
        toggleTool.checked = false;
        toggle.visible = false;
        toggle.Accessible.toggleAction();
        toggle.Accessible.pressAction();
        compare(tc.toggles, 0, "a hidden Toggle never reports");
        toggle.visible = true;
        toggle.enabled = false;
        toggle.Accessible.toggleAction();
        compare(tc.toggles, 0, "a disabled Toggle never reports");
        toggle.enabled = true;
        toggle.Accessible.toggleAction();
        compare(tc.toggles, 1);
    }

    // A hidden or disabled control that is handed key events (code can focus it, Keys.forwardTo reaches it) acts on none, and
    // swallows its activation keys so that a parent does not act on them either.
    function test_hiddenOrDisabledControlsSwallowTheirKeys() {
        const keys = [Qt.Key_Space, Qt.Key_Return, Qt.Key_Enter];
        for (const state of ["hidden", "disabled"]) {
            for (const c of [toggleTool, check, sw, toggle, radio1, radio2]) {
                const before = c.checked;
                const togglesBefore = tc.toggles;
                if (state === "hidden")
                    c.visible = false;
                else
                    c.enabled = false;
                forwarder.target = c;
                forwarder.reached = [];
                if (state === "hidden")
                    c.forceActiveFocus(Qt.TabFocusReason);  // code can still give a hidden control the focus
                else
                    forwarder.forceActiveFocus();
                for (const k of keys)
                    keyClick(k);
                compare(c.checked, before, c.Accessible.name + " " + state + ": no change on an activation key");
                compare(tc.toggles, togglesBefore, c.Accessible.name + " " + state + ": nothing reported");
                compare(forwarder.reached, [], c.Accessible.name + " " + state + ": the activation keys were swallowed");
                c.visible = true;
                c.enabled = true;
            }
            // Radio groups: the arrows do not check a sibling either (a hidden radio is not in its own group: indexOf was -1).
            radio1.checked = true;
            if (state === "hidden")
                radio1.visible = false;
            else
                radio1.enabled = false;
            forwarder.target = radio1;
            keyClick(Qt.Key_Down);
            verify(!radio2.checked, "a " + state + " radio does not move the group");
            radio1.visible = true;
            radio1.enabled = true;
        }
        forwarder.target = null;
    }

    // Hiding or disabling the control that has the focus moves the focus on (macOS): it never stays on what cannot act.
    function test_hidingOrDisablingTheFocusedControlMovesTheFocus() {
        for (const c of [toggleTool, check, sw, toggle, radio2]) {
            for (const state of ["hidden", "disabled"]) {
                c.forceActiveFocus(Qt.TabFocusReason);
                verify(c.activeFocus, c.Accessible.name + " has the focus");
                if (state === "hidden")
                    c.visible = false;
                else
                    c.enabled = false;
                verify(!c.activeFocus, c.Accessible.name + " " + state + ": the focus left it");
                c.visible = true;
                c.enabled = true;
            }
        }
        // An accessibility toggle on a hidden Button does nothing either (the Allow button of the polkit dialog).
        button.visible = false;
        button.Accessible.toggleAction();
        compare(tc.clicks, 0);
        button.visible = true;
        button.Accessible.toggleAction();
        compare(tc.clicks, 1);
    }

    function test_reduceMotionCapsTheSwitchAnimation() {
        Appearance.reduceMotion = true;
        verify(Appearance.duration(Tokens.motionSlow) <= Tokens.motionReducedMax);
    }
}
