import QtQuick
import QtTest
import Grassfield.Ui

// The key guard of the shared Button (ui/Grassfield/Ui/Button.qml): a Button that is hidden or disabled while it still holds the
// keyboard focus never activates, and swallows ONLY its activation keys (Return, Enter, Space) so that they do not bubble up to a
// parent that acts on them; every other key, Escape above all (the polkit dialog and the Notifications column close on it),
// propagates to the parents.
TestCase {
    id: tc

    name: "ButtonKeys"
    width: 300
    height: 200
    visible: true
    when: windowShown

    property int clicks: 0
    property var parentKeys: []

    Item {
        id: host

        anchors.fill: parent
        Keys.onPressed: event => {
            tc.parentKeys.push(event.key);
            event.accepted = true;
        }

        Button {
            id: button

            text: "Test"
            onClicked: tc.clicks++
        }
    }

    function init() {
        tc.clicks = 0;
        tc.parentKeys = [];
        button.visible = true;
        button.enabled = true;
        button.forceActiveFocus();
        verify(button.activeFocus);
    }

    function test_visibleButtonActivates() {
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Space);
        keyClick(Qt.Key_Enter);
        compare(tc.clicks, 3);
        compare(tc.parentKeys.length, 0);
    }

    // The activation keys do nothing and do not reach the parent.
    function test_hiddenButtonSwallowsActivationKeys() {
        button.visible = false;
        verify(button.activeFocus, "Qt keeps the focus on a hidden item");
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Space);
        keyClick(Qt.Key_Enter);
        compare(tc.clicks, 0);
        compare(tc.parentKeys.length, 0);
    }

    // (No case for a disabled Button: Qt takes the focus off a disabled item, so a key never reaches its handler and a test of the
    // `enabled` half of the guard would prove nothing. The hidden case below does reach it: Qt keeps the focus on a hidden item.)

    // Escape (and any other key) from a hidden Button reaches the parent.
    function test_hiddenButtonLetsEscapeAndOtherKeysPropagate() {
        button.visible = false;
        verify(button.activeFocus);
        keyClick(Qt.Key_Escape);
        keyClick(Qt.Key_Delete);
        keyClick(Qt.Key_Tab);
        compare(tc.clicks, 0);
        compare(tc.parentKeys.indexOf(Qt.Key_Escape) >= 0, true, "Escape reached the parent");
        compare(tc.parentKeys.indexOf(Qt.Key_Delete) >= 0, true, "Delete reached the parent");
    }

    function test_visibleButtonLetsOtherKeysPropagate() {
        keyClick(Qt.Key_Escape);
        compare(tc.parentKeys.indexOf(Qt.Key_Escape) >= 0, true);
        compare(tc.clicks, 0);
    }
}
