import QtQuick
import QtTest
import Grassfield.Ui

// The key guard of the shared Button (ui/Grassfield/Ui/Button.qml): a Button that is hidden or disabled while it still holds the
// keyboard focus never activates, and swallows ONLY its activation keys (Return, Enter, Space) so that they do not bubble up to a
// parent that acts on them; every other key, Escape above all (the polkit dialog and the Notifications column close on it),
// propagates to the parents. An accessibility press goes through the same guard (Button.activate()).
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

    // Hands every key to the Button's own handler first and records the keys it did not accept.
    Item {
        id: forwarder

        property var reached: []

        Keys.forwardTo: [button]
        Keys.onPressed: event => {
            forwarder.reached = forwarder.reached.concat([event.key]);
            event.accepted = true;
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

    // A disabled Button: Qt takes the focus off a disabled item, so its keys are handed to its handler by `forwarder`
    // (Keys.forwardTo delivers to the target whether or not it is enabled). Nothing acts, and the activation keys are swallowed:
    // none comes back to the forwarder's own handler.
    function test_disabledButtonSwallowsActivationKeys() {
        button.enabled = false;
        verify(!button.activeFocus, "Qt takes the focus off a disabled item");
        forwarder.reached = [];
        forwarder.forceActiveFocus();
        verify(forwarder.activeFocus);
        keyClick(Qt.Key_Return);
        keyClick(Qt.Key_Space);
        keyClick(Qt.Key_Enter);
        compare(tc.clicks, 0);
        compare(forwarder.reached, [], "the disabled Button's handler received and swallowed them");
        // Control: the same path reaches an enabled Button, which acts.
        button.enabled = true;
        forwarder.forceActiveFocus();
        keyClick(Qt.Key_Return);
        compare(tc.clicks, 1);
    }

    // An assistive technology's press (Accessible.pressAction, the AT-SPI "press" action) goes through the same guard: it acts
    // on a shown, enabled Button only.
    function test_accessibilityPressHonoursVisibleAndEnabled() {
        button.Accessible.pressAction();
        compare(tc.clicks, 1);
        button.enabled = false;
        button.Accessible.pressAction();
        compare(tc.clicks, 1, "a disabled Button never acts on an accessibility press");
        button.enabled = true;
        button.visible = false;
        button.Accessible.pressAction();
        compare(tc.clicks, 1, "a hidden Button never acts on an accessibility press");
    }

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
