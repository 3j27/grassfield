import QtQuick
import QtTest
import Grassfield.Ui

// Increase Contrast outlines every shared control (ADR-0039 steps 1 and 2, G8 and G9): the switches' tracks and knobs, the
// slider's track above its fill, the rimmed capsules of app windows; the settings-row pop-up outlines its chevron disc, never a box
// around its value (the value starts at the pop-up's edge, so a box cut into its first letter: "Icon theme" read "|con theme").
// The switches, sliders and capsules are judged on what they render (grabImage), not on their properties: a slider's fill once
// covered the outline its track drew, and a knobless slider at its end changed no pixel. With the setting off, nothing carries
// the outline (a slider's overlay or a knob's border left on would read as a heavier control).
TestCase {
    id: tc

    name: "IncreaseContrast"
    width: 400
    height: 300
    visible: true
    when: windowShown

    // The controls sit on the material of their appearance, as in the shell (the test window's own white would hide a light outline).
    Rectangle {
        anchors.fill: parent
        color: Appearance.colors.materialTint
    }

    Column {
        spacing: 12

        Toggle { id: toggleOff; checked: false }
        Toggle { id: toggleOn; checked: true }
        Switch { id: switchOff; checked: false }
        Slider { id: slider; width: 200; value: 0.5 }
        Slider { id: knobless; width: 200; value: 0.5; knobless: true }
        Slider { id: knoblessFull; width: 200; value: 1; knobless: true }
        RimmedCapsule { id: capsule; width: 200; height: Tokens.toolbarSearchHeight }
        ComboBox { id: form; width: 180; model: [{id: "a", text: "Automatic"}]; value: "a" }
        ComboBox { id: rowPopUp; inline: true; model: [{id: "a", text: "Icon theme"}]; value: "a" }
    }

    property bool wasDark: true

    function initTestCase() {
        tc.wasDark = Appearance.dark;
    }

    function init() {
        Appearance.increaseContrast = false;
    }

    function cleanup() {
        Appearance.increaseContrast = false;
        Appearance.dark = tc.wasDark;
    }

    // The visible rectangle of `item` as wide as the control: a switch's or a slider's track, a pop-up's bezel.
    function track(item, width) {
        const stack = [item];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it !== item && it.visible && String(it).indexOf("QQuickRectangle") === 0 && Math.abs(it.width - width) < 0.01)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    // The control outline of Increase Contrast: the material border colour at the border opacity. (A Rectangle reports a
    // 1-wide black border even when it draws none, so the width alone does not tell.)
    function outlined(rect) {
        return rect.border.width === Tokens.controlBorderWidth
            && Qt.colorEqual(rect.border.color, Appearance.withAlpha(Appearance.colors.materialBorder, Tokens.materialBorderOpacity));
    }

    // Every visible rectangle of `control` (the control itself included: a RimmedCapsule is one) that carries the outline: a
    // track, a knob, the slider's overlay, a bezel, a disc. The slider's knob is left out: it always draws its own edge in the
    // shadow colour at the border opacity, which is the outline's colour in the light appearance (Increase Contrast darkens it).
    function outlines(control) {
        let n = 0;
        const stack = [control];
        while (stack.length > 0) {
            const it = stack.shift();
            const rectangle = it.border !== undefined && it.radius !== undefined;
            const sliderKnob = it.width === Tokens.controlSliderKnobWidth && it.height === Tokens.controlSliderKnob;
            if (it.visible && rectangle && !sliderKnob && outlined(it))
                n++;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return n;
    }

    function changedPixels(a, b, width, height) {
        let n = 0;
        for (let y = 0; y < height; y++) {
            for (let x = 0; x < width; x++) {
                if (!Qt.colorEqual(a.pixel(x, y), b.pixel(x, y)))
                    n++;
            }
        }
        return n;
    }

    function test_nothingIsOutlinedWithTheSettingOff_data() {
        const rows = [];
        const controls = [
            {tag: "toggle off", control: toggleOff},
            {tag: "toggle on", control: toggleOn},
            {tag: "switch off", control: switchOff},
            {tag: "slider", control: slider},
            {tag: "knobless slider", control: knobless},
            {tag: "knobless slider at its end", control: knoblessFull},
            {tag: "rimmed capsule", control: capsule},
            {tag: "form pop-up", control: form},
            {tag: "row pop-up", control: rowPopUp}
        ];
        for (const dark of [false, true]) {
            for (const c of controls)
                rows.push({tag: c.tag + (dark ? ", dark" : ", light"), control: c.control, dark: dark});
        }
        return rows;
    }

    function test_nothingIsOutlinedWithTheSettingOff(data) {
        Appearance.dark = data.dark;
        compare(outlines(data.control), 0, data.tag + ": an outline with Increase Contrast off");
        Appearance.increaseContrast = true;
        verify(outlines(data.control) >= 1, data.tag + ": no outline with Increase Contrast on");
    }

    function test_switchesSlidersAndCapsulesShowTheOutline_data() {
        const rows = [];
        const controls = [
            {tag: "toggle off", control: toggleOff},
            {tag: "toggle on", control: toggleOn},
            {tag: "switch off", control: switchOff},
            {tag: "slider", control: slider},
            {tag: "knobless slider", control: knobless},
            {tag: "knobless slider at its end", control: knoblessFull},
            {tag: "rimmed capsule", control: capsule}
        ];
        for (const dark of [false, true]) {
            for (const c of controls) {
                // Dark, a knobless slider at its end is all white fill: the outline (white at the border opacity) adds nothing,
                // and the fill itself is the edge against the dark material.
                const fillIsTheEdge = dark && c.control === knoblessFull;
                rows.push({tag: c.tag + (dark ? ", dark" : ", light"), control: c.control, dark: dark, fillIsTheEdge: fillIsTheEdge});
            }
        }
        return rows;
    }

    function test_switchesSlidersAndCapsulesShowTheOutline(data) {
        Appearance.dark = data.dark;
        wait(Tokens.motionSlow);   // colour behaviours settle before the first frame is taken
        const w = Math.ceil(data.control.width);
        const h = Math.ceil(data.control.height);
        const before = grabImage(data.control);
        compare(changedPixels(before, grabImage(data.control), w, h), 0, "the control is still while it is taken");
        Appearance.increaseContrast = true;
        const after = grabImage(data.control);
        if (data.fillIsTheEdge) {
            // The fill's middle against the material beside the control: a component edge needs 3:1 (WCAG 1.4.11).
            const fill = after.pixel(Math.floor(w / 2), Math.floor(h / 2));
            const ratio = contrast(fill, Qt.lighter(Appearance.colors.materialTint, 1));
            verify(ratio >= 3, data.tag + ": the fill against the material " + ratio.toFixed(2) + ":1");
            return;
        }
        // At least a run along each long edge (an outline of 1 pt round the whole shape changes far more).
        verify(changedPixels(before, after, w, h) >= w, data.tag + ": " + changedPixels(before, after, w, h) + " pixels changed");
    }

    function luminance(c) {
        const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    function contrast(a, b) {
        const la = luminance(a);
        const lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    // G9: a white knob on a light track is 1.57:1; under Increase Contrast the knob carries the outline too.
    function knobOf(control) {
        const stack = [control];
        while (stack.length > 0) {
            const it = stack.shift();
            if (it !== control && String(it).indexOf("QQuickRectangle") === 0 && it.visible
                    && Math.abs(it.width - Tokens.controlToggleKnobWidth) < 0.01 && Math.abs(it.height - Tokens.controlToggleKnobHeight) < 0.01)
                return it;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        return null;
    }

    function test_switchKnobsAreOutlined_data() {
        return [{tag: "toggle", control: toggleOff}, {tag: "switch", control: switchOff}];
    }

    // grabImage(item) crops the window at item.x and item.y, which are relative to the item's parent: a knob inside its control
    // is judged on the whole scene's image, in its own rectangle mapped to the scene (the knob's edges included).
    function changedPixelsOf(item, before, after) {
        const p = item.mapToItem(tc, 0, 0);
        let n = 0;
        for (let y = Math.floor(p.y); y < Math.ceil(p.y + item.height); y++) {
            for (let x = Math.floor(p.x); x < Math.ceil(p.x + item.width); x++) {
                if (!Qt.colorEqual(before.pixel(x, y), after.pixel(x, y)))
                    n++;
            }
        }
        return n;
    }

    function test_switchKnobsAreOutlined(data) {
        Appearance.dark = false;
        wait(Tokens.motionSlow);
        const knob = knobOf(data.control);
        verify(knob !== null, "knob of the " + data.tag);
        const p = knob.mapToItem(tc, 0, 0);
        const c = data.control.mapToItem(tc, 0, 0);
        verify(p.y >= c.y && p.y + knob.height <= c.y + data.control.height, "the knob lies inside the " + data.tag);
        verify(p.y + knob.height <= tc.height, "the knob lies inside the scene");
        const before = grabImage(tc);
        Appearance.increaseContrast = true;
        const after = grabImage(tc);
        const n = changedPixelsOf(knob, before, after);
        verify(n >= knob.width, data.tag + " knob: " + n + " pixels changed");
    }

    function test_formPopUpKeepsItsBezelOutline() {
        const bezel = form.background as Rectangle;
        verify(!outlined(bezel));
        Appearance.increaseContrast = true;
        verify(outlined(bezel));
    }

    function test_inlinePopUpOutlinesItsDiscNotItsValue() {
        const bezel = rowPopUp.background as Rectangle;
        const disc = rowPopUp.indicator.children[0] as Rectangle;
        verify(disc.visible);
        verify(!outlined(bezel) && !outlined(disc));
        Appearance.increaseContrast = true;
        verify(!outlined(bezel), "no box around the value: it starts at the pop-up's edge");
        verify(outlined(disc), "the chevron disc carries the outline");
    }

    function test_inlinePopUpDiscIsOnWholePixels() {
        // settings.popupInset is a measured 3.5: the disc is rounded onto the device-pixel grid (here scale 1), within half a
        // point of it.
        verify(rowPopUp.width === Math.round(rowPopUp.width), "pop-up width " + rowPopUp.width);
        const x = rowPopUp.indicator.x;
        compare(x, Math.round(x));
        verify(Math.abs(rowPopUp.width - x - Tokens.settingsPopupIndicatorSize - Tokens.settingsPopupInset) <= 0.5,
               "disc inset " + (rowPopUp.width - x - Tokens.settingsPopupIndicatorSize));
    }
}
