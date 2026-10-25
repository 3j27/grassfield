import QtQuick
import QtTest
import "../../shell/overlay/InputSource.js" as IS

// The keyboard-versus-pointer tracking behind the Quick Settings focus ring.
TestCase {
    name: "InputSource"

    function test_startsWithThePointer() {
        compare(IS.start().keyboard, false);
    }

    function test_aKeyboardFocusTurnsTheRingOn() {
        let s = IS.focusMoved(IS.start(), true);
        compare(s.keyboard, true);
        compare(IS.ringShown(s, true), true);
        compare(IS.ringShown(s, false), false, "a control without a visual focus has no ring");
    }

    function test_aPointerFocusDoesNotTurnItOn() {
        compare(IS.focusMoved(IS.start(), false).keyboard, false);
        compare(IS.focusMoved(IS.start(), undefined).keyboard, false);
    }

    function test_hoverNeverChangesIt() {
        // Tab, then the mouse moves (and redraws send hover updates), then Return: the ring is still there.
        let s = IS.focusMoved(IS.start(), true);
        for (let i = 0; i < 5; i++)
            s = IS.hovered(s);
        compare(IS.ringShown(s, true), true);
    }

    function test_aPressHandsTheFocusToThePointer() {
        let s = IS.focusMoved(IS.start(), true);
        s = IS.pressed(s);
        compare(s.keyboard, false);
        compare(IS.ringShown(s, true), false);
        s = IS.focusMoved(s, true);
        compare(s.keyboard, true, "the next keyboard focus brings the ring back");
    }
}
