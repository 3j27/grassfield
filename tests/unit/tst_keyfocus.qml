import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// KeyFocus (ADR-0039 step 7, G7): an item that is not a Control shows its focus ring after a key gave it the focus, never after a
// click that took it; the click itself still reaches the item's own MouseArea. Then the same on real hosts: LinkText and
// Settings' colour well (a click opens its popover, whose square takes the focus by code: no ring either). Last, a surface that
// gives an item the focus when it opens (the shell's volume menu, Force Quit, a stack: ADR-0039 step 8) binds `pointer` to how
// it was opened (Popups.openedByPointer): no ring when a click opened it, the ring when a key did.
TestCase {
    id: tc

    name: "KeyFocus"
    width: 300
    height: 120
    visible: true
    when: windowShown

    Row {
        spacing: 20

        Item {
            id: before
            width: 60
            height: 40
            activeFocusOnTab: true
        }

        Item {
            id: item
            width: 60
            height: 40
            activeFocusOnTab: true
            property int clicks: 0

            // Declared before the MouseArea, as most hosts do: it still sees the press.
            KeyFocus {
                id: keyFocus
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    item.clicks++;
                    item.forceActiveFocus();
                }
            }

            FocusRing {
                id: ring
                visible: keyFocus.active
            }
        }
    }

    Column {
        y: 60
        spacing: 12

        LinkText {
            id: link
            text: "A link"
        }

        SettingsQml.ColorWell {
            id: well
            accessibleName: "Colour"
            color: "#e5484d"
        }
    }

    // A surface whose item has the focus when it opens, as the volume menu's mute button.
    Component {
        id: surfaceComponent

        FocusScope {
            id: surface

            // How it was opened (the shell's Popups.openedByPointer).
            property bool openedByPointer: false

            y: 100
            width: 60
            height: 20

            property alias ring: openRing
            property alias button: openButton

            Item {
                id: openButton
                width: 60
                height: 20
                focus: true
                activeFocusOnTab: true

                KeyFocus {
                    id: openFocus
                    pointer: surface.openedByPointer
                }

                FocusRing {
                    id: openRing
                    visible: openFocus.active
                }
            }
        }
    }

    // The visible FocusRing under `item` (its border is the focus outline), or null.
    function shownRing(item) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it.shapeRadius !== undefined && it.border !== undefined && it.visible && it.border.width === Tokens.controlFocusOutline
                    && Qt.colorEqual(it.border.color, Appearance.focusRingColor))
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function init() {
        before.forceActiveFocus(Qt.TabFocusReason);
        item.clicks = 0;
    }

    function test_aKeyShowsTheRing() {
        keyClick(Qt.Key_Tab);
        verify(item.activeFocus, "Tab moved the focus to the item");
        verify(keyFocus.active);
        verify(ring.visible);
    }

    function test_aClickShowsNoRing() {
        mouseClick(item);
        compare(item.clicks, 1, "the click reached the item's own MouseArea");
        verify(item.activeFocus, "the click gave the item the focus");
        verify(!keyFocus.active);
        verify(!ring.visible, "no ring after a click");
    }

    function test_theKeyboardAfterAClick() {
        mouseClick(item);
        verify(!ring.visible);
        // Away and back by the keyboard: the ring shows again.
        keyClick(Qt.Key_Tab, Qt.ShiftModifier);
        verify(before.activeFocus);
        keyClick(Qt.Key_Tab);
        verify(item.activeFocus);
        verify(ring.visible, "the focus a key gave shows the ring");
    }

    function test_aClickOnAKeyFocusedItemHidesTheRing() {
        keyClick(Qt.Key_Tab);
        verify(ring.visible);
        mouseClick(item);
        verify(item.activeFocus);
        verify(!ring.visible, "a press hands the focus to the pointer");
    }

    function test_aLinkShowsItsRingAfterAKeyOnly() {
        link.forceActiveFocus(Qt.TabFocusReason);
        verify(shownRing(link) !== null, "Tab: the link's ring");
        before.forceActiveFocus(Qt.TabFocusReason);
        mouseClick(link);
        verify(link.activeFocus, "a click gives the link the focus");
        compare(shownRing(link), null, "no ring after a click");
    }

    function test_aColourWellShowsNoRingAfterAClick() {
        mouseClick(well);
        verify(well.open, "the click opened the popover");
        compare(shownRing(well), null, "no ring on the well or its square after a click");
        keyClick(Qt.Key_Escape);
        verify(!well.open);
        verify(well.activeFocus, "Escape gives the well the focus back");
        verify(shownRing(well) !== null, "a key closed it: the well's ring");
    }

    function test_aSurfaceOpenedByAClickShowsNoRingOnOpen() {
        const surface = createTemporaryObject(surfaceComponent, tc, {openedByPointer: true});
        surface.forceActiveFocus();
        verify(surface.button.activeFocus, "the item has the focus on open");
        verify(!surface.ring.visible, "a click opened the surface: no ring");
        // Away and back by the keyboard: the ring shows.
        before.forceActiveFocus(Qt.TabFocusReason);
        surface.button.forceActiveFocus(Qt.TabFocusReason);
        verify(surface.ring.visible, "the focus a key gave shows the ring");
    }

    function test_aSurfaceOpenedByAKeyShowsItsRingOnOpen() {
        const surface = createTemporaryObject(surfaceComponent, tc, {openedByPointer: false});
        surface.forceActiveFocus();
        verify(surface.button.activeFocus);
        verify(surface.ring.visible, "a key opened the surface: the ring");
    }
}
