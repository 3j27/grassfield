import QtQuick
import QtTest
import Grassfield.Ui

// One fill for "on" (ADR-0039 step 11, D-Q4: "the same as on macOS 27", which draws its switches, check boxes, slider fills,
// default buttons and selected rows in one accent fill with white marks; the dark macOS 27 captures show one green for the
// menu highlight, the selected row and the swatch). A switch that is on, a slider's fill, a checked box and a default button
// share the selection colour, in both appearances and for every accent: before, a switch and a slider took the bright dark
// accent, on which the white knob held 1.5 to 2.8:1. The knob's edge reaches 3:1 (WCAG 1.4.11) against that fill: the white
// knob itself (4.85:1 or more), or, on the yellow and green fills that keep dark marks, the outline drawn in their mark colour.
TestCase {
    id: tc

    name: "OnFill"
    width: 400
    height: 200
    visible: true
    when: windowShown

    readonly property var accents: ["multicolor", "blue", "purple", "pink", "red", "orange", "yellow", "green", "graphite"]

    Column {
        Toggle { id: toggle; checked: true }
        Switch { id: switchControl; checked: true }
        Slider { id: slider; width: 200; value: 0.5 }
        CheckBox { id: box; checked: true; text: "Box" }
        Button { id: defaultButton; text: "OK"; primary: true }
    }

    function channel(v) {
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    }

    function ratio(a, b) {
        const ca = Qt.color(a), cb = Qt.color(b);
        const la = 0.2126 * channel(ca.r) + 0.7152 * channel(ca.g) + 0.0722 * channel(ca.b);
        const lb = 0.2126 * channel(cb.r) + 0.7152 * channel(cb.g) + 0.0722 * channel(cb.b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    function cleanup() {
        Appearance.accentSetting = "multicolor";
        Appearance.dark = true;
        Appearance.increaseContrast = false;
    }

    // The visible rectangles under `item` of a given size (a track, a knob), largest first.
    function rects(item, w, h) {
        const out = [];
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it !== item && String(it).indexOf("QQuickRectangle") === 0 && it.visible && Math.abs(it.width - w) < 0.5 && Math.abs(it.height - h) < 0.5)
                out.push(it);
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return out;
    }

    function track(control) {
        const found = rects(control, control.width, control.height).filter(r => r.radius === r.height / 2);
        verify(found.length > 0, "the track of " + control);
        return found[0];
    }

    function knob(control) {
        const found = rects(control, Tokens.controlToggleKnobWidth, Tokens.controlToggleKnobHeight);
        verify(found.length === 1, "the knob of " + control);
        return found[0];
    }

    function sliderFill() {
        const stack = [slider];
        while (stack.length > 0) {
            const it = stack.shift();
            if (String(it).indexOf("QQuickRectangle") === 0 && it.visible && it.height === Tokens.controlSliderTrack && it.width < slider.width - 1 && it.width > 0)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function sliderKnob() {
        const found = rects(slider, Tokens.controlSliderKnobWidth, Tokens.controlSliderKnob);
        verify(found.length === 1, "the slider's knob");
        return found[0];
    }

    // The colour the knob's edge shows against the fill: its outline when the control outlines it, else the knob itself (the
    // slider's knob always carries a faint shadow hairline, which is no edge colour).
    function edge(k, outlined) {
        return outlined ? k.border.color : k.color;
    }

    function test_oneFillForOn() {
        for (const name of tc.accents) {
            Appearance.accentSetting = name;
            for (const dark of [true, false]) {
                Appearance.dark = dark;
                const what = name + (dark ? " dark" : " light");
                const fill = Qt.color(Appearance.colors.selection);
                // The tracks crossfade to a new colour (Behavior on color).
                const t1 = track(toggle), t2 = track(switchControl);
                tryVerify(() => Qt.colorEqual(t1.color, fill), Tokens.motionSlow * 4, "a Toggle that is on, " + what + ": " + t1.color);
                tryVerify(() => Qt.colorEqual(t2.color, fill), Tokens.motionSlow * 4, "a Switch that is on, " + what + ": " + t2.color);
                const f = sliderFill();
                verify(f !== null, "the slider's fill");
                compare(f.color, fill, "a slider's fill, " + what);
                compare(defaultButton.background.color, fill, "a default button, " + what);
                verify(rects(box, Tokens.controlCheckBoxSize, Tokens.controlCheckBoxSize).some(r => Qt.colorEqual(r.color, fill)), "a checked box, " + what);
            }
        }
    }

    function test_theKnobsEdgeHoldsOnTheFill() {
        for (const name of tc.accents) {
            Appearance.accentSetting = name;
            for (const dark of [true, false]) {
                Appearance.dark = dark;
                const what = name + (dark ? " dark" : " light");
                const fill = Appearance.colors.selection;
                const white = ratio(Appearance.colors.knob, fill);
                for (const c of [{control: toggle, knob: knob(toggle)}, {control: switchControl, knob: knob(switchControl)}, {control: slider, knob: sliderKnob()}]) {
                    const k = c.knob;
                    const outlined = c.control.knobOutlined;
                    compare(outlined, white < Tokens.controlKnobMinContrast, what + ": outlined exactly where white holds under 3:1");
                    const r = ratio(edge(k, outlined), fill);
                    verify(r >= Tokens.controlKnobMinContrast, what + ": the knob's edge " + edge(k, outlined) + " on " + fill + " " + r.toFixed(2));
                    if (outlined) {
                        verify(k.border.width > 0, what + ": an outline is drawn");
                        verify(Qt.colorEqual(k.border.color, Appearance.colors.selectionText), what + ": in the mark colour");
                    } else if (c.control !== slider) {
                        compare(k.border.width, 0, what + ": no outline where white holds");
                    }
                }
            }
        }
        // The two fills that keep dark marks.
        Appearance.dark = true;
        for (const name of ["yellow", "green"]) {
            Appearance.accentSetting = name;
            verify(toggle.knobOutlined && switchControl.knobOutlined && slider.knobOutlined, name);
        }
        Appearance.accentSetting = "multicolor";
        verify(!toggle.knobOutlined && !switchControl.knobOutlined && !slider.knobOutlined, "the Grassfield green holds white");
    }

    function test_offHasNoOutline() {
        Appearance.accentSetting = "green";
        toggle.checked = false;
        switchControl.checked = false;
        verify(!toggle.knobOutlined && !switchControl.knobOutlined, "off, the track is no fill of the accent");
        toggle.checked = true;
        switchControl.checked = true;
    }
}
