import QtQuick
import QtTest
import Grassfield.Ui

// A press on a toolbar button dismisses its tooltip until the pointer leaves (macOS): the Files Share button's menu opens with
// the pointer still on the button, and the tooltip must not stay on top of it.
TestCase {
    id: tc
    name: "TooltipDismiss"
    width: 200
    height: 80
    visible: true
    when: windowShown

    ToolButton {
        id: button
        x: 20
        y: 20
        accessibleName: "Share"
        iconName: "share"
    }

    function test_pressDismissesUntilTheyLeave() {
        mouseMove(tc, button.x + 4, button.y + 4);
        tryVerify(() => button.hovered);
        verify(!button.tipDismissed);
        mousePress(tc, button.x + 4, button.y + 4);
        verify(button.tipDismissed, "a press dismisses the tooltip");
        mouseRelease(tc, button.x + 4, button.y + 4);
        verify(button.hovered);
        verify(button.tipDismissed, "still dismissed while the pointer rests on the button");
        mouseMove(tc, 150, 70);
        tryVerify(() => !button.hovered);
        verify(!button.tipDismissed, "the pointer left: the next hover may show it again");
    }
}
