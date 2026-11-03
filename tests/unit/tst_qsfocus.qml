import QtQuick
import QtTest
import Grassfield.Ui

// Quick Settings: the focus ring is for the keyboard only (a click leaves none), and the module sliders are knobless with a
// white fill (visual audit 2026-10-25, integrator decisions, macOS model).
TestCase {
    id: testCase
    name: "QuickSettingsFocus"
    width: 300
    height: 200
    visible: true
    when: windowShown

    Component {
        id: navComponent
        Loader {
            width: 40
            height: 40
            source: Qt.resolvedUrl("../../shell/overlay/controlcenter/NavItem.qml")
            // qmllint disable missing-property
            onLoaded: item.accessibleName = "probe"
            // qmllint enable missing-property
        }
    }

    Component {
        id: sliderComponent
        Slider {
            width: 200
            height: 22
            knobless: true
            trackHeight: Tokens.controlSliderTrackCompact
            value: 0.5
        }
    }

    // The ring rectangle of a NavItem: the child drawn above the content (z 10).
    function ringOf(nav) {
        for (const child of nav.children) {
            if (child.z === 10)
                return child;
        }
        return null;
    }

    function test_pointerFocusShowsNoRing() {
        const loader = createTemporaryObject(navComponent, testCase);
        tryVerify(() => loader.item !== null);
        const nav = loader.item;
        const ring = ringOf(nav);
        verify(ring !== null);
        nav.forceActiveFocus(Qt.MouseFocusReason);
        verify(nav.activeFocus);
        compare(nav.visualFocus, false);
        // The shared FocusRing outside the item (ADR-0039 step 7): hidden, not thinned.
        compare(ring.visible, false);
    }

    function test_keyboardFocusShowsTheRing() {
        const loader = createTemporaryObject(navComponent, testCase);
        tryVerify(() => loader.item !== null);
        const nav = loader.item;
        nav.forceActiveFocus(Qt.TabFocusReason);
        compare(nav.visualFocus, true);
        verify(ringOf(nav).visible);
        compare(ringOf(nav).border.width, Tokens.controlFocusOutline);
        // Outside the item, never inside its shape.
        verify(ringOf(nav).x < 0 && ringOf(nav).width > nav.width, "ring " + ringOf(nav).x + ", " + ringOf(nav).width);
    }

    function test_knoblessSliderIsAWhiteFillOnADarkerTrack() {
        const s = createTemporaryObject(sliderComponent, testCase);
        compare(s.knobless, true);
        compare(s.travel, s.width);
        // Clicking the middle sets the middle: no knob offset in the mapping.
        mouseClick(s, 100, 11);
        fuzzyCompare(s.shown, 0.5, 0.01);
        mouseClick(s, 150, 11);
        fuzzyCompare(s.shown, 0.75, 0.01);
        verify(Tokens.quicksettingsSliderTrackOpacity > Tokens.materialFillOpacity);
    }
}
