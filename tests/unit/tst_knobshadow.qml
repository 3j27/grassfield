import QtQuick
import QtTest
import Grassfield.Ui

// The switch knob's drop shadow (ADR-0039 step 28, G9 with Increase Contrast off; audit §3.24, measured on macOS 27): a real
// RectangularShadow under the knob of Toggle and Switch, on the tokens, a child of the knob.
TestCase {
    id: tc

    name: "KnobShadow"
    width: 200
    height: 100
    visible: true
    when: windowShown

    Rectangle {
        id: scene
        width: 200
        height: 100
        color: Appearance.colors.groupFill

        Toggle {
            id: toggle
            x: 20
            y: 20
        }

        Switch {
            id: sw
            x: 20
            y: 60
        }
    }

    property bool wasDark: false

    function initTestCase() {
        tc.wasDark = Appearance.dark;
        Appearance.dark = false;
    }

    function cleanupTestCase() {
        Appearance.dark = tc.wasDark;
    }

    function shadowOf(control) {
        const stack = [control];
        while (stack.length > 0) {
            const it = stack.shift();
            if (String(it).indexOf("QQuickRectangularShadow") === 0)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_theShadowIsOnTheTokens_data() {
        return [{tag: "Toggle", control: toggle}, {tag: "Switch", control: sw}];
    }

    function test_theShadowIsOnTheTokens(data) {
        const s = shadowOf(data.control);
        verify(s !== null, "a real shadow, not a drawn ring");
        compare(s.blur, Tokens.controlKnobShadowBlur);
        compare(s.offset.y, Tokens.controlKnobShadowOffsetY);
        fuzzyCompare(Qt.color(s.color).a, Tokens.controlKnobShadowOpacity, 0.005);
        verify(s.z < 0, "under the knob");
        compare(s.width, s.parent.width, "the knob's own shape");
        compare(s.radius, s.parent.radius);
    }

    // The shadow is the knob's child: it moves with the knob and fades with a dimmed knob. Its pixels need the GPU renderer
    // (a RectangularShadow is a shader: the offscreen software renderer here draws none); the 2x render of audit §3.24 is
    // the evidence that it matches the macOS 27 measure.
    function test_theShadowFollowsTheKnob() {
        const s = shadowOf(toggle);
        const knob = s.parent;
        verify(Qt.colorEqual(knob.color, Appearance.colors.knob), "the knob");
        const x0 = knob.x;
        toggle.checked = true;
        tryVerify(() => knob.x !== x0, 1000, "the knob moves");
        compare(s.x, 0, "the shadow with it");
        toggle.checked = false;
        compare(Qt.color(s.color).a > 0, true);
    }
}
